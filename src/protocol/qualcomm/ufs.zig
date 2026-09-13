//! UFS provisioning config — Zig port of linux-msm/qdl src/ufs.c
//! (BSD-3-Clause, © 2018 The Linux Foundation).
//!
//! Loads a `<ufs>` provisioning XML (one common tag, one or more LUN body
//! tags, one epilogue tag), validates it against the user's finalize intent
//! (qdl's --finalize-provisioning ↔ bConfigDescrLock match rule), and runs
//! qdl's two-pass execution: a full validation pass with commit=0 that the
//! target may refuse, then the real pass with commit=1.
//!
//! Provisioning with bConfigDescrLock = 1 is an irreversible OTP operation.

const std = @import("std");
const log = @import("../../core/log.zig");
const fileio = @import("../../core/fileio.zig");
const xml = @import("xml.zig");
const firehose = @import("firehose.zig");

pub const Config = struct {
    common: firehose.UfsCommon,
    bodies: std.ArrayList(firehose.UfsBody) = .empty,
    epilogue: firehose.UfsEpilogue = .{},

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        self.bodies.deinit(alloc);
    }

    /// True when this config performs the irreversible OTP lock.
    pub fn isOtp(self: *const Config) bool {
        return self.common.bConfigDescrLock != 0;
    }
};

fn attrU64(el: *xml.Element, name: []const u8, errors: *u32) u64 {
    const v = el.attr(name) orelse {
        errors.* += 1;
        return 0;
    };
    return std.fmt.parseInt(u64, v, 10) catch {
        errors.* += 1;
        return 0;
    };
}

fn attrBool(el: *xml.Element, name: []const u8, errors: *u32) u32 {
    return if (attrU64(el, name, errors) != 0) 1 else 0;
}

/// Load and validate a provisioning XML. `finalize` mirrors qdl's
/// --finalize-provisioning: it must match the XML's bConfigDescrLock, or
/// provisioning is refused (qdl's mismatch safety).
pub fn load(alloc: std.mem.Allocator, path: []const u8, finalize: bool, logger: *log.Logger) !Config {
    const contents = fileio.readFileAlloc(alloc, path, 4 * 1024 * 1024) catch |e| {
        logger.err("unable to read {s}: {s}", .{ path, @errorName(e) });
        return e;
    };
    defer alloc.free(contents);

    // The arena owns the desc strings; the parsed values are copied out.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const doc = try xml.parse(arena.allocator(), contents);

    var cfg = Config{ .common = .{} };
    errdefer cfg.deinit(alloc);
    var have_common = false;
    var have_epilogue = false;

    for (doc.root.children) |el| {
        if (!std.mem.eql(u8, el.name, "ufs")) {
            logger.err("unrecognized tag <{s}> in {s}, ignoring", .{ el.name, path });
            continue;
        }

        var errors: u32 = 0;
        if (el.attr("bNumberLU") != null) {
            if (have_common) {
                logger.err("multiple UFS common tags found in {s}", .{path});
                return error.Invalid;
            }
            var c = firehose.UfsCommon{
                .bNumberLU = @intCast(attrU64(el, "bNumberLU", &errors)),
                .bBootEnable = attrBool(el, "bBootEnable", &errors),
                .bDescrAccessEn = attrBool(el, "bDescrAccessEn", &errors),
                .bInitPowerMode = @intCast(attrU64(el, "bInitPowerMode", &errors)),
                .bHighPriorityLUN = @intCast(attrU64(el, "bHighPriorityLUN", &errors)),
                .bSecureRemovalType = @intCast(attrU64(el, "bSecureRemovalType", &errors)),
                .bInitActiveICCLevel = @intCast(attrU64(el, "bInitActiveICCLevel", &errors)),
                .wPeriodicRTCUpdate = @intCast(attrU64(el, "wPeriodicRTCUpdate", &errors)),
                .bConfigDescrLock = attrBool(el, "bConfigDescrLock", &errors),
            };
            // Optional write-booster parameters.
            var wb_errors: u32 = 0;
            c.bWriteBoosterBufferPreserveUserSpaceEn = attrBool(el, "bWriteBoosterBufferPreserveUserSpaceEn", &wb_errors);
            c.bWriteBoosterBufferType = attrBool(el, "bWriteBoosterBufferType", &wb_errors);
            c.shared_wb_buffer_size_in_kb = @intCast(attrU64(el, "shared_wb_buffer_size_in_kb", &wb_errors));
            c.wb = wb_errors == 0;
            if (errors != 0) {
                logger.err("errors while parsing UFS common tag in {s}", .{path});
                return error.Invalid;
            }
            cfg.common = c;
            have_common = true;
        } else if (el.attr("LUNum") != null) {
            const b = firehose.UfsBody{
                .LUNum = @intCast(attrU64(el, "LUNum", &errors)),
                .bLUEnable = attrBool(el, "bLUEnable", &errors),
                .bBootLunID = @intCast(attrU64(el, "bBootLunID", &errors)),
                .size_in_kb = @intCast(attrU64(el, "size_in_kb", &errors)),
                .bDataReliability = @intCast(attrU64(el, "bDataReliability", &errors)),
                .bLUWriteProtect = @intCast(attrU64(el, "bLUWriteProtect", &errors)),
                .bMemoryType = @intCast(attrU64(el, "bMemoryType", &errors)),
                .bLogicalBlockSize = @intCast(attrU64(el, "bLogicalBlockSize", &errors)),
                .bProvisioningType = @intCast(attrU64(el, "bProvisioningType", &errors)),
                .wContextCapabilities = @intCast(attrU64(el, "wContextCapabilities", &errors)),
                .desc = el.attr("desc"),
            };
            if (errors != 0) {
                logger.err("errors while parsing UFS body tag in {s}", .{path});
                return error.Invalid;
            }
            try cfg.bodies.append(alloc, b);
        } else if (el.attr("commit") != null) {
            if (have_epilogue) {
                logger.err("multiple UFS finalizing tags found in {s}", .{path});
                return error.Invalid;
            }
            cfg.epilogue = .{ .LUNtoGrow = @intCast(attrU64(el, "LUNtoGrow", &errors)) };
            if (errors != 0) {
                logger.err("errors while parsing UFS finalizing tag in {s}", .{path});
                return error.Invalid;
            }
            have_epilogue = true;
        } else {
            logger.err("unknown tag found in ufs-type file {s}", .{path});
            return error.Invalid;
        }
    }

    if (!have_common or cfg.bodies.items.len == 0 or !have_epilogue) {
        logger.err("incomplete UFS provisioning information in {s}", .{path});
        return error.Invalid;
    }

    // qdl's safety: the OTP lock flag must match the user's explicit intent.
    if (@intFromBool(finalize) != @intFromBool(cfg.isOtp())) {
        logger.err("bConfigDescrLock={d} in {s} does not match the finalize intent ({d}) — provisioning not performed", .{ cfg.common.bConfigDescrLock, path, @intFromBool(finalize) });
        logger.err("UFS provisioning is irreversible (OTP) when bConfigDescrLock=1; see the tool's provisioning panel", .{});
        return error.Mismatch;
    }

    // desc strings live in the arena — copy them out for the returned config.
    for (cfg.bodies.items) |*b| {
        if (b.desc) |d| {
            const owned = try alloc.dupe(u8, d);
            b.desc = owned;
        }
    }
    return cfg;
}

pub fn deinitDescs(cfg: *Config, alloc: std.mem.Allocator) void {
    for (cfg.bodies.items) |*b| {
        if (b.desc) |d| alloc.free(d);
        b.desc = null;
    }
}

/// Port of ufs_provisioning_execute: full validation pass (commit=0, the
/// target may refuse a bad XML), then the real pass (commit=1).
pub fn execute(cfg: *const Config, fh: *firehose.Session, logger: *log.Logger) !void {
    logger.info("UFS provisioning: validation pass (commit=0)", .{});
    try runPass(cfg, fh, false, logger);
    logger.info("UFS provisioning: validation accepted by the target — committing", .{});
    if (cfg.isOtp()) {
        logger.warn("WARNING: irreversible OTP provisioning is being committed", .{});
    }
    try runPass(cfg, fh, true, logger);
}

fn runPass(cfg: *const Config, fh: *firehose.Session, commit: bool, logger: *log.Logger) !void {
    try fh.applyUfsCommon(&cfg.common);
    for (cfg.bodies.items) |*b| {
        try fh.applyUfsBody(b);
    }
    fh.applyUfsEpilogue(&cfg.epilogue, commit) catch {
        if (!commit) logger.err("UFS provisioning impossible, provisioning XML may be corrupted", .{});
        return error.UfsFailed;
    };
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const test_xml =
    \\<?xml version="1.0" ?>
    \\<provision>
    \\<ufs bNumberLU="4" bBootEnable="1" bDescrAccessEn="0" bInitPowerMode="15" bHighPriorityLUN="1" bSecureRemovalType="0" bInitActiveICCLevel="0" wPeriodicRTCUpdate="0" bConfigDescrLock="0"/>
    \\<ufs LUNum="0" bLUEnable="1" bBootLunID="0" size_in_kb="16384" bDataReliability="1" bLUWriteProtect="0" bMemoryType="3" bLogicalBlockSize="12" bProvisioningType="0" wContextCapabilities="0" desc="HeliOSS"/>
    \\<ufs LUNum="1" bLUEnable="1" bBootLunID="0" size_in_kb="1024" bDataReliability="1" bLUWriteProtect="0" bMemoryType="3" bLogicalBlockSize="12" bProvisioningType="0" wContextCapabilities="0"/>
    \\<ufs LUNtoGrow="1" commit="0"/>
    \\</provision>
;

fn testLogger() *log.Logger {
    const l = std.testing.allocator.create(log.Logger) catch unreachable;
    l.* = .{ .mirror_stderr = false };
    return l;
}

test "ufs load parses tags and validates" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("provision.xml", test_xml);

    const l = testLogger();
    defer std.testing.allocator.destroy(l);
    var pbuf: [176]u8 = undefined;
    const path = try tmp.filePath(&pbuf, "provision.xml");

    var cfg = try load(std.testing.allocator, path, false, l);
    defer cfg.deinit(std.testing.allocator);
    defer deinitDescs(&cfg, std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 4), cfg.common.bNumberLU);
    try std.testing.expectEqual(@as(u32, 0), cfg.common.bConfigDescrLock);
    try std.testing.expectEqual(@as(usize, 2), cfg.bodies.items.len);
    try std.testing.expectEqualStrings("HeliOSS", cfg.bodies.items[0].desc.?);
    try std.testing.expectEqual(@as(u32, 1), cfg.epilogue.LUNtoGrow);
    try std.testing.expect(!cfg.isOtp());
}

test "ufs load rejects finalize mismatch" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("provision.xml", test_xml);

    const l = testLogger();
    defer std.testing.allocator.destroy(l);
    var pbuf: [176]u8 = undefined;
    const path = try tmp.filePath(&pbuf, "provision.xml");

    try std.testing.expectError(error.Mismatch, load(std.testing.allocator, path, true, l));
}

test "ufs execute runs validation then commit against the firehose session" {
    const Harness = @import("../../transport/sim.zig").Harness;
    const SimStep = @import("../../transport/sim.zig").Step;
    const transport = @import("../../transport/transport.zig");

    const ack = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\"/></data>";
    const steps = [_]SimStep{
        // validation pass: common + 2 bodies + epilogue(commit=0)
        .{ .any_write = {} },
        .{ .respond = ack },
        .{ .any_write = {} },
        .{ .respond = ack },
        .{ .any_write = {} },
        .{ .respond = ack },
        .{ .any_write = {} },
        .{ .respond = ack },
        // commit pass: epilogue carries commit=1
        .{ .any_write = {} },
        .{ .respond = ack },
        .{ .any_write = {} },
        .{ .respond = ack },
        .{ .any_write = {} },
        .{ .respond = ack },
        .{ .any_write = {} },
        .{ .respond = ack },
    };

    const l = testLogger();
    defer std.testing.allocator.destroy(l);

    var h = try Harness.init(std.testing.allocator, &steps);
    defer h.deinit();
    var io = transport.Io.init(std.testing.allocator, h.transport());
    defer io.deinit();
    var sess = firehose.Session{ .alloc = std.testing.allocator, .io = &io, .logger = l };

    var cfg = Config{ .common = .{ .bNumberLU = 2 }, .epilogue = .{ .LUNtoGrow = 1 } };
    defer cfg.deinit(std.testing.allocator);
    try cfg.bodies.append(std.testing.allocator, .{ .LUNum = 0 });
    try cfg.bodies.append(std.testing.allocator, .{ .LUNum = 1 });

    try execute(&cfg, &sess, l);
    try std.testing.expect(h.failure == null);
}
