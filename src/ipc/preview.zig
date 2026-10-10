//! Read-only flash plan inspection using the execution parser. No USB access.
const std = @import("std");
const raw = @import("../protocol/qualcomm/rawprogram.zig");
const log = @import("../core/log.zig");
const codec = @import("codec.zig");

pub fn inspect(alloc: std.mem.Allocator, files: []const []const u8, logger: *log.Logger) ![]u8 {
    if (files.len == 0 or files.len > 128) return error.InvalidPlan;
    var loader = raw.Loader.init(alloc);
    defer loader.deinit();
    for (files) |file| try loader.loadFile(file, false, logger);
    const ops = loader.opsSlice();
    if (ops.len == 0 or ops.len > 10000) return error.InvalidPlan;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var digest: [64]u8 = undefined;
    loader.reviewDigest(&digest);
    try out.appendSlice(alloc, "{\"ev\":\"flash_plan\",\"digest\":");
    try codec.appendJsonString(&out, alloc, &digest);
    try out.appendSlice(alloc, ",\"operations\":[");
    var count: usize = 0;
    for (ops) |op| {
        // Execution ignores programs without a payload and patches aimed at files.
        if (op.tag == .program and op.tag.program.filename == null) continue;
        if (op.tag == .patch and !std.mem.eql(u8, op.tag.patch.filename orelse "", "DISK")) continue;
        if (count > 0) try out.append(alloc, ',');
        count += 1;
        const kind = @tagName(op.tag);
        const lun = switch (op.tag) {
            inline else => |p| p.partition,
        };
        const start = switch (op.tag) {
            inline else => |p| p.start_sector,
        };
        const label = switch (op.tag) {
            .program => |p| p.label orelse "Unlabelled range",
            .erase => "Erase range",
            .patch => |p| p.what orelse "Disk patch",
        };
        const image = switch (op.tag) {
            .program => |p| p.filename orelse "",
            else => "",
        };
        const size: u64 = switch (op.tag) {
            .program => |p| @as(u64, p.num_sectors) * p.sector_size,
            .erase => |p| @as(u64, p.num_sectors) * p.sector_size,
            .patch => |p| p.size_in_bytes,
        };
        const sectors: u64 = switch (op.tag) {
            .program => |p| p.num_sectors,
            .erase => |p| p.num_sectors,
            else => 0,
        };
        var detail_buf: [512]u8 = undefined;
        const detail = switch (op.tag) {
            .program => |p| try std.fmt.bufPrint(&detail_buf, "Image offset: {d} sectors; sector size: {d} bytes (0 uses session size)", .{ p.file_offset, p.sector_size }),
            .erase => |p| try std.fmt.bufPrint(&detail_buf, "Erase {d} sectors; sector size: {d} bytes (0 uses session size)", .{ p.num_sectors, p.sector_size }),
            .patch => |p| p.value,
        };
        try out.appendSlice(alloc, "{\"detail\":");
        try codec.appendJsonString(&out, alloc, detail);
        try out.appendSlice(alloc, ",\"kind\":");
        try codec.appendJsonString(&out, alloc, kind);
        try out.appendSlice(alloc, ",\"label\":");
        try codec.appendJsonString(&out, alloc, label);
        try out.appendSlice(alloc, ",\"start\":");
        try codec.appendJsonString(&out, alloc, start);
        try out.appendSlice(alloc, ",\"image\":");
        try codec.appendJsonString(&out, alloc, image);
        var buf: [128]u8 = undefined;
        try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, ",\"lun\":{d},\"bytes\":{d},\"sectors\":{d}}}", .{ lun, size, sectors }));
    }
    if (count == 0) return error.InvalidPlan;
    if (@import("../protocol/qualcomm/manager.zig").findBootablePartition(ops)) |lun| {
        var buf: [256]u8 = undefined;
        try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, ",{{\"kind\":\"set_bootable\",\"label\":\"Select bootable LUN\",\"start\":\"\",\"image\":\"\",\"lun\":{d},\"bytes\":0,\"sectors\":0,\"detail\":\"Select the bootloader LUN as bootable\"}}", .{lun}));
    }
    try out.appendSlice(alloc, "]}\n");
    return out.toOwnedSlice(alloc);
}

test "preview includes exact ranges and the review digest changes with XML" {
    const fileio = @import("../core/fileio.zig");
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("boot.img", "payload");
    try tmp.writeFile("plan.xml", "<data><program filename=\"boot.img\" label=\"boot_a\" start_sector=\"8\" SECTOR_SIZE_IN_BYTES=\"512\" num_partition_sectors=\"1\" physical_partition_number=\"2\"/><erase start_sector=\"40\" num_partition_sectors=\"3\"/></data>");
    var buf: [176]u8 = undefined;
    const path = try tmp.filePath(&buf, "plan.xml");
    var logger = log.Logger{ .mirror_stderr = false };
    const result = try inspect(std.testing.allocator, &.{path}, &logger);
    defer std.testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const entries = parsed.value.object.get("operations").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("boot_a", entries[0].object.get("label").?.string);
    try std.testing.expectEqual(@as(i64, 2), entries[0].object.get("lun").?.integer);
    try tmp.writeFile("plan.xml", "<data><erase start_sector=\"41\" num_partition_sectors=\"1\"/></data>");
    const changed = try inspect(std.testing.allocator, &.{path}, &logger);
    defer std.testing.allocator.free(changed);
    try std.testing.expect(!std.mem.eql(u8, result[0..100], changed[0..100]));
}

test "preview includes disk patch details and automatic boot LUN selection" {
    const fileio = @import("../core/fileio.zig");
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("xbl.img", "bootloader");
    try tmp.writeFile("raw.xml", "<data><program filename=\"xbl.img\" label=\"xbl_a\" physical_partition_number=\"1\"/></data>");
    try tmp.writeFile("patch.xml", "<patches><patch filename=\"DISK\" start_sector=\"2\" value=\"CRC32(2,4096)\" what=\"GPT CRC\" size_in_bytes=\"4\"/></patches>");
    var a: [176]u8 = undefined;
    var b: [176]u8 = undefined;
    const first = try tmp.filePath(&a, "raw.xml");
    const second = try tmp.filePath(&b, "patch.xml");
    var logger = log.Logger{ .mirror_stderr = false };
    const result = try inspect(std.testing.allocator, &.{ first, second }, &logger);
    defer std.testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const ops = parsed.value.object.get("operations").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), ops.len);
    try std.testing.expectEqualStrings("patch", ops[1].object.get("kind").?.string);
    try std.testing.expectEqualStrings("CRC32(2,4096)", ops[1].object.get("detail").?.string);
    try std.testing.expectEqualStrings("set_bootable", ops[2].object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), ops[2].object.get("lun").?.integer);
}

/// Read only the file size and format marker; no device access or full-image allocation.
pub fn inspectImage(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const fileio = @import("../core/fileio.zig");
    const sparse = @import("../firmware/sparse.zig");
    var file = try fileio.File.open(path);
    defer file.close();
    const size = try file.size();
    var magic: [4]u8 = @splat(0);
    const n = try file.readAll(&magic);
    const is_sparse = n == 4 and sparse.isSparse(&magic);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"ev\":\"image_info\",\"path\":");
    try codec.appendJsonString(&out, alloc, path);
    var buf: [128]u8 = undefined;
    try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, ",\"size\":{d},\"sparse\":{s}}}\n", .{ size, if (is_sparse) "true" else "false" }));
    return out.toOwnedSlice(alloc);
}

test "image inspection distinguishes sparse content regardless of extension" {
    const fileio = @import("../core/fileio.zig");
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("boot.img", "raw-image");
    try tmp.writeFile("system.bin", &.{ 0x3a, 0xff, 0x26, 0xed });
    try tmp.writeFile("empty.img", "");
    var buf: [176]u8 = undefined;
    const raw_info = try inspectImage(std.testing.allocator, try tmp.filePath(&buf, "boot.img"));
    defer std.testing.allocator.free(raw_info);
    try std.testing.expect(std.mem.indexOf(u8, raw_info, "\"size\":9,\"sparse\":false") != null);
    const sparse_info = try inspectImage(std.testing.allocator, try tmp.filePath(&buf, "system.bin"));
    defer std.testing.allocator.free(sparse_info);
    try std.testing.expect(std.mem.indexOf(u8, sparse_info, "\"sparse\":true") != null);
    const empty_info = try inspectImage(std.testing.allocator, try tmp.filePath(&buf, "empty.img"));
    defer std.testing.allocator.free(empty_info);
    try std.testing.expect(std.mem.indexOf(u8, empty_info, "\"size\":0") != null);
}
