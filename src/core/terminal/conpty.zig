//! Windows pseudo consoles. `PseudoConsole` runs one child behind ConPTY and
//! captures its output on a dedicated reader thread, so `ClosePseudoConsole`
//! never blocks on an undrained output pipe; test drivers use it.
//! `HostedConsole` runs a terminal session's shell in a Job Object and hands
//! the output pipe to the terminal host's own reader. Reference only from
//! code selected at comptime for Windows; the unit tests skip elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const win32 = @import("../shared/win32.zig");
const process_job = @import("../shared/process_job.zig");

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
    ProcessJobUnavailable,
    OutOfMemory,
};

/// The handles of a child just started behind a new pseudo console. The
/// caller owns every handle.
const Attached = struct {
    hpc: win32.HPCON,
    input_write: windows.HANDLE,
    output_read: windows.HANDLE,
    info: windows.PROCESS.INFORMATION,
};

/// Starts `command_line` behind a new pseudo console of `size`, in `cwd`
/// when given, suspended when asked. The child inherits this process's
/// environment.
fn attach(
    alloc: Allocator,
    command_line: []const u8,
    cwd: ?[]const u8,
    size: Size,
    suspended: bool,
) SpawnError!Attached {
    const command_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, command_line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommandLine,
    };
    defer alloc.free(command_w);
    const cwd_w = if (cwd) |path| std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommandLine,
    } else null;
    defer if (cwd_w) |path| alloc.free(path);

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
        .{
            .extended_startupinfo_present = true,
            .create_unicode_environment = true,
            .create_suspended = suspended,
        },
        null,
        if (cwd_w) |path| path.ptr else null,
        &startup.StartupInfo,
        &info,
    ) == .FALSE) return error.ProcessCreateFailed;
    return .{ .hpc = hpc, .input_write = input_write, .output_read = output_read, .info = info };
}

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
        const attached = try attach(alloc, command_line, null, size, false);
        const hpc = attached.hpc;
        const input_write = attached.input_write;
        const output_read = attached.output_read;
        const info = attached.info;
        errdefer {
            _ = win32.TerminateProcess(info.hProcess, 1);
            windows.CloseHandle(info.hThread);
            windows.CloseHandle(info.hProcess);
            win32.ClosePseudoConsole(hpc);
            windows.CloseHandle(input_write);
            windows.CloseHandle(output_read);
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

/// The exit code `HostedConsole.terminate` gives every process in the job,
/// so the exit path can tell a kill by pf from the shell's own exit status.
pub const terminated_exit_code: u32 = 0x7066_0009;

/// A terminal session's shell behind a pseudo console, inside a Job Object
/// that kills the shell and everything it starts when the job's last handle
/// closes, which also happens when the terminal host process dies. The host
/// reads `output` on its own thread. Input, resize, and close may run on
/// different threads; `mutex` orders them against the pseudo console's
/// teardown.
pub const HostedConsole = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    hpc: ?win32.HPCON,
    input: ?windows.HANDLE,
    output: windows.HANDLE,
    process: windows.HANDLE,
    thread: ?windows.HANDLE,
    pid: u32,
    job: process_job.Job,

    /// Starts `command_line` suspended behind a pseudo console of `size` in
    /// `cwd`, already inside its job, so nothing it starts can escape the
    /// job. Call `resumeChild` to let it run. Caller owns the result and
    /// must call `deinit`.
    pub fn start(
        alloc: Allocator,
        io: std.Io,
        command_line: []const u8,
        cwd: []const u8,
        size: Size,
    ) SpawnError!HostedConsole {
        var job = process_job.Job.create() catch return error.ProcessJobUnavailable;
        errdefer job.close();
        const attached = try attach(alloc, command_line, cwd, size, true);
        errdefer {
            _ = win32.TerminateProcess(attached.info.hProcess, 1);
            windows.CloseHandle(attached.info.hThread);
            windows.CloseHandle(attached.info.hProcess);
            win32.ClosePseudoConsole(attached.hpc);
            windows.CloseHandle(attached.input_write);
            windows.CloseHandle(attached.output_read);
        }
        if (win32.AssignProcessToJobObject(job.handle, attached.info.hProcess) == .FALSE) {
            return error.ProcessJobUnavailable;
        }
        return .{
            .io = io,
            .hpc = attached.hpc,
            .input = attached.input_write,
            .output = attached.output_read,
            .process = attached.info.hProcess,
            .thread = attached.info.hThread,
            .pid = attached.info.dwProcessId,
            .job = job,
        };
    }

    pub fn resumeChild(self: *HostedConsole) error{ProcessResumeFailed}!void {
        const thread = self.thread orelse return;
        defer {
            windows.CloseHandle(thread);
            self.thread = null;
        }
        if (win32.ResumeThread(thread) == std.math.maxInt(windows.DWORD)) return error.ProcessResumeFailed;
    }

    /// Writes all of `bytes` to the console input.
    pub fn write(self: *HostedConsole, bytes: []const u8) error{WriteFailed}!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const handle = self.input orelse return error.WriteFailed;
        var rest = bytes;
        while (rest.len > 0) {
            const chunk: windows.DWORD = @intCast(@min(rest.len, std.math.maxInt(windows.DWORD)));
            var written: windows.DWORD = 0;
            if (win32.WriteFile(handle, rest.ptr, chunk, &written, null) == .FALSE) return error.WriteFailed;
            rest = rest[written..];
        }
    }

    pub fn resize(self: *HostedConsole, size: Size) error{ResizeFailed}!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const hpc = self.hpc orelse return error.ResizeFailed;
        if (win32.ResizePseudoConsole(hpc, size.coord()) < 0) return error.ResizeFailed;
    }

    /// Closes the console input and the pseudo console, which sends every
    /// attached process `CTRL_CLOSE_EVENT`, the console's hangup, and ends
    /// the output pipe once the pseudo console drains. The output reader
    /// must keep draining while this runs.
    pub fn closeConsole(self: *HostedConsole) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.input) |handle| {
            windows.CloseHandle(handle);
            self.input = null;
        }
        if (self.hpc) |hpc| {
            win32.ClosePseudoConsole(hpc);
            self.hpc = null;
        }
    }

    /// Kills every process in the job with `terminated_exit_code`.
    pub fn terminate(self: *HostedConsole) void {
        _ = win32.TerminateJobObject(self.job.handle, terminated_exit_code);
    }

    /// Returns the shell's exit code once it exits within `timeout_ms`, or
    /// null while it is still running.
    pub fn waitExit(self: *HostedConsole, timeout_ms: u32) ?u32 {
        if (win32.WaitForSingleObject(self.process, timeout_ms) != win32.WAIT_OBJECT_0) return null;
        var code: windows.DWORD = 0;
        if (win32.GetExitCodeProcess(self.process, &code) == .FALSE) return terminated_exit_code;
        return code;
    }

    /// Kills whatever still runs in the job and releases every handle. The
    /// output reader must have stopped or must stop when the pseudo console
    /// closes.
    pub fn deinit(self: *HostedConsole) void {
        self.terminate();
        if (self.thread) |thread| windows.CloseHandle(thread);
        self.closeConsole();
        windows.CloseHandle(self.output);
        windows.CloseHandle(self.process);
        self.job.close();
        self.* = undefined;
    }
};

/// Appends `arg` to a Windows command line so `CommandLineToArgvW` and the
/// C runtime read it back unchanged.
pub fn appendCommandLineArg(alloc: Allocator, out: *std.ArrayList(u8), arg: []const u8) Allocator.Error!void {
    if (out.items.len != 0) try out.append(alloc, ' ');
    const needs_quotes = arg.len == 0 or std.mem.findAny(u8, arg, " \t\n\x0b\"") != null;
    if (!needs_quotes) return out.appendSlice(alloc, arg);
    try out.append(alloc, '"');
    var backslashes: usize = 0;
    for (arg) |byte| {
        if (byte == '\\') {
            backslashes += 1;
            continue;
        }
        // Backslashes double only before a quote.
        const count = if (byte == '"') backslashes * 2 + 1 else backslashes;
        try out.appendNTimes(alloc, '\\', count);
        backslashes = 0;
        try out.append(alloc, byte);
    }
    try out.appendNTimes(alloc, '\\', backslashes * 2);
    try out.append(alloc, '"');
}

test "command line arguments quote only when Windows needs it" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for ([_][]const u8{ "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "", "a\"b", "end\\", ". 'C:/x y/boot'" }) |arg| {
        try appendCommandLineArg(alloc, &out, arg);
    }
    try std.testing.expectEqualStrings(
        "\"C:\\Program Files\\Git\\bin\\bash.exe\" --login \"\" \"a\\\"b\" end\\ \". 'C:/x y/boot'\"",
        out.items,
    );
}

test "hosted console runs its shell suspended in a job and kills the whole job" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(cwd);
    var console = try HostedConsole.start(alloc, std.testing.io, "cmd.exe /d /c cd & ping -n 30 127.0.0.1 >nul", cwd, .{ .cols = 80, .rows = 25 });
    var console_live = true;
    defer if (console_live) console.deinit();

    // Drain as the host's reader does, so closing never blocks on output.
    const Drain = struct {
        fn run(handle: windows.HANDLE, out: *std.ArrayList(u8)) void {
            var buf: [4096]u8 = undefined;
            while (true) {
                var read_len: windows.DWORD = 0;
                if (win32.ReadFile(handle, &buf, buf.len, &read_len, null) == .FALSE) return;
                out.appendSlice(std.testing.allocator, buf[0..read_len]) catch return;
            }
        }
    };
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(alloc);
    const reader = try std.Thread.spawn(.{}, Drain.run, .{ console.output, &captured });
    var reader_live = true;
    defer if (reader_live) {
        console.closeConsole();
        reader.join();
    };

    try std.testing.expectEqual(@as(?u32, null), console.waitExit(100));
    try console.resumeChild();
    try std.testing.expectEqual(@as(?u32, null), console.waitExit(300));
    try std.testing.expect(console.job.activeProcessCount() >= 2);
    try console.resize(.{ .cols = 100, .rows = 30 });
    console.terminate();
    try std.testing.expectEqual(@as(?u32, terminated_exit_code), console.waitExit(5_000));
    try std.testing.expectEqual(@as(u32, 0), console.job.activeProcessCount());

    console.closeConsole();
    reader.join();
    reader_live = false;
    console.deinit();
    console_live = false;
    try std.testing.expect(std.mem.find(u8, captured.items, std.fs.path.basename(cwd)) != null);
}

test "pseudo console captures a child's output" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const console = try PseudoConsole.spawn(std.testing.allocator, std.testing.io, "cmd.exe /c echo pf-conpty", .{ .cols = 80, .rows = 25 });
    defer console.deinit();
    try std.testing.expectEqual(@as(?u32, 0), console.waitExit(10_000));
    console.finish();
    try std.testing.expect(std.mem.find(u8, console.output.items, "pf-conpty") != null);
}
