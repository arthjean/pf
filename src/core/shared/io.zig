const std = @import("std");
const builtin = @import("builtin");
const darwin_process_spawn = @import("darwin_process_spawn.zig");

pub const RawEnviron = [*:null]const ?[*:0]const u8;

// Process globals are installed before threads start and remain read-only.
var real_io: ?std.Io = null;

// Fallback used by non-test code only when setIo was not called. The real
// application installs `real_io` from main before spawning threads.
var fallback_threaded: std.Io.Threaded = .init_single_threaded;

var global_environ: ?*const std.process.Environ.Map = null;
var global_environ_block: ?std.process.Environ.Block = null;
var global_raw_environ: ?RawEnviron = null;

pub fn setIo(zio: std.Io) void {
    real_io = process_io_for(builtin.os.tag, zio);
}

fn process_io_for(comptime os_tag: std.Target.Os.Tag, zio: std.Io) std.Io {
    return switch (os_tag) {
        .macos => darwin_process_spawn.wrap(zio),
        .windows => wrapWindowsIo(zio),
        else => zio,
    };
}

var windows_vtable: std.Io.VTable = undefined;
var windows_original_vtable: ?*const std.Io.VTable = null;

fn wrapWindowsIo(original: std.Io) std.Io {
    if (windows_original_vtable) |original_vtable| {
        std.debug.assert(original_vtable == original.vtable);
    } else {
        windows_vtable = original.vtable.*;
        windows_vtable.dirOpenFile = windowsDirOpenFile;
        windows_vtable.processSpawn = windowsProcessSpawn;
        windows_original_vtable = original.vtable;
    }
    return .{ .userdata = original.userdata, .vtable = &windows_vtable };
}

// Zig 0.16.0 resolves a bare argv[0] in the child's working directory before
// `PATH`, so a `git.exe` planted in a repository would run. Every spawn
// through `getIo` resolves a bare name with `resolveExecutableAlloc` first and
// passes the absolute path, which std launches without any search.
/// Serializes Windows spawns. The standard library creates each child's pipe
/// ends as inheritable and calls `CreateProcessW` with handle inheritance on,
/// so a second spawn running at the same moment would inherit the first
/// child's pipes. Its process would then hold them open, and the first
/// child's reader would never see end of file.
var windows_spawn_mutex: std.Io.Mutex = .init;

fn windowsProcessSpawn(
    userdata: ?*anyopaque,
    options: std.process.SpawnOptions,
) std.process.SpawnError!std.process.Child {
    const original = windows_original_vtable.?;
    windows_spawn_mutex.lockUncancelable(getIo());
    defer windows_spawn_mutex.unlock(getIo());
    if (options.argv.len == 0 or !isBareExecutableName(options.argv[0])) {
        return original.processSpawn(userdata, options);
    }
    const alloc = std.heap.smp_allocator;
    const resolved = try resolveExecutableAlloc(alloc, options.argv[0]) orelse return error.FileNotFound;
    defer alloc.free(resolved);
    const argv = try alloc.dupe([]const u8, options.argv);
    defer alloc.free(argv);
    argv[0] = resolved;
    var resolved_options = options;
    resolved_options.argv = argv;
    return original.processSpawn(userdata, resolved_options);
}

/// Absolute path of the platform null device. A bare `/dev/null` on Windows
/// resolves to a regular file on the current drive.
pub const null_device_path = if (is_windows) "\\\\.\\NUL" else "/dev/null";

/// Extensions pf launches by bare name on Windows, in search order.
const windows_executable_extensions = [_][]const u8{ ".exe", ".com", ".cmd", ".bat" };

/// Whether `name` is a bare executable name: no directory part and no drive.
pub fn isBareExecutableName(name: []const u8) bool {
    if (name.len == 0) return false;
    return std.mem.findAny(u8, name, if (is_windows) "/\\:" else "/") == null;
}

/// Resolves a bare executable name to an absolute path on Windows. Only the
/// absolute entries of `PATH` are searched, never the working directory, and
/// a name without a launchable extension tries `.exe`, `.com`, `.cmd`, then
/// `.bat` in each entry. Returns null when nothing matches. Caller owns the
/// returned path. Windows only: elsewhere std resolves names through `PATH`
/// without the working directory already. `PATH` comes from the process
/// environment block, the same source std's own search reads.
pub fn resolveExecutableAlloc(alloc: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]u8 {
    const path_value = try processPathAlloc(alloc) orelse return null;
    defer alloc.free(path_value);
    return resolveExecutableInPathAlloc(alloc, name, path_value);
}

/// Returns this process's `PATH` from the Windows environment block. Caller
/// owns the returned text. Windows only.
pub fn processPathAlloc(alloc: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
    comptime std.debug.assert(is_windows);
    const environ: std.process.Environ = .{ .block = .global };
    const path_w = environ.getWindows(std.unicode.wtf8ToWtf16LeStringLiteral("PATH")) orelse return null;
    return try std.unicode.wtf16LeToWtf8Alloc(alloc, path_w);
}

/// `resolveExecutableAlloc` against an explicit `PATH` value.
pub fn resolveExecutableInPathAlloc(alloc: std.mem.Allocator, name: []const u8, path_value: []const u8) error{OutOfMemory}!?[]u8 {
    if (!isBareExecutableName(name)) return null;
    const has_extension = for (windows_executable_extensions) |extension| {
        if (std.ascii.endsWithIgnoreCase(name, extension)) break true;
    } else false;
    var entries = std.mem.tokenizeScalar(u8, path_value, ';');
    while (entries.next()) |raw_entry| {
        const entry = std.mem.trim(u8, std.mem.trim(u8, raw_entry, " "), "\"");
        if (!isFullyQualifiedWindowsPath(entry)) continue;
        if (has_extension) {
            if (try existingFileAlloc(alloc, entry, name, "")) |path| return path;
            continue;
        }
        for (windows_executable_extensions) |extension| {
            if (try existingFileAlloc(alloc, entry, name, extension)) |path| return path;
        }
    }
    return null;
}

/// A drive path such as `C:\tools` or a UNC path. Rooted paths without a
/// drive (`\tools`) and drive-relative paths (`C:tools`) depend on the
/// current directory, so they are not accepted.
fn isFullyQualifiedWindowsPath(path: []const u8) bool {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        isWindowsSeparator(path[2])) return true;
    return path.len >= 3 and isWindowsSeparator(path[0]) and isWindowsSeparator(path[1]);
}

fn isWindowsSeparator(byte: u8) bool {
    return byte == '\\' or byte == '/';
}

fn existingFileAlloc(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, extension: []const u8) error{OutOfMemory}!?[]u8 {
    const trimmed_dir = std.mem.trimEnd(u8, dir, "\\/");
    const path = try std.fmt.allocPrint(alloc, "{s}\\{s}{s}", .{ trimmed_dir, name, extension });
    const stat = std.Io.Dir.cwd().statFile(getIo(), path, .{}) catch {
        alloc.free(path);
        return null;
    };
    if (stat.kind != .file) {
        alloc.free(path);
        return null;
    }
    return path;
}

/// Describes a failed spawn of `argv` for the user when the failure is one pf
/// can name: an executable missing from `PATH`, or a batch script argument
/// that Windows cannot pass safely. Returns null for other errors. Caller owns
/// the returned text.
pub fn spawnFailureMessageAlloc(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    err: anyerror,
) error{OutOfMemory}!?[]u8 {
    if (argv.len == 0) return null;
    switch (err) {
        error.FileNotFound => {
            if (!isBareExecutableName(argv[0])) return null;
            return try std.fmt.allocPrint(alloc, "{s} was not found on PATH", .{argv[0]});
        },
        error.InvalidBatchScriptArg => {
            for (argv[1..], 1..) |arg, position| {
                if (std.mem.findAny(u8, arg, "\r\n\x00") != null) {
                    return try std.fmt.allocPrint(
                        alloc,
                        "Argument {d} contains a line break, which Windows batch files cannot receive safely",
                        .{position},
                    );
                }
            }
            return try std.fmt.allocPrint(alloc, "An argument contains a line break, which Windows batch files cannot receive safely", .{});
        },
        else => return null,
    }
}

fn windowsDirOpenFile(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    sub_path: []const u8,
    options: std.Io.Dir.OpenFileOptions,
) std.Io.File.OpenError!std.Io.File {
    const file = try windows_original_vtable.?.dirOpenFile(userdata, dir, sub_path, options);
    if (options.follow_symlinks or (!options.isRead() and !options.isWrite())) return file;
    // Zig 0.16.0 opens a no-follow handle for asynchronous I/O but marks the
    // File blocking: a positional read or write reaches `unreachable`, and a
    // streaming one fails with INVALID_PARAMETER because it has no offset.
    // Reopening the same file object by handle gives synchronous I/O without
    // resolving the path again.
    const win32 = @import("win32.zig");
    var access: std.os.windows.DWORD = 0;
    if (options.isRead()) access |= win32.GENERIC_READ;
    if (options.isWrite()) access |= win32.GENERIC_WRITE;
    const reopened = win32.ReOpenFile(
        file.handle,
        access,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT,
    );
    std.os.windows.CloseHandle(file.handle);
    if (reopened == std.os.windows.INVALID_HANDLE_VALUE) return error.Unexpected;
    return .{ .handle = reopened, .flags = .{ .nonblocking = false } };
}

pub fn getIo() std.Io {
    if (real_io) |zio| return zio;
    if (comptime builtin.is_test) return process_io_for(builtin.os.tag, std.testing.io);
    return process_io_for(builtin.os.tag, fallback_threaded.io());
}

/// Opens an absolute directory path without following any path component.
/// The caller owns the returned directory handle.
pub fn openDirAbsoluteNoFollow(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    var components = std.fs.path.componentIterator(path);
    const root = components.root() orelse return error.InvalidPath;
    var component = components.next() orelse {
        var root_options = options;
        root_options.follow_symlinks = false;
        return std.Io.Dir.openDirAbsolute(getIo(), root, root_options);
    };

    var dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .follow_symlinks = false });
    errdefer dir.close(getIo());
    while (components.next()) |next_component| {
        if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
            return error.InvalidPath;
        }
        const next_dir = try openChildDirNoFollow(dir, component.name, .{});
        dir.close(getIo());
        dir = next_dir;
        component = next_component;
    }
    if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
        return error.InvalidPath;
    }
    const result = try openChildDirNoFollow(dir, component.name, options);
    dir.close(getIo());
    return result;
}

/// Opens the directory `name` below `dir` without following a link. A
/// no-follow open on Windows returns the link or junction itself instead of
/// failing, so it is rejected with the error POSIX `O_NOFOLLOW` reports.
fn openChildDirNoFollow(dir: std.Io.Dir, name: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    var no_follow = options;
    no_follow.follow_symlinks = false;
    const child = try dir.openDir(getIo(), name, no_follow);
    if (comptime is_windows) {
        errdefer child.close(getIo());
        const stat = try child.stat(getIo());
        if (stat.kind == .sym_link) return error.SymLinkLoop;
    }
    return child;
}

test "Darwin process I/O replaces only processSpawn with stable storage" {
    // The Darwin spawn backend uses POSIX descriptors and does not compile for Windows.
    if (comptime is_windows) return error.SkipZigTest;
    const original = std.testing.io;
    const selected = process_io_for(.macos, original);
    const selected_again = process_io_for(.macos, original);

    try std.testing.expect(selected.userdata == original.userdata);
    try std.testing.expect(selected.vtable == selected_again.vtable);
    inline for (@typeInfo(std.Io.VTable).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "processSpawn")) {
            try std.testing.expect(@field(selected.vtable, field.name) != @field(original.vtable, field.name));
        } else {
            try std.testing.expectEqual(@field(original.vtable, field.name), @field(selected.vtable, field.name));
        }
    }
}

test "getIo applies Darwin process selection to the test fallback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const previous = real_io;
    real_io = null;
    defer real_io = previous;

    const selected = getIo();
    try std.testing.expect(selected.userdata == std.testing.io.userdata);
    try std.testing.expect(selected.vtable.processSpawn != std.testing.io.vtable.processSpawn);
}

test "getIo Darwin test fallback runs a child through the selected backend" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const previous = real_io;
    real_io = null;
    defer real_io = previous;

    const alloc = std.testing.allocator;
    const io = getIo();
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "/usr/bin/printf", "get-io-spawn-ok" },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTermination,
    }
    try std.testing.expectEqualStrings("get-io-spawn-ok", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-Darwin process I/O keeps the original vtable" {
    const original = std.testing.io;
    const selected = process_io_for(.linux, original);

    try std.testing.expect(selected.userdata == original.userdata);
    try std.testing.expect(selected.vtable == original.vtable);
}

test "openDirAbsoluteNoFollow rejects unsafe path components" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(getIo(), "real/child");
    try writeTempFile(tmp.dir, "plain-file", "not a directory");
    tmp.dir.symLink(std.testing.io, "real", "linked", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const linked_child = try std.fs.path.join(alloc, &.{ root, "linked/child" });
    defer alloc.free(linked_child);
    const missing = try std.fs.path.join(alloc, &.{ root, "missing" });
    defer alloc.free(missing);
    const wrong_kind = try std.fs.path.join(alloc, &.{ root, "plain-file" });
    defer alloc.free(wrong_kind);

    if (openDirAbsoluteNoFollow(linked_child, .{})) |dir| {
        dir.close(getIo());
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.NotDir, error.SymLinkLoop => {},
        // Windows opens the link itself, which has no children.
        error.FileNotFound => if (comptime !is_windows) return err,
        else => return err,
    }
    try std.testing.expectError(error.FileNotFound, openDirAbsoluteNoFollow(missing, .{}));
    try std.testing.expectError(error.NotDir, openDirAbsoluteNoFollow(wrong_kind, .{}));
}

/// Opens an existing regular file without following the final symlink and
/// without waiting on a special file that races the initial metadata check.
/// The caller owns the returned file.
pub fn openExistingRegularFile(
    dir: std.Io.Dir,
    sub_path: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) OpenRegularFileError!std.Io.File {
    return openExistingRegularFileWithPolicy(dir, sub_path, .{
        .mode = mode,
        .final_symlink = .no_follow,
        .hardlinks = .reject,
    });
}

/// Opens an existing read-only regular file according to `final_symlink`.
/// Hardlinks are accepted. Following a link does not authorize its target;
/// the caller owns that policy and the returned file.
pub fn openExistingReadOnlyRegularFile(
    dir: std.Io.Dir,
    sub_path: []const u8,
    final_symlink: FinalSymlinkPolicy,
) OpenRegularFileError!std.Io.File {
    return openExistingRegularFileWithPolicy(dir, sub_path, .{
        .mode = .read_only,
        .final_symlink = final_symlink,
        .hardlinks = .allow,
    });
}

pub const FinalSymlinkPolicy = enum {
    no_follow,
    follow,
};

const HardlinkPolicy = enum {
    reject,
    allow,
};

const RegularFileOpenPolicy = struct {
    mode: std.Io.Dir.OpenFileOptions.Mode,
    final_symlink: FinalSymlinkPolicy,
    hardlinks: HardlinkPolicy,
};

/// Errors from opening an existing regular file, the same on every platform.
pub const OpenRegularFileError = std.Io.Dir.StatFileError ||
    std.Io.File.OpenError ||
    std.Io.File.StatError ||
    (if (builtin.os.tag == .windows or builtin.os.tag == .wasi) error{} else std.posix.OpenError) ||
    error{ DurablePathUnsafe, FileControlFailed };

fn openExistingRegularFileWithPolicy(
    dir: std.Io.Dir,
    sub_path: []const u8,
    policy: RegularFileOpenPolicy,
) OpenRegularFileError!std.Io.File {
    const initial = try dir.statFile(getIo(), sub_path, .{
        .follow_symlinks = policy.final_symlink == .follow,
    });
    // A lookup that races an atomic replacement can return the replaced file
    // after its last link is gone. Apply the opened-file policy, so a
    // read-only open accepts that snapshot as the check after the open does.
    try verifyOpenedRegularFileWithPolicy(initial, policy);

    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        var file = try dir.openFile(getIo(), sub_path, .{
            .mode = policy.mode,
            .allow_directory = false,
            .follow_symlinks = policy.final_symlink == .follow,
        });
        errdefer file.close(getIo());
        const stat = try file.stat(getIo());
        try verifyOpenedRegularFileWithPolicy(stat, policy);
        return file;
    }

    var flags: std.posix.O = .{
        .ACCMODE = switch (policy.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
        .NOFOLLOW = policy.final_symlink == .no_follow,
        .NONBLOCK = true,
    };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;

    const fd = std.posix.openat(dir.handle, sub_path, flags, 0) catch |err| switch (err) {
        error.NoDevice, error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    var file = std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = true },
    };
    errdefer file.close(getIo());
    const stat = try file.stat(getIo());
    try verifyOpenedRegularFileWithPolicy(stat, policy);
    try makeFileBlocking(&file);
    return file;
}

pub fn verifyOpenedRegularFile(
    stat: std.Io.File.Stat,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !void {
    return verifyOpenedRegularFileWithPolicy(stat, .{
        .mode = mode,
        .final_symlink = .no_follow,
        .hardlinks = .reject,
    });
}

fn verifyOpenedRegularFileWithPolicy(stat: std.Io.File.Stat, policy: RegularFileOpenPolicy) !void {
    if (stat.kind != .file) {
        return error.DurablePathUnsafe;
    }
    if (policy.hardlinks == .reject and stat.nlink > 1) {
        return error.DurablePathUnsafe;
    }
    if (policy.hardlinks == .reject and policy.mode != .read_only and stat.nlink != 1) {
        return error.DurablePathUnsafe;
    }
}

fn makeFileBlocking(file: *std.Io.File) !void {
    const current = while (true) {
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.GETFL,
            @as(usize, 0),
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @as(usize, @intCast(rc)),
            .INTR => continue,
            else => return error.FileControlFailed,
        }
    };
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    while (true) {
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.SETFL,
            current & ~nonblock,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.FileControlFailed,
        }
    }
    file.flags.nonblocking = false;
}

test "read-only regular files remain valid when atomic replacement unlinks the descriptor" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "old" });

    var file = try openExistingRegularFile(tmp.dir, "target", .read_only);
    defer file.close(getIo());
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "replacement", .data = "new" });
    try tmp.dir.rename("replacement", tmp.dir, "target", getIo());

    const stat = try file.stat(getIo());
    try std.testing.expectEqual(@as(u64, 0), stat.nlink);
    try verifyOpenedRegularFile(stat, .read_only);
    try std.testing.expectError(
        error.DurablePathUnsafe,
        verifyOpenedRegularFile(stat, .read_write),
    );
    const bytes = try readFileToEnd(alloc, &file, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("old", bytes);
}

test "read-only opens accept a file that a concurrent atomic replacement unlinks" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "v" });
    const Replacer = struct {
        dir: std.Io.Dir,
        stop: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            while (!self.stop.load(.acquire)) {
                self.dir.writeFile(getIo(), .{ .sub_path = "next", .data = "v" }) catch return;
                self.dir.rename("next", self.dir, "target", getIo()) catch return;
            }
        }
    };
    var replacer: Replacer = .{ .dir = tmp.dir };
    const thread = try std.Thread.spawn(.{}, Replacer.run, .{&replacer});
    defer {
        replacer.stop.store(true, .release);
        thread.join();
    }
    // Some lookups see the replaced file after its last link is gone.
    for (0..5000) |_| {
        var file = try openExistingRegularFile(tmp.dir, "target", .read_only);
        file.close(getIo());
    }
}

test "read-only regular file policy accepts hardlinks while durable policy rejects" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "metadata" });
    try testHardLink(tmp.dir, "target", "alias");

    try std.testing.expectError(
        error.DurablePathUnsafe,
        openExistingRegularFile(tmp.dir, "target", .read_only),
    );
    var file = try openExistingReadOnlyRegularFile(tmp.dir, "target", .no_follow);
    defer file.close(getIo());
    const bytes = try readFileToEnd(alloc, &file, 64);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("metadata", bytes);
}

test "opened file path evidence rejects a deleted handle" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "metadata" });

    var file = try openExistingReadOnlyRegularFile(tmp.dir, "target", .no_follow);
    defer file.close(getIo());
    try tmp.dir.deleteFile(getIo(), "target");
    try std.testing.expectError(error.HandlePathUnavailable, openedFilePathAlloc(alloc, file));
}

pub fn setEnvironMap(m: *const std.process.Environ.Map) void {
    global_environ = m;
    global_environ_block = null;
    global_raw_environ = null;
}

pub fn setEnvironBlock(block: std.process.Environ.Block) void {
    global_environ = null;
    global_environ_block = block;
    global_raw_environ = null;
}

pub fn setRawEnviron(raw: RawEnviron) void {
    if (comptime builtin.os.tag == .windows) {
        // The C runtime's environment uses the ANSI code page. Read the
        // WTF-16 process environment instead, so values arrive intact and
        // names match without regard to case.
        installWindowsEnviron();
        return;
    }
    global_environ = null;
    global_environ_block = null;
    global_raw_environ = raw;
}

var windows_environ: std.process.Environ.Map = undefined;
var windows_environ_installed = false;

fn installWindowsEnviron() void {
    if (!windows_environ_installed) {
        windows_environ = std.process.Environ.createMap(.{ .block = .global }, std.heap.page_allocator) catch {
            setEnvironBlock(.empty);
            return;
        };
        windows_environ_installed = true;
    }
    setEnvironMap(&windows_environ);
}

/// Returns the process command line as WTF-16, the buffer `GetCommandLineW`
/// returns. Windows only.
pub fn windowsCommandLine() []const u16 {
    return std.os.windows.peb().ProcessParameters.CommandLine.slice();
}

pub fn getenv(key: []const u8) ?[]const u8 {
    if (global_environ) |m| return m.get(key);
    if (global_environ_block) |block| return getenvFromBlock(block, key);
    if (global_raw_environ) |raw| return getenvFromLibc(key) orelse getenvFromRaw(raw, key);
    return null;
}

/// Returns the profile home directory: `USERPROFILE`, else `HOME`, on
/// Windows, and `HOME` elsewhere. Git Bash exports its own `HOME`, so Windows
/// prefers `USERPROFILE` to find one profile from every shell. The slice
/// borrows the process environment.
pub fn homeDir() ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        if (nonEmptyEnv("USERPROFILE")) |profile| return profile;
    }
    return getenv("HOME");
}

/// Returns the temporary directory: `TEMP`, else `TMP`, else
/// `GetTempPathW`, on Windows, and `TMPDIR`, else `/tmp`, elsewhere.
pub fn tempDir() []const u8 {
    if (comptime builtin.os.tag == .windows) {
        if (nonEmptyEnv("TEMP")) |temp| return temp;
        if (nonEmptyEnv("TMP")) |temp| return temp;
        return windowsTempPath();
    }
    return getenv("TMPDIR") orelse "/tmp";
}

fn nonEmptyEnv(key: []const u8) ?[]const u8 {
    const value = getenv(key) orelse return null;
    return if (value.len == 0) null else value;
}

var windows_temp_state: std.atomic.Value(u8) = .init(0);
var windows_temp_buf: [(std.os.windows.MAX_PATH + 1) * 3]u8 = undefined;
var windows_temp_len: usize = 0;

fn windowsTempPath() []const u8 {
    // 0: not computed, 1: computing, 2: ready.
    while (true) {
        switch (windows_temp_state.cmpxchgStrong(0, 1, .acquire, .acquire) orelse 0) {
            0 => break,
            2 => return windows_temp_buf[0..windows_temp_len],
            else => std.atomic.spinLoopHint(),
        }
    }
    windows_temp_len = queryWindowsTempPath(&windows_temp_buf);
    windows_temp_state.store(2, .release);
    return windows_temp_buf[0..windows_temp_len];
}

fn queryWindowsTempPath(out: []u8) usize {
    const win32 = @import("win32.zig");
    var wide: [std.os.windows.MAX_PATH + 1]u16 = undefined;
    const len = win32.GetTempPathW(wide.len, &wide);
    if (len > 0 and len <= wide.len) {
        var path = wide[0..len];
        // GetTempPathW ends the path with a separator; drop it unless it is a drive root.
        if (path.len > 3 and path[path.len - 1] == '\\') path = path[0 .. path.len - 1];
        return std.unicode.wtf16LeToWtf8(out, path);
    }
    // GetTempPathW falls back to the Windows directory; mirror that if it fails.
    const fallback = nonEmptyEnv("SystemRoot") orelse "C:\\Windows";
    const n = @min(fallback.len, out.len);
    @memcpy(out[0..n], fallback[0..n]);
    return n;
}

pub fn e2eFailIfDurableMutationAttempted() void {
    const enabled = getenv("PF_E2E_FAIL_ON_DURABLE_MUTATION") orelse return;
    if (!std.mem.eql(u8, enabled, "1")) return;
    std.process.exit(86);
}

pub fn environMap() ?*const std.process.Environ.Map {
    return global_environ;
}

pub const CloneEnvironMapError = std.mem.Allocator.Error ||
    std.process.Environ.CreateMapError ||
    error{EnvironmentUnavailable};

pub fn cloneEnvironMap(
    alloc: std.mem.Allocator,
) CloneEnvironMapError!std.process.Environ.Map {
    if (global_environ) |map| return map.clone(alloc);
    if (global_environ_block) |block| {
        return std.process.Environ.createMap(.{ .block = block }, alloc);
    }
    if (global_raw_environ) |raw| {
        var len: usize = 0;
        while (raw[len] != null) : (len += 1) {}
        const entries: []const [*:0]const u8 = @ptrCast(raw[0..len]);
        var map = std.process.Environ.Map.init(alloc);
        errdefer map.deinit();
        try map.putPosixBlock(.{ .slice = entries });
        return map;
    }
    return error.EnvironmentUnavailable;
}

fn getenvFromBlock(block: std.process.Environ.Block, key: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .freestanding or builtin.os.tag == .other) {
        return null;
    }
    if (comptime (builtin.os.tag == .wasi or builtin.os.tag == .emscripten) and !builtin.link_libc) {
        return null;
    }

    const view = block.view();
    for (view.slice) |entry_z| {
        const entry = std.mem.sliceTo(entry_z, 0);
        if (entry.len <= key.len or entry[key.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..key.len], key)) return entry[key.len + 1 ..];
    }
    return null;
}

fn getenvFromRaw(raw: RawEnviron, key: []const u8) ?[]const u8 {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (raw[i]) |entry_z| : (i += 1) {
        const entry = std.mem.sliceTo(entry_z, 0);
        if (entry.len <= key.len or entry[key.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..key.len], key)) return entry[key.len + 1 ..];
    }
    return null;
}

fn getenvFromLibc(key: []const u8) ?[]const u8 {
    if (comptime !builtin.link_libc) return null;
    if (key.len >= 128) return null;

    var key_buf: [128]u8 = undefined;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    const value_z = std.c.getenv(key_buf[0..key.len :0].ptr) orelse return null;
    return std.mem.sliceTo(value_z, 0);
}

pub fn readFileToEnd(alloc: std.mem.Allocator, file: *std.Io.File, max_bytes: usize) ![]u8 {
    const zio = getIo();
    var read_buf: [8192]u8 = undefined;
    var r = file.reader(zio, &read_buf);
    return r.interface.allocRemaining(alloc, std.Io.Limit.limited(max_bytes));
}

pub fn readFileToEndZ(alloc: std.mem.Allocator, file: *std.Io.File, max_bytes: usize) ![:0]u8 {
    const data = try readFileToEnd(alloc, file, max_bytes);
    errdefer alloc.free(data);
    const result = try alloc.realloc(data, data.len + 1);
    result[data.len] = 0;
    return result[0..data.len :0];
}

pub fn milliTimestamp() i64 {
    const ts = std.Io.Timestamp.now(getIo(), .real);
    return @intCast(@divFloor(ts.nanoseconds, 1_000_000));
}

pub fn nanoTimestamp() i128 {
    const ts = std.Io.Timestamp.now(getIo(), .real);
    return @intCast(ts.nanoseconds);
}

/// Operating-system process id. POSIX process and group ids are positive
/// `pid_t` values and Windows process ids are DWORDs, so both fit. Convert to
/// `pid_t` only at a POSIX system call with `posixPid`.
pub const ProcessId = u32;

/// Returns the id of the calling process.
pub fn currentProcessId() ProcessId {
    if (comptime builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

/// Returns the process id of a spawned child. On Windows the child id is a
/// process handle, so the id comes from `GetProcessId`.
pub fn childProcessId(id: std.process.Child.Id) ProcessId {
    if (comptime builtin.os.tag == .windows) return @import("win32.zig").GetProcessId(id);
    return @intCast(id);
}

/// Returns whether no running process has id `pid`. A POSIX zombie still
/// counts as running. Test use only.
pub fn testProcessGone(pid: ProcessId) bool {
    if (comptime builtin.os.tag == .windows) {
        const win32 = @import("win32.zig");
        const handle = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid) orelse
            return std.os.windows.GetLastError() == .INVALID_PARAMETER;
        defer std.os.windows.CloseHandle(handle);
        var exit_code: std.os.windows.DWORD = 0;
        if (!win32.GetExitCodeProcess(handle, &exit_code).toBool()) return false;
        return exit_code != win32.STILL_ACTIVE;
    }
    std.posix.kill(posixPid(pid), @enumFromInt(0)) catch |err| return err == error.ProcessNotFound;
    return false;
}

/// Converts a process id for a POSIX system call. POSIX only.
pub fn posixPid(id: ProcessId) std.posix.pid_t {
    comptime std.debug.assert(builtin.os.tag != .windows);
    return @intCast(id);
}

pub fn writeFileAtomic(alloc: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    e2eFailIfDurableMutationAttempted();
    const maybe_existing_permissions = existingFilePermissions(path);
    if (maybe_existing_permissions) |existing_permissions| {
        if (!isWritable(existing_permissions)) return error.AccessDenied;
    }
    const permissions = maybe_existing_permissions orelse .default_file;
    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ path, nanoTimestamp() });
    defer alloc.free(temp_path);

    var cleanup_temp = true;
    defer if (cleanup_temp) std.Io.Dir.deleteFileAbsolute(getIo(), temp_path) catch {};

    {
        var file = try std.Io.Dir.createFileAbsolute(getIo(), temp_path, .{ .truncate = true, .permissions = permissions });
        defer file.close(getIo());
        try file.writeStreamingAll(getIo(), text);
        try file.sync(getIo());
    }

    try std.Io.Dir.renameAbsolute(temp_path, path, getIo());
    cleanup_temp = false;
}

// Private state API. POSIX keeps profile state at modes 0700 and 0600 and
// checks those modes. Windows has no mode bits: private entries inherit the
// profile directory ACL, and verification checks only the entry kind and its
// link count. No other production file converts modes.

const is_windows = builtin.os.tag == .windows;

/// Permissions for creating a private directory.
pub const private_dir_permissions: std.Io.File.Permissions =
    if (is_windows) .default_dir else .fromMode(0o700);
/// Permissions for creating a private file.
pub const private_file_permissions: std.Io.File.Permissions =
    if (is_windows) .default_file else .fromMode(0o600);

/// Returns whether a file has exactly the private file mode (0600). Always
/// true on Windows.
pub fn isPrivateFileMode(permissions: std.Io.File.Permissions) bool {
    if (comptime is_windows) return true;
    return permissions.toMode() & 0o777 == 0o600;
}

/// Returns whether a directory has exactly the private directory mode
/// (0700). Always true on Windows.
pub fn isPrivateDirMode(permissions: std.Io.File.Permissions) bool {
    if (comptime is_windows) return true;
    return permissions.toMode() & 0o777 == 0o700;
}

/// Returns whether no group or other class has any access. Always true on
/// Windows.
pub fn isOwnerOnlyMode(permissions: std.Io.File.Permissions) bool {
    if (comptime is_windows) return true;
    return permissions.toMode() & 0o077 == 0;
}

/// Returns whether an entry is writable: some class has write permission on
/// POSIX, and the read-only attribute is clear on Windows.
pub fn isWritable(permissions: std.Io.File.Permissions) bool {
    // Zig 0.16.0 `Permissions.readOnly` names a missing Windows constant and
    // does not compile there, so test the attribute bit directly.
    if (comptime is_windows) {
        const attributes: std.os.windows.FILE.ATTRIBUTE = @bitCast(@intFromEnum(permissions));
        return !attributes.READONLY;
    }
    return !permissions.readOnly();
}

/// Verifies stat evidence for a private file: a regular file, not a link of
/// any kind, with one name, and the private mode on POSIX.
pub fn verifyPrivateFile(stat: std.Io.File.Stat) error{ DurablePathUnsafe, PrivateStatePermissionsUnsupported }!void {
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    if (!isPrivateFileMode(stat.permissions)) return error.PrivateStatePermissionsUnsupported;
}

/// Verifies stat evidence for a private directory: a directory, not a link
/// or junction, with the private mode on POSIX.
pub fn verifyPrivateDir(stat: std.Io.File.Stat) error{ DurablePathUnsafe, PrivateStatePermissionsUnsupported }!void {
    if (stat.kind != .directory) return error.DurablePathUnsafe;
    if (!isPrivateDirMode(stat.permissions)) return error.PrivateStatePermissionsUnsupported;
}

/// Applies private `permissions` to an open `std.Io.Dir` or `std.Io.File` on
/// POSIX. Windows keeps the inherited ACL and does nothing: changing
/// attributes there needs write-attribute access that read handles lack.
pub fn applyPrivatePermissions(handle: anytype, permissions: std.Io.File.Permissions) !void {
    if (comptime is_windows) return;
    try handle.setPermissions(getIo(), permissions);
}

/// Returns whether the group or other class may write. Always false on
/// Windows.
pub fn isWritableByGroupOrOther(permissions: std.Io.File.Permissions) bool {
    if (comptime is_windows) return false;
    return permissions.toMode() & 0o022 != 0;
}

/// Applies the private directory mode on POSIX, then verifies the directory.
/// Windows keeps the inherited ACL and only verifies.
pub fn ensurePrivateDir(dir: std.Io.Dir) !void {
    if (comptime !is_windows) {
        dir.setPermissions(getIo(), private_dir_permissions) catch return error.PrivateStatePermissionsUnsupported;
    }
    try verifyPrivateDir(try dir.stat(getIo()));
}

/// Applies the private file mode on POSIX, then verifies the file. Windows
/// keeps the inherited ACL and only verifies.
pub fn ensurePrivateFile(file: std.Io.File) !void {
    if (comptime !is_windows) {
        file.setPermissions(getIo(), private_file_permissions) catch return error.PrivateStatePermissionsUnsupported;
    }
    try verifyPrivateFile(try file.stat(getIo()));
}

/// Creates a file with private permissions. The caller owns the file.
pub fn createPrivateFile(dir: std.Io.Dir, sub_path: []const u8, flags: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
    var private_flags = flags;
    private_flags.permissions = private_file_permissions;
    // Windows needs read access on the handle to query the attributes that
    // verification checks.
    if (comptime is_windows) private_flags.read = true;
    return dir.createFile(getIo(), sub_path, private_flags);
}

pub const VerifiedDir = struct {
    dir: std.Io.Dir,

    pub fn close(self: *VerifiedDir) void {
        self.dir.close(getIo());
        self.* = undefined;
    }
};

fn defaultSyncFile(_: ?*anyopaque, file: std.Io.File) anyerror!void {
    try file.sync(getIo());
}

fn defaultSyncDir(_: ?*anyopaque, dir: std.Io.Dir) anyerror!void {
    try syncVerifiedDir(dir);
}

pub const DurableOps = struct {
    ctx: ?*anyopaque = null,
    sync_file: *const fn (?*anyopaque, std.Io.File) anyerror!void = defaultSyncFile,
    sync_dir: *const fn (?*anyopaque, std.Io.Dir) anyerror!void = defaultSyncDir,
};

fn defaultTryLock(_: ?*anyopaque, file: std.Io.File) anyerror!bool {
    return file.tryLock(getIo(), .exclusive);
}

fn defaultLockNow(_: ?*anyopaque) i64 {
    return milliTimestamp();
}

fn defaultLockSleep(_: ?*anyopaque, millis: u64) void {
    sleep(millis * std.time.ns_per_ms);
}

pub const LockOps = struct {
    ctx: ?*anyopaque = null,
    try_lock: *const fn (?*anyopaque, std.Io.File) anyerror!bool = defaultTryLock,
    now_ms: *const fn (?*anyopaque) i64 = defaultLockNow,
    sleep_ms: *const fn (?*anyopaque, u64) void = defaultLockSleep,
};

pub const TimedAdvisoryLock = struct {
    file: std.Io.File,

    pub fn release(self: *TimedAdvisoryLock) void {
        self.file.unlock(getIo());
        self.file.close(getIo());
        self.* = undefined;
    }
};

fn validateRelativeLeaf(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return error.DurablePathUnsafe;
    }
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.DurablePathUnsafe;
}

fn verifyPrivateRegularFile(file: std.Io.File) !void {
    try verifyPrivateFile(try file.stat(getIo()));
}

/// The handle must come from an `openDir` that requested iteration. Linux returns an
/// `O_PATH` descriptor otherwise, and `fsync` rejects those with `EBADF`.
/// Windows offers no directory flush, so this succeeds there; callers flush
/// the file itself before the rename.
pub fn syncVerifiedDir(dir: std.Io.Dir) !void {
    if (comptime builtin.os.tag == .windows) return;
    while (true) {
        const rc = std.c.fsync(dir.handle);
        if (rc == 0) return;
        switch (std.c.errno(rc)) {
            .INTR => continue,
            .INVAL, .OPNOTSUPP => return error.OperationUnsupported,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            .ROFS => return error.ReadOnlyFileSystem,
            else => return error.DirectorySyncFailed,
        }
    }
}

fn openOrCreateVerifiedPrivateChild(parent: std.Io.Dir, name: []const u8) !VerifiedDir {
    e2eFailIfDurableMutationAttempted();
    try validateRelativeLeaf(name);
    const zio = getIo();

    var created = false;
    var dir = parent.openDir(zio, name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            parent.createDir(zio, name, private_dir_permissions) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return create_err,
            };
            created = true;
            break :blk try parent.openDir(zio, name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
        },
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer dir.close(zio);

    try ensurePrivateDir(dir);
    if (created) try syncVerifiedDir(parent);
    return .{ .dir = dir };
}

pub fn openOrCreateVerifiedPrivateDir(parent: *VerifiedDir, name: []const u8) !VerifiedDir {
    return openOrCreateVerifiedPrivateChild(parent.dir, name);
}

pub fn openOrCreateVerifiedPrivateDirFromDir(parent: std.Io.Dir, name: []const u8) !VerifiedDir {
    return openOrCreateVerifiedPrivateChild(parent, name);
}

fn validateReplaceTarget(dir: std.Io.Dir, name: []const u8) !void {
    const stat = dir.statFile(getIo(), name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    if (!isWritable(stat.permissions)) return error.AccessDenied;
}

fn cleanupVerifiedTemp(dir: std.Io.Dir, name: []const u8) void {
    const stat = dir.statFile(getIo(), name, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .file or stat.nlink != 1) return;
    dir.deleteFile(getIo(), name) catch {};
}

pub fn durableReplaceVerified(
    alloc: std.mem.Allocator,
    dir: *VerifiedDir,
    name: []const u8,
    bytes: []const u8,
) !void {
    return durableReplaceVerifiedWithOps(alloc, dir, name, bytes, .{});
}

pub fn durableReplaceVerifiedWithOps(
    alloc: std.mem.Allocator,
    dir: *VerifiedDir,
    name: []const u8,
    bytes: []const u8,
    ops: DurableOps,
) !void {
    e2eFailIfDurableMutationAttempted();
    try validateRelativeLeaf(name);
    validateReplaceTarget(dir.dir, name) catch |err| switch (err) {
        error.DurablePathUnsafe, error.AccessDenied => return err,
        else => return error.DurableReplacePreRenameFailed,
    };

    var random_bytes: [16]u8 = undefined;
    getIo().random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    const temp_name = try std.fmt.allocPrint(alloc, ".{s}.tmp.{s}", .{ name, suffix });
    defer alloc.free(temp_name);

    var temp_exists = false;
    defer if (temp_exists) cleanupVerifiedTemp(dir.dir, temp_name);

    var file = dir.dir.createFile(getIo(), temp_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch return error.DurableReplacePreRenameFailed;
    temp_exists = true;
    defer file.close(getIo());

    ensurePrivateFile(file) catch |err| switch (err) {
        error.DurablePathUnsafe, error.PrivateStatePermissionsUnsupported => return err,
        else => return error.DurableReplacePreRenameFailed,
    };
    file.writeStreamingAll(getIo(), bytes) catch return error.DurableReplacePreRenameFailed;
    ops.sync_file(ops.ctx, file) catch return error.DurableReplacePreRenameFailed;
    renameReplacing(alloc, dir.dir, temp_name, name) catch |err| switch (err) {
        error.DurableReplaceTargetBusy, error.OutOfMemory => return err,
        else => return error.DurableReplacePreRenameFailed,
    };
    temp_exists = false;

    const final_stat = dir.dir.statFile(getIo(), name, .{ .follow_symlinks = false }) catch {
        return error.DurableReplacePostRenameFailed;
    };
    verifyPrivateFile(final_stat) catch return error.DurableReplacePostRenameFailed;
    ops.sync_dir(ops.ctx, dir.dir) catch return error.DurableReplacePostRenameFailed;
}

/// Bounds for replacing a file that another program holds open on Windows,
/// such as an antivirus scanner or an indexer.
pub const replace_busy_max_attempts = 10;
pub const replace_busy_budget_ms = 2_000;

/// Renames `temp_name` over `name` within `dir`. On Windows the rename goes
/// through `MoveFileExW` with write-through, and a sharing, lock, or access
/// violation is retried up to `replace_busy_max_attempts` times within
/// `replace_busy_budget_ms`, then reported as `DurableReplaceTargetBusy`.
const RenameReplacingError = std.Io.Dir.RenameError || std.mem.Allocator.Error || error{
    DurableReplaceTargetBusy,
    RenameFailed,
    HandlePathUnavailable,
    InvalidWtf8,
};

fn renameReplacing(alloc: std.mem.Allocator, dir: std.Io.Dir, temp_name: []const u8, name: []const u8) RenameReplacingError!void {
    if (comptime !is_windows) return dir.rename(temp_name, dir, name, getIo());
    const win32 = @import("win32.zig");
    const dir_w = try windowsFinalPathWideAlloc(alloc, dir.handle);
    defer alloc.free(dir_w);
    const from_w = try windowsChildPathWideAlloc(alloc, dir_w, temp_name);
    defer alloc.free(from_w);
    const to_w = try windowsChildPathWideAlloc(alloc, dir_w, name);
    defer alloc.free(to_w);

    const started = milliTimestamp();
    var attempt: u32 = 1;
    var delay_ms: u64 = 10;
    while (true) : (attempt += 1) {
        if (win32.MoveFileExW(from_w, to_w, win32.MOVEFILE_REPLACE_EXISTING | win32.MOVEFILE_WRITE_THROUGH).toBool()) return;
        switch (std.os.windows.GetLastError()) {
            .SHARING_VIOLATION, .LOCK_VIOLATION, .ACCESS_DENIED => {},
            else => return error.RenameFailed,
        }
        const elapsed: u64 = @intCast(@max(milliTimestamp() - started, 0));
        if (attempt >= replace_busy_max_attempts or elapsed >= replace_busy_budget_ms) {
            recordReplaceBusyPath(to_w);
            return error.DurableReplaceTargetBusy;
        }
        sleep(@min(delay_ms, replace_busy_budget_ms - elapsed) * std.time.ns_per_ms);
        delay_ms = @min(delay_ms * 2, 400);
    }
}

/// Joins a verbatim directory path and a child name into a NUL-terminated
/// WTF-16 path. The caller owns the returned path.
fn windowsChildPathWideAlloc(alloc: std.mem.Allocator, dir_w: []const u16, name: []const u8) ![:0]u16 {
    const name_w = try std.unicode.wtf8ToWtf16LeAlloc(alloc, name);
    defer alloc.free(name_w);
    const sep = [_]u16{'\\'};
    return std.mem.concatWithSentinel(alloc, u16, &.{ dir_w, &sep, name_w }, 0);
}

// The path behind the latest `DurableReplaceTargetBusy` on this thread, so
// error reporting can name it.
threadlocal var replace_busy_path_buf: [std.fs.max_path_bytes]u8 = undefined;
threadlocal var replace_busy_path_len: usize = 0;

fn recordReplaceBusyPath(path_w: []const u16) void {
    const prefix = [_]u16{ '\\', '\\', '?', '\\' };
    const path = if (std.mem.startsWith(u16, path_w, &prefix)) path_w[prefix.len..] else path_w;
    if (std.unicode.calcWtf8Len(path) > replace_busy_path_buf.len) {
        replace_busy_path_len = 0;
        return;
    }
    replace_busy_path_len = std.unicode.wtf16LeToWtf8(&replace_busy_path_buf, path);
}

/// Formats the user message for the latest `DurableReplaceTargetBusy` on this
/// thread into `buf`, naming the file when it is known.
pub fn replaceBusyMessage(buf: []u8) []const u8 {
    const path = if (replace_busy_path_len > 0) replace_busy_path_buf[0..replace_busy_path_len] else "a pf file";
    return std.fmt.bufPrint(buf, "Could not replace {s} because another program has it open. Close it and retry.", .{path}) catch
        "Could not replace a pf file because another program has it open. Close it and retry.";
}

fn openOrCreatePrivateLockFile(dir: *VerifiedDir, name: []const u8) !std.Io.File {
    try validateRelativeLeaf(name);
    const zio = getIo();

    var file = dir.dir.openFile(zio, name, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const created = dir.dir.createFile(zio, name, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = private_file_permissions,
                .resolve_beneath = true,
            }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => break :blk try dir.dir.openFile(zio, name, .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                }),
                else => return create_err,
            };
            if (comptime !is_windows) {
                created.setPermissions(zio, private_file_permissions) catch {
                    created.close(zio);
                    return error.PrivateStatePermissionsUnsupported;
                };
            }
            syncVerifiedDir(dir.dir) catch {
                created.close(zio);
                return error.DirectorySyncFailed;
            };
            break :blk created;
        },
        error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer file.close(zio);
    try verifyPrivateRegularFile(file);
    return file;
}

pub fn acquireTimedAdvisoryLock(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(dir, name, deadline_ms, null, .{});
}

pub fn acquireTimedAdvisoryLockWithOps(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    ops: LockOps,
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(dir, name, deadline_ms, null, ops);
}

pub fn acquireTimedAdvisoryLockCancellable(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    cancel_flag: *const std.atomic.Value(bool),
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(
        dir,
        name,
        deadline_ms,
        cancel_flag,
        .{},
    );
}

pub fn acquireTimedAdvisoryLockCancellableWithOps(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    cancel_flag: *const std.atomic.Value(bool),
    ops: LockOps,
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(
        dir,
        name,
        deadline_ms,
        cancel_flag,
        ops,
    );
}

fn acquireTimedAdvisoryLockControlled(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    cancel_flag: ?*const std.atomic.Value(bool),
    ops: LockOps,
) !TimedAdvisoryLock {
    const file = try openOrCreatePrivateLockFile(dir, name);
    errdefer file.close(getIo());

    const started = ops.now_ms(ops.ctx);
    const deadline: i64 = started + @as(i64, @intCast(deadline_ms));
    while (true) {
        if (cancel_flag) |flag| {
            if (flag.load(.acquire)) return error.Cancelled;
        }
        const locked = ops.try_lock(ops.ctx, file) catch |err| switch (err) {
            error.FileLocksUnsupported => return error.LockUnsupported,
            else => return err,
        };
        if (locked) return .{ .file = file };
        if (ops.now_ms(ops.ctx) >= deadline) return error.LockBusy;
        ops.sleep_ms(ops.ctx, @min(@as(u64, 10), deadline_ms));
    }
}

pub fn copyFileAtomic(alloc: std.mem.Allocator, source_path: []const u8, dest_path: []const u8) !void {
    const zio = getIo();
    var source = try std.Io.Dir.openFileAbsolute(zio, source_path, .{});
    defer source.close(zio);

    const stat = try source.stat(zio);
    if (stat.kind != .file) return error.NotRegularFile;
    if (existingFilePermissions(dest_path)) |existing_permissions| {
        if (!isWritable(existing_permissions)) return error.AccessDenied;
    }

    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ dest_path, nanoTimestamp() });
    defer alloc.free(temp_path);

    var cleanup_temp = true;
    defer if (cleanup_temp) std.Io.Dir.deleteFileAbsolute(zio, temp_path) catch {};

    {
        var dest = try std.Io.Dir.createFileAbsolute(zio, temp_path, .{ .truncate = true, .permissions = stat.permissions });
        defer dest.close(zio);

        var read_buf: [8192]u8 = undefined;
        var reader = source.readerStreaming(zio, &read_buf);
        var transfer_buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try reader.interface.readSliceShort(&transfer_buf);
            if (n == 0) break;
            try dest.writeStreamingAll(zio, transfer_buf[0..n]);
        }
        try dest.sync(zio);
    }

    try std.Io.Dir.renameAbsolute(temp_path, dest_path, zio);
    cleanup_temp = false;
}

fn existingFilePermissions(path: []const u8) ?std.Io.File.Permissions {
    const stat = std.Io.Dir.cwd().statFile(getIo(), path, .{}) catch return null;
    if (stat.kind != .file) return null;
    return stat.permissions;
}

pub fn sleep(ns: u64) void {
    getIo().sleep(.{ .nanoseconds = @intCast(ns) }, .real) catch {};
}

pub fn makeDirRecursive(path: []const u8) !void {
    const zio = getIo();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.createDirAbsolute(zio, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                if (std.fs.path.dirname(path)) |parent| try makeDirRecursive(parent);
                try std.Io.Dir.createDirAbsolute(zio, path, .default_dir);
            },
        };
    } else {
        std.Io.Dir.cwd().createDirPath(zio, path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

/// Errors from `realpathAlloc` and `dirRealpathAlloc`, the same on every
/// platform.
pub const RealpathError = std.mem.Allocator.Error || error{
    FileNotFound,
    NotDir,
    SymLinkLoop,
    AccessDenied,
    PermissionDenied,
    NameTooLong,
    BadPathName,
    InputOutput,
    Unexpected,
};

pub fn realpathAlloc(alloc: std.mem.Allocator, path: []const u8) RealpathError![]u8 {
    if (comptime is_windows) return windowsRealpathAlloc(alloc, std.Io.Dir.cwd(), path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.NameTooLong;
    var result_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ptr = std.c.realpath(path_z, &result_buf) orelse {
        return switch (std.posix.errno(-1)) {
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .LOOP => error.SymLinkLoop,
            .ACCES => error.AccessDenied,
            .PERM => error.PermissionDenied,
            .NAMETOOLONG => error.NameTooLong,
            .INVAL => error.BadPathName,
            .IO => error.InputOutput,
            .NOMEM => error.OutOfMemory,
            else => |err| std.posix.unexpectedErrno(err),
        };
    };
    const resolved = std.mem.sliceTo(ptr, 0);
    return alloc.dupe(u8, resolved);
}

fn handlePathAlloc(alloc: std.mem.Allocator, handle: std.Io.File.Handle) ![]u8 {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
        // F_GETPATH (macOS fcntl command 50): resolve filesystem path for an fd.
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const rc = std.c.fcntl(handle, @as(c_int, 50), @intFromPtr(&path_buf));
        if (rc == -1) return error.HandlePathUnavailable;
        return alloc.dupe(u8, std.mem.sliceTo(&path_buf, 0));
    } else if (comptime builtin.os.tag == .linux) {
        var fd_path_buf: [64:0]u8 = undefined;
        _ = std.fmt.bufPrintZ(&fd_path_buf, "/proc/self/fd/{d}", .{handle}) catch return error.HandlePathUnavailable;
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rc = std.c.readlink(&fd_path_buf, &link_buf, link_buf.len);
        if (rc < 0) return error.HandlePathUnavailable;
        return alloc.dupe(u8, link_buf[0..@intCast(rc)]);
    } else if (comptime is_windows) {
        return windowsFinalPathAlloc(alloc, handle) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.HandlePathUnavailable,
        };
    } else {
        return error.HandlePathUnavailable;
    }
}

/// Opens `sub_path` below `dir`, following links and junctions, and returns
/// its canonical path. The caller owns the returned path.
fn windowsRealpathAlloc(alloc: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) RealpathError![]u8 {
    const file = dir.openFile(getIo(), sub_path, .{ .allow_directory = true }) catch |err| return switch (err) {
        // A dangling link or junction fails to open its missing target.
        error.FileNotFound, error.NetworkNotFound, error.NoDevice => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.SymLinkLoop => error.SymLinkLoop,
        error.NotDir => error.NotDir,
        // Zig 0.16 reports a link that does not resolve, such as a loop, as
        // an unexpected NTSTATUS.
        error.Unexpected => if (windowsPathHasUnresolvedLink(dir, sub_path)) error.SymLinkLoop else error.Unexpected,
        else => error.Unexpected,
    };
    defer file.close(getIo());
    return windowsFinalPathAlloc(alloc, file.handle) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unexpected,
    };
}

/// Reports whether the deepest component of `sub_path` that can be opened
/// without following links is itself a link, so the path fails on a link
/// that does not resolve rather than on a missing or invalid component.
fn windowsPathHasUnresolvedLink(dir: std.Io.Dir, sub_path: []const u8) bool {
    var current: ?[]const u8 = sub_path;
    while (current) |path| : (current = std.fs.path.dirname(path)) {
        const stat = dir.statFile(getIo(), path, .{ .follow_symlinks = false }) catch continue;
        return stat.kind == .sym_link;
    }
    return false;
}

/// Returns `GetFinalPathNameByHandleW` output for an open handle with links
/// and junctions resolved, the `\\?\` prefix removed, `\\?\UNC\server\share`
/// rewritten to `\\server\share`, and the drive letter uppercased. The caller
/// owns the returned path.
fn windowsFinalPathAlloc(alloc: std.mem.Allocator, handle: std.Io.File.Handle) ![]u8 {
    const wide = try windowsFinalPathWideAlloc(alloc, handle);
    defer alloc.free(wide);
    const wtf8 = try std.unicode.wtf16LeToWtf8Alloc(alloc, wide);
    defer alloc.free(wtf8);
    return windowsDosPathAlloc(alloc, wtf8);
}

/// Returns the raw `\\?\` form of `GetFinalPathNameByHandleW` as WTF-16.
/// The caller owns the returned path.
fn windowsFinalPathWideAlloc(alloc: std.mem.Allocator, handle: std.Io.File.Handle) ![]u16 {
    const win32 = @import("win32.zig");
    const flags = win32.FILE_NAME_NORMALIZED | win32.VOLUME_NAME_DOS;
    // Callers resolve into small fixed buffers, so only a path longer than the
    // stack buffer allocates, and then at the size the API reports.
    var stack_buf: [1024]u16 = undefined;
    const len = win32.GetFinalPathNameByHandleW(handle, &stack_buf, stack_buf.len, flags);
    if (len == 0) return error.HandlePathUnavailable;
    if (len < stack_buf.len) return alloc.dupe(u16, stack_buf[0..len]);
    const wide = try alloc.alloc(u16, len);
    defer alloc.free(wide);
    const written = win32.GetFinalPathNameByHandleW(handle, wide.ptr, len, flags);
    if (written == 0 or written >= len) return error.HandlePathUnavailable;
    return alloc.dupe(u16, wide[0..written]);
}

/// Rewrites a `\\?\` path from `GetFinalPathNameByHandleW` into its DOS form.
/// The caller owns the returned path.
fn windowsDosPathAlloc(alloc: std.mem.Allocator, final_path: []const u8) ![]u8 {
    const unc_prefix = "\\\\?\\UNC\\";
    const local_prefix = "\\\\?\\";
    if (std.ascii.startsWithIgnoreCase(final_path, unc_prefix)) {
        return std.mem.concat(alloc, u8, &.{ "\\\\", final_path[unc_prefix.len..] });
    }
    const path = if (std.mem.startsWith(u8, final_path, local_prefix)) final_path[local_prefix.len..] else final_path;
    const result = try alloc.dupe(u8, path);
    if (result.len >= 2 and result[1] == ':') result[0] = std.ascii.toUpper(result[0]);
    return result;
}

/// Compares two canonical paths: ignoring case with the NTFS upcase table on
/// Windows, and byte for byte elsewhere.
pub fn pathsEqual(a: []const u8, b: []const u8) bool {
    if (comptime is_windows) return std.os.windows.eqlIgnoreCaseWtf8(a, b);
    return std.mem.eql(u8, a, b);
}

/// Writes `path`, an existing absolute Windows path, into `out` with every 8.3
/// short name expanded to its long form, without resolving links. Returns null
/// when the path does not exist or does not fit the bounded buffers.
pub fn windowsLongPathInto(path: []const u8, out: []u8) ?[]const u8 {
    if (comptime !is_windows) @compileError("windowsLongPathInto is Windows only");
    const win32 = @import("win32.zig");
    const unc = path.len > 2 and path[0] == '\\' and path[1] == '\\';
    // The `\\?\` prefix lifts the MAX_PATH limit.
    const prefix = if (unc) "\\\\?\\UNC\\" else "\\\\?\\";
    const body = if (unc) path[2..] else path;
    var wide_in: [1024:0]u16 = undefined;
    var wide_len: usize = 0;
    for (prefix) |byte| {
        wide_in[wide_len] = byte;
        wide_len += 1;
    }
    const body_wide_len = std.unicode.calcWtf16LeLen(body) catch return null;
    if (body_wide_len > wide_in.len - wide_len) return null;
    wide_len += std.unicode.wtf8ToWtf16Le(wide_in[wide_len..], body) catch return null;
    wide_in[wide_len] = 0;

    var wide_out: [1024]u16 = undefined;
    const written = win32.GetLongPathNameW(wide_in[0..wide_len :0], &wide_out, wide_out.len);
    if (written == 0 or written >= wide_out.len) return null;
    var long_wide: []const u16 = wide_out[0..written];
    if (!std.mem.startsWith(u16, long_wide, wide_in[0..prefix.len])) return null;
    long_wide = long_wide[prefix.len..];
    var out_len: usize = 0;
    if (unc) {
        if (out.len < 2) return null;
        out[0..2].* = "\\\\".*;
        out_len = 2;
    }
    if (std.unicode.calcWtf8Len(long_wide) > out.len - out_len) return null;
    out_len += std.unicode.wtf16LeToWtf8(out[out_len..], long_wide);
    return out[0..out_len];
}

/// Returns absolute path evidence reported by an already-open regular file
/// handle. The caller owns the returned path. Deleted or otherwise
/// unresolvable handles fail closed.
pub fn openedFilePathAlloc(alloc: std.mem.Allocator, file: std.Io.File) ![]u8 {
    const stat = try file.stat(getIo());
    if (stat.kind != .file or stat.nlink == 0) return error.HandlePathUnavailable;
    const path = try handlePathAlloc(alloc, file.handle);
    errdefer alloc.free(path);
    if (!std.fs.path.isAbsolute(path)) return error.HandlePathUnavailable;
    if (comptime builtin.os.tag == .linux) {
        if (std.mem.endsWith(u8, path, " (deleted)")) return error.HandlePathUnavailable;
    }
    return path;
}

pub fn dirRealpathAlloc(alloc: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) RealpathError![]u8 {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
        const dir_path = handlePathAlloc(alloc, dir.handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileNotFound,
        };
        if (sub_path.len == 0) return dir_path;
        defer alloc.free(dir_path);
        const joined = try std.fs.path.join(alloc, &.{ dir_path, sub_path });
        defer alloc.free(joined);
        return realpathAlloc(alloc, joined);
    } else if (comptime builtin.os.tag == .linux) {
        const dir_path = handlePathAlloc(alloc, dir.handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileNotFound,
        };
        if (sub_path.len == 0) return dir_path;
        defer alloc.free(dir_path);
        const joined = try std.fs.path.join(alloc, &.{ dir_path, sub_path });
        defer alloc.free(joined);
        return realpathAlloc(alloc, joined);
    } else if (comptime builtin.os.tag == .wasi) {
        if (std.fs.path.isAbsolute(sub_path)) return alloc.dupe(u8, sub_path);
        return std.fs.path.resolve(alloc, &.{sub_path});
    } else if (comptime is_windows) {
        return windowsRealpathAlloc(alloc, dir, if (sub_path.len == 0) "." else sub_path);
    } else {
        @compileError("dirRealpathAlloc not implemented for this OS");
    }
}

/// Asserts that stat evidence describes a private file: mode 0600 on POSIX,
/// one regular file on every platform.
pub fn expectPrivateFile(stat: std.Io.File.Stat) !void {
    try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
    try std.testing.expectEqual(@as(@TypeOf(stat.nlink), 1), stat.nlink);
    if (comptime !is_windows) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
}

/// Asserts that stat evidence describes a private directory: mode 0700 on
/// POSIX.
pub fn expectPrivateDir(stat: std.Io.File.Stat) !void {
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
    if (comptime !is_windows) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    }
}

/// Creates `alias` as a second name for `target`, both below `dir`. The
/// standard library has no hard link support on Windows. Test use only.
pub fn testHardLink(dir: std.Io.Dir, target: []const u8, alias: []const u8) !void {
    if (comptime is_windows) {
        const win32 = @import("win32.zig");
        const alloc = std.testing.allocator;
        const root = try dirRealpathAlloc(alloc, dir, ".");
        defer alloc.free(root);
        const target_path = try std.fs.path.join(alloc, &.{ root, target });
        defer alloc.free(target_path);
        const alias_path = try std.fs.path.join(alloc, &.{ root, alias });
        defer alloc.free(alias_path);
        const target_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, target_path);
        defer alloc.free(target_w);
        const alias_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, alias_path);
        defer alloc.free(alias_w);
        if (win32.CreateHardLinkW(alias_w, target_w, null) == .FALSE) return error.HardLinkFailed;
        return;
    }
    try std.testing.expectEqual(@as(c_int, 0), std.c.linkat(dir.handle, @ptrCast(target), dir.handle, @ptrCast(alias), 0));
}

/// Creates the symlink `link_path` below `dir` pointing at `target_path`.
/// Windows links are typed, so a link to an existing directory is created as
/// a directory link, as Git does; POSIX links are untyped. Test use only.
pub fn testSymLink(dir: std.Io.Dir, target_path: []const u8, link_path: []const u8) !void {
    const is_directory = if (comptime is_windows) is_directory: {
        const alloc = std.testing.allocator;
        const parent = std.fs.path.dirname(link_path) orelse ".";
        const resolved = if (std.fs.path.isAbsolute(target_path))
            try alloc.dupe(u8, target_path)
        else
            try std.fs.path.join(alloc, &.{ parent, target_path });
        defer alloc.free(resolved);
        const stat = dir.statFile(getIo(), resolved, .{}) catch break :is_directory false;
        break :is_directory stat.kind == .directory;
    } else false;
    return dir.symLink(getIo(), target_path, link_path, .{ .is_directory = is_directory });
}

/// Removes the directory symlink `sub_path` below `dir` without following it.
/// Windows removes a directory link as a directory. Test use only.
pub fn testDeleteDirSymLink(dir: std.Io.Dir, sub_path: []const u8) !void {
    if (comptime is_windows) return dir.deleteDir(getIo(), sub_path);
    return dir.deleteFile(getIo(), sub_path);
}

/// Sets a socket option on `handle`. `std.posix.setsockopt` does not
/// compile on Windows. Test use only.
pub fn testSetSocketOption(handle: std.Io.net.Socket.Handle, level: i32, name: u32, value: []const u8) !void {
    if (comptime is_windows) {
        const win32 = @import("win32.zig");
        if (win32.setsockopt(handle, level, @intCast(name), value.ptr, @intCast(value.len)) != 0)
            return error.SocketOptionFailed;
        return;
    }
    try std.posix.setsockopt(handle, level, name, value);
}

/// Makes closing `handle` reset the connection (linger on, zero timeout).
/// Test use only.
pub fn testResetOnClose(handle: std.Io.net.Socket.Handle) !void {
    if (comptime is_windows) {
        // Zig sockets are AFD handles that Winsock options cannot reach, so
        // an abortive disconnect sends the reset before the close instead.
        const windows = std.os.windows;
        const info: windows.AFD.PARTIAL_DISCONNECT_INFO = .{
            .DisconnectMode = .{ .ABORTIVE = true },
            .Timeout = -1,
        };
        const result = try getIo().operate(.{ .device_io_control = .{
            .file = .{ .handle = handle, .flags = .{ .nonblocking = false } },
            .code = windows.IOCTL.AFD.PARTIAL_DISCONNECT,
            .in = std.mem.asBytes(&info),
        } });
        if (result.device_io_control.u.Status != .SUCCESS) return error.SocketOptionFailed;
        return;
    }
    const Linger = if (is_windows) std.os.windows.ws2_32.linger else std.posix.linger;
    const linger: Linger = .{ .onoff = 1, .linger = 0 };
    try testSetSocketOption(handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger));
}

fn writeTempFile(dir: std.Io.Dir, name: []const u8, content: []const u8) !void {
    var file = try dir.createFile(getIo(), name, .{ .truncate = true });
    defer file.close(getIo());
    try file.writeStreamingAll(getIo(), content);
}

fn readTempFile(alloc: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, max_bytes: usize) ![]u8 {
    var file = try dir.openFile(getIo(), name, .{});
    defer file.close(getIo());
    return readFileToEnd(alloc, &file, max_bytes);
}

test "getenv returns null before setEnvironMap" {
    const previous = global_environ;
    global_environ = null;
    defer global_environ = previous;

    try std.testing.expect(getenv("PF_IO_TEST") == null);
}

test "getenv returns set value after setEnvironMap" {
    const previous = global_environ;
    global_environ = null;
    defer global_environ = previous;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("PF_IO_TEST", "present");

    setEnvironMap(&environ);
    try std.testing.expectEqualStrings("present", getenv("PF_IO_TEST").?);
    global_environ = null;
}

test "environMap returns borrowed process environment map" {
    const previous = global_environ;
    global_environ = null;
    defer global_environ = previous;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("PF_CORE2_IO_TEST", "present");

    setEnvironMap(&environ);
    const borrowed = environMap().?;
    try std.testing.expectEqualStrings("present", borrowed.get("PF_CORE2_IO_TEST").?);
    global_environ = null;
}

test "cloneEnvironMap owns an independent copy of map environment state" {
    const previous_map = global_environ;
    const previous_block = global_environ_block;
    const previous_raw = global_raw_environ;
    defer {
        global_environ = previous_map;
        global_environ_block = previous_block;
        global_raw_environ = previous_raw;
    }

    var source = std.process.Environ.Map.init(std.testing.allocator);
    defer source.deinit();
    try source.put("PATH", "/map/bin");
    setEnvironMap(&source);

    var cloned = try cloneEnvironMap(std.testing.allocator);
    defer cloned.deinit();
    try source.put("PATH", "/changed");
    try std.testing.expectEqualStrings("/map/bin", cloned.get("PATH").?);
}

test "cloneEnvironMap copies installed block environment state" {
    // Windows reads only the global process environment block.
    if (comptime is_windows) return error.SkipZigTest;
    const previous_map = global_environ;
    const previous_block = global_environ_block;
    const previous_raw = global_raw_environ;
    defer {
        global_environ = previous_map;
        global_environ_block = previous_block;
        global_raw_environ = previous_raw;
    }

    var source = std.process.Environ.Map.init(std.testing.allocator);
    defer source.deinit();
    try source.put("HOME", "/block/home");
    const block = try source.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    setEnvironBlock(block);

    var cloned = try cloneEnvironMap(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqualStrings("/block/home", cloned.get("HOME").?);
}

test "cloneEnvironMap copies installed raw environment state" {
    // Windows ignores the C runtime environment; see setRawEnviron.
    if (comptime is_windows) return error.SkipZigTest;
    const previous_map = global_environ;
    const previous_block = global_environ_block;
    const previous_raw = global_raw_environ;
    defer {
        global_environ = previous_map;
        global_environ_block = previous_block;
        global_raw_environ = previous_raw;
    }

    const raw_entries = [_:null]?[*:0]const u8{
        "PATH=/raw/bin",
        "HOME=/raw/home",
    };
    setRawEnviron(@ptrCast(&raw_entries));

    var cloned = try cloneEnvironMap(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqualStrings("/raw/bin", cloned.get("PATH").?);
    try std.testing.expectEqualStrings("/raw/home", cloned.get("HOME").?);
}

test "readFileToEnd: file under cap returns full content" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "under.txt", "0123456789");

    const data = try readTempFile(alloc, tmp.dir, "under.txt", 100);
    defer alloc.free(data);
    try std.testing.expectEqual(@as(usize, 10), data.len);
    try std.testing.expectEqualStrings("0123456789", data);
}

test "readFileToEnd: file at exact cap returns error.StreamTooLong" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "exact.txt", "0123456789");

    if (readTempFile(alloc, tmp.dir, "exact.txt", 10)) |data| {
        defer alloc.free(data);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.StreamTooLong, err);
    }
}

test "readFileToEnd: file over cap returns error.StreamTooLong" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "over.txt", "0123456789");

    if (readTempFile(alloc, tmp.dir, "over.txt", 9)) |data| {
        defer alloc.free(data);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.StreamTooLong, err);
    }
}

test "readFileToEndZ returns null-terminated slice" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "sentinel.txt", "hello");

    var file = try tmp.dir.openFile(getIo(), "sentinel.txt", .{});
    defer file.close(getIo());
    const data = try readFileToEndZ(alloc, &file, 100);
    defer alloc.free(data);
    try std.testing.expectEqual(@as(usize, 5), data.len);
    try std.testing.expectEqualStrings("hello", data);
    try std.testing.expectEqual(@as(u8, 0), data.ptr[data.len]);
}

test "timestamp wrappers return plausible real-clock values" {
    try std.testing.expect(milliTimestamp() > 0);
    try std.testing.expect(nanoTimestamp() > 0);
}

test "writeFileAtomic replaces file content and leaves no temp file behind" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.fs.path.join(alloc, &.{ root, "state.json" });
    defer alloc.free(file_path);

    try writeFileAtomic(alloc, file_path, "first");
    try writeFileAtomic(alloc, file_path, "second");

    var file = try std.Io.Dir.openFileAbsolute(getIo(), file_path, .{});
    defer file.close(getIo());
    const content = try readFileToEnd(alloc, &file, 128);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("second", content);

    var check_dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .iterate = true });
    defer check_dir.close(getIo());
    var iter = check_dir.iterate();
    var count: usize = 0;
    while (try iter.next(getIo())) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.name, ".tmp.") == null);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "writeFileAtomic preserves existing file permissions" {
    // Windows has no mode bits to preserve.
    if (comptime is_windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.fs.path.join(alloc, &.{ root, "script.sh" });
    defer alloc.free(file_path);

    try writeFileAtomic(alloc, file_path, "first");
    try std.Io.Dir.cwd().setFilePermissions(getIo(), file_path, std.Io.File.Permissions.fromMode(0o755), .{});
    try writeFileAtomic(alloc, file_path, "second");

    const stat = try std.Io.Dir.cwd().statFile(getIo(), file_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o777);
}

test "copyFileAtomic copies through temp file and cleans up" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const source_path = try std.fs.path.join(alloc, &.{ root, "source.txt" });
    defer alloc.free(source_path);
    const dest_path = try std.fs.path.join(alloc, &.{ root, "dest.txt" });
    defer alloc.free(dest_path);

    try writeFileAtomic(alloc, source_path, "source");
    try copyFileAtomic(alloc, source_path, dest_path);

    var file = try std.Io.Dir.openFileAbsolute(getIo(), dest_path, .{});
    defer file.close(getIo());
    const content = try readFileToEnd(alloc, &file, 128);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("source", content);

    var check_dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .iterate = true });
    defer check_dir.close(getIo());
    var iter = check_dir.iterate();
    while (try iter.next(getIo())) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.name, ".tmp.") == null);
    }
}

test "copyFileAtomic failed replacement leaves existing destination intact" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const source_path = try std.fs.path.join(alloc, &.{ root, "source.txt" });
    defer alloc.free(source_path);
    const dest_dir = try std.fs.path.join(alloc, &.{ root, "dest" });
    defer alloc.free(dest_dir);

    try writeFileAtomic(alloc, source_path, "source");
    try std.Io.Dir.cwd().createDirPath(getIo(), dest_dir);
    if (copyFileAtomic(alloc, source_path, dest_dir)) {
        return error.TestExpectedError;
    } else |_| {}

    var check_dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .iterate = true });
    defer check_dir.close(getIo());
    var iter = check_dir.iterate();
    while (try iter.next(getIo())) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.name, ".tmp.") == null);
    }
}

test "dirRealpathAlloc resolves tmp file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "resolved.txt", "content");

    const resolved = try dirRealpathAlloc(alloc, tmp.dir, "resolved.txt");
    defer alloc.free(resolved);
    try std.testing.expect(std.fs.path.isAbsolute(resolved));
    try std.testing.expect(std.mem.endsWith(u8, resolved, std.fs.path.sep_str ++ "resolved.txt"));
}

test "realpathAlloc on nonexistent path returns FileNotFound" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const missing = try std.fs.path.join(alloc, &.{ root, "missing-realpath-target" });
    defer alloc.free(missing);

    try std.testing.expectError(error.FileNotFound, realpathAlloc(alloc, missing));
}

test "realpathAlloc distinguishes non-directory and symlink-loop paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "file", "content");
    try tmp.dir.symLink(getIo(), "loop", "loop", .{});
    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const not_dir = try std.fs.path.join(alloc, &.{ root, "file/child" });
    defer alloc.free(not_dir);
    const loop = try std.fs.path.join(alloc, &.{ root, "loop/child" });
    defer alloc.free(loop);

    if (comptime is_windows) {
        // Windows reports a missing path component in both cases.
        try std.testing.expectError(error.FileNotFound, realpathAlloc(alloc, not_dir));
        if (realpathAlloc(alloc, loop)) |path| {
            alloc.free(path);
            return error.TestExpectedError;
        } else |_| {}
        return;
    }
    try std.testing.expectError(error.NotDir, realpathAlloc(alloc, not_dir));
    try std.testing.expectError(error.SymLinkLoop, realpathAlloc(alloc, loop));
}

const DurableFailureState = struct {
    fail_temp_sync: bool = false,
    fail_parent_sync: bool = false,
    lock_attempts: usize = 0,
    now_ms: i64 = 0,
};

fn testDurableSyncFile(ctx: ?*anyopaque, file: std.Io.File) anyerror!void {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    if (state.fail_temp_sync) return error.InjectedSyncFailure;
    try file.sync(getIo());
}

fn testDurableSyncDir(ctx: ?*anyopaque, dir: std.Io.Dir) anyerror!void {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    if (state.fail_parent_sync) return error.InjectedSyncFailure;
    try syncVerifiedDir(dir);
}

fn testLockAlwaysBusy(ctx: ?*anyopaque, _: std.Io.File) anyerror!bool {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    state.lock_attempts += 1;
    return false;
}

fn testLockUnsupported(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
    return error.FileLocksUnsupported;
}

fn testLockNow(ctx: ?*anyopaque) i64 {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    return state.now_ms;
}

fn testLockSleep(ctx: ?*anyopaque, millis: u64) void {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    state.now_ms += @intCast(millis);
}

test "durable replace reports pre-rename failure without changing target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try durableReplaceVerified(alloc, &dir, "settings.json", "old");

    var state = DurableFailureState{ .fail_temp_sync = true };
    const ops = DurableOps{ .ctx = &state, .sync_file = testDurableSyncFile };
    try std.testing.expectError(
        error.DurableReplacePreRenameFailed,
        durableReplaceVerifiedWithOps(alloc, &dir, "settings.json", "new", ops),
    );

    var file = try dir.dir.openFile(getIo(), "settings.json", .{ .follow_symlinks = false });
    defer file.close(getIo());
    const bytes = try readFileToEnd(alloc, &file, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("old", bytes);
}

test "durable replace reports post-rename sync failure as indeterminate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try durableReplaceVerified(alloc, &dir, "settings.json", "old");

    var state = DurableFailureState{ .fail_parent_sync = true };
    const ops = DurableOps{ .ctx = &state, .sync_dir = testDurableSyncDir };
    try std.testing.expectError(
        error.DurableReplacePostRenameFailed,
        durableReplaceVerifiedWithOps(alloc, &dir, "settings.json", "new", ops),
    );

    var file = try dir.dir.openFile(getIo(), "settings.json", .{ .follow_symlinks = false });
    defer file.close(getIo());
    const bytes = try readFileToEnd(alloc, &file, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("new", bytes);
}

test "private durable file mode is exactly 0600" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try durableReplaceVerified(alloc, &dir, "settings.json", "{}\n");

    try expectPrivateFile(try dir.dir.statFile(getIo(), "settings.json", .{ .follow_symlinks = false }));
}

test "private durable directory mode is exactly 0700" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var parent = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer parent.close();
    var child = try openOrCreateVerifiedPrivateDir(&parent, "state");
    defer child.close();

    try expectPrivateDir(try child.dir.stat(getIo()));
}

test "caller-owned directory can create a verified private child" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var parent = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false });
    defer parent.close(getIo());
    var child = try openOrCreateVerifiedPrivateDirFromDir(parent, "state");
    defer child.close();

    try expectPrivateDir(try child.dir.stat(getIo()));
}

test "caller-owned directory rejects unsafe private children" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(getIo(), .{ .sub_path = "file", .data = "not a directory" });
    try std.testing.expectError(
        error.DurablePathUnsafe,
        openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "file"),
    );

    try tmp.dir.createDir(getIo(), "target", .default_dir);
    tmp.dir.symLink(getIo(), "target", "link", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    try std.testing.expectError(
        error.DurablePathUnsafe,
        openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "link"),
    );
}

test "timed advisory lock returns busy after deadline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    var state = DurableFailureState{};
    const ops = LockOps{
        .ctx = &state,
        .try_lock = testLockAlwaysBusy,
        .now_ms = testLockNow,
        .sleep_ms = testLockSleep,
    };

    try std.testing.expectError(
        error.LockBusy,
        acquireTimedAdvisoryLockWithOps(&dir, "settings.lock", 25, ops),
    );
    try std.testing.expect(state.lock_attempts > 1);
}

test "cancellable timed advisory lock stops between busy attempts" {
    const CancelState = struct {
        cancel: *std.atomic.Value(bool),
        now_ms: i64 = 0,

        fn tryLock(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
            return false;
        }

        fn now(raw: ?*anyopaque) i64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.now_ms;
        }

        fn sleep(raw: ?*anyopaque, millis: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.now_ms += @intCast(millis);
            self.cancel.store(true, .release);
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(
        getIo(),
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer dir.close();
    var cancel = std.atomic.Value(bool).init(false);
    var state = CancelState{ .cancel = &cancel };

    try std.testing.expectError(
        error.Cancelled,
        acquireTimedAdvisoryLockCancellableWithOps(
            &dir,
            "credentials.lock",
            2_000,
            &cancel,
            .{
                .ctx = &state,
                .try_lock = CancelState.tryLock,
                .now_ms = CancelState.now,
                .sleep_ms = CancelState.sleep,
            },
        ),
    );
    try std.testing.expectEqual(@as(i64, 10), state.now_ms);
}

test "timed advisory lock reports unsupported without unlocked fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    const ops = LockOps{ .try_lock = testLockUnsupported };

    try std.testing.expectError(
        error.LockUnsupported,
        acquireTimedAdvisoryLockWithOps(&dir, "settings.lock", 25, ops),
    );
}

test "Windows command line arguments arrive as WTF-8 without loss" {
    if (comptime !is_windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const typed = "r\u{e9}sum\u{e9} de C:\\Users\\Zo\u{eb}\\projet";
    const line = try std.unicode.wtf8ToWtf16LeAlloc(a, "pf.exe ask \"" ++ typed ++ "\" x");
    // Append an argument holding an unpaired high surrogate.
    var with_surrogate: std.ArrayList(u16) = .empty;
    try with_surrogate.appendSlice(a, line);
    try with_surrogate.appendSlice(a, &.{ ' ', 0xD800, 'z' });

    const args = try (std.process.Args{ .vector = with_surrogate.items }).toSlice(a);
    try std.testing.expectEqual(@as(usize, 5), args.len);
    try std.testing.expectEqualStrings("ask", args[1]);
    try std.testing.expectEqualStrings(typed, args[2]);
    // WTF-8 encodes the lone surrogate as ED A0 80.
    try std.testing.expectEqualSlices(u8, "\xED\xA0\x80z", args[4]);

    // The live command line decodes the same way.
    const live = try (std.process.Args{ .vector = windowsCommandLine() }).toSlice(a);
    try std.testing.expect(live.len >= 1);
}

test "getenv ignores name case on Windows only" {
    const previous = global_environ;
    defer global_environ = previous;

    if (comptime is_windows) {
        global_environ = null;
        setRawEnviron(undefined);
        const upper = getenv("PATH") orelse return error.TestExpectedEnvironment;
        const mixed = getenv("Path") orelse return error.TestExpectedEnvironment;
        try std.testing.expectEqualStrings(upper, mixed);
        return;
    }

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("PF_CASE_TEST", "upper");
    setEnvironMap(&environ);
    try std.testing.expectEqualStrings("upper", getenv("PF_CASE_TEST").?);
    try std.testing.expect(getenv("pf_case_test") == null);
}

test "homeDir prefers USERPROFILE on Windows and reads HOME elsewhere" {
    const previous = global_environ;
    defer global_environ = previous;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/git-bash/home");
    setEnvironMap(&environ);
    try std.testing.expectEqualStrings("/git-bash/home", homeDir().?);

    try environ.put("USERPROFILE", "C:\\Users\\a");
    try std.testing.expectEqualStrings(if (is_windows) "C:\\Users\\a" else "/git-bash/home", homeDir().?);

    _ = environ.swapRemove("HOME");
    if (is_windows) {
        try std.testing.expectEqualStrings("C:\\Users\\a", homeDir().?);
        _ = environ.swapRemove("USERPROFILE");
    }
    try std.testing.expect(homeDir() == null);
}

test "tempDir follows the platform order" {
    const previous = global_environ;
    defer global_environ = previous;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    setEnvironMap(&environ);
    if (comptime is_windows) {
        const queried = tempDir();
        try std.testing.expect(std.fs.path.isAbsolute(queried));
        try std.testing.expect(!std.mem.endsWith(u8, queried, "\\"));
        try environ.put("TMP", "C:\\tmp-b");
        try std.testing.expectEqualStrings("C:\\tmp-b", tempDir());
        try environ.put("TEMP", "C:\\tmp-a");
        try std.testing.expectEqualStrings("C:\\tmp-a", tempDir());
        return;
    }
    try std.testing.expectEqualStrings("/tmp", tempDir());
    try environ.put("TMPDIR", "/var/tmp-x");
    try std.testing.expectEqualStrings("/var/tmp-x", tempDir());
}

/// Creates a junction named `link` below `dir` that points to `target`.
fn testJunction(alloc: std.mem.Allocator, dir: std.Io.Dir, link: []const u8, target: []const u8) !void {
    const root = try dirRealpathAlloc(alloc, dir, ".");
    defer alloc.free(root);
    const link_path = try std.fs.path.join(alloc, &.{ root, link });
    defer alloc.free(link_path);
    const result = try std.process.run(alloc, getIo(), .{
        .argv = &.{ "cmd.exe", "/c", "mklink", "/J", link_path, target },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.JunctionFailed,
        else => return error.JunctionFailed,
    }
}

test "private file verification rejects hard links and junctions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var private_file = try createPrivateFile(tmp.dir, "auth.json", .{});
    try ensurePrivateFile(private_file);
    private_file.close(getIo());
    try verifyPrivateFile(try tmp.dir.statFile(getIo(), "auth.json", .{ .follow_symlinks = false }));

    try testHardLink(tmp.dir, "auth.json", "auth-alias.json");
    try std.testing.expectError(
        error.DurablePathUnsafe,
        verifyPrivateFile(try tmp.dir.statFile(getIo(), "auth.json", .{ .follow_symlinks = false })),
    );
    try std.testing.expectError(error.DurablePathUnsafe, openExistingRegularFile(tmp.dir, "auth.json", .read_only));

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try std.testing.expectError(error.DurablePathUnsafe, durableReplaceVerified(alloc, &dir, "auth.json", "{}"));

    if (comptime is_windows) {
        try tmp.dir.createDir(getIo(), "elsewhere", .default_dir);
        const elsewhere = try dirRealpathAlloc(alloc, tmp.dir, "elsewhere");
        defer alloc.free(elsewhere);
        try testJunction(alloc, tmp.dir, "grok-auth.json", elsewhere);
        try std.testing.expectError(
            error.DurablePathUnsafe,
            verifyPrivateFile(try tmp.dir.statFile(getIo(), "grok-auth.json", .{ .follow_symlinks = false })),
        );
        try std.testing.expectError(error.DurablePathUnsafe, openExistingRegularFile(tmp.dir, "grok-auth.json", .read_only));
    }
}

test "syncVerifiedDir succeeds after a durable write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(getIo());
    try syncVerifiedDir(dir);
}

test "Windows executable resolution searches only absolute PATH entries" {
    if (comptime !is_windows) return error.SkipZigTest; // Windows PATH and extension rules.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(getIo(), "first");
    try tmp.dir.createDirPath(getIo(), "second");
    try writeTempFile(tmp.dir, "tool.exe", "planted");
    try writeTempFile(tmp.dir, "first/npx.cmd", "");
    try writeTempFile(tmp.dir, "second/tool.cmd", "");
    try writeTempFile(tmp.dir, "second/tool.exe", "");
    try writeTempFile(tmp.dir, "second/script.ps1", "");
    try tmp.dir.createDirPath(getIo(), "second/dir.exe");
    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path_value = try std.fmt.allocPrint(
        alloc,
        ".;{s};relative\\bin;\\rooted;\"{s}\\first\";{s}\\second\\",
        .{ root[0..2], root, root },
    );
    defer alloc.free(path_value);

    const tool = (try resolveExecutableInPathAlloc(alloc, "tool", path_value)).?;
    defer alloc.free(tool);
    const expected_tool = try std.fmt.allocPrint(alloc, "{s}\\second\\tool.exe", .{root});
    defer alloc.free(expected_tool);
    try std.testing.expectEqualStrings(expected_tool, tool);

    const npx = (try resolveExecutableInPathAlloc(alloc, "npx", path_value)).?;
    defer alloc.free(npx);
    const expected_npx = try std.fmt.allocPrint(alloc, "{s}\\first\\npx.cmd", .{root});
    defer alloc.free(expected_npx);
    try std.testing.expectEqualStrings(expected_npx, npx);

    const explicit = (try resolveExecutableInPathAlloc(alloc, "TOOL.CMD", path_value)).?;
    defer alloc.free(explicit);
    try std.testing.expect(std.ascii.endsWithIgnoreCase(explicit, "\\second\\TOOL.CMD"));

    try std.testing.expect(try resolveExecutableInPathAlloc(alloc, "script", path_value) == null);
    try std.testing.expect(try resolveExecutableInPathAlloc(alloc, "dir", path_value) == null);
    try std.testing.expect(try resolveExecutableInPathAlloc(alloc, "missing", path_value) == null);
    try std.testing.expect(try resolveExecutableInPathAlloc(alloc, ".\\tool", path_value) == null);
    try std.testing.expect(!isBareExecutableName("C:tool"));
    try std.testing.expect(!isBareExecutableName("bin/tool"));
    try std.testing.expect(isBareExecutableName("tool.exe"));
}

test "Windows spawn never runs an executable planted in the working directory" {
    if (comptime !is_windows) return error.SkipZigTest; // Windows-only working-directory search.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "whoami.bat", "@echo planted> marker.txt\r\n");
    try writeTempFile(tmp.dir, "whoami.cmd", "@echo planted> marker.txt\r\n");
    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    // Unwrapped, std runs the planted script from the working directory.
    const planted = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{"whoami"},
        .cwd = .{ .path = root },
    });
    alloc.free(planted.stdout);
    alloc.free(planted.stderr);
    _ = try tmp.dir.statFile(getIo(), "marker.txt", .{});
    try tmp.dir.deleteFile(getIo(), "marker.txt");

    const result = try std.process.run(alloc, getIo(), .{
        .argv = &.{"whoami"},
        .cwd = .{ .path = root },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(getIo(), "marker.txt", .{}));

    try std.testing.expectError(error.FileNotFound, std.process.run(alloc, getIo(), .{
        .argv = &.{"pf-missing-executable-for-test"},
    }));
    const missing = (try spawnFailureMessageAlloc(alloc, &.{"pf-missing-executable-for-test"}, error.FileNotFound)).?;
    defer alloc.free(missing);
    try std.testing.expectEqualStrings("pf-missing-executable-for-test was not found on PATH", missing);
}

test "Windows batch script arguments with line breaks fail and name their position" {
    if (comptime !is_windows) return error.SkipZigTest; // Batch script quoting is Windows-only.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "echo-args.cmd", "@echo %*\r\n");
    const script = try dirRealpathAlloc(alloc, tmp.dir, "echo-args.cmd");
    defer alloc.free(script);

    const argv = [_][]const u8{ script, "safe", "two\nlines" };
    const err = std.process.run(alloc, getIo(), .{ .argv = &argv });
    try std.testing.expectError(error.InvalidBatchScriptArg, err);
    const message = (try spawnFailureMessageAlloc(alloc, &argv, error.InvalidBatchScriptArg)).?;
    defer alloc.free(message);
    try std.testing.expectEqualStrings(
        "Argument 2 contains a line break, which Windows batch files cannot receive safely",
        message,
    );
}

test "windowsDosPathAlloc strips verbatim prefixes and uppercases the drive" {
    const alloc = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "\\\\?\\c:\\dev\\pf", "C:\\dev\\pf" },
        .{ "\\\\?\\UNC\\server\\share\\x", "\\\\server\\share\\x" },
        .{ "D:\\x", "D:\\x" },
    };
    for (cases) |case| {
        const got = try windowsDosPathAlloc(alloc, case[0]);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "realpath resolves junctions and returns a DOS path on Windows" {
    if (comptime !is_windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(getIo(), "real/inner");
    const real = try dirRealpathAlloc(alloc, tmp.dir, "real");
    defer alloc.free(real);
    try std.testing.expect(!std.mem.startsWith(u8, real, "\\\\?\\"));
    try std.testing.expect(real[1] == ':' and std.ascii.isUpper(real[0]));

    try testJunction(alloc, tmp.dir, "via", real);
    const through = try dirRealpathAlloc(alloc, tmp.dir, "via\\inner");
    defer alloc.free(through);
    const expected = try std.fs.path.join(alloc, &.{ real, "inner" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, through);

    // A lowercase drive in the input still yields the canonical form.
    const lower = try alloc.dupe(u8, expected);
    defer alloc.free(lower);
    lower[0] = std.ascii.toLower(lower[0]);
    const canonical = try realpathAlloc(alloc, lower);
    defer alloc.free(canonical);
    try std.testing.expectEqualStrings(expected, canonical);

    // A dangling junction fails cleanly.
    try tmp.dir.createDir(getIo(), "gone", .default_dir);
    const gone = try dirRealpathAlloc(alloc, tmp.dir, "gone");
    defer alloc.free(gone);
    try testJunction(alloc, tmp.dir, "dangling", gone);
    try tmp.dir.deleteDir(getIo(), "gone");
    try std.testing.expectError(error.FileNotFound, dirRealpathAlloc(alloc, tmp.dir, "dangling"));
}

test "realpath and reads work below a path longer than 260 characters" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const segment = "segment-with-a-long-name-for-path-length-tests-" ++ "x" ** 40;
    const relative = segment ++ "/" ++ segment ++ "/" ++ segment ++ "/" ++ segment ++ "/" ++ segment;
    try tmp.dir.createDirPath(getIo(), relative);
    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const deep = try std.fs.path.join(alloc, &.{ root, relative });
    defer alloc.free(deep);
    try std.testing.expect(deep.len > 400);

    const canonical = try realpathAlloc(alloc, deep);
    defer alloc.free(canonical);
    try std.testing.expect(canonical.len > 400);

    var deep_dir = try std.Io.Dir.openDirAbsolute(getIo(), canonical, .{});
    defer deep_dir.close(getIo());
    try writeTempFile(deep_dir, "r\u{e9}sum\u{e9}.txt", "deep content");
    const bytes = try readTempFile(alloc, deep_dir, "r\u{e9}sum\u{e9}.txt", 64);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("deep content", bytes);
}

test "pathsEqual ignores case on Windows only" {
    try std.testing.expect(pathsEqual("C:\\dev\\pf", "C:\\dev\\pf"));
    try std.testing.expectEqual(is_windows, pathsEqual("C:\\DEV\\PF", "c:\\dev\\pf"));
    try std.testing.expectEqual(is_windows, pathsEqual("C:\\\u{c9}t\u{e9}", "c:\\\u{e9}T\u{c9}"));
    try std.testing.expect(!pathsEqual("C:\\dev\\pf", "C:\\dev\\pg"));
}

test "durable replace retries a busy target within its budget on Windows" {
    if (comptime !is_windows) return error.SkipZigTest;
    const win32 = @import("win32.zig");
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try durableReplaceVerified(alloc, &dir, "settings.json", "{\"v\":1}");

    // Hold the target open without FILE_SHARE_DELETE, as a scanner might.
    const path = try dirRealpathAlloc(alloc, tmp.dir, "settings.json");
    defer alloc.free(path);
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);
    const holder = win32.CreateFileW(path_w, win32.GENERIC_READ, win32.FILE_SHARE_READ, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(holder != std.os.windows.INVALID_HANDLE_VALUE);

    const started = milliTimestamp();
    try std.testing.expectError(error.DurableReplaceTargetBusy, durableReplaceVerified(alloc, &dir, "settings.json", "{\"v\":2}"));
    const elapsed = milliTimestamp() - started;
    try std.testing.expect(elapsed <= replace_busy_budget_ms + 250);

    var message_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
    const message = replaceBusyMessage(&message_buf);
    try std.testing.expect(std.mem.indexOf(u8, message, path) != null);

    // Released during the retries, the replace succeeds.
    const Release = struct {
        fn run(handle: std.os.windows.HANDLE) void {
            sleep(150 * std.time.ns_per_ms);
            std.os.windows.CloseHandle(handle);
        }
    };
    const holder2 = win32.CreateFileW(path_w, win32.GENERIC_READ, win32.FILE_SHARE_READ, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    std.os.windows.CloseHandle(holder);
    try std.testing.expect(holder2 != std.os.windows.INVALID_HANDLE_VALUE);
    const thread = try std.Thread.spawn(.{}, Release.run, .{holder2});
    try durableReplaceVerified(alloc, &dir, "settings.json", "{\"v\":3}");
    thread.join();
    const bytes = try readTempFile(alloc, tmp.dir, "settings.json", 64);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("{\"v\":3}", bytes);
}

test "concurrent locked durable writers both complete with one valid result" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Writer = struct {
        fn run(parent: std.Io.Dir, payload: []const u8, failures: *std.atomic.Value(u32)) void {
            write(parent, payload) catch {
                _ = failures.fetchAdd(1, .monotonic);
            };
        }

        fn write(parent: std.Io.Dir, payload: []const u8) !void {
            var dir = VerifiedDir{ .dir = try parent.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
            defer dir.close();
            for (0..20) |_| {
                var lock = try acquireTimedAdvisoryLock(&dir, "settings.lock", 5_000);
                defer lock.release();
                try durableReplaceVerified(std.heap.page_allocator, &dir, "settings.json", payload);
            }
        }
    };

    var failures = std.atomic.Value(u32).init(0);
    const a = try std.Thread.spawn(.{}, Writer.run, .{ tmp.dir, "{\"writer\":\"a\"}", &failures });
    const b = try std.Thread.spawn(.{}, Writer.run, .{ tmp.dir, "{\"writer\":\"b\"}", &failures });
    a.join();
    b.join();
    try std.testing.expectEqual(@as(u32, 0), failures.load(.monotonic));

    const bytes = try readTempFile(alloc, tmp.dir, "settings.json", 64);
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const writer = parsed.value.object.get("writer").?.string;
    try std.testing.expect(std.mem.eql(u8, writer, "a") or std.mem.eql(u8, writer, "b"));
}

test "Windows concurrent spawns never inherit each other's pipes" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest; // Handle inheritance races are Windows-specific.
    const Holder = struct {
        // Starts processes that outlive the reads below, so any pipe they
        // inherited would delay that read's end of file.
        fn run(done: *std.atomic.Value(bool)) void {
            while (!done.load(.acquire)) {
                var child = std.process.spawn(getIo(), .{
                    .argv = &.{ "ping", "-n", "4", "127.0.0.1" },
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                }) catch return;
                _ = child.wait(getIo()) catch {};
            }
        }
    };
    var done = std.atomic.Value(bool).init(false);
    var holders: [4]std.Thread = undefined;
    for (&holders) |*thread| thread.* = try std.Thread.spawn(.{}, Holder.run, .{&done});
    defer {
        done.store(true, .release);
        for (holders) |thread| thread.join();
    }

    for (0..20) |_| {
        var child = try std.process.spawn(getIo(), .{
            .argv = &.{ "cmd.exe", "/d", "/c", "exit 0" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        const started = milliTimestamp();
        var buffer: [256]u8 = undefined;
        while (true) {
            const count = child.stdout.?.readStreaming(getIo(), &.{&buffer}) catch break;
            if (count == 0) break;
        }
        _ = child.wait(getIo()) catch {};
        try std.testing.expect(milliTimestamp() - started < 1_500);
    }
}
