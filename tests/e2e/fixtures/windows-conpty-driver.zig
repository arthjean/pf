//! Drives one command behind a Windows pseudo console from a timed script,
//! writes the captured output, and exits with the child's exit code.
//!
//! Usage:
//!   conpty-driver --cols N --rows N --script PATH --output PATH
//!                 [--events PATH] [--exit-timeout-ms N] -- COMMAND [ARGS...]
//!
//! Script lines (blank lines and lines starting with `#` are ignored):
//!   sleep MS                      wait MS milliseconds
//!   send JSON                     write the JSON string's bytes to the console input
//!   resize COLS ROWS              resize the pseudo console
//!   wait JSON [MS]                wait until the output after the mark contains the text
//!   wait-run JSON COUNT [MS]      wait for exactly COUNT adjacent copies of the text
//!   echo-latency COUNT [MS]       type COUNT letters one at a time and time each echo
//!   mark LABEL                    record a timestamped event
//!   close [MS]                    close the pseudo console, which sends the child
//!                                 CTRL_CLOSE_EVENT, and wait for it to exit
//!
//! A matched wait moves the mark past the match. Every step, wait, and the
//! child's exit is recorded with its time in the events file (stderr by
//! default). The driver stops writing as soon as the child exits, drains the
//! remaining output, and closes the pseudo console. Exit codes: the child's
//! code, 124 when a wait or the final exit times out, 2 for usage errors.

const std = @import("std");
const console_exports = @import("windows_console_exports");
const conpty = console_exports.conpty;

const Allocator = std.mem.Allocator;
const default_wait_ms: u32 = 5_000;

const Driver = struct {
    alloc: Allocator,
    io: std.Io,
    console: *conpty.PseudoConsole,
    events: std.ArrayList(u8) = .empty,
    started_ns: i96,
    mark: usize = 0,
    exit_code: ?u32 = null,
    timed_out: bool = false,

    fn elapsedMs(self: *Driver) i64 {
        return @intCast(@divTrunc(nowNs(self.io) - self.started_ns, std.time.ns_per_ms));
    }

    fn event(self: *Driver, comptime fmt: []const u8, args: anytype) void {
        self.events.print(self.alloc, "t_ms={d} " ++ fmt ++ "\n", .{self.elapsedMs()} ++ args) catch {};
    }

    /// Returns true once the child has exited, recording its code once.
    fn childExited(self: *Driver) bool {
        if (self.exit_code != null) return true;
        const code = self.console.waitExit(0) orelse return false;
        self.exit_code = code;
        self.event("child_exit code={d}", .{code});
        return true;
    }

    fn sleepMs(self: *Driver, ms: u32) void {
        const deadline = self.elapsedMs() + ms;
        while (self.elapsedMs() < deadline) {
            if (self.childExited()) return;
            self.io.sleep(.fromMilliseconds(@min(5, deadline - self.elapsedMs())), .awake) catch {};
        }
    }

    fn waitFor(self: *Driver, needle: []const u8, run_count: ?usize, timeout_ms: u32) bool {
        const started = self.elapsedMs();
        while (true) {
            const found = if (run_count) |count| self.findRun(needle, count) else self.console.findFrom(self.mark, needle);
            if (found) |end| {
                self.mark = end;
                self.event("wait_matched elapsed_ms={d}", .{self.elapsedMs() - started});
                return true;
            }
            if (self.childExited()) return false;
            if (self.elapsedMs() - started >= timeout_ms) {
                self.event("wait_timeout elapsed_ms={d}", .{self.elapsedMs() - started});
                self.timed_out = true;
                return false;
            }
            self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    /// Finds `count` adjacent copies of `unit` after the mark that are not
    /// part of a longer run, and returns the offset after the run.
    fn findRun(self: *Driver, unit: []const u8, count: usize) ?usize {
        self.console.mutex.lockUncancelable(self.io);
        defer self.console.mutex.unlock(self.io);
        const items = self.console.output.items;
        var index = self.mark;
        while (index < items.len) {
            const start = index + (std.mem.find(u8, items[index..], unit) orelse return null);
            var end = start;
            var copies: usize = 0;
            while (end + unit.len <= items.len and std.mem.eql(u8, items[end..][0..unit.len], unit)) {
                end += unit.len;
                copies += 1;
            }
            // A run touching the end of the capture may still grow.
            if (copies == count and end < items.len) return end;
            index = end;
        }
        return null;
    }

    fn send(self: *Driver, bytes: []const u8) bool {
        if (self.childExited()) return false;
        self.console.write(bytes) catch {
            self.event("send_failed", .{});
            return false;
        };
        return true;
    }

    fn echoLatency(self: *Driver, count: usize, timeout_ms: u32) bool {
        const latencies = self.alloc.alloc(i64, count) catch return false;
        defer self.alloc.free(latencies);
        for (latencies, 0..) |*latency, i| {
            const letter = [1]u8{'a' + @as(u8, @intCast(i % 26))};
            const offset = self.console.outputLen();
            const sent_ns = nowNs(self.io);
            if (!self.send(&letter)) return false;
            while (self.console.findFrom(offset, &letter) == null) {
                if (self.childExited()) return false;
                if (nowNs(self.io) - sent_ns >= @as(i96, timeout_ms) * std.time.ns_per_ms) {
                    self.event("echo_timeout index={d}", .{i});
                    self.timed_out = true;
                    return false;
                }
                self.io.sleep(.fromMicroseconds(200), .awake) catch {};
            }
            latency.* = @intCast(@divTrunc(nowNs(self.io) - sent_ns, std.time.ns_per_us));
        }
        std.mem.sort(i64, latencies, {}, std.sort.asc(i64));
        self.event("echo_latency_us count={d} p50={d} p95={d} max={d}", .{
            count,
            percentile(latencies, 50),
            percentile(latencies, 95),
            latencies[latencies.len - 1],
        });
        self.mark = self.console.outputLen();
        return true;
    }

    /// Runs one script line. Returns false when the script must stop.
    fn step(self: *Driver, line: []const u8) !bool {
        const command_end = std.mem.findScalar(u8, line, ' ') orelse line.len;
        const command = line[0..command_end];
        const rest = std.mem.trim(u8, line[command_end..], " \t");
        self.event("step {s}", .{line});
        if (std.mem.eql(u8, command, "sleep")) {
            self.sleepMs(try std.fmt.parseInt(u32, rest, 10));
            return !self.childExited();
        }
        if (std.mem.eql(u8, command, "send")) {
            const text, _ = try parseJsonString(self.alloc, rest);
            defer self.alloc.free(text);
            return self.send(text);
        }
        if (std.mem.eql(u8, command, "resize")) {
            var fields = std.mem.tokenizeScalar(u8, rest, ' ');
            const cols = try std.fmt.parseInt(u16, fields.next() orelse return error.InvalidScript, 10);
            const rows = try std.fmt.parseInt(u16, fields.next() orelse return error.InvalidScript, 10);
            if (self.childExited()) return false;
            try self.console.resize(.{ .cols = cols, .rows = rows });
            return true;
        }
        if (std.mem.eql(u8, command, "wait")) {
            const text, const tail = try parseJsonString(self.alloc, rest);
            defer self.alloc.free(text);
            const timeout_ms = if (tail.len == 0) default_wait_ms else try std.fmt.parseInt(u32, tail, 10);
            return self.waitFor(text, null, timeout_ms);
        }
        if (std.mem.eql(u8, command, "wait-run")) {
            const text, const tail = try parseJsonString(self.alloc, rest);
            defer self.alloc.free(text);
            var fields = std.mem.tokenizeScalar(u8, tail, ' ');
            const count = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidScript, 10);
            const timeout_ms = if (fields.next()) |value| try std.fmt.parseInt(u32, value, 10) else default_wait_ms;
            return self.waitFor(text, count, timeout_ms);
        }
        if (std.mem.eql(u8, command, "echo-latency")) {
            var fields = std.mem.tokenizeScalar(u8, rest, ' ');
            const count = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidScript, 10);
            if (count == 0) return error.InvalidScript;
            const timeout_ms = if (fields.next()) |value| try std.fmt.parseInt(u32, value, 10) else default_wait_ms;
            return self.echoLatency(count, timeout_ms);
        }
        if (std.mem.eql(u8, command, "close")) {
            const timeout_ms = if (rest.len == 0) default_wait_ms else try std.fmt.parseInt(u32, rest, 10);
            const started = self.elapsedMs();
            self.console.closeConsole();
            self.event("console_closed close_call_ms={d}", .{self.elapsedMs() - started});
            if (self.console.waitExit(timeout_ms)) |code| {
                self.exit_code = code;
                self.event("child_exit code={d} after_close_ms={d}", .{ code, self.elapsedMs() - started });
            } else {
                self.event("close_exit_timeout", .{});
                self.timed_out = true;
            }
            return false;
        }
        if (std.mem.eql(u8, command, "mark")) {
            self.event("mark {s}", .{rest});
            return true;
        }
        return error.InvalidScript;
    }
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
}

fn percentile(sorted: []const i64, pct: usize) i64 {
    const rank = (pct * sorted.len + 99) / 100;
    return sorted[@max(rank, 1) - 1];
}

/// Parses the JSON string at the start of `text` and returns its value
/// (owned by the caller) and the trimmed text after it.
fn parseJsonString(alloc: Allocator, text: []const u8) !struct { []u8, []const u8 } {
    if (text.len == 0 or text[0] != '"') return error.InvalidScript;
    var end: usize = 1;
    while (end < text.len and text[end] != '"') : (end += 1) {
        if (text[end] == '\\') end += 1;
    }
    if (end >= text.len) return error.InvalidScript;
    const value = try std.json.parseFromSliceLeaky([]u8, alloc, text[0 .. end + 1], .{});
    return .{ value, std.mem.trim(u8, text[end + 1 ..], " \t") };
}

/// Joins arguments into one command line with the quoting rules that
/// `CommandLineToArgvW` and the C runtime reverse.
fn joinCommandLine(alloc: Allocator, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (args, 0..) |arg, i| {
        if (i != 0) try out.append(alloc, ' ');
        const needs_quotes = arg.len == 0 or std.mem.findAny(u8, arg, " \t\"") != null;
        if (!needs_quotes) {
            try out.appendSlice(alloc, arg);
            continue;
        }
        try out.append(alloc, '"');
        var backslashes: usize = 0;
        for (arg) |c| {
            if (c == '\\') {
                backslashes += 1;
                continue;
            }
            const repeat = if (c == '"') backslashes * 2 + 1 else backslashes;
            try out.appendNTimes(alloc, '\\', repeat);
            backslashes = 0;
            try out.append(alloc, c);
        }
        try out.appendNTimes(alloc, '\\', backslashes * 2);
        try out.append(alloc, '"');
    }
    return out.toOwnedSlice(alloc);
}

fn usage(io: std.Io, message: []const u8) u8 {
    var buf: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    writer.interface.print("conpty-driver: {s}\n", .{message}) catch {};
    writer.interface.flush() catch {};
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);

    var size: conpty.Size = .{ .cols = 120, .rows = 30 };
    var script_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var events_path: ?[]const u8 = null;
    var exit_timeout_ms: u32 = 10_000;
    var command: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const arg = std.mem.sliceTo(raw_args[i], 0);
        if (std.mem.eql(u8, arg, "--")) {
            for (raw_args[i + 1 ..]) |item| try command.append(arena, std.mem.sliceTo(item, 0));
            break;
        }
        if (i + 1 >= raw_args.len) return usage(io, "missing option value");
        const value = std.mem.sliceTo(raw_args[i + 1], 0);
        i += 1;
        if (std.mem.eql(u8, arg, "--cols")) {
            size.cols = std.fmt.parseInt(u16, value, 10) catch return usage(io, "invalid --cols");
        } else if (std.mem.eql(u8, arg, "--rows")) {
            size.rows = std.fmt.parseInt(u16, value, 10) catch return usage(io, "invalid --rows");
        } else if (std.mem.eql(u8, arg, "--script")) {
            script_path = value;
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = value;
        } else if (std.mem.eql(u8, arg, "--events")) {
            events_path = value;
        } else if (std.mem.eql(u8, arg, "--exit-timeout-ms")) {
            exit_timeout_ms = std.fmt.parseInt(u32, value, 10) catch return usage(io, "invalid --exit-timeout-ms");
        } else return usage(io, "unknown option");
    }
    if (command.items.len == 0) return usage(io, "missing command after --");
    const script = std.Io.Dir.cwd().readFileAlloc(io, script_path orelse return usage(io, "missing --script"), arena, .limited(1 << 20)) catch
        return usage(io, "cannot read --script");
    const output = output_path orelse return usage(io, "missing --output");

    const command_line = try joinCommandLine(arena, command.items);
    // A child inherits the creator's "ignore Ctrl+C" flag, which shells such
    // as MSYS bash set; clear it so Ctrl+C reaches the child as on a desktop.
    _ = console_exports.win32.SetConsoleCtrlHandler(null, .FALSE);
    var driver: Driver = .{
        .alloc = alloc,
        .io = io,
        .console = try conpty.PseudoConsole.spawn(alloc, io, command_line, size),
        .started_ns = nowNs(io),
    };
    defer driver.events.deinit(alloc);
    defer driver.console.deinit();
    driver.event("spawn cols={d} rows={d} command={s}", .{ size.cols, size.rows, command_line });

    var lines = std.mem.splitScalar(u8, script, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const keep_going = driver.step(line) catch |err| {
            driver.event("script_error line={d} err={s}", .{ line_number, @errorName(err) });
            driver.timed_out = true;
            break;
        };
        if (!keep_going) break;
    }

    if (driver.exit_code == null and !driver.timed_out) {
        if (driver.console.waitExit(exit_timeout_ms)) |code| {
            driver.exit_code = code;
            driver.event("child_exit code={d}", .{code});
        } else {
            driver.event("exit_timeout", .{});
            driver.timed_out = true;
        }
    }
    if (driver.exit_code == null) driver.console.terminate(124);
    const drain_started = driver.elapsedMs();
    driver.console.finish();
    driver.event("drained bytes={d} close_ms={d}", .{ driver.console.output.items.len, driver.elapsedMs() - drain_started });

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = driver.console.output.items });
    if (events_path) |path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = driver.events.items });
    } else {
        std.Io.File.stderr().writeStreamingAll(io, driver.events.items) catch {};
    }
    if (driver.timed_out and driver.exit_code == null) return 124;
    const code = driver.exit_code orelse 124;
    // Windows exit codes such as STATUS_CONTROL_C_EXIT do not fit in a u8.
    if (code > std.math.maxInt(u8)) std.os.windows.ntdll.RtlExitUserProcess(code);
    return @intCast(code);
}
