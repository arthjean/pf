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

pub extern "kernel32" fn GetProcessId(
    Process: windows.HANDLE,
) callconv(.winapi) windows.DWORD;

pub const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: windows.DWORD,
    PageFaultCount: windows.DWORD,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
};

pub extern "kernel32" fn K32GetProcessMemoryInfo(
    Process: windows.HANDLE,
    ppsmemCounters: *PROCESS_MEMORY_COUNTERS,
    cb: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetProcessHandleCount(
    hProcess: windows.HANDLE,
    pdwHandleCount: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn TerminateProcess(
    hProcess: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

pub const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x1000;

pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwProcessId: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

pub const STILL_ACTIVE: windows.DWORD = 259;

pub extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

// Console

pub const STD_INPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -11));

pub const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x1;
pub const ENABLE_LINE_INPUT: windows.DWORD = 0x2;
pub const ENABLE_ECHO_INPUT: windows.DWORD = 0x4;
pub const ENABLE_WINDOW_INPUT: windows.DWORD = 0x8;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x200;
pub const ENABLE_PROCESSED_OUTPUT: windows.DWORD = 0x1;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x4;

pub const CP_UTF8: windows.UINT = 65001;

pub const KEY_EVENT: windows.WORD = 0x1;
pub const WINDOW_BUFFER_SIZE_EVENT: windows.WORD = 0x4;

pub const WAIT_OBJECT_0: windows.DWORD = 0;
pub const WAIT_TIMEOUT: windows.DWORD = 0x102;
pub const INFINITE: windows.DWORD = 0xFFFFFFFF;

pub const SMALL_RECT = extern struct {
    Left: i16,
    Top: i16,
    Right: i16,
    Bottom: i16,
};

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: windows.COORD,
    dwCursorPosition: windows.COORD,
    wAttributes: windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: windows.COORD,
};

pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: windows.BOOL,
    wRepeatCount: windows.WORD,
    wVirtualKeyCode: windows.WORD,
    wVirtualScanCode: windows.WORD,
    UnicodeChar: windows.WCHAR,
    dwControlKeyState: windows.DWORD,
};

pub const INPUT_RECORD = extern struct {
    EventType: windows.WORD,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        WindowBufferSizeEvent: windows.COORD,
        raw: [16]u8,
    },
};

pub extern "kernel32" fn GetStdHandle(
    nStdHandle: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

pub extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    lpMode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn SetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    dwMode: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetConsoleCP() callconv(.winapi) windows.UINT;

pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) windows.UINT;

pub extern "kernel32" fn SetConsoleCP(
    wCodePageID: windows.UINT,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn SetConsoleOutputCP(
    wCodePageID: windows.UINT,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn ReadConsoleW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: [*]u16,
    nNumberOfCharsToRead: windows.DWORD,
    lpNumberOfCharsRead: *windows.DWORD,
    pInputControl: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn PeekConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: [*]INPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: [*]INPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

pub extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: windows.HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) windows.BOOL;

pub const CTRL_C_EVENT: windows.DWORD = 0;
pub const CTRL_BREAK_EVENT: windows.DWORD = 1;
pub const CTRL_CLOSE_EVENT: windows.DWORD = 2;
pub const CTRL_LOGOFF_EVENT: windows.DWORD = 5;
pub const CTRL_SHUTDOWN_EVENT: windows.DWORD = 6;

pub const HandlerRoutine = *const fn (dwCtrlType: windows.DWORD) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?HandlerRoutine,
    Add: windows.BOOL,
) callconv(.winapi) windows.BOOL;

// Pseudo consoles, and the pipes and process attributes that host them.

pub const HPCON = *opaque {};
pub const HRESULT = i32;

pub extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*const windows.SECURITY_ATTRIBUTES,
    nSize: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: windows.DWORD,
    lpNumberOfBytesWritten: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn CreatePseudoConsole(
    size: windows.COORD,
    hInput: windows.HANDLE,
    hOutput: windows.HANDLE,
    dwFlags: windows.DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;

pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: windows.COORD) callconv(.winapi) HRESULT;

pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: windows.DWORD,
    dwFlags: windows.DWORD,
    lpSize: *usize,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: *anyopaque,
    dwFlags: windows.DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;

// Standard input that is not a console.

pub const FILE_TYPE_DISK: windows.DWORD = 1;
pub const FILE_TYPE_CHAR: windows.DWORD = 2;
pub const FILE_TYPE_PIPE: windows.DWORD = 3;

pub extern "kernel32" fn GetFileType(hFile: windows.HANDLE) callconv(.winapi) windows.DWORD;

pub extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpBuffer: ?[*]u8,
    nBufferSize: windows.DWORD,
    lpBytesRead: ?*windows.DWORD,
    lpTotalBytesAvail: ?*windows.DWORD,
    lpBytesLeftThisMessage: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

// Winsock, for socket options that `std.Io.net` does not expose. A Winsock
// socket is an AFD endpoint, so `std.Io.net` can accept on it and close it.

pub const WSADATA = extern struct {
    wVersion: windows.WORD,
    wHighVersion: windows.WORD,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*]u8,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
};

pub const SO_EXCLUSIVEADDRUSE: i32 = ~@as(i32, windows.ws2_32.SO.REUSEADDR);
pub const WSA_FLAG_OVERLAPPED: windows.DWORD = 0x01;
pub const WSA_FLAG_NO_HANDLE_INHERIT: windows.DWORD = 0x80;
pub const WSAEACCES: i32 = 10013;
pub const WSAEADDRINUSE: i32 = 10048;

pub extern "ws2_32" fn WSAStartup(
    wVersionRequested: windows.WORD,
    lpWSAData: *WSADATA,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;

pub extern "ws2_32" fn WSASocketW(
    af: i32,
    socket_type: i32,
    protocol: i32,
    lpProtocolInfo: ?*anyopaque,
    g: u32,
    dwFlags: windows.DWORD,
) callconv(.winapi) windows.HANDLE;

pub extern "ws2_32" fn setsockopt(
    s: windows.HANDLE,
    level: i32,
    optname: i32,
    optval: [*]const u8,
    optlen: i32,
) callconv(.winapi) i32;

pub extern "ws2_32" fn bind(
    s: windows.HANDLE,
    name: *const windows.ws2_32.sockaddr,
    namelen: i32,
) callconv(.winapi) i32;

pub extern "ws2_32" fn listen(s: windows.HANDLE, backlog: i32) callconv(.winapi) i32;

pub extern "ws2_32" fn closesocket(s: windows.HANDLE) callconv(.winapi) i32;
