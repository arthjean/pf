//! Windows pseudo console host. Runs one child behind ConPTY and captures its
//! output on a dedicated reader thread, so `ClosePseudoConsole` never blocks
//! on an undrained output pipe. Reference only from code selected at comptime
//! for Windows; the unit test skips elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const win32 = @import("../shared/win32.zig");

const Allocator = std.mem.Allocator;

pub const Size = struct {
    cols: u16,
    rows: u16,

    fn coord(self: Size) windows.COORD {
        return .{ .X = @intCast(self.cols), .Y = @intCast(self.rows) };
    }
};

pub const SpawnError = error{
    PipeCreateFailed,
    PseudoConsoleCreateFailed,
    AttributeListFailed,
    ProcessCreateFailed,
    ReaderStartFailed,
    InvalidCommandLine,
    OutOfMemory,
};

/// One child process attached to a pseudo console. Heap-allocated because the
/// reader thread holds its address until `finish` joins it.
pub const PseudoConsole = struct {
    alloc: Allocator,
    io: std.Io,
    hpc: ?win32.HPCON,
    input_write: ?windows.HANDLE,
    output_read: windows.HANDLE,
    process: windows.HANDLE,
    thread: windows.HANDLE,
    reader: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    /// Captured child output, guarded by `mutex` until `finish` returns.
    output: std.ArrayList(u8) = .empty,
    reader_done: std.atomic.Value(bool) = .init(false),

    /// Starts `command_line` (UTF-8, Windows quoting rules) behind a new
    /// pseudo console of `size`. The child inherits this process's
    /// environment and working directory. Caller owns the result and must
    /// call `deinit`.
    pub fn spawn(alloc: Allocator, io: std.Io, command_line: []const u8, size: Size) SpawnError!*PseudoConsole {
        const command_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, command_line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCommandLine,
        };
        defer alloc.free(command_w);

        // ConPTY reads input_read and writes output_write; this side keeps the
        // opposite ends.
        var input_read: windows.HANDLE = undefined;
        var input_write: windows.HANDLE = undefined;
        if (win32.CreatePipe(&input_read, &input_write, null, 0) == .FALSE) return error.PipeCreateFailed;
        defer windows.CloseHandle(input_read);
        errdefer windows.CloseHandle(input_write);
        var output_read: windows.HANDLE = undefined;
        var output_write: windows.HANDLE = undefined;
        if (win32.CreatePipe(&output_read, &output_write, null, 0) == .FALSE) return error.PipeCreateFailed;
        defer windows.CloseHandle(output_write);
        errdefer windows.CloseHandle(output_read);

        var hpc: win32.HPCON = undefined;
        if (win32.CreatePseudoConsole(size.coord(), input_read, output_write, 0, &hpc) < 0) {
            return error.PseudoConsoleCreateFailed;
        }
        errdefer win32.ClosePseudoConsole(hpc);

        var attribute_size: usize = 0;
        _ = win32.InitializeProcThreadAttributeList(null, 1, 0, &attribute_size);
        const attribute_buf = try alloc.alignedAlloc(u8, .of(usize), attribute_size);
        defer alloc.free(attribute_buf);
        const attributes: *anyopaque = attribute_buf.ptr;
        if (win32.InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size) == .FALSE) {
            return error.AttributeListFailed;
        }
        defer win32.DeleteProcThreadAttributeList(attributes);
        if (win32.UpdateProcThreadAttribute(
            attributes,
            0,
            win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            hpc,
            @sizeOf(win32.HPCON),
            null,
            null,
        ) == .FALSE) return error.AttributeListFailed;

        var startup = std.mem.zeroes(win32.STARTUPINFOEXW);
        startup.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);
        // Empty standard handles keep a parent with redirected handles from
        // leaking them into the child instead of the pseudo console's.
        startup.StartupInfo.dwFlags = windows.STARTF_USESTDHANDLES;
        startup.lpAttributeList = attributes;
        var info: windows.PROCESS.INFORMATION = undefined;
        if (windows.kernel32.CreateProcessW(
            null,
            command_w.ptr,
            null,
            null,
            .FALSE,
            .{ .extended_startupinfo_present = true, .create_unicode_environment = true },
            null,
            null,
            &startup.StartupInfo,
            &info,
        ) == .FALSE) return error.ProcessCreateFailed;
        errdefer {
            _ = win32.TerminateProcess(info.hProcess, 1);
            windows.CloseHandle(info.hThread);
            windows.CloseHandle(info.hProcess);
        }

        const self = try alloc.create(PseudoConsole);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .hpc = hpc,
            .input_write = input_write,
            .output_read = output_read,
            .process = info.hProcess,
            .thread = info.hThread,
        };
        self.reader = std.Thread.spawn(.{}, readOutput, .{self}) catch return error.ReaderStartFailed;
        return self;
    }

    fn readOutput(self: *PseudoConsole) void {
        defer self.reader_done.store(true, .release);
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            var read_len: windows.DWORD = 0;
            if (win32.ReadFile(self.output_read, &buf, buf.len, &read_len, null) == .FALSE) return;
            if (read_len == 0) continue;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.output.appendSlice(self.alloc, buf[0..read_len]) catch return;
        }
    }

    /// Writes all bytes to the child's console input.
    pub fn write(self: *PseudoConsole, bytes: []const u8) error{WriteFailed}!void {
        const handle = self.input_write orelse return error.WriteFailed;
        var rest = bytes;
        while (rest.len > 0) {
            const chunk: windows.DWORD = @intCast(@min(rest.len, std.math.maxInt(windows.DWORD)));
            var written: windows.DWORD = 0;
            if (win32.WriteFile(handle, rest.ptr, chunk, &written, null) == .FALSE) return error.WriteFailed;
            rest = rest[written..];
        }
    }

    pub fn resize(self: *PseudoConsole, size: Size) error{ResizeFailed}!void {
        const hpc = self.hpc orelse return error.ResizeFailed;
        if (win32.ResizePseudoConsole(hpc, size.coord()) < 0) return error.ResizeFailed;
    }

    /// Bytes captured so far.
    pub fn outputLen(self: *PseudoConsole) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.output.items.len;
    }

    /// Returns the offset just past the first `needle` at or after `start`.
    pub fn findFrom(self: *PseudoConsole, start: usize, needle: []const u8) ?usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const items = self.output.items;
        if (start >= items.len) return null;
        const index = std.mem.find(u8, items[start..], needle) orelse return null;
        return start + index + needle.len;
    }

    /// Returns the child's exit code once it exits within `timeout_ms`, or
    /// null while it is still running.
    pub fn waitExit(self: *PseudoConsole, timeout_ms: u32) ?u32 {
        if (win32.WaitForSingleObject(self.process, timeout_ms) != win32.WAIT_OBJECT_0) return null;
        var code: windows.DWORD = 0;
        if (win32.GetExitCodeProcess(self.process, &code) == .FALSE) return 1;
        return code;
    }

    pub fn terminate(self: *PseudoConsole, code: u32) void {
        _ = win32.TerminateProcess(self.process, code);
    }

    /// Stops input and closes the pseudo console, which sends the attached
    /// child `CTRL_CLOSE_EVENT`. The reader keeps draining output.
    pub fn closeConsole(self: *PseudoConsole) void {
        if (self.input_write) |handle| {
            windows.CloseHandle(handle);
            self.input_write = null;
        }
        if (self.hpc) |hpc| {
            win32.ClosePseudoConsole(hpc);
            self.hpc = null;
        }
    }

    /// Closes the pseudo console and joins the reader after it drains the
    /// remaining output. After it returns, `output.items` holds the complete
    /// capture and needs no lock.
    pub fn finish(self: *PseudoConsole) void {
        self.closeConsole();
        if (self.reader) |thread| {
            thread.join();
            self.reader = null;
        }
    }

    pub fn deinit(self: *PseudoConsole) void {
        if (self.waitExit(0) == null) self.terminate(1);
        self.finish();
        windows.CloseHandle(self.output_read);
        windows.CloseHandle(self.thread);
        windows.CloseHandle(self.process);
        self.output.deinit(self.alloc);
        self.alloc.destroy(self);
    }
};

test "pseudo console captures a child's output" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const console = try PseudoConsole.spawn(std.testing.allocator, std.testing.io, "cmd.exe /c echo pf-conpty", .{ .cols = 80, .rows = 25 });
    defer console.deinit();
    try std.testing.expectEqual(@as(?u32, 0), console.waitExit(10_000));
    console.finish();
    try std.testing.expect(std.mem.find(u8, console.output.items, "pf-conpty") != null);
}
