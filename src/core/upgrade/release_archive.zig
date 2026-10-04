//! Extracts the pf binary from a release archive without spawning a process.
//!
//! Linux and macOS releases are `.tar.gz` archives and the Windows release is a
//! `.zip`. Every entry name is checked before anything is written, links are
//! refused, and only the binary at the archive root is written, so nothing
//! can land outside the destination directory.

const std = @import("std");
const builtin = @import("builtin");

pub const Format = enum {
    tar_gz,
    zip,

    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .tar_gz => ".tar.gz",
            .zip => ".zip",
        };
    }
};

/// The archive format pf publishes for the running platform.
pub const native_format: Format = if (builtin.os.tag == .windows) .zip else .tar_gz;
/// The binary name a release archive holds at its root.
pub const binary_name = if (builtin.os.tag == .windows) "pf.exe" else "pf";
/// pf refuses archives whose entries expand beyond this many bytes.
pub const max_uncompressed_bytes: u64 = 100 * 1024 * 1024;

pub const Error = error{
    /// An entry escapes the archive root, is a link, or the archive does not
    /// hold exactly one pf binary at its root.
    InvalidArchive,
    /// The entries expand beyond `max_uncompressed_bytes`.
    ArchiveTooLarge,
    /// The archive or the destination could not be read or written.
    ExtractionFailed,
};

/// Writes the archive's root `binary_name` entry to `dest_dir`. The caller
/// owns `dest_dir`, a fresh temporary directory, and deletes it on failure.
pub fn extractBinary(io: std.Io, archive_path: []const u8, format: Format, dest_dir: std.Io.Dir) Error!void {
    var file = std.Io.Dir.openFileAbsolute(io, archive_path, .{}) catch return error.ExtractionFailed;
    defer file.close(io);
    return switch (format) {
        .tar_gz => extractTarGz(io, file, dest_dir),
        .zip => extractZip(io, file, dest_dir),
    };
}

/// Tracks the entries seen so far and enforces the archive rules.
const Entries = struct {
    total_bytes: u64 = 0,
    found_binary: bool = false,

    /// Returns true when `name` is the binary to write.
    fn admit(self: *Entries, name: []const u8, size: u64) Error!bool {
        if (!isSafeEntryName(name)) return error.InvalidArchive;
        self.total_bytes +|= size;
        if (self.total_bytes > max_uncompressed_bytes) return error.ArchiveTooLarge;
        if (!std.mem.eql(u8, name, "pf") and !std.mem.eql(u8, name, "pf.exe")) return false;
        if (self.found_binary or !std.mem.eql(u8, name, binary_name)) return error.InvalidArchive;
        self.found_binary = true;
        return true;
    }

    fn finish(self: Entries) Error!void {
        if (!self.found_binary) return error.InvalidArchive;
    }
};

/// Accepts relative `/`-separated names without `.`/`..` components, drive
/// letters, or backslashes. A trailing `/` marks a directory.
fn isSafeEntryName(raw: []const u8) bool {
    const name = std.mem.trimEnd(u8, raw, "/");
    if (name.len == 0 or name[0] == '/') return false;
    if (std.mem.findAny(u8, name, "\\:") != null) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn createBinary(io: std.Io, dest_dir: std.Io.Dir) Error!std.Io.File {
    return dest_dir.createFile(io, binary_name, .{ .exclusive = true, .permissions = .executable_file }) catch
        error.ExtractionFailed;
}

fn extractTarGz(io: std.Io, file: std.Io.File, dest_dir: std.Io.Dir) Error!void {
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.readerStreaming(io, &file_buf);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &window);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tar = std.tar.Iterator.init(&gzip.reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    var entries: Entries = .{};
    // Hard links and other special entries fail inside `next`.
    while (tar.next() catch return readError(&file_reader)) |entry| {
        if (entry.kind == .sym_link) return error.InvalidArchive;
        const size = if (entry.kind == .file) entry.size else 0;
        if (!try entries.admit(entry.name, size) or entry.kind != .file) continue;

        var out = try createBinary(io, dest_dir);
        defer out.close(io);
        var out_buf: [64 * 1024]u8 = undefined;
        var out_writer = out.writerStreaming(io, &out_buf);
        tar.streamRemaining(entry, &out_writer.interface) catch |err| return switch (err) {
            error.WriteFailed => error.ExtractionFailed,
            error.ReadFailed, error.EndOfStream => readError(&file_reader),
        };
        out_writer.interface.flush() catch return error.ExtractionFailed;
    }
    return entries.finish();
}

/// A read failure of the archive file itself is an I/O error; any other
/// failure while decoding means the archive is malformed.
fn readError(file_reader: *std.Io.File.Reader) Error {
    return if (file_reader.err != null) error.ExtractionFailed else error.InvalidArchive;
}

fn extractZip(io: std.Io, file: std.Io.File, dest_dir: std.Io.Dir) Error!void {
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    var zip = std.zip.Iterator.init(&file_reader) catch return readError(&file_reader);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;

    var entries: Entries = .{};
    while (zip.next() catch return readError(&file_reader)) |entry| {
        if (entry.filename_len > name_buf.len) return error.InvalidArchive;
        file_reader.seekTo(entry.header_zip_offset) catch return error.ExtractionFailed;
        const header = file_reader.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little) catch
            return readError(&file_reader);
        const name = name_buf[0..entry.filename_len];
        file_reader.interface.readSliceAll(name) catch return readError(&file_reader);
        // Unix hosts store the file type in the high bits; refuse links.
        const unix_type = (header.external_file_attributes >> 16) & 0o170000;
        if (unix_type == 0o120000) return error.InvalidArchive;
        if (!try entries.admit(name, entry.uncompressed_size)) continue;

        entry.extract(&file_reader, .{}, &name_buf, dest_dir) catch |err| return switch (err) {
            error.ReadFailed => error.ExtractionFailed,
            error.AccessDenied, error.NoSpaceLeft, error.WriteFailed => error.ExtractionFailed,
            else => error.InvalidArchive,
        };
    }
    return entries.finish();
}

const TestEntry = struct {
    name: []const u8,
    data: []const u8 = "",
    kind: enum { file, directory, sym_link } = .file,
    /// Size claimed by the entry header instead of `data.len`; the data is
    /// left out of a tar entry.
    declared_size: ?u32 = null,
};

fn writeTestTarGz(alloc: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, entries: []const TestEntry) !void {
    var tar_bytes: std.Io.Writer.Allocating = .init(alloc);
    defer tar_bytes.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_bytes.writer };
    for (entries) |entry| switch (entry.kind) {
        .file => if (entry.declared_size) |size| {
            var header: std.tar.Writer.Header = .init(.regular);
            try header.setPath("", entry.name);
            try header.setSize(size);
            try header.write(&tar_bytes.writer);
        } else try tar.writeFileBytes(entry.name, entry.data, .{ .mode = 0o755 }),
        .directory => try tar.writeDir(entry.name, .{}),
        .sym_link => try tar.writeLink(entry.name, entry.data, .{}),
    };
    try tar.finishPedantically();

    var gz_bytes: std.Io.Writer.Allocating = try .initCapacity(alloc, 4096);
    defer gz_bytes.deinit();
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);
    const compress = try alloc.create(std.compress.flate.Compress);
    defer alloc.destroy(compress);
    compress.* = try .init(&gz_bytes.writer, window, .gzip, .default);
    try compress.writer.writeAll(tar_bytes.written());
    try compress.finish();
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = gz_bytes.written() });
}

fn deflateRaw(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    // Compress asserts room for its header in the output buffer.
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, 4096);
    defer out.deinit();
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);
    const compress = try alloc.create(std.compress.flate.Compress);
    defer alloc.destroy(compress);
    compress.* = try .init(&out.writer, window, .raw, .default);
    try compress.writer.writeAll(data);
    try compress.finish();
    return out.toOwnedSlice();
}

/// Writes a zip with deflated entries, as PowerShell's Compress-Archive does.
fn writeTestZip(alloc: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, entries: []const TestEntry) !void {
    var local: std.Io.Writer.Allocating = .init(alloc);
    defer local.deinit();
    var central: std.Io.Writer.Allocating = .init(alloc);
    defer central.deinit();
    for (entries) |entry| {
        const compressed = try deflateRaw(alloc, entry.data);
        defer alloc.free(compressed);
        const crc = std.hash.Crc32.hash(entry.data);
        const mode: u32 = switch (entry.kind) {
            .file => 0o100755,
            .directory => 0o040755,
            .sym_link => 0o120777,
        };
        const offset: u32 = @intCast(local.written().len);
        const w = &local.writer;
        try w.writeAll(&std.zip.local_file_header_sig);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 8, .little);
        try w.writeInt(u32, 0, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(compressed.len), .little);
        try w.writeInt(u32, entry.declared_size orelse @intCast(entry.data.len), .little);
        try w.writeInt(u16, @intCast(entry.name.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(entry.name);
        try w.writeAll(compressed);

        const c = &central.writer;
        try c.writeAll(&std.zip.central_file_header_sig);
        try c.writeInt(u16, (3 << 8) | 20, .little);
        try c.writeInt(u16, 20, .little);
        try c.writeInt(u16, 0, .little);
        try c.writeInt(u16, 8, .little);
        try c.writeInt(u32, 0, .little);
        try c.writeInt(u32, crc, .little);
        try c.writeInt(u32, @intCast(compressed.len), .little);
        try c.writeInt(u32, entry.declared_size orelse @intCast(entry.data.len), .little);
        try c.writeInt(u16, @intCast(entry.name.len), .little);
        try c.writeInt(u16, 0, .little);
        try c.writeInt(u16, 0, .little);
        try c.writeInt(u16, 0, .little);
        try c.writeInt(u16, 0, .little);
        try c.writeInt(u32, mode << 16, .little);
        try c.writeInt(u32, offset, .little);
        try c.writeAll(entry.name);
    }
    const w = &local.writer;
    const central_offset: u32 = @intCast(local.written().len);
    try w.writeAll(central.written());
    try w.writeAll(&std.zip.end_record_sig);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u32, @intCast(central.written().len), .little);
    try w.writeInt(u32, central_offset, .little);
    try w.writeInt(u16, 0, .little);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = local.written() });
}

const TestArchive = struct {
    tmp: std.testing.TmpDir,
    archive_path: []u8,
    out: std.Io.Dir,

    fn init(alloc: std.mem.Allocator, format: Format, entries: []const TestEntry) !TestArchive {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const name = if (format == .zip) "release.zip" else "release.tar.gz";
        switch (format) {
            .tar_gz => try writeTestTarGz(alloc, tmp.dir, name, entries),
            .zip => try writeTestZip(alloc, tmp.dir, name, entries),
        }
        const root = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(root);
        const archive_path = try std.fs.path.join(alloc, &.{ root, name });
        errdefer alloc.free(archive_path);
        try tmp.dir.createDir(std.testing.io, "out", .default_dir);
        const out = try tmp.dir.openDir(std.testing.io, "out", .{ .iterate = true });
        return .{ .tmp = tmp, .archive_path = archive_path, .out = out };
    }

    fn deinit(self: *TestArchive, alloc: std.mem.Allocator) void {
        self.out.close(std.testing.io);
        alloc.free(self.archive_path);
        self.tmp.cleanup();
    }

    fn extract(self: *TestArchive, format: Format) Error!void {
        return extractBinary(std.testing.io, self.archive_path, format, self.out);
    }

    /// Fails unless `out` holds at most the binary and the parent directory
    /// holds only the archive and `out`.
    fn expectNothingElseWritten(self: *TestArchive) !void {
        var it = self.out.iterate();
        while (try it.next(std.testing.io)) |entry| {
            try std.testing.expectEqualStrings(binary_name, entry.name);
        }
        var parent = try self.tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
        defer parent.close(std.testing.io);
        var parent_it = parent.iterate();
        var count: usize = 0;
        while (try parent_it.next(std.testing.io)) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 2), count);
    }
};

test "release archive extracts the root binary from tar.gz and zip" {
    const alloc = std.testing.allocator;
    const entries = [_]TestEntry{
        .{ .name = binary_name, .data = "new pf binary" },
        .{ .name = "LICENSE", .data = "license" },
        .{ .name = "docs/", .kind = .directory },
    };
    for ([_]Format{ .tar_gz, .zip }) |format| {
        var archive = try TestArchive.init(alloc, format, &entries);
        defer archive.deinit(alloc);
        try archive.extract(format);
        const extracted = try archive.out.readFileAlloc(std.testing.io, binary_name, alloc, .limited(1024));
        defer alloc.free(extracted);
        try std.testing.expectEqualStrings("new pf binary", extracted);
        try archive.expectNothingElseWritten();
        if (builtin.os.tag != .windows) {
            const stat = try archive.out.statFile(std.testing.io, binary_name, .{});
            try std.testing.expect(stat.permissions.toMode() & 0o100 != 0);
        }
    }
}

test "release archive refuses escaping names and links" {
    const alloc = std.testing.allocator;
    const cases = [_][]const TestEntry{
        &.{ .{ .name = binary_name, .data = "pf" }, .{ .name = "/tmp/pf-escape", .data = "x" } },
        &.{ .{ .name = binary_name, .data = "pf" }, .{ .name = "../pf-escape", .data = "x" } },
        &.{ .{ .name = binary_name, .data = "pf" }, .{ .name = "docs/../../pf-escape", .data = "x" } },
        &.{ .{ .name = "link", .data = "/etc/passwd", .kind = .sym_link }, .{ .name = binary_name, .data = "pf" } },
        &.{.{ .name = binary_name, .data = "/bin/sh", .kind = .sym_link }},
    };
    for ([_]Format{ .tar_gz, .zip }) |format| {
        for (cases) |entries| {
            var archive = try TestArchive.init(alloc, format, entries);
            defer archive.deinit(alloc);
            try std.testing.expectError(error.InvalidArchive, archive.extract(format));
            try archive.expectNothingElseWritten();
        }
    }

    var drive = try TestArchive.init(alloc, .zip, &.{.{ .name = "C:pf-escape", .data = "x" }});
    defer drive.deinit(alloc);
    try std.testing.expectError(error.InvalidArchive, drive.extract(.zip));
    var backslash = try TestArchive.init(alloc, .zip, &.{.{ .name = "..\\pf-escape", .data = "x" }});
    defer backslash.deinit(alloc);
    try std.testing.expectError(error.InvalidArchive, backslash.extract(.zip));
}

test "release archive requires exactly one binary at the root" {
    const alloc = std.testing.allocator;
    const other_name = if (builtin.os.tag == .windows) "pf" else "pf.exe";
    const cases = [_][]const TestEntry{
        &.{.{ .name = "LICENSE", .data = "license" }},
        &.{.{ .name = "bin/" ++ binary_name, .data = "nested" }},
        &.{.{ .name = other_name, .data = "wrong platform" }},
        &.{ .{ .name = binary_name, .data = "one" }, .{ .name = other_name, .data = "two" } },
    };
    for ([_]Format{ .tar_gz, .zip }) |format| {
        for (cases) |entries| {
            var archive = try TestArchive.init(alloc, format, entries);
            defer archive.deinit(alloc);
            try std.testing.expectError(error.InvalidArchive, archive.extract(format));
        }
    }
}

test "release archive stops at the uncompressed size limit" {
    const alloc = std.testing.allocator;
    const over: u32 = @intCast(max_uncompressed_bytes + 1);
    const half: u32 = @intCast(max_uncompressed_bytes / 2 + 1);
    const single = [_]TestEntry{
        .{ .name = "padding", .declared_size = over },
        .{ .name = binary_name, .data = "pf" },
    };
    for ([_]Format{ .tar_gz, .zip }) |format| {
        var archive = try TestArchive.init(alloc, format, &single);
        defer archive.deinit(alloc);
        try std.testing.expectError(error.ArchiveTooLarge, archive.extract(format));
        try archive.expectNothingElseWritten();
    }

    // The zip central directory declares every size up front, so the limit
    // applies to the sum before any entry is read.
    var summed = try TestArchive.init(alloc, .zip, &.{
        .{ .name = "padding-a", .declared_size = half },
        .{ .name = "padding-b", .declared_size = half },
        .{ .name = binary_name, .data = "pf" },
    });
    defer summed.deinit(alloc);
    try std.testing.expectError(error.ArchiveTooLarge, summed.extract(.zip));
    try summed.expectNothingElseWritten();
}

test "release archive refuses corrupt archives" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "garbage", .data = "not an archive at all" });
    const root = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "garbage" });
    defer alloc.free(path);
    try std.testing.expectError(error.InvalidArchive, extractBinary(std.testing.io, path, .tar_gz, tmp.dir));
    try std.testing.expectError(error.InvalidArchive, extractBinary(std.testing.io, path, .zip, tmp.dir));
}
