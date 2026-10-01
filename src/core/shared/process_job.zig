//! Windows Job Objects that contain a spawned process tree. A job created
//! here kills every process in it when its last handle closes, so a tree
//! stops on timeout, on cancellation, and when pf exits, including when pf
//! itself is terminated. Reference this file only from code selected at
//! comptime for Windows.

const std = @import("std");
const windows = std.os.windows;
const win32 = @import("win32.zig");

pub const Error = error{ProcessJobUnavailable};

pub const Job = struct {
    handle: windows.HANDLE,

    /// Creates a job that kills its processes when its last handle closes.
    /// The handle is not inheritable, so only pf holds it.
    pub fn create() Error!Job {
        const handle = win32.CreateJobObjectW(null, null) orelse return error.ProcessJobUnavailable;
        errdefer windows.CloseHandle(handle);
        var limits: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
        limits.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (win32.SetInformationJobObject(
            handle,
            win32.JobObjectExtendedLimitInformation,
            &limits,
            @sizeOf(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        ) == .FALSE) return error.ProcessJobUnavailable;
        return .{ .handle = handle };
    }

    /// Closes the job, which kills every process still in it.
    pub fn close(self: *Job) void {
        windows.CloseHandle(self.handle);
        self.* = undefined;
    }

    /// Kills every process in the job. Already-exited processes are ignored.
    pub fn terminate(self: Job) void {
        _ = win32.TerminateJobObject(self.handle, 1);
    }

    /// Returns how many processes in the job are still running.
    pub fn activeProcessCount(self: Job) u32 {
        var info: win32.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = undefined;
        if (win32.QueryInformationJobObject(
            self.handle,
            win32.JobObjectBasicAccountingInformation,
            &info,
            @sizeOf(win32.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION),
            null,
        ) == .FALSE) return 0;
        return info.ActiveProcesses;
    }
};

/// Spawns `options` suspended, assigns the child to `job`, and resumes it, so
/// the child and everything it starts belong to the job before the child runs
/// any code. When pf already runs inside a job, as in the VS Code terminal,
/// the new job nests inside it.
pub fn spawn(io: std.Io, options: std.process.SpawnOptions, job: Job) (std.process.SpawnError || Error)!std.process.Child {
    var suspended = options;
    suspended.start_suspended = true;
    var child = try std.process.spawn(io, suspended);
    errdefer child.kill(io);
    if (win32.AssignProcessToJobObject(job.handle, child.id.?) == .FALSE) return error.ProcessJobUnavailable;
    if (win32.ResumeThread(child.thread_handle) == std.math.maxInt(windows.DWORD)) return error.ProcessJobUnavailable;
    return child;
}

/// Returns the ids of the running processes whose parent is `parent_pid`.
/// Caller owns the returned slice.
pub fn childProcessIdsAlloc(alloc: std.mem.Allocator, parent_pid: u32) ![]u32 {
    const snapshot = win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPPROCESS, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) return error.ProcessSnapshotUnavailable;
    defer windows.CloseHandle(snapshot);
    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(alloc);
    var entry: win32.PROCESSENTRY32W = .{};
    var more = win32.Process32FirstW(snapshot, &entry).toBool();
    while (more) : (more = win32.Process32NextW(snapshot, &entry).toBool()) {
        if (entry.th32ParentProcessID == parent_pid and entry.th32ProcessID != parent_pid) {
            try ids.append(alloc, entry.th32ProcessID);
        }
    }
    return ids.toOwnedSlice(alloc);
}

const io_mod = @import("io.zig");
const builtin = @import("builtin");

fn spawnPingTree(job: Job) !std.process.Child {
    return spawn(io_mod.getIo(), .{
        .argv = &.{ "cmd", "/d", "/c", "ping -n 30 127.0.0.1 >NUL" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }, job);
}

fn waitForChildren(alloc: std.mem.Allocator, parent_pid: u32, want_any: bool, timeout_ms: i64) !bool {
    const deadline = io_mod.milliTimestamp() + timeout_ms;
    while (true) {
        const ids = try childProcessIdsAlloc(alloc, parent_pid);
        defer alloc.free(ids);
        if ((ids.len > 0) == want_any) return true;
        if (io_mod.milliTimestamp() >= deadline) return false;
        io_mod.sleep(20 * std.time.ns_per_ms);
    }
}

test "Windows process job terminates every descendant within 2 s" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest; // Job Objects are Windows-only.
    const alloc = std.testing.allocator;
    var job = try Job.create();
    defer job.close();
    var child = try spawnPingTree(job);
    const cmd_pid = io_mod.childProcessId(child.id.?);
    try std.testing.expect(try waitForChildren(alloc, cmd_pid, true, 5_000));
    try std.testing.expect(job.activeProcessCount() >= 2);

    const killed_ms = io_mod.milliTimestamp();
    job.terminate();
    _ = try child.wait(io_mod.getIo());
    try std.testing.expect(try waitForChildren(alloc, cmd_pid, false, 2_000));
    try std.testing.expectEqual(@as(u32, 0), job.activeProcessCount());
    try std.testing.expect(io_mod.milliTimestamp() - killed_ms < 2_000);
}

test "Windows process job kills its processes when its last handle closes" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest; // Job Objects are Windows-only.
    const alloc = std.testing.allocator;
    var job = try Job.create();
    var child = try spawnPingTree(job);
    const cmd_pid = io_mod.childProcessId(child.id.?);
    try std.testing.expect(try waitForChildren(alloc, cmd_pid, true, 5_000));
    job.close();
    _ = try child.wait(io_mod.getIo());
    try std.testing.expect(try waitForChildren(alloc, cmd_pid, false, 2_000));
}

test "Windows process job nests inside a job that already holds pf" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest; // Job Objects are Windows-only.
    const outer = win32.CreateJobObjectW(null, null) orelse return error.ProcessJobUnavailable;
    defer windows.CloseHandle(outer);
    // The outer job has no limits, so holding the test process changes nothing else.
    try std.testing.expect(win32.AssignProcessToJobObject(outer, windows.GetCurrentProcess()).toBool());

    var job = try Job.create();
    defer job.close();
    var child = try spawnPingTree(job);
    defer {
        job.terminate();
        _ = child.wait(io_mod.getIo()) catch {};
    }
    var in_inner: windows.BOOL = .FALSE;
    var in_outer: windows.BOOL = .FALSE;
    try std.testing.expect(win32.IsProcessInJob(child.id.?, job.handle, &in_inner).toBool());
    try std.testing.expect(win32.IsProcessInJob(child.id.?, outer, &in_outer).toBool());
    try std.testing.expect(in_inner.toBool());
    try std.testing.expect(in_outer.toBool());
}
