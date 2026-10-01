const std = @import("std");

const command_admission = @import("../permissions/command_admission.zig");
const direct_command = @import("../permissions/direct_command.zig");
const command_runner = @import("../execution/command_runner.zig");
const command_effect = @import("../shell_command/command_effect.zig");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const shell_selection = @import("shell_selection.zig");

pub const RouteKind = enum {
    direct_read_only,
    approved_shell,
};

/// An admitted foreground command prepared for local execution.
///
/// The direct plan owns its allocations. The caller must call `deinit`.
pub const PreparedCommand = union(enum) {
    direct_read_only: command_effect.DirectReadOnlyPlan,
    approved_shell: struct {
        command_ctx: command_admission.CommandContext,
        reason: command_effect.ApprovalReason,
        source: command_admission.ShellAuthorizationSource,
    },

    pub fn deinit(self: *PreparedCommand, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .direct_read_only => |*plan| plan.deinit(alloc),
            .approved_shell => {},
        }
        self.* = undefined;
    }
};

pub const CommandResult = struct {
    route: RouteKind,
    result: command_runner.CommandExecutionResult,
};

/// Upper bound for raw callback bytes that can still be represented by the
/// command's ordinary foreground result. Above this bound execution either
/// rejects output or promotes it to an unordered command artifact.
pub fn foregroundResultComparisonLimit(
    command: PreparedCommand,
    approved_shell_limit: usize,
) usize {
    return switch (command) {
        .direct_read_only => direct_command.direct_output_limit_bytes,
        .approved_shell => approved_shell_limit,
    };
}

/// Executes a prepared foreground command without taking ownership of it.
pub fn executePreparedCommand(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    command: PreparedCommand,
) !CommandResult {
    return switch (command) {
        .direct_read_only => |plan| .{
            .route = .direct_read_only,
            .result = try direct_command.executeDirectReadOnly(cfg, alloc, plan),
        },
        .approved_shell => |shell| .{
            .route = .approved_shell,
            .result = try command_runner.executeCommandInEnvironment(
                cfg,
                alloc,
                shell.command_ctx.command,
                shell.command_ctx.resolved_cwd,
                shell.command_ctx.environment,
            ),
        },
    };
}

test "local executor keeps route-specific foreground result limits" {
    const direct = PreparedCommand{ .direct_read_only = .{
        .command = "",
        .cwd = "",
        .stages = &.{},
    } };
    try std.testing.expectEqual(
        direct_command.direct_output_limit_bytes,
        foregroundResultComparisonLimit(direct, 1),
    );

    const approved = PreparedCommand{ .approved_shell = .{
        .command_ctx = .{
            .command = "",
            .resolved_cwd = "",
            .target_os = @import("builtin").os.tag,
        },
        .reason = .process_or_system,
        .source = .interactive_once,
    } };
    try std.testing.expectEqual(
        @as(usize, 1024),
        foregroundResultComparisonLimit(approved, 1024),
    );
}

test "local executor runs an approved shell command with its admitted context" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = PreparedCommand{ .approved_shell = .{
        .command_ctx = .{
            .command = "printf local-executor",
            .resolved_cwd = "/tmp",
            .target_os = @import("builtin").os.tag,
        },
        .reason = .process_or_system,
        .source = .interactive_once,
    } };
    const executed = try executePreparedCommand(.{
        .max_command_output_bytes = 1024,
    }, arena, command);

    try std.testing.expectEqual(RouteKind.approved_shell, executed.route);
    try std.testing.expect(std.mem.find(
        u8,
        executed.result.output,
        "<stdout>\nlocal-executor\n</stdout>",
    ) != null);
    const foreground = executed.result.command_result.?;
    try std.testing.expectEqualStrings(command.approved_shell.command_ctx.command, foreground.command);
    try std.testing.expectEqualStrings(command.approved_shell.command_ctx.resolved_cwd, foreground.cwd);
    try std.testing.expectEqual(@as(?i64, 0), foreground.exit_code);
}

/// Counts running processes whose image is `exe_name`. Windows test helper.
fn windowsProcessCount(exe_name: []const u8) !usize {
    const win32 = @import("../shared/win32.zig");
    const snapshot = win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPPROCESS, 0);
    if (snapshot == std.os.windows.INVALID_HANDLE_VALUE) return error.ProcessSnapshotUnavailable;
    defer std.os.windows.CloseHandle(snapshot);
    var entry: win32.PROCESSENTRY32W = .{};
    var count: usize = 0;
    var more = win32.Process32FirstW(snapshot, &entry).toBool();
    while (more) : (more = win32.Process32NextW(snapshot, &entry).toBool()) {
        var name_buffer: [std.os.windows.MAX_PATH * 3]u8 = undefined;
        const name_w = std.mem.sliceTo(&entry.szExeFile, 0);
        const name_len = std.unicode.wtf16LeToWtf8(&name_buffer, name_w);
        if (std.ascii.eqlIgnoreCase(name_buffer[0..name_len], exe_name)) count += 1;
    }
    return count;
}

fn waitForWindowsProcessCount(exe_name: []const u8, expected: usize, timeout_ms: i64) !bool {
    const deadline = io_mod.milliTimestamp() + timeout_ms;
    while (true) {
        if (try windowsProcessCount(exe_name) == expected) return true;
        if (io_mod.milliTimestamp() >= deadline) return false;
        io_mod.sleep(20 * std.time.ns_per_ms);
    }
}

test "Windows command timeout and cancellation end the whole process tree" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest; // Job Objects are Windows-only.
    const shell = shell_selection.current() catch return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A uniquely named copy of ping makes the tree's descendants countable.
    const probe_name = "pf-command-tree-probe.exe";
    try std.Io.Dir.copyFileAbsolute("C:\\Windows\\System32\\PING.EXE", try std.fs.path.join(arena, &.{ try io_mod.dirRealpathAlloc(arena, tmp.dir, "."), probe_name }), io_mod.getIo(), .{});
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const probe = try std.mem.replaceOwned(u8, arena, try std.fs.path.join(arena, &.{ root, probe_name }), "\\", "/");
    const command = switch (shell.dialect) {
        .posix_sh => try std.fmt.allocPrint(arena, "'{s}' -n 30 127.0.0.1 >/dev/null & '{s}' -n 30 127.0.0.1", .{ probe, probe }),
        .powershell => try std.fmt.allocPrint(arena, "Start-Process '{s}' -ArgumentList '-n 30 127.0.0.1' -NoNewWindow; & '{s}' -n 30 127.0.0.1", .{ probe, probe }),
    };

    const timeout_started = io_mod.milliTimestamp();
    try std.testing.expectError(error.TimeoutExpired, command_runner.executeCommand(.{
        .max_command_output_bytes = 4096,
        .timeout_ms = 1_500,
    }, arena, command, root));
    try std.testing.expect(io_mod.milliTimestamp() - timeout_started < 1_500 + 2_000);
    try std.testing.expect(try waitForWindowsProcessCount(probe_name, 0, 2_000));

    var cancel = std.atomic.Value(bool).init(false);
    const Canceller = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            const deadline = io_mod.milliTimestamp() + 10_000;
            while (io_mod.milliTimestamp() < deadline) {
                if ((windowsProcessCount(probe_name) catch 0) == 2) break;
                io_mod.sleep(20 * std.time.ns_per_ms);
            }
            flag.store(true, .seq_cst);
        }
    };
    const canceller = try std.Thread.spawn(.{}, Canceller.run, .{&cancel});
    const cancel_result = command_runner.executeCommand(.{
        .max_command_output_bytes = 4096,
        .cancel_flag = &cancel,
    }, arena, command, root);
    canceller.join();
    const cancelled_ms = io_mod.milliTimestamp();
    if (cancel_result) |result| {
        try std.testing.expect(result.cancelled);
    } else |err| try std.testing.expectEqual(error.Cancelled, err);
    try std.testing.expect(try waitForWindowsProcessCount(probe_name, 0, 2_000));
    try std.testing.expect(io_mod.milliTimestamp() - cancelled_ms < 2_000);
}
