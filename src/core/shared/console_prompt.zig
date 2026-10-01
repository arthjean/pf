//! Console prompts outside the TUI: one line of visible or hidden input, a
//! wait for Enter, and a line that arrives while other work polls. A terminal
//! is switched to raw input for a prompt (POSIX `termios`, Windows console
//! modes) and restored before the prompt returns or fails; standard input that
//! is not a terminal is read as lines without changing any mode.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

const Allocator = std.mem.Allocator;

pub const max_line_bytes = 8 * 1024;
/// The exit code a POSIX shell reports for SIGINT, used when Ctrl+C arrives as
/// a key at a raw prompt.
pub const interrupt_exit_code: u8 = 130;

pub const Echo = enum { visible, masked };

pub const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;

pub const ReadError = error{
    /// Ctrl+C at a raw prompt.
    Interrupted,
    /// Ctrl+D or Escape at a raw prompt, or the terminal closed.
    Cancelled,
    /// Standard input that is not a terminal ended before any byte.
    EndOfInput,
    TooLong,
    ReadFailed,
    OutOfMemory,
};

pub const LineOptions = struct {
    echo: Echo,
    max_bytes: usize = max_line_bytes,
    /// Receives the echo: typed text, or one `mask` per character.
    write: WriteFn,
    write_ctx: ?*anyopaque = null,
    mask: []const u8 = "•",
};

const windows = std.os.windows;
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else struct {};

fn stdinHandle() std.posix.fd_t {
    return std.Io.File.stdin().handle;
}

fn consoleMode(handle: std.posix.fd_t) ?u32 {
    var mode: windows.DWORD = 0;
    if (!win32.GetConsoleMode(handle, &mode).toBool()) return null;
    return mode;
}

pub fn stdinIsTerminal() bool {
    return switch (builtin.os.tag) {
        .windows => consoleMode(stdinHandle()) != null,
        else => std.c.isatty(std.posix.STDIN_FILENO) != 0,
    };
}

/// Ends the process the way SIGINT ends it at a cooked prompt.
pub fn exitInterrupted() noreturn {
    std.process.exit(interrupt_exit_code);
}

/// Raw terminal input for the duration of one prompt: no line editing, no
/// echo, and Ctrl+C delivered as byte 3.
const RawInput = struct {
    saved: Saved,

    const Saved = switch (builtin.os.tag) {
        .windows => struct { input_mode: u32, output_code_page: u32 },
        else => std.posix.termios,
    };

    fn enable() ReadError!RawInput {
        switch (builtin.os.tag) {
            .windows => {
                const handle = stdinHandle();
                const mode = consoleMode(handle) orelse return error.ReadFailed;
                const raw = (mode & ~(win32.ENABLE_LINE_INPUT | win32.ENABLE_ECHO_INPUT | win32.ENABLE_PROCESSED_INPUT)) |
                    win32.ENABLE_VIRTUAL_TERMINAL_INPUT;
                if (!win32.SetConsoleMode(handle, raw).toBool()) return error.ReadFailed;
                const output_code_page = win32.GetConsoleOutputCP();
                // Echoed text is UTF-8.
                _ = win32.SetConsoleOutputCP(win32.CP_UTF8);
                return .{ .saved = .{ .input_mode = mode, .output_code_page = output_code_page } };
            },
            else => {
                const original = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return error.ReadFailed;
                var raw = original;
                raw.iflag.BRKINT = false;
                raw.iflag.ICRNL = false;
                raw.iflag.INPCK = false;
                raw.iflag.ISTRIP = false;
                raw.iflag.IXON = false;
                raw.iflag.IXOFF = false;
                raw.cflag.CSIZE = .CS8;
                raw.lflag.ECHO = false;
                raw.lflag.ICANON = false;
                raw.lflag.IEXTEN = false;
                raw.lflag.ISIG = false;
                const vmin_idx: usize = if (builtin.os.tag == .linux) 6 else 16;
                const vtime_idx: usize = if (builtin.os.tag == .linux) 5 else 17;
                if (vmin_idx < raw.cc.len and vtime_idx < raw.cc.len) {
                    raw.cc[vmin_idx] = 1;
                    raw.cc[vtime_idx] = 0;
                }
                std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch return error.ReadFailed;
                return .{ .saved = original };
            },
        }
    }

    fn restore(self: *const RawInput) void {
        switch (builtin.os.tag) {
            .windows => {
                _ = win32.SetConsoleMode(stdinHandle(), self.saved.input_mode);
                _ = win32.SetConsoleOutputCP(self.saved.output_code_page);
            },
            else => std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.saved) catch {},
        }
    }
};

const Key = union(enum) {
    byte: u8,
    timeout,
    end,
};

/// Reads raw terminal input one UTF-8 byte at a time. On Windows it decodes
/// the UTF-16 units of `ReadConsoleW`.
const KeyReader = struct {
    pending: [8]u8 = undefined,
    pending_start: usize = 0,
    pending_end: usize = 0,
    high_surrogate: ?u16 = null,

    /// Returns the next byte, `.timeout` when `timeout_ms` passes first, or
    /// `.end` when input closed. A null timeout waits indefinitely.
    fn next(self: *KeyReader, timeout_ms: ?u32) ReadError!Key {
        if (self.pending_start < self.pending_end) {
            defer self.pending_start += 1;
            return .{ .byte = self.pending[self.pending_start] };
        }
        switch (builtin.os.tag) {
            .windows => {
                while (self.pending_start == self.pending_end) {
                    if (!try waitForConsoleText(timeout_ms)) return .timeout;
                    var unit: [1]u16 = undefined;
                    var count: windows.DWORD = 0;
                    if (!win32.ReadConsoleW(stdinHandle(), &unit, 1, &count, null).toBool()) return error.ReadFailed;
                    if (count == 0) return .end;
                    self.decode(unit[0]);
                }
                return self.next(null);
            },
            else => {
                if (timeout_ms) |ms| {
                    var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
                    const ready = std.posix.poll(&fds, @intCast(@min(ms, std.math.maxInt(i32)))) catch return error.ReadFailed;
                    if (ready == 0) return .timeout;
                }
                var byte: [1]u8 = undefined;
                const n = std.posix.read(std.posix.STDIN_FILENO, &byte) catch return error.ReadFailed;
                return if (n == 0) .end else .{ .byte = byte[0] };
            },
        }
    }

    fn decode(self: *KeyReader, unit: u16) void {
        self.pending_start = 0;
        self.pending_end = 0;
        var code_point: u21 = unit;
        if (self.high_surrogate) |high| {
            self.high_surrogate = null;
            if (std.unicode.utf16IsLowSurrogate(unit)) {
                code_point = 0x10000 + ((@as(u21, high) - 0xD800) << 10) + (unit - 0xDC00);
            } else {
                self.append(std.unicode.replacement_character);
            }
        }
        if (code_point == unit and std.unicode.utf16IsHighSurrogate(unit)) {
            self.high_surrogate = unit;
            return;
        }
        if (code_point == unit and std.unicode.utf16IsLowSurrogate(unit)) code_point = std.unicode.replacement_character;
        self.append(code_point);
    }

    fn append(self: *KeyReader, code_point: u21) void {
        const len = std.unicode.utf8Encode(code_point, self.pending[self.pending_end..]) catch
            std.unicode.utf8Encode(std.unicode.replacement_character, self.pending[self.pending_end..]) catch unreachable;
        self.pending_end += len;
    }
};

/// Waits until console input holds a text key, discarding other records.
/// Returns false when `timeout_ms` passes first.
fn waitForConsoleText(timeout_ms: ?u32) ReadError!bool {
    const handle = stdinHandle();
    const started = io_mod.milliTimestamp();
    while (true) {
        // A zero or spent timeout still checks the input once.
        var wait_ms: u32 = win32.INFINITE;
        if (timeout_ms) |limit| {
            const elapsed: u64 = @intCast(@max(io_mod.milliTimestamp() - started, 0));
            wait_ms = if (elapsed >= limit) 0 else @intCast(limit - elapsed);
        }
        if (win32.WaitForSingleObject(handle, wait_ms) != win32.WAIT_OBJECT_0) return false;
        var records: [16]win32.INPUT_RECORD = undefined;
        var count: windows.DWORD = 0;
        if (!win32.PeekConsoleInputW(handle, &records, records.len, &count).toBool()) return error.ReadFailed;
        var skip: windows.DWORD = 0;
        while (skip < count and !isTextRecord(records[skip])) skip += 1;
        if (skip < count) {
            if (skip > 0) {
                var removed: windows.DWORD = 0;
                _ = win32.ReadConsoleInputW(handle, &records, skip, &removed);
            }
            return true;
        }
        var removed: windows.DWORD = 0;
        if (count > 0 and !win32.ReadConsoleInputW(handle, &records, count, &removed).toBool()) return error.ReadFailed;
    }
}

fn isTextRecord(record: anytype) bool {
    if (record.EventType != win32.KEY_EVENT) return false;
    const key = record.Event.KeyEvent;
    return key.bKeyDown.toBool() and key.UnicodeChar != 0;
}

/// Line editing shared by blocking prompts and polled lines.
const LineEditor = struct {
    line: std.ArrayList(u8) = .empty,
    options: LineOptions,

    const Step = enum { more, submit };

    /// Applies one input byte and echoes its effect.
    fn apply(self: *LineEditor, alloc: Allocator, byte: u8) ReadError!Step {
        switch (byte) {
            '\r', '\n' => return if (self.line.items.len == 0) .more else .submit,
            3 => return error.Interrupted,
            4, 0x1b => return error.Cancelled,
            8, 0x7f => {
                if (self.line.items.len == 0) return .more;
                // Remove one whole UTF-8 sequence.
                var len = self.line.items.len - 1;
                while (len > 0 and self.line.items[len] & 0xC0 == 0x80) len -= 1;
                std.crypto.secureZero(u8, self.line.items[len..]);
                self.line.shrinkRetainingCapacity(len);
                self.echo("\x08 \x08");
            },
            else => {
                if (byte < 0x20) return .more;
                // Hidden input takes printable ASCII only, as API keys are.
                if (self.options.echo == .masked and byte >= 0x7f) return .more;
                if (self.line.items.len >= self.options.max_bytes) return error.TooLong;
                try self.line.append(alloc, byte);
                switch (self.options.echo) {
                    .visible => self.echo(&.{byte}),
                    .masked => self.echo(self.options.mask),
                }
            },
        }
        return .more;
    }

    fn echo(self: *LineEditor, bytes: []const u8) void {
        self.options.write(self.options.write_ctx, bytes) catch {};
    }

    /// Returns the line as an exact-size owned copy and wipes the editor.
    fn take(self: *LineEditor, alloc: Allocator) ReadError![]u8 {
        // toOwnedSlice may move the buffer through realloc and free the old
        // one unwiped, so copy out and wipe the source.
        const owned = try alloc.dupe(u8, self.line.items);
        self.wipe(alloc);
        return owned;
    }

    fn wipe(self: *LineEditor, alloc: Allocator) void {
        std.crypto.secureZero(u8, self.line.allocatedSlice());
        self.line.deinit(alloc);
        self.line = .empty;
    }
};

/// Reads one line from standard input. On a terminal the input is raw:
/// typed text is echoed through `options.write` (or masked), Backspace
/// removes the last character, Enter submits a nonempty line, Ctrl+C returns
/// `error.Interrupted`, and Ctrl+D or Escape returns `error.Cancelled`. The
/// original modes are restored before returning. Other standard input is
/// read as one line without its line ending, without changing any mode.
/// Caller owns the returned slice and should wipe it when it is a secret.
pub fn readLine(alloc: Allocator, options: LineOptions) ReadError![]u8 {
    if (!stdinIsTerminal()) return readStreamLine(alloc, options.max_bytes);
    const raw = try RawInput.enable();
    defer raw.restore();
    var reader: KeyReader = .{};
    var editor: LineEditor = .{ .options = options };
    errdefer editor.wipe(alloc);
    while (true) {
        const byte = switch (try reader.next(null)) {
            .byte => |byte| byte,
            .timeout, .end => return error.Cancelled,
        };
        if (try editor.apply(alloc, byte) == .submit) return editor.take(alloc);
    }
}

/// Reads one line from standard input that is not a terminal, byte by byte
/// so nothing past the line is consumed.
fn readStreamLine(alloc: Allocator, max_bytes: usize) ReadError![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer {
        std.crypto.secureZero(u8, line.allocatedSlice());
        line.deinit(alloc);
    }
    const stdin = std.Io.File.stdin();
    while (true) {
        var byte: [1]u8 = undefined;
        const n = stdin.readStreaming(io_mod.getIo(), &.{&byte}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return error.ReadFailed,
        };
        if (n == 0) {
            if (line.items.len == 0) return error.EndOfInput;
            break;
        }
        if (byte[0] == '\n') break;
        if (line.items.len >= max_bytes) return error.TooLong;
        try line.append(alloc, byte[0]);
    }
    if (std.mem.endsWith(u8, line.items, "\r")) line.items.len -= 1;
    const owned = try alloc.dupe(u8, line.items);
    std.crypto.secureZero(u8, line.allocatedSlice());
    line.deinit(alloc);
    return owned;
}

/// Waits up to `timeout_ms` for the user to press Enter at a cooked prompt
/// and discards the line. Returns false when the time passes first. Ctrl+C
/// keeps its default effect: SIGINT on POSIX, and on Windows the console
/// control handler pf installs at startup.
pub fn waitForEnter(timeout_ms: u64) bool {
    const timeout: u32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));
    switch (builtin.os.tag) {
        .windows => {
            const handle = stdinHandle();
            if (consoleMode(handle) != null) return waitForConsoleEnter(handle, timeout);
            if (!streamReadable(handle)) {
                io_mod.sleep(@as(u64, timeout) * std.time.ns_per_ms);
                if (!streamReadable(handle)) return false;
            }
        },
        else => {
            var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, @intCast(timeout)) catch return false;
            if (ready == 0 or (fds[0].revents & std.posix.POLL.IN) == 0) return false;
        },
    }
    discardStreamLine();
    return true;
}

fn waitForConsoleEnter(handle: std.posix.fd_t, timeout_ms: u32) bool {
    const started = io_mod.milliTimestamp();
    while (true) {
        const elapsed: u64 = @intCast(@max(io_mod.milliTimestamp() - started, 0));
        if (elapsed >= timeout_ms) return false;
        if (win32.WaitForSingleObject(handle, @intCast(timeout_ms - elapsed)) != win32.WAIT_OBJECT_0) return false;
        var records: [32]win32.INPUT_RECORD = undefined;
        var count: windows.DWORD = 0;
        if (!win32.ReadConsoleInputW(handle, &records, records.len, &count).toBool()) return false;
        for (records[0..count]) |record| {
            if (isTextRecord(record) and record.Event.KeyEvent.UnicodeChar == '\r') return true;
        }
    }
}

/// Reports whether standard input that is not a console has bytes to read
/// or is a file.
fn streamReadable(handle: std.posix.fd_t) bool {
    return switch (win32.GetFileType(handle)) {
        win32.FILE_TYPE_PIPE => {
            var available: windows.DWORD = 0;
            // A broken pipe reads as end of input, which also ends the wait.
            if (!win32.PeekNamedPipe(handle, null, 0, null, &available, null).toBool()) return true;
            return available > 0;
        },
        win32.FILE_TYPE_DISK => true,
        else => false,
    };
}

fn discardStreamLine() void {
    var buf: [256]u8 = undefined;
    const stdin = std.Io.File.stdin();
    while (true) {
        const n = stdin.readStreaming(io_mod.getIo(), &.{&buf}) catch return;
        if (n == 0) return;
        if (std.mem.findScalar(u8, buf[0..n], '\n') != null) return;
    }
}

/// Collects one line from standard input while the caller polls other work.
/// On a Windows console the input is raw for the poller's lifetime, with the
/// typed text echoed; elsewhere the terminal stays cooked and echoes itself.
pub const LinePoller = struct {
    buffer: [max_line_bytes]u8 = undefined,
    len: usize = 0,
    closed: bool = false,
    raw: ?RawInput = null,
    reader: KeyReader = .{},
    options: LineOptions,

    pub fn init(options: LineOptions) LinePoller {
        var self: LinePoller = .{ .options = options };
        if (comptime builtin.os.tag == .windows) {
            if (consoleMode(stdinHandle()) != null) self.raw = RawInput.enable() catch null;
        }
        return self;
    }

    /// Returns the completed line once Enter arrives, or the collected text
    /// when input ends. The slice stays valid until `clear` or `deinit`.
    pub fn poll(self: *LinePoller) ReadError!?[]const u8 {
        if (self.closed) return null;
        if (self.raw != null) return self.pollConsole();
        return self.pollStream();
    }

    fn pollConsole(self: *LinePoller) ReadError!?[]const u8 {
        var fixed = std.heap.FixedBufferAllocator.init(&self.buffer);
        var editor: LineEditor = .{ .options = self.options };
        editor.line = .{ .items = self.buffer[0..self.len], .capacity = self.buffer.len };
        defer self.len = editor.line.items.len;
        while (true) {
            const byte = switch (try self.reader.next(0)) {
                .byte => |byte| byte,
                .timeout => return null,
                .end => {
                    self.closed = true;
                    return if (editor.line.items.len == 0) null else editor.line.items;
                },
            };
            if (try editor.apply(fixed.allocator(), byte) == .submit) {
                self.closed = true;
                editor.echo("\r\n");
                return editor.line.items;
            }
        }
    }

    fn pollStream(self: *LinePoller) ReadError!?[]const u8 {
        const readable = switch (builtin.os.tag) {
            .windows => streamReadable(stdinHandle()),
            else => blk: {
                var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
                const ready = std.posix.poll(&fds, 0) catch return error.ReadFailed;
                break :blk ready != 0 and (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0;
            },
        };
        if (!readable) return null;

        var chunk: [512]u8 = undefined;
        defer std.crypto.secureZero(u8, &chunk);
        const read_len = std.Io.File.stdin().readStreaming(io_mod.getIo(), &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return error.ReadFailed,
        };
        if (read_len == 0) {
            self.closed = true;
            return if (self.len == 0) null else self.buffer[0..self.len];
        }
        const line_end = std.mem.findScalar(u8, chunk[0..read_len], '\n') orelse read_len;
        if (line_end > self.buffer.len - self.len) return error.TooLong;
        @memcpy(self.buffer[self.len..][0..line_end], chunk[0..line_end]);
        self.len += line_end;
        if (line_end < read_len) {
            self.closed = true;
            if (self.len > 0 and self.buffer[self.len - 1] == '\r') self.len -= 1;
            return self.buffer[0..self.len];
        }
        return null;
    }

    /// Wipes the collected line so a rejected code can be typed again.
    pub fn clear(self: *LinePoller) void {
        std.crypto.secureZero(u8, self.buffer[0..self.len]);
        self.len = 0;
        if (self.raw != null) self.closed = false;
    }

    pub fn deinit(self: *LinePoller) void {
        if (self.raw) |*raw| raw.restore();
        std.crypto.secureZero(u8, &self.buffer);
        self.* = undefined;
    }
};

fn collectWrites(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
    const out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
    try out.appendSlice(std.testing.allocator, bytes);
}

test "line editor masks input, deletes whole characters, and submits a nonempty line" {
    const alloc = std.testing.allocator;
    var echoed: std.ArrayList(u8) = .empty;
    defer echoed.deinit(alloc);
    var editor: LineEditor = .{ .options = .{ .echo = .masked, .write = collectWrites, .write_ctx = &echoed } };
    defer editor.wipe(alloc);

    try std.testing.expectEqual(LineEditor.Step.more, try editor.apply(alloc, '\r'));
    for ("ab") |byte| try std.testing.expectEqual(LineEditor.Step.more, try editor.apply(alloc, byte));
    try std.testing.expectEqual(LineEditor.Step.more, try editor.apply(alloc, 0x7f));
    // Hidden input ignores non-ASCII bytes.
    try std.testing.expectEqual(LineEditor.Step.more, try editor.apply(alloc, 0xc3));
    try std.testing.expectEqual(LineEditor.Step.submit, try editor.apply(alloc, '\r'));
    try std.testing.expectEqualStrings("a", editor.line.items);
    try std.testing.expectEqualStrings("••\x08 \x08", echoed.items);
}

test "line editor echoes visible text and removes a multibyte character at once" {
    const alloc = std.testing.allocator;
    var echoed: std.ArrayList(u8) = .empty;
    defer echoed.deinit(alloc);
    var editor: LineEditor = .{ .options = .{ .echo = .visible, .write = collectWrites, .write_ctx = &echoed } };
    defer editor.wipe(alloc);

    for ("xé") |byte| _ = try editor.apply(alloc, byte);
    _ = try editor.apply(alloc, 8);
    try std.testing.expectEqualStrings("x", editor.line.items);
    try std.testing.expectEqualStrings("xé\x08 \x08", echoed.items);
}

test "line editor reports Ctrl+C as an interrupt and Ctrl+D or Escape as a cancel" {
    const alloc = std.testing.allocator;
    var editor: LineEditor = .{ .options = .{ .echo = .visible, .write = collectWrites, .write_ctx = null } };
    defer editor.wipe(alloc);
    try std.testing.expectError(error.Interrupted, editor.apply(alloc, 3));
    try std.testing.expectError(error.Cancelled, editor.apply(alloc, 4));
    try std.testing.expectError(error.Cancelled, editor.apply(alloc, 0x1b));
}

test "line editor bounds the line length" {
    const alloc = std.testing.allocator;
    var echoed: std.ArrayList(u8) = .empty;
    defer echoed.deinit(alloc);
    var editor: LineEditor = .{ .options = .{ .echo = .masked, .max_bytes = 2, .write = collectWrites, .write_ctx = &echoed } };
    defer editor.wipe(alloc);
    _ = try editor.apply(alloc, 'a');
    _ = try editor.apply(alloc, 'b');
    try std.testing.expectError(error.TooLong, editor.apply(alloc, 'c'));
}

test "key reader decodes UTF-16 surrogate pairs into UTF-8" {
    var reader: KeyReader = .{};
    reader.decode(0xD835);
    try std.testing.expectEqual(@as(usize, 0), reader.pending_end);
    reader.decode(0xDC91);
    try std.testing.expectEqualSlices(u8, "𝒑", reader.pending[0..reader.pending_end]);
    reader.decode(0xDC91);
    try std.testing.expectEqualSlices(u8, "\u{FFFD}", reader.pending[0..reader.pending_end]);
}
