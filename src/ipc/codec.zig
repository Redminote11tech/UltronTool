//! Line-delimited JSON codec for the Ultron IPC daemon.
//!
//! The daemon (ipc/daemon.zig) owns the device scanner and the Firehose
//! session manager and speaks one JSON object per line over its stdio pipes:
//! requests arrive on stdin, events leave on stdout. The shapes here are the
//! contract with the TS frontend (ui-ts/src/state/daemon.ts) — change both
//! sides together.
//!
//! Serialization is hand-rolled (strings/ints/bools only, one escaper) so the
//! daemon needs no JSON writer API that churns between Zig versions. Requests
//! are parsed through std.json.Value into slices backed by the caller's arena;
//! the manager heap-dupes everything it keeps, so arena lifetime only has to
//! cover the enqueue call.

const std = @import("std");
const ev = @import("../core/event.zig");
const log = @import("../core/log.zig");
const manager = @import("../protocol/qualcomm/manager.zig");
const firehose = @import("../protocol/qualcomm/firehose.zig");
const transport = @import("../transport/transport.zig");

pub const protocol_version = 1;

// ----------------------------------------------------------------------
// JSON string escaping
// ----------------------------------------------------------------------

pub fn appendJsonString(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => {
                if (ch < 0x20) {
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
                    try list.appendSlice(alloc, hex);
                } else {
                    try list.append(alloc, ch);
                }
            },
        }
    }
    try list.append(alloc, '"');
}

// ----------------------------------------------------------------------
// Event serialization (daemon → UI)
// ----------------------------------------------------------------------

/// ModeTag → the TS vendors.ts ids.
pub fn modeId(tag: ev.ModeTag) []const u8 {
    return switch (tag) {
        .qualcomm_edl => "qualcomm_edl",
        .qualcomm_crash => "qualcomm_crash",
        .mtk_brom, .mtk_preloader => "mtk",
        .samsung_odin => "samsung",
        .lg_laf => "lg",
        .spd_brom => "spd",
        .unknown => "unknown",
    };
}

pub const session_state_names = [_][]const u8{
    "disconnected", "needs_loader", "firehose_ready", "samsung_ready", "lg_ready", "spd_ready",
};

pub fn sessionStateName(s: ev.SessionState) []const u8 {
    return session_state_names[@intFromEnum(s)];
}

/// Append one event object (without trailing newline) for the wire.
pub fn appendEvent(list: *std.ArrayList(u8), alloc: std.mem.Allocator, event: ev.Event) !void {
    switch (event) {
        .device_added => |d| {
            try list.appendSlice(alloc, "{\"ev\":\"device_added\",\"path\":");
            try appendJsonString(list, alloc, d.key.path.slice());
            try list.appendSlice(alloc, ",\"vid\":");
            try appendInt(list, alloc, d.vid);
            try list.appendSlice(alloc, ",\"pid\":");
            try appendInt(list, alloc, d.pid);
            try list.appendSlice(alloc, ",\"bus\":");
            try appendInt(list, alloc, d.bus);
            try list.appendSlice(alloc, ",\"devnum\":");
            try appendInt(list, alloc, d.devnum);
            try list.appendSlice(alloc, ",\"mode\":");
            try appendJsonString(list, alloc, modeId(d.mode));
            try list.appendSlice(alloc, ",\"label\":");
            try appendJsonString(list, alloc, d.mode.displayName());
            try list.appendSlice(alloc, ",\"manufacturer\":");
            try appendJsonString(list, alloc, d.manufacturer.slice());
            try list.appendSlice(alloc, ",\"product\":");
            try appendJsonString(list, alloc, d.product.slice());
            try list.appendSlice(alloc, ",\"serial\":");
            try appendJsonString(list, alloc, d.serial.slice());
            try list.append(alloc, '}');
        },
        .device_removed => |k| {
            try list.appendSlice(alloc, "{\"ev\":\"device_removed\",\"path\":");
            try appendJsonString(list, alloc, k.path.slice());
            try list.append(alloc, '}');
        },
        .progress => |p| {
            try list.appendSlice(alloc, "{\"ev\":\"progress\",\"fraction\":");
            if (p.fraction < 0) {
                try list.appendSlice(alloc, "-1");
            } else {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d:.4}", .{p.fraction}) catch unreachable;
                try list.appendSlice(alloc, s);
            }
            try list.appendSlice(alloc, ",\"done\":");
            try appendInt(list, alloc, p.done);
            try list.appendSlice(alloc, ",\"total\":");
            try appendInt(list, alloc, p.total);
            try list.appendSlice(alloc, ",\"label\":");
            try appendJsonString(list, alloc, p.label.slice());
            try list.append(alloc, '}');
        },
        .chip_info => |c| {
            try list.appendSlice(alloc, "{\"ev\":\"chip_info\",\"protocol_version\":");
            try appendInt(list, alloc, c.protocol_version);
            try list.appendSlice(alloc, ",\"serial\":");
            if (c.serial) |s| try appendInt(list, alloc, s) else try list.appendSlice(alloc, "null");
            try list.appendSlice(alloc, ",\"hwid\":");
            if (c.hwid) |h| {
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\"0x{x}\"", .{h}) catch unreachable;
                try list.appendSlice(alloc, s);
            } else {
                try list.appendSlice(alloc, "null");
            }
            try list.appendSlice(alloc, ",\"msm_id\":");
            try appendInt(list, alloc, c.msm_id);
            try list.appendSlice(alloc, ",\"oem_id\":");
            try appendInt(list, alloc, c.oem_id);
            try list.appendSlice(alloc, ",\"model_id\":");
            try appendInt(list, alloc, c.model_id);
            try list.appendSlice(alloc, ",\"pkhash\":");
            try appendJsonString(list, alloc, c.pkhash.slice());
            try list.append(alloc, '}');
        },
        .finished => |f| {
            try list.appendSlice(alloc, "{\"ev\":\"finished\",\"success\":");
            try list.appendSlice(alloc, if (f.success) "true" else "false");
            try list.appendSlice(alloc, ",\"message\":");
            try appendJsonString(list, alloc, f.message.slice());
            try list.append(alloc, '}');
        },
        .session_state => |s| {
            try list.appendSlice(alloc, "{\"ev\":\"state\",\"state\":");
            try appendJsonString(list, alloc, sessionStateName(s));
            try list.append(alloc, '}');
        },
        .partitions => |p| {
            try list.appendSlice(alloc, "{\"ev\":\"partitions\",\"lun\":");
            try appendInt(list, alloc, p.lun);
            try list.appendSlice(alloc, ",\"sector_size\":");
            try appendInt(list, alloc, p.sector_size);
            try list.appendSlice(alloc, ",\"luns\":");
            try appendInt(list, alloc, p.luns);
            try list.appendSlice(alloc, ",\"vip\":");
            try list.appendSlice(alloc, if (p.vip) "true" else "false");
            try list.appendSlice(alloc, ",\"parts\":[");
            for (p.parts[0..p.count], 0..) |part, i| {
                if (i > 0) try list.append(alloc, ',');
                try list.appendSlice(alloc, "{\"name\":");
                try appendJsonString(list, alloc, part.name.slice());
                try list.appendSlice(alloc, ",\"first_lba\":");
                try appendInt(list, alloc, part.first_lba);
                try list.appendSlice(alloc, ",\"last_lba\":");
                try appendInt(list, alloc, part.last_lba);
                try list.append(alloc, '}');
            }
            try list.appendSlice(alloc, "]}");
        },
        .huawei_app => |h| {
            try list.appendSlice(alloc, "{\"ev\":\"huawei_app\",\"gen\":");
            try appendInt(list, alloc, h.gen);
            try list.appendSlice(alloc, ",\"entries\":[");
            for (h.entries[0..h.count], 0..) |e, i| {
                if (i > 0) try list.append(alloc, ',');
                try list.appendSlice(alloc, "{\"name\":");
                try appendJsonString(list, alloc, e.name.slice());
                try list.appendSlice(alloc, ",\"data_size\":");
                try appendInt(list, alloc, e.data_size);
                try list.appendSlice(alloc, ",\"raw_size\":");
                try appendInt(list, alloc, e.raw_size);
                try list.appendSlice(alloc, ",\"sparse\":");
                try list.appendSlice(alloc, if (e.sparse) "true" else "false");
                try list.append(alloc, '}');
            }
            try list.appendSlice(alloc, "]}");
        },
    }
}

/// One log entry as a wire event.
pub fn appendLogEvent(list: *std.ArrayList(u8), alloc: std.mem.Allocator, entry: log.Entry) !void {
    try list.appendSlice(alloc, "{\"ev\":\"log\",\"level\":");
    try appendJsonString(list, alloc, levelName(entry.level));
    try list.appendSlice(alloc, ",\"text\":");
    try appendJsonString(list, alloc, entry.text[0..entry.len]);
    try list.append(alloc, '}');
}

fn levelName(l: log.Level) []const u8 {
    return switch (l) {
        .debug => "debug",
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
}

fn appendInt(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: anytype) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try list.appendSlice(alloc, s);
}

/// Startup banner sent before anything else.
pub fn helloLine(list: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    try list.appendSlice(alloc, "{\"ev\":\"hello\",\"protocol\":\"ultron-daemon\",\"version\":");
    try appendInt(list, alloc, protocol_version);
    try list.append(alloc, '}');
}

// ----------------------------------------------------------------------
// Request parsing (UI → daemon)
// ----------------------------------------------------------------------

pub const ParseError = error{
    NotJson,
    NotAnObject,
    UnknownCommand,
    BadField,
    OutOfMemory,
};

/// A parsed request. Manager requests reference arena-backed slices — valid
/// until the caller resets the arena (the manager dupes on enqueue).
pub const Parsed = union(enum) {
    manager: manager.Request,
    cancel,
    shutdown,
};

fn objBool(obj: std.json.ObjectMap, key: []const u8, default: bool) ParseError!bool {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => error.BadField,
    };
}

fn objInt(obj: std.json.ObjectMap, comptime T: type, key: []const u8, default: ?T) ParseError!T {
    const v = obj.get(key) orelse return default orelse error.BadField;
    return switch (v) {
        .integer => |i| std.math.cast(T, i) orelse error.BadField,
        else => error.BadField,
    };
}

fn objStr(obj: std.json.ObjectMap, key: []const u8) ParseError!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => error.BadField,
    };
}

fn parseStorage(obj: std.json.ObjectMap) ParseError!firehose.StorageType {
    const s = (try objStr(obj, "storage")) orelse "ufs";
    if (std.mem.eql(u8, s, "ufs")) return .ufs;
    if (std.mem.eql(u8, s, "emmc")) return .emmc;
    if (std.mem.eql(u8, s, "spinor")) return .spinor;
    if (std.mem.eql(u8, s, "nand")) return .nand;
    if (std.mem.eql(u8, s, "nvme")) return .nvme;
    return error.BadField;
}

fn parseTarget(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!?transport.Target {
    const serial = try objStr(obj, "serial");
    const bus: ?u32 = if (obj.get("bus")) |_| try objInt(obj, u32, "bus", null) else null;
    const devnum: ?u32 = if (obj.get("devnum")) |_| try objInt(obj, u32, "devnum", null) else null;
    if (serial == null and bus == null and devnum == null) return null;
    return .{
        .serial = if (serial) |s| try alloc.dupe(u8, s) else null,
        .bus = bus,
        .devnum = devnum,
    };
}

/// Parse one request line. All returned slices live in `arena`.
pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) ParseError!Parsed {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    const cmd = (try objStr(obj, "cmd")) orelse return error.UnknownCommand;

    if (std.mem.eql(u8, cmd, "cancel")) return .cancel;
    if (std.mem.eql(u8, cmd, "shutdown")) return .shutdown;
    if (std.mem.eql(u8, cmd, "reset")) return .{ .manager = .reset };
    if (std.mem.eql(u8, cmd, "disconnect")) return .{ .manager = .disconnect };

    if (std.mem.eql(u8, cmd, "connect")) {
        return .{ .manager = .{ .connect = .{
            .programmer = try objStr(obj, "programmer"),
            .storage = try parseStorage(obj),
            .skip_storage_init = try objBool(obj, "skip_storage_init", false),
            .vip_dir = try objStr(obj, "vip_dir"),
            .target = try parseTarget(arena, obj),
        } } };
    }
    if (std.mem.eql(u8, cmd, "upload_loader")) {
        const programmer = (try objStr(obj, "programmer")) orelse return error.BadField;
        return .{ .manager = .{ .upload_loader = .{
            .programmer = programmer,
            .storage = try parseStorage(obj),
            .skip_storage_init = try objBool(obj, "skip_storage_init", false),
            .vip_dir = try objStr(obj, "vip_dir"),
            .target = try parseTarget(arena, obj),
        } } };
    }
    if (std.mem.eql(u8, cmd, "flash_xml")) {
        const files_val = obj.get("files") orelse return error.BadField;
        const arr = switch (files_val) {
            .array => |a| a,
            else => return error.BadField,
        };
        const files = try arena.alloc([]const u8, arr.items.len);
        for (arr.items, 0..) |item, i| {
            files[i] = switch (item) {
                .string => |s| s,
                else => return error.BadField,
            };
        }
        return .{ .manager = .{ .flash_xml = .{
            .files = files,
            .allow_missing = try objBool(obj, "allow_missing", false),
        } } };
    }
    if (std.mem.eql(u8, cmd, "list_partitions")) {
        return .{ .manager = .{ .list_partitions = .{ .lun = try objInt(obj, u32, "lun", 0) } } };
    }
    if (std.mem.eql(u8, cmd, "read_partition")) {
        return .{ .manager = .{ .read_partition = .{
            .path = (try objStr(obj, "path")) orelse return error.BadField,
            .first_lba = try objInt(obj, u64, "first_lba", 0),
            .num_sectors = try objInt(obj, u64, "num_sectors", null),
            .lun = try objInt(obj, u32, "lun", 0),
            .label = (try objStr(obj, "label")) orelse "partition",
        } } };
    }
    if (std.mem.eql(u8, cmd, "write_partition")) {
        return .{ .manager = .{ .write_partition = .{
            .path = (try objStr(obj, "path")) orelse return error.BadField,
            .first_lba = try objInt(obj, u64, "first_lba", 0),
            .max_sectors = try objInt(obj, u64, "max_sectors", null),
            .lun = try objInt(obj, u32, "lun", 0),
            .label = (try objStr(obj, "label")) orelse "partition",
        } } };
    }
    if (std.mem.eql(u8, cmd, "erase_partition")) {
        return .{ .manager = .{ .erase_partition = .{
            .first_lba = try objInt(obj, u64, "first_lba", 0),
            .num_sectors = try objInt(obj, u64, "num_sectors", null),
            .lun = try objInt(obj, u32, "lun", 0),
            .label = (try objStr(obj, "label")) orelse "partition",
        } } };
    }
    if (std.mem.eql(u8, cmd, "provision_ufs")) {
        return .{ .manager = .{ .provision_ufs = .{
            .path = (try objStr(obj, "path")) orelse return error.BadField,
            .finalize = try objBool(obj, "finalize", false),
        } } };
    }
    return error.UnknownCommand;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn collectEvent(alloc: std.mem.Allocator, event: ev.Event) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(alloc);
    try appendEvent(&list, alloc, event);
    return list.toOwnedSlice(alloc);
}

test "appendJsonString escapes specials and passes utf-8 through" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(testing.allocator);
    try appendJsonString(&list, testing.allocator, "a\"b\\c\nd\x01é");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001é\"", list.items);
}

test "finished event serializes with escaped message" {
    var msg = ev.FixedStr(512){};
    msg.set("write \"xbl\" done\nline2");
    const out = try collectEvent(testing.allocator, .{ .finished = .{ .success = true, .message = msg } });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"ev\":\"finished\",\"success\":true,\"message\":\"write \\\"xbl\\\" done\\nline2\"}", out);
}

test "device_added carries mode id, label and identity" {
    var info = ev.DeviceInfo{ .vid = 0x05c6, .pid = 0x9008, .bus = 1, .devnum = 7, .mode = .qualcomm_edl };
    info.key.path.set("/sys/devices/x");
    info.product.set("QDLoader");
    const out = try collectEvent(testing.allocator, .{ .device_added = info });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"mode\":\"qualcomm_edl\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"label\":\"Qualcomm EDL\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"vid\":1478") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"pid\":36872") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"product\":\"QDLoader\"") != null);
}

test "progress serializes fraction and indeterminate" {
    const out = try collectEvent(testing.allocator, .{ .progress = .{ .fraction = 0.5, .done = 10, .total = 20, .label = FixedStrLit(160, "writing xbl") } });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"fraction\":0.5000") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"label\":\"writing xbl\"") != null);

    const out2 = try collectEvent(testing.allocator, .{ .progress = .{ .fraction = -1.0 } });
    defer testing.allocator.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "\"fraction\":-1") != null);
}

fn FixedStrLit(comptime N: usize, s: []const u8) ev.FixedStr(N) {
    return ev.FixedStr(N).fromSlice(s);
}

test "session state and partitions serialize" {
    const out = try collectEvent(testing.allocator, .{ .session_state = .firehose_ready });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"ev\":\"state\",\"state\":\"firehose_ready\"}", out);

    var parts = ev.PartitionsEvent{ .lun = 0, .sector_size = 4096, .luns = 2 };
    parts.parts[0] = .{ .index = 1, .first_lba = 6, .last_lba = 100, .name = FixedStrLit(72, "xbl") };
    parts.count = 1;
    const out2 = try collectEvent(testing.allocator, .{ .partitions = parts });
    defer testing.allocator.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "\"vip\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out2, "\"name\":\"xbl\",\"first_lba\":6,\"last_lba\":100") != null);
}

test "log event serializes level and text" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(testing.allocator);
    try appendLogEvent(&list, testing.allocator, .{ .seq = 1, .ts_ms = 0, .level = .warn, .len = 5, .text = blk: {
        var t: [log.max_text_len]u8 = undefined;
        @memcpy(t[0..5], "cache");
        break :blk t;
    } });
    try testing.expectEqualStrings("{\"ev\":\"log\",\"level\":\"warn\",\"text\":\"cache\"}", list.items);
}

test "hello line has protocol and version" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(testing.allocator);
    try helloLine(&list, testing.allocator);
    try testing.expectEqualStrings("{\"ev\":\"hello\",\"protocol\":\"ultron-daemon\",\"version\":1}", list.items);
}

test "parseRequest maps commands onto manager requests" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // connect with all optional fields
    const p1 = try parseRequest(arena, "{\"cmd\":\"connect\",\"programmer\":\"/tmp/firehose.mbn\",\"storage\":\"emmc\",\"skip_storage_init\":true,\"bus\":1,\"devnum\":9}");
    switch (p1.manager) {
        .connect => |c| {
            try testing.expectEqualStrings("/tmp/firehose.mbn", c.programmer.?);
            try testing.expectEqual(firehose.StorageType.emmc, c.storage);
            try testing.expect(c.skip_storage_init);
            try testing.expect(c.target != null);
            try testing.expectEqual(@as(u32, 9), c.target.?.devnum.?);
        },
        else => return error.TestUnexpectedResult,
    }

    // flash_xml with a file list
    const p2 = try parseRequest(arena, "{\"cmd\":\"flash_xml\",\"files\":[\"a.xml\",\"b.xml\"],\"allow_missing\":true}");
    switch (p2.manager) {
        .flash_xml => |f| {
            try testing.expectEqual(@as(usize, 2), f.files.len);
            try testing.expectEqualStrings("b.xml", f.files[1]);
            try testing.expect(f.allow_missing);
        },
        else => return error.TestUnexpectedResult,
    }

    // void commands
    try testing.expect(std.meta.activeTag((try parseRequest(arena, "{\"cmd\":\"reset\"}")).manager) == .reset);
    try testing.expect((try parseRequest(arena, "{\"cmd\":\"cancel\"}")) == .cancel);
    try testing.expect((try parseRequest(arena, "{\"cmd\":\"shutdown\"}")) == .shutdown);

    // defaults: storage falls back to ufs, skip_storage_init to false
    const p3 = try parseRequest(arena, "{\"cmd\":\"connect\"}");
    switch (p3.manager) {
        .connect => |c| {
            try testing.expectEqual(firehose.StorageType.ufs, c.storage);
            try testing.expect(!c.skip_storage_init);
            try testing.expect(c.programmer == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseRequest rejects garbage and unknown commands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.NotJson, parseRequest(arena, "not json"));
    try testing.expectError(error.NotAnObject, parseRequest(arena, "[1,2]"));
    try testing.expectError(error.UnknownCommand, parseRequest(arena, "{}"));
    try testing.expectError(error.UnknownCommand, parseRequest(arena, "{\"cmd\":\"exec\",\"args\":\"rm -rf\"}"));
    try testing.expectError(error.BadField, parseRequest(arena, "{\"cmd\":\"connect\",\"storage\":\"scsi\"}"));
    try testing.expectError(error.BadField, parseRequest(arena, "{\"cmd\":\"upload_loader\"}"));
    try testing.expectError(error.BadField, parseRequest(arena, "{\"cmd\":\"flash_xml\",\"files\":\"a.xml\"}"));
}
