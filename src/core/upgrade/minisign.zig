//! Verifies minisign signatures of pf release archives.
//!
//! pf accepts only minisign's prehashed `ED` algorithm: Ed25519 over the
//! BLAKE2b-512 digest of the file. The trusted comment is covered by the global
//! signature and must name the exact file, version, and channel pf expects, so
//! a valid signature cannot be moved to another archive or relabeled as another
//! release.

const std = @import("std");
const builtin = @import("builtin");

const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const base64 = std.base64.standard;

/// Upper bound for a `.minisig` file; a signature with the longest trusted
/// comment pf writes is far below it.
pub const max_signature_bytes: usize = 4096;

const key_id_len = 8;
const public_key_raw_len = 2 + key_id_len + Ed25519.PublicKey.encoded_length;
const signature_raw_len = 2 + key_id_len + Ed25519.Signature.encoded_length;
const untrusted_prefix = "untrusted comment: ";
const trusted_prefix = "trusted comment: ";

pub const Error = error{
    /// The file does not have minisign's four-line layout.
    MalformedSignature,
    /// The signature uses minisign's legacy `Ed` algorithm, which signs the
    /// file without prehashing it.
    LegacyAlgorithm,
    /// The signature's key id matches none of the trusted public keys.
    UnknownKey,
    /// The archive bytes do not match the signature.
    InvalidSignature,
    /// The trusted comment does not match the global signature.
    InvalidTrustedComment,
    /// The trusted comment names another file, version, channel, or commit.
    ReleaseMismatch,
    /// The archive could not be read.
    ReadFailed,
};

pub const PublicKey = struct {
    key_id: [key_id_len]u8,
    key: Ed25519.PublicKey,

    /// Parses the base64 line of a `minisign.pub` file.
    pub fn parse(text: []const u8) error{InvalidPublicKey}!PublicKey {
        var raw: [public_key_raw_len]u8 = undefined;
        decodeExact(&raw, std.mem.trim(u8, text, " \t\r\n")) catch return error.InvalidPublicKey;
        if (!std.mem.eql(u8, raw[0..2], "Ed")) return error.InvalidPublicKey;
        return .{
            .key_id = raw[2..][0..key_id_len].*,
            .key = Ed25519.PublicKey.fromBytes(raw[2 + key_id_len ..][0..Ed25519.PublicKey.encoded_length].*) catch
                return error.InvalidPublicKey,
        };
    }
};

/// The release a signature must belong to. `commit` is set only for dev
/// builds, whose trusted comment also names the commit.
pub const Expected = struct {
    file: []const u8,
    version: []const u8,
    channel: []const u8,
    commit: ?[]const u8 = null,
};

const Signature = struct {
    key_id: [key_id_len]u8,
    signature: Ed25519.Signature,
    trusted_comment: []const u8,
    global_signature: Ed25519.Signature,

    fn parse(bytes: []const u8) Error!Signature {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const untrusted = trimCr(lines.next() orelse return error.MalformedSignature);
        if (!std.mem.startsWith(u8, untrusted, untrusted_prefix)) return error.MalformedSignature;

        var raw: [signature_raw_len]u8 = undefined;
        decodeExact(&raw, trimCr(lines.next() orelse return error.MalformedSignature)) catch
            return error.MalformedSignature;
        if (std.mem.eql(u8, raw[0..2], "Ed")) return error.LegacyAlgorithm;
        if (!std.mem.eql(u8, raw[0..2], "ED")) return error.MalformedSignature;

        const trusted = trimCr(lines.next() orelse return error.MalformedSignature);
        if (!std.mem.startsWith(u8, trusted, trusted_prefix)) return error.MalformedSignature;

        var global: [Ed25519.Signature.encoded_length]u8 = undefined;
        decodeExact(&global, trimCr(lines.next() orelse return error.MalformedSignature)) catch
            return error.MalformedSignature;
        while (lines.next()) |rest| {
            if (trimCr(rest).len != 0) return error.MalformedSignature;
        }

        return .{
            .key_id = raw[2..][0..key_id_len].*,
            .signature = .fromBytes(raw[2 + key_id_len ..][0..Ed25519.Signature.encoded_length].*),
            .trusted_comment = trusted[trusted_prefix.len..],
            .global_signature = .fromBytes(global),
        };
    }
};

/// Verifies `signature_bytes` (a `.minisig` file) over the contents of
/// `file`, read from its current position to the end, against `trusted_keys`.
/// Succeeds only when the archive signature, the global signature, and the
/// trusted comment all match.
pub fn verifyFile(
    io: std.Io,
    file: std.Io.File,
    signature_bytes: []const u8,
    trusted_keys: []const PublicKey,
    expected: Expected,
) Error!void {
    const sig = try Signature.parse(signature_bytes);
    const key = findKey(trusted_keys, sig.key_id) orelse return error.UnknownKey;

    var hasher = Blake2b512.init(.{});
    var read_buf: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ReadFailed,
        };
        hasher.update(chunk);
        reader.interface.toss(chunk.len);
    }
    var digest: [Blake2b512.digest_length]u8 = undefined;
    hasher.final(&digest);
    sig.signature.verify(&digest, key.key) catch return error.InvalidSignature;

    var global = sig.global_signature.verifier(key.key) catch return error.InvalidTrustedComment;
    global.update(&sig.signature.toBytes());
    global.update(sig.trusted_comment);
    global.verify() catch return error.InvalidTrustedComment;

    if (!commentMatches(sig.trusted_comment, expected)) return error.ReleaseMismatch;
}

fn findKey(keys: []const PublicKey, key_id: [key_id_len]u8) ?PublicKey {
    for (keys) |key| {
        if (std.mem.eql(u8, &key.key_id, &key_id)) return key;
    }
    return null;
}

/// The comment must hold exactly one `file:`, `version:`, and `channel:`
/// field, plus `commit:` when one is expected, and nothing else. Versions
/// compare without a leading `v`, since release tags carry one.
fn commentMatches(comment: []const u8, expected: Expected) bool {
    var file = false;
    var version = false;
    var channel = false;
    var commit = false;
    var fields = std.mem.tokenizeScalar(u8, comment, ' ');
    while (fields.next()) |field| {
        const colon = std.mem.findScalar(u8, field, ':') orelse return false;
        const name = field[0..colon];
        const value = field[colon + 1 ..];
        const seen, const matches = if (std.mem.eql(u8, name, "file"))
            .{ &file, std.mem.eql(u8, value, expected.file) }
        else if (std.mem.eql(u8, name, "version"))
            .{ &version, std.mem.eql(u8, withoutV(value), withoutV(expected.version)) }
        else if (std.mem.eql(u8, name, "channel"))
            .{ &channel, std.mem.eql(u8, value, expected.channel) }
        else if (std.mem.eql(u8, name, "commit"))
            .{ &commit, expected.commit != null and std.mem.eql(u8, value, expected.commit.?) }
        else
            return false;
        if (seen.* or !matches) return false;
        seen.* = true;
    }
    return file and version and channel and commit == (expected.commit != null);
}

fn withoutV(version: []const u8) []const u8 {
    return if (version.len > 0 and version[0] == 'v') version[1..] else version;
}

fn trimCr(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

fn decodeExact(dest: []u8, text: []const u8) !void {
    if (try base64.Decoder.calcSizeForSlice(text) != dest.len) return error.InvalidLength;
    try base64.Decoder.decode(dest, text);
}

const TestSigner = struct {
    key_pair: Ed25519.KeyPair,
    key_id: [key_id_len]u8,

    fn init(seed_byte: u8, key_id_byte: u8) !TestSigner {
        return .{
            .key_pair = try Ed25519.KeyPair.generateDeterministic(@splat(seed_byte)),
            .key_id = @splat(key_id_byte),
        };
    }

    fn publicKey(self: TestSigner) PublicKey {
        return .{ .key_id = self.key_id, .key = self.key_pair.public_key };
    }

    fn publicKeyText(self: TestSigner, out: *[base64.Encoder.calcSize(public_key_raw_len)]u8) []const u8 {
        const raw = "Ed".* ++ self.key_id ++ self.key_pair.public_key.toBytes();
        return base64.Encoder.encode(out, &raw);
    }

    /// Writes a `.minisig` for `data` the way `minisign -S` does.
    fn sign(self: TestSigner, alloc: std.mem.Allocator, algorithm: *const [2]u8, data: []const u8, comment: []const u8) ![]u8 {
        var digest: [Blake2b512.digest_length]u8 = undefined;
        Blake2b512.hash(data, &digest, .{});
        const signed: []const u8 = if (std.mem.eql(u8, algorithm, "ED")) &digest else data;
        const signature = (try self.key_pair.sign(signed, null)).toBytes();
        const global_message = try std.mem.concat(alloc, u8, &.{ &signature, comment });
        defer alloc.free(global_message);
        const global = (try self.key_pair.sign(global_message, null)).toBytes();

        const raw = algorithm.* ++ self.key_id ++ signature;
        var raw_b64: [base64.Encoder.calcSize(signature_raw_len)]u8 = undefined;
        var global_b64: [base64.Encoder.calcSize(global.len)]u8 = undefined;
        return std.fmt.allocPrint(alloc, "untrusted comment: signature from pf test key\n{s}\ntrusted comment: {s}\n{s}\n", .{
            base64.Encoder.encode(&raw_b64, &raw),
            comment,
            base64.Encoder.encode(&global_b64, &global),
        });
    }
};

const test_comment = "file:pf-linux-x86_64.tar.gz version:v0.1.0 channel:stable";
const test_expected: Expected = .{ .file = "pf-linux-x86_64.tar.gz", .version = "v0.1.0", .channel = "stable" };

fn verifyBytes(data: []const u8, signature: []const u8, keys: []const PublicKey, expected: Expected) Error!void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(io, .{ .sub_path = "archive", .data = data }) catch return error.ReadFailed;
    var file = tmp.dir.openFile(io, "archive", .{}) catch return error.ReadFailed;
    defer file.close(io);
    return verifyFile(io, file, signature, keys, expected);
}

test "minisign accepts a prehashed signature with the expected trusted comment" {
    const alloc = std.testing.allocator;
    const signer = try TestSigner.init(1, 0x11);
    const other = try TestSigner.init(2, 0x22);
    const sig = try signer.sign(alloc, "ED", "archive bytes", test_comment);
    defer alloc.free(sig);

    try verifyBytes("archive bytes", sig, &.{ other.publicKey(), signer.publicKey() }, test_expected);
    // Release tags carry a `v`; the expected version may omit it.
    try verifyBytes("archive bytes", sig, &.{signer.publicKey()}, .{
        .file = "pf-linux-x86_64.tar.gz",
        .version = "0.1.0",
        .channel = "stable",
    });
}

test "minisign rejects each tampering case with a distinct error" {
    const alloc = std.testing.allocator;
    const signer = try TestSigner.init(1, 0x11);
    const keys = [_]PublicKey{signer.publicKey()};
    const sig = try signer.sign(alloc, "ED", "archive bytes", test_comment);
    defer alloc.free(sig);

    try std.testing.expectError(error.InvalidSignature, verifyBytes("archive bytez", sig, &keys, test_expected));

    const tampered_comment = try std.mem.replaceOwned(u8, alloc, sig, "v0.1.0", "v0.2.0");
    defer alloc.free(tampered_comment);
    try std.testing.expectError(error.InvalidTrustedComment, verifyBytes("archive bytes", tampered_comment, &keys, .{
        .file = "pf-linux-x86_64.tar.gz",
        .version = "v0.2.0",
        .channel = "stable",
    }));

    const stranger = try TestSigner.init(3, 0x33);
    const unknown = try stranger.sign(alloc, "ED", "archive bytes", test_comment);
    defer alloc.free(unknown);
    try std.testing.expectError(error.UnknownKey, verifyBytes("archive bytes", unknown, &keys, test_expected));

    const legacy = try signer.sign(alloc, "Ed", "archive bytes", test_comment);
    defer alloc.free(legacy);
    try std.testing.expectError(error.LegacyAlgorithm, verifyBytes("archive bytes", legacy, &keys, test_expected));

    try std.testing.expectError(error.MalformedSignature, verifyBytes("archive bytes", sig[0 .. sig.len / 2], &keys, test_expected));
    try std.testing.expectError(error.MalformedSignature, verifyBytes("archive bytes", "", &keys, test_expected));
}

test "minisign binds the signature to the file, version, channel, and commit" {
    const alloc = std.testing.allocator;
    const signer = try TestSigner.init(1, 0x11);
    const keys = [_]PublicKey{signer.publicKey()};
    const sig = try signer.sign(alloc, "ED", "archive bytes", test_comment);
    defer alloc.free(sig);

    const mismatches = [_]Expected{
        .{ .file = "pf-macos-aarch64.tar.gz", .version = "v0.1.0", .channel = "stable" },
        .{ .file = "pf-linux-x86_64.tar.gz", .version = "v0.0.9", .channel = "stable" },
        .{ .file = "pf-linux-x86_64.tar.gz", .version = "v0.1.0", .channel = "dev" },
        .{ .file = "pf-linux-x86_64.tar.gz", .version = "v0.1.0", .channel = "stable", .commit = "0123456" },
    };
    for (mismatches) |expected| {
        try std.testing.expectError(error.ReleaseMismatch, verifyBytes("archive bytes", sig, &keys, expected));
    }

    const dev_comment = "file:pf-linux-x86_64.tar.gz version:0.1.0 channel:dev commit:0123456789ab";
    const dev_sig = try signer.sign(alloc, "ED", "archive bytes", dev_comment);
    defer alloc.free(dev_sig);
    try verifyBytes("archive bytes", dev_sig, &keys, .{
        .file = "pf-linux-x86_64.tar.gz",
        .version = "0.1.0",
        .channel = "dev",
        .commit = "0123456789ab",
    });
    try std.testing.expectError(error.ReleaseMismatch, verifyBytes("archive bytes", dev_sig, &keys, .{
        .file = "pf-linux-x86_64.tar.gz",
        .version = "0.1.0",
        .channel = "dev",
    }));
    try std.testing.expectError(error.ReleaseMismatch, verifyBytes("archive bytes", dev_sig, &keys, .{
        .file = "pf-linux-x86_64.tar.gz",
        .version = "0.1.0",
        .channel = "dev",
        .commit = "fedcba987654",
    }));

    const padded = try signer.sign(alloc, "ED", "archive bytes", test_comment ++ " extra:1");
    defer alloc.free(padded);
    try std.testing.expectError(error.ReleaseMismatch, verifyBytes("archive bytes", padded, &keys, test_expected));
    const repeated = try signer.sign(alloc, "ED", "archive bytes", test_comment ++ " version:v0.1.0");
    defer alloc.free(repeated);
    try std.testing.expectError(error.ReleaseMismatch, verifyBytes("archive bytes", repeated, &keys, test_expected));
}

test "minisign parses public keys and rejects malformed ones" {
    const signer = try TestSigner.init(1, 0x11);
    var text_buf: [base64.Encoder.calcSize(public_key_raw_len)]u8 = undefined;
    const parsed = try PublicKey.parse(signer.publicKeyText(&text_buf));
    try std.testing.expectEqualSlices(u8, &signer.key_id, &parsed.key_id);

    try std.testing.expectError(error.InvalidPublicKey, PublicKey.parse(""));
    try std.testing.expectError(error.InvalidPublicKey, PublicKey.parse("RWQ"));
    var other_algorithm = text_buf;
    other_algorithm[0] = 'A';
    try std.testing.expectError(error.InvalidPublicKey, PublicKey.parse(&other_algorithm));
}

test "minisign verifies a 15 MB archive within the release budget" {
    const alloc = std.testing.allocator;
    const signer = try TestSigner.init(1, 0x11);
    const data = try alloc.alloc(u8, 15 * 1024 * 1024);
    defer alloc.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    const sig = try signer.sign(alloc, "ED", data, test_comment);
    defer alloc.free(sig);

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "archive", .data = data });
    var file = try tmp.dir.openFile(io, "archive", .{});
    defer file.close(io);

    const started = std.Io.Timestamp.now(io, .awake);
    try verifyFile(io, file, sig, &.{signer.publicKey()}, test_expected);
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    // Debug builds are not the shipped binary; the budget applies to ReleaseSafe.
    if (builtin.mode != .Debug) try std.testing.expect(elapsed_ms < 500);
}
