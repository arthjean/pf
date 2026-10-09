//! Winsock AF_UNIX endpoints for the Windows terminal host. `std.Io.net`
//! listens on AF_UNIX through AFD but cannot name the peer process, so the
//! host and the session launchers listen through Winsock, which answers
//! `SIO_AF_UNIX_GETPEERPID`. Each accepted socket is an AFD endpoint that
//! `std.Io.net` reads and writes like its own. Clients connect through
//! `std.Io.net.UnixAddress`. Reference this file only from code selected at
//! comptime for Windows.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const win32 = @import("../shared/win32.zig");
const io_mod = @import("../shared/io.zig");

pub const ListenError = error{
    SocketUnavailable,
    NameTooLong,
    AddressInUse,
};

/// Listens on the AF_UNIX `path`, which Winsock reads as UTF-8. The socket
/// is overlapped, so `std.Io.net` can use the streams it accepts, and not
/// inheritable. Close it with `closeSocket`.
pub fn listen(path: []const u8) ListenError!windows.HANDLE {
    try startup();
    var address: ws2_32.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= address.path.len) return error.NameTooLong;
    @memcpy(address.path[0..path.len], path);
    const socket = win32.WSASocketW(
        ws2_32.AF.UNIX,
        ws2_32.SOCK.STREAM,
        0,
        null,
        0,
        win32.WSA_FLAG_OVERLAPPED | win32.WSA_FLAG_NO_HANDLE_INHERIT,
    );
    if (socket == windows.INVALID_HANDLE_VALUE) return error.SocketUnavailable;
    errdefer closeSocket(socket);
    if (win32.bind(socket, @ptrCast(&address), @sizeOf(ws2_32.sockaddr.un)) != 0) {
        return switch (win32.WSAGetLastError()) {
            win32.WSAEADDRINUSE => error.AddressInUse,
            else => error.SocketUnavailable,
        };
    }
    if (win32.listen(socket, std.Io.net.default_kernel_backlog) != 0) return error.SocketUnavailable;
    return socket;
}

pub fn closeSocket(socket: windows.HANDLE) void {
    _ = win32.closesocket(socket);
}

/// Closes a stream accepted by `acceptTimeout`.
pub fn closeStream(stream: std.Io.net.Stream) void {
    closeSocket(stream.socket.handle);
}

pub const AcceptError = error{ ListenerClosed, AcceptFailed };

/// Waits up to `timeout_ms` for a connection on `listener` and accepts it.
/// Returns null when none arrived or the peer gave up first. Close the
/// stream with `closeStream`.
pub fn acceptTimeout(listener: windows.HANDLE, timeout_ms: i32) AcceptError!?std.Io.net.Stream {
    var poll_fds = [_]win32.WSAPOLLFD{.{ .fd = listener, .events = win32.POLLRDNORM, .revents = 0 }};
    const ready = win32.WSAPoll(&poll_fds, 1, timeout_ms);
    if (ready < 0) return error.ListenerClosed;
    if (ready == 0) return null;
    if (poll_fds[0].revents & (win32.POLLERR | win32.POLLHUP | win32.POLLNVAL) != 0) return error.ListenerClosed;
    const socket = win32.accept(listener, null, null);
    if (socket == windows.INVALID_HANDLE_VALUE) {
        return switch (win32.WSAGetLastError()) {
            win32.WSAEWOULDBLOCK, win32.WSAECONNRESET => null,
            else => error.AcceptFailed,
        };
    }
    return .{ .socket = .{ .handle = socket, .address = .{ .ip4 = .loopback(0) } } };
}

/// The process id of the peer of an AF_UNIX socket accepted through Winsock.
fn peerProcessId(socket: windows.HANDLE) error{PeerIdentityUnavailable}!u32 {
    var pid: windows.ULONG = 0;
    var returned: windows.DWORD = 0;
    // Windows leaves the returned byte count at zero for this control code,
    // so a nonzero pid is what proves the call answered.
    if (win32.WSAIoctl(
        socket,
        win32.SIO_AF_UNIX_GETPEERPID,
        null,
        0,
        &pid,
        @sizeOf(windows.ULONG),
        &returned,
        null,
        null,
    ) != 0 or pid == 0) return error.PeerIdentityUnavailable;
    return pid;
}

/// Whether the peer of a connected AF_UNIX `socket`, on either side, runs as
/// the user that runs this process. Fails closed. Windows records the peer's
/// pid at connect, so a process created after this check began holds a reused
/// pid and does not match.
pub fn peerMatchesCurrentUser(socket: windows.HANDLE) bool {
    var now: windows.FILETIME = undefined;
    win32.GetSystemTimePreciseAsFileTime(&now);
    const pid = peerProcessId(socket) catch return false;
    return processUserMatchesCurrent(pid, fileTimeValue(now));
}

fn fileTimeValue(time: windows.FILETIME) u64 {
    return (@as(u64, time.dwHighDateTime) << 32) | time.dwLowDateTime;
}

/// Whether process `pid`, created no later than `created_by`, runs as the
/// user that runs this process. Fails closed: a process that cannot be
/// opened or queried does not match.
fn processUserMatchesCurrent(pid: u32, created_by: u64) bool {
    const process = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid) orelse return false;
    defer windows.CloseHandle(process);
    var created: windows.FILETIME = undefined;
    var exited: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (!win32.GetProcessTimes(process, &created, &exited, &kernel, &user).toBool()) return false;
    if (fileTimeValue(created) > created_by) return false;
    var peer: TokenUser = .{};
    if (!peer.load(process)) return false;
    var own: TokenUser = .{};
    if (!own.load(windows.GetCurrentProcess())) return false;
    return win32.EqualSid(peer.sid(), own.sid()) != .FALSE;
}

const TokenUser = struct {
    // TOKEN_USER plus its SID, which is at most 68 bytes.
    buffer: [128]u8 align(@alignOf(win32.SID_AND_ATTRIBUTES)) = undefined,

    fn load(self: *TokenUser, process: windows.HANDLE) bool {
        var token: windows.HANDLE = undefined;
        if (win32.OpenProcessToken(process, win32.TOKEN_QUERY, &token) == .FALSE) return false;
        defer windows.CloseHandle(token);
        var returned: windows.DWORD = 0;
        return win32.GetTokenInformation(token, win32.TokenUser, &self.buffer, self.buffer.len, &returned) != .FALSE;
    }

    fn sid(self: *TokenUser) *anyopaque {
        const user: *const win32.SID_AND_ATTRIBUTES = @ptrCast(&self.buffer);
        return user.Sid;
    }
};

pub const ConnectError = error{ SocketUnavailable, NameTooLong, ConnectionRefused };

/// Connects to the AF_UNIX `path` through Winsock, so the stream supports
/// `receiveTimeout`, which `std.Io.net` does not offer on Windows. Close it
/// with `closeStream`.
pub fn connect(path: []const u8) ConnectError!std.Io.net.Stream {
    try startup();
    var address: ws2_32.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= address.path.len) return error.NameTooLong;
    @memcpy(address.path[0..path.len], path);
    const socket = win32.WSASocketW(
        ws2_32.AF.UNIX,
        ws2_32.SOCK.STREAM,
        0,
        null,
        0,
        win32.WSA_FLAG_OVERLAPPED | win32.WSA_FLAG_NO_HANDLE_INHERIT,
    );
    if (socket == windows.INVALID_HANDLE_VALUE) return error.SocketUnavailable;
    errdefer closeSocket(socket);
    if (win32.connect(socket, @ptrCast(&address), @sizeOf(ws2_32.sockaddr.un)) != 0) return error.ConnectionRefused;
    return .{ .socket = .{ .handle = socket, .address = .{ .ip4 = .loopback(0) } } };
}

pub const ReceiveError = error{ Timeout, ConnectionResetByPeer, ReceiveFailed };

/// Receives at least one byte from a Winsock `socket` within `timeout_ms`.
/// Returns 0 at end of stream.
fn receiveTimeout(socket: windows.HANDLE, destination: []u8, timeout_ms: i64) ReceiveError!usize {
    var poll_fds = [_]win32.WSAPOLLFD{.{ .fd = socket, .events = win32.POLLRDNORM, .revents = 0 }};
    const wait: i32 = @intCast(std.math.clamp(timeout_ms, 0, std.math.maxInt(i32)));
    const ready = win32.WSAPoll(&poll_fds, 1, wait);
    if (ready < 0) return error.ReceiveFailed;
    if (ready == 0) return error.Timeout;
    const want: i32 = @intCast(@min(destination.len, std.math.maxInt(i32)));
    const count = win32.recv(socket, destination.ptr, want, 0);
    if (count < 0) {
        return if (win32.WSAGetLastError() == win32.WSAECONNRESET) error.ConnectionResetByPeer else error.ReceiveFailed;
    }
    return @intCast(count);
}

/// Fills `destination` from a Winsock `socket` within `timeout_ms` in total.
pub fn receiveExactTimeout(
    socket: windows.HANDLE,
    destination: []u8,
    timeout_ms: i64,
) (ReceiveError || error{EndOfStream})!void {
    const deadline = io_mod.milliTimestamp() + timeout_ms;
    var offset: usize = 0;
    while (offset < destination.len) {
        const remaining = deadline - io_mod.milliTimestamp();
        if (remaining <= 0) return error.Timeout;
        const count = try receiveTimeout(socket, destination[offset..], remaining);
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

/// Writes all of `bytes` to a Winsock `socket`.
pub fn sendAll(socket: windows.HANDLE, bytes: []const u8) error{SendFailed}!void {
    var rest = bytes;
    while (rest.len > 0) {
        const chunk: i32 = @intCast(@min(rest.len, std.math.maxInt(i32)));
        const count = win32.send(socket, rest.ptr, chunk, 0);
        if (count <= 0) return error.SendFailed;
        rest = rest[@intCast(count)..];
    }
}

fn startup() error{SocketUnavailable}!void {
    var data: win32.WSADATA = undefined;
    if (win32.WSAStartup(0x0202, &data) != 0) return error.SocketUnavailable;
}

test "Winsock AF_UNIX endpoints name their peer and serve std.Io streams" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A non-ASCII directory proves Winsock reads the path as UTF-8.
    try tmp.dir.createDir(std.testing.io, "h\u{e9}", .default_dir);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "h\u{e9}");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "e.sock" });
    defer alloc.free(path);

    const listener = try listen(path);
    defer closeSocket(listener);
    try std.testing.expectEqual(@as(?std.Io.net.Stream, null), try acceptTimeout(listener, 0));

    // A std.Io client, as the control marker uses.
    const address = try std.Io.net.UnixAddress.init(path);
    var marker = try address.connect(std.testing.io);
    defer marker.close(std.testing.io);
    const marker_peer = (try acceptTimeout(listener, 2_000)) orelse return error.TestUnexpectedResult;
    defer closeStream(marker_peer);
    try std.testing.expectEqual(io_mod.currentProcessId(), try peerProcessId(marker_peer.socket.handle));
    try std.testing.expect(peerMatchesCurrentUser(marker_peer.socket.handle));
    // A process created after the connection holds a reused pid.
    try std.testing.expect(!processUserMatchesCurrent(io_mod.currentProcessId(), 0));
    var write_buffer: [16]u8 = undefined;
    var marker_writer = marker.writer(std.testing.io, &write_buffer);
    try marker_writer.interface.writeAll("ping");
    try marker_writer.interface.flush();
    var ping: [4]u8 = undefined;
    try receiveExactTimeout(marker_peer.socket.handle, &ping, 2_000);
    try std.testing.expectEqualStrings("ping", &ping);

    // A Winsock client, as the terminal client uses, against std.Io reads
    // and writes on the accepted side, as the host uses.
    const client = try connect(path);
    defer closeStream(client);
    const accepted = (try acceptTimeout(listener, 2_000)) orelse return error.TestUnexpectedResult;
    var accepted_open = true;
    defer if (accepted_open) closeStream(accepted);
    // The client names the listening process too.
    try std.testing.expectEqual(io_mod.currentProcessId(), try peerProcessId(client.socket.handle));
    try std.testing.expect(peerMatchesCurrentUser(client.socket.handle));
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.Timeout, receiveTimeout(client.socket.handle, &buffer, 50));
    var host_writer = accepted.writer(std.testing.io, &write_buffer);
    try host_writer.interface.writeAll("pong");
    try host_writer.interface.flush();
    try receiveExactTimeout(client.socket.handle, buffer[0..4], 2_000);
    try std.testing.expectEqualStrings("pong", buffer[0..4]);
    var client_writer = client.writer(std.testing.io, &write_buffer);
    try client_writer.interface.writeAll("data");
    try client_writer.interface.flush();
    var read_buffer: [16]u8 = undefined;
    var host_reader = accepted.reader(std.testing.io, &read_buffer);
    try std.testing.expectEqualStrings("data", try host_reader.interface.take(4));
    closeStream(accepted);
    accepted_open = false;
    try std.testing.expectEqual(@as(usize, 0), try receiveTimeout(client.socket.handle, &buffer, 2_000));
}
