//! Ultron — Qualcomm EDL flashing tool.
//!
//! SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const ui = @import("ui/app.zig");
const log_mod = @import("core/log.zig");
const firehose = @import("protocol/qualcomm/firehose.zig");
const digestgen = @import("protocol/qualcomm/digestgen.zig");

const usage_text =
    \\Usage:
    \\  ultron                          start the GUI
    \\  ultron --version                print the version
    \\  ultron --debug                  GUI with debug logging on stderr
    \\
    \\VIP digest-table generation (for programmers that enforce VIP):
    \\  ultron --create-digests DIR [--payload-size N] [--storage NAME]
    \\         [--skip-storage-init] rawprogram*.xml [patch*.xml ...]
    \\
    \\  Replays the flash plan offline and hashes every Firehose packet into
    \\  VIP digest tables in DIR. The table is only valid for a flashing run
    \\  with exactly this plan: same XML files and images, same storage type,
    \\  same payload size (the real programmer must ACK it without
    \\  renegotiating — use its advertised MaxPayloadSizeToTargetInBytes,
    \\  e.g. 16384) and same SkipStorageInit setting as the GUI session.
    \\  Have DigestsToSign.bin signed, save the signed image as
    \\  DigestsToSign.bin.mbn in DIR, then select DIR as the "VIP digest
    \\  tables" folder in the GUI.
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    for (args, 0..) |a, i| {
        const arg = std.mem.span(a);
        if (std.mem.eql(u8, arg, "--create-digests")) {
            // Slice from the flag so digestgenMain sees it at index 0.
            return digestgenMain(args[i..]);
        }
    }
    try ui.mainRun(init);
}

/// Headless `--create-digests` mode: argv[0] is the flag, argv[1] the
/// output directory, then options and XML files.
fn digestgenMain(argv: []const [*:0]const u8) !void {
    const alloc = std.heap.c_allocator;
    const logger = try alloc.create(log_mod.Logger);
    logger.* = .{ .min_level = .info, .mirror_stderr = true };

    if (argv.len < 2) {
        std.debug.print("{s}", .{usage_text});
        std.process.exit(2);
    }

    var opts = digestgen.Options{ .dir = std.mem.span(argv[1]), .xml_files = &.{} };
    var xmls = std.ArrayList([]const u8).empty;
    defer xmls.deinit(alloc);

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--payload-size")) {
            i += 1;
            if (i >= argv.len) return usageFail();
            opts.payload_size = std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) catch return usageFail();
        } else if (std.mem.eql(u8, arg, "--storage")) {
            i += 1;
            if (i >= argv.len) return usageFail();
            const name = std.mem.span(argv[i]);
            opts.storage = parseStorage(name) orelse return usageFail();
        } else if (std.mem.eql(u8, arg, "--skip-storage-init")) {
            opts.skip_storage_init = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("unknown option: {s}\n\n{s}", .{ arg, usage_text });
            std.process.exit(2);
        } else {
            xmls.append(alloc, arg) catch {
                logger.err("out of memory", .{});
                std.process.exit(1);
            };
        }
    }
    if (xmls.items.len == 0) return usageFail();
    opts.xml_files = xmls.items;

    digestgen.run(alloc, logger, opts) catch |e| {
        logger.err("digest generation failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
}

fn usageFail() error{InvalidArguments} {
    std.debug.print("{s}", .{usage_text});
    std.process.exit(2);
}

fn parseStorage(name: []const u8) ?firehose.StorageType {
    inline for (@typeInfo(firehose.StorageType).@"enum".fields) |f| {
        if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

test {
    _ = @import("test_root.zig");
}
