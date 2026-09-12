//! Flash-session orchestration — port of the qdl op-list design
//! (linux-msm/qdl src/qdl.c, BSD-3-Clause).
//!
//! A session runs on a worker thread: it opens the USB transport, uploads the
//! firehose programmer over Sahara, configures Firehose, executes the ops
//! built from the user's rawprogram/patch XML files in the order given,
//! appends SET_BOOTABLE when an xbl/xbl_a/sbl1 partition was written, and
//! finishes with a device reset. Progress and the final result are pushed to
//! the UI event channel; cancellation is checked between transfers.

const std = @import("std");
const transport = @import("../../transport/transport.zig");
const usb = @import("../../transport/usb.zig");
const log = @import("../../core/log.zig");
const ev = @import("../../core/event.zig");
const sahara = @import("sahara.zig");
const fh = @import("firehose.zig");
const rawprogram = @import("rawprogram.zig");
const usb_ids = @import("usb_ids.zig");
const fileio = @import("../../core/fileio.zig");

const Error = transport.Error;
const EventChannel = ev.Channel(ev.Event, 256);

pub const FlashRequest = struct {
    /// Path to the device's firehose programmer (.mbn/.elf). Optional when
    /// the programmer is already running on the device.
    programmer: ?[]const u8 = null,
    /// rawprogram*.xml and patch*.xml files, executed in the given order
    /// (qdl applies ops in argv order).
    xml_files: []const []const u8 = &.{},
    storage: fh.StorageType = .ufs,
    /// Skip images whose files are absent (qdl --allow-missing).
    allow_missing: bool = false,
    /// Do not send the final reset.
    skip_reset: bool = false,
    /// Optional "_SN:" serial filter for the USB device.
    serial: ?[]const u8 = null,
    /// How long to wait for the device to appear, ms.
    wait_ms: u32 = 5000,
};

/// Run one full flash session. Always pushes a .finished event. Never throws.
pub fn flash(
    alloc: std.mem.Allocator,
    logger: *log.Logger,
    cancel: *const std.atomic.Value(bool),
    channel: *EventChannel,
    req: *const FlashRequest,
) void {
    flashInner(alloc, logger, cancel, channel, req) catch |e| {
        pushFinished(channel, false, @errorName(e));
    };
}

fn flashInner(
    alloc: std.mem.Allocator,
    logger: *log.Logger,
    cancel: *const std.atomic.Value(bool),
    channel: *EventChannel,
    req: *const FlashRequest,
) !void {
    if (cancel.load(.acquire)) return error.Cancelled;

    // 1. Parse the XML files into an op list (user-given order preserved).
    var loader = rawprogram.Loader.init(alloc);
    defer loader.deinit();
    for (req.xml_files) |xml_file| {
        loader.loadFile(xml_file, req.allow_missing, logger) catch |e| {
            logger.err("failed to load {s}", .{xml_file});
            return e;
        };
    }
    const ops = loader.opsSlice();

    if (ops.len == 0 and req.programmer == null) {
        logger.err("nothing to do: no programmer and no XML operations given", .{});
        return error.NothingToDo;
    }

    // 2. Load the programmer image (qdl: image id 13, SAHARA_ID_EHOSTDL_IMG).
    var programmer_data: ?[]u8 = null;
    defer if (programmer_data) |d| alloc.free(d);
    if (req.programmer) |path| {
        logger.info("loading programmer {s}", .{path});
        programmer_data = fileio.readFileAlloc(alloc, path, 64 * 1024 * 1024) catch |e| {
            logger.err("unable to read programmer {s}", .{path});
            return e;
        };
    }

    // 3. Open the USB transport.
    logger.info("waiting for EDL device…", .{});
    var usb_dev = usb.open(&usb_ids.policy, req.serial, req.wait_ms, logger) catch |e| {
        logger.err("failed to open EDL device: {s}", .{@errorName(e)});
        return e;
    };
    defer usb_dev.close();
    logger.info("device opened (interface {d}, out-chunk {d} bytes)", .{ usb_dev.interface_number, usb_dev.out_chunk_size });

    var io = transport.Io.init(alloc, usb_dev.transport());
    defer io.deinit();

    // 4. Sahara: upload the programmer (or skip if Firehose already running).
    if (programmer_data) |data| {
        var images = [_]sahara.Image{.{
            .id = 13,
            .name = std.fs.path.basename(req.programmer.?),
            .data = data,
        }};
        var sa = sahara.Session{
            .io = &io,
            .logger = logger,
            .images = &images,
            .cancel = cancel,
            .progress = .{ .ctx = @constCast(@ptrCast(channel)), .cb = saharaProgressCb },
        };
        logger.info("starting Sahara image transfer", .{});
        try sa.run(.{ .detect_firehose = true });
    } else {
        logger.info("no programmer given; assuming Firehose programmer is already running", .{});
    }

    if (cancel.load(.acquire)) return error.Cancelled;

    // 5. Firehose configure.
    var fhs = fh.Session{
        .alloc = alloc,
        .io = &io,
        .logger = logger,
        .cancel = cancel,
    };
    var exec_ctx = ExecCtx{ .channel = channel, .logger = logger };
    fhs.progress = .{ .ctx = &exec_ctx, .cb = firehoseProgressCb };

    logger.info("configuring Firehose ({s})", .{req.storage.memoryName()});
    try fhs.configure(req.storage, false);

    // 6. Append SET_BOOTABLE when a primary bootloader partition was written
    //    (port of qdl_determine_bootable / program_find_bootable_partition).
    var op_list = std.ArrayList(ExecOp).empty;
    defer op_list.deinit(alloc);
    for (ops) |op| {
        try op_list.append(alloc, .{ .op = op });
    }
    if (findBootablePartition(ops)) |part| {
        logger.info("adding set-bootable for partition {d}", .{part});
        try op_list.append(alloc, .{ .set_bootable = part });
    }

    // 7. Execute the ops in order, reporting overall progress.
    const total = op_list.items.len;
    exec_ctx.op_total = total;
    for (op_list.items, 0..) |item, i| {
        if (cancel.load(.acquire)) return error.Cancelled;
        exec_ctx.op_idx = i;

        switch (item) {
            .op => |op| switch (op.tag) {
                .program => |*p| {
                    const fname = p.filename orelse continue; // dropped missing image
                    logger.info("programming {s} (label {s})", .{ fname, p.label orelse "?" });
                    var file = fileio.File.open(fname) catch |e| {
                        logger.err("unable to open image {s}", .{fname});
                        return e;
                    };
                    defer file.close();
                    try fhs.program(p, &file);
                },
                .erase => |*e| {
                    logger.info("erasing partition {s} ({d} sectors)", .{ e.start_sector, e.num_sectors });
                    try fhs.erase(e);
                },
                .patch => |*pt| {
                    try fhs.applyPatch(pt);
                },
            },
            .set_bootable => |part| {
                try fhs.setBootable(part);
            },
        }
    }

    // 8. Reset unless asked otherwise. A failed reset does not fail the flash.
    if (!req.skip_reset and total > 0) {
        logger.info("resetting device", .{});
        fhs.reset() catch |e| {
            logger.warn("device reset failed: {s} (you may need to reboot manually)", .{@errorName(e)});
        };
    }

    pushFinished(channel, true, "done");
}

const ExecOp = union(enum) {
    op: rawprogram.Op,
    set_bootable: u32,
};

/// Port of program_find_bootable_partition: first match wins with the
/// priority xbl > xbl_a > sbl1 (later candidates only apply when no earlier
/// one was found).
fn findBootablePartition(ops: []const rawprogram.Op) ?u32 {
    const candidates = [_][]const u8{ "xbl", "xbl_a", "sbl1" };
    for (candidates) |label| {
        for (ops) |op| {
            switch (op.tag) {
                .program => |p| {
                    const l = p.label orelse continue;
                    if (std.mem.eql(u8, l, label)) return p.partition;
                },
                else => {},
            }
        }
    }
    return null;
}

/// Sahara progress → overall progress event (sahara upload counts as the
/// first 10% of the session).
fn saharaProgressCb(ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void {
    const channel: *EventChannel = @ptrCast(@alignCast(ctx orelse return));
    const frac: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    var buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "uploading {s}", .{name}) catch name;
    channel.push(.{ .progress = .{ .fraction = 0.1 * frac, .label = ev.FixedStr(160).fromSlice(text) } });
}

const ExecCtx = struct {
    channel: *EventChannel,
    logger: *log.Logger,
    op_idx: usize = 0,
    op_total: usize = 0,
};

fn firehoseProgressCb(ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void {
    const ectx: *ExecCtx = @ptrCast(@alignCast(ctx orelse return));
    const op_frac: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    const base: f32 = if (ectx.op_total == 0) 0 else @as(f32, @floatFromInt(ectx.op_idx)) / @as(f32, @floatFromInt(ectx.op_total));
    const step: f32 = if (ectx.op_total == 0) 1 else 1.0 / @as(f32, @floatFromInt(ectx.op_total));
    const overall = 0.1 + 0.9 * (base + step * op_frac);

    var label = ev.FixedStr(160){};
    label.set(name);
    ectx.channel.push(.{ .progress = .{ .fraction = overall, .label = label } });
}

fn pushFinished(channel: *EventChannel, success: bool, msg: []const u8) void {
    var m = ev.FixedStr(512){};
    m.set(msg);
    channel.push(.{ .finished = .{ .success = success, .message = m } });
}

// ----------------------------------------------------------------------
// Chip identity probe (port of sahara_chipinfo)
// ----------------------------------------------------------------------

pub fn chipInfo(
    alloc: std.mem.Allocator,
    logger: *log.Logger,
    cancel: *const std.atomic.Value(bool),
    serial: ?[]const u8,
    wait_ms: u32,
) !sahara.ChipInfo {
    var usb_dev = try usb.open(&usb_ids.policy, serial, wait_ms, logger, alloc);
    defer usb_dev.close();
    var io = transport.Io.init(alloc, usb_dev.transport());
    defer io.deinit();

    var sa = sahara.Session{ .io = &io, .logger = logger, .images = &[_]sahara.Image{}, .cancel = cancel };
    return sa.chipInfoSession();
}

test "flash session end-to-end over sim transport" {
    // The sim backend is protocol-agnostic; here we drive the inner pieces
    // against a scripted firehose programmer (sahara skipped: no programmer).
const SimHarness = @import("../../transport/sim.zig").Harness;
const SimStep = @import("../../transport/sim.zig").Step;

    // Exactly 2 sectors of 32 bytes, so ceil(size/sector) == num_partition_sectors.
    var image: [64]u8 = undefined;
    for (&image, 0..) |*b, i| b.* = @truncate(i * 7);
    const padded = image;

    const setup_ack = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\"/></data>";
    const steps = [_]SimStep{
        // The setup ack is only queued after the first read, which follows
        // the ignored program-request write.
        .{ .read_timeout = {} },
        .{ .respond = setup_ack },
        // image data (2 sectors of 32 bytes)
        .{ .expect_write = padded[0..64] },
        // final ack, reset ack
        .{ .respond = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\"/></data>" },
        .{ .respond = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\"/></data>" },
    };

    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("img.bin", &image);

    const xml_content = "<?xml version=\"1.0\" ?><data><program SECTOR_SIZE_IN_BYTES=\"32\" file_sector_offset=\"0\" filename=\"img.bin\" label=\"boot\" num_partition_sectors=\"2\" physical_partition_number=\"0\" start_sector=\"1024\"/></data>";
    try tmp.writeFile("rawprogram0.xml", xml_content);
    var xbuf: [176]u8 = undefined;
    const xml_path = try tmp.filePath(&xbuf, "rawprogram0.xml");

    var h = try SimHarness.init(std.testing.allocator, &steps);
    defer h.deinit();
    var io = transport.Io.init(std.testing.allocator, h.transport());
    defer io.deinit();
    var logger = log.Logger{ .mirror_stderr = false };

    // Drive the post-transport stages directly (usb.open is not simulated).
    var cancel = std.atomic.Value(bool).init(false);
    var channel = EventChannel{};
    var loader = rawprogram.Loader.init(std.testing.allocator);
    defer loader.deinit();
    try loader.loadFile(xml_path, false, &logger);

    var fhs = fh.Session{
        .alloc = std.testing.allocator,
        .io = &io,
        .logger = &logger,
        .cancel = &cancel,
        .max_payload_size = 64,
        .sector_size = 32,
    };
    var ectx = ExecCtx{ .channel = &channel, .logger = &logger };
    fhs.progress = .{ .ctx = &ectx, .cb = firehoseProgressCb };
    // Skip configure's network-free probe path: set sizes directly.
    ectx.op_total = loader.opsSlice().len;
    for (loader.opsSlice(), 0..) |op, i| {
        ectx.op_idx = i;
        switch (op.tag) {
            .program => |*p| {
                var file = try fileio.File.open(p.filename.?);
                defer file.close();
                try fhs.program(p, &file);
            },
            else => {},
        }
    }
    // Label "boot" is not a primary bootloader: qdl adds no set-bootable op.
    try std.testing.expect(findBootablePartition(loader.opsSlice()) == null);
    try fhs.reset();

    try std.testing.expect(h.failure == null);
}
