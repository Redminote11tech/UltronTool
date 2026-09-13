//! One-shot Sahara helpers that manage their own transport: the chip-identity
//! probe and the Memory-Debug RAM dump (both ported from linux-msm/qdl,
//! BSD-3-Clause). Each opens its own USB device, runs one Sahara exchange and
//! closes it — they are used pre-connect (probe) and for crash-dump devices.
//! The persistent Firehose session orchestration lives in manager.zig.

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
