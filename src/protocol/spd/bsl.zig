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
pub const BSL_CMD_START_DATA: u16 = 0x01;
pub const BSL_CMD_MIDST_DATA: u16 = 0x02;
pub const BSL_CMD_END_DATA: u16 = 0x03;
pub const BSL_CMD_EXEC_DATA: u16 = 0x04;
pub const BSL_CMD_READ_FLASH: u16 = 0x06;
pub const BSL_REP_READ_FLASH: u16 = 0x07;
pub const BSL_CMD_ERASE_FLASH: u16 = 0x0a;
pub const BSL_CMD_READ_START: u16 = 0x10;
pub const BSL_CMD_READ_MIDST: u16 = 0x11;
pub const BSL_CMD_READ_END: u16 = 0x12;
pub const BSL_REP_ACK: u16 = 0x80;
pub const BSL_REP_VER: u16 = 0x81;

pub const timeout_ms: u32 = 5000;
/// Feature phones respond to EXEC immediately; smartphones may take a
/// second — spd_dump waits 15 s for the FDL2 exec acknowledgment.
pub const exec_timeout_ms: u32 = 15_000;
pub const raw_frame_max = 1024;
pub const enc_frame_max = 2 * raw_frame_max + 2;
/// spd_dump's transfer steps: reads use 1024, writes 528.
pub const read_step: u32 = 1024;
pub const write_step: u32 = 528;

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
/// and inverted, byte-swapped for even lengths. Used when ENCODING.
pub fn byteSum(data_in: []const u8) u16 {
    return byteSumFinal(data_in, 1);
}

/// Receive-side variant: spd_dump verifies with CHK_ORIG (final=2), where
/// `len < final` holds for BOTH even (0) and odd (1) remainders — the
/// swap is unconditional after fold+invert.
pub fn byteSumVerify(data_in: []const u8) u16 {
    return byteSumFinal(data_in, 2);
}

fn byteSumFinal(data_in: []const u8, final: u32) u16 {
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
    // C's `if (len < final)`: with CHK_FIXZERO (final=1) only even totals
    // (remaining 0) swap; with CHK_ORIG (final=2) the swap is unconditional.
    if (len < final) return @intCast((inv >> 8) | ((inv & 0xff) << 8));
    return @intCast(inv);
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

pub const Frame = struct { type: u16, len: usize };

pub const Session = struct {
    alloc: std.mem.Allocator,
    io: *Io,
    logger: *log.Logger,
    cancel: *const std.atomic.Value(bool),

    use_crc16: bool = true, // bootrom stage; FDL2 uses the byte sum
    recv_timeout_ms: u32 = timeout_ms,
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
        var none: [0]u8 = .{};
        _ = self.io.transport.control(0x21, 34, 0x601, 0, &none) catch |e| {
            self.logger.debug("SPD: SET_CONTROL_LINE_STATE failed ({s}) — continuing", .{@errorName(e)});
        };
    }

    pub fn encodeMsg(self: *Session, msg_type: u16, data: []const u8) Error!void {
        // The frame must fit raw_frame_max (4 header bytes + payload + 2
        // checksum bytes), not just the u16 length field.
        if (data.len > raw_frame_max - 6) return Error.Io;
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
    pub fn recv(self: *Session) Error!Frame {
        return self.recvTimeout(self.recv_timeout_ms);
    }

    pub fn recvTimeout(self: *Session, timeout: u32) Error!Frame {
        // Read until a 0x7E header byte.
        var start: u8 = 0;
        while (true) {
            if (self.cancelled()) return Error.Cancelled;
            var b: [1]u8 = undefined;
            try self.readExactTimeout(&b, timeout);
            start = b[0];
            if (start == hdlc_header) break;
        }
        // Read until the closing 0x7E.
        var got: usize = 0;
        while (true) {
            if (self.cancelled()) return Error.Cancelled;
            if (got >= self.enc.len - 1) return Error.Io;
            var b: [1]u8 = undefined;
            try self.readExactTimeout(&b, timeout);
            // The opening delimiter is dropped, not stored (the reference
            // discards everything up to and including a header byte).
            if (b[0] == hdlc_header) break;
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
        const expected = if (self.use_crc16) crc16_xmodem(self.raw[0 .. 4 + len]) else byteSumVerify(self.raw[0 .. 4 + len]);
        if (stored != expected) {
            self.logger.err("SPD: frame checksum mismatch (type 0x{X:0>4})", .{msg_type});
            return Error.Io;
        }
        return .{ .type = msg_type, .len = len };
    }

    fn readExact(self: *Session, buf: []u8) Error!void {
        try self.readExactTimeout(buf, timeout_ms);
    }

    fn readExactTimeout(self: *Session, buf: []u8, timeout: u32) Error!void {
        var got: usize = 0;
        while (got < buf.len) {
            if (self.cancelled()) return Error.Cancelled;
            const n = try self.io.read(buf[got..], timeout);
            got += n;
        }
    }

    /// 16-bit big-endian length of the last received frame's payload.
    pub fn lastPayloadLen(self: *const Session) u16 {
        return std.mem.readInt(u16, self.raw[2..4], .big);
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
        return self.checkBaudConnect(1, version_out);
    }

    /// The FDL-stage handshake (spd_dump.c:1270-1284 bootrom with 1 bare
    /// 0x7E, 1299-1308 FDL1 with 4 bare 0x7E retried up to 10×): the
    /// loader consumes the first frame after sync as the version request
    /// and answers BSL_REP_VER regardless of type, so CHECK_BAUD must
    /// precede every real command exchange. `n_baud` bare 0x7E bytes are
    /// sent (1 bootrom, 4 FDL1), each retried up to 10× until a response.
    pub fn checkBaudConnect(self: *Session, n_baud: usize, version_out: []u8) Error!usize {
        // CHECK_BAUD encodes to n bare delimiters (encodeMsg special-case).
        var pad: [4]u8 = @splat(0);
        if (n_baud > pad.len) return Error.Io;
        try self.encodeMsg(BSL_CMD_CHECK_BAUD, pad[0..n_baud]);
        var ver_len: usize = 0;
        var got_ver = false;
        var attempt: u32 = 0;
        while (attempt < 10) : (attempt += 1) {
            if (self.cancelled()) return Error.Cancelled;
            try self.send();
            if (self.recv()) |ver| {
                if (ver.type != BSL_REP_VER) {
                    self.logger.err("SPD: expected BSL_REP_VER, got 0x{X:0>4}", .{ver.type});
                    return Error.Io;
                }
                ver_len = @min(ver.len, version_out.len);
                @memcpy(version_out[0..ver_len], self.raw[4 .. 4 + ver_len]);
                got_ver = true;
                break;
            } else |e| {
                if (e != Error.Timeout) return e;
            }
        }
        if (!got_ver) {
            self.logger.err("SPD: no BSL_REP_VER after {d} baud checks", .{attempt});
            return Error.Timeout;
        }
        try self.sendAndCheck(BSL_CMD_CONNECT, &.{});
        return ver_len;
    }

    // ------------------------------------------------------------------
    // FDL upload + flash operations (spd_dump send_buf/read_flash/...)
    // ------------------------------------------------------------------

    /// Stage switch: the bootrom speaks CRC-16, FDL2 speaks the byte sum.
    pub fn setStage(self: *Session, bootrom: bool) void {
        self.use_crc16 = bootrom;
    }

    /// UTF-16LE partition selection packet (spd_dump select_partition):
    /// name padded to 36 u16, then size (LE u32, plus high word for 64-bit
    /// mode). Selects a virtual partition for the next READ_*/DATA/ERASE
    /// command and waits for its ACK.
    /// Encode only — the selection packet for `cmd` (no I/O).
    pub fn encodePartitionSelect(self: *Session, name: []const u8, size: u64, cmd: u16) Error!void {
        var pkt = std.mem.zeroes([36 * 2 + 4 + 4 + 8]u8);
        const u16len = @min(name.len, 36);
        var i: usize = 0;
        while (i < u16len) : (i += 1) {
            const cp: u16 = @intCast(std.unicode.utf8Decode(name[i .. i + 1]) catch @as(u21, name[i]));
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &tmp, cp, .little);
            @memcpy(pkt[i * 2 ..][0..2], &tmp);
        }
        std.mem.writeInt(u32, pkt[72..76], @truncate(size), .little);
        std.mem.writeInt(u32, pkt[76..80], @intCast(size >> 32), .little);
        const pkt_len: usize = if (size >> 32 != 0) 80 else 76;
        try self.encodeMsg(cmd, pkt[0..pkt_len]);
    }

    pub fn selectPartition(self: *Session, name: []const u8, size: u64, cmd: u16) Error!void {
        try self.encodePartitionSelect(name, size, cmd);
        try self.send();
        const r = try self.recv();
        if (r.type != BSL_REP_ACK) {
            self.logger.err("SPD: partition \"{s}\" select answered 0x{X:0>4} (not ACK)", .{ name, r.type });
            return Error.Io;
        }
    }

    /// Upload one FDL: START_DATA(addr, size) → 528-byte MIDST chunks →
    /// END_DATA → EXEC_DATA. `exec_timeout` covers the FDL2 boot delay.
    pub fn fdlUpload(self: *Session, data: []const u8, addr: u32, exec_timeout: u32) Error!void {
        if (data.len > 0xffff_0000) return Error.Io;
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], addr, .big);
        std.mem.writeInt(u32, hdr[4..8], @intCast(data.len), .big);
        try self.encodeMsg(BSL_CMD_START_DATA, &hdr);
        try self.send();
        var r = try self.recv();
        if (r.type != BSL_REP_ACK) return Error.Io;

        var off: usize = 0;
        while (off < data.len) {
            if (self.cancelled()) return Error.Cancelled;
            const n = @min(data.len - off, write_step);
            try self.encodeMsg(BSL_CMD_MIDST_DATA, data[off .. off + n]);
            try self.send();
            r = try self.recv();
            if (r.type != BSL_REP_ACK) return Error.Io;
            off += n;
        }
        try self.encodeMsg(BSL_CMD_END_DATA, &.{});
        try self.send();
        r = try self.recv();
        if (r.type != BSL_REP_ACK) return Error.Io;

        try self.encodeMsg(BSL_CMD_EXEC_DATA, &.{});
        try self.send();
        self.recv_timeout_ms = exec_timeout;
        defer self.recv_timeout_ms = timeout_ms;
        r = try self.recv();
        // Feature phones ACK; some FDL2 builds answer INCOMPATIBLE_PARTITION
        // (0x96) which spd_dump tolerates. 0x8D is NOT_ENOUGH_MEMORY — a
        // real failure.
        if (r.type != BSL_REP_ACK and r.type != 0x96) {
            self.logger.err("SPD: EXEC_DATA answered 0x{X:0>4}", .{r.type});
            return Error.Io;
        }
    }

    /// Address-based flash read (spd_dump read_flash): 1024-byte chunks,
    /// each answered with BSL_REP_READ_FLASH carrying the data.
    pub fn flashRead(self: *Session, addr: u32, offset: u32, len: u32, out: []u8, progress: ProgressHook) Error!void {
        if (out.len < len) return Error.Io;
        var off: u32 = offset;
        var done: u32 = 0;
        while (done < len) {
            if (self.cancelled()) return Error.Cancelled;
            var n: u32 = len - done;
            if (n > read_step) n = read_step;
            var hdr: [12]u8 = undefined;
            std.mem.writeInt(u32, hdr[0..4], addr, .big);
            std.mem.writeInt(u32, hdr[4..8], n, .big);
            std.mem.writeInt(u32, hdr[8..12], off, .big);
            try self.encodeMsg(BSL_CMD_READ_FLASH, &hdr);
            try self.send();
            const r = try self.recv();
            if (r.type != BSL_REP_READ_FLASH) {
                self.logger.err("SPD: READ_FLASH answered 0x{X:0>4}", .{r.type});
                return Error.Io;
            }
            const nread = self.lastPayloadLen();
            if (nread > n) return Error.Io;
            @memcpy(out[done .. done + nread], self.raw[4 .. 4 + nread]);
            done += nread;
            off += nread;
            if (nread != n) break;
            progress.report("reading", done, len);
        }
        if (done != len) {
            self.logger.err("SPD: short read ({d}/{d})", .{ done, len });
            return Error.Io;
        }
    }

    /// Address-based flash write (spd_dump send_buf): START_DATA(addr,
    /// size) → 528-byte MIDST chunks → END_DATA.
    pub fn flashWrite(self: *Session, addr: u32, data: []const u8, progress: ProgressHook) Error!void {
        if (data.len > 0xffff_0000) return Error.Io;
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], addr, .big);
        std.mem.writeInt(u32, hdr[4..8], @intCast(data.len), .big);
        try self.encodeMsg(BSL_CMD_START_DATA, &hdr);
        try self.send();
        var r = try self.recv();
        if (r.type != BSL_REP_ACK) return Error.Io;
        var off: usize = 0;
        while (off < data.len) {
            if (self.cancelled()) return Error.Cancelled;
            const n = @min(data.len - off, write_step);
            try self.encodeMsg(BSL_CMD_MIDST_DATA, data[off .. off + n]);
            try self.send();
            r = try self.recv();
            if (r.type != BSL_REP_ACK) return Error.Io;
            off += n;
            progress.report("writing", off, data.len);
        }
        try self.encodeMsg(BSL_CMD_END_DATA, &.{});
        try self.send();
        r = try self.recv();
        if (r.type != BSL_REP_ACK) return Error.Io;
    }

    /// Address-based flash erase (spd_dump erase_flash).
    pub fn flashErase(self: *Session, addr: u32, size: u32) Error!void {
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], addr, .big);
        std.mem.writeInt(u32, hdr[4..8], size, .big);
        try self.encodeMsg(BSL_CMD_ERASE_FLASH, &hdr);
        try self.send();
        const r = try self.recv();
        if (r.type != BSL_REP_ACK) {
            self.logger.err("SPD: ERASE_FLASH answered 0x{X:0>4}", .{r.type});
            return Error.Io;
        }
    }

    // ------------------------------------------------------------------
    // Virtual-partition (name-addressed) operations — FDL2 only
    // ------------------------------------------------------------------

    /// Read a partition by name (spd_dump dump_partition): READ_START
    /// selects it, READ_MIDST chunks carry (LE length, LE offset lo,
    /// LE offset hi) and return BSL_REP_READ_FLASH payloads, READ_END
    /// closes the read session.
    pub fn partitionRead(self: *Session, name: []const u8, out: []u8, progress: ProgressHook) Error!void {
        try self.selectPartition(name, out.len, BSL_CMD_READ_START);
        var off: u64 = 0;
        while (off < out.len) {
            if (self.cancelled()) return Error.Cancelled;
            const n: u64 = @min(out.len - off, read_step);
            var data: [12]u8 = undefined;
            std.mem.writeInt(u32, data[0..4], @intCast(n), .little);
            std.mem.writeInt(u32, data[4..8], @truncate(off), .little);
            std.mem.writeInt(u32, data[8..12], @intCast(off >> 32), .little);
            try self.encodeMsg(BSL_CMD_READ_MIDST, data[0..]);
            try self.send();
            const r = try self.recv();
            if (r.type != BSL_REP_READ_FLASH) {
                self.logger.err("SPD: READ_MIDST answered 0x{X:0>4}", .{r.type});
                return Error.Io;
            }
            const nread = self.lastPayloadLen();
            if (nread > n) return Error.Io;
            @memcpy(out[@intCast(off)..@intCast(off + nread)], self.raw[4 .. 4 + nread]);
            off += nread;
            if (nread != n) break;
            progress.report("reading", off, out.len);
        }
        try self.encodeMsg(BSL_CMD_READ_END, &.{});
        try self.send();
        const r = try self.recv();
        if (r.type != BSL_REP_ACK) {
            self.logger.err("SPD: READ_END answered 0x{X:0>4}", .{r.type});
            return Error.Io;
        }
    }

    /// Write a partition by name (spd_dump load_partition): START_DATA
    /// selects it with the total size, MIDST_DATA streams 528-byte chunks
    /// (15 s per-chunk timeout — smartphones are slow here), END_DATA
    /// commits.
    pub fn partitionWrite(self: *Session, name: []const u8, data: []const u8, progress: ProgressHook) Error!void {
        try self.selectPartition(name, data.len, BSL_CMD_START_DATA);
        var off: usize = 0;
        while (off < data.len) {
            if (self.cancelled()) return Error.Cancelled;
            const n = @min(data.len - off, write_step);
            try self.encodeMsg(BSL_CMD_MIDST_DATA, data[off .. off + n]);
            try self.send();
            self.recv_timeout_ms = exec_timeout_ms;
            const r = self.recv() catch |e| {
                self.recv_timeout_ms = timeout_ms;
                return e;
            };
            self.recv_timeout_ms = timeout_ms;
            if (r.type != BSL_REP_ACK) {
                self.logger.err("SPD: partition MIDST answered 0x{X:0>4}", .{r.type});
                return Error.Io;
            }
            off += n;
            progress.report("writing", off, data.len);
        }
        try self.encodeMsg(BSL_CMD_END_DATA, &.{});
        try self.send();
        const r = try self.recv();
        if (r.type != BSL_REP_ACK) {
            self.logger.err("SPD: partition END_DATA answered 0x{X:0>4}", .{r.type});
            return Error.Io;
        }
    }

    /// Erase a partition by name (spd_dump erase_partition): the ERASE
    /// command itself carries the selection packet.
    pub fn partitionErase(self: *Session, name: []const u8) Error!void {
        try self.selectPartition(name, 0, BSL_CMD_ERASE_FLASH);
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
    // folded, inverted, byte-swapped (even length) → 0xfbf9.
    try testing.expectEqual(@as(u16, 0xfbf9), byteSum(&.{ 1, 2, 3, 4 }));
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

test "fdl upload and flash ops against scripted frames" {
    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };
    const cancel = std.atomic.Value(bool).init(false);

    const payload = "FDLDATA__";

    // Encode the full expected command sequence with a throwaway session,
    // then script those bytes as expectations with ACK/data responses.
    var enc = Session{ .alloc = testing.allocator, .io = undefined, .logger = l, .cancel = &cancel };
    defer enc.deinit();
    enc.use_crc16 = false;

    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);

    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 0x80000000, .big);
    std.mem.writeInt(u32, hdr[4..8], @intCast(payload.len), .big);
    var ack_raw: [6]u8 = undefined;
    std.mem.writeInt(u16, ack_raw[0..2], BSL_REP_ACK, .big);
    std.mem.writeInt(u16, ack_raw[2..4], 0, .big);
    std.mem.writeInt(u16, ack_raw[4..6], byteSumVerify(ack_raw[0..4][0..]), .big);
    var ack_frame: [8]u8 = undefined;
    ack_frame[0] = 0x7e;
    @memcpy(ack_frame[1..7], &ack_raw);
    ack_frame[7] = 0x7e;

    const seq = [_]struct { t: u16, data: []const u8 }{
        .{ .t = BSL_CMD_START_DATA, .data = &hdr },
        .{ .t = BSL_CMD_MIDST_DATA, .data = payload },
        .{ .t = BSL_CMD_END_DATA, .data = &.{} },
        .{ .t = BSL_CMD_EXEC_DATA, .data = &.{} },
    };
    var snaps: [4][]u8 = undefined;
    for (seq, 0..) |cmd, si| {
        try enc.encodeMsg(cmd.t, cmd.data);
        snaps[si] = try testing.allocator.dupe(u8, enc.enc[0..enc.enc_len]);
        try steps.append(testing.allocator, .{ .expect_write = snaps[si] });
        try steps.append(testing.allocator, .{ .respond = &ack_frame });
    }
    defer for (snaps) |sn| testing.allocator.free(sn);

    // READ_FLASH request (encoded by the caller per spd_dump framing).
    var rreq: [16]u8 = undefined;
    std.mem.writeInt(u16, rreq[0..2], BSL_CMD_READ_FLASH, .big);
    std.mem.writeInt(u16, rreq[2..4], 12, .big);
    std.mem.writeInt(u32, rreq[4..8], 0x80000000, .big);
    std.mem.writeInt(u32, rreq[8..12], @intCast(payload.len), .big);
    std.mem.writeInt(u32, rreq[12..16], 0, .big);
    var rframe: [1 + rreq.len + 2 + 1]u8 = undefined;
    rframe[0] = 0x7e;
    @memcpy(rframe[1 .. 1 + rreq.len], &rreq);
    std.mem.writeInt(u16, rframe[1 + rreq.len ..][0..2], byteSum(rreq[0..]), .big);
    rframe[rframe.len - 1] = 0x7e;
    try steps.append(testing.allocator, .{ .expect_write = &rframe });

    var data_raw: [4 + 9 + 2]u8 = undefined;
    std.mem.writeInt(u16, data_raw[0..2], BSL_REP_READ_FLASH, .big);
    std.mem.writeInt(u16, data_raw[2..4], @intCast(payload.len), .big);
    @memcpy(data_raw[4 .. 4 + payload.len], payload);
    std.mem.writeInt(u16, data_raw[4 + payload.len ..][0..2], byteSumVerify(data_raw[0 .. 4 + payload.len][0..]), .big);
    var data_frame: [2 + data_raw.len]u8 = undefined;
    data_frame[0] = 0x7e;
    @memcpy(data_frame[1 .. 1 + data_raw.len], &data_raw);
    data_frame[data_frame.len - 1] = 0x7e;
    try steps.append(testing.allocator, .{ .respond = &data_frame });

    var h = try Harness.init(testing.allocator, steps.items);
    defer h.deinit();
    var io = Io.init(testing.allocator, h.transport());
    defer io.deinit();
    var sess = Session{ .alloc = testing.allocator, .io = &io, .logger = l, .cancel = &cancel };
    defer sess.deinit();
    sess.use_crc16 = false;

    try sess.fdlUpload(payload, 0x80000000, exec_timeout_ms);
    var out: [9]u8 = undefined;
    try sess.flashRead(0x80000000, 0, @intCast(payload.len), &out, .{});
    try testing.expectEqualStrings(payload, &out);
}

test "partition read and erase by name against scripted frames" {
    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };
    const cancel = std.atomic.Value(bool).init(false);

    const pname = "wfixnv1";
    const payload = "PARTDATA!";

    // Build expectations with a throwaway session (FDL2 stage).
    var enc = Session{ .alloc = testing.allocator, .io = undefined, .logger = l, .cancel = &cancel };
    defer enc.deinit();
    enc.use_crc16 = false;

    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);

    var ack_frame: [8]u8 = undefined;
    var ack_raw: [6]u8 = undefined;
    std.mem.writeInt(u16, ack_raw[0..2], BSL_REP_ACK, .big);
    std.mem.writeInt(u16, ack_raw[2..4], 0, .big);
    std.mem.writeInt(u16, ack_raw[4..6], byteSumVerify(ack_raw[0..4][0..]), .big);
    ack_frame[0] = 0x7e;
    @memcpy(ack_frame[1..7], &ack_raw);
    ack_frame[7] = 0x7e;

    // READ_START (name selection) → ACK
    var snaps: [3][]u8 = undefined;
    try enc.encodePartitionSelect(pname, payload.len, BSL_CMD_READ_START);
    snaps[0] = try testing.allocator.dupe(u8, enc.enc[0..enc.enc_len]);
    try steps.append(testing.allocator, .{ .expect_write = snaps[0] });
    try steps.append(testing.allocator, .{ .respond = &ack_frame });

    // READ_MIDST (LE len=9, LE offset=0, hi=0) → data frame
    var midst: [12]u8 = undefined;
    std.mem.writeInt(u32, midst[0..4], payload.len, .little);
    std.mem.writeInt(u32, midst[4..8], 0, .little);
    std.mem.writeInt(u32, midst[8..12], 0, .little);
    try enc.encodeMsg(BSL_CMD_READ_MIDST, midst[0..]);
    snaps[1] = try testing.allocator.dupe(u8, enc.enc[0..enc.enc_len]);
    try steps.append(testing.allocator, .{ .expect_write = snaps[1] });
    var data_raw: [4 + 9 + 2]u8 = undefined;
    std.mem.writeInt(u16, data_raw[0..2], BSL_REP_READ_FLASH, .big);
    std.mem.writeInt(u16, data_raw[2..4], @intCast(payload.len), .big);
    @memcpy(data_raw[4 .. 4 + payload.len], payload);
    std.mem.writeInt(u16, data_raw[4 + payload.len ..][0..2], byteSumVerify(data_raw[0 .. 4 + payload.len][0..]), .big);
    var data_frame: [2 + data_raw.len]u8 = undefined;
    data_frame[0] = 0x7e;
    @memcpy(data_frame[1 .. 1 + data_raw.len], &data_raw);
    data_frame[data_frame.len - 1] = 0x7e;
    try steps.append(testing.allocator, .{ .respond = &data_frame });

    // READ_END → ACK
    try enc.encodeMsg(BSL_CMD_READ_END, &.{});
    snaps[2] = try testing.allocator.dupe(u8, enc.enc[0..enc.enc_len]);
    try steps.append(testing.allocator, .{ .expect_write = snaps[2] });
    try steps.append(testing.allocator, .{ .respond = &ack_frame });
    defer for (snaps) |sn| testing.allocator.free(sn);

    var h = try Harness.init(testing.allocator, steps.items);
    defer h.deinit();
    var io = Io.init(testing.allocator, h.transport());
    defer io.deinit();
    var sess = Session{ .alloc = testing.allocator, .io = &io, .logger = l, .cancel = &cancel };
    defer sess.deinit();
    sess.use_crc16 = false;

    var out: [payload.len]u8 = undefined;
    try sess.partitionRead(pname, &out, .{});
    try testing.expectEqualStrings(payload, &out);

    // Erase by name: ERASE_FLASH carries the selection packet. Fresh step
    // list — h consumed the read script above.
    var erase_steps = std.ArrayList(Step).empty;
    defer erase_steps.deinit(testing.allocator);
    try enc.encodePartitionSelect(pname, 0, BSL_CMD_ERASE_FLASH);
    const erase_snap = try testing.allocator.dupe(u8, enc.enc[0..enc.enc_len]);
    defer testing.allocator.free(erase_snap);
    try erase_steps.append(testing.allocator, .{ .expect_write = erase_snap });
    try erase_steps.append(testing.allocator, .{ .respond = &ack_frame });

    var h2 = try Harness.init(testing.allocator, erase_steps.items);
    defer h2.deinit();
    var io2 = Io.init(testing.allocator, h2.transport());
    defer io2.deinit();
    var sess2 = Session{ .alloc = testing.allocator, .io = &io2, .logger = l, .cancel = &cancel };
    defer sess2.deinit();
    sess2.use_crc16 = false;

    try sess2.partitionErase(pname);
}
