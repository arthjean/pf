//! Win32 functions that `std.os.windows` does not declare. Reference this
//! file only from code selected at comptime for Windows.

const windows = @import("std").os.windows;

pub const FILE_NAME_NORMALIZED: windows.DWORD = 0x0;
pub const VOLUME_NAME_DOS: windows.DWORD = 0x0;

pub extern "kernel32" fn GetFinalPathNameByHandleW(
    hFile: windows.HANDLE,
    lpszFilePath: [*]u16,
    cchFilePath: windows.DWORD,
    dwFlags: windows.DWORD,
) callconv(.winapi) windows.DWORD;

pub const MOVEFILE_REPLACE_EXISTING: windows.DWORD = 0x1;
pub const MOVEFILE_WRITE_THROUGH: windows.DWORD = 0x8;

pub extern "kernel32" fn MoveFileExW(
    lpExistingFileName: [*:0]const u16,
    lpNewFileName: [*:0]const u16,
    dwFlags: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetTempPathW(
    nBufferLength: windows.DWORD,
    lpBuffer: [*]u16,
) callconv(.winapi) windows.DWORD;

pub extern "kernel32" fn CreateHardLinkW(
    lpFileName: [*:0]const u16,
    lpExistingFileName: [*:0]const u16,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub const GENERIC_READ: windows.DWORD = 0x80000000;
pub const FILE_SHARE_READ: windows.DWORD = 0x1;
pub const OPEN_EXISTING: windows.DWORD = 3;
pub const FILE_ATTRIBUTE_NORMAL: windows.DWORD = 0x80;

pub extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;
