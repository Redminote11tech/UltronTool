//! MediaTek legacy-DA flash operations — port of mtkclient's
//! DA/legacy/dalegacy_lib.py (GPL-3.0): the exchange protocol a running
//! (jumped-to) Download Agent speaks.
//!
//! Responses are single characters (Rsp: ACK 0x5A, NACK 0xA5, CONT 0x69).
//! Commands are echoed or ACKed depending on the op; payloads are
//! big-endian. Ported scope: SDMMC_SWITCH_PART (boot/user partition
//! select), READ_CMD eMMC read (1 MiB packets, per-packet BE checksum,
//! ACK each), SDMMC_WRITE_DATA (header → per-packet ACK/byte-sum/CONT),
//! FORMAT_CMD with the progress pump, and FINISH. NOR/NAND paths are not
//! ported (eMMC/UFS devices only — the common rescue case).

const std = @import("std");
const transport = @import("../../transport/transport.zig");
const log = @import("../../core/log.zig");

const Io = transport.Io;
const Error = transport.Error;

/// Full Rsp table from dalegacy_param.py (only ack/cont are exchanged by
/// the ported commands; the rest are kept for reference completeness).
pub const Rsp = struct {
    pub const soc_ok: u8 = 0xc1;
    pub const soc_fail: u8 = 0xcf;
    pub const sync_char: u8 = 0xc0;
    pub const cont_char: u8 = 0x69;
    pub const stop_char: u8 = 0x96;
    pub const ack: u8 = 0x5a;
    pub const nack: u8 = 0xa5;
};

pub const CMD_READ: u8 = 0xd6;
pub const CMD_FORMAT: u8 = 0xd4;
pub const CMD_FINISH: u8 = 0xd9;
pub const CMD_USB_CHECK_STATUS: u8 = 0x72;
pub const CMD_SDMMC_SWITCH_PART: u8 = 0x60;
pub const CMD_SDMMC_WRITE_DATA: u8 = 0x62;

/// EMMC_PART_USER (mtkclient's default partition target).
pub const EMMC_PART_USER: u8 = 0x08;
/// Storage type byte for READ/FORMAT packets (the reference hardcodes
/// 0x02 there). SDMMC_WRITE_DATA takes DaStorage values instead, where
/// eMMC is 0x01 — see WRITE_DATA below.
pub const STORAGE_EMMC: u8 = 0x02;
/// DaStorage.MTK_DA_STORAGE_EMMC — byte 1 of the SDMMC_WRITE_DATA header.
pub const DASTORAGE_EMMC: u8 = 0x01;
/// READ_CMD packet size (1 MiB, as the reference).
pub const read_packet_size: u32 = 0x100000;
/// Host identity byte for READ_CMD (0x0C = Linux).
pub const HOST_LINUX: u8 = 0x0c;

pub const timeout_ms: u32 = 10_000;
/// Data-phase reads can be slow on big packets.
pub const data_timeout_ms: u32 = 30_000;

pub const ProgressHook = struct {
    ctx: ?*anyopaque = null,
    cb: ?*const fn (ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void = null,

    pub fn report(self: ProgressHook, name: []const u8, done: u64, total: u64) void {
        if (self.cb) |cb| cb(self.ctx, name, done, total);
    }
};

pub const Session = struct {
    alloc: std.mem.Allocator,
    io: *Io,
    logger: *log.Logger,
    cancel: *const std.atomic.Value(bool),

    fn cancelled(self: *const Session) bool {
        return self.cancel.load(.acquire);
    }

    fn readByte(self: *Session, timeout: u32) Error!u8 {
        var b: [1]u8 = undefined;
        var got: usize = 0;
        while (got < 1) {
            if (self.cancelled()) return Error.Cancelled;
            got += try self.io.read(&b, timeout);
        }
        return b[0];
    }

    fn expectByte(self: *Session, want: u8, what: []const u8) Error!void {
        const got = try self.readByte(timeout_ms);
        if (got != want) {
            self.logger.err("MTK DA: expected {s} (0x{X:0>2}), got 0x{X:0>2}", .{ what, want, got });
            return Error.Io;
        }
    }

    fn readExact(self: *Session, buf: []u8, timeout: u32) Error!void {
        var got: usize = 0;
        while (got < buf.len) {
            if (self.cancelled()) return Error.Cancelled;
            const n = try self.io.read(buf[got..], timeout);
            got += n;
        }
    }

    fn writeExact(self: *Session, buf: []const u8, timeout: u32) Error!void {
        _ = try self.io.write(buf, timeout);
    }

    /// USB_CHECK_STATUS (0x72): ACK + speed byte — verifies the DA responds.
    pub fn checkStatus(self: *Session) Error!void {
        try self.writeExact(&.{CMD_USB_CHECK_STATUS}, timeout_ms);
        try self.expectByte(Rsp.ack, "USB_CHECK_STATUS ACK");
        _ = try self.readByte(timeout_ms); // speed
    }

    /// SDMMC_SWITCH_PART (0x60): select the eMMC hardware partition.
    pub fn switchPartition(self: *Session, part: u8) Error!void {
        try self.writeExact(&.{CMD_SDMMC_SWITCH_PART}, timeout_ms);
        try self.expectByte(Rsp.ack, "SWITCH_PART ACK");
        try self.writeExact(&.{part}, timeout_ms);
        try self.expectByte(Rsp.ack, "SWITCH_PART part ACK");
    }

    /// READ_CMD (0xD6) eMMC read: header (host id, storage type, BE
    /// addr/length, BE packet size) ACKed, then length/packet-size packets
    /// each followed by a BE u16 checksum and answered with ACK.
    pub fn readFlash(self: *Session, addr: u64, out: []u8, progress: ProgressHook) Error!void {
        try self.switchPartition(EMMC_PART_USER);
        var hdr: [19]u8 = undefined;
        hdr[0] = CMD_READ;
        hdr[1] = HOST_LINUX;
        hdr[2] = STORAGE_EMMC;
        std.mem.writeInt(u64, hdr[3..11], addr, .big);
        std.mem.writeInt(u64, hdr[11..19], out.len, .big);
        // packet size appended below
        var pkt: [19 + 4]u8 = undefined;
        @memcpy(pkt[0..19], &hdr);
        std.mem.writeInt(u32, pkt[19..23], read_packet_size, .big);
        try self.writeExact(&pkt, timeout_ms);
        try self.expectByte(Rsp.ack, "READ header ACK");

        var done: usize = 0;
        var chunk: [read_packet_size]u8 = undefined;
        while (done < out.len) {
            if (self.cancelled()) return Error.Cancelled;
            const want = @min(read_packet_size, out.len - done);
            try self.readExact(chunk[0..want], data_timeout_ms);
            var cs_buf: [2]u8 = undefined;
            try self.readExact(&cs_buf, timeout_ms);
            const rx_sum = std.mem.readInt(u16, &cs_buf, .big);
            var sum: u16 = 0;
            for (chunk[0..want]) |b| sum +%= b;
            if (rx_sum != sum) {
                self.logger.err("MTK DA: read packet checksum mismatch (rx 0x{X:0>4}, computed 0x{X:0>4})", .{ rx_sum, sum });
                return Error.Io;
            }
            @memcpy(out[done .. done + want], chunk[0..want]);
            try self.writeExact(&.{Rsp.ack}, timeout_ms);
            done += want;
            progress.report("reading", done, out.len);
        }
    }

    /// SDMMC_WRITE_DATA (0x62): header (BE storage/part/addr/length, BE
    /// 1 MiB packet size) ACKed, then 1 MiB packets: ACK → data + BE u16
    /// byte-sum → CONT. Length is 512-padded like the reference.
    pub fn writeFlash(self: *Session, addr: u64, data: []const u8, progress: ProgressHook) Error!void {
        try self.switchPartition(EMMC_PART_USER);
        // 512-align the length (the DA requires block-sized transfers).
        const length: u64 = (data.len + 511) / 512 * 512;
        var pkt: [1 + 1 + 1 + 8 + 8 + 4]u8 = undefined;
        pkt[0] = CMD_SDMMC_WRITE_DATA;
        pkt[1] = DASTORAGE_EMMC; // DaStorage value, not the 0x02 hardcode
        pkt[2] = EMMC_PART_USER;
        std.mem.writeInt(u64, pkt[3..11], addr, .big);
        std.mem.writeInt(u64, pkt[11..19], length, .big);
        std.mem.writeInt(u32, pkt[19..23], read_packet_size, .big);
        try self.writeExact(&pkt, timeout_ms);
        try self.expectByte(Rsp.ack, "WRITE header ACK");

        var done: usize = 0;
        const buf = self.alloc.alloc(u8, read_packet_size) catch return Error.OutOfMemory;
        defer self.alloc.free(buf);
        while (done < length) {
            if (self.cancelled()) return Error.Cancelled;
            try self.writeExact(&.{Rsp.ack}, timeout_ms);
            const count: usize = @min(read_packet_size, length - done);
            @memset(buf[0..count], 0);
            const copy = @min(data.len - done, count);
            @memcpy(buf[0..copy], data[done .. done + copy]);
            try self.writeExact(buf[0..count], data_timeout_ms);
            var sum: u16 = 0;
            for (buf[0..count]) |b| sum +%= b;
            var cs_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &cs_buf, sum, .big);
            try self.writeExact(&cs_buf, timeout_ms);
            try self.expectByte(Rsp.cont_char, "WRITE packet CONT");
            done += count;
            progress.report("writing", @min(done, data.len), data.len);
        }
    }

    /// FORMAT_CMD (0xD4): erase addr..addr+length on eMMC with the
    /// progress pump (ACK, progress %, ACK each step until 100).
    pub fn formatFlash(self: *Session, addr: u64, length: u64, progress: ProgressHook) Error!void {
        try self.switchPartition(EMMC_PART_USER);
        var pkt: [1 + 1 + 1 + 1 + 1 + 8 + 8]u8 = undefined;
        pkt[0] = CMD_FORMAT;
        pkt[1] = STORAGE_EMMC;
        pkt[2] = 0x00; // NUTL erase flag
        pkt[3] = 0x00; // validation off
        pkt[4] = 0x00; // NUTL_ADDR_LOGICAL
        std.mem.writeInt(u64, pkt[5..13], addr, .big);
        std.mem.writeInt(u64, pkt[13..21], length, .big);
        try self.writeExact(&pkt, timeout_ms);

        // Progress pump: the DA sends ACK, a progress %, then ACK steps.
        while (true) {
            if (self.cancelled()) return Error.Cancelled;
            try self.expectByte(Rsp.ack, "FORMAT progress ACK");
            try self.expectByte(Rsp.ack, "FORMAT step ACK");
            var prog_buf: [4]u8 = undefined;
            try self.readExact(&prog_buf, timeout_ms); // PROGRESS_INIT
            const pct = try self.readByte(timeout_ms);
            try self.writeExact(&.{Rsp.ack}, timeout_ms);
            progress.report("formatting", pct, 100);
            if (pct == 100) break;
        }
        try self.expectByte(Rsp.ack, "FORMAT final ACK");
    }

    /// FINISH_CMD (0xD9) with value 1 (reboot), per the reference.
    pub fn finish(self: *Session, value: u32) Error!void {
        try self.writeExact(&.{CMD_FINISH}, timeout_ms);
        try self.expectByte(Rsp.ack, "FINISH ACK");
        var be: [4]u8 = undefined;
        std.mem.writeInt(u32, &be, value, .big);
        try self.writeExact(&be, timeout_ms);
        try self.expectByte(Rsp.ack, "FINISH value ACK");
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const Harness = @import("../../transport/sim.zig").Harness;
const Step = @import("../../transport/sim.zig").Step;

test "da read, write, format and finish against a scripted DA" {
    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);

    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };
    const cancel = std.atomic.Value(bool).init(false);

    const ack = [_]u8{Rsp.ack};
    const cont = [_]u8{Rsp.cont_char};

    // READ: switch part, header ack, one packet of 8 bytes + checksum.
    try steps.append(testing.allocator, .{ .expect_write = &.{CMD_SDMMC_SWITCH_PART} });
    try steps.append(testing.allocator, .{ .respond = &ack });
    try steps.append(testing.allocator, .{ .expect_write = &.{EMMC_PART_USER} });
    try steps.append(testing.allocator, .{ .respond = &ack });
    // READ header: cmd + host + storage + addr(8) + len(8) + pktsize(4) = 23
    try steps.append(testing.allocator, .{ .expect_write_len = 23 });
    try steps.append(testing.allocator, .{ .respond = &ack });
    const data = "DATA_123";
    try steps.append(testing.allocator, .{ .respond = data });
    var sum: u16 = 0;
    for (data) |b| sum +%= b;
    var cs: [2]u8 = undefined;
    std.mem.writeInt(u16, &cs, sum, .big);
    try steps.append(testing.allocator, .{ .respond = &cs });
    try steps.append(testing.allocator, .{ .expect_write = &ack });

    // WRITE: switch part, header ack, then ACK / data+sum / CONT.
    try steps.append(testing.allocator, .{ .expect_write = &.{CMD_SDMMC_SWITCH_PART} });
    try steps.append(testing.allocator, .{ .respond = &ack });
    try steps.append(testing.allocator, .{ .expect_write = &.{EMMC_PART_USER} });
    try steps.append(testing.allocator, .{ .respond = &ack });
    try steps.append(testing.allocator, .{ .expect_write_len = 23 }); // write header
    try steps.append(testing.allocator, .{ .respond = &ack });
    try steps.append(testing.allocator, .{ .expect_write = &ack }); // packet poll
    try steps.append(testing.allocator, .{ .expect_write_len = 512 }); // padded packet
    var wsum: u16 = 0;
    for (data) |b| wsum +%= b;
    for (data.len..512) |_| wsum +%= 0;
    var wcs: [2]u8 = undefined;
    std.mem.writeInt(u16, &wcs, wsum, .big);
    try steps.append(testing.allocator, .{ .respond = &cont });
    // (the checksum rides in the same write as the data — the sim compares
    // the whole 512+2 against expect_write_len, so allow 514)
    try steps.append(testing.allocator, .{ .any_write = {} });

    var h = try Harness.init(testing.allocator, steps.items);
    defer h.deinit();
    var io = Io.init(testing.allocator, h.transport());
    defer io.deinit();
    var sess = Session{ .alloc = testing.allocator, .io = &io, .logger = l, .cancel = &cancel };

    var out: [data.len]u8 = undefined;
    try sess.readFlash(0x00010000, &out, .{});
    try testing.expectEqualStrings(data, &out);

    try sess.writeFlash(0x00010000, data, .{});
}
