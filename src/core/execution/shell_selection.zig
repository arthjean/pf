//! The shell that runs model-proposed commands and the dialect permission
//! analysis assumes for them. POSIX runs `sh`. Windows runs Git Bash when it
//! is available and PowerShell otherwise, never `cmd.exe`, as chosen by
//! `PF_WINDOWS_SHELL` (`auto`, `bash`, or `powershell`) and
//! `PF_GIT_BASH_PATH`. Execution, admission, the turn context, and
//! `pf doctor` all read the one selection `current` makes per process.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const is_windows = builtin.os.tag == .windows;

pub const Dialect = enum {
    /// POSIX sh, including bash from Git for Windows. pf parses it.
    posix_sh,
    /// PowerShell, which pf does not parse: every command is opaque.
    powershell,
};

/// The dialect a command context assumes until it is set from `dialect()`:
/// the restrictive one on Windows, where a context built without the
/// selection must not be parsed.
pub const default_dialect: Dialect = if (is_windows) .powershell else .posix_sh;

pub const Reason = enum {
    posix,
    git_bash_path_env,
    git_install,
    program_files,
    pwsh_on_path,
    windows_powershell_on_path,
    pwsh_requested,
    windows_powershell_requested,

    pub fn text(self: Reason) []const u8 {
        return switch (self) {
            .posix => "the POSIX shell",
            .git_bash_path_env => "PF_GIT_BASH_PATH names it",
            .git_install => "it is installed beside git.exe on PATH",
            .program_files => "it is installed in %ProgramFiles%\\Git",
            .pwsh_on_path => "Git Bash was not found and pwsh.exe is on PATH",
            .windows_powershell_on_path => "Git Bash and pwsh.exe were not found and powershell.exe is on PATH",
            .pwsh_requested => "PF_WINDOWS_SHELL is powershell and pwsh.exe is on PATH",
            .windows_powershell_requested => "PF_WINDOWS_SHELL is powershell, pwsh.exe was not found, and powershell.exe is on PATH",
        };
    }
};

pub const Shell = struct {
    dialect: Dialect,
    /// Absolute on Windows.
    path: []const u8,
    reason: Reason,
    /// PowerShell version such as `7.5.2`, when known.
    version: ?[]const u8 = null,

    /// The dialect as the model and `pf doctor` see it.
    pub fn dialectLabel(self: Shell, alloc: Allocator) Allocator.Error![]u8 {
        return switch (self.dialect) {
            .posix_sh => alloc.dupe(u8, if (is_windows) "bash (Git Bash)" else "sh"),
            .powershell => if (self.version) |version|
                std.fmt.allocPrint(alloc, "PowerShell {s}", .{version})
            else
                alloc.dupe(u8, "PowerShell"),
        };
    }
};

pub const SelectionError = error{
    InvalidWindowsShell,
    GitBashPathNotFound,
    GitBashNotFound,
    NoSupportedShell,
};

/// The user-facing message for a selection failure.
pub fn errorMessage(err: SelectionError) []const u8 {
    return switch (err) {
        error.InvalidWindowsShell => "PF_WINDOWS_SHELL must be auto, bash, or powershell.",
        error.GitBashPathNotFound => "PF_GIT_BASH_PATH does not name an existing bash.exe. Fix PF_GIT_BASH_PATH or unset it.",
        error.GitBashNotFound => "Git Bash not found. Set PF_GIT_BASH_PATH or PF_WINDOWS_SHELL=auto.",
        error.NoSupportedShell => "No supported shell found. Install Git for Windows or PowerShell 7.",
    };
}

/// Everything selection reads, so tests can supply it.
pub const Inputs = struct {
    windows_shell: ?[]const u8 = null,
    git_bash_path: ?[]const u8 = null,
    program_files: ?[]const u8 = null,
    path: []const u8 = "",
};

const Preference = enum { auto, bash, powershell };

/// Selects the Windows shell from `inputs`. The returned paths are allocated
/// with `alloc`, which should be an arena.
pub fn selectWindows(alloc: Allocator, inputs: Inputs) (SelectionError || Allocator.Error)!Shell {
    const preference: Preference = if (inputs.windows_shell) |raw| blk: {
        const value = std.mem.trim(u8, raw, " ");
        if (value.len == 0) break :blk .auto;
        inline for (@typeInfo(Preference).@"enum".fields) |field| {
            if (std.ascii.eqlIgnoreCase(value, field.name)) break :blk @enumFromInt(field.value);
        }
        return error.InvalidWindowsShell;
    } else .auto;

    if (preference != .powershell) {
        if (try findGitBash(alloc, inputs)) |shell| return shell;
        if (preference == .bash) return error.GitBashNotFound;
    }
    if (try io_mod.resolveExecutableInPathAlloc(alloc, "pwsh.exe", inputs.path)) |path| {
        return .{
            .dialect = .powershell,
            .path = path,
            .reason = if (preference == .powershell) .pwsh_requested else .pwsh_on_path,
            .version = try powershellVersion(alloc, path),
        };
    }
    if (try io_mod.resolveExecutableInPathAlloc(alloc, "powershell.exe", inputs.path)) |path| {
        return .{
            .dialect = .powershell,
            .path = path,
            .reason = if (preference == .powershell) .windows_powershell_requested else .windows_powershell_on_path,
            .version = "5.1",
        };
    }
    return error.NoSupportedShell;
}

fn findGitBash(alloc: Allocator, inputs: Inputs) (SelectionError || Allocator.Error)!?Shell {
    if (inputs.git_bash_path) |raw| {
        const path = std.mem.trim(u8, raw, " \"");
        if (path.len > 0) {
            if (!std.fs.path.isAbsolute(path) or !isFile(path)) return error.GitBashPathNotFound;
            return .{ .dialect = .posix_sh, .path = try alloc.dupe(u8, path), .reason = .git_bash_path_env };
        }
    }
    if (try io_mod.resolveExecutableInPathAlloc(alloc, "git.exe", inputs.path)) |git| {
        if (gitInstallRoot(git)) |root| {
            const bash = try std.fs.path.join(alloc, &.{ root, "bin", "bash.exe" });
            if (isFile(bash)) return .{ .dialect = .posix_sh, .path = bash, .reason = .git_install };
        }
    }
    if (inputs.program_files) |program_files| {
        const bash = try std.fs.path.join(alloc, &.{ program_files, "Git", "bin", "bash.exe" });
        if (isFile(bash)) return .{ .dialect = .posix_sh, .path = bash, .reason = .program_files };
    }
    return null;
}

/// The Git for Windows install root above `git.exe`, which lives in `cmd`,
/// `bin`, or `<mingw>\bin` under the root.
fn gitInstallRoot(git_path: []const u8) ?[]const u8 {
    const dir = std.fs.path.dirname(git_path) orelse return null;
    const parent = std.fs.path.dirname(dir) orelse return null;
    const dir_name = std.fs.path.basename(dir);
    if (std.ascii.eqlIgnoreCase(dir_name, "cmd")) return parent;
    if (!std.ascii.eqlIgnoreCase(dir_name, "bin")) return null;
    const parent_name = std.fs.path.basename(parent);
    for ([_][]const u8{ "mingw64", "mingw32", "clang64", "clangarm64", "ucrt64" }) |mingw| {
        if (std.ascii.eqlIgnoreCase(parent_name, mingw)) return std.fs.path.dirname(parent);
    }
    return parent;
}

/// The MSYS `usr\bin` directory of the Git Bash at `bash_path`, which holds
/// the coreutils that bash itself runs. `bash_path` is `<root>\bin\bash.exe`
/// or `<root>\usr\bin\bash.exe`.
pub fn msysUsrBinAlloc(alloc: Allocator, bash_path: []const u8) Allocator.Error!?[]u8 {
    const dir = std.fs.path.dirname(bash_path) orelse return null;
    const root = std.fs.path.dirname(dir) orelse return null;
    if (std.ascii.eqlIgnoreCase(std.fs.path.basename(root), "usr")) return try alloc.dupe(u8, dir);
    const usr_bin = try std.fs.path.join(alloc, &.{ root, "usr", "bin" });
    return usr_bin;
}

fn isFile(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return false;
    return stat.kind == .file;
}

fn powershellVersion(alloc: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    if (comptime !is_windows) return null;
    const win32 = @import("../shared/win32.zig");
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch return null;
    const size = win32.GetFileVersionInfoSizeW(path_w, null);
    if (size == 0) return null;
    const data = try alloc.alignedAlloc(u8, .of(u32), size);
    if (!win32.GetFileVersionInfoW(path_w, 0, size, data.ptr).toBool()) return null;
    var info: ?*anyopaque = null;
    var info_len: std.os.windows.UINT = 0;
    if (!win32.VerQueryValueW(data.ptr, std.unicode.wtf8ToWtf16LeStringLiteral("\\"), &info, &info_len).toBool()) return null;
    if (info == null or info_len < @sizeOf(win32.VS_FIXEDFILEINFO)) return null;
    const fixed: *const win32.VS_FIXEDFILEINFO = @ptrCast(@alignCast(info.?));
    return try std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{
        fixed.dwProductVersionMS >> 16,
        fixed.dwProductVersionMS & 0xffff,
        fixed.dwProductVersionLS >> 16,
    });
}

// The selection depends only on the process environment and installed
// files, so it is made once per process and kept for every later caller.
var cache_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var cache_mutex: std.Io.Mutex = .init;
var cached: ?(SelectionError || Allocator.Error)!Shell = null;

/// The shell this process runs commands with. POSIX always gets `sh`.
pub fn current() (SelectionError || Allocator.Error)!Shell {
    if (comptime !is_windows) return .{ .dialect = .posix_sh, .path = "sh", .reason = .posix };
    const io = io_mod.getIo();
    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);
    if (cached) |result| return result;
    const alloc = cache_arena.allocator();
    const path = try io_mod.processPathAlloc(alloc);
    const result = selectWindows(alloc, .{
        .windows_shell = io_mod.getenv("PF_WINDOWS_SHELL"),
        .git_bash_path = io_mod.getenv("PF_GIT_BASH_PATH"),
        .program_files = io_mod.getenv("ProgramFiles"),
        .path = path orelse "",
    });
    // Running out of memory says nothing about the installed shells, so a
    // later call selects again.
    if (result) |_| {
        cached = result;
    } else |err| if (err != error.OutOfMemory) {
        cached = result;
    }
    return result;
}

/// Tests set this to exercise a dialect on any host, and reset it to null.
pub var test_dialect: ?Dialect = null;

/// The dialect permission analysis assumes. When no shell can be selected,
/// commands are treated as opaque PowerShell, the restrictive choice; they
/// cannot run anyway.
pub fn dialect() Dialect {
    if (builtin.is_test) {
        if (test_dialect) |value| return value;
    }
    if (comptime !is_windows) return .posix_sh;
    const shell = current() catch return .powershell;
    return shell.dialect;
}

/// The `-EncodedCommand` script that runs `command` in PowerShell with UTF-8
/// plain-text output and returns `$LASTEXITCODE`, or 1 when the last pipeline
/// failed without one. The setup stays on the first line, so PowerShell
/// reports the command's own lines from line 2. Caller owns the returned
/// base64 text.
pub fn powershellEncodedCommandAlloc(alloc: Allocator, command: []const u8) (Allocator.Error || error{InvalidWtf8})![]u8 {
    const script = try std.fmt.allocPrint(alloc,
        \\$ProgressPreference = 'SilentlyContinue'; if ($PSStyle) {{ $PSStyle.OutputRendering = 'PlainText' }}; [Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false); $global:LASTEXITCODE = 0
        \\{s}
        \\if (-not $?) {{ if ($global:LASTEXITCODE) {{ exit $global:LASTEXITCODE }} else {{ exit 1 }} }}
        \\exit $global:LASTEXITCODE
        \\
    , .{command});
    defer alloc.free(script);
    const units = std.unicode.wtf8ToWtf16LeAlloc(alloc, script) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidWtf8,
    };
    defer alloc.free(units);
    // Windows is little-endian, so the native bytes are UTF-16LE.
    const bytes = std.mem.sliceAsBytes(units);
    const encoder = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

test "Windows shell selection prefers Git Bash, then PowerShell, never cmd" {
    if (comptime !is_windows) return error.SkipZigTest; // Windows shell discovery.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{
        "Git/cmd/git.exe",
        "Git/bin/bash.exe",
        "Other/Git/bin/bash.exe",
        "custom/bash.exe",
        "pwsh/pwsh.exe",
        "winps/powershell.exe",
        "winps/cmd.exe",
    }) |name| {
        if (std.fs.path.dirname(name)) |dir| try tmp.dir.createDirPath(io_mod.getIo(), dir);
        try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = name, .data = "" });
    }
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const p = struct {
        fn join(a: Allocator, base: []const u8, sub: []const u8) []const u8 {
            return std.fmt.allocPrint(a, "{s}\\{s}", .{ base, sub }) catch unreachable;
        }
    }.join;
    const full_path = try std.fmt.allocPrint(arena, "{s};{s};{s}", .{ p(arena, root, "Git\\cmd"), p(arena, root, "pwsh"), p(arena, root, "winps") });
    const ps_path = try std.fmt.allocPrint(arena, "{s};{s}", .{ p(arena, root, "pwsh"), p(arena, root, "winps") });
    const winps_path = p(arena, root, "winps");

    const from_git = try selectWindows(arena, .{ .path = full_path });
    try std.testing.expectEqual(Dialect.posix_sh, from_git.dialect);
    try std.testing.expectEqual(Reason.git_install, from_git.reason);
    try std.testing.expectEqualStrings(p(arena, root, "Git\\bin\\bash.exe"), from_git.path);

    const custom = p(arena, root, "custom\\bash.exe");
    const from_env = try selectWindows(arena, .{ .path = full_path, .git_bash_path = custom, .windows_shell = "AUTO" });
    try std.testing.expectEqual(Reason.git_bash_path_env, from_env.reason);
    try std.testing.expectEqualStrings(custom, from_env.path);

    const from_program_files = try selectWindows(arena, .{ .path = ps_path, .program_files = p(arena, root, "Other") });
    try std.testing.expectEqual(Reason.program_files, from_program_files.reason);

    const pwsh = try selectWindows(arena, .{ .path = ps_path });
    try std.testing.expectEqual(Dialect.powershell, pwsh.dialect);
    try std.testing.expectEqual(Reason.pwsh_on_path, pwsh.reason);

    const forced = try selectWindows(arena, .{ .path = full_path, .windows_shell = "powershell" });
    try std.testing.expectEqual(Reason.pwsh_requested, forced.reason);

    const windows_powershell = try selectWindows(arena, .{ .path = winps_path });
    try std.testing.expectEqual(Reason.windows_powershell_on_path, windows_powershell.reason);
    try std.testing.expectEqualStrings("PowerShell 5.1", try windows_powershell.dialectLabel(arena));

    try std.testing.expectError(error.GitBashNotFound, selectWindows(arena, .{ .path = ps_path, .windows_shell = "bash" }));
    try std.testing.expectError(error.GitBashPathNotFound, selectWindows(arena, .{ .path = full_path, .git_bash_path = p(arena, root, "missing\\bash.exe") }));
    try std.testing.expectError(error.NoSupportedShell, selectWindows(arena, .{ .path = p(arena, root, "custom") }));
    try std.testing.expectError(error.InvalidWindowsShell, selectWindows(arena, .{ .path = full_path, .windows_shell = "cmd" }));
}

test "Windows Git install roots and MSYS directories" {
    if (comptime !is_windows) return error.SkipZigTest; // Windows path layout.
    try std.testing.expectEqualStrings("C:\\Git", gitInstallRoot("C:\\Git\\cmd\\git.exe").?);
    try std.testing.expectEqualStrings("C:\\Git", gitInstallRoot("C:\\Git\\mingw64\\bin\\git.exe").?);
    try std.testing.expectEqualStrings("C:\\Git", gitInstallRoot("C:\\Git\\bin\\git.exe").?);
    try std.testing.expect(gitInstallRoot("C:\\tools\\git.exe") == null);
    const alloc = std.testing.allocator;
    const from_bin = (try msysUsrBinAlloc(alloc, "C:\\Git\\bin\\bash.exe")).?;
    defer alloc.free(from_bin);
    try std.testing.expectEqualStrings("C:\\Git\\usr\\bin", from_bin);
    const from_usr = (try msysUsrBinAlloc(alloc, "C:\\Git\\usr\\bin\\bash.exe")).?;
    defer alloc.free(from_usr);
    try std.testing.expectEqualStrings("C:\\Git\\usr\\bin", from_usr);
}
