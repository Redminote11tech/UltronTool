//! LG LAF (download mode) protocol session — port of Lekensteyn/lglaf
//! (lglaf.py + protocol.md, MIT): the request/response protocol spoken by
//! `lafd` on LG devices in download mode.
//!
//! Framing: a 32-byte header — command[4], four u32 arguments, body length
//! u32, CRC-16 (stored in a 4-byte field, computed over header+body with
//! the CRC zeroed), and a bit-wise inversion of the command — followed by
//! the optional body. Every request is answered by a response with a
//! matching command; `FAIL` responses carry the error code in arg1.
//!
//! Transfer sizing ported from partitions.py: reads and writes are chunked
//! at BLOCK_SIZE × MAX_BLOCK_SIZE = 15.5 KiB (larger reads hang `lafd`).
//! Writes refuse to touch the GPT area (first 34 sectors) — the reference
//! guards this for writes and we extend the guard to erases.
//! Shell execution (EXEC) is deliberately not implemented.

const std = @import("std");
const transport = @import("../../transport/transport.zig");
const log = @import("../../core/log.zig");

const Io = transport.Io;
const Error = transport.Error;
const glib = @import("glib");

pub const version_arg: u32 = 0x01000001;
/// partitions.py: BLOCK_SIZE × MAX_BLOCK_SIZE = 512 × ((16 KiB − 512) / 512).
pub const chunk_max: usize = 512 * ((16 * 1024 - 512) / 512);
/// write_partition refuses to write below the end of the GPT array.
pub const gpt_guard_offset: u64 = 34 * 512;
pub const timeout_ms: u32 = 10_000;

const header_len = 0x20;

pub const ProgressHook = struct {
    ctx: ?*anyopaque = null,
    cb: ?*const fn (ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void = null,

    pub fn report(self: ProgressHook, name: []const u8, done: u64, total: u64) void {
        if (self.cb) |cb| cb(self.ctx, name, done, total);
    }
};

/// CRC-16-CCITT, LSB-first (reflected poly 0x8408), init and final XOR
/// 0xFFFF — port of lglaf.py's crc16.
pub fn crc16(data: []const u8) u16 {
    var crc: u16 = 0xffff;
    for (data) |byte| {
        crc ^= byte;
        var bits: usize = 0;
        while (bits < 8) : (bits += 1) {
            crc = if (crc & 1 != 0) (crc >> 1) ^ 0x8408 else crc >> 1;
        }
    }
    return crc ^ 0xffff;
}

const Packet = struct {
    cmd: [4]u8,
    args: [4]u32,
    body: []u8,
};

pub const Session = struct {
    alloc: std.mem.Allocator,
    io: *Io,
    logger: *log.Logger,
    cancel: *const std.atomic.Value(bool),

    /// TX packet buffer (header + chunk body).
    tx: []u8 = &.{},
    /// RX buffer for header + response body.
    rx: []u8 = &.{},
    version_min: u32 = 0,

    pub fn init(self: *Session) Error!void {
        self.tx = self.alloc.alloc(u8, header_len + chunk_max) catch return Error.OutOfMemory;
        self.rx = self.alloc.alloc(u8, header_len + chunk_max) catch {
            self.alloc.free(self.tx);
            self.tx = &.{};
            return Error.OutOfMemory;
        };
    }

    pub fn deinit(self: *Session) void {
        if (self.tx.len > 0) self.alloc.free(self.tx);
        if (self.rx.len > 0) self.alloc.free(self.rx);
        self.tx = &.{};
        self.rx = &.{};
    }

    fn cancelled(self: *const Session) bool {
        return self.cancel.load(.acquire);
    }

    fn cmdWord(cmd: *const [4]u8) u32 {
        return std.mem.readInt(u32, cmd, .little);
    }

    fn sendPacket(self: *Session, cmd: *const [4]u8, args: [4]u32, body: []const u8) Error!void {
        if (body.len > chunk_max) return Error.Io;
        const pkt = self.tx[0 .. header_len + body.len];
        std.mem.writeInt(u32, pkt[0..4], cmdWord(cmd), .little);
        inline for (0..4) |i| std.mem.writeInt(u32, pkt[4 + i * 4 ..][0..4], args[i], .little);
        std.mem.writeInt(u32, pkt[0x14..][0..4], @intCast(body.len), .little);
        std.mem.writeInt(u32, pkt[0x18..][0..4], 0, .little);
        std.mem.writeInt(u32, pkt[0x1c..][0..4], cmdWord(cmd) ^ 0xffff_ffff, .little);
        @memcpy(pkt[header_len..], body);
        const crc = crc16(pkt);
        // The CRC is 16-bit but stored in a 4-byte field (lglaf packs it as
        // a DWORD) — the upper half stays zero.
        std.mem.writeInt(u16, pkt[0x18..][0..2], crc, .little);
        std.mem.writeInt(u16, pkt[0x1a..][0..2], 0, .little);
        _ = try self.io.write(pkt, timeout_ms);
    }

    fn readExact(self: *Session, buf: []u8) Error!void {
        var got: usize = 0;
        const deadline = glib.getMonotonicTime() + @as(i64, timeout_ms) * std.time.us_per_ms;
        while (got < buf.len) {
            if (self.cancelled()) return Error.Cancelled;
            if (glib.getMonotonicTime() >= deadline) return Error.Timeout;
            const n = try self.io.read(buf[got..], timeout_ms);
            got += n; // ZLPs surface as 0 and just loop
        }
    }

    /// Read one response packet: header, then body, then CRC validation.
    fn readPacket(self: *Session) Error!Packet {
        try self.readExact(self.rx[0..header_len]);
        const body_len = std.mem.readInt(u32, self.rx[0x14..][0..4], .little);
        if (body_len > chunk_max) {
            self.logger.err("LAF: response body {d} exceeds the chunk cap — cannot resync", .{body_len});
            return Error.Io;
        }
        if (body_len > 0) try self.readExact(self.rx[header_len .. header_len + body_len]);

        // Tail must be the inverted command.
        const cmd = self.rx[0..4].*;
        const tail = std.mem.readInt(u32, self.rx[0x1c..][0..4], .little);
        if (tail != cmdWord(&cmd) ^ 0xffff_ffff) {
            self.logger.err("LAF: response trailer mismatch (cmd {s})", .{&cmd});
            return Error.Io;
        }
        // CRC covers header (zeroed 4-byte CRC field) + body — lglaf
        // zeroes all four bytes of the field, not just the u16.
        const stored = std.mem.readInt(u16, self.rx[0x18..][0..2], .little);
        const crc_rx: [4]u8 = self.rx[0x18..0x1c].*;
        @memset(self.rx[0x18..0x1c], 0);
        const expected = crc16(self.rx[0 .. header_len + body_len]);
        self.rx[0x18..0x1c].* = crc_rx;
        if (expected != stored) {
            self.logger.err("LAF: response CRC mismatch (expected {x:0>4}, got {x:0>4})", .{ expected, stored });
            return Error.Io;
        }

        var args: [4]u32 = undefined;
        inline for (0..4) |i| args[i] = std.mem.readInt(u32, self.rx[4 + i * 4 ..][0..4], .little);
        if (std.mem.eql(u8, &cmd, "FAIL")) {
            self.logger.err("LAF: device refused (FAIL code 0x{X:0>8})", .{args[0]});
            return Error.Io;
        }
        return .{ .cmd = cmd, .args = args, .body = self.rx[header_len .. header_len + body_len] };
    }

    fn expectCmd(self: *Session, pkt: *const Packet, cmd: *const [4]u8) Error!void {
        if (!std.mem.eql(u8, &pkt.cmd, cmd)) {
            self.logger.err("LAF: expected {s} response, got {s}", .{ cmd, &pkt.cmd });
            return Error.Io;
        }
    }

    /// HELO exchange — lglaf re-sends until the device answers with HELO,
    /// then sends a second HELO "just to be sure".
    pub fn hello(self: *Session) Error!void {
        const args = [4]u32{ version_arg, 0, 0, 0 };
        var attempts: u32 = 0;
        while (attempts < 3) : (attempts += 1) {
            if (self.cancelled()) return Error.Cancelled;
            try self.sendPacket("HELO", args, &.{});
            const pkt = try self.readPacket();
            if (std.mem.eql(u8, &pkt.cmd, "HELO")) {
                // lglaf checks only the command word; a device answering
                // with its own (newer) protocol id must still pass.
                self.version_min = pkt.args[1];
                self.logger.info("LAF: session open (min protocol 0x{X:0>8})", .{self.version_min});
                return;
            }
            self.logger.warn("LAF: expected HELO, got {s} — retrying", .{&pkt.cmd});
        }
        return Error.Io;
    }

    /// OPEN: body is the NUL-terminated path; an empty body opens
    /// /dev/block/mmcblk0 read-write (lglaf semantics).
    pub fn openDevice(self: *Session, path: []const u8) Error!u32 {
        var body_buf: [276]u8 = undefined;
        if (path.len + 1 > body_buf.len) return Error.Io;
        @memcpy(body_buf[0..path.len], path);
        body_buf[path.len] = 0;
        try self.sendPacket("OPEN", .{ 0, 0, 0, 0 }, body_buf[0 .. path.len + 1]);
        const pkt = try self.readPacket();
        try self.expectCmd(&pkt, "OPEN");
        return pkt.args[0];
    }

    pub fn close(self: *Session, fd: u32) Error!void {
        try self.sendPacket("CLSE", .{ fd, 0, 0, 0 }, &.{});
        const pkt = try self.readPacket();
        try self.expectCmd(&pkt, "CLSE");
        if (pkt.args[0] != fd) {
            self.logger.err("LAF: CLSE fd echo mismatch", .{});
            return Error.Io;
        }
    }

    /// READ in reference-sized chunks; each response must echo the request's
    /// fd/offset/length (12-byte arg check, like laf_read's assertion).
    pub fn readAt(self: *Session, fd: u32, block_offset: u64, out: []u8, progress: ProgressHook) Error!void {
        if (block_offset > std.math.maxInt(u32)) return Error.Io;
        var done: usize = 0;
        while (done < out.len) {
            if (self.cancelled()) return Error.Cancelled;
            const want = @min(out.len - done, chunk_max);
            const blk: u32 = @intCast(block_offset + done / 512);
            if (want % 512 != 0 and done + want < out.len) return Error.Io; // keep block alignment
            try self.sendPacket("READ", .{ fd, blk, @intCast(want), 0 }, &.{});
            const pkt = try self.readPacket();
            try self.expectCmd(&pkt, "READ");
            if (pkt.args[0] != fd or pkt.args[1] != blk or pkt.args[2] != want) {
                self.logger.err("LAF: READ echo mismatch", .{});
                return Error.Io;
            }
            if (pkt.body.len != want) return Error.Io;
            @memcpy(out[done .. done + want], pkt.body);
            done += want;
            progress.report("reading", done, out.len);
        }
    }

    /// WRTE in reference-sized chunks; the response's byte offset must match
    /// (block × 512, wrapping like the device does).
    pub fn writeAt(self: *Session, fd: u32, block_offset: u64, data: []const u8, progress: ProgressHook) Error!void {
        if (block_offset * 512 < gpt_guard_offset) {
            self.logger.err("LAF: refusing to write inside the GPT area (below sector 34)", .{});
            return Error.Io;
        }
        if (block_offset > std.math.maxInt(u32)) return Error.Io;
        var done: usize = 0;
        while (done < data.len) {
            if (self.cancelled()) return Error.Cancelled;
            const want = @min(data.len - done, chunk_max);
            const blk: u32 = @intCast(block_offset + done / 512);
            try self.sendPacket("WRTE", .{ fd, blk, 0, 0 }, data[done .. done + want]);
            const pkt = try self.readPacket();
            try self.expectCmd(&pkt, "WRTE");
            if (pkt.args[0] != fd) {
                self.logger.err("LAF: WRTE fd echo mismatch", .{});
                return Error.Io;
            }
            const expected_off: u32 = @truncate((@as(u64, blk) * 512) & 0xffff_ffff);
            if (pkt.args[1] != expected_off) {
                self.logger.err("LAF: WRTE offset mismatch (got {d}, expected {d})", .{ pkt.args[1], expected_off });
                return Error.Io;
            }
            done += want;
            progress.report("writing", done, data.len);
        }
    }

    /// ERSE (TRIM). The reference notes old data reads back until reboot.
    pub fn eraseSectors(self: *Session, fd: u32, start_sector: u32, count: u32) Error!void {
        if (@as(u64, start_sector) * 512 < gpt_guard_offset) {
            self.logger.err("LAF: refusing to erase inside the GPT area (below sector 34)", .{});
            return Error.Io;
        }
        try self.sendPacket("ERSE", .{ fd, start_sector, count, 0 }, &.{});
        const pkt = try self.readPacket();
        try self.expectCmd(&pkt, "ERSE");
        if (pkt.args[0] != fd or pkt.args[1] != start_sector or pkt.args[2] != count) {
            self.logger.err("LAF: ERSE echo mismatch", .{});
            return Error.Io;
        }
    }

    /// CTRL reboot (RSET) / power off (POFF) / reboot-to-download (ONRS).
    pub fn ctrl(self: *Session, sub: *const [4]u8) Error!void {
        const sub_arg = std.mem.readInt(u32, sub, .little);
        try self.sendPacket("CTRL", .{ sub_arg, 0, 0, 0 }, &.{});
        const pkt = try self.readPacket();
        try self.expectCmd(&pkt, "CTRL");
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const Harness = @import("../../transport/sim.zig").Harness;
const Step = @import("../../transport/sim.zig").Step;

fn buildPacket(buf: []u8, cmd: *const [4]u8, args: [4]u32, body: []const u8) []u8 {
    const pkt = buf[0 .. header_len + body.len];
    std.mem.writeInt(u32, pkt[0..4], std.mem.readInt(u32, cmd, .little), .little);
    inline for (0..4) |i| std.mem.writeInt(u32, pkt[4 + i * 4 ..][0..4], args[i], .little);
    std.mem.writeInt(u32, pkt[0x14..][0..4], @intCast(body.len), .little);
    std.mem.writeInt(u32, pkt[0x18..][0..4], 0, .little);
    std.mem.writeInt(u32, pkt[0x1c..][0..4], std.mem.readInt(u32, cmd, .little) ^ 0xffff_ffff, .little);
    @memcpy(pkt[header_len..], body);
    const crc = crc16(pkt);
    std.mem.writeInt(u16, pkt[0x18..][0..2], crc, .little);
    std.mem.writeInt(u16, pkt[0x1a..][0..2], 0, .little);
    return pkt;
}

test "crc16 matches the reference vector" {
    // Independently computed with lglaf.py's crc16 for a HELO request
    // header (inverted-command tail included, CRC field zeroed).
    const helo = [_]u8{
        0x48, 0x45, 0x4c, 0x4f, 0x01, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xb7, 0xba, 0xb3, 0xb0,
    };
    try testing.expectEqual(@as(u16, 0xb15c), crc16(&helo));
}

test "hello opens the session and echoes the version" {
    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);

    var req_helo: [32]u8 = undefined;
    _ = buildPacket(&req_helo, "HELO", .{ version_arg, 0, 0, 0 }, &.{});
    try steps.append(testing.allocator, .{ .expect_write = &req_helo });
    var resp_helo: [32]u8 = undefined;
    _ = buildPacket(&resp_helo, "HELO", .{ version_arg, 0x00800000, 0, 0 }, &.{});
    try steps.append(testing.allocator, .{ .respond = &resp_helo });
    // Second HELO per the reference.
    try steps.append(testing.allocator, .{ .expect_write = &req_helo });
    try steps.append(testing.allocator, .{ .respond = &resp_helo });

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
    try sess.init();

    sess.hello() catch {
        if (h.failure) |f| std.debug.print("DBG fail: {s}\n", .{f[0..@min(f.len, 160)]});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(u32, 0x00800000), sess.version_min);
}

test "open, read, write and erase exchange against scripted responses" {
    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);

    // hello: one HELO on a clean sync (the second is only for desyncs).
    var resp: []u8 = undefined;

    var req_helo: [32]u8 = undefined;
    _ = buildPacket(&req_helo, "HELO", .{ version_arg, 0, 0, 0 }, &.{});
    var resp_helo: [32]u8 = undefined;
    _ = buildPacket(&resp_helo, "HELO", .{ version_arg, 0, 0, 0 }, &.{});
    try steps.append(testing.allocator, .{ .expect_write = &req_helo });
    try steps.append(testing.allocator, .{ .respond = &resp_helo });

    // OPEN "" → fd 7
    var open_req: [33]u8 = undefined;
    _ = buildPacket(&open_req, "OPEN", .{ 0, 0, 0, 0 }, &.{0});
    try steps.append(testing.allocator, .{ .expect_write = &open_req });
    var open_resp: [32]u8 = undefined;
    _ = buildPacket(&open_resp, "OPEN", .{ 7, 0, 0, 0 }, &.{});
    try steps.append(testing.allocator, .{ .respond = &open_resp });

    // READ fd 7, block 2, 512 bytes → 512 data bytes
    const read_size = 512;
    var read_req: [32]u8 = undefined;
    _ = buildPacket(&read_req, "READ", .{ 7, 2, read_size, 0 }, &.{});
    try steps.append(testing.allocator, .{ .expect_write = &read_req });
    var read_resp: [32 + read_size]u8 = undefined;
    const read_body = [_]u8{0xEE} ** read_size;
    resp = buildPacket(&read_resp, "READ", .{ 7, 2, read_size, 0 }, &read_body);
    try steps.append(testing.allocator, .{ .respond = resp });

    // WRTE fd 7, block 2048, 512 bytes of data
    var write_req: [32 + 512]u8 = undefined;
    const wr_body = [_]u8{0xAB} ** 512;
    _ = buildPacket(&write_req, "WRTE", .{ 7, 2048, 0, 0 }, &wr_body);
    try steps.append(testing.allocator, .{ .expect_write = &write_req });
    var write_resp: [32]u8 = undefined;
    _ = buildPacket(&write_resp, "WRTE", .{ 7, 2048 * 512, 0, 0 }, &.{});
    try steps.append(testing.allocator, .{ .respond = &write_resp });

    // ERSE fd 7, sector 4096, count 8
    var erase_req: [32]u8 = undefined;
    _ = buildPacket(&erase_req, "ERSE", .{ 7, 4096, 8, 0 }, &.{});
    try steps.append(testing.allocator, .{ .expect_write = &erase_req });
    var erase_resp: [32]u8 = undefined;
    _ = buildPacket(&erase_resp, "ERSE", .{ 7, 4096, 8, 0 }, &.{});
    try steps.append(testing.allocator, .{ .respond = &erase_resp });

    // CLSE fd 7
    var close_req: [32]u8 = undefined;
    _ = buildPacket(&close_req, "CLSE", .{ 7, 0, 0, 0 }, &.{});
    try steps.append(testing.allocator, .{ .expect_write = &close_req });
    var close_resp: [32]u8 = undefined;
    _ = buildPacket(&close_resp, "CLSE", .{ 7, 0, 0, 0 }, &.{});
    try steps.append(testing.allocator, .{ .respond = &close_resp });

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
    try sess.init();

    try sess.hello();
    const fd = try sess.openDevice("");
    try testing.expectEqual(@as(u32, 7), fd);

    var out: [read_size]u8 = undefined;
    try sess.readAt(fd, 2, &out, .{});
    try testing.expectEqual(@as(u8, 0xEE), out[0]);

    try sess.writeAt(fd, 2048, &wr_body, .{});
    try sess.eraseSectors(fd, 4096, 8);
    try sess.close(fd);
}

test "write refuses the GPT area and FAIL responses error out" {
    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);

    var req_helo: [32]u8 = undefined;
    _ = buildPacket(&req_helo, "HELO", .{ version_arg, 0, 0, 0 }, &.{});
    var resp_helo: [32]u8 = undefined;
    _ = buildPacket(&resp_helo, "HELO", .{ version_arg, 0, 0, 0 }, &.{});
    try steps.append(testing.allocator, .{ .expect_write = &req_helo });
    try steps.append(testing.allocator, .{ .respond = &resp_helo });

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
    try sess.init();
    try sess.hello();

    // Writing below sector 34 is refused before any packet is sent.
    try testing.expectError(error.Io, sess.writeAt(7, 0, &.{ 1, 2, 3 }, .{}));
    try testing.expectError(error.Io, sess.eraseSectors(7, 0, 4));
}

