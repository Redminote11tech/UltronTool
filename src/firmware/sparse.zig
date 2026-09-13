//! Android sparse image → raw conversion (system/core/libsparse format).
//!
//! Sparse images carry only the blocks that differ from zero, chunk by
//! chunk: RAW (literal data), FILL (a repeated 4-byte pattern), DON'T CARE
//! (holes — skipped on output) and CRC32 (validation, skipped here). The
//! raw output is total_blks × blk_sz bytes.

const std = @import("std");
const log = @import("../core/log.zig");
const fileio = @import("../core/fileio.zig");

pub const sparse_magic: u32 = 0xED26FF3A; // bytes 3A FF 26 ED

pub const CHUNK_RAW: u16 = 0xCAC1;
pub const CHUNK_FILL: u16 = 0xCAC2;
pub const CHUNK_DONT_CARE: u16 = 0xCAC3;
pub const CHUNK_CRC32: u16 = 0xCAC4;

/// Sanity cap so a corrupt header cannot demand absurd work.
pub const max_raw_size: u64 = 16 * 1024 * 1024 * 1024;

pub fn isSparse(bytes: *const [4]u8) bool {
    return std.mem.readInt(u32, bytes, .little) == sparse_magic;
}

/// Peek the expanded raw size of a sparse image at the file's current
/// position (leaves the position moved).
pub fn rawSizeAt(file: *fileio.File) !u64 {
    var hdr: [28]u8 = undefined;
    const n = try file.readAll(&hdr);
    if (n < 28 or !isSparse(hdr[0..4])) return error.NotSparse;
    const blk_sz = std.mem.readInt(u32, hdr[12..16], .little);
    const total_blks = std.mem.readInt(u32, hdr[16..20], .little);
    return @as(u64, blk_sz) * @as(u64, total_blks);
}

const Converter = struct {
    alloc: std.mem.Allocator,
    in: *fileio.File,
    out: *fileio.File,
    logger: *log.Logger,
    out_pos: u64 = 0,

    fn seekOut(self: *Converter) !void {
        if (self.out.tell() != self.out_pos) try self.out.seekTo(self.out_pos);
    }

    fn writeAll(self: *Converter, buf: []const u8) !void {
        try self.seekOut();
        const n = try self.out.writeAll(buf);
        if (n != buf.len) return error.WriteFailed;
        self.out_pos += buf.len;
    }

    /// Copy `size` bytes from the input to the output.
    fn copy(self: *Converter, size: u64, buf: []u8) !void {
        var left = size;
        while (left > 0) {
            const want: usize = @intCast(@min(left, buf.len));
            const got = try self.in.readAll(buf[0..want]);
            if (got == 0) return error.Truncated;
            try self.writeAll(buf[0..got]);
            left -= got;
        }
    }
};

/// Convert the sparse image at the input's current position into a raw file
/// at `out_path`. Returns the raw size (total_blks × blk_sz). DON'T CARE
/// chunks advance the output position without writing — reads of the raw
/// file return zeros there, and the file itself stays sparse on disk.
pub fn convertToFile(
    alloc: std.mem.Allocator,
    in: *fileio.File,
    out_path: []const u8,
    logger: *log.Logger,
) !u64 {
    var hdr: [28]u8 = undefined;
    if ((try in.readAll(&hdr)) < 28) return error.Truncated;
    if (!isSparse(hdr[0..4])) return error.NotSparse;
    const major = std.mem.readInt(u16, hdr[4..6], .little);
    const file_hdr_sz = std.mem.readInt(u16, hdr[8..10], .little);
    const chunk_hdr_sz = std.mem.readInt(u16, hdr[10..12], .little);
    const blk_sz = std.mem.readInt(u32, hdr[12..16], .little);
    const total_blks = std.mem.readInt(u32, hdr[16..20], .little);
    const total_chunks = std.mem.readInt(u32, hdr[20..24], .little);
    if (major != 1) return error.UnsupportedVersion;
    if (file_hdr_sz < 28 or chunk_hdr_sz < 12) return error.CorruptHeader;
    if (blk_sz == 0 or total_blks == 0) return error.CorruptHeader;
    const raw_size = @as(u64, blk_sz) * @as(u64, total_blks);
    if (raw_size > max_raw_size) {
        logger.err("sparse image expands to {d} bytes — exceeds the sanity cap", .{raw_size});
        return error.TooLarge;
    }

    var out = try fileio.File.create(out_path);
    defer out.close();
    var conv = Converter{ .alloc = alloc, .in = in, .out = &out, .logger = logger };

    const buf = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(buf);

    var blocks_done: u64 = 0;
    var chunk: u32 = 0;
    while (chunk < total_chunks) : (chunk += 1) {
        var chdr: [12]u8 = undefined;
        if ((try in.readAll(&chdr)) < 12) return error.Truncated;
        const ctype = std.mem.readInt(u16, chdr[0..2], .little);
        const chunk_sz = std.mem.readInt(u32, chdr[4..8], .little);
        const total_sz = std.mem.readInt(u32, chdr[8..12], .little);
        const chunk_bytes = @as(u64, chunk_sz) * blk_sz;

        switch (ctype) {
            CHUNK_RAW => {
                if (total_sz < 12) return error.CorruptHeader;
                try conv.copy(total_sz - 12, buf);
            },
            CHUNK_FILL => {
                if (total_sz != 16) return error.CorruptHeader;
                var pat: [4]u8 = undefined;
                if ((try in.readAll(&pat)) < 4) return error.Truncated;
                // Repeat the 4-byte pattern across the block range.
                for (buf, 0..) |*b, i| b.* = pat[i % 4];
                var left = chunk_bytes;
                while (left > 0) {
                    const want: usize = @intCast(@min(left, buf.len));
                    try conv.writeAll(buf[0..want]);
                    left -= want;
                }
            },
            CHUNK_DONT_CARE => {
                if (total_sz != 12) return error.CorruptHeader;
                conv.out_pos += chunk_bytes; // hole: no bytes written
            },
            CHUNK_CRC32 => {
                if (total_sz != 12) return error.CorruptHeader;
                // Validation-only chunk; nothing to convert.
            },
            else => return error.UnknownChunk,
        }
        blocks_done += chunk_sz;
    }

    if (blocks_done != total_blks) {
        logger.warn("sparse image chunk blocks ({d}) do not sum to total_blks ({d})", .{ blocks_done, total_blks });
    }
    // A trailing DON'T CARE leaves the file short of raw_size; extend it so
    // the raw output is always exactly raw_size bytes (the gap reads as
    // zeros, which is what a hole means).
    if ((try out.size()) < conv.out_pos) {
        try conv.seekOut();
        try out.seekTo(conv.out_pos - 1);
        const zero = [_]u8{0};
        if ((try out.writeAll(&zero)) != 1) return error.WriteFailed;
    }
    // A failed flush means the OS still holds (or lost) data — the raw file
    // on disk would be short and the flashed image silently wrong.
    out.flush() catch return error.WriteFailed;
    return raw_size;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn appendInt(list: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try list.appendSlice(testing.allocator, &b);
}

test "sparse convert: raw, fill and dont-care chunks become raw content" {
    var sparse_img = std.ArrayList(u8).empty;
    defer sparse_img.deinit(testing.allocator);
    const blk_sz: u32 = 4096;

    // Header: 3 RAW blocks, 2 FILL blocks, 2 DON'T CARE blocks.
    try appendInt(&sparse_img, u32, sparse_magic);
    try appendInt(&sparse_img, u16, 1); // major
    try appendInt(&sparse_img, u16, 0); // minor
    try appendInt(&sparse_img, u16, 28); // file header size
    try appendInt(&sparse_img, u16, 12); // chunk header size
    try appendInt(&sparse_img, u32, blk_sz);
    try appendInt(&sparse_img, u32, 7); // total blocks
    try appendInt(&sparse_img, u32, 3); // total chunks
    try appendInt(&sparse_img, u32, 0); // checksum

    // Chunk 1: RAW 2 blocks (block 0: AA.., block 1: BB..)
    const raw0: [4096]u8 = @splat(0xAA);
    const raw1: [4096]u8 = @splat(0xBB);
    try appendInt(&sparse_img, u16, CHUNK_RAW);
    try appendInt(&sparse_img, u16, 0);
    try appendInt(&sparse_img, u32, 2);
    try appendInt(&sparse_img, u32, 12 + 2 * blk_sz);
    try sparse_img.appendSlice(testing.allocator, &raw0);
    try sparse_img.appendSlice(testing.allocator, &raw1);

    // Chunk 2: FILL 2 blocks with pattern 0xDEADBEEF (blocks 2-3)
    try appendInt(&sparse_img, u16, CHUNK_FILL);
    try appendInt(&sparse_img, u16, 0);
    try appendInt(&sparse_img, u32, 2);
    try appendInt(&sparse_img, u32, 16);
    try appendInt(&sparse_img, u32, 0xDEADBEEF);

    // Chunk 3: DON'T CARE 3 blocks (blocks 4-6)
    try appendInt(&sparse_img, u16, CHUNK_DONT_CARE);
    try appendInt(&sparse_img, u16, 0);
    try appendInt(&sparse_img, u32, 3);
    try appendInt(&sparse_img, u32, 12);

    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("in.sparse", sparse_img.items);
    var pbuf: [176]u8 = undefined;
    var pbuf2: [176]u8 = undefined;
    const in_path = try tmp.filePath(&pbuf, "in.sparse");
    const out_path = try tmp.filePath(&pbuf2, "out.raw");

    const logger = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(logger);
    logger.* = .{ .mirror_stderr = false };

    var in = try fileio.File.open(in_path);
    defer in.close();
    const raw_size = try convertToFile(testing.allocator, &in, out_path, logger);
    try testing.expectEqual(@as(u64, 7 * blk_sz), raw_size);

    const raw = try fileio.readFileAlloc(testing.allocator, out_path, 1 << 24);
    defer testing.allocator.free(raw);
    try testing.expectEqual(raw_size, raw.len);
    try testing.expectEqualSlices(u8, &raw0, raw[0..4096]);
    try testing.expectEqualSlices(u8, &raw1, raw[4096..8192]);
    // FILL pattern repeats every 4 bytes.
    try testing.expectEqual(@as(u8, 0xEF), raw[8192]);
    try testing.expectEqual(@as(u8, 0xBE), raw[8193]);
    try testing.expectEqual(@as(u8, 0xAD), raw[8194]);
    try testing.expectEqual(@as(u8, 0xDE), raw[8195]);
    try testing.expectEqual(@as(u8, 0xEF), raw[8196]);
    // DON'T CARE reads back as zeros.
    for (raw[4 * 4096 ..]) |b| try testing.expectEqual(@as(u8, 0), b);
}
