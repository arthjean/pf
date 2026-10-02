const std = @import("std");
const activity_runtime = @import("../core/output/activity_runtime.zig");
const builtin = @import("builtin");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const transcript_runtime = @import("transcript/runtime.zig");
const frame_layout = @import("render_engine/frame_layout.zig");
const cursor_probe = @import("terminal/cursor_probe.zig");
const resize_runtime = @import("resize_runtime.zig");
const ui_terminal = @import("terminal/terminal.zig");
const wasm_terminal = if (builtin.os.tag == .wasi) @import("terminal/wasm_terminal.zig") else struct {};

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const Metrics = types.Metrics;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

const TmuxHistoryClearRunner = *const fn (Allocator, []const []const u8) anyerror!void;
var tmux_history_clear_test_runner: if (builtin.is_test) ?TmuxHistoryClearRunner else void = if (builtin.is_test) null else {};

const supports_test_pty = switch (builtin.os.tag) {
    .linux,
    .macos,
    .freebsd,
    .netbsd,
    .openbsd,
    => true,
    else => false,
};

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;

pub const supports_resize_signal = resize_runtime.supports_resize_signal;
pub const ResizeHandler = if (builtin.os.tag == .wasi or builtin.os.tag == .windows)
    *const fn () callconv(.c) void
else
    std.posix.Sigaction.handler_fn;
pub const ResizeApprovalInterlock = resize_runtime.ResizeApprovalInterlock;
pub const RedrawMode = resize_runtime.RedrawMode;

pub const PollResult = struct {
    readable: bool = false,
    hung_up: bool = false,
    has_error: bool = false,

    pub fn closed(self: PollResult) bool {
        return self.hung_up or self.has_error;
    }
};

pub const CursorPosition = cursor_probe.Position;

pub const AlternateScreenOwner = enum {
    none,
    file_approval,
    full_transcript,
    catalog_menu,
};

/// Placeholder handles until `TerminalState.init` binds the standard streams.
/// Windows resolves console handles only at run time, so its defaults are an
/// invalid handle that fails every call.
const unbound_input: std.Io.File = if (builtin.os.tag == .windows) unbound_windows_file else std.Io.File.stdin();
const unbound_output: std.Io.File = if (builtin.os.tag == .windows) unbound_windows_file else std.Io.File.stdout();
const unbound_windows_file: std.Io.File = if (builtin.os.tag == .windows)
    .{ .handle = std.os.windows.INVALID_HANDLE_VALUE, .flags = .{ .nonblocking = false } }
else
    undefined;

/// Terminal mode state saved by each platform backend.
const SavedModes = switch (builtin.os.tag) {
    .wasi => struct {},
    .windows => struct {
        input_mode: u32 = 0,
        output_mode: u32 = 0,
        input_code_page: u32 = 0,
        output_code_page: u32 = 0,
    },
    else => struct {
        termios: std.posix.termios = undefined,
        old_winch_action: ?std.posix.Sigaction = null,
    },
};

pub const TerminalState = struct {
    input: std.Io.File = unbound_input,
    output: std.Io.File = unbound_output,
    saved: SavedModes = .{},
    raw_enabled: bool = false,
    alternate_screen_owner: AlternateScreenOwner = .none,
    alternate_frame_layout: frame_layout.CommittedLayoutSnapshot = .{},
    alternate_mouse_tracking_active: bool = false,
    signal_handler_installed: bool = false,

    /// Binds the process standard input and output.
    pub fn init() TerminalState {
        return .{ .input = std.Io.File.stdin(), .output = std.Io.File.stdout() };
    }

    pub fn fileApprovalScreenActive(self: TerminalState) bool {
        return self.alternate_screen_owner == .file_approval;
    }

    pub fn fullTranscriptScreenActive(self: TerminalState) bool {
        return self.alternate_screen_owner == .full_transcript;
    }

    pub fn catalogMenuScreenActive(self: TerminalState) bool {
        return self.alternate_screen_owner == .catalog_menu;
    }

    pub fn inputIsTerminal(self: TerminalState) bool {
        return switch (builtin.os.tag) {
            .wasi => true,
            .windows => windowsConsoleMode(self.input) != null,
            else => std.c.isatty(self.input.handle) != 0,
        };
    }

    pub fn ensureInteractive(self: TerminalState) !void {
        if (comptime builtin.os.tag == .wasi) return;
        const output_is_terminal = if (comptime builtin.os.tag == .windows)
            windowsConsoleMode(self.output) != null
        else
            std.c.isatty(self.output.handle) != 0;
        if (!self.inputIsTerminal() or !output_is_terminal) {
            return error.NotATerminal;
        }
    }

    pub fn captureOriginalTermios(self: *TerminalState) !void {
        switch (builtin.os.tag) {
            .wasi => {},
            .windows => {
                const win32 = @import("../core/shared/win32.zig");
                self.saved = .{
                    .input_mode = windowsConsoleMode(self.input) orelse return error.NotATerminal,
                    .output_mode = windowsConsoleMode(self.output) orelse return error.NotATerminal,
                    .input_code_page = win32.GetConsoleCP(),
                    .output_code_page = win32.GetConsoleOutputCP(),
                };
            },
            else => self.saved.termios = try std.posix.tcgetattr(self.input.handle),
        }
    }

    pub fn enableRawMode(self: *TerminalState) !void {
        switch (builtin.os.tag) {
            .wasi => {},
            .windows => try self.enableWindowsRawMode(),
            else => try self.enablePosixRawMode(),
        }
        self.raw_enabled = true;
    }

    fn enablePosixRawMode(self: *TerminalState) !void {
        var raw = self.saved.termios;

        raw.iflag.BRKINT = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INLCR = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.iflag.IXOFF = false;

        raw.cflag.CSIZE = .CS8;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        const vmin_idx = vminIndex();
        const vtime_idx = vtimeIndex();
        if (vmin_idx < raw.cc.len and vtime_idx < raw.cc.len) {
            raw.cc[vmin_idx] = 1;
            raw.cc[vtime_idx] = 0;
        }

        try std.posix.tcsetattr(self.input.handle, .NOW, raw);
    }

    /// Windows raw mode: virtual terminal input and window events in, no line
    /// editing, echo, or Ctrl+C processing, so Ctrl+C arrives as byte 0x03;
    /// virtual terminal processing and UTF-8 out.
    fn enableWindowsRawMode(self: *TerminalState) !void {
        const win32 = @import("../core/shared/win32.zig");
        const input_mode = (self.saved.input_mode &
            ~(win32.ENABLE_LINE_INPUT | win32.ENABLE_ECHO_INPUT | win32.ENABLE_PROCESSED_INPUT)) |
            win32.ENABLE_VIRTUAL_TERMINAL_INPUT | win32.ENABLE_WINDOW_INPUT;
        if (!win32.SetConsoleMode(self.input.handle, input_mode).toBool()) {
            return error.VirtualTerminalUnavailable;
        }
        const output_mode = self.saved.output_mode |
            win32.ENABLE_PROCESSED_OUTPUT | win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        if (!win32.SetConsoleMode(self.output.handle, output_mode).toBool()) {
            _ = win32.SetConsoleMode(self.input.handle, self.saved.input_mode);
            return error.VirtualTerminalUnavailable;
        }
        _ = win32.SetConsoleOutputCP(win32.CP_UTF8);
        _ = win32.SetConsoleCP(win32.CP_UTF8);
    }

    pub fn disableRawMode(self: *TerminalState) void {
        if (!self.raw_enabled) return;
        switch (builtin.os.tag) {
            .wasi => {},
            .windows => self.restoreWindowsConsole(),
            else => std.posix.tcsetattr(self.input.handle, .FLUSH, self.saved.termios) catch {},
        }
        self.raw_enabled = false;
    }

    /// Restores the console modes and code pages saved at startup. Safe to
    /// call from a console control handler thread.
    pub fn restoreWindowsConsole(self: *const TerminalState) void {
        const win32 = @import("../core/shared/win32.zig");
        _ = win32.SetConsoleMode(self.input.handle, self.saved.input_mode);
        _ = win32.SetConsoleMode(self.output.handle, self.saved.output_mode);
        _ = win32.SetConsoleCP(self.saved.input_code_page);
        _ = win32.SetConsoleOutputCP(self.saved.output_code_page);
    }

    pub fn installResizeSignal(self: *TerminalState, handler: ResizeHandler) void {
        if (!supports_resize_signal) return;
        if (comptime builtin.os.tag == .windows) {
            // Resizes arrive as console input records; see `pollInput`.
            windows_console.resize_handler = handler;
            self.signal_handler_installed = true;
            return;
        }

        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };

        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(std.posix.SIG.WINCH, &act, &old);
        self.saved.old_winch_action = old;
        self.signal_handler_installed = true;
    }

    pub fn uninstallResizeSignal(self: *TerminalState) void {
        if (!supports_resize_signal or !self.signal_handler_installed) return;
        if (comptime builtin.os.tag == .windows) {
            windows_console.resize_handler = null;
        } else if (self.saved.old_winch_action) |old| {
            std.posix.sigaction(std.posix.SIG.WINCH, &old, null);
        }
        self.signal_handler_installed = false;
    }

    pub fn queryLayout(self: TerminalState, footer_rows: u16) !Layout {
        return switch (builtin.os.tag) {
            .wasi => wasm_terminal.queryLayout(footer_rows),
            // The console window size belongs to the screen buffer, so it is
            // read from the output handle.
            .windows => ui_terminal.queryLayout(self.output, footer_rows),
            else => ui_terminal.queryLayout(self.input, footer_rows),
        };
    }

    pub fn queryCursorPosition(self: TerminalState) !CursorPosition {
        if (comptime builtin.os.tag == .wasi) {
            // JavaScript hosts provide a fresh terminal surface rather than an
            // existing shell viewport, so there are no launch rows to preserve.
            return .{ .row = 1, .col = 1 };
        }
        try self.output.writeStreamingAll(io_mod.getIo(), "\x1b[6n");

        var buf: [64]u8 = undefined;
        var len: usize = 0;
        const deadline_ms = io_mod.milliTimestamp() + 100;

        while (len < buf.len) {
            const now_ms = io_mod.milliTimestamp();
            if (now_ms >= deadline_ms) break;

            const remaining_ms: i32 = @intCast(deadline_ms - now_ms);
            const poll = try self.pollInput(remaining_ms);
            if (poll.closed() or !poll.readable) break;

            const n = try self.read(buf[len .. len + 1]);
            if (n == 0) break;
            len += n;
            if (cursor_probe.findPositionResponse(buf[0..len]) != null) break;
        }

        return cursor_probe.parsePositionResponse(buf[0..len]);
    }

    pub fn clearTmuxScreenAndHistory(self: *TerminalState, alloc: Allocator) void {
        if (comptime builtin.is_test) return;
        if (io_mod.getenv("TMUX") == null) return;
        const pane = io_mod.getenv("TMUX_PANE") orelse return;

        self.output.writeStreamingAll(io_mod.getIo(), "\x1b[0m\x1b[2J\x1b[3J\x1b[H") catch |err| {
            debug_trace.logf("resize", "tmux_clear_screen_failed pane={s} err={s}", .{ pane, @errorName(err) });
            return;
        };
        waitForTmuxScreenClear(alloc, pane);
        clearTmuxHistoryForPane(alloc, pane);
    }

    pub fn requestResizeCursorPosition(
        self: TerminalState,
        protocol: cursor_probe.Protocol,
    ) !void {
        try self.output.writeStreamingAll(io_mod.getIo(), cursor_probe.queryBytes(protocol));
    }

    pub fn enableThemeNotifications(self: TerminalState) !void {
        try self.output.writeStreamingAll(io_mod.getIo(), ui_terminal.theme_notification_enable_sequence);
    }

    pub fn requestThemeColorScheme(self: TerminalState) !void {
        try self.output.writeStreamingAll(io_mod.getIo(), ui_terminal.theme_color_scheme_query);
    }

    pub fn requestThemeResponseFence(self: TerminalState) !void {
        try self.output.writeStreamingAll(io_mod.getIo(), ui_terminal.theme_response_fence_query);
    }

    pub fn requestThemeBackground(self: TerminalState) !void {
        try self.output.writeStreamingAll(io_mod.getIo(), ui_terminal.theme_background_query_with_fence);
    }

    pub fn read(self: TerminalState, out: []u8) !usize {
        return switch (builtin.os.tag) {
            .wasi => std.Io.File.stdin().readStreaming(io_mod.getIo(), &.{out}),
            .windows => windows_console.read(self.input, out),
            else => std.posix.read(self.input.handle, out),
        };
    }

    pub fn pollInput(self: TerminalState, timeout_ms: i32) !PollResult {
        switch (builtin.os.tag) {
            .wasi => return switch (wasm_terminal.pollInput(timeout_ms)) {
                1 => .{ .readable = true },
                -1 => .{ .hung_up = true },
                else => .{},
            },
            .windows => {
                // An unbound terminal has no input, as POSIX poll reports no
                // POLLIN for an invalid descriptor.
                if (self.input.handle == std.os.windows.INVALID_HANDLE_VALUE) return .{};
                return windows_console.poll(self.input, timeout_ms);
            },
            else => {},
        }
        var fds = [_]std.posix.pollfd{.{
            .fd = self.input.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        _ = try std.posix.poll(&fds, timeout_ms);
        const revents = fds[0].revents;
        return .{
            .readable = (revents & std.posix.POLL.IN) != 0,
            .hung_up = (revents & std.posix.POLL.HUP) != 0,
            .has_error = (revents & std.posix.POLL.ERR) != 0,
        };
    }
};

/// Returns the console mode of `file`, or null when it is not a console.
fn windowsConsoleMode(file: std.Io.File) ?u32 {
    const win32 = @import("../core/shared/win32.zig");
    var mode: u32 = 0;
    if (!win32.GetConsoleMode(file.handle, &mode).toBool()) return null;
    return mode;
}

/// The console input buffer is process-wide, so its decoding state is too.
var windows_console: WindowsConsoleInput = .{};

/// Reads Windows console input as UTF-8. `ReadConsoleW` returns UTF-16 with
/// virtual terminal sequences inline; a code point split across reads keeps
/// its first surrogate here, and bytes that did not fit the caller's buffer
/// wait in `pending`.
const WindowsConsoleInput = struct {
    pending: [128]u8 = undefined,
    pending_start: usize = 0,
    pending_end: usize = 0,
    high_surrogate: ?u16 = null,
    resize_handler: ?ResizeHandler = null,

    fn poll(self: *WindowsConsoleInput, input: std.Io.File, timeout_ms: i32) !PollResult {
        const win32 = @import("../core/shared/win32.zig");
        if (self.pending_end > self.pending_start) return .{ .readable = true };
        const deadline_ms: ?i64 = if (timeout_ms < 0) null else io_mod.milliTimestamp() + timeout_ms;
        while (true) {
            if (try self.skipNonText(input)) return .{ .readable = true };
            // The handle can stay signaled with no record left, for example
            // while the console closes, so the deadline ends the wait itself.
            var wait_ms: u32 = win32.INFINITE;
            if (deadline_ms) |deadline| {
                const remaining = deadline - io_mod.milliTimestamp();
                if (remaining <= 0) return .{};
                wait_ms = @intCast(remaining);
            }
            switch (win32.WaitForSingleObject(input.handle, wait_ms)) {
                win32.WAIT_OBJECT_0 => {},
                win32.WAIT_TIMEOUT => return .{},
                else => return .{ .has_error = true },
            }
        }
    }

    /// Removes leading input records that `ReadConsoleW` would skip without
    /// returning, turning window size changes into resize notifications.
    /// Returns whether a text record is next.
    fn skipNonText(self: *WindowsConsoleInput, input: std.Io.File) !bool {
        const win32 = @import("../core/shared/win32.zig");
        var records: [16]win32.INPUT_RECORD = undefined;
        while (true) {
            var count: u32 = 0;
            if (!win32.PeekConsoleInputW(input.handle, &records, records.len, &count).toBool()) {
                return error.ConsoleInputUnavailable;
            }
            var skip: u32 = 0;
            while (skip < count and !isTextRecord(records[skip])) skip += 1;
            if (skip == 0) return count != 0;
            var removed: u32 = 0;
            if (!win32.ReadConsoleInputW(input.handle, &records, skip, &removed).toBool()) {
                return error.ConsoleInputUnavailable;
            }
            for (records[0..removed]) |record| {
                if (record.EventType == win32.WINDOW_BUFFER_SIZE_EVENT) {
                    if (self.resize_handler) |handler| handler();
                }
            }
            if (skip < count) return true;
        }
    }

    fn isTextRecord(record: @import("../core/shared/win32.zig").INPUT_RECORD) bool {
        const win32 = @import("../core/shared/win32.zig");
        if (record.EventType != win32.KEY_EVENT) return false;
        const key = record.Event.KeyEvent;
        return key.bKeyDown.toBool() and key.UnicodeChar != 0;
    }

    fn read(self: *WindowsConsoleInput, input: std.Io.File, out: []u8) !usize {
        const win32 = @import("../core/shared/win32.zig");
        if (out.len == 0) return 0;
        while (self.pending_end == self.pending_start) {
            var wide: [32]u16 = undefined;
            var count: u32 = 0;
            if (!win32.ReadConsoleW(input.handle, &wide, wide.len, &count, null).toBool()) {
                return error.ConsoleInputUnavailable;
            }
            if (count == 0) return 0;
            self.decode(wide[0..count]);
        }
        const n = @min(out.len, self.pending_end - self.pending_start);
        @memcpy(out[0..n], self.pending[self.pending_start..][0..n]);
        self.pending_start += n;
        if (self.pending_start == self.pending_end) {
            self.pending_start = 0;
            self.pending_end = 0;
        }
        return n;
    }

    /// Appends UTF-8 for `units` to `pending`. An unpaired surrogate becomes
    /// U+FFFD; a trailing high surrogate waits for the next read.
    fn decode(self: *WindowsConsoleInput, units: []const u16) void {
        for (units) |unit| {
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
                continue;
            }
            if (code_point == unit and std.unicode.utf16IsLowSurrogate(unit)) {
                code_point = std.unicode.replacement_character;
            }
            self.append(code_point);
        }
    }

    fn append(self: *WindowsConsoleInput, code_point: u21) void {
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(code_point, &encoded) catch
            std.unicode.utf8Encode(std.unicode.replacement_character, &encoded) catch unreachable;
        @memcpy(self.pending[self.pending_end..][0..len], encoded[0..len]);
        self.pending_end += len;
    }
};

fn clearTmuxHistoryForPane(alloc: Allocator, pane: []const u8) void {
    runTmuxHistoryClear(alloc, pane) catch |err| {
        debug_trace.logf(
            "resize",
            "tmux_clear_history_failed pane={s} err={s}",
            .{ pane, @errorName(err) },
        );
        return;
    };
    debug_trace.logf("resize", "tmux_clear_history_complete pane={s}", .{pane});
}

fn waitForTmuxScreenClear(alloc: Allocator, pane: []const u8) void {
    for (0..5) |attempt| {
        const clear = tmuxScreenIsClear(alloc, pane) catch |err| {
            debug_trace.logf("resize", "tmux_clear_screen_check_failed pane={s} err={s}", .{ pane, @errorName(err) });
            return;
        };
        if (clear) return;
        if (attempt + 1 < 5) io_mod.sleep(5 * std.time.ns_per_ms);
    }
    debug_trace.logf("resize", "tmux_clear_screen_timeout pane={s}", .{pane});
}

fn tmuxScreenIsClear(alloc: Allocator, pane: []const u8) !bool {
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "tmux", "capture-pane", "-p", "-t", pane },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TmuxCapturePaneFailed;
    return std.mem.trim(u8, result.stdout, " \t\r\n").len == 0;
}

fn runTmuxHistoryClear(alloc: Allocator, pane: []const u8) !void {
    // clear-history also dismisses tmux pane modes. In particular, choose-tree
    // zooms a split pane and triggers our resize reset while the chooser is open.
    // Decide inside tmux, not with a separate client-side mode query. -C runs
    // tmux commands, not a shell; only tmux's own pane_id enters command text.
    // Keep the explicit target: nested commands need not inherit run-shell's -t.
    const argv = [_][]const u8{
        "tmux",                                          "run-shell", "-C", "-t", pane,
        "#{?pane_in_mode,,clear-history -t #{pane_id}}",
    };
    if (comptime builtin.is_test) {
        if (tmux_history_clear_test_runner) |runner| return runner(alloc, &argv);
    }
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &argv,
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TmuxClearHistoryFailed;
}

var tmux_history_clear_test_calls: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

fn failTmuxHistoryClearForTest(_: Allocator, _: []const []const u8) !void {
    tmux_history_clear_test_calls += 1;
    return error.TestTmuxHistoryClearFailure;
}

test "tmux history clear failure does not escape the reset boundary" {
    tmux_history_clear_test_calls = 0;
    tmux_history_clear_test_runner = failTmuxHistoryClearForTest;
    defer tmux_history_clear_test_runner = null;

    clearTmuxHistoryForPane(std.testing.allocator, "%1");

    try std.testing.expectEqual(@as(usize, 1), tmux_history_clear_test_calls);
}

fn expectModeSafeTmuxHistoryClearForTest(_: Allocator, argv: []const []const u8) !void {
    tmux_history_clear_test_calls += 1;
    const expected = [_][]const u8{
        "tmux",                                          "run-shell", "-C", "-t", "%42",
        "#{?pane_in_mode,,clear-history -t #{pane_id}}",
    };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, actual| {
        try std.testing.expectEqualStrings(want, actual);
    }
}

test "tmux history clear preserves pane modes with a server-owned target" {
    tmux_history_clear_test_calls = 0;
    tmux_history_clear_test_runner = expectModeSafeTmuxHistoryClearForTest;
    defer tmux_history_clear_test_runner = null;

    try runTmuxHistoryClear(std.testing.allocator, "%42");

    try std.testing.expectEqual(@as(usize, 1), tmux_history_clear_test_calls);
}

pub fn detectSyncUpdatesEnabled(_: Allocator) bool {
    const override = io_mod.getenv("PF_SYNC_UPDATES");

    const fallback_override = if (override == null)
        io_mod.getenv("FLASH_SYNC_UPDATES")
    else
        null;

    const term = io_mod.getenv("TERM");

    return syncUpdatesEnabledForValues(override orelse fallback_override, term);
}

pub fn detectHistoryResetUsesRis(_: Allocator) bool {
    return historyResetUsesRisForValues(
        io_mod.getenv("TERM_PROGRAM"),
        io_mod.getenv("TMUX"),
    );
}

pub fn applyToolLifecycle(
    alloc: Allocator,
    shell: anytype,
    event: types.ToolLifecycleEvent,
) !?types.ToolActivityKind {
    return shell.applyToolLifecycle(alloc, event);
}

pub fn applyToolLifecyclePreservingNormalBufferAnchor(
    alloc: Allocator,
    shell: anytype,
    event: types.ToolLifecycleEvent,
) !?types.ToolActivityKind {
    const Shell = @TypeOf(shell.*);
    if (comptime @hasDecl(Shell, "applyToolLifecyclePreservingNormalBufferAnchor")) {
        return shell.applyToolLifecyclePreservingNormalBufferAnchor(alloc, event);
    }
    return shell.applyToolLifecycle(alloc, event);
}

pub fn finishLifecycleBatch(
    alloc: Allocator,
    shell: anytype,
) !void {
    return shell.finishLifecycleBatch(alloc);
}

pub fn activityProjection(
    shell: anytype,
) activity_runtime.ActivityProjection {
    return shell.activityProjection();
}

pub fn focusedToolEntryId(shell: anytype) ?u32 {
    return shell.focusedToolEntryId();
}

pub fn focusedToolActivityKind(
    shell: anytype,
) ?types.ToolActivityKind {
    return shell.focusedToolActivityKind();
}

pub fn activeToolActivityCount(shell: anytype) usize {
    return shell.activeToolActivityCount();
}

pub fn presentActiveToolCancellation(
    alloc: Allocator,
    shell: anytype,
) !bool {
    const Shell = @TypeOf(shell.*);
    if (comptime !@hasDecl(Shell, "presentActiveToolCancellation")) {
        return false;
    }
    return shell.presentActiveToolCancellation(alloc);
}

pub fn writeTurnCancellation(
    alloc: Allocator,
    shell: anytype,
    metrics: *Metrics,
    record: bool,
) !void {
    const Shell = @TypeOf(shell.*);
    if (comptime !@hasDecl(Shell, "writeTurnCancellation")) return;
    try shell.writeTurnCancellation(alloc, metrics, record);
}

pub fn requestRedraw(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    mode: RedrawMode,
) !void {
    return resize_runtime.requestRedraw(shell, metrics, mode);
}

pub fn collectResizeFacts(
    terminal: TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    probe: *cursor_probe.Parser,
    resize_interlock: *ResizeApprovalInterlock,
    footer_rows: u16,
    debounce_ms: i64,
    cursor_probe_allowed: bool,
) !void {
    return resize_runtime.collectResizeFacts(
        terminal,
        shell,
        metrics,
        probe,
        resize_interlock,
        footer_rows,
        debounce_ms,
        cursor_probe_allowed,
    );
}

pub fn admitResizeSignal(
    shell: *TranscriptRuntime,
    resize_interlock: *ResizeApprovalInterlock,
    now_ms: i64,
    debounce_ms: i64,
    source: []const u8,
) bool {
    return resize_runtime.admitResizeSignal(
        shell,
        resize_interlock,
        now_ms,
        debounce_ms,
        source,
    );
}

pub fn resizeLifecycleIdle(shell: anytype) bool {
    return resize_runtime.lifecycleIdle(shell);
}

pub fn resizeBlocksFrameCommit(shell: anytype) bool {
    return resize_runtime.blocksFrameCommit(shell);
}

pub const ResizeFrameCommit = resize_runtime.FrameCommit;

pub fn pendingResizeFrameCommit(shell: anytype, resize_reason: bool) ResizeFrameCommit {
    return resize_runtime.pendingFrameCommit(shell, resize_reason);
}

pub fn acknowledgeResizeFrameCommit(shell: anytype, commit: ResizeFrameCommit) void {
    resize_runtime.acknowledgeFrameCommit(shell, commit);
}

pub fn completeResizeCursorProbe(
    shell: *TranscriptRuntime,
    position: CursorPosition,
) void {
    resize_runtime.completeResizeCursorProbe(shell, position);
}

pub fn suspendResizeCursorProbeForPaste(probe: *cursor_probe.Parser) void {
    return resize_runtime.suspendResizeCursorProbeForPaste(probe);
}

pub fn resumeResizeCursorProbeAfterPaste(probe: *cursor_probe.Parser, now_ms: i64) void {
    return resize_runtime.resumeResizeCursorProbeAfterPaste(probe, now_ms);
}

pub fn applyResizeWithLayout(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    new_layout: Layout,
    settled: bool,
) !void {
    return resize_runtime.applyResizeWithLayout(shell, metrics, new_layout, settled);
}

fn syncUpdatesEnabledForValues(override: ?[]const u8, term: ?[]const u8) bool {
    if (override) |value| {
        if (std.ascii.eqlIgnoreCase(value, "0") or
            std.ascii.eqlIgnoreCase(value, "false") or
            std.ascii.eqlIgnoreCase(value, "off"))
        {
            return false;
        }
        if (std.ascii.eqlIgnoreCase(value, "1") or
            std.ascii.eqlIgnoreCase(value, "true") or
            std.ascii.eqlIgnoreCase(value, "on"))
        {
            return true;
        }
    }

    if (term) |value| {
        if (std.mem.eql(u8, value, "dumb")) return false;
    }

    return true;
}

fn historyResetUsesRisForValues(term_program: ?[]const u8, tmux: ?[]const u8) bool {
    return tmux == null and
        term_program != null and
        std.mem.eql(u8, term_program.?, "Apple_Terminal");
}

fn vminIndex() usize {
    return switch (builtin.os.tag) {
        .linux => 6,
        .macos, .ios, .tvos, .watchos, .visionos => 16,
        .freebsd, .netbsd, .dragonfly, .openbsd => 16,
        else => 16,
    };
}

fn vtimeIndex() usize {
    return switch (builtin.os.tag) {
        .linux => 5,
        .macos, .ios, .tvos, .watchos, .visionos => 17,
        .freebsd, .netbsd, .dragonfly, .openbsd => 17,
        else => 17,
    };
}

test "sync updates override beats dumb term" {
    try std.testing.expect(syncUpdatesEnabledForValues("on", "dumb"));
    try std.testing.expect(!syncUpdatesEnabledForValues("off", "xterm-256color"));
    try std.testing.expect(!syncUpdatesEnabledForValues(null, "dumb"));
}

test "direct Apple Terminal uses RIS for terminal history resets" {
    try std.testing.expect(historyResetUsesRisForValues("Apple_Terminal", null));
    try std.testing.expect(!historyResetUsesRisForValues("Apple_Terminal", "/tmp/tmux-1/default,1,0"));
    try std.testing.expect(!historyResetUsesRisForValues("Ghostty", null));
}

const TestPty = struct {
    master: std.posix.fd_t,
    slave: std.posix.fd_t,

    fn open() !TestPty {
        const flags = std.posix.O{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        };
        const flags_int: c_int = @bitCast(flags);
        const master_fd = posix_openpt(flags_int);
        if (master_fd < 0) return error.PtyUnavailable;
        errdefer closeTestFd(master_fd);

        if (grantpt(master_fd) != 0) return error.PtyUnavailable;
        if (unlockpt(master_fd) != 0) return error.PtyUnavailable;
        const slave_name = ptsname(master_fd) orelse return error.PtyUnavailable;
        const slave_fd = try std.posix.openatZ(std.posix.AT.FDCWD, slave_name, flags, 0);
        errdefer closeTestFd(slave_fd);

        return .{
            .master = master_fd,
            .slave = slave_fd,
        };
    }

    fn close(self: TestPty) void {
        closeTestFd(self.master);
        closeTestFd(self.slave);
    }
};

fn closeTestFd(fd: std.posix.fd_t) void {
    (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).close(io_mod.getIo());
}

test "enableRawMode preserves already queued input" {
    if (!supports_test_pty) return error.SkipZigTest;

    const pty = try TestPty.open();
    defer pty.close();

    var original = try std.posix.tcgetattr(pty.slave);
    original.lflag.ECHO = false;
    original.lflag.ICANON = false;
    original.lflag.ISIG = false;
    const vmin_idx = vminIndex();
    const vtime_idx = vtimeIndex();
    if (vmin_idx < original.cc.len and vtime_idx < original.cc.len) {
        original.cc[vmin_idx] = 1;
        original.cc[vtime_idx] = 0;
    }
    try std.posix.tcsetattr(pty.slave, .NOW, original);

    var terminal = TerminalState{ .input = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } } };
    try terminal.captureOriginalTermios();

    const queued = [_]u8{3};
    try (std.Io.File{
        .handle = pty.master,
        .flags = .{ .nonblocking = false },
    }).writeStreamingAll(io_mod.getIo(), &queued);

    try terminal.enableRawMode();
    defer terminal.disableRawMode();

    var fds = [_]std.posix.pollfd{.{
        .fd = pty.slave,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 100));
    try std.testing.expect((fds[0].revents & std.posix.POLL.IN) != 0);

    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.read(pty.slave, &buf));
    try std.testing.expectEqual(@as(u8, 3), buf[0]);
}

test "enableRawMode preserves carriage return input" {
    if (!supports_test_pty) return error.SkipZigTest;

    const pty = try TestPty.open();
    defer pty.close();

    var original = try std.posix.tcgetattr(pty.slave);
    original.iflag.IGNCR = true;
    original.iflag.ICRNL = true;
    original.iflag.INLCR = true;
    try std.posix.tcsetattr(pty.slave, .NOW, original);

    var terminal = TerminalState{ .input = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } } };
    try terminal.captureOriginalTermios();
    try terminal.enableRawMode();
    defer terminal.disableRawMode();

    const raw = try std.posix.tcgetattr(pty.slave);
    try std.testing.expect(!raw.iflag.IGNCR);
    try std.testing.expect(!raw.iflag.ICRNL);
    try std.testing.expect(!raw.iflag.INLCR);

    const enter = [_]u8{'\r'};
    try (std.Io.File{
        .handle = pty.master,
        .flags = .{ .nonblocking = false },
    }).writeStreamingAll(io_mod.getIo(), &enter);

    var fds = [_]std.posix.pollfd{.{
        .fd = pty.slave,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 100));
    try std.testing.expect((fds[0].revents & std.posix.POLL.IN) != 0);

    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.read(pty.slave, &buf));
    try std.testing.expectEqual(@as(u8, '\r'), buf[0]);
}

test "reconstructive paint re-emits a full transcript in order" {
    try @import("resize_tests.zig").testReconstructiveFullTranscriptReplay();
}

test {
    // Pull adjacent UI test files into the test binary. Declaring
    // imports inside a test block keeps them out of release builds
    // (`zig build`) but still lets `zig build test` discover and run
    // their test blocks.
    _ = @import("render_engine/terminal_diff.zig");
    _ = @import("../core/terminal/engine.zig");
    _ = @import("resize_tests.zig");
    _ = @import("../core/cli/cli_replay.zig");
}
