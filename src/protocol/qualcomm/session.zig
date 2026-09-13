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

// ----------------------------------------------------------------------
// Chip identity probe (port of sahara_chipinfo)
// ----------------------------------------------------------------------

pub fn chipInfo(
    alloc: std.mem.Allocator,
    logger: *log.Logger,
    cancel: *const std.atomic.Value(bool),
    target: ?transport.Target,
    wait_ms: u32,
) !sahara.ChipInfo {
    var usb_dev = try usb.open(&usb_ids.policy, target, wait_ms, logger, alloc, cancel);
    defer usb_dev.close();
    var io = transport.Io.init(alloc, usb_dev.transport());
    defer io.deinit();

    var sa = sahara.Session{ .io = &io, .logger = logger, .images = &[_]sahara.Image{}, .cancel = cancel };
    return sa.chipInfoSession();
}

// ----------------------------------------------------------------------
// RAM dump (Sahara Memory Debug mode, crash-dump devices)
// ----------------------------------------------------------------------

pub fn ramDump(
    alloc: std.mem.Allocator,
    logger: *log.Logger,
    cancel: *const std.atomic.Value(bool),
    progress: sahara.ProgressHook,
    target: ?transport.Target,
    wait_ms: u32,
    dir: []const u8,
    filter: ?[]const u8,
) !u32 {
    var usb_dev = try usb.open(&usb_ids.policy, target, wait_ms, logger, alloc, cancel);
    defer usb_dev.close();
    var io = transport.Io.init(alloc, usb_dev.transport());
    defer io.deinit();

    var sa = sahara.Session{
        .io = &io,
        .logger = logger,
        .images = &[_]sahara.Image{},
        .cancel = cancel,
        .progress = progress,
    };
    return sa.ramDump(alloc, .{ .dir = dir, .filter = filter });
}
