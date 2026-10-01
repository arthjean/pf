const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const shell_runtime = @import("../shell_runtime.zig");
const terminal_sequences = @import("terminal.zig");
const theme_protocol = @import("theme_protocol.zig");

pub const Detection = struct {
    light: bool,
    rgb: ?theme_protocol.Rgb,
};

pub const TerminalBackground = theme_protocol.Background;

pub fn explicitThemeOverride() ?bool {
    const override = io_mod.getenv("PF_THEME") orelse return null;
    if (std.ascii.eqlIgnoreCase(override, "light")) return true;
    if (std.ascii.eqlIgnoreCase(override, "dark")) return false;
    return null;
}

/// PF_THEME values other than light/dark name a user theme under
/// `~/.pf/themes/<name>.json`.
pub fn explicitThemeName() ?[]const u8 {
    const override = io_mod.getenv("PF_THEME") orelse return null;
    if (override.len == 0) return null;
    if (explicitThemeOverride() != null) return null;
    return override;
}

pub fn detectTheme(_: std.mem.Allocator, terminal_state: *const shell_runtime.TerminalState) Detection {
    if (explicitThemeOverride()) |light| return .{ .light = light, .rgb = null };
    if (comptime builtin.os.tag == .wasi) return .{ .light = false, .rgb = null };

    // One probe derives both light/dark and the RGB used for bar shading.
    if (queryTerminalBackground(terminal_state)) |info| {
        return .{ .light = info.light, .rgb = info.rgb };
    }

    const colorfgbg = io_mod.getenv("COLORFGBG");
    if (colorfgbg) |value| {
        if (theme_protocol.parseColorFgBgLight(value)) return .{ .light = true, .rgb = null };
    }

    return .{ .light = false, .rgb = null };
}

/// How long the background query waits for the terminal's answer.
const background_query_timeout_ms = 100;

/// Set when a background query goes unanswered, so later probes in this
/// process fall back at once instead of waiting again.
var background_query_unanswered = std.atomic.Value(bool).init(false);

fn queryTerminalBackground(terminal_state: *const shell_runtime.TerminalState) ?TerminalBackground {
    if (background_query_unanswered.load(.monotonic)) return null;
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io_mod.getIo(), terminal_sequences.theme_background_query) catch return null;

    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const started_ms = io_mod.milliTimestamp();
    const deadline_ms = started_ms + background_query_timeout_ms;

    while (len < buf.len) {
        const now_ms = io_mod.milliTimestamp();
        if (now_ms >= deadline_ms) break;

        const remaining_ms: i32 = @intCast(deadline_ms - now_ms);
        const poll = terminal_state.pollInput(remaining_ms) catch return null;
        if (poll.closed() or !poll.readable) break;

        const n = terminal_state.read(buf[len .. len + 1]) catch return null;
        if (n == 0) break;
        len += n;
        if (buf[len - 1] == '\\' or buf[len - 1] == 0x07) break;
    }

    const background = theme_protocol.parseOsc11Response(buf[0..len]);
    if (background == null) {
        background_query_unanswered.store(true, .monotonic);
        debug_trace.logf("theme", "background_query_unanswered elapsed_ms={d}", .{io_mod.milliTimestamp() - started_ms});
    }
    return background;
}
