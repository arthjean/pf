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

pub const SW_SHOWNORMAL: c_int = 1;
pub const COINIT_APARTMENTTHREADED: windows.DWORD = 0x2;
pub const COINIT_DISABLE_OLE1DDE: windows.DWORD = 0x4;

pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: windows.DWORD) callconv(.winapi) HRESULT;

pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

/// Returns a value greater than 32 on success, and an error code otherwise.
pub extern "shell32" fn ShellExecuteW(
    hwnd: ?windows.HWND,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: c_int,
) callconv(.winapi) ?windows.HINSTANCE;

pub extern "kernel32" fn GetLongPathNameW(
    lpszShortPath: [*:0]const u16,
    lpszLongPath: [*]u16,
    cchBuffer: windows.DWORD,
) callconv(.winapi) windows.DWORD;

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
pub const FILE_SHARE_WRITE: windows.DWORD = 0x2;
pub const FILE_SHARE_DELETE: windows.DWORD = 0x4;
pub const GENERIC_WRITE: windows.DWORD = 0x40000000;
pub const FILE_FLAG_BACKUP_SEMANTICS: windows.DWORD = 0x02000000;
pub const FILE_FLAG_OPEN_REPARSE_POINT: windows.DWORD = 0x00200000;

/// Reopens the file object behind `hOriginalFile` with new access and flags.
/// Returns INVALID_HANDLE_VALUE on failure.
pub extern "kernel32" fn ReOpenFile(
    hOriginalFile: windows.HANDLE,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
) callconv(.winapi) windows.HANDLE;
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
pub const PROCESS_TERMINATE: windows.DWORD = 0x0001;
pub const PROCESS_SET_QUOTA: windows.DWORD = 0x0100;

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

// Job Objects

pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: windows.DWORD = 0x2000;
pub const JobObjectBasicAccountingInformation: windows.DWORD = 1;
pub const JobObjectExtendedLimitInformation: windows.DWORD = 9;

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: windows.LARGE_INTEGER = 0,
    PerJobUserTimeLimit: windows.LARGE_INTEGER = 0,
    LimitFlags: windows.DWORD = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: windows.DWORD = 0,
    Affinity: usize = 0,
    PriorityClass: windows.DWORD = 0,
    SchedulingClass: windows.DWORD = 0,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

pub const JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = extern struct {
    TotalUserTime: windows.LARGE_INTEGER,
    TotalKernelTime: windows.LARGE_INTEGER,
    ThisPeriodTotalUserTime: windows.LARGE_INTEGER,
    ThisPeriodTotalKernelTime: windows.LARGE_INTEGER,
    TotalPageFaultCount: windows.DWORD,
    TotalProcesses: windows.DWORD,
    ActiveProcesses: windows.DWORD,
    TotalTerminatedProcesses: windows.DWORD,
};

pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*anyopaque,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;

pub extern "kernel32" fn SetInformationJobObject(
    hJob: windows.HANDLE,
    JobObjectInformationClass: windows.DWORD,
    lpJobObjectInformation: *anyopaque,
    cbJobObjectInformationLength: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn QueryInformationJobObject(
    hJob: ?windows.HANDLE,
    JobObjectInformationClass: windows.DWORD,
    lpJobObjectInformation: *anyopaque,
    cbJobObjectInformationLength: windows.DWORD,
    lpReturnLength: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn AssignProcessToJobObject(
    hJob: windows.HANDLE,
    hProcess: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn TerminateJobObject(
    hJob: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn IsProcessInJob(
    ProcessHandle: windows.HANDLE,
    JobHandle: ?windows.HANDLE,
    Result: *windows.BOOL,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn ResumeThread(hThread: windows.HANDLE) callconv(.winapi) windows.DWORD;

// File version resources

pub const VS_FIXEDFILEINFO = extern struct {
    dwSignature: windows.DWORD,
    dwStrucVersion: windows.DWORD,
    dwFileVersionMS: windows.DWORD,
    dwFileVersionLS: windows.DWORD,
    dwProductVersionMS: windows.DWORD,
    dwProductVersionLS: windows.DWORD,
    dwFileFlagsMask: windows.DWORD,
    dwFileFlags: windows.DWORD,
    dwFileOS: windows.DWORD,
    dwFileType: windows.DWORD,
    dwFileSubtype: windows.DWORD,
    dwFileDateMS: windows.DWORD,
    dwFileDateLS: windows.DWORD,
};

pub extern "version" fn GetFileVersionInfoSizeW(
    lptstrFilename: [*:0]const u16,
    lpdwHandle: ?*windows.DWORD,
) callconv(.winapi) windows.DWORD;

pub extern "version" fn GetFileVersionInfoW(
    lptstrFilename: [*:0]const u16,
    dwHandle: windows.DWORD,
    dwLen: windows.DWORD,
    lpData: *anyopaque,
) callconv(.winapi) windows.BOOL;

pub extern "version" fn VerQueryValueW(
    pBlock: *const anyopaque,
    lpSubBlock: [*:0]const u16,
    lplpBuffer: *?*anyopaque,
    puLen: *windows.UINT,
) callconv(.winapi) windows.BOOL;

// Process snapshots

pub const TH32CS_SNAPPROCESS: windows.DWORD = 0x2;

pub const PROCESSENTRY32W = extern struct {
    dwSize: windows.DWORD = @sizeOf(PROCESSENTRY32W),
    cntUsage: windows.DWORD = 0,
    th32ProcessID: windows.DWORD = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: windows.DWORD = 0,
    cntThreads: windows.DWORD = 0,
    th32ParentProcessID: windows.DWORD = 0,
    pcPriClassBase: i32 = 0,
    dwFlags: windows.DWORD = 0,
    szExeFile: [windows.MAX_PATH]u16 = undefined,
};

pub extern "kernel32" fn CreateToolhelp32Snapshot(
    dwFlags: windows.DWORD,
    th32ProcessID: windows.DWORD,
) callconv(.winapi) windows.HANDLE;

pub extern "kernel32" fn Process32FirstW(
    hSnapshot: windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn Process32NextW(
    hSnapshot: windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetProcessTimes(
    hProcess: windows.HANDLE,
    lpCreationTime: *windows.FILETIME,
    lpExitTime: *windows.FILETIME,
    lpKernelTime: *windows.FILETIME,
    lpUserTime: *windows.FILETIME,
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
