//! Unisoc (Spreadtrum) BSL download-mode protocol — port of
//! ilyakurdyukov/spreadtrum_flash (MIT): spd_dump.c's packet encoder,
//! HDLC transcoding, the CRC16/sum checksums, and the bootrom handshake.
//!
//! Packets: raw frame = type u16 BE, length u16 BE, payload, checksum u16
//! BE (bootrom: CRC-16/XMODEM poly 0x1021; FDL2: a folded byte sum).
//! Frames are HDLC-encoded: 0x7E … payload with 0x7E→0x7D 0x5E and
//! 0x7D→0x7D 0x5D stuffing … 0x7E. The bootrom stage speaks CRC16 and
//! needs a CDC SET_CONTROL_LINE_STATE with wValue 0x601 first.
//!
//! This module covers the probe scope (CHECK_BAUD → version string,
//! CONNECT → ACK). FDL1/FDL2 upload and flash operations are the
//! roadmap's next Unisoc phase.

const std = @import("std");
const transport = @import("../../transport/transport.zig");
const log = @import("../../core/log.zig");

const Io = transport.Io;
const Error = transport.Error;
const glib = @import("glib");

pub const hdlc_header: u8 = 0x7e;
pub const hdlc_escape: u8 = 0x7d;

// Bootrom commands (spd_cmd.h).
pub const BSL_CMD_CHECK_BAUD: u16 = 0x7e;
pub const BSL_CMD_CONNECT: u16 = 0x00;
pub const BSL_REP_ACK: u16 = 0x80;
pub const BSL_REP_VER: u16 = 0x81;

pub const timeout_ms: u32 = 5000;
pub const raw_frame_max = 1024;
pub const enc_frame_max = 2 * raw_frame_max + 2;

pub const ProgressHook = struct {
    ctx: ?*anyopaque = null,
    cb: ?*const fn (ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void = null,

    pub fn report(self: ProgressHook, name: []const u8, done: u64, total: u64) void {
        if (self.cb) |cb| cb(self.ctx, name, done, total);
    }
};

/// Bootrom CRC (spd_crc16): MSB-first CRC-16/XMODEM, poly 0x1021, init 0.
pub fn crc16_xmodem(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |b| {
        crc ^= @as(u16, b) << 8;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            crc = (crc << 1) ^ (if (crc & 0x8000 != 0) @as(u16, 0x1021) else 0);
        }
    }
    return crc;
}

/// FDL2 checksum (spd_checksum with CHK_FIXZERO): 16-bit word sum, folded
/// and inverted, byte-swapped for odd lengths.
pub fn byteSum(data_in: []const u8) u16 {
    var crc: u32 = 0;
    var data = data_in;
    var len = data.len;
    while (len > 1) {
        crc += @as(u32, data[1]) << 8 | data[0];
        data = data[2..];
        len -= 2;
    }
    if (len > 0) crc += data[0];
    crc = (crc >> 16) + (crc & 0xffff);
    crc += crc >> 16;
    const inv = ~crc & 0xffff;
    if (len < 1) return @intCast(inv);
    // odd length: byteswap (CHK_FIXZERO pads conceptually to even)
    return @intCast((inv >> 8) | ((inv & 0xff) << 8));
}

fn transcode(dst: []u8, src: []const u8) usize {
    var n: usize = 0;
    for (src) |a| {
        if (a == hdlc_header or a == hdlc_escape) {
            dst[n] = hdlc_escape;
            dst[n + 1] = a ^ 0x20;
            n += 2;
        } else {
            dst[n] = a;
            n += 1;
        }
    }
    return n;
}

pub const Session = struct {
    alloc: std.mem.Allocator,
    io: *Io,
    logger: *log.Logger,
    cancel: *const std.atomic.Value(bool),

    use_crc16: bool = true, // bootrom stage; FDL2 uses the byte sum
    raw: [raw_frame_max]u8 = undefined,
    enc: [enc_frame_max]u8 = undefined,
    enc_len: usize = 0,

    pub fn deinit(self: *Session) void {
        _ = self;
    }

    fn cancelled(self: *const Session) bool {
        return self.cancel.load(.acquire);
    }

    /// CDC SET_CONTROL_LINE_STATE wValue 0x601 — required by smartphone
    /// bootroms (spd_dump.c's control transfer).
    pub fn configurePort(self: *Session) Error!void {
        _ = self.io.transport.control(0x21, 34, 0x601, 0, &{}) catch |e| {
            self.logger.debug("SPD: SET_CONTROL_LINE_STATE failed ({s}) — continuing", .{@errorName(e)});
        };
    }

    pub fn encodeMsg(self: *Session, msg_type: u16, data: []const u8) Error!void {
        if (data.len > 0xffff) return Error.Io;
        if (msg_type == BSL_CMD_CHECK_BAUD) {
            // The baud check is sent as bare 0x7E bytes (len of them).
            if (data.len > self.enc.len) return Error.Io;
            @memset(self.enc[0..data.len], hdlc_header);
            self.enc_len = data.len;
            return;
        }

        var p: usize = 0;
        std.mem.writeInt(u16, self.raw[0..2], msg_type, .big);
        std.mem.writeInt(u16, self.raw[2..4], @intCast(data.len), .big);
        @memcpy(self.raw[4 .. 4 + data.len], data);
        p = 4 + data.len;
        const chk = if (self.use_crc16) crc16_xmodem(self.raw[0..p]) else byteSum(self.raw[0..p]);
        std.mem.writeInt(u16, self.raw[p..][0..2], chk, .big);
        p += 2;

        self.enc[0] = hdlc_header;
        const n = transcode(self.enc[1 .. 1 + p * 2], self.raw[0..p]);
        self.enc[1 + n] = hdlc_header;
        self.enc_len = n + 2;
    }

    pub fn send(self: *Session) Error!void {
        if (self.enc_len == 0) return Error.Io;
        _ = try self.io.write(self.enc[0..self.enc_len], timeout_ms);
        self.enc_len = 0;
    }

    /// Read one HDLC frame, decode, and return (type, payload length).
    /// The decoded payload stays in self.raw.
    pub fn recv(self: *Session) Error!struct { type: u16, len: usize } {
        // Read until a 0x7E header byte.
        var start: u8 = 0;
        while (true) {
            if (self.cancelled()) return Error.Cancelled;
            var b: [1]u8 = undefined;
            try self.readExact(&b);
            start = b[0];
            if (start == hdlc_header) break;
        }
        // Read until the closing 0x7E.
        var got: usize = 0;
        while (true) {
            if (self.cancelled()) return Error.Cancelled;
            if (got >= self.enc.len - 1) return Error.Io;
            var b: [1]u8 = undefined;
            try self.readExact(&b);
            if (b[0] == hdlc_header and got > 0) break;
            self.enc[got] = b[0];
            got += 1;
        }
        if (got < 5) return Error.Io;

        // Decode the stuffing into self.raw.
        var n: usize = 0;
        var i: usize = 0;
        while (i < got) : (i += 1) {
            if (n >= self.raw.len) return Error.Io;
            if (self.enc[i] == hdlc_escape) {
                i += 1;
                if (i >= got) return Error.Io;
                self.raw[n] = self.enc[i] ^ 0x20;
            } else {
                self.raw[n] = self.enc[i];
            }
            n += 1;
        }
        if (n < 6) return Error.Io;
        const msg_type = std.mem.readInt(u16, self.raw[0..2], .big);
        const len = std.mem.readInt(u16, self.raw[2..4], .big);
        if (4 + @as(usize, len) + 2 > n) return Error.Io;
        const stored = std.mem.readInt(u16, self.raw[4 + len ..][0..2], .big);
        const expected = if (self.use_crc16) crc16_xmodem(self.raw[0 .. 4 + len]) else byteSum(self.raw[0 .. 4 + len]);
        if (stored != expected) {
            self.logger.err("SPD: frame checksum mismatch (type 0x{X:0>4})", .{msg_type});
            return Error.Io;
        }
        return .{ .type = msg_type, .len = len };
    }

    fn readExact(self: *Session, buf: []u8) Error!void {
        var got: usize = 0;
        while (got < buf.len) {
            if (self.cancelled()) return Error.Cancelled;
            const n = try self.io.read(buf[got..], timeout_ms);
            got += n;
        }
    }

    pub fn sendAndCheck(self: *Session, msg_type: u16, data: []const u8) Error!void {
        try self.encodeMsg(msg_type, data);
        try self.send();
        const r = try self.recv();
        if (r.type != BSL_REP_ACK) {
            self.logger.err("SPD: command 0x{X:0>4} answered 0x{X:0>4} instead of ACK", .{ msg_type, r.type });
            return Error.Io;
        }
    }

    /// Bootrom probe: baud check (responds with the version string) and
    /// CONNECT handshake. Returns the reported version string.
    pub fn probe(self: *Session, version_out: []u8) Error!usize {
        try self.encodeMsg(BSL_CMD_CHECK_BAUD, &.{1});
        try self.send();
        const ver = try self.recv();
        if (ver.type != BSL_REP_VER) {
            self.logger.err("SPD: expected BSL_REP_VER, got 0x{X:0>4}", .{ver.type});
            return Error.Io;
        }
        const n = @min(ver.len, version_out.len);
        @memcpy(version_out[0..n], self.raw[4 .. 4 + n]);
        try self.sendAndCheck(BSL_CMD_CONNECT, &.{});
        return n;
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const Harness = @import("../../transport/sim.zig").Harness;
const Step = @import("../../transport/sim.zig").Step;

test "crc16_xmodem and byteSum check out" {
    // CRC-16/XMODEM("123456789") = 0x31C3 (well-known check value).
    try testing.expectEqual(@as(u16, 0x31c3), crc16_xmodem("123456789"));
    // spd_checksum of {0x01,0x02,0x03,0x04}: words 0x0201+0x0403 = 0x0604,
    // folded, inverted, swapped for the odd... even length → ~0x0604.
    try testing.expectEqual(@as(u16, ~@as(u16, 0x0604)), byteSum(&.{ 1, 2, 3, 4 }));
}

test "bootrom probe: baud check and connect against scripted frames" {
    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);

    // CHECK_BAUD: a single bare 0x7E.
    const baud = [_]u8{0x7e};
    try steps.append(testing.allocator, .{ .expect_write = &baud });
    // Response: BSL_REP_VER, "SPRD3" — type 0x0081, len 5, crc16 BE.
    const payload = "SPRD3";
    var raw: [4 + 5 + 2]u8 = undefined;
    std.mem.writeInt(u16, raw[0..2], BSL_REP_VER, .big);
    std.mem.writeInt(u16, raw[2..4], payload.len, .big);
    @memcpy(raw[4 .. 4 + payload.len], payload);
    std.mem.writeInt(u16, raw[4 + payload.len ..][0..2], crc16_xmodem(raw[0 .. 4 + payload.len]), .big);
    // HDLC-encode (no 0x7e/0x7d in the payload, so frame = 7e + raw + 7e).
    var frame: [2 + raw.len]u8 = undefined;
    frame[0] = 0x7e;
    @memcpy(frame[1 .. 1 + raw.len], &raw);
    frame[frame.len - 1] = 0x7e;
    try steps.append(testing.allocator, .{ .respond = &frame });

    // CONNECT request: type 0x0000, len 0, crc16 — HDLC frame.
    var conn_raw: [6]u8 = undefined;
    std.mem.writeInt(u16, conn_raw[0..2], BSL_CMD_CONNECT, .big);
    std.mem.writeInt(u16, conn_raw[2..4], 0, .big);
    std.mem.writeInt(u16, conn_raw[4..6], crc16_xmodem(conn_raw[0..4]), .big);
    var conn_frame: [8]u8 = undefined;
    conn_frame[0] = 0x7e;
    @memcpy(conn_frame[1 .. 1 + conn_raw.len], &conn_raw);
    conn_frame[conn_frame.len - 1] = 0x7e;
    try steps.append(testing.allocator, .{ .expect_write = &conn_frame });
    // ACK: type 0x0080, len 0.
    var ack_raw: [6]u8 = undefined;
    std.mem.writeInt(u16, ack_raw[0..2], BSL_REP_ACK, .big);
    std.mem.writeInt(u16, ack_raw[2..4], 0, .big);
    std.mem.writeInt(u16, ack_raw[4..6], crc16_xmodem(ack_raw[0..4]), .big);
    var ack_frame: [8]u8 = undefined;
    ack_frame[0] = 0x7e;
    @memcpy(ack_frame[1 .. 1 + ack_raw.len], &ack_raw);
    ack_frame[ack_frame.len - 1] = 0x7e;
    try steps.append(testing.allocator, .{ .respond = &ack_frame });

    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };

    var h = try Harness.init(testing.allocator, steps.items);
    defer h.deinit();
    var io = Io.init(testing.allocator, h.transport());
    defer io.deinit();
    const cancel = std.atomic.Value(bool).init(false);
    var sess = Session{ .alloc = testing.allocator, .io = &io, .logger = l, .cancel = &cancel };
    defer sess.deinit();

    var ver_buf: [32]u8 = undefined;
    const n = try sess.probe(&ver_buf);
    try testing.expectEqualStrings("SPRD3", ver_buf[0..n]);
}
