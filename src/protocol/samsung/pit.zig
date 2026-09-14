//! Samsung PIT (Partition Information Table) parser — port of
//! TheAirBlow.Thor.Library PIT/PitData.cs + PitEntry.cs (MIT).
//!
//! A PIT dump is a fixed 28-byte header followed by 132-byte entries:
//! nine little-endian u32 fields and three 32-byte ASCII strings
//! (partition name, file name, delta name). The delta name is never used
//! for flashing, so it is parsed over but not stored.

const std = @import("std");
const log = @import("../../core/log.zig");

pub const magic: u32 = 0x12349876;
pub const header_size = 28;
pub const entry_size = 132;
/// Samsung PITs in the wild carry ~60 entries; cap defensively.
pub const max_entries = 256;

pub const Error = error{ NotPit, Truncated, OutOfMemory };

pub const Entry = struct {
    /// 0 = application-processor flash, 1 = modem (flashed with the
    /// modem-shaped end-sequence packet — see odin.zig).
    binary_type: u32 = 0,
    device_type: u32 = 0,
    /// Per-table id the bootloader's end-sequence packet expects.
    partition_id: u32 = 0,
    attributes: u32 = 0,
    update_attributes: u32 = 0,
    /// Start and length in device blocks (512 bytes on eMMC/UFS targets).
    block_size: u32 = 0,
    block_count: u32 = 0,
    file_offset: u32 = 0,
    file_size: u32 = 0,

    partition: [32]u8 = undefined,
    partition_len: usize = 0,
    file_name: [32]u8 = undefined,
    file_name_len: usize = 0,

    pub fn nameSlice(self: *const Entry) []const u8 {
        return self.partition[0..self.partition_len];
    }

    pub fn fileNameSlice(self: *const Entry) []const u8 {
        return self.file_name[0..self.file_name_len];
    }

    pub fn sectors(self: *const Entry) u64 {
        return self.block_count;
    }
};

pub const Table = struct {
    entries: []Entry,
    count: usize,

    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        alloc.free(self.entries);
        self.entries = &.{};
        self.count = 0;
    }

    pub fn find(self: *const Table, partition_name: []const u8) ?*const Entry {
        for (self.entries[0..self.count]) |*e| {
            if (std.mem.eql(u8, e.nameSlice(), partition_name)) return e;
        }
        return null;
    }
};

/// Copy a fixed-width ASCII field, stopping at the first NUL.
fn copyString(field: []const u8, out: *[32]u8) usize {
    const n = @min(field.len, out.len);
    var len: usize = 0;
    while (len < n and field[len] != 0) : (len += 1) {}
    @memcpy(out[0..len], field[0..len]);
    return len;
}

/// Parse a PIT dump (raw bytes as received from the device).
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8, logger: *log.Logger) Error!Table {
    if (bytes.len < header_size) return error.Truncated;
    if (std.mem.readInt(u32, bytes[0..4], .little) != magic) return error.NotPit;
    const count = std.mem.readInt(u32, bytes[4..8], .little);
    if (count == 0) return error.Truncated;
    if (count > max_entries) {
        logger.err("PIT declares {d} entries, refusing to parse more than {d}", .{ count, max_entries });
        return error.Truncated;
    }
    if (bytes.len < header_size + @as(usize, count) * entry_size) return error.Truncated;

    const entries = alloc.alloc(Entry, count) catch return error.OutOfMemory;
    errdefer alloc.free(entries);

    for (0..count) |i| {
        const o = header_size + i * entry_size;
        const e = bytes[o .. o + entry_size];
        entries[i] = .{
            .binary_type = std.mem.readInt(u32, e[0..4], .little),
            .device_type = std.mem.readInt(u32, e[4..8], .little),
            .partition_id = std.mem.readInt(u32, e[8..12], .little),
            .attributes = std.mem.readInt(u32, e[12..16], .little),
            .update_attributes = std.mem.readInt(u32, e[16..20], .little),
            .block_size = std.mem.readInt(u32, e[20..24], .little),
            .block_count = std.mem.readInt(u32, e[24..28], .little),
            .file_offset = std.mem.readInt(u32, e[28..32], .little),
            .file_size = std.mem.readInt(u32, e[32..36], .little),
        };
        entries[i].partition_len = copyString(e[36..68], &entries[i].partition);
        entries[i].file_name_len = copyString(e[68..100], &entries[i].file_name);
    }

    return .{ .entries = entries, .count = count };
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

fn appendString(list: *std.ArrayList(u8), s: []const u8, width: usize) !void {
    try list.appendSlice(testing.allocator, s);
    try list.appendNTimes(testing.allocator, 0, width - s.len);
}

/// Build a valid PIT dump with two entries ("AP" and "BOOT"), also used by
/// odin.zig's session tests.
pub fn buildPit(list: *std.ArrayList(u8)) !void {
    try appendInt(list, u32, magic);
    try appendInt(list, u32, 2);
    try appendString(list, "UNKWN00", 8);
    try appendString(list, "PROJECT", 8);
    try appendInt(list, u32, 0);

    // Entry 0: eMMC app-processor partition "AP".
    try appendInt(list, u32, 0); // binary type
    try appendInt(list, u32, 2); // device type (eMMC)
    try appendInt(list, u32, 1); // partition id
    try appendInt(list, u32, 0); // attributes
    try appendInt(list, u32, 0); // update attributes
    try appendInt(list, u32, 1024); // block size
    try appendInt(list, u32, 2048); // block count
    try appendInt(list, u32, 0); // file offset
    try appendInt(list, u32, 0); // file size
    try appendString(list, "AP", 32);
    try appendString(list, "ap.img", 32);
    try appendString(list, "", 32); // delta name

    // Entry 1: modem partition "RADIO" (binary_type 1).
    try appendInt(list, u32, 1);
    try appendInt(list, u32, 2);
    try appendInt(list, u32, 2);
    try appendInt(list, u32, 1); // write-protected attribute
    try appendInt(list, u32, 0);
    try appendInt(list, u32, 4096);
    try appendInt(list, u32, 8192);
    try appendInt(list, u32, 0);
    try appendInt(list, u32, 0);
    try appendString(list, "RADIO", 32);
    try appendString(list, "modem.bin", 32);
    try appendString(list, "", 32);
}

test "pit parses entries and trims names" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buildPit(&buf);

    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };

    var table = try parse(testing.allocator, buf.items, l);
    defer table.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), table.count);
    const ap = &table.entries[0];
    try testing.expectEqualStrings("AP", ap.nameSlice());
    try testing.expectEqualStrings("ap.img", ap.fileNameSlice());
    try testing.expectEqual(@as(u32, 1024), ap.block_size);
    try testing.expectEqual(@as(u32, 2048), ap.block_count);
    try testing.expectEqual(@as(u32, 1), ap.partition_id);

    const radio = table.find("RADIO").?;
    try testing.expectEqual(@as(u32, 1), radio.binary_type);
    try testing.expect(table.find("NOPE") == null);
}

test "pit rejects bad magic and truncation" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buildPit(&buf);

    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };

    buf.items[0] ^= 0xFF;
    try testing.expectError(error.NotPit, parse(testing.allocator, buf.items, l));
    buf.items[0] ^= 0xFF;

    try testing.expectError(error.Truncated, parse(testing.allocator, buf.items[0 .. buf.items.len - 1], l));
    try testing.expectError(error.Truncated, parse(testing.allocator, buf.items[0..20], l));
}
