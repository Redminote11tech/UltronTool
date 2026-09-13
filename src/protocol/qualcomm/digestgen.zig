//! Offline VIP digest-table generation — the `ultron --create-digests` mode.
//!
//! Replays a rawprogram flash plan against a loopback "always ACK" device
//! while hashing every Firehose packet (XML command documents and data
//! chunks) into a VIP digest table. The byte-exact packet sequence is the
//! whole point: the resulting table is only valid for flashing runs that
//! send exactly these packets, in this order — same storage type, same
//! payload size (no renegotiation!), same SkipStorageInit setting, same XML
//! files and images, no partition reads in between.
//!
//! Reference: linux-msm/qdl vip.c digest generation (sim dry-run mode).

const std = @import("std");
const transport = @import("../../transport/transport.zig");
const log = @import("../../core/log.zig");
const fileio = @import("../../core/fileio.zig");
const firehose = @import("firehose.zig");
const rawprogram = @import("rawprogram.zig");
const vip = @import("vip.zig");

pub const Options = struct {
    /// Directory that receives DIGEST_TABLE.bin, DigestsToSign.bin and
    /// ChainedTableOfDigests<N>.bin.
    dir: []const u8,
    /// rawprogram*.xml / patch*.xml files, in flash order.
    xml_files: []const []const u8,
    /// Must match the payload size the real programmer accepts without
    /// renegotiation — it changes the chunk layout, hence every digest.
    payload_size: usize = firehose.default_max_payload_size,
    storage: firehose.StorageType = .ufs,
    /// Must match the flashing run's SkipStorageInit setting.
    skip_storage_init: bool = false,
};

pub fn run(alloc: std.mem.Allocator, logger: *log.Logger, opts: Options) !void {
    // Load the flash plan up front so a bad XML or missing image fails
    // before any output is written.
    var loader = rawprogram.Loader.init(alloc);
    defer loader.deinit();
    for (opts.xml_files) |file| {
        try loader.loadFile(file, false, logger);
    }
    const ops = loader.opsSlice();
    if (ops.len == 0) return error.NoOperations;

    var gen = try vip.Generator.init(alloc, opts.dir);
    defer gen.deinit();

    var dev = AutoAck.init(alloc, logger);
    defer dev.deinit();
    var io = transport.Io.init(alloc, dev.asTransport());
    defer io.deinit();

    var sess = firehose.Session{
        .alloc = alloc,
        .io = &io,
        .logger = logger,
        .max_payload_size = opts.payload_size,
        .digest_gen = &gen,
    };
    // The offline replay must skip the sector-size probe: the real VIP run
    // skips it too (probe packets are not in the digest table).
    sess.no_probe = true;

    logger.info("digest replay: configure (payload {d}, storage {s}, skip_storage_init {})", .{
        opts.payload_size,
        opts.storage.memoryName(),
        opts.skip_storage_init,
    });
    try sess.configure(opts.storage, opts.skip_storage_init);

    // Op order mirrors manager.flashXml, including the conditional
    // set-bootable append — keep both in sync.
    var op_list = std.ArrayList(ExecOp).empty;
    defer op_list.deinit(alloc);
    for (ops) |op| try op_list.append(alloc, .{ .op = op });
    if (findBootablePartition(ops)) |part| {
        logger.info("digest replay: adding set-bootable for partition {d}", .{part});
        try op_list.append(alloc, .{ .set_bootable = part });
    }

    for (op_list.items) |item| {
        switch (item) {
            .op => |op| switch (op.tag) {
                .program => |*p| {
                    const fname = p.filename orelse continue;
                    logger.info("digest replay: programming {s}", .{fname});
                    var file = try fileio.File.open(fname);
                    defer file.close();
                    try sess.program(p, &file);
                },
                .erase => |*e| {
                    logger.info("digest replay: erasing {s}+{d}", .{ e.start_sector, e.num_sectors });
                    try sess.erase(e);
                },
                .patch => |*pt| {
                    logger.info("digest replay: patching {s}", .{pt.what orelse "?"});
                    try sess.applyPatch(pt);
                },
            },
            .set_bootable => |part| try sess.setBootable(part),
        }
    }

    try gen.finalize();

    const total = gen.digest_num_written;
    const chained = vip.chainedCountFor(total);
    logger.info("✓ digest tables written to {s}: {d} packets ({d} signed-table slots, {d} chained table(s))", .{
        opts.dir,
        total,
        @min(total, vip.max_digests_per_signed_table),
        chained,
    });
    logger.info("next step: have DigestsToSign.bin signed, then save the signed image as DigestsToSign.bin.mbn next to the chained tables", .{});
    if (chained > vip.max_chained_files) {
        logger.err("plan needs {d} chained tables but a session supports at most {d} — split the flash plan", .{ chained, vip.max_chained_files });
        return error.TooManyChainedTables;
    }
}

const ExecOp = union(enum) {
    op: rawprogram.Op,
    set_bootable: u32,
};

/// Port of manager.findBootablePartition (xbl > xbl_a > sbl1, first match).
/// Kept in sync with the manager's copy.
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

// ----------------------------------------------------------------------
// Loopback device: ACKs every XML command, consumes data phases
// ----------------------------------------------------------------------

/// The smallest Firehose "device" the replay can run against: XML commands
/// get an ACK, program data phases are counted so the final ACK arrives at
/// the right moment. Responses only — the packet hashing happens in the
/// Firehose layer via the digest generator.
const AutoAck = struct {
    alloc: std.mem.Allocator,
    logger: *log.Logger,
    pending: std.ArrayList(u8) = .empty,
    data_left: u64 = 0,

    const ack_xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\"/></data>";

    fn init(alloc: std.mem.Allocator, logger: *log.Logger) AutoAck {
        return .{ .alloc = alloc, .logger = logger };
    }

    fn deinit(self: *AutoAck) void {
        self.pending.deinit(self.alloc);
    }

    fn asTransport(self: *AutoAck) transport.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = transport.Transport.VTable{
        .read = read,
        .write = write,
        .close = close,
        .packetSizes = packetSizes,
    };

    fn read(ptr: *anyopaque, buf: []u8, timeout_ms: u32) transport.Error!usize {
        _ = timeout_ms;
        const self: *AutoAck = @ptrCast(@alignCast(ptr));
        if (self.pending.items.len == 0) return transport.Error.Timeout;
        const n = @min(buf.len, self.pending.items.len);
        @memcpy(buf[0..n], self.pending.items[0..n]);
        std.mem.copyForwards(u8, self.pending.items[0 .. self.pending.items.len - n], self.pending.items[n..]);
        self.pending.items.len -= n;
        return n;
    }

    fn write(ptr: *anyopaque, buf: []const u8, timeout_ms: u32) transport.Error!usize {
        _ = timeout_ms;
        const self: *AutoAck = @ptrCast(@alignCast(ptr));
        if (std.mem.startsWith(u8, buf, "<?xml")) {
            try self.classify(buf);
            return buf.len;
        }
        // Binary data chunk of a program operation.
        if (self.data_left < buf.len) {
            self.logger.err("digest replay: data chunk exceeds the declared program size", .{});
            return transport.Error.Io;
        }
        self.data_left -= buf.len;
        if (self.data_left == 0) self.setPending(ack_xml); // final ACK
        return buf.len;
    }

    fn classify(self: *AutoAck, buf: []const u8) transport.Error!void {
        if (std.mem.indexOf(u8, buf, "<program") != null) {
            const sector = xmlAttrU64(buf, "SECTOR_SIZE_IN_BYTES") orelse 0;
            const count = xmlAttrU64(buf, "num_partition_sectors") orelse 0;
            if (sector == 0 or count == 0) {
                self.logger.err("digest replay: program command with zero size", .{});
                return transport.Error.Io;
            }
            self.data_left = sector * count;
            self.setPending(ack_xml); // setup ACK; final ACK queued when data ends
            return;
        }
        self.setPending(ack_xml);
    }

    fn setPending(self: *AutoAck, s: []const u8) void {
        self.pending.clearRetainingCapacity();
        self.pending.appendSlice(self.alloc, s) catch {
            self.logger.err("digest replay: out of memory staging a response", .{});
        };
    }

    fn close(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn packetSizes(ptr: *anyopaque) transport.PacketSizes {
        _ = ptr;
        return .{ .in_max = 512, .out_max = 512 };
    }
};

fn xmlAttrU64(buf: []const u8, name: []const u8) ?u64 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "{s}=\"", .{name}) catch return null;
    const start = std.mem.indexOf(u8, buf, pat) orelse return null;
    const vstart = start + pat.len;
    var end = vstart;
    while (end < buf.len and std.ascii.isDigit(buf[end])) end += 1;
    if (end == vstart) return null;
    return std.fmt.parseInt(u64, buf[vstart..end], 10) catch null;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

test "digest generation covers configure, setup, data and patch packets" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("rawprogram0.xml",
        \\<?xml version="1.0" ?><data>
        \\<program SECTOR_SIZE_IN_BYTES="512" file_sector_offset="0" filename="boot.img" label="boot" num_partition_sectors="2" physical_partition_number="0" start_sector="8192"/>
        \\</data>
    );
    try tmp.writeFile("patch0.xml",
        \\<?xml version="1.0" ?><patches>
        \\<patch SECTOR_SIZE_IN_BYTES="512" byte_offset="72" filename="DISK" physical_partition_number="0" size_in_bytes="8" start_sector="1" value="0x99" what="test patch"/>
        \\</patches>
    );
    const image = "B" ** 1024; // 2 sectors → one 1024-byte chunk at payload 1024
    try tmp.writeFile("boot.img", image);

    const logger = try std.testing.allocator.create(log.Logger);
    defer std.testing.allocator.destroy(logger);
    logger.* = .{ .mirror_stderr = false };

    var pbuf: [176]u8 = undefined;
    var pbuf2b: [176]u8 = undefined;
    const xml_path = try tmp.filePath(&pbuf, "rawprogram0.xml");
    const patch_path = try tmp.filePath(&pbuf2b, "patch0.xml");
    const xmls = [_][]const u8{ xml_path, patch_path };

    try run(std.testing.allocator, logger, .{
        .dir = tmp.path(),
        .xml_files = &xmls,
        .payload_size = 1024,
        .skip_storage_init = true,
    });

    // Packets: configure + program setup + 1 data chunk + patch = 4 digests.
    var pbuf2: [176]u8 = undefined;
    const table_path = try tmp.filePath(&pbuf2, "DIGEST_TABLE.bin");
    const table = try fileio.readFileAlloc(std.testing.allocator, table_path, 1 << 20);
    defer std.testing.allocator.free(table);
    try std.testing.expectEqual(@as(usize, 4 * 32), table.len);

    const sign_path = try tmp.filePath(&pbuf2, "DigestsToSign.bin");
    const signed = try fileio.readFileAlloc(std.testing.allocator, sign_path, 1 << 20);
    defer std.testing.allocator.free(signed);
    try std.testing.expectEqualSlices(u8, table, signed);
    try std.testing.expect(!fileio.exists(try tmp.filePath(&pbuf2, "ChainedTableOfDigests0.bin")));
}

test "digest generation errors on a missing image" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("rawprogram0.xml",
        \\<?xml version="1.0" ?><data>
        \\<program SECTOR_SIZE_IN_BYTES="512" file_sector_offset="0" filename="absent.img" label="boot" num_partition_sectors="2" physical_partition_number="0" start_sector="8192"/>
        \\</data>
    );

    const logger = try std.testing.allocator.create(log.Logger);
    defer std.testing.allocator.destroy(logger);
    logger.* = .{ .mirror_stderr = false };

    var pbuf: [176]u8 = undefined;
    const xml_path = try tmp.filePath(&pbuf, "rawprogram0.xml");
    const xmls = [_][]const u8{xml_path};
    try std.testing.expectError(error.MissingImage, run(std.testing.allocator, logger, .{
        .dir = tmp.path(),
        .xml_files = &xmls,
    }));
}
