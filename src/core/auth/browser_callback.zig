const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const poll_ms: i64 = 100;

/// Listens for an OAuth callback on 127.0.0.1:`port`; port 0 picks a free one.
/// On Windows `std.Io.net` binds every listener with shared access, so another
/// program could bind the same port and receive the redirect. Windows ports,
/// fixed or picked, are therefore bound through Winsock with
/// `SO_EXCLUSIVEADDRUSE`, and a port another program holds returns
/// `error.AddressInUse`.
pub fn listenLoopback(port: u16) !std.Io.net.Server {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    if (comptime builtin.os.tag == .windows) return listenExclusiveWindows(address);
    return address.listen(io_mod.getIo(), .{ .reuse_address = true });
}

/// Listens on a Windows loopback `address`, IPv4 or IPv6, with
/// `SO_EXCLUSIVEADDRUSE`. Port 0 picks a free port, which the returned
/// server's address names. A port another program holds returns
/// `error.AddressInUse`, and a host without that address family returns
/// `error.AddressFamilyUnsupported` or `error.AddressUnavailable`.
pub fn listenExclusiveWindows(address: std.Io.net.IpAddress) error{
    OAuthCallbackListenerFailed,
    AddressInUse,
    AddressFamilyUnsupported,
    AddressUnavailable,
}!std.Io.net.Server {
    const win32 = @import("../shared/win32.zig");
    const ws2_32 = std.os.windows.ws2_32;
    var wsa_data: win32.WSADATA = undefined;
    if (win32.WSAStartup(0x0202, &wsa_data) != 0) return error.OAuthCallbackListenerFailed;
    const family: i32 = switch (address) {
        .ip4 => ws2_32.AF.INET,
        .ip6 => ws2_32.AF.INET6,
    };
    const socket = win32.WSASocketW(
        family,
        ws2_32.SOCK.STREAM,
        ws2_32.IPPROTO.TCP,
        null,
        0,
        win32.WSA_FLAG_OVERLAPPED | win32.WSA_FLAG_NO_HANDLE_INHERIT,
    );
    if (socket == std.os.windows.INVALID_HANDLE_VALUE) {
        return if (win32.WSAGetLastError() == win32.WSAEAFNOSUPPORT)
            error.AddressFamilyUnsupported
        else
            error.OAuthCallbackListenerFailed;
    }
    errdefer _ = win32.closesocket(socket);
    const enable: i32 = 1;
    if (win32.setsockopt(socket, ws2_32.SOL.SOCKET, win32.SO_EXCLUSIVEADDRUSE, std.mem.asBytes(&enable), @sizeOf(i32)) != 0) {
        return error.OAuthCallbackListenerFailed;
    }
    const bind_result = switch (address) {
        .ip4 => |value| ip4: {
            const sockaddr: ws2_32.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, value.port),
                .addr = @bitCast(value.bytes),
            };
            break :ip4 win32.bind(socket, @ptrCast(&sockaddr), @sizeOf(ws2_32.sockaddr.in));
        },
        .ip6 => |value| ip6: {
            const sockaddr: ws2_32.sockaddr.in6 = .{
                .port = std.mem.nativeToBig(u16, value.port),
                .flowinfo = value.flow,
                .addr = value.bytes,
                .scope_id = value.interface.index,
            };
            break :ip6 win32.bind(socket, @ptrCast(&sockaddr), @sizeOf(ws2_32.sockaddr.in6));
        },
    };
    if (bind_result != 0) {
        return switch (win32.WSAGetLastError()) {
            // EACCES: the holder bound with SO_EXCLUSIVEADDRUSE.
            win32.WSAEADDRINUSE, win32.WSAEACCES => error.AddressInUse,
            win32.WSAEADDRNOTAVAIL => error.AddressUnavailable,
            win32.WSAEAFNOSUPPORT => error.AddressFamilyUnsupported,
            else => error.OAuthCallbackListenerFailed,
        };
    }
    if (win32.listen(socket, std.Io.net.default_kernel_backlog) != 0) return error.OAuthCallbackListenerFailed;
    var bound = address;
    if (address.getPort() == 0) {
        var storage: ws2_32.sockaddr.in6 = undefined;
        var length: i32 = @sizeOf(ws2_32.sockaddr.in6);
        if (win32.getsockname(socket, @ptrCast(&storage), &length) != 0) return error.OAuthCallbackListenerFailed;
        // The port sits at the same offset in both address families.
        bound.setPort(std.mem.bigToNative(u16, storage.port));
    }
    return .{
        .socket = .{ .handle = socket, .address = bound },
        .options = .{ .mode = .stream, .protocol = .tcp },
    };
}

const silence_ms: i64 = 250;
const max_accepts_per_poll: usize = 16;

pub const Response = enum {
    ok,
    failed,
    unrelated,
};

pub fn ParseResult(comptime Callback: type) type {
    return union(enum) {
        accepted: Callback,
        unrelated,
        failed: anyerror,
    };
}

pub fn Accepted(comptime Callback: type) type {
    return struct {
        stream: std.Io.net.Stream,
        callback: Callback,
        cors_origin: ?[]const u8 = null,

        pub fn deinit(self: *@This()) void {
            self.stream.close(io_mod.getIo());
            self.* = undefined;
        }

        pub fn respond(self: *@This(), outcome: Response) !void {
            try writeResponse(self.stream, outcome, self.cors_origin);
        }
    };
}

/// Drains the listener's queued connections and returns the first callback the
/// provider accepts, or null when no callback is ready during this poll.
///
/// Browsers may open an idle speculative connection or request unrelated paths
/// before sending the redirect. Those connections must not close the listener
/// or hold the real callback in the accept queue. Provider-specific parsing and
/// error classification stay in the adapter passed by the caller.
pub fn await(
    comptime Callback: type,
    comptime parse: fn (?*anyopaque, Allocator, []const u8) ParseResult(Callback),
    alloc: Allocator,
    listener: *std.Io.net.Server,
    parser_context: ?*anyopaque,
    cancel_flag: *std.atomic.Value(bool),
    allowed_cors_origin: ?[]const u8,
) !?Accepted(Callback) {
    return await_request(Callback, parse, alloc, listener, parser_context, .{ .caller = cancel_flag }, allowed_cors_origin, null);
}

/// Accept a browser form POST from one exact HTTPS bridge origin.
pub fn await_form(
    comptime Callback: type,
    comptime parse: fn (?*anyopaque, Allocator, []const u8) ParseResult(Callback),
    alloc: Allocator,
    listener: *std.Io.net.Server,
    parser_context: ?*anyopaque,
    cancel_flag: ?*const std.atomic.Value(bool),
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
    origin: []const u8,
) !?Accepted(Callback) {
    return await_request(Callback, parse, alloc, listener, parser_context, .{ .caller = cancel_flag, .runtime = lifecycle_cancel_flag }, null, origin);
}

/// Like `await`, for a caller that carries its own cancel flag and the
/// runtime's, either of which may be absent.
pub fn awaitCancellable(
    comptime Callback: type,
    comptime parse: fn (?*anyopaque, Allocator, []const u8) ParseResult(Callback),
    alloc: Allocator,
    listener: *std.Io.net.Server,
    parser_context: ?*anyopaque,
    cancel_flag: ?*const std.atomic.Value(bool),
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
) !?Accepted(Callback) {
    return await_request(Callback, parse, alloc, listener, parser_context, .{ .caller = cancel_flag, .runtime = lifecycle_cancel_flag }, null, null);
}

const Cancellation = struct {
    caller: ?*const std.atomic.Value(bool) = null,
    runtime: ?*const std.atomic.Value(bool) = null,

    fn cancelled(self: Cancellation) bool {
        return (if (self.caller) |flag| flag.load(.acquire) else false) or
            (if (self.runtime) |flag| flag.load(.acquire) else false);
    }
};

fn await_request(
    comptime Callback: type,
    comptime parse: fn (?*anyopaque, Allocator, []const u8) ParseResult(Callback),
    alloc: Allocator,
    listener: *std.Io.net.Server,
    parser_context: ?*anyopaque,
    cancel_flag: Cancellation,
    allowed_cors_origin: ?[]const u8,
    form_origin: ?[]const u8,
) !?Accepted(Callback) {
    var accepts: usize = 0;
    while (accepts < max_accepts_per_poll) : (accepts += 1) {
        var stream = (try acceptWithin(listener, cancel_flag)) orelse return null;
        var handed_off = false;
        defer if (!handed_off) stream.close(io_mod.getIo());

        const maybe_request = readRequest(alloc, stream, cancel_flag, allowed_cors_origin, form_origin, listener.socket.address.getPort()) catch |err| switch (err) {
            error.Cancelled => return err,
            error.InvalidOAuthCallbackRequest, error.OAuthCallbackRequestTooLarge => {
                writeResponse(stream, .unrelated, null) catch {};
                continue;
            },
            else => return err,
        };
        var request = maybe_request orelse continue;
        defer request.deinit(alloc);
        switch (request.kind) {
            .preflight => {
                writePreflightResponse(stream, allowed_cors_origin.?) catch {};
                continue;
            },
            .unrelated => {
                writeResponse(stream, .unrelated, null) catch {};
                continue;
            },
            .callback => {},
        }

        const parsed = parse(parser_context, alloc, request.target);
        switch (parsed) {
            .accepted => |callback| {
                handed_off = true;
                return .{
                    .stream = stream,
                    .callback = callback,
                    .cors_origin = request.cors_origin,
                };
            },
            .unrelated => {
                writeResponse(stream, .unrelated, request.cors_origin) catch {};
                continue;
            },
            .failed => |err| {
                writeResponse(stream, .failed, request.cors_origin) catch {};
                return err;
            },
        }
    }
    return null;
}

const RequestKind = enum {
    callback,
    preflight,
    unrelated,
};

const Request = struct {
    kind: RequestKind,
    target: []u8,
    cors_origin: ?[]const u8 = null,

    fn deinit(self: *Request, alloc: Allocator) void {
        alloc.free(self.target);
        self.* = undefined;
    }
};

const AcceptEvent = union(enum) {
    accept: std.Io.net.Server.AcceptError!std.Io.net.Stream,
    tick: std.Io.Cancelable!void,
};

/// Waits one poll interval for a connection through `std.Io` accept, and
/// returns null when none arrived or the peer aborted it.
fn acceptWithin(
    listener: *std.Io.net.Server,
    cancel_flag: Cancellation,
) !?std.Io.net.Stream {
    if (cancel_flag.cancelled()) return error.Cancelled;
    const zio = io_mod.getIo();
    var buffer: [2]AcceptEvent = undefined;
    var select: std.Io.Select(AcceptEvent) = .init(zio, &buffer);
    try select.concurrent(.accept, acceptOne, .{listener});
    select.concurrent(.tick, sleepMs, .{poll_ms}) catch |err| {
        if (finishAccept(&select, null)) |stream| stream.close(zio);
        return err;
    };
    var accepted: ?std.Io.net.Stream = null;
    var accept_err: ?std.Io.net.Server.AcceptError = null;
    switch (try select.await()) {
        .accept => |result| {
            if (result) |stream| accepted = stream else |err| accept_err = err;
        },
        .tick => {},
    }
    // An accept that completes while the tick is canceled still counts.
    accepted = finishAccept(&select, accepted);
    if (cancel_flag.cancelled()) {
        if (accepted) |stream| stream.close(zio);
        return error.Cancelled;
    }
    if (accepted) |stream| return stream;
    if (accept_err) |err| switch (err) {
        error.ConnectionAborted, error.WouldBlock => return null,
        else => return err,
    };
    return null;
}

fn acceptOne(listener: *std.Io.net.Server) std.Io.net.Server.AcceptError!std.Io.net.Stream {
    return listener.accept(io_mod.getIo());
}

fn sleepMs(ms: i64) std.Io.Cancelable!void {
    return io_mod.getIo().sleep(.fromMilliseconds(ms), .awake);
}

/// Cancels the remaining accept tasks. Keeps `accepted`, or the first stream
/// a canceled accept still produced, and closes any other.
fn finishAccept(select: *std.Io.Select(AcceptEvent), accepted: ?std.Io.net.Stream) ?std.Io.net.Stream {
    var kept = accepted;
    while (select.cancel()) |event| switch (event) {
        .accept => |result| {
            const stream = result catch continue;
            if (kept == null) kept = stream else stream.close(io_mod.getIo());
        },
        .tick => {},
    };
    return kept;
}

const FillEvent = union(enum) {
    fill: std.Io.Reader.Error!void,
    tick: std.Io.Cancelable!void,
};

/// Waits until the reader has buffered bytes or reached end of stream, using a
/// `std.Io` receive bounded by `deadline_ms`. Returns false when the deadline
/// passes first.
fn requestReadable(
    reader: *std.Io.Reader,
    cancel_flag: Cancellation,
    deadline_ms: i64,
) !bool {
    if (cancel_flag.cancelled()) return error.Cancelled;
    const zio = io_mod.getIo();
    var buffer: [2]FillEvent = undefined;
    var select: std.Io.Select(FillEvent) = .init(zio, &buffer);
    try select.concurrent(.fill, fillMore, .{reader});
    while (true) {
        const remaining_ms = deadline_ms - io_mod.milliTimestamp();
        if (remaining_ms <= 0) {
            select.cancelDiscard();
            return reader.bufferedLen() != 0;
        }
        select.concurrent(.tick, sleepMs, .{@min(remaining_ms, poll_ms)}) catch |err| {
            select.cancelDiscard();
            return err;
        };
        switch (try select.await()) {
            // The caller's next take observes end of stream or the read error.
            .fill => {
                select.cancelDiscard();
                return true;
            },
            .tick => if (cancel_flag.cancelled()) {
                select.cancelDiscard();
                return error.Cancelled;
            },
        }
    }
}

fn fillMore(reader: *std.Io.Reader) std.Io.Reader.Error!void {
    return reader.fillMore();
}

/// Reads one bounded HTTP request, or returns null when the connection remains
/// silent for the speculative-preconnect budget.
fn readRequest(
    alloc: Allocator,
    stream: std.Io.net.Stream,
    cancel_flag: Cancellation,
    allowed_cors_origin: ?[]const u8,
    form_origin: ?[]const u8,
    port: u16,
) !?Request {
    const deadline_ms = io_mod.milliTimestamp() + silence_ms;
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &socket_buffer);
    var request_bytes: [16 * 1024]u8 = undefined;
    var request_len: usize = 0;
    var found_terminator = false;
    while (request_len < request_bytes.len) {
        if (reader.interface.bufferedLen() == 0 and
            !try requestReadable(&reader.interface, cancel_flag, deadline_ms))
        {
            return null;
        }
        request_bytes[request_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return if (request_len == 0)
                null
            else
                error.InvalidOAuthCallbackRequest,
            error.ReadFailed => switch (reader.err orelse return error.ReadFailed) {
                error.ConnectionResetByPeer => return null,
                // Zig reports every Windows receive failure, a reset
                // included, as Unexpected.
                error.Unexpected => if (comptime builtin.os.tag == .windows) return null else return error.Unexpected,
                else => |read_err| return read_err,
            },
        };
        request_len += 1;
        if (std.mem.endsWith(u8, request_bytes[0..request_len], "\r\n\r\n")) {
            found_terminator = true;
            break;
        }
    }
    if (!found_terminator) return error.OAuthCallbackRequestTooLarge;
    const line_end = std.mem.find(u8, request_bytes[0..request_len], "\r\n") orelse
        return error.InvalidOAuthCallbackRequest;
    const request_line = request_bytes[0..line_end];
    const method_end = std.mem.findScalar(u8, request_line, ' ') orelse
        return error.InvalidOAuthCallbackRequest;
    const target_start = method_end + 1;
    const target_end = std.mem.findScalarPos(u8, request_line, target_start, ' ') orelse
        return error.InvalidOAuthCallbackRequest;
    const method = request_line[0..method_end];
    const target = request_line[target_start..target_end];
    const origin = requestHeaderValue(request_bytes[line_end + 2 .. request_len], "origin");
    if (form_origin) |required_origin| {
        var host_buf: [32]u8 = undefined;
        const expected_host = try std.fmt.bufPrint(&host_buf, "127.0.0.1:{d}", .{port});
        const headers = request_bytes[line_end + 2 .. request_len];
        const content_type = unique_header(headers, "content-type") orelse return error.InvalidOAuthCallbackRequest;
        const host_header = unique_header(headers, "host") orelse return error.InvalidOAuthCallbackRequest;
        const form_request_origin = unique_header(headers, "origin") orelse return error.InvalidOAuthCallbackRequest;
        if (!std.mem.eql(u8, method, "POST") or !std.mem.eql(u8, target, "/slack/oauth/callback") or
            !std.mem.eql(u8, form_request_origin, required_origin) or !std.mem.eql(u8, host_header, expected_host) or
            !std.mem.eql(u8, std.mem.trim(u8, std.mem.sliceTo(content_type, ';'), " "), "application/x-www-form-urlencoded") or
            requestHeaderValue(headers, "transfer-encoding") != null) return error.InvalidOAuthCallbackRequest;
        const length_header = unique_header(headers, "content-length") orelse return error.InvalidOAuthCallbackRequest;
        const length = std.fmt.parseInt(usize, length_header, 10) catch return error.InvalidOAuthCallbackRequest;
        if (length == 0 or length > 8192) return error.OAuthCallbackRequestTooLarge;
        const body = try alloc.alloc(u8, length);
        defer alloc.free(body);
        for (body) |*byte| {
            if (reader.interface.bufferedLen() == 0 and !try requestReadable(&reader.interface, cancel_flag, deadline_ms)) return null;
            byte.* = reader.interface.takeByte() catch return error.InvalidOAuthCallbackRequest;
        }
        return .{ .kind = .callback, .target = try alloc.dupe(u8, body) };
    }
    const cors_origin = allowed_cors_origin orelse {
        if (!std.mem.eql(u8, method, "GET")) return error.InvalidOAuthCallbackRequest;
        return .{
            .kind = .callback,
            .target = try alloc.dupe(u8, target),
        };
    };
    const origin_allowed = if (origin) |value| std.mem.eql(u8, value, cors_origin) else false;

    if (std.mem.eql(u8, method, "OPTIONS")) {
        const requested_method = requestHeaderValue(
            request_bytes[line_end + 2 .. request_len],
            "access-control-request-method",
        );
        const callback_path = std.mem.eql(u8, target, "/callback") or
            std.mem.startsWith(u8, target, "/callback?");
        const valid = origin_allowed and
            requested_method != null and
            std.ascii.eqlIgnoreCase(requested_method.?, "GET") and
            callback_path;
        return .{
            .kind = if (valid) .preflight else .unrelated,
            .target = try alloc.dupe(u8, target),
        };
    }
    if (!std.mem.eql(u8, method, "GET")) return error.InvalidOAuthCallbackRequest;
    return .{
        .kind = if (origin == null or origin_allowed) .callback else .unrelated,
        .target = try alloc.dupe(u8, target),
        .cors_origin = if (origin_allowed) cors_origin else null,
    };
}

fn unique_header(headers: []const u8, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        if (result != null) return null;
        result = std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return result;
}

fn requestHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn callbackPage(comptime title: []const u8, comptime detail: []const u8) []const u8 {
    return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<title>pf</title><style>" ++
        ":root{color-scheme:light dark}" ++
        "body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;" ++
        "background:#fff;color:#111;" ++
        "font:15px/1.6 ui-sans-serif,-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif}" ++
        "@media(prefers-color-scheme:dark){body{background:#0b0b0c;color:#f4f4f5}}" ++
        "main{text-align:center;padding:2rem;max-width:26rem}" ++
        "h1{margin:0 0 .5rem;font-size:1.125rem;font-weight:600;letter-spacing:-.01em}" ++
        "p{margin:0;font-size:.875rem;opacity:.62}" ++
        "</style></head><body><main><h1>" ++ title ++ "</h1><p>" ++ detail ++ "</p></main></body></html>";
}

pub fn writeResponse(stream: std.Io.net.Stream, outcome: Response, cors_origin: ?[]const u8) !void {
    const reply: struct { status: []const u8, body: []const u8 } = switch (outcome) {
        .ok => .{
            .status = "200 OK",
            .body = comptime callbackPage(
                "Authorization complete",
                "Returning you to pf. You can close this tab.",
            ),
        },
        .failed => .{
            .status = "400 Bad Request",
            .body = comptime callbackPage(
                "Authorization failed",
                "Return to pf for details.",
            ),
        },
        .unrelated => .{
            .status = "404 Not Found",
            .body = "<!doctype html><title>Not found</title>Not found.",
        },
    };
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.print("HTTP/1.1 {s}\r\n", .{reply.status});
    if (cors_origin) |origin| {
        try writer.interface.print("Access-Control-Allow-Origin: {s}\r\nVary: Origin\r\n", .{origin});
    }
    try writer.interface.print(
        "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ reply.body.len, reply.body },
    );
    try writer.interface.flush();
}

fn writePreflightResponse(stream: std.Io.net.Stream, origin: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.print(
        "HTTP/1.1 204 No Content\r\n" ++
            "Access-Control-Allow-Origin: {s}\r\n" ++
            "Access-Control-Allow-Methods: GET\r\n",
        .{origin},
    );
    try writer.interface.writeAll(
        "Access-Control-Allow-Private-Network: true\r\n" ++
            "Vary: Origin, Access-Control-Request-Method, Access-Control-Request-Private-Network\r\n" ++
            "Content-Length: 0\r\nConnection: close\r\n\r\n",
    );
    try writer.interface.flush();
}

fn bindTestListener() !std.Io.net.Server {
    return listenLoopback(0);
}

test "loopback callback listener reports a fixed port another program holds" {
    const zio = io_mod.getIo();
    var probe = try listenLoopback(0);
    const port = probe.socket.address.getPort();
    probe.deinit(zio);

    var listener = try listenLoopback(port);
    // The fixed port still accepts and reads like any listener.
    const client = try listener.socket.address.connect(zio, .{ .mode = .stream });
    defer client.close(zio);
    var client_writer = client.writer(zio, &.{});
    try client_writer.interface.writeAll("ping");
    const accepted = try listener.accept(zio);
    defer accepted.close(zio);
    var buffer: [4]u8 = undefined;
    var reader = accepted.reader(zio, &buffer);
    try std.testing.expectEqualStrings("ping", try reader.interface.take(4));
    listener.deinit(zio);

    // Another program's listener, on a port no connection has used.
    const holder_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var holder = try holder_address.listen(zio, .{});
    defer holder.deinit(zio);
    try std.testing.expectError(error.AddressInUse, listenLoopback(holder.socket.address.getPort()));
}

test "loopback callback listener holds a picked Windows port exclusively" {
    // Only Windows binds listeners with shared access by default.
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var listener = try listenLoopback(0);
    defer listener.deinit(zio);
    const port = listener.socket.address.getPort();
    try std.testing.expect(port != 0);

    // A shared bind by another program cannot take the picked port.
    const intruder_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    if (intruder_address.listen(zio, .{ .reuse_address = true })) |intruder| {
        var bound = intruder;
        bound.deinit(zio);
        return error.TestUnexpectedResult;
    } else |_| {}

    // The picked port accepts like any listener.
    const client = try listener.socket.address.connect(zio, .{ .mode = .stream });
    defer client.close(zio);
    const accepted = try listener.accept(zio);
    accepted.close(zio);
}

const TestCallback = struct {
    code: []const u8,
};

fn parseTestCallback(
    _: ?*anyopaque,
    _: Allocator,
    target: []const u8,
) ParseResult(TestCallback) {
    if (std.mem.eql(u8, target, "/callback?code=granted")) {
        return .{ .accepted = .{ .code = "granted" } };
    }
    return .unrelated;
}

const CallbackProbe = struct {
    port: u16,
    requests: []const []const u8,

    fn run(self: CallbackProbe) void {
        const io = io_mod.getIo();
        for (self.requests) |request| {
            var address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch return;
            var stream = address.connect(io, .{ .mode = .stream }) catch return;
            defer stream.close(io);
            if (request.len == 0) continue;
            var buffer: [512]u8 = undefined;
            var writer = stream.writer(io, &buffer);
            writer.interface.writeAll(request) catch return;
            writer.interface.flush() catch return;
            var read_buffer: [512]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            _ = reader.interface.discardRemaining() catch {};
        }
    }
};

const ResetPreconnectProbe = struct {
    port: u16,
    request: []const u8,
    hold_ms: u64,
    connected: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *ResetPreconnectProbe) void {
        const io = io_mod.getIo();
        var address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch
            return self.finish(true);
        {
            var reset_stream = address.connect(io, .{ .mode = .stream }) catch
                return self.finish(true);
            defer reset_stream.close(io);
            io_mod.testResetOnClose(reset_stream.socket.handle) catch return self.finish(true);
            self.finish(false);
            io_mod.sleep(self.hold_ms * std.time.ns_per_ms);
        }

        var stream = address.connect(io, .{ .mode = .stream }) catch return;
        defer stream.close(io);
        var buffer: [512]u8 = undefined;
        var writer = stream.writer(io, &buffer);
        writer.interface.writeAll(self.request) catch return;
        writer.interface.flush() catch return;
    }

    fn finish(self: *ResetPreconnectProbe, failed: bool) void {
        self.failed.store(failed, .release);
        self.connected.store(true, .release);
    }

    fn waitUntilConnected(self: *ResetPreconnectProbe) !void {
        while (!self.connected.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
        try std.testing.expect(!self.failed.load(.acquire));
    }
};

const HeldPreconnectProbe = struct {
    port: u16,
    request: []const u8 = "",
    delivered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *HeldPreconnectProbe) void {
        const io = io_mod.getIo();
        var address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch
            return self.finish(true);
        var idle = address.connect(io, .{ .mode = .stream }) catch
            return self.finish(true);
        defer idle.close(io);
        if (self.request.len == 0) {
            self.finish(false);
            return self.wait();
        }
        var stream = address.connect(io, .{ .mode = .stream }) catch
            return self.finish(true);
        defer stream.close(io);
        var buffer: [512]u8 = undefined;
        var writer = stream.writer(io, &buffer);
        writer.interface.writeAll(self.request) catch return self.finish(true);
        writer.interface.flush() catch return self.finish(true);
        self.finish(false);
        self.wait();
    }

    fn finish(self: *HeldPreconnectProbe, failed: bool) void {
        self.failed.store(failed, .release);
        self.delivered.store(true, .release);
    }

    fn wait(self: *HeldPreconnectProbe) void {
        while (!self.release.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    }

    fn waitUntilDelivered(self: *HeldPreconnectProbe) !void {
        while (!self.delivered.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
        try std.testing.expect(!self.failed.load(.acquire));
    }
};

test "browser callback outruns an idle preconnect held open" {
    var listener = try bindTestListener();
    defer listener.deinit(io_mod.getIo());

    var probe = HeldPreconnectProbe{
        .port = listener.socket.address.getPort(),
        .request = "GET /callback?code=granted HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{}, HeldPreconnectProbe.run, .{&probe});
    defer thread.join();
    defer probe.release.store(true, .release);
    try probe.waitUntilDelivered();

    var cancel_flag = std.atomic.Value(bool).init(false);
    const started_ms = io_mod.milliTimestamp();
    var accepted = (try await(
        TestCallback,
        parseTestCallback,
        std.testing.allocator,
        &listener,
        null,
        &cancel_flag,
        null,
    )) orelse return error.CallbackNeverArrived;
    defer accepted.deinit();
    try std.testing.expectEqualStrings("granted", accepted.callback.code);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1_000);
}

test "browser callback cancels while an idle preconnect is open" {
    var listener = try bindTestListener();
    defer listener.deinit(io_mod.getIo());

    var probe = HeldPreconnectProbe{ .port = listener.socket.address.getPort() };
    const thread = try std.Thread.spawn(.{}, HeldPreconnectProbe.run, .{&probe});
    defer thread.join();
    defer probe.release.store(true, .release);
    try probe.waitUntilDelivered();

    var cancel_flag = std.atomic.Value(bool).init(false);
    const Flip = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };
    const flip = try std.Thread.spawn(.{}, Flip.run, .{&cancel_flag});
    defer flip.join();

    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.Cancelled,
        await(
            TestCallback,
            parseTestCallback,
            std.testing.allocator,
            &listener,
            null,
            &cancel_flag,
            null,
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1_000);
}

test "browser callback survives unrelated requests before the redirect" {
    var listener = try bindTestListener();
    defer listener.deinit(io_mod.getIo());
    const port = listener.socket.address.getPort();

    const requests = [_][]const u8{
        "",
        "GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "GET /unrelated?code=nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "GET /callback?code=granted HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    };
    const probe = CallbackProbe{ .port = port, .requests = &requests };
    const thread = try std.Thread.spawn(.{}, CallbackProbe.run, .{probe});
    defer thread.join();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var accepted = (try await(
        TestCallback,
        parseTestCallback,
        std.testing.allocator,
        &listener,
        null,
        &cancel_flag,
        null,
    )) orelse return error.CallbackNeverArrived;
    defer accepted.deinit();
    try accepted.respond(.ok);
    try std.testing.expectEqualStrings("granted", accepted.callback.code);
}

fn expectResetPreconnectSurvives(hold_ms: u64) !void {
    var listener = try bindTestListener();
    defer listener.deinit(io_mod.getIo());

    var probe = ResetPreconnectProbe{
        .port = listener.socket.address.getPort(),
        .request = "GET /callback?code=granted HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        .hold_ms = hold_ms,
    };
    const thread = try std.Thread.spawn(.{}, ResetPreconnectProbe.run, .{&probe});
    defer thread.join();
    try probe.waitUntilConnected();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var accepted = (try await(
        TestCallback,
        parseTestCallback,
        std.testing.allocator,
        &listener,
        null,
        &cancel_flag,
        null,
    )) orelse return error.CallbackNeverArrived;
    defer accepted.deinit();
    try std.testing.expectEqualStrings("granted", accepted.callback.code);
}

test "browser callback survives a reset preconnect before the redirect" {
    try expectResetPreconnectSurvives(100);
}

test "browser callback survives a reset queued before accept" {
    try expectResetPreconnectSurvives(0);
}

const CorsCallbackProbe = struct {
    port: u16,
    preflight_response: [1024]u8 = undefined,
    preflight_len: usize = 0,
    callback_response: [4096]u8 = undefined,
    callback_len: usize = 0,
    failed: bool = false,

    fn run(self: *CorsCallbackProbe) void {
        self.preflight_len = self.exchange(
            "OPTIONS /callback HTTP/1.1\r\n" ++
                "Host: 127.0.0.1\r\n" ++
                "Origin: https://accounts.x.ai\r\n" ++
                "Access-Control-Request-Method: GET\r\n" ++
                "Access-Control-Request-Private-Network: true\r\n\r\n",
            &self.preflight_response,
        ) orelse return self.markFailed();
        self.callback_len = self.exchange(
            "GET /callback?code=granted HTTP/1.1\r\n" ++
                "Host: 127.0.0.1\r\n" ++
                "Origin: https://accounts.x.ai\r\n\r\n",
            &self.callback_response,
        ) orelse return self.markFailed();
    }

    fn exchange(self: *CorsCallbackProbe, request: []const u8, response: []u8) ?usize {
        const io = io_mod.getIo();
        var address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch return null;
        var stream = address.connect(io, .{ .mode = .stream }) catch return null;
        defer stream.close(io);
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        writer.interface.writeAll(request) catch return null;
        writer.interface.flush() catch return null;

        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var total: usize = 0;
        while (total < response.len) {
            const read_len = reader.interface.readSliceShort(response[total..]) catch return null;
            if (read_len == 0) break;
            total += read_len;
        }
        return total;
    }

    fn markFailed(self: *CorsCallbackProbe) void {
        self.failed = true;
    }
};

test "browser callback permits the xAI CORS private-network preflight" {
    var listener = try bindTestListener();
    defer listener.deinit(io_mod.getIo());

    var probe = CorsCallbackProbe{ .port = listener.socket.address.getPort() };
    const thread = try std.Thread.spawn(.{}, CorsCallbackProbe.run, .{&probe});

    var cancel_flag = std.atomic.Value(bool).init(false);
    var accepted = (try await(
        TestCallback,
        parseTestCallback,
        std.testing.allocator,
        &listener,
        null,
        &cancel_flag,
        "https://accounts.x.ai",
    )) orelse return error.CallbackNeverArrived;
    accepted.respond(.ok) catch |err| {
        accepted.deinit();
        thread.join();
        return err;
    };
    accepted.deinit();
    thread.join();

    try std.testing.expect(!probe.failed);
    const preflight = probe.preflight_response[0..probe.preflight_len];
    try std.testing.expect(std.mem.startsWith(u8, preflight, "HTTP/1.1 204 No Content\r\n"));
    try std.testing.expect(std.mem.find(u8, preflight, "Access-Control-Allow-Origin: https://accounts.x.ai\r\n") != null);
    try std.testing.expect(std.mem.find(u8, preflight, "Access-Control-Allow-Methods: GET\r\n") != null);
    try std.testing.expect(std.mem.find(u8, preflight, "Access-Control-Allow-Private-Network: true\r\n") != null);
    const callback = probe.callback_response[0..probe.callback_len];
    try std.testing.expect(std.mem.startsWith(u8, callback, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.find(u8, callback, "Access-Control-Allow-Origin: https://accounts.x.ai\r\n") != null);
    try std.testing.expect(std.mem.find(u8, callback, "Content-Type: text/html; charset=utf-8\r\n") != null);
    try std.testing.expect(std.mem.find(u8, callback, "<h1>Authorization complete</h1>") != null);
    try std.testing.expect(std.mem.find(u8, callback, "prefers-color-scheme:dark") != null);
}
