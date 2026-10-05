const std = @import("std");
const builtin = @import("builtin");
const host = @import("host.zig");
const native_secret_store = @import("native_secret_store.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

pub const clipboard = host.Clipboard{
    .copy_fn = copyToClipboard,
    .copy_file_fn = copy_file_to_clipboard,
};

pub const secret_store = native_secret_store.provider;

fn copyToClipboard(_: ?*anyopaque, text: []const u8) host.ClipboardError!bool {
    if (comptime builtin.os.tag == .windows) return copyToWindowsClipboard(text);
    const argv = clipboardCommand(builtin.os.tag) orelse return false;
    const io = io_mod.getIo();
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        debug_trace.logf("host", "clipboard copy spawn failed err={s}", .{@errorName(err)});
        return error.CopyFailed;
    };
    defer child.kill(io);

    if (child.stdin) |*stdin| {
        stdin.writeStreamingAll(io, text) catch |err| {
            stdin.close(io);
            child.stdin = null;
            debug_trace.logf("host", "clipboard copy write failed err={s}", .{@errorName(err)});
            return error.CopyFailed;
        };
        stdin.close(io);
        child.stdin = null;
    } else {
        debug_trace.logf("host", "clipboard copy failed reason=stdin_unavailable", .{});
        return error.CopyFailed;
    }

    const term = child.wait(io) catch |err| {
        debug_trace.logf("host", "clipboard copy wait failed err={s}", .{@errorName(err)});
        return error.CopyFailed;
    };
    if (!copySucceeded(term)) {
        logUnsuccessfulTerm(term);
        return error.CopyFailed;
    }
    return true;
}

/// How long a copy waits for another program to release the Windows clipboard.
const windows_clipboard_busy_ms: i64 = 500;
const windows_clipboard_retry_ms: u64 = 10;

/// Places `text` on the Windows clipboard as `CF_UNICODETEXT`. The clipboard
/// opens for one process at a time, so a held clipboard is retried for
/// `windows_clipboard_busy_ms` before reporting `ClipboardBusy`.
fn copyToWindowsClipboard(text: []const u8) host.ClipboardError!bool {
    const win32 = @import("../shared/win32.zig");
    const length = std.unicode.calcWtf16LeLen(text) catch {
        debug_trace.logf("host", "clipboard copy failed reason=invalid_utf8", .{});
        return error.CopyFailed;
    };
    const bytes = (length + 1) * @sizeOf(u16);
    const memory = win32.GlobalAlloc(win32.GMEM_MOVEABLE, bytes) orelse return error.CopyFailed;
    var owned_by_clipboard = false;
    defer if (!owned_by_clipboard) {
        _ = win32.GlobalFree(memory);
    };
    {
        const locked = win32.GlobalLock(memory) orelse return error.CopyFailed;
        defer _ = win32.GlobalUnlock(memory);
        const destination: [*]u16 = @ptrCast(@alignCast(locked));
        const written = std.unicode.wtf8ToWtf16Le(destination[0..length], text) catch return error.CopyFailed;
        destination[written] = 0;
    }

    try openWindowsClipboard(windows_clipboard_busy_ms);
    defer _ = win32.CloseClipboard();
    if (!win32.EmptyClipboard().toBool()) {
        debug_trace.logf("host", "clipboard copy failed step=empty err={t}", .{std.os.windows.GetLastError()});
        return error.CopyFailed;
    }
    if (win32.SetClipboardData(win32.CF_UNICODETEXT, memory) == null) {
        debug_trace.logf("host", "clipboard copy failed step=set err={t}", .{std.os.windows.GetLastError()});
        return error.CopyFailed;
    }
    owned_by_clipboard = true;
    return true;
}

fn openWindowsClipboard(busy_ms: i64) host.ClipboardError!void {
    const win32 = @import("../shared/win32.zig");
    const started_ms = io_mod.milliTimestamp();
    while (!win32.OpenClipboard(null).toBool()) {
        if (io_mod.milliTimestamp() - started_ms >= busy_ms) {
            debug_trace.logf("host", "clipboard copy failed reason=busy err={t}", .{std.os.windows.GetLastError()});
            return error.ClipboardBusy;
        }
        io_mod.sleep(windows_clipboard_retry_ms * std.time.ns_per_ms);
    }
}

const ClipboardProcessResult = struct {
    term: std.process.Child.Term,
    stderr: []u8,
};

fn collect_clipboard_process_output(
    alloc: std.mem.Allocator,
    child: *std.process.Child,
    deadline: std.Io.Clock.Timestamp,
) std.process.RunError![]u8 {
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io_mod.getIo(), multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(64, .{ .deadline = deadline })) |_| {
        if (stdout_reader.buffered().len > 1024 or stderr_reader.buffered().len > 4096) {
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |fill_err| return fill_err,
    }
    try multi_reader.checkAnyError();

    return multi_reader.toOwnedSlice(1);
}

fn clipboard_process_term(status: c_int) std.process.Child.Term {
    const raw_status: u32 = @bitCast(status);
    return if (std.c.W.IFEXITED(raw_status))
        .{ .exited = std.c.W.EXITSTATUS(raw_status) }
    else if (std.c.W.IFSIGNALED(raw_status))
        .{ .signal = std.c.W.TERMSIG(raw_status) }
    else if (std.c.W.IFSTOPPED(raw_status))
        .{ .stopped = std.c.W.STOPSIG(raw_status) }
    else
        .{ .unknown = raw_status };
}

fn close_clipboard_process_streams(child: *std.process.Child) void {
    const io = io_mod.getIo();
    if (child.stdin) |stdin| stdin.close(io);
    if (child.stdout) |stdout| stdout.close(io);
    if (child.stderr) |stderr| stderr.close(io);
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
}

fn try_reap_clipboard_process(child: *std.process.Child) error{WaitFailed}!?std.process.Child.Term {
    const pid = child.id orelse return error.WaitFailed;
    var status: c_int = undefined;
    const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (waited == 0) return null;
    if (waited != pid) return error.WaitFailed;

    child.id = null;
    return clipboard_process_term(status);
}

fn kill_and_wait_clipboard_process(child: *std.process.Child) !std.process.Child.Term {
    const pid = child.id orelse return error.WaitFailed;
    std.posix.kill(pid, .KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => |kill_err| return kill_err,
    };
    return child.wait(io_mod.getIo());
}

fn wait_for_clipboard_process(
    child: *std.process.Child,
    deadline: std.Io.Clock.Timestamp,
) !std.process.Child.Term {
    const io = io_mod.getIo();
    while (true) {
        if (try try_reap_clipboard_process(child)) |term| return term;

        const now = std.Io.Clock.Timestamp.now(io, .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) {
            _ = try kill_and_wait_clipboard_process(child);
            return error.Timeout;
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

fn run_clipboard_process(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    deadline: std.Io.Clock.Timestamp,
) !ClipboardProcessResult {
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io_mod.getIo());
    defer close_clipboard_process_streams(&child);

    const term = wait_for_clipboard_process(&child, deadline) catch |err| {
        if (child.id != null) {
            _ = kill_and_wait_clipboard_process(&child) catch |cleanup_err| {
                debug_trace.logf("host", "clipboard file copy cleanup failed err={s}", .{@errorName(cleanup_err)});
            };
        }
        return err;
    };
    const stderr = try collect_clipboard_process_output(alloc, &child, deadline);
    return .{
        .term = term,
        .stderr = stderr,
    };
}

// Publish eager file representations so the pasteboard server owns them after
// this short-lived process exits.
fn copy_file_to_clipboard(_: ?*anyopaque, alloc: std.mem.Allocator, path: []const u8) host.ClipboardError!bool {
    if (comptime builtin.os.tag != .macos) return false;

    const script =
        \\function run(argv) {
        \\  ObjC.import("AppKit");
        \\  var url = $.NSURL.fileURLWithPath(argv[0]).standardizedURL;
        \\  var expected = ObjC.unwrap(url.absoluteString);
        \\  var pb = $.NSPasteboard.generalPasteboard;
        \\  pb.clearContents;
        \\  if (!pb.setStringForType(expected, "public.file-url")) {
        \\    throw new Error("public.file-url materialization failed");
        \\  }
        \\  var files = $.NSArray.arrayWithObject(argv[0]);
        \\  if (!pb.setPropertyListForType(files, "NSFilenamesPboardType")) {
        \\    throw new Error("NSFilenamesPboardType materialization failed");
        \\  }
        \\  var copiedValue = pb.stringForType("public.file-url");
        \\  if (!copiedValue) throw new Error("public.file-url readback missing");
        \\  var copied = ObjC.unwrap(copiedValue);
        \\  if (copied !== expected) throw new Error("public.file-url readback mismatch");
        \\  var copiedFiles = ObjC.deepUnwrap(pb.propertyListForType("NSFilenamesPboardType"));
        \\  if (!copiedFiles || copiedFiles.length !== 1 || copiedFiles[0] !== argv[0]) {
        \\    throw new Error("NSFilenamesPboardType readback mismatch");
        \\  }
        \\}
    ;
    const argv: []const []const u8 = &.{ "osascript", "-l", "JavaScript", "-e", script, path };
    const started_ms = io_mod.milliTimestamp();
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromSeconds(5),
    });
    const result = run_clipboard_process(alloc, argv, deadline) catch |err| {
        const finished_ms = io_mod.milliTimestamp();
        const elapsed_ms = if (finished_ms >= started_ms) finished_ms - started_ms else 0;
        debug_trace.logf("host", "clipboard file copy process failed err={s} elapsed_ms={d}", .{ @errorName(err), elapsed_ms });
        return error.CopyFailed;
    };
    defer alloc.free(result.stderr);

    const finished_ms = io_mod.milliTimestamp();
    const elapsed_ms = if (finished_ms >= started_ms) finished_ms - started_ms else 0;
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return true;
            debug_trace.logf("host", "clipboard file copy failed exit_code={d} elapsed_ms={d} stderr={s}", .{ code, elapsed_ms, result.stderr });
        },
        .signal => |signal| debug_trace.logf("host", "clipboard file copy failed term=signal signal={d} elapsed_ms={d} stderr={s}", .{ @intFromEnum(signal), elapsed_ms, result.stderr }),
        .stopped => |signal| debug_trace.logf("host", "clipboard file copy failed term=stopped signal={d} elapsed_ms={d} stderr={s}", .{ @intFromEnum(signal), elapsed_ms, result.stderr }),
        .unknown => |status| debug_trace.logf("host", "clipboard file copy failed term=unknown status={d} elapsed_ms={d} stderr={s}", .{ status, elapsed_ms, result.stderr }),
    }
    return error.CopyFailed;
}

fn clipboardCommand(os_tag: std.Target.Os.Tag) ?[]const []const u8 {
    return switch (os_tag) {
        .macos => &.{"pbcopy"},
        .linux => &.{ "xclip", "-selection", "clipboard" },
        else => null,
    };
}

fn copySucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };
}

fn logUnsuccessfulTerm(term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| debug_trace.logf("host", "clipboard copy failed exit_code={d}", .{code}),
        .signal => |signal| debug_trace.logf("host", "clipboard copy failed term=signal signal={d}", .{@intFromEnum(signal)}),
        .stopped => |signal| debug_trace.logf("host", "clipboard copy failed term=stopped signal={d}", .{@intFromEnum(signal)}),
        .unknown => |status| debug_trace.logf("host", "clipboard copy failed term=unknown status={d}", .{status}),
    }
}

test "native clipboard selects the platform command" {
    try std.testing.expectEqualStrings("pbcopy", clipboardCommand(.macos).?[0]);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "xclip", "-selection", "clipboard" },
        clipboardCommand(.linux).?,
    );
    try std.testing.expect(clipboardCommand(.windows) == null);
    try std.testing.expect(clipboardCommand(.wasi) == null);
}

test "native clipboard accepts only a successful exit" {
    try std.testing.expect(copySucceeded(.{ .exited = 0 }));
    try std.testing.expect(!copySucceeded(.{ .exited = 1 }));
    try std.testing.expect(!copySucceeded(.{ .signal = .TERM }));
    try std.testing.expect(!copySucceeded(.{ .stopped = if (builtin.os.tag == .windows) .TERM else .STOP }));
    try std.testing.expect(!copySucceeded(.{ .unknown = 1 }));
}

test "Windows clipboard copy reports a clipboard another thread holds" {
    // The Win32 clipboard exists only on Windows.
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const win32 = @import("../shared/win32.zig");
    const Holder = struct {
        opened: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            // A clipboard opened without a window does not exclude other
            // threads of this process, so the holder opens it through a
            // message-only window, as another program's window would.
            const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
            const window = win32.CreateWindowExW(0, class, null, 0, 0, 0, 0, 0, win32.HWND_MESSAGE, null, null, null) orelse return;
            defer _ = win32.DestroyWindow(window);
            if (!win32.OpenClipboard(window).toBool()) return;
            self.opened.store(true, .release);
            while (!self.release.load(.acquire)) io_mod.sleep(5 * std.time.ns_per_ms);
            _ = win32.CloseClipboard();
        }
    };
    var holder: Holder = .{};
    const thread = try std.Thread.spawn(.{}, Holder.run, .{&holder});
    defer thread.join();
    defer holder.release.store(true, .release);
    const wait_started = io_mod.milliTimestamp();
    while (!holder.opened.load(.acquire)) {
        if (io_mod.milliTimestamp() - wait_started > 2_000) return error.SkipZigTest;
        io_mod.sleep(5 * std.time.ns_per_ms);
    }

    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(error.ClipboardBusy, copyToClipboard(null, "held clipboard"));
    const elapsed_ms = io_mod.milliTimestamp() - started_ms;
    try std.testing.expect(elapsed_ms >= windows_clipboard_busy_ms);
    try std.testing.expect(elapsed_ms < windows_clipboard_busy_ms + 1_000);
}

test "Windows clipboard copy places Unicode text and restores the previous text" {
    // Writes the real clipboard, so it runs only on request.
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    if (io_mod.getenv("PF_TEST_WINDOWS_CLIPBOARD") == null) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const previous = try readWindowsClipboardText(alloc);
    defer if (previous) |text| alloc.free(text);
    defer if (previous) |text| {
        _ = copyToClipboard(null, text) catch {};
    };

    const text = "pf clipboard é ✓ 日本";
    try std.testing.expect(try copyToClipboard(null, text));
    const copied = (try readWindowsClipboardText(alloc)) orelse return error.TestExpectedClipboardText;
    defer alloc.free(copied);
    try std.testing.expectEqualStrings(text, copied);
}

/// Returns the clipboard's `CF_UNICODETEXT` as UTF-8, or null when it holds
/// none. Test use only.
fn readWindowsClipboardText(alloc: std.mem.Allocator) !?[]u8 {
    const win32 = @import("../shared/win32.zig");
    try openWindowsClipboard(windows_clipboard_busy_ms);
    defer _ = win32.CloseClipboard();
    const memory = win32.GetClipboardData(win32.CF_UNICODETEXT) orelse return null;
    const locked = win32.GlobalLock(memory) orelse return null;
    defer _ = win32.GlobalUnlock(memory);
    const wide: [*:0]const u16 = @ptrCast(@alignCast(locked));
    return try std.unicode.wtf16LeToWtf8Alloc(alloc, std.mem.sliceTo(wide, 0));
}
