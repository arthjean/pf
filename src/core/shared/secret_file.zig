//! Credential files at rest in the profile directory. On Windows each file
//! holds a DPAPI blob bound to the current user, so another account or a
//! copied disk cannot read it. Elsewhere the bytes stay as written, protected
//! by owner-only permissions. Every credential reader and writer goes through
//! `readStored`, `decode`, and `replace` so the format has one owner.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");

const Allocator = std.mem.Allocator;
const is_windows = builtin.os.tag == .windows;

/// Starts every encrypted file. Plaintext credentials are JSON objects or API
/// keys, so they never start with it.
const header = "pf-dpapi-v1\n";
/// Binds the blobs to pf, so a program that calls `CryptUnprotectData` on
/// the user's files without it does not decrypt them by accident.
const entropy = "pf.credentials.v1";
/// DPAPI adds a fixed header, a MAC, and block padding to the plaintext.
const max_overhead_bytes: usize = 1024;
/// A legacy file is migrated only when its writer lock is free soon.
const migration_lock_deadline_ms: u64 = 250;
const max_backup_attempts: usize = 100;

pub const unreadable_suffix = ".unreadable";

/// Locates the open credential file for migration and quarantine.
pub const Location = struct {
    /// The directory that holds the file. Borrowed, never closed here.
    dir: std.Io.Dir,
    name: []const u8,
    /// The advisory lock that serializes writers of `name`, or null when the
    /// caller already holds it or the file has no writer lock.
    lock_name: ?[]const u8,
};

/// Returns the largest stored size for a plaintext of at most `max_plain` bytes.
pub fn encodedLimit(max_plain: usize) usize {
    if (comptime !is_windows) return max_plain;
    return max_plain + header.len + max_overhead_bytes;
}

/// Reads the stored bytes of an open credential file of at most `max_plain`
/// plaintext bytes. The caller owns the result, closes `file`, and then
/// passes the result to `decode`.
pub fn readStored(alloc: Allocator, file: *std.Io.File, max_plain: usize) ![]u8 {
    return io_mod.readFileToEnd(alloc, file, encodedLimit(max_plain));
}

/// Consumes `stored`, read by `readStored` from `location`, and returns its
/// plaintext. The caller must zero and free the result with `alloc`. Call it
/// only after closing the file: Windows cannot rename or replace a file that
/// pf still holds open.
///
/// On Windows a file that cannot be decrypted, for example on a logon without
/// the user's DPAPI keys or after a profile move, is renamed to a
/// `.unreadable` backup and `error.CredentialsUndecryptable` is returned. A
/// plaintext file left by an earlier pf is encrypted in place.
pub fn decode(alloc: Allocator, stored: []u8, max_plain: usize, location: Location) ![]u8 {
    if (comptime !is_windows) return stored;

    if (std.mem.startsWith(u8, stored, header)) {
        defer zeroAndFree(alloc, stored);
        return unprotect(alloc, stored[header.len..]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CredentialsUndecryptable => {
                quarantine(alloc, location);
                return error.CredentialsUndecryptable;
            },
        };
    }
    if (stored.len > max_plain) {
        zeroAndFree(alloc, stored);
        return error.StreamTooLong;
    }
    migrate(alloc, location, stored) catch |err| {
        zeroAndFree(alloc, stored);
        return err;
    };
    return stored;
}

/// Durably replaces `name` in `dir` with `plaintext`, encrypted on Windows.
pub fn replace(alloc: Allocator, dir: *io_mod.VerifiedDir, name: []const u8, plaintext: []const u8) !void {
    if (comptime !is_windows) return io_mod.durableReplaceVerified(alloc, dir, name, plaintext);
    const encoded = try protect(alloc, plaintext);
    defer zeroAndFree(alloc, encoded);
    try io_mod.durableReplaceVerified(alloc, dir, name, encoded);
    forgetQuarantine(alloc, dir.dir, name);
}

/// Whether this process moved `name` in `dir` to an `.unreadable` backup and
/// no credential has replaced it since. The first reader of an undecryptable
/// file is often a presence probe that ignores errors, so a reader that then
/// finds the file gone calls this and reports `error.CredentialsUndecryptable`
/// instead of a missing credential.
pub fn quarantinedInProcess(alloc: Allocator, dir: std.Io.Dir, name: []const u8) bool {
    if (comptime !is_windows) return false;
    const zio = io_mod.getIo();
    quarantine_registry.mutex.lockUncancelable(zio);
    const empty = quarantine_registry.count == 0;
    quarantine_registry.mutex.unlock(zio);
    if (empty) return false;
    const key = quarantineKey(alloc, dir, name) orelse return false;
    quarantine_registry.mutex.lockUncancelable(zio);
    defer quarantine_registry.mutex.unlock(zio);
    return std.mem.findScalar(u64, &quarantine_registry.keys, key) != null;
}

/// Files this process quarantined, as hashes of their directory and name.
const QuarantineRegistry = struct {
    mutex: std.Io.Mutex = .init,
    /// Zero marks a free slot; when every slot is taken, the oldest entry
    /// gives way.
    keys: [16]u64 = @splat(0),
    count: usize = 0,
    next: usize = 0,
};
var quarantine_registry: QuarantineRegistry = .{};

fn quarantineKey(alloc: Allocator, dir: std.Io.Dir, name: []const u8) ?u64 {
    const path = io_mod.dirRealpathAlloc(alloc, dir, ".") catch return null;
    defer alloc.free(path);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    hasher.update(&.{0});
    hasher.update(name);
    return hasher.final() | 1;
}

fn rememberQuarantine(alloc: Allocator, dir: std.Io.Dir, name: []const u8) void {
    const key = quarantineKey(alloc, dir, name) orelse return;
    const zio = io_mod.getIo();
    quarantine_registry.mutex.lockUncancelable(zio);
    defer quarantine_registry.mutex.unlock(zio);
    const registry = &quarantine_registry;
    if (std.mem.findScalar(u64, &registry.keys, key) != null) return;
    const slot = std.mem.findScalar(u64, &registry.keys, 0) orelse slot: {
        const oldest = registry.next;
        registry.next = (registry.next + 1) % registry.keys.len;
        registry.count -= 1;
        break :slot oldest;
    };
    registry.keys[slot] = key;
    registry.count += 1;
}

fn forgetQuarantine(alloc: Allocator, dir: std.Io.Dir, name: []const u8) void {
    const zio = io_mod.getIo();
    quarantine_registry.mutex.lockUncancelable(zio);
    const empty = quarantine_registry.count == 0;
    quarantine_registry.mutex.unlock(zio);
    if (empty) return;
    const key = quarantineKey(alloc, dir, name) orelse return;
    quarantine_registry.mutex.lockUncancelable(zio);
    defer quarantine_registry.mutex.unlock(zio);
    const slot = std.mem.findScalar(u64, &quarantine_registry.keys, key) orelse return;
    quarantine_registry.keys[slot] = 0;
    quarantine_registry.count -= 1;
}

/// Returns `header` followed by the DPAPI blob of `plaintext`. The caller owns
/// the result.
fn protect(alloc: Allocator, plaintext: []const u8) ![]u8 {
    const win32 = @import("win32.zig");
    const input: win32.DATA_BLOB = .{
        .cbData = std.math.cast(u32, plaintext.len) orelse return error.CredentialTooLarge,
        .pbData = @constCast(plaintext.ptr),
    };
    var output: win32.DATA_BLOB = .{ .cbData = 0, .pbData = null };
    if (!win32.CryptProtectData(&input, null, &entropyBlob(), null, null, win32.CRYPTPROTECT_UI_FORBIDDEN, &output).toBool()) {
        debug_trace.logf("secret_file", "protect failed err={t}", .{std.os.windows.GetLastError()});
        return error.CredentialProtectFailed;
    }
    defer _ = win32.LocalFree(output.pbData);
    const blob = output.pbData.?[0..output.cbData];
    const encoded = try alloc.alloc(u8, header.len + blob.len);
    @memcpy(encoded[0..header.len], header);
    @memcpy(encoded[header.len..], blob);
    return encoded;
}

/// Decrypts a DPAPI blob. The caller must zero and free the result.
fn unprotect(alloc: Allocator, blob: []const u8) error{ OutOfMemory, CredentialsUndecryptable }![]u8 {
    const win32 = @import("win32.zig");
    const input: win32.DATA_BLOB = .{
        .cbData = std.math.cast(u32, blob.len) orelse return error.CredentialsUndecryptable,
        .pbData = @constCast(blob.ptr),
    };
    var output: win32.DATA_BLOB = .{ .cbData = 0, .pbData = null };
    if (!win32.CryptUnprotectData(&input, null, &entropyBlob(), null, null, win32.CRYPTPROTECT_UI_FORBIDDEN, &output).toBool()) {
        debug_trace.logf("secret_file", "unprotect failed err={t}", .{std.os.windows.GetLastError()});
        return error.CredentialsUndecryptable;
    }
    const plain = output.pbData.?[0..output.cbData];
    defer {
        std.crypto.secureZero(u8, @volatileCast(plain));
        _ = win32.LocalFree(output.pbData);
    }
    return alloc.dupe(u8, plain);
}

fn entropyBlob() @import("win32.zig").DATA_BLOB {
    return .{ .cbData = entropy.len, .pbData = @constCast(entropy.ptr) };
}

/// Encrypts a legacy plaintext file in place. It runs under the file's writer
/// lock and only while the file still holds `plaintext`, so a concurrent
/// writer's newer credential is never replaced. A failure leaves the file as
/// it was, and the next read retries.
fn migrate(alloc: Allocator, location: Location, plaintext: []const u8) error{OutOfMemory}!void {
    if (plaintext.len == 0) return;
    var dir: io_mod.VerifiedDir = .{ .dir = location.dir };
    var lock: ?io_mod.TimedAdvisoryLock = if (location.lock_name) |lock_name|
        io_mod.acquireTimedAdvisoryLock(&dir, lock_name, migration_lock_deadline_ms) catch |err| {
            debug_trace.logf("secret_file", "migration skipped file={s} step=lock err={s}", .{ location.name, @errorName(err) });
            return;
        }
    else
        null;
    defer if (lock) |*held| held.release();

    if (!try stillHolds(alloc, location, plaintext)) return;
    replace(alloc, &dir, location.name, plaintext) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("secret_file", "migration failed file={s} err={s}", .{ location.name, @errorName(err) });
            return;
        },
    };
    debug_trace.logf("secret_file", "migrated plaintext file={s}", .{location.name});
}

fn stillHolds(alloc: Allocator, location: Location, expected: []const u8) error{OutOfMemory}!bool {
    var file = location.dir.openFile(io_mod.getIo(), location.name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return false;
    defer file.close(io_mod.getIo());
    const current = io_mod.readFileToEnd(alloc, &file, expected.len + 1) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer zeroAndFree(alloc, current);
    return std.mem.eql(u8, current, expected);
}

/// Renames an undecryptable file to `<name>.unreadable`, or to
/// `<name>.unreadable.<n>` when earlier backups exist. It never deletes one.
fn quarantine(alloc: Allocator, location: Location) void {
    var attempt: usize = 0;
    while (attempt < max_backup_attempts) : (attempt += 1) {
        const backup = (if (attempt == 0)
            std.fmt.allocPrint(alloc, "{s}{s}", .{ location.name, unreadable_suffix })
        else
            std.fmt.allocPrint(alloc, "{s}{s}.{d}", .{ location.name, unreadable_suffix, attempt })) catch return;
        defer alloc.free(backup);
        _ = location.dir.statFile(io_mod.getIo(), backup, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                location.dir.rename(location.name, location.dir, backup, io_mod.getIo()) catch |rename_err| {
                    debug_trace.logf("secret_file", "quarantine failed file={s} err={s}", .{ location.name, @errorName(rename_err) });
                    return;
                };
                debug_trace.logf("secret_file", "quarantined undecryptable file={s} backup={s}", .{ location.name, backup });
                rememberQuarantine(alloc, location.dir, location.name);
                return;
            },
            else => return,
        };
    }
}

fn zeroAndFree(alloc: Allocator, value: []u8) void {
    std.crypto.secureZero(u8, @volatileCast(value));
    alloc.free(value);
}

fn openTestDir(tmp: *std.testing.TmpDir) !io_mod.VerifiedDir {
    return .{ .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
}

fn readTestFile(alloc: Allocator, dir: std.Io.Dir, name: []const u8, lock_name: ?[]const u8) ![]u8 {
    const stored = stored: {
        var file = try dir.openFile(io_mod.getIo(), name, .{ .mode = .read_only });
        defer file.close(io_mod.getIo());
        break :stored try readStored(alloc, &file, 4096);
    };
    return decode(alloc, stored, 4096, .{ .dir = dir, .name = name, .lock_name = lock_name });
}

fn rawTestFile(alloc: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    var file = try dir.openFile(io_mod.getIo(), name, .{ .mode = .read_only });
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1 << 16);
}

test "credential file round-trips and is unreadable as plaintext on Windows" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    const token = "{\"access_token\":\"secret-token-value\"}";
    try replace(alloc, &dir, "auth.json", token);

    const raw = try rawTestFile(alloc, dir.dir, "auth.json");
    defer alloc.free(raw);
    if (is_windows) {
        try std.testing.expect(std.mem.startsWith(u8, raw, header));
        try std.testing.expect(std.mem.indexOf(u8, raw, "secret-token-value") == null);
    } else {
        try std.testing.expectEqualStrings(token, raw);
    }

    const plain = try readTestFile(alloc, dir.dir, "auth.json", null);
    defer zeroAndFree(alloc, plain);
    try std.testing.expectEqualStrings(token, plain);
}

test "credential file read encrypts a legacy plaintext file in place" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    const token = "legacy-api-key-value";
    try io_mod.durableReplaceVerified(alloc, &dir, "api-key", token);

    const plain = try readTestFile(alloc, dir.dir, "api-key", "api-key.lock");
    defer zeroAndFree(alloc, plain);
    try std.testing.expectEqualStrings(token, plain);

    const raw = try rawTestFile(alloc, dir.dir, "api-key");
    defer alloc.free(raw);
    if (is_windows) {
        try std.testing.expect(std.mem.startsWith(u8, raw, header));
        try std.testing.expect(std.mem.indexOf(u8, raw, token) == null);
    } else {
        try std.testing.expectEqualStrings(token, raw);
    }

    const again = try readTestFile(alloc, dir.dir, "api-key", "api-key.lock");
    defer zeroAndFree(alloc, again);
    try std.testing.expectEqualStrings(token, again);
}

test "credential migration leaves a file that changed since it was read" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    try io_mod.durableReplaceVerified(alloc, &dir, "auth.json", "newer-value");
    try migrate(alloc, .{ .dir = dir.dir, .name = "auth.json", .lock_name = null }, "older-value");

    const raw = try rawTestFile(alloc, dir.dir, "auth.json");
    defer alloc.free(raw);
    try std.testing.expectEqualStrings("newer-value", raw);
}

test "undecryptable credential file becomes an unreadable backup" {
    // DPAPI decryption failure exists only on Windows.
    if (comptime !is_windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    // A blob that fails the DPAPI integrity check, as one protected by
    // another account or another machine does.
    const corrupt = header ++ "\x01\x00\x00\x00not-a-dpapi-blob";
    try io_mod.durableReplaceVerified(alloc, &dir, "chatgpt-auth.json", corrupt);
    try io_mod.durableReplaceVerified(alloc, &dir, "chatgpt-auth.json" ++ unreadable_suffix, "earlier backup");

    try std.testing.expectError(
        error.CredentialsUndecryptable,
        readTestFile(alloc, dir.dir, "chatgpt-auth.json", "chatgpt-auth.lock"),
    );
    try std.testing.expectError(
        error.FileNotFound,
        dir.dir.statFile(io_mod.getIo(), "chatgpt-auth.json", .{}),
    );
    const earlier = try rawTestFile(alloc, dir.dir, "chatgpt-auth.json" ++ unreadable_suffix);
    defer alloc.free(earlier);
    try std.testing.expectEqualStrings("earlier backup", earlier);
    const backup = try rawTestFile(alloc, dir.dir, "chatgpt-auth.json" ++ unreadable_suffix ++ ".1");
    defer alloc.free(backup);
    try std.testing.expectEqualStrings(corrupt, backup);

    // Later readers learn why the file is gone until a new credential
    // replaces it.
    try std.testing.expect(quarantinedInProcess(alloc, dir.dir, "chatgpt-auth.json"));
    try std.testing.expect(!quarantinedInProcess(alloc, dir.dir, "grok-auth.json"));
    try replace(alloc, &dir, "chatgpt-auth.json", "{\"access_token\":\"new\"}");
    try std.testing.expect(!quarantinedInProcess(alloc, dir.dir, "chatgpt-auth.json"));
}

/// The `dwFlags` of a DPAPI blob, which records the scope it was protected
/// with. The layout is stable since Windows 2000: version (4 bytes), provider
/// GUID (16), master key version (4), master key GUID (16), then flags.
fn dpapiBlobFlags(blob: []const u8) !u32 {
    const provider_guid = [_]u8{ 0xD0, 0x8C, 0x9D, 0xDF, 0x01, 0x15, 0xD1, 0x11, 0x8C, 0x7A, 0x00, 0xC0, 0x4F, 0xC2, 0x97, 0xEB };
    if (blob.len < 44 or !std.mem.eql(u8, blob[4..20], &provider_guid)) return error.TestUnexpectedResult;
    return std.mem.readInt(u32, blob[40..44], .little);
}

test "credential blob is bound to the user, not the machine" {
    // DPAPI exists only on Windows. A user-scope blob decrypts only for the
    // account that protected it, which DPAPI guarantees; this proves pf asks
    // for that scope, so no second account is needed.
    if (comptime !is_windows) return error.SkipZigTest;
    const win32 = @import("win32.zig");
    const local_machine: u32 = 0x4;
    const alloc = std.testing.allocator;

    const encoded = try protect(alloc, "user-scope-secret");
    defer zeroAndFree(alloc, encoded);
    try std.testing.expectEqual(@as(u32, 0), try dpapiBlobFlags(encoded[header.len..]) & local_machine);

    // The same field reads as machine scope on a machine-scope blob, so the
    // check above reads the right bytes.
    const plain = "machine-scope-secret";
    const input: win32.DATA_BLOB = .{ .cbData = plain.len, .pbData = @constCast(plain.ptr) };
    var output: win32.DATA_BLOB = .{ .cbData = 0, .pbData = null };
    try std.testing.expect(win32.CryptProtectData(&input, null, null, null, null, win32.CRYPTPROTECT_UI_FORBIDDEN | local_machine, &output).toBool());
    defer _ = win32.LocalFree(output.pbData);
    try std.testing.expect(try dpapiBlobFlags(output.pbData.?[0..output.cbData]) & local_machine != 0);
}

test "credential blob does not decrypt without the pf entropy" {
    // DPAPI exists only on Windows.
    if (comptime !is_windows) return error.SkipZigTest;
    const win32 = @import("win32.zig");
    const alloc = std.testing.allocator;
    const encoded = try protect(alloc, "entropy-bound-secret");
    defer zeroAndFree(alloc, encoded);

    const blob = encoded[header.len..];
    const input: win32.DATA_BLOB = .{ .cbData = @intCast(blob.len), .pbData = blob.ptr };
    var output: win32.DATA_BLOB = .{ .cbData = 0, .pbData = null };
    try std.testing.expect(!win32.CryptUnprotectData(&input, null, null, null, null, win32.CRYPTPROTECT_UI_FORBIDDEN, &output).toBool());
}
