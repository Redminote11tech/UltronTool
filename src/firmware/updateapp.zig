//! Huawei UPDATE.APP firmware container — port of the classic
//! splitupdate/split_updata.pl parsing (XDA community reference format).
//!
//! The file is a flat sequence of chunks. Each chunk starts with the magic
//! bytes 55 AA 5A A5 followed by a variable-length header (little-endian):
//!
//!   offset  size  field
//!   0       4     magic 55 AA 5A A5
//!   4       4     header length (>= 98; the data follows it)
//!   8       4     unknown
//!   12      8     hardware id
//!   20      4     file sequence number
//!   24      4     data size (bytes of payload after the header)
//!   28      16    file date string
//!   44      16    file time string
//!   60      32    entry name ("BOOT", "SYSTEM", …, NUL-padded)
//!   92      2     header checksum
//!   94      4     block size (checksum table granularity)
//!   98      ..    file checksum table (header_len - 98 bytes)
//!
//! Payloads are frequently Android sparse images (see ../firmware/sparse.zig)
//! that must be expanded before flashing. The checksum table is not verified
//! here — flashing runs its own SHA-256 verification against the device.

const std = @import("std");
const log = @import("../core/log.zig");
const fileio = @import("../core/fileio.zig");
const sparse = @import("sparse.zig");

pub const chunk_magic = [4]u8{ 0x55, 0xAA, 0x5A, 0xA5 };

/// Sanity bounds for one chunk header.
const min_header_len: u64 = 98;
const max_header_len: u64 = 64 * 1024;

/// Upper bound of entries in one UPDATE.APP (real packages have ~30–60).
pub const max_entries: usize = 128;

pub const Entry = struct {
    /// Absolute offset of the chunk magic inside the APP file.
    offset: u64 = 0,
    /// Header length in bytes (payload follows it).
    header_len: u64 = 0,
    /// Absolute offset of the payload.
    data_offset: u64 = 0,
    /// Payload size in bytes.
    data_size: u64 = 0,
    /// Expanded size for sparse payloads; equals data_size for raw ones.
    raw_size: u64 = 0,
    /// Payload starts with the Android sparse magic.
    is_sparse: bool = false,
    sequence: u32 = 0,
    hw: [8]u8 = undefined,
    name_buf: [32]u8 = undefined,
    name_len: usize = 0,

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Index = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Index, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
    }

    /// Find an entry by name, case-insensitively, ignoring an ".img"
    /// suffix on either side (UPDATE.APP entries carry bare names).
    pub fn find(self: *const Index, want: []const u8) ?*const Entry {
        for (self.entries.items) |*e| {
            if (nameEql(e.name(), want)) return e;
        }
        return null;
    }
};

fn stripImgSuffix(s: []const u8) []const u8 {
    if (s.len > 4 and std.ascii.eqlIgnoreCase(s[s.len - 4 ..], ".img")) return s[0 .. s.len - 4];
    return s;
}

pub fn nameEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(stripImgSuffix(a), stripImgSuffix(b));
}

/// Scan the whole file and index every chunk. Robust against padding and
/// (minor) corruption: after each chunk the parser scans forward for the
/// next magic instead of trusting alignment, like the Perl reference.
pub fn parse(alloc: std.mem.Allocator, file: *fileio.File, logger: *log.Logger) !Index {
    var index = Index{};
    errdefer index.deinit(alloc);

    const size = try file.size();
    var pos: u64 = 0;

    while (true) {
        pos = try findMagic(alloc, file, pos, size) orelse break;
        if (size - pos < min_header_len) break;

        var hdr: [102]u8 = undefined;
        try file.seekTo(pos);
        const got = try file.readAll(&hdr);
        if (got < min_header_len) break;

        const header_len: u64 = std.mem.readInt(u32, hdr[4..8], .little);
        if (header_len < min_header_len or header_len > max_header_len) {
            pos += 4; // bogus length: keep scanning for the next magic
            continue;
        }
        const data_size: u64 = std.mem.readInt(u32, hdr[24..28], .little);
        const data_offset: u64 = pos + header_len;
        if (data_offset > size or data_size > size - data_offset) {
            logger.warn("UPDATE.APP: chunk at 0x{x} claims data past EOF — stopping", .{pos});
            break;
        }

        var entry = Entry{
            .offset = pos,
            .header_len = header_len,
            .data_offset = data_offset,
            .data_size = data_size,
            .sequence = std.mem.readInt(u32, hdr[20..24], .little),
        };
        entry.hw = hdr[12..20].*;

        // Name: bytes 60..92, NUL-padded (classic tools read 16+16 and miss
        // names longer than 15 chars — ERECOVERY_RAMDISK taught better).
        const name_field = hdr[60..92];
        const nlen = std.mem.indexOfScalar(u8, name_field, 0) orelse name_field.len;
        entry.name_len = @min(nlen, entry.name_buf.len);
        @memcpy(entry.name_buf[0..entry.name_len], name_field[0..entry.name_len]);

        // Sparse detection + expanded size peek.
        try file.seekTo(data_offset);
        var magic: [4]u8 = undefined;
        const m = try file.readAll(&magic);
        if (m == 4 and sparse.isSparse(&magic)) {
            entry.is_sparse = true;
            try file.seekTo(data_offset);
            entry.raw_size = sparse.rawSizeAt(file) catch entry.data_size;
        } else {
            entry.raw_size = data_size;
        }

        try index.entries.append(alloc, entry);
        if (index.entries.items.len >= max_entries) {
            logger.warn("UPDATE.APP: more than {d} entries — ignoring the rest", .{max_entries});
            break;
        }

        pos = data_offset + data_size;
    }

    if (index.entries.items.len == 0) return error.NoEntries;
    logger.info("UPDATE.APP: {d} entries indexed", .{index.entries.items.len});
    return index;
}

/// Search for the next chunk magic from `start`, reading in 1 MiB windows
/// with a 3-byte overlap between windows.
fn findMagic(alloc: std.mem.Allocator, file: *fileio.File, start: u64, size: u64) !?u64 {
    const window: u64 = 1024 * 1024;
    const buf = try alloc.alloc(u8, @intCast(window));
    defer alloc.free(buf);

    var pos = start;
    while (pos < size) {
        try file.seekTo(pos);
        const got = try file.readAll(buf);
        if (got < 4) break;
        const hit = std.mem.indexOf(u8, buf[0..got], &chunk_magic) orelse {
            // Overlap: a magic may straddle the window boundary.
            if (got < window) break;
            pos += got - 3;
            continue;
        };
        return pos + hit;
    }
    return null;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn magicTo(list: *std.ArrayList(u8)) !void {
    try list.appendSlice(testing.allocator, &chunk_magic);
}

fn appendInt(list: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try list.appendSlice(testing.allocator, &b);
}

test "updateapp parse: indexes raw and sparse entries with correct offsets" {
    // Layout: 92 blank bytes (observed in real packages), then a raw "BOOT"
    // entry (512 bytes payload), then a sparse "SYSTEM" entry.
    var app = std.ArrayList(u8).empty;
    defer app.deinit(testing.allocator);

    try app.appendNTimes(testing.allocator, 0, 92);

    // ---- entry 1: raw BOOT ----
    try magicTo(&app);
    const hdr1: u32 = 98;
    try appendInt(&app, u32, hdr1);
    try appendInt(&app, u32, 0); // unknown
    try app.appendSlice(testing.allocator, "HWID1234");
    try appendInt(&app, u32, 1); // sequence
    const payload1: [512]u8 = @splat(0xC3);
    try appendInt(&app, u32, payload1.len);
    try app.appendNTimes(testing.allocator, 0, 16); // file date @28
    try app.appendNTimes(testing.allocator, 0, 16); // file time @44
    var name1: [32]u8 = @splat(0);
    @memcpy(name1[0..4], "BOOT");
    try app.appendSlice(testing.allocator, name1[0..32]); // name @60
    try appendInt(&app, u16, 0); // header checksum @92
    try appendInt(&app, u32, 4096); // block size @94
    try app.appendNTimes(testing.allocator, 0, hdr1 - 98); // checksum table
    try app.appendSlice(testing.allocator, &payload1);

    // ---- entry 2: sparse SYSTEM ----
    const hdr2: u32 = 98;
    var spr = std.ArrayList(u8).empty;
    defer spr.deinit(testing.allocator);
    try appendInt(&spr, u32, sparse.sparse_magic);
    try appendInt(&spr, u16, 1);
    try appendInt(&spr, u16, 0);
    try appendInt(&spr, u16, 28);
    try appendInt(&spr, u16, 12);
    try appendInt(&spr, u32, 512); // blk size
    try appendInt(&spr, u32, 2); // total blocks
    try appendInt(&spr, u32, 1); // total chunks
    try appendInt(&spr, u32, 0);
    try appendInt(&spr, u16, sparse.CHUNK_RAW);
    try appendInt(&spr, u16, 0);
    try appendInt(&spr, u32, 2);
    try appendInt(&spr, u32, 12 + 1024);
    try spr.appendNTimes(testing.allocator, 0x5C, 1024);

    try magicTo(&app);
    try appendInt(&app, u32, hdr2);
    try appendInt(&app, u32, 0);
    try app.appendSlice(testing.allocator, "HWID1234");
    try appendInt(&app, u32, 2);
    try appendInt(&app, u32, @intCast(spr.items.len));
    try app.appendNTimes(testing.allocator, 0, 16); // file date @28
    try app.appendNTimes(testing.allocator, 0, 16); // file time @44
    var name2: [32]u8 = @splat(0);
    @memcpy(name2[0..6], "SYSTEM");
    try app.appendSlice(testing.allocator, name2[0..32]);
    try appendInt(&app, u16, 0);
    try appendInt(&app, u32, 512);
    try app.appendNTimes(testing.allocator, 0, hdr2 - 98);
    try app.appendSlice(testing.allocator, spr.items);

    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("UPDATE.APP", app.items);
    var pbuf: [176]u8 = undefined;
    const path = try tmp.filePath(&pbuf, "UPDATE.APP");

    const logger = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(logger);
    logger.* = .{ .mirror_stderr = false };

    var file = try fileio.File.open(path);
    defer file.close();
    var index = try parse(testing.allocator, &file, logger);
    defer index.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), index.entries.items.len);

    const e1 = index.find("BOOT").?;
    try testing.expectEqual(@as(u64, 92), e1.offset);
    try testing.expectEqual(@as(u64, 92 + hdr1), e1.data_offset);
    try testing.expectEqual(@as(u64, 512), e1.data_size);
    try testing.expectEqual(@as(u64, 512), e1.raw_size);
    try testing.expect(!e1.is_sparse);

    const e2 = index.find("system.img").?; // .img suffix tolerated
    try testing.expect(e2.is_sparse);
    try testing.expectEqual(@as(u64, 2 * 512), e2.raw_size);
    try testing.expectEqual(@as(usize, 2), e2.sequence);
    try testing.expect(index.find("missing") == null);

    // The sparse payload converts and matches its content.
    var pbuf2: [176]u8 = undefined;
    const out_path = try tmp.filePath(&pbuf2, "system.raw");
    try file.seekTo(e2.data_offset);
    const logger2 = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(logger2);
    logger2.* = .{ .mirror_stderr = false };
    const raw_size = try sparse.convertToFile(testing.allocator, &file, out_path, logger2);
    try testing.expectEqual(@as(u64, 1024), raw_size);
    const raw = try fileio.readFileAlloc(testing.allocator, out_path, 1 << 20);
    defer testing.allocator.free(raw);
    for (raw) |b| try testing.expectEqual(@as(u8, 0x5C), b);
}
