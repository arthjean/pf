//! Reads console input the way pf's Windows TUI backend does and reports the
//! exact bytes each input produced.
//!
//! Usage: vt-input-probe REPORT_PATH LABEL...
//!
//! The probe enables `ENABLE_VIRTUAL_TERMINAL_INPUT`, disables line, echo, and
//! processed input, and turns on bracketed paste and focus reporting. For
//! each label it reads one input group with `ReadConsoleW` (reads separated
//! by less than 150 ms), converts the UTF-16 units to UTF-8, and prints
//! `got N` so a driver script can send the next input. It restores the
//! console modes and writes a JSON report before exiting.

const std = @import("std");
const windows = std.os.windows;
const win32 = @import("windows_console_exports").win32;

const group_gap_ms: u32 = 150;
const first_input_timeout_ms: u32 = 15_000;

const Entry = struct {
    label: []const u8,
    utf16: []const u16,
    utf8: []const u8,
};

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

/// Removes leading records that `ReadConsoleW` would not return as text, as
/// pf's TUI backend does, and reports whether text is pending.
fn textPending(input: windows.HANDLE) !bool {
    var records: [16]win32.INPUT_RECORD = undefined;
    while (true) {
        var count: windows.DWORD = 0;
        if (win32.PeekConsoleInputW(input, &records, records.len, &count) == .FALSE) return error.ReadFailed;
        var skip: windows.DWORD = 0;
        while (skip < count and !isTextRecord(records[skip])) skip += 1;
        if (skip == 0) return count != 0;
        var removed: windows.DWORD = 0;
        if (win32.ReadConsoleInputW(input, &records, skip, &removed) == .FALSE) return error.ReadFailed;
        if (skip < count) return true;
    }
}

fn isTextRecord(record: win32.INPUT_RECORD) bool {
    if (record.EventType != win32.KEY_EVENT) return false;
    const key = record.Event.KeyEvent;
    return key.bKeyDown.toBool() and key.UnicodeChar != 0;
}

fn readGroup(alloc: std.mem.Allocator, input: windows.HANDLE) ![]u16 {
    var units: std.ArrayList(u16) = .empty;
    errdefer units.deinit(alloc);
    var timeout = first_input_timeout_ms;
    while (win32.WaitForSingleObject(input, timeout) == win32.WAIT_OBJECT_0) {
        if (!try textPending(input)) continue;
        var buf: [512]u16 = undefined;
        var read_len: windows.DWORD = 0;
        if (win32.ReadConsoleW(input, &buf, buf.len, &read_len, null) == .FALSE) return error.ReadFailed;
        try units.appendSlice(alloc, buf[0..read_len]);
        timeout = group_gap_ms;
    }
    return units.toOwnedSlice(alloc);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.Io.File.stderr().writeStreamingAll(io, "usage: vt-input-probe REPORT_PATH LABEL...\n") catch {};
        return 2;
    }
    const report_path = std.mem.sliceTo(args[1], 0);

    const input = win32.GetStdHandle(win32.STD_INPUT_HANDLE) orelse return error.NoConsole;
    const output = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE) orelse return error.NoConsole;
    var input_mode: windows.DWORD = 0;
    var output_mode: windows.DWORD = 0;
    if (win32.GetConsoleMode(input, &input_mode) == .FALSE) return error.NotAConsole;
    if (win32.GetConsoleMode(output, &output_mode) == .FALSE) return error.NotAConsole;
    const raw_input = (input_mode & ~(win32.ENABLE_LINE_INPUT | win32.ENABLE_ECHO_INPUT | win32.ENABLE_PROCESSED_INPUT)) |
        win32.ENABLE_VIRTUAL_TERMINAL_INPUT;
    if (win32.SetConsoleMode(input, raw_input) == .FALSE) return error.VirtualTerminalInputUnavailable;
    defer _ = win32.SetConsoleMode(input, input_mode);
    _ = win32.SetConsoleMode(output, output_mode | win32.ENABLE_PROCESSED_OUTPUT | win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    defer _ = win32.SetConsoleMode(output, output_mode);

    // Bracketed paste and focus reports reach the input only after the client
    // asks for them.
    writeOut(io, "\x1b[?2004h\x1b[?1004hready\r\n");
    defer writeOut(io, "\x1b[?1004l\x1b[?2004l");

    var entries: std.ArrayList(Entry) = .empty;
    for (args[2..], 0..) |raw_label, index| {
        const units = try readGroup(arena, input);
        try entries.append(arena, .{
            .label = std.mem.sliceTo(raw_label, 0),
            .utf16 = units,
            .utf8 = try std.unicode.wtf16LeToWtf8Alloc(arena, units),
        });
        writeOut(io, try std.fmt.allocPrint(arena, "got {d}\r\n", .{index}));
    }

    var report: std.Io.Writer.Allocating = .init(arena);
    const writer = &report.writer;
    try writer.writeAll("{\n  \"reader\": \"ReadConsoleW with ENABLE_VIRTUAL_TERMINAL_INPUT, line, echo, and processed input disabled\",\n  \"inputs\": [\n");
    for (entries.items, 0..) |entry, index| {
        try writer.writeAll("    {\"label\": ");
        try std.json.Stringify.value(entry.label, .{}, writer);
        try writer.writeAll(", \"utf8_hex\": \"");
        for (entry.utf8) |byte| try writer.print("{x:0>2}", .{byte});
        try writer.writeAll("\", \"utf16\": [");
        for (entry.utf16, 0..) |unit, unit_index| {
            if (unit_index != 0) try writer.writeAll(", ");
            try writer.print("\"{x:0>4}\"", .{unit});
        }
        try writer.writeAll("], \"text\": ");
        try std.json.Stringify.value(entry.utf8, .{}, writer);
        try writer.writeAll(if (index + 1 == entries.items.len) "}\n" else "},\n");
    }
    try writer.writeAll("  ]\n}\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = report_path, .data = report.written() });
    return 0;
}
