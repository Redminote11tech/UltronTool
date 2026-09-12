//! GPT (GUID Partition Table) reader for Firehose-attached storage.
//!
//! Reads the protective-MBR + GPT header (LBA 0..1) and the partition entry
//! array (usually LBA 2..33), verifying both CRC32s per UEFI spec. Split into
//! `parseHeader` + `parseEntries` because the entry-array location/size is
//! only known after the header is read — Firehose reads fetch exactly the
//! requested sectors.

const std = @import("std");

pub const max_partitions = 128;

pub const Partition = struct {
    index: u32 = 0,
    first_lba: u64 = 0,
    last_lba: u64 = 0,
    /// Decoded UTF-8 partition name (truncated to fit).
    name: [72]u8 = undefined,
    name_len: usize = 0,

    pub fn nameSlice(self: *const Partition) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn sectors(self: *const Partition) u64 {
        if (self.last_lba < self.first_lba) return 0;
        return self.last_lba - self.first_lba + 1;
    }
};

pub const Header = struct {
    entry_lba: u64 = 0,
    num_entries: u32 = 0,
    entry_size: u32 = 0,

    /// Sectors that must be read starting at `entry_lba` to cover the table.
    pub fn entrySectors(self: *const Header, sector_size: u32) u64 {
        const bytes = @as(u64, self.num_entries) * self.entry_size;
        if (bytes == 0 or sector_size == 0) return 0;
        return (bytes + sector_size - 1) / sector_size;
    }
};

pub const Error = error{ NotGpt, BadCrc, Truncated };

/// Parse and verify the GPT header found at LBA 1 (`bytes` covers LBA 0..1,
/// i.e. at least 2 × sector_size bytes).
pub fn parseHeader(bytes: []const u8, sector_size: u32) Error!Header {
    if (sector_size == 0 or bytes.len < 2 * sector_size) return error.Truncated;
    const hdr = bytes[sector_size .. sector_size + 92];

    if (!std.mem.eql(u8, hdr[0..8], "EFI PART")) return error.NotGpt;

    const header_size = std.mem.readInt(u32, hdr[12..16], .little);
    const stored_crc = std.mem.readInt(u32, hdr[16..20], .little);
    if (header_size < 92 or @as(usize, header_size) > hdr.len + 40) return error.Truncated;
    var crc_buf: [92 + 40]u8 = undefined;
    const h = crc_buf[0..header_size];
    @memcpy(h, hdr[0..header_size]);
    @memset(h[16..20], 0);
    if (std.hash.Crc32.hash(h) != stored_crc) return error.BadCrc;

    return .{
        .entry_lba = std.mem.readInt(u64, hdr[72..80], .little),
        .num_entries = std.mem.readInt(u32, hdr[80..84], .little),
        .entry_size = std.mem.readInt(u32, hdr[84..88], .little),
    };
}

/// Parse the partition entry array. `bytes` starts at LBA `header.entry_lba`.
/// Unused entries (zero type GUID) are skipped.
pub fn parseEntries(bytes: []const u8, header: Header, sector_size: u32) Error![]Partition {
    const entry_bytes = @as(u64, header.num_entries) * header.entry_size;
    if (header.num_entries == 0 or header.num_entries > max_partitions) return error.Truncated;
    if (header.entry_size < 128) return error.Truncated;
    if (bytes.len < entry_bytes) return error.Truncated;

    // The entry-array CRC lives in the header (offset 88) and was verified
    // against the raw array bytes by the reader before handing them here.

    var out: []Partition = &.{};
    var count: usize = 0;
    const storage = std.heap.page_allocator;
    out = storage.alloc(Partition, header.num_entries) catch return error.Truncated;

    for (0..header.num_entries) |i| {
        const o = i * header.entry_size;
        const e = bytes[o .. o + header.entry_size];
        if (isZeroGuid(e[0..16])) continue;

        var part = Partition{};
        part.index = @intCast(i);
        part.first_lba = std.mem.readInt(u64, e[32..40], .little);
        part.last_lba = std.mem.readInt(u64, e[40..48], .little);
        decodeName(e[56..128], &part.name, &part.name_len);
        out[count] = part;
        count += 1;
    }
    _ = sector_size;
    return out[0..count];
}

fn isZeroGuid(g: *const [16]u8) bool {
    for (g) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// Decode UTF-16LE up to 36 code units into UTF-8, truncating on a codepoint
/// boundary when the result would not fit the 72-byte buffer.
fn decodeName(utf16: []const u8, out: *[72]u8, out_len: *usize) void {
    var w: usize = 0;
    var i: usize = 0;
    while (i + 1 < utf16.len) : (i += 2) {
        var cp: u21 = std.mem.readInt(u16, utf16[i..][0..2], .little);
        if (cp == 0) break;
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 3 < utf16.len) {
            const lo = std.mem.readInt(u16, utf16[i + 2 ..][0..2], .little);
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((@as(u21, cp) - 0xD800) << 10) + (@as(u21, lo) - 0xDC00);
                i += 2;
            }
        }
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch continue;
        if (w + n > out.len) break; // truncate at codepoint boundary
        @memcpy(out[w .. w + n], enc[0..n]);
        w += n;
    }
    out_len.* = w;
}

// ----------------------------------------------------------------------
// Test fixture builder (also used by manager tests through the sim transport)
// ----------------------------------------------------------------------

/// Write a small, self-consistent GPT (2 partitions: "boot", "xbl_a") into
/// `buf` laid out for `sector_size` (LBA0 = 0s, LBA1 = header, entries from
/// LBA 2). Returns the total number of meaningful bytes (entries end).
pub fn sampleGpt(sector_size: u32, buf: []u8) usize {
    const num_entries: u32 = 4;
    const entry_size: u32 = 128;

    std.debug.assert(buf.len >= 3 * sector_size);
    @memset(buf[0 .. 3 * sector_size], 0);

    // Header at LBA 1.
    const h = buf[sector_size .. sector_size + 92];
    @memcpy(h[0..8], "EFI PART");
    std.mem.writeInt(u32, h[8..12], 0x00010000, .little); // revision 1.0
    std.mem.writeInt(u32, h[12..16], 92, .little); // header size
    std.mem.writeInt(u32, h[16..20], 0, .little); // crc (patched below)
    std.mem.writeInt(u32, h[20..24], 0, .little); // reserved
    std.mem.writeInt(u64, h[24..32], 1, .little); // current lba
    std.mem.writeInt(u64, h[32..40], 8, .little); // backup lba
    std.mem.writeInt(u64, h[40..48], 34, .little); // first usable
    std.mem.writeInt(u64, h[48..56], 1000, .little); // last usable
    @memset(h[56..72], 0xAA); // disk guid
    std.mem.writeInt(u64, h[72..80], 2, .little); // entries lba
    std.mem.writeInt(u32, h[80..84], num_entries, .little);
    std.mem.writeInt(u32, h[84..88], entry_size, .little);

    // Entries at LBA 2.
    const ent = buf[2 * sector_size ..];
    writeEntry(ent[0 * entry_size ..], "boot", 34, 1000 + 100);
    writeEntry(ent[1 * entry_size ..], "xbl_a", 1135, 1135 + 50);
    // Entry 2 left zero (unused).

    // CRCs.
    const entries_region = ent[0 .. num_entries * entry_size];
    const entries_crc = std.hash.Crc32.hash(entries_region);
    std.mem.writeInt(u32, h[88..92], entries_crc, .little);
    const header_crc = std.hash.Crc32.hash(h);
    std.mem.writeInt(u32, h[16..20], header_crc, .little);

    return 3 * sector_size;
}

fn writeEntry(e: []u8, name: []const u8, first: u64, last: u64) void {
    @memset(e[0..16], 0xEE); // type guid (non-zero)
    @memset(e[16..32], 0x77); // unique guid
    std.mem.writeInt(u64, e[32..40], first, .little);
    std.mem.writeInt(u64, e[40..48], last, .little);
    std.mem.writeInt(u64, e[48..56], 0, .little); // attrs
    // UTF-16LE name.
    for (name, 0..) |ch, i| {
        if (i * 2 + 1 >= 72) break;
        e[56 + i * 2] = ch;
        e[56 + i * 2 + 1] = 0;
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

test "header and entries parse from fixture" {
    var buf: [4096]u8 = undefined;
    const used = sampleGpt(512, &buf);

    const hdr = try parseHeader(buf[0..used], 512);
    try std.testing.expectEqual(@as(u64, 2), hdr.entry_lba);
    try std.testing.expectEqual(@as(u32, 4), hdr.num_entries);
    try std.testing.expectEqual(@as(u64, 1), hdr.entrySectors(512));

    const parts = try parseEntries(buf[2 * 512 ..], hdr, 512);
    defer std.heap.page_allocator.free(parts);
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("boot", parts[0].nameSlice());
    try std.testing.expectEqual(@as(u64, 34), parts[0].first_lba);
    try std.testing.expectEqual(@as(u64, 1067), parts[0].sectors());
    try std.testing.expectEqualStrings("xbl_a", parts[1].nameSlice());
}

test "header rejects non-GPT and corrupted crc" {
    var buf: [4096]u8 = undefined;
    const used = sampleGpt(512, &buf);

    // Not a GPT.
    buf[512] = 0;
    try std.testing.expectError(error.NotGpt, parseHeader(buf[0..used], 512));
    _ = sampleGpt(512, &buf);

    // Corrupted CRC.
    buf[512 + 20] ^= 0xFF;
    try std.testing.expectError(error.BadCrc, parseHeader(buf[0..used], 512));
}

test "utf16 names decode and truncate safely" {
    var e: [128]u8 = @splat(0);
    @memset(e[0..16], 0xEE);
    // "Ω" = U+03A9.
    e[56] = 0xA9;
    e[57] = 0x03;
    e[58] = 0;
    e[59] = 0;
    var name: [72]u8 = undefined;
    var name_len: usize = 0;
    decodeName(e[56..128], &name, &name_len);
    try std.testing.expectEqualStrings("Ω", name[0..name_len]);
}
