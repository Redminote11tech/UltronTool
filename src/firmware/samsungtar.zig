//! Samsung tar.md5 firmware bundle reader.
//!
//! Samsung BL/AP/CP/CSC packages are plain ustar archives whose image
//! members are followed by `<name>.md5` checksum members (the official
//! odin4 verifies these — CryptoPP is embedded for it). This module lists
//! the members without loading anything: flashing streams straight from
//! the archive at the member's byte offset.

const std = @import("std");
const log = @import("../core/log.zig");
const fileio = @import("../core/fileio.zig");

pub const block_size = 512;

pub const Error = error{ NotTar, Truncated, CorruptHeader, UnsupportedEntry, OutOfMemory };

pub const Member = struct {
    name_buf: [128]u8 = undefined,
    name_len: usize = 0,
    /// Byte offset of the member's data inside the archive file.
    data_offset: u64 = 0,
    /// Data size in bytes.
    size: u64 = 0,

    pub fn nameSlice(self: *const Member) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Checksum members ("boot.img.md5") carry the md5 of the preceding
    /// image and are never flashed.
    pub fn isMd5(self: *const Member) bool {
        return std.mem.endsWith(u8, self.nameSlice(), ".md5");
    }
};

pub const Archive = struct {
    members: []Member,
    count: usize,

    pub fn deinit(self: *Archive, alloc: std.mem.Allocator) void {
        alloc.free(self.members);
        self.members = &.{};
        self.count = 0;
    }

    pub fn find(self: *const Archive, name: []const u8) ?*const Member {
        for (self.members[0..self.count]) |*m| {
            if (std.mem.eql(u8, m.nameSlice(), name)) return m;
        }
        return null;
    }
};

/// Parse an octal size field (space/NUL-terminated, e.g. "0000012345\0").
fn parseOctal(field: []const u8) u64 {
    var v: u64 = 0;
    for (field) |ch| {
        if (ch < '0' or ch > '7') {
            if (v > 0) break; // terminator reached
            continue; // leading spaces
        }
        v = v * 8 + (ch - '0');
    }
    return v;
}

fn copyName(bytes: []const u8, out: []u8) usize {
    var len: usize = 0;
    while (len < bytes.len and len < out.len and bytes[len] != 0) : (len += 1) {}
    // Trailing spaces are padding in some tars.
    while (len > 0 and (bytes[len - 1] == ' ')) len -= 1;
    @memcpy(out[0..len], bytes[0..len]);
    return len;
}

/// List all regular-file members of a ustar archive.
pub fn list(alloc: std.mem.Allocator, path: []const u8, logger: *log.Logger) !Archive {
    var file = try fileio.File.open(path);
    defer file.close();

    var members = std.ArrayList(Member).empty;
    errdefer members.deinit(alloc);

    var pos: u64 = 0;
    const total = try file.size();
    while (pos + block_size <= total) {
        var hdr: [block_size]u8 = undefined;
        file.seekTo(pos) catch return error.Truncated;
        if ((try file.readAll(&hdr)) < block_size) return error.Truncated;

        // End of archive: zero block.
        var nonzero = false;
        for (hdr) |b| {
            if (b != 0) {
                nonzero = true;
                break;
            }
        }
        if (!nonzero) break;

        if (!std.mem.eql(u8, hdr[257..262], "ustar")) {
            logger.err("tar member at offset {d} is not ustar", .{pos});
            return error.NotTar;
        }
        const typeflag = hdr[156];
        if (typeflag == 'L') {
            // GNU long names: Samsung firmware does not use them; refuse
            // rather than flashing under a truncated name.
            logger.err("GNU long-name entries are not supported", .{});
            return error.UnsupportedEntry;
        }

        var m = Member{};
        const size = parseOctal(hdr[124..136]);

        const regular = typeflag == '0' or typeflag == 0;
        if (regular) {
            m.data_offset = pos + block_size;
            m.size = size;
            // GNU tar puts long names in the prefix/name pair; join them.
            const prefix = copyName(hdr[345..500], &m.name_buf);
            if (prefix > 0) {
                if (prefix + 1 >= m.name_buf.len) return error.CorruptHeader;
                m.name_buf[prefix] = '/';
                m.name_len = prefix + copyName(hdr[0..100], m.name_buf[prefix + 1 .. m.name_buf.len]) + 1;
            } else {
                m.name_len = copyName(hdr[0..100], &m.name_buf);
            }
            try members.append(alloc, m);
        } else if (typeflag == '5') {
            // directory: skip
        } else if (typeflag == 'x' or typeflag == 'g') {
            // pax headers carry metadata: skip (size is honoured below)
        } else {
            logger.warn("tar: skipping member type '{c}' at offset {d}", .{ typeflag, pos });
        }

        pos += block_size + ((size + block_size - 1) / block_size) * block_size;
    }

    const count = members.items.len;
    return .{ .members = try members.toOwnedSlice(alloc), .count = count };
}

/// Stream-md5 a member's data range and compare against the expected hex
/// digest (odin4 verifies the .md5 members before flashing).
pub fn verifyMd5(alloc: std.mem.Allocator, path: []const u8, member: *const Member, expected_hex: []const u8, logger: *log.Logger) !bool {
    var file = try fileio.File.open(path);
    defer file.close();
    try file.seekTo(member.data_offset);

    var hasher = std.crypto.hash.Md5.init(.{});
    const buf = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(buf);

    var left = member.size;
    while (left > 0) {
        const want: usize = @intCast(@min(left, buf.len));
        const n = try file.readAll(buf[0..want]);
        if (n == 0) {
            logger.err("tar member \"{s}\" truncated while hashing", .{member.nameSlice()});
            return false;
        }
        hasher.update(buf[0..n]);
        left -= n;
    }

    var digest: [16]u8 = undefined;
    hasher.final(&digest);
    var hex: [32]u8 = undefined;
    const hexdigits = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = hexdigits[b >> 4];
        hex[i * 2 + 1] = hexdigits[b & 0xf];
    }

    // The .md5 member content is "<hex>  <name>" — compare the hex prefix.
    if (expected_hex.len < 32) {
        logger.err("tar: malformed md5 entry for \"{s}\"", .{member.nameSlice()});
        return false;
    }
    return std.mem.eql(u8, hex[0..], expected_hex[0..32]);
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn octalField(comptime n: usize, v: u64) [n]u8 {
    var f: [n]u8 = @splat('0');
    var val = v;
    var i: usize = n - 1;
    while (i > 0) {
        f[i] = '0' + @as(u8, @intCast(val % 8));
        val /= 8;
        i -= 1;
    }
    f[0] = '0' + @as(u8, @intCast(val % 8));
    return f;
}

fn appendMember(out: *std.ArrayList(u8), name: []const u8, data: []const u8) !void {
    var hdr: [512]u8 = @splat(0);
    @memcpy(hdr[0..name.len], name);
    const sz = octalField(12, data.len);
    @memcpy(hdr[124..136], &sz);
    hdr[156] = '0';
    @memcpy(hdr[257..262], "ustar");
    try out.appendSlice(testing.allocator, &hdr);
    try out.appendSlice(testing.allocator, data);
    const pad = (block_size - (data.len % block_size)) % block_size;
    try out.appendNTimes(testing.allocator, 0, pad);
}

test "tar lists members and verifies md5" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();

    const image = "ABCDEFGHIJKLMNOP"; // 16 bytes
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(image);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    var hex_buf: [32]u8 = undefined;
    const hexdigits = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex_buf[i * 2] = hexdigits[b >> 4];
        hex_buf[i * 2 + 1] = hexdigits[b & 0xf];
    }
    const hex = hex_buf[0..];

    var tar = std.ArrayList(u8).empty;
    defer tar.deinit(testing.allocator);
    try appendMember(&tar, "boot.img", image);
    var md5_content: [40]u8 = @splat(0);
    @memcpy(md5_content[0..32], hex);
    try appendMember(&tar, "boot.img.md5", md5_content[0..]);
    try appendMember(&tar, "recovery.img", "XYZ");

    try tmp.writeFile("AP.tar.md5", tar.items);
    var pbuf: [176]u8 = undefined;
    const path = try tmp.filePath(&pbuf, "AP.tar.md5");

    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };

    var archive = try list(testing.allocator, path, l);
    defer archive.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), archive.count);
    const boot = archive.find("boot.img").?;
    try testing.expectEqual(@as(u64, 16), boot.size);
    try testing.expect(boot.data_offset == 512);
    try testing.expect(!boot.isMd5());
    try testing.expect(archive.find("boot.img.md5").?.isMd5());

    const md5_member = archive.find("boot.img.md5").?;
    try testing.expect(try verifyMd5(testing.allocator, path, boot, tar.items[md5_member.data_offset .. md5_member.data_offset + 32], l));
    // Wrong digest must fail.
    try testing.expect(!(try verifyMd5(testing.allocator, path, boot, "00000000000000000000000000000000", l)));
}

test "tar rejects non-ustar and supports end-of-archive" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();

    var tar = std.ArrayList(u8).empty;
    defer tar.deinit(testing.allocator);
    try appendMember(&tar, "a.img", "data");
    try tar.appendNTimes(testing.allocator, 0, 1024); // end blocks
    try tmp.writeFile("x.tar", tar.items);
    var pbuf: [176]u8 = undefined;
    const path = try tmp.filePath(&pbuf, "x.tar");

    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };

    var archive = try list(testing.allocator, path, l);
    defer archive.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), archive.count);

    tar.items[257] = 'X';
    try tmp.writeFile("bad.tar", tar.items);
    const bad = try tmp.filePath(&pbuf, "bad.tar");
    try testing.expectError(error.NotTar, list(testing.allocator, bad, l));
}
