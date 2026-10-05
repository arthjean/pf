const std = @import("std");
const builtin = @import("builtin");

/// Stable local profile identity used only inside private terminal authority:
/// the user id on POSIX and the user's SID on Windows.
pub fn profileUser(buffer: *[64]u8) ?[]const u8 {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        return std.fmt.bufPrint(buffer, "uid-{d}", .{std.c.getuid()}) catch null;
    }
    if (comptime builtin.os.tag == .windows) return windowsUserSid(buffer);
    return null;
}

fn windowsUserSid(buffer: *[64]u8) ?[]const u8 {
    const windows = std.os.windows;
    const win32 = @import("../shared/win32.zig");
    var token: windows.HANDLE = undefined;
    if (win32.OpenProcessToken(windows.GetCurrentProcess(), win32.TOKEN_QUERY, &token) == .FALSE) return null;
    defer windows.CloseHandle(token);
    // TOKEN_USER plus its SID, which is at most 68 bytes.
    var info: [128]u8 align(@alignOf(win32.SID_AND_ATTRIBUTES)) = undefined;
    var returned: windows.DWORD = 0;
    if (win32.GetTokenInformation(token, win32.TokenUser, &info, info.len, &returned) == .FALSE) return null;
    const user: *const win32.SID_AND_ATTRIBUTES = @ptrCast(&info);
    var text: ?[*:0]u8 = null;
    if (win32.ConvertSidToStringSidA(user.Sid, &text) == .FALSE) return null;
    defer _ = win32.LocalFree(text);
    return std.fmt.bufPrint(buffer, "sid-{s}", .{std.mem.span(text.?)}) catch null;
}

test "profile identity is available exactly on supported terminal hosts" {
    var buffer: [64]u8 = undefined;
    const value = profileUser(&buffer);
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        try std.testing.expect(value != null);
        try std.testing.expect(std.mem.startsWith(u8, value.?, "uid-"));
    } else if (comptime builtin.os.tag == .windows) {
        try std.testing.expect(value != null);
        try std.testing.expect(std.mem.startsWith(u8, value.?, "sid-S-1-"));
        var again: [64]u8 = undefined;
        try std.testing.expectEqualStrings(value.?, profileUser(&again).?);
    } else {
        try std.testing.expect(value == null);
    }
}
