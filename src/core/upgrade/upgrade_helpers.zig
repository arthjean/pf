const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const update_target = @import("update_target.zig");
const minisign = @import("minisign.zig");
const release_archive = @import("release_archive.zig");
const release_keys = @import("release_keys.zig");

const Allocator = std.mem.Allocator;

const recv_timeout_ms: i64 = 30 * std.time.ms_per_s;
const latest_version_max_bytes: usize = 128;
const checksum_max_bytes: usize = 4096;

const Channel = update_target.Channel;
const Target = update_target.Target;

/// Shuts a transfer's socket down after `recv_timeout_ms` without progress,
/// with a `std.Io` timer task instead of a socket receive timeout option.
const ReceiveWatchdog = struct {
    slot: TransferInterrupt = .{},
    last_progress_ms: std.atomic.Value(i64) = .init(0),
    future: ?std.Io.Future(std.Io.Cancelable!void) = null,

    fn start(self: *ReceiveWatchdog, conn: ?*std.http.Client.Connection) void {
        const connection = conn orelse return;
        self.slot.publish(connection.stream_writer.stream.socket.handle);
        self.progress();
        self.future = std.Io.concurrent(io_mod.getIo(), run, .{self}) catch null;
    }

    fn progress(self: *ReceiveWatchdog) void {
        self.last_progress_ms.store(io_mod.milliTimestamp(), .release);
    }

    fn stop(self: *ReceiveWatchdog) void {
        if (self.future) |*future| future.cancel(io_mod.getIo()) catch {};
        self.slot.clear();
    }

    fn run(self: *ReceiveWatchdog) std.Io.Cancelable!void {
        const zio = io_mod.getIo();
        while (true) {
            try zio.sleep(.fromMilliseconds(std.time.ms_per_s), .awake);
            if (io_mod.milliTimestamp() - self.last_progress_ms.load(.acquire) >= recv_timeout_ms) {
                self.slot.interrupt();
                return;
            }
        }
    }
};

/// pf's release host. It serves `latest.txt`, then each release under its tag.
pub const cdn_base = "https://releases.paneflow.dev/agent";

/// Where releases come from and the minisign keys they must be signed with.
pub const ReleaseOrigin = struct {
    base_url: []const u8,
    keys_buf: [2]minisign.PublicKey = undefined,
    key_count: usize = 0,

    pub fn keys(self: *const ReleaseOrigin) []const minisign.PublicKey {
        return self.keys_buf[0..self.key_count];
    }

    fn trust(self: *ReleaseOrigin, text: []const u8) void {
        if (text.len == 0 or self.key_count == self.keys_buf.len) return;
        self.keys_buf[self.key_count] = minisign.PublicKey.parse(text) catch return;
        self.key_count += 1;
    }
};

/// Resolves the release host. A validated loopback `PF_E2E_UPGRADE_BASE_URL`
/// replaces it for end-to-end tests, and only then does
/// `PF_E2E_UPGRADE_PUBLIC_KEY` replace the embedded release keys.
pub fn resolveReleaseOrigin() ReleaseOrigin {
    if (io_mod.getenv("PF_E2E_UPGRADE_BASE_URL")) |url| {
        if (isLoopbackE2eUpgradeBase(url)) {
            var origin: ReleaseOrigin = .{ .base_url = url };
            origin.trust(io_mod.getenv("PF_E2E_UPGRADE_PUBLIC_KEY") orelse "");
            return origin;
        }
    }
    var origin: ReleaseOrigin = .{ .base_url = cdn_base };
    origin.trust(release_keys.active);
    origin.trust(release_keys.next);
    return origin;
}

fn isLoopbackE2eUpgradeBase(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null or
        !uri.path.isEmpty() or
        uri.query != null or
        uri.fragment != null)
    {
        return false;
    }

    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1");
}

/// Release artifact platform, or null where pf publishes no artifact.
pub const platform: ?[]const u8 = platformFromTarget();

fn platformFromTarget() ?[]const u8 {
    const os: ?[]const u8 = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => if (builtin.cpu.arch == .x86_64) "windows" else null,
        else => null,
    };
    const arch: ?[]const u8 = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => null,
    };
    if (os) |o| {
        if (arch) |a| {
            return o ++ "-" ++ a;
        }
    }
    return null;
}

/// File name of this platform's release archive, such as `pf-linux-x86_64.tar.gz`.
pub const archive_name: ?[]const u8 = if (platform) |p| "pf-" ++ p ++ release_archive.native_format.extension() else null;

pub fn fetchTarget(alloc: Allocator, channel: Channel, base_url: []const u8, control: TransferControl) !Target {
    return switch (channel) {
        .stable => blk: {
            const latest = fetchLatestVersion(alloc, base_url, control) catch |err| return switch (err) {
                error.NotFound => error.NoReleasePublished,
                else => err,
            };
            defer alloc.free(latest);
            break :blk Target.initStable(alloc, latest) catch return error.FetchFailed;
        },
        .dev => blk: {
            var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
            defer client.deinit();
            const url = try std.fmt.allocPrint(alloc, "{s}/dev.json", .{base_url});
            defer alloc.free(url);
            const manifest = fetchTextBounded(
                &client,
                alloc,
                url,
                update_target.max_manifest_bytes,
                control,
            ) catch |err| return switch (err) {
                error.NotFound => error.NoReleasePublished,
                else => err,
            };
            defer alloc.free(manifest);
            break :blk Target.parseDevManifest(alloc, manifest) catch return error.FetchFailed;
        },
    };
}

fn fetchLatestVersion(alloc: Allocator, base_url: []const u8, control: TransferControl) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const url = try std.fmt.allocPrint(alloc, "{s}/latest.txt", .{base_url});
    defer alloc.free(url);

    const raw = try fetchTextBounded(
        &client,
        alloc,
        url,
        latest_version_max_bytes,
        control,
    );
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == raw.len) return raw;

    const duped = try alloc.dupe(u8, trimmed);
    alloc.free(raw);
    return duped;
}

pub fn cancelRequested(cancel: ?*const std.atomic.Value(bool)) bool {
    return if (cancel) |flag| flag.load(.acquire) else false;
}

/// Lets one thread interrupt another thread's blocking transfer read. The
/// transfer publishes its socket before first use and clears it before the
/// socket can be closed, both under the mutex, so interrupt() always acts on
/// a live socket or none at all.
pub const TransferInterrupt = struct {
    mutex: std.Io.Mutex = .init,
    handle: ?std.Io.net.Socket.Handle = null,

    pub fn publish(self: *TransferInterrupt, handle: std.Io.net.Socket.Handle) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        self.handle = handle;
    }

    pub fn clear(self: *TransferInterrupt) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        self.handle = null;
    }

    pub fn interrupt(self: *TransferInterrupt) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const handle = self.handle orelse return;
        zio.vtable.netShutdown(zio.userdata, handle, .both) catch {};
    }
};

pub const TransferControl = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    interrupt: ?*TransferInterrupt = null,
};

fn controlCancelled(control: TransferControl) bool {
    return cancelRequested(control.cancel);
}

/// Registers the request socket with the interrupt slot; the matching clear
/// runs before the request (and its connection) can be torn down.
fn publishConnection(
    control: TransferControl,
    req: *std.http.Client.Request,
) void {
    const slot = control.interrupt orelse return;
    const conn = req.connection orelse return;
    slot.publish(conn.stream_writer.stream.socket.handle);
}

fn clearConnection(control: TransferControl) void {
    const slot = control.interrupt orelse return;
    slot.clear();
}

test "transfer interrupt wakes a blocked socket read" {
    // The interrupt shuts the socket down gracefully, which does not wake a
    // pending Windows receive; stop() detaches the thread there instead.
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const zio = io_mod.getIo();
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(zio, .{});
    defer server.deinit(zio);

    const Ctx = struct {
        server: *std.Io.net.Server,
        slot: *TransferInterrupt,
        woke_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    };
    var slot: TransferInterrupt = .{};
    var ctx: Ctx = .{ .server = &server, .slot = &slot };
    const reader = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ctx) void {
            const z = io_mod.getIo();
            const conn = c.server.accept(z) catch return;
            defer conn.close(z);
            c.slot.publish(conn.socket.handle);
            defer c.slot.clear();
            var buf: [16]u8 = undefined;
            var stream_reader = conn.reader(z, &buf);
            // Blocks until the interrupt shuts the socket down.
            _ = stream_reader.interface.takeByte() catch {};
            c.woke_ms.store(io_mod.milliTimestamp(), .release);
        }
    }.run, .{&ctx});

    const client = try server.socket.address.connect(zio, .{ .mode = .stream });
    defer client.close(zio);

    const started_ms = io_mod.milliTimestamp();
    io_mod.sleep(100 * std.time.ns_per_ms);
    slot.interrupt();
    reader.join();
    const woke_ms = ctx.woke_ms.load(.acquire);
    try std.testing.expect(woke_ms != 0);
    try std.testing.expect(woke_ms - started_ms < 2000);

    // Interrupting an idle slot is a no-op.
    slot.interrupt();
}

fn fetchTextBounded(
    client: *std.http.Client,
    alloc: Allocator,
    url: []const u8,
    max_bytes: usize,
    control: TransferControl,
) ![]u8 {
    if (controlCancelled(control)) return error.Cancelled;
    const uri = std.Uri.parse(url) catch return error.FetchFailed;

    var req = client.request(.GET, uri, .{ .redirect_behavior = .unhandled }) catch return error.FetchFailed;
    defer req.deinit();

    var watchdog: ReceiveWatchdog = .{};
    watchdog.start(req.connection);
    defer watchdog.stop();
    publishConnection(control, &req);
    defer clearConnection(control);
    req.sendBodiless() catch return error.FetchFailed;

    var response = req.receiveHead(&.{}) catch return error.FetchFailed;
    watchdog.progress();
    try checkStatus(response.head.status, error.FetchFailed);
    if (response.head.content_length) |content_length| {
        if (content_length > max_bytes) return error.FetchFailed;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var transfer_buf: [4096]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    var chunk: [1024]u8 = undefined;
    while (true) {
        if (controlCancelled(control)) return error.Cancelled;
        const n = body_reader.readSliceShort(&chunk) catch return error.FetchFailed;
        watchdog.progress();
        if (n == 0) break;
        if (n > max_bytes -| out.writer.buffered().len) return error.FetchFailed;
        out.writer.writeAll(chunk[0..n]) catch return error.FetchFailed;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// pf never follows a redirect: the release host serves every object
/// directly, so a redirect can only send pf somewhere it must not download
/// from.
fn checkStatus(status: std.http.Status, comptime other: anyerror) !void {
    if (status == .ok) return;
    if (status.class() == .redirect) return error.UnexpectedRedirect;
    if (status == .not_found) return error.NotFound;
    return other;
}

pub const DownloadProgress = struct {
    ctx: *anyopaque,
    start: *const fn (*anyopaque, ?u64) void,
    update: *const fn (*anyopaque, u64, ?u64) void,
};

pub fn downloadFileStreaming(client: *std.http.Client, url: []const u8, dest_path: []const u8, control: TransferControl) !void {
    return downloadFileStreamingWithProgress(client, url, dest_path, null, control);
}

pub fn downloadFileStreamingWithProgress(client: *std.http.Client, url: []const u8, dest_path: []const u8, progress: ?DownloadProgress, control: TransferControl) !void {
    if (controlCancelled(control)) return error.Cancelled;
    var file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), dest_path, .{}) catch return error.DownloadFailed;
    defer file.close(io_mod.getIo());

    var write_buf: [64 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .initStreaming(file, io_mod.getIo(), &write_buf);

    const uri = std.Uri.parse(url) catch return error.DownloadFailed;
    var req = client.request(.GET, uri, .{ .redirect_behavior = .unhandled }) catch return error.DownloadFailed;
    defer req.deinit();

    var watchdog: ReceiveWatchdog = .{};
    watchdog.start(req.connection);
    defer watchdog.stop();
    publishConnection(control, &req);
    defer clearConnection(control);
    req.sendBodiless() catch return error.DownloadFailed;

    var response = req.receiveHead(&.{}) catch return error.DownloadFailed;
    watchdog.progress();
    try checkStatus(response.head.status, error.DownloadFailed);

    const total = response.head.content_length;
    if (progress) |p| p.start(p.ctx, total);

    var transfer_buf: [4096]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    var copy_buf: [64 * 1024]u8 = undefined;
    var downloaded: u64 = 0;
    while (true) {
        if (controlCancelled(control)) return error.Cancelled;
        const n = body_reader.readSliceShort(&copy_buf) catch return error.DownloadFailed;
        watchdog.progress();
        if (n == 0) break;
        file_writer.interface.writeAll(copy_buf[0..n]) catch return error.DownloadFailed;
        downloaded += n;
        if (progress) |p| p.update(p.ctx, downloaded, total);
    }

    file_writer.interface.flush() catch return error.DownloadFailed;
}

pub fn verifyChecksum(client: *std.http.Client, file_path: []const u8, checksum_url: []const u8, control: TransferControl) !void {
    const raw = fetchTextBounded(
        client,
        client.allocator,
        checksum_url,
        checksum_max_bytes,
        control,
    ) catch |err| return switch (err) {
        error.Cancelled => error.Cancelled,
        error.UnexpectedRedirect => error.UnexpectedRedirect,
        else => error.ChecksumFetchFailed,
    };
    defer client.allocator.free(raw);

    const expected_hex = extractChecksumHex(raw) orelse return error.ChecksumMismatch;
    if (expected_hex.len != 64) return error.ChecksumMismatch;

    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), file_path, .{}) catch return error.ChecksumMismatch;
    defer file.close(io_mod.getIo());

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var rbuf: [8192]u8 = undefined;
    var r = file.readerStreaming(io_mod.getIo(), &rbuf);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = r.interface.readSliceShort(&buf) catch return error.ChecksumMismatch;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    const digest = hasher.finalResult();
    const actual_hex = bytesToHex(&digest);

    if (!std.mem.eql(u8, &actual_hex, expected_hex)) return error.ChecksumMismatch;
}

fn bytesToHex(bytes: *const [32]u8) [64]u8 {
    const charset = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (bytes, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
    return out;
}

fn extractChecksumHex(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.findScalar(u8, trimmed, ' ')) |space_idx| {
        return trimmed[0..space_idx];
    }
    return if (trimmed.len >= 64) trimmed[0..64] else null;
}

pub const VerifiedDownloadError = error{
    NoArtifact,
    DownloadFailed,
    UnexpectedRedirect,
    ChecksumFetchFailed,
    ChecksumMismatch,
    SignatureMissing,
    SignatureFetchFailed,
    InvalidArchive,
    ArchiveTooLarge,
    ExtractionFailed,
    OutOfMemory,
    Cancelled,
} || minisign.Error;

/// Downloads this platform's archive of `target` into `tmp_dir`, verifies its
/// SHA-256 sidecar and its minisign signature against `origin`'s keys, then
/// extracts the binary. Returns the extracted binary's path, owned by the
/// caller. Nothing outside `tmp_dir` is written.
pub fn downloadVerifiedBinary(
    alloc: Allocator,
    client: *std.http.Client,
    origin: *const ReleaseOrigin,
    target: update_target.Target,
    tmp_dir: []const u8,
    progress: ?DownloadProgress,
    control: TransferControl,
) VerifiedDownloadError![]u8 {
    const name = archive_name orelse return error.NoArtifact;
    const archive_url = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ origin.base_url, target.artifactRef(), name });
    defer alloc.free(archive_url);
    const archive_path = try std.fs.path.join(alloc, &.{ tmp_dir, name });
    defer alloc.free(archive_path);

    downloadFileStreamingWithProgress(client, archive_url, archive_path, progress, control) catch |err| return switch (err) {
        error.Cancelled => error.Cancelled,
        error.UnexpectedRedirect => error.UnexpectedRedirect,
        else => error.DownloadFailed,
    };
    if (controlCancelled(control)) return error.Cancelled;

    const checksum_url = try std.fmt.allocPrint(alloc, "{s}.sha256", .{archive_url});
    defer alloc.free(checksum_url);
    try verifyChecksum(client, archive_path, checksum_url, control);

    const signature_url = try std.fmt.allocPrint(alloc, "{s}.minisig", .{archive_url});
    defer alloc.free(signature_url);
    const signature = fetchTextBounded(client, alloc, signature_url, minisign.max_signature_bytes, control) catch |err| return switch (err) {
        error.Cancelled => error.Cancelled,
        error.UnexpectedRedirect => error.UnexpectedRedirect,
        error.NotFound => error.SignatureMissing,
        error.OutOfMemory => error.OutOfMemory,
        else => error.SignatureFetchFailed,
    };
    defer alloc.free(signature);

    const zio = io_mod.getIo();
    {
        var archive = std.Io.Dir.openFileAbsolute(zio, archive_path, .{}) catch return error.ExtractionFailed;
        defer archive.close(zio);
        try minisign.verifyFile(zio, archive, signature, origin.keys(), .{
            .file = name,
            .version = target.version(),
            .channel = target.channel().label(),
            .commit = target.revision(),
        });
    }
    if (controlCancelled(control)) return error.Cancelled;

    var dest = std.Io.Dir.openDirAbsolute(zio, tmp_dir, .{}) catch return error.ExtractionFailed;
    defer dest.close(zio);
    try release_archive.extractBinary(zio, archive_path, release_archive.native_format, dest);
    return std.fs.path.join(alloc, &.{ tmp_dir, release_archive.binary_name });
}

/// Fails with `error.InstallDirNotWritable` unless pf can create a file next
/// to `exe_path`, so an upgrade stops before it downloads anything.
pub fn checkInstallDirWritable(exe_path: []const u8) error{InstallDirNotWritable}!void {
    const dir_path = std.fs.path.dirname(exe_path) orelse return error.InstallDirNotWritable;
    const zio = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(zio, dir_path, .{}) catch return error.InstallDirNotWritable;
    defer dir.close(zio);
    var rand_buf: [8]u8 = undefined;
    zio.random(&rand_buf);
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, ".pf-write-probe-{s}", .{std.fmt.bytesToHex(rand_buf, .lower)}) catch unreachable;
    var probe = dir.createFile(zio, name, .{ .exclusive = true }) catch return error.InstallDirNotWritable;
    probe.close(zio);
    dir.deleteFile(zio, name) catch {};
}

/// Installs `new_path` as the binary at `target_path`. POSIX replaces the
/// file in one atomic rename. Windows cannot replace a running `.exe`, so it
/// renames the running binary to `<target>.old` first and renames it back if
/// the new binary cannot be moved into place; `sweepReplacedBinary` removes
/// the leftovers on a later start.
pub fn installBinary(alloc: Allocator, new_path: []const u8, target_path: []const u8) error{ReplaceFailed}!void {
    if (comptime builtin.os.tag != .windows) {
        io_mod.copyFileAtomic(alloc, new_path, target_path) catch return error.ReplaceFailed;
        return;
    }
    const zio = io_mod.getIo();
    const staged_path = std.fmt.allocPrint(alloc, "{s}.new", .{target_path}) catch return error.ReplaceFailed;
    defer alloc.free(staged_path);
    const old_path = std.fmt.allocPrint(alloc, "{s}.old", .{target_path}) catch return error.ReplaceFailed;
    defer alloc.free(old_path);

    // Stage on the target's volume so the final step is a rename.
    io_mod.copyFileAtomic(alloc, new_path, staged_path) catch return error.ReplaceFailed;
    errdefer std.Io.Dir.deleteFileAbsolute(zio, staged_path) catch {};
    std.Io.Dir.deleteFileAbsolute(zio, old_path) catch |err| switch (err) {
        error.FileNotFound => {},
        // A pf still running from the leftover, such as the parent of a
        // ctrl+g relaunch, keeps it from being deleted. A running image can
        // still be renamed, so it moves aside under a unique name.
        error.AccessDenied, error.PermissionDenied, error.FileBusy => try moveAside(alloc, old_path),
        else => return error.ReplaceFailed,
    };
    try moveFileWindows(alloc, target_path, old_path);
    moveFileWindows(alloc, staged_path, target_path) catch {
        moveFileWindows(alloc, old_path, target_path) catch {};
        return error.ReplaceFailed;
    };
}

fn moveAside(alloc: Allocator, old_path: []const u8) error{ReplaceFailed}!void {
    var rand_buf: [8]u8 = undefined;
    io_mod.getIo().random(&rand_buf);
    const aside_path = std.fmt.allocPrint(alloc, "{s}.{s}", .{ old_path, std.fmt.bytesToHex(rand_buf, .lower) }) catch
        return error.ReplaceFailed;
    defer alloc.free(aside_path);
    try moveFileWindows(alloc, old_path, aside_path);
}

/// Renames a file that may be a running executable. `std.Io.Dir.rename`
/// opens the source for writing, which Windows refuses for a mapped image;
/// `MoveFileExW` needs only delete access.
fn moveFileWindows(alloc: Allocator, from: []const u8, to: []const u8) error{ReplaceFailed}!void {
    const win32 = @import("../shared/win32.zig");
    const from_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, from) catch return error.ReplaceFailed;
    defer alloc.free(from_w);
    const to_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, to) catch return error.ReplaceFailed;
    defer alloc.free(to_w);
    if (!win32.MoveFileExW(from_w, to_w, win32.MOVEFILE_WRITE_THROUGH).toBool()) return error.ReplaceFailed;
}

/// Deletes the `pf.exe.old` and `pf.exe.old.<id>` files Windows upgrades left
/// next to the running binary. A failure, such as a previous pf still
/// running, is ignored and the next start tries again.
pub fn sweepReplacedBinary() void {
    if (comptime builtin.os.tag != .windows) return;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = currentExecutablePath(&exe_buf) catch return;
    sweepReplacedBinaryAt(exe);
}

fn sweepReplacedBinaryAt(exe_path: []const u8) void {
    const zio = io_mod.getIo();
    const dir_path = std.fs.path.dirname(exe_path) orelse return;
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_name = std.fmt.bufPrint(&prefix_buf, "{s}.old", .{std.fs.path.basename(exe_path)}) catch return;
    var dir = std.Io.Dir.openDirAbsolute(zio, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(zio);
    var entries = dir.iterate();
    while (entries.next(zio) catch return) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, old_name)) continue;
        const rest = entry.name[old_name.len..];
        if (rest.len != 0 and rest[0] != '.') continue;
        dir.deleteFile(zio, entry.name) catch {};
    }
}

pub const ExecutablePathError = error{
    SelfExeNotFound,
    PathTooLong,
};

pub fn currentExecutablePath(out: []u8) ExecutablePathError![]const u8 {
    const n = std.process.executablePath(io_mod.getIo(), out) catch |err| switch (err) {
        error.NameTooLong => return error.PathTooLong,
        else => return error.SelfExeNotFound,
    };
    const path = out[0..n];
    const linux_deleted_suffix = " (deleted)";
    if (builtin.os.tag == .linux and std.mem.endsWith(u8, path, linux_deleted_suffix)) {
        return path[0 .. path.len - linux_deleted_suffix.len];
    }
    return path;
}

fn writeTempFile(dir: std.Io.Dir, name: []const u8, content: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), name, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readAbsoluteFile(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

test "platform string is valid" {
    const value = platform orelse return error.SkipZigTest;
    try std.testing.expect(value.len > 0);
    try std.testing.expect(std.mem.find(u8, value, "-") != null);
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        try std.testing.expectEqualStrings("windows-x86_64", value);
        try std.testing.expectEqualStrings("pf-windows-x86_64.zip", archive_name.?);
    }
}

test "E2E upgrade base accepts only explicit IPv4 loopback origins" {
    try std.testing.expect(isLoopbackE2eUpgradeBase("http://127.0.0.1:1234"));
    try std.testing.expect(!isLoopbackE2eUpgradeBase("https://127.0.0.1:1234"));
    try std.testing.expect(!isLoopbackE2eUpgradeBase("http://127.0.0.1"));
    try std.testing.expect(!isLoopbackE2eUpgradeBase("http://127.0.0.1:80@example.com"));
    try std.testing.expect(!isLoopbackE2eUpgradeBase("http://localhost:1234"));
}

test "production upgrade origin is the release host with the embedded keys" {
    if (io_mod.getenv("PF_E2E_UPGRADE_BASE_URL") != null) return error.SkipZigTest;
    const origin = resolveReleaseOrigin();
    try std.testing.expectEqualStrings("https://releases.paneflow.dev/agent", origin.base_url);
    // Every embedded key parses, so a malformed slot cannot silently drop out.
    const expected_keys: usize = if (release_keys.next.len == 0) 1 else 2;
    try std.testing.expectEqual(expected_keys, origin.keys().len);
}

test "release host responses never follow redirects" {
    try checkStatus(.ok, error.FetchFailed);
    try std.testing.expectError(error.UnexpectedRedirect, checkStatus(.found, error.FetchFailed));
    try std.testing.expectError(error.UnexpectedRedirect, checkStatus(.moved_permanently, error.FetchFailed));
    try std.testing.expectError(error.UnexpectedRedirect, checkStatus(.temporary_redirect, error.FetchFailed));
    try std.testing.expectError(error.NotFound, checkStatus(.not_found, error.FetchFailed));
    try std.testing.expectError(error.FetchFailed, checkStatus(.internal_server_error, error.FetchFailed));
}

test "extractChecksumHex parses sha256sum format" {
    const with_filename = "abc123def456  pf-macos-aarch64.tar.gz\n";
    const hex = extractChecksumHex(with_filename).?;
    try std.testing.expectEqualStrings("abc123def456", hex);
}

test "extractChecksumHex parses raw hex" {
    const raw = "a" ** 64 ++ "\n";
    const hex = extractChecksumHex(raw).?;
    try std.testing.expectEqual(@as(usize, 64), hex.len);
    try std.testing.expectEqualStrings("a" ** 64, hex);
}

test "extractChecksumHex rejects short raw checksum" {
    try std.testing.expect(extractChecksumHex("abcd\n") == null);
}

test "bytesToHex renders lowercase sha256 digest" {
    const bytes = [_]u8{0x0f} ** 32;
    const hex = bytesToHex(&bytes);
    try std.testing.expectEqualStrings("0f" ** 32, &hex);
}

test "installBinary replaces the target and keeps the old binary aside on Windows" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(tmp.dir, "pf-old", "old");
    try writeTempFile(tmp.dir, "pf-new", "new");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const new_path = try std.fs.path.join(alloc, &.{ root, "pf-new" });
    defer alloc.free(new_path);
    const target_path = try std.fs.path.join(alloc, &.{ root, "pf-old" });
    defer alloc.free(target_path);

    try installBinary(alloc, new_path, target_path);

    const replaced = try readAbsoluteFile(alloc, target_path);
    defer alloc.free(replaced);
    try std.testing.expectEqualStrings("new", replaced);
    if (builtin.os.tag == .windows) {
        const old_path = try std.fmt.allocPrint(alloc, "{s}.old", .{target_path});
        defer alloc.free(old_path);
        const old = try readAbsoluteFile(alloc, old_path);
        defer alloc.free(old);
        try std.testing.expectEqualStrings("old", old);
        // A second upgrade replaces the leftover.
        try installBinary(alloc, new_path, target_path);
    }
}

test "installBinary leaves the target untouched when it cannot replace it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(tmp.dir, "pf.exe", "old");
    try writeTempFile(tmp.dir, "pf-new", "new");
    // A directory where the old binary must go cannot be removed as a file.
    try tmp.dir.createDir(std.testing.io, "pf.exe.old", .default_dir);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const new_path = try std.fs.path.join(alloc, &.{ root, "pf-new" });
    defer alloc.free(new_path);
    const target_path = try std.fs.path.join(alloc, &.{ root, "pf.exe" });
    defer alloc.free(target_path);

    try std.testing.expectError(error.ReplaceFailed, installBinary(alloc, new_path, target_path));
    const kept = try readAbsoluteFile(alloc, target_path);
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("old", kept);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "pf.exe.new", .{}));
}

test "installBinary moves a leftover that still runs aside on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const target_path = try std.fs.path.join(alloc, &.{ root, "pf.exe" });
    defer alloc.free(target_path);
    const new_path = try std.fs.path.join(alloc, &.{ root, "pf-new" });
    defer alloc.free(new_path);
    const system_root = io_mod.getenv("SystemRoot") orelse "C:\\Windows";
    const ping = try std.fs.path.join(alloc, &.{ system_root, "System32", "PING.EXE" });
    defer alloc.free(ping);
    try io_mod.copyFileAtomic(alloc, ping, target_path);
    try writeTempFile(tmp.dir, "pf-new", "new");

    // The running pf.exe moves to pf.exe.old and keeps running there, as the
    // parent of a ctrl+g relaunch does.
    var running = try std.process.spawn(zio, .{
        .argv = &.{ target_path, "-n", "60", "127.0.0.1" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var killed = false;
    defer if (!killed) running.kill(zio);
    try installBinary(alloc, new_path, target_path);

    // A second upgrade cannot delete the running leftover and moves it aside.
    try writeTempFile(tmp.dir, "pf-new", "newer");
    try installBinary(alloc, new_path, target_path);
    const installed = try readAbsoluteFile(alloc, target_path);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("newer", installed);
    const old_path = try std.fmt.allocPrint(alloc, "{s}.old", .{target_path});
    defer alloc.free(old_path);
    const old = try readAbsoluteFile(alloc, old_path);
    defer alloc.free(old);
    try std.testing.expectEqualStrings("new", old);
    try std.testing.expectEqual(@as(usize, 1), countLeftovers(tmp.dir, "pf.exe.old."));

    running.kill(zio);
    killed = true;
    sweepReplacedBinaryAt(target_path);
    try std.testing.expectEqual(@as(usize, 0), countLeftovers(tmp.dir, "pf.exe.old"));
}

fn countLeftovers(dir: std.Io.Dir, prefix: []const u8) usize {
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(std.testing.io) catch return count) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) count += 1;
    }
    return count;
}

test "sweepReplacedBinaryAt removes only the binary's leftovers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const exe_path = try std.fs.path.join(alloc, &.{ root, "pf.exe" });
    defer alloc.free(exe_path);
    for ([_][]const u8{ "pf.exe", "pf.exe.old", "pf.exe.old.0123456789abcdef", "pf.exe.older", "other.exe.old" }) |name| {
        try writeTempFile(tmp.dir, name, "x");
    }

    sweepReplacedBinaryAt(exe_path);

    try std.testing.expectEqual(@as(usize, 0), countLeftovers(tmp.dir, "pf.exe.old."));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "pf.exe.old", .{}));
    for ([_][]const u8{ "pf.exe", "pf.exe.older", "other.exe.old" }) |name| {
        _ = try tmp.dir.statFile(std.testing.io, name, .{});
    }
}

test "checkInstallDirWritable probes the binary directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const exe_path = try std.fs.path.join(alloc, &.{ root, "pf" });
    defer alloc.free(exe_path);
    try checkInstallDirWritable(exe_path);
    var it = tmp.dir.iterate();
    try std.testing.expect(try it.next(std.testing.io) == null);

    const missing = try std.fs.path.join(alloc, &.{ root, "missing", "pf" });
    defer alloc.free(missing);
    try std.testing.expectError(error.InstallDirNotWritable, checkInstallDirWritable(missing));
}
