//! Sahara protocol — Zig port of linux-msm/qdl src/sahara.c (BSD-3-Clause).
//!
//! The host is almost entirely passive during image transfer: the device
//! sends HELLO (host answers with version 2 / compatible 1, echoing the
//! device's requested mode), READ_DATA / READ_DATA64 requests (host serves
//! slices of the programmer image), END_OF_IMAGE (host sends DONE on status
//! 0), and DONE_RESP (status 0 = more images pending, 1 = complete).

const std = @import("std");
const transport = @import("../../transport/transport.zig");
const log = @import("../../core/log.zig");

const Io = transport.Io;
const Error = transport.Error;

// Packet commands (all little-endian; every packet starts with u32 cmd, u32 length)
pub const HELLO: u32 = 0x01;
pub const HELLO_RESP: u32 = 0x02;
pub const READ_DATA: u32 = 0x03;
pub const END_OF_IMAGE: u32 = 0x04;
pub const DONE: u32 = 0x05;
pub const DONE_RESP: u32 = 0x06;
pub const RESET: u32 = 0x07;
pub const RESET_RESP: u32 = 0x08;
pub const MEM_DEBUG: u32 = 0x09;
pub const MEM_READ: u32 = 0x0a;
pub const CMD_READY: u32 = 0x0b;
pub const SWITCH_MODE: u32 = 0x0c;
pub const EXECUTE: u32 = 0x0d;
pub const EXECUTE_RESP: u32 = 0x0e;
pub const EXECUTE_DATA: u32 = 0x0f;
pub const MEM_DEBUG64: u32 = 0x10;
pub const MEM_READ64: u32 = 0x11;
pub const READ_DATA64: u32 = 0x12;
pub const RESET_STATE: u32 = 0x13;
pub const WRITE_DATA: u32 = 0x14;

pub const VERSION: u32 = 2;
pub const SUCCESS: u32 = 0;

pub const MODE_IMAGE_TX_PENDING: u32 = 0x0;
pub const MODE_IMAGE_TX_COMPLETE: u32 = 0x1;
pub const MODE_MEMORY_DEBUG: u32 = 0x2;
pub const MODE_COMMAND: u32 = 0x3;

const HELLO_LENGTH: u32 = 0x30;
const READ_DATA_LENGTH: u32 = 0x14;
const READ_DATA64_LENGTH: u32 = 0x20;
const END_OF_IMAGE_LENGTH: u32 = 0x10;
const DONE_LENGTH: u32 = 0x08;
const DONE_RESP_LENGTH: u32 = 0x0c;
const RESET_LENGTH: u32 = 0x08;
const EXECUTE_LENGTH: u32 = 0x0c;
const SWITCH_MODE_LENGTH: u32 = 0x0c;

// Command-mode client commands, carried by EXECUTE
pub const EXEC_CMD_SERIAL_NUM_READ: u32 = 0x01;
pub const EXEC_CMD_MSM_HW_ID_READ: u32 = 0x02;
pub const EXEC_CMD_OEM_PK_HASH_READ: u32 = 0x03;
pub const EXEC_CMD_READ_CHIP_ID_V3: u32 = 0x0a;

pub const cmd_timeout_ms: u32 = 1000;

/// An image the device may request during Sahara transfer (the firehose
/// programmer, or extra images for multi-image targets).
pub const Image = struct {
    id: u32,
    name: []const u8,
    data: []const u8,
};

pub const ProgressHook = struct {
    ctx: ?*anyopaque = null,
    cb: ?*const fn (ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void = null,

    fn report(self: ProgressHook, name: []const u8, done: u64, total: u64) void {
        if (self.cb) |cb| cb(self.ctx, name, done, total);
    }
};

/// Chip identity as reported by Sahara command mode.
pub const ChipInfo = struct {
    protocol_version: u32 = 0,
    serial: ?u32 = null,
    hwid: ?u64 = null,
    msm_id: u32 = 0,
    oem_id: u16 = 0,
    model_id: u16 = 0,
    /// Hex string (leading zero bytes trimmed, per qdl).
    pkhash: struct {
        len: usize = 0,
        buf: [128]u8 = undefined,
        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    } = .{},
};

pub const Session = struct {
    io: *Io,
    logger: *log.Logger,
    images: []const Image,
    progress: ProgressHook = .{},
    cancel: ?*const std.atomic.Value(bool) = null,
    protocol_version: u32 = 0,

    fn cancelled(self: *Session) bool {
        return self.cancel != null and self.cancel.?.load(.acquire);
    }

    // ------------------------------------------------------------------
    // Packet builders (little-endian on the wire)
    // ------------------------------------------------------------------

    fn putHeader(buf: []u8, cmd: u32, length: u32) void {
        std.mem.writeInt(u32, buf[0..4], cmd, .little);
        std.mem.writeInt(u32, buf[4..8], length, .little);
    }

    pub fn sendReset(self: *Session) void {
        var buf: [8]u8 = undefined;
        putHeader(&buf, RESET, RESET_LENGTH);
        _ = self.io.write(&buf, cmd_timeout_ms) catch {};
    }

    fn sendHelloResp(self: *Session, version: u32, mode: u32) void {
        var buf: [HELLO_LENGTH]u8 = @splat(0);
        putHeader(&buf, HELLO_RESP, HELLO_LENGTH);
        std.mem.writeInt(u32, buf[8..12], version, .little);
        std.mem.writeInt(u32, buf[12..16], 1, .little); // compatible
        std.mem.writeInt(u32, buf[16..20], SUCCESS, .little); // status
        std.mem.writeInt(u32, buf[20..24], mode, .little);
        _ = self.io.write(&buf, cmd_timeout_ms) catch {};
    }

    fn sendDone(self: *Session) void {
        var buf: [8]u8 = undefined;
        putHeader(&buf, DONE, DONE_LENGTH);
        _ = self.io.write(&buf, cmd_timeout_ms) catch {};
    }

    fn sendSwitchMode(self: *Session, mode: u32) void {
        var buf: [SWITCH_MODE_LENGTH]u8 = @splat(0);
        putHeader(&buf, SWITCH_MODE, SWITCH_MODE_LENGTH);
        std.mem.writeInt(u32, buf[8..12], mode, .little);
        _ = self.io.write(&buf, cmd_timeout_ms) catch {};
    }

    // ------------------------------------------------------------------
    // Image transfer state machine (port of sahara_run)
    // ------------------------------------------------------------------

    pub const RunOpts = struct {
        /// Auto-detect a device that is already running the Firehose
        /// programmer (first read times out or greets with "<?xml").
        detect_firehose: bool = true,
    };

    pub fn run(self: *Session, opts: RunOpts) Error!void {
        var first_read = true;
        var done = false;

        while (!done) {
            if (self.cancelled()) return Error.Cancelled;
            var buf: [4096]u8 = undefined;
            const n = self.io.read(&buf, cmd_timeout_ms) catch |e| {
                if (first_read and opts.detect_firehose and e == Error.Timeout) {
                    self.logger.info("Sahara: no HELLO received; assuming Firehose programmer is already running", .{});
                    return;
                }
                return e;
            };

            if (first_read and opts.detect_firehose and n >= 5 and std.mem.eql(u8, buf[0..5], "<?xml")) {
                self.logger.info("Sahara: device is already in Firehose mode, skipping Sahara", .{});
                return;
            }
            first_read = false;

            if (n < 8) {
                self.logger.err("Sahara: short packet ({d} bytes)", .{n});
                return Error.Io;
            }
            const cmd = std.mem.readInt(u32, buf[0..4], .little);
            const length = std.mem.readInt(u32, buf[4..8], .little);
            if (@as(u32, @intCast(n)) != length) {
                self.logger.err("Sahara: request length not matching received request ({d} != {d})", .{ n, length });
                return Error.Io;
            }

            switch (cmd) {
                HELLO => try self.handleHello(&buf),
                READ_DATA => try self.handleRead(&buf, false),
                READ_DATA64 => try self.handleRead(&buf, true),
                END_OF_IMAGE => try self.handleEoi(&buf),
                DONE_RESP => {
                    if (length < DONE_RESP_LENGTH) {
                        self.logger.err("Sahara: short DONE_RESP packet", .{});
                        return Error.Io;
                    }
                    const status = std.mem.readInt(u32, buf[8..12], .little);
                    // 0 == PENDING (device expects more images), 1 == COMPLETE.
                    done = status != 0;
                    // E.g. MSM8916 EDL reports done = 0 here; with a single
                    // image whose id is 13 the device is done regardless.
                    if (self.hasDonePendingQuirk()) done = true;
                    self.logger.debug("Sahara: DONE status {d} ({s})", .{ status, if (done) "complete" else "pending" });
                },
                RESET_RESP => {
                    self.logger.debug("Sahara: device reset", .{});
                    done = true;
                },
                else => {
                    self.logger.warn("Sahara: unexpected packet cmd {x} (len {d})", .{ cmd, length });
                },
            }
        }
    }

    fn hasDonePendingQuirk(self: *Session) bool {
        return self.images.len == 1 and self.images[0].id == 13;
    }

    fn handleHello(self: *Session, buf: []const u8) Error!void {
        if (std.mem.readInt(u32, buf[4..8], .little) != HELLO_LENGTH) {
            self.logger.err("Sahara: unexpected HELLO packet length {d}", .{std.mem.readInt(u32, buf[4..8], .little)});
            self.sendReset();
            return Error.Io;
        }
        const version = std.mem.readInt(u32, buf[8..12], .little);
        const compatible = std.mem.readInt(u32, buf[12..16], .little);
        const max_len = std.mem.readInt(u32, buf[16..20], .little);
        const mode = std.mem.readInt(u32, buf[20..24], .little);
        self.logger.info("Sahara: HELLO version {x} compatible {x} max_len {d} mode {d}", .{ version, compatible, max_len, mode });
        self.protocol_version = version;
        self.sendHelloResp(VERSION, mode);
    }

    fn handleRead(self: *Session, buf: []const u8, wide: bool) Error!void {
        const expect_len: u32 = if (wide) READ_DATA64_LENGTH else READ_DATA_LENGTH;
        if (std.mem.readInt(u32, buf[4..8], .little) != expect_len) {
            if (wide) {
                self.logger.err("Sahara: unexpected READ_DATA64 packet length", .{});
            } else {
                self.logger.err("Sahara: unexpected READ_DATA packet length", .{});
            }
            self.sendReset();
            return Error.Io;
        }

        var image_id: u64 = undefined;
        var offset: u64 = undefined;
        var len: u64 = undefined;
        if (wide) {
            image_id = std.mem.readInt(u64, buf[8..16], .little);
            offset = std.mem.readInt(u64, buf[16..24], .little);
            len = std.mem.readInt(u64, buf[24..32], .little);
        } else {
            image_id = std.mem.readInt(u32, buf[8..12], .little);
            offset = std.mem.readInt(u32, buf[12..16], .little);
            len = std.mem.readInt(u32, buf[16..20], .little);
        }

        var image: ?Image = null;
        for (self.images) |img| {
            if (img.id == image_id) image = img;
        }
        const img = image orelse {
            self.logger.err("Sahara: device requested unknown image id {d}", .{image_id});
            self.sendReset();
            return Error.Io;
        };
        if (offset > img.data.len or len > img.data.len - offset) {
            self.logger.err("Sahara: device requested invalid range of image {d}", .{image_id});
            return Error.Io;
        }

        if (offset == 0) {
            self.logger.info("Sahara: sending {s} ({d} bytes)", .{ img.name, img.data.len });
        }
        self.progress.report(img.name, offset + len, img.data.len);

        const written = try self.io.write(img.data[@intCast(offset)..@intCast(offset + len)], cmd_timeout_ms);
        if (written != len) {
            self.logger.err("Sahara: failed to write {d} bytes to Sahara (wrote {d})", .{ len, written });
            return Error.Io;
        }
    }

    fn handleEoi(self: *Session, buf: []const u8) Error!void {
        if (std.mem.readInt(u32, buf[4..8], .little) != END_OF_IMAGE_LENGTH) {
            self.logger.err("Sahara: unexpected END_OF_IMAGE packet length", .{});
            self.sendReset();
            return Error.Io;
        }
        const image_id = std.mem.readInt(u32, buf[8..12], .little);
        const status = std.mem.readInt(u32, buf[12..16], .little);
        self.logger.debug("Sahara: END OF IMAGE image {d} status {d}", .{ image_id, status });
        if (status != 0) {
            self.logger.err("Sahara: received non-successful end-of-image result", .{});
            return Error.Io;
        }
        self.sendDone();
    }

    /// Port of sahara_chipinfo: answer the HELLO requesting COMMAND mode,
    /// wait for CMD_READY, read the chip identity, then switch back to
    /// image-transfer mode so the device re-issues its HELLO and stays
    /// usable for a subsequent flash without a reset.
    pub fn chipInfoSession(self: *Session) Error!ChipInfo {
        var buf: [4096]u8 = undefined;

        const n = try self.io.read(&buf, cmd_timeout_ms);
        if (n >= 5 and std.mem.eql(u8, buf[0..5], "<?xml")) {
            self.logger.err("device is already in Firehose mode; chip info is only available via Sahara", .{});
            return Error.Io;
        }
        if (n < 8) {
            self.logger.err("failed to read Sahara HELLO from device", .{});
            return Error.Timeout;
        }
        const cmd = std.mem.readInt(u32, buf[0..4], .little);
        const length = std.mem.readInt(u32, buf[4..8], .little);
        if (@as(u32, @intCast(n)) != length or cmd != HELLO) {
            self.logger.err("unexpected Sahara packet 0x{x} while waiting for HELLO", .{cmd});
            return Error.Io;
        }

        if (n < 0x24) {
            self.logger.err("Sahara: short HELLO packet ({d} bytes)", .{n});
            return Error.Io;
        }
        const version = std.mem.readInt(u32, buf[8..12], .little);
        const mode = std.mem.readInt(u32, buf[20..24], .little);
        self.logger.debug("Sahara HELLO version {d} mode {d}", .{ version, mode });
        self.protocol_version = version;
        self.sendHelloResp(version, MODE_COMMAND);

        errdefer self.sendSwitchMode(MODE_IMAGE_TX_PENDING);

        const n2 = self.io.read(&buf, cmd_timeout_ms) catch {
            self.logger.err("no Sahara CMD_READY received; device may not support command mode", .{});
            return Error.Timeout;
        };
        if (n2 < 8) return Error.Io;
        const cmd2 = std.mem.readInt(u32, buf[0..4], .little);
        if (cmd2 == END_OF_IMAGE) {
            self.logger.err("device rejected command mode (end-of-image status {d})", .{std.mem.readInt(u32, buf[12..16], .little)});
            return Error.Io;
        }
        if (cmd2 != CMD_READY) {
            self.logger.err("unexpected Sahara packet 0x{x} while entering command mode", .{cmd2});
            return Error.Io;
        }

        const info = try self.commandInfo();
        self.sendSwitchMode(MODE_IMAGE_TX_PENDING);
        return info;
    }

    // ------------------------------------------------------------------
    // Command mode (port of sahara_command_exec / sahara_command_info)
    // ------------------------------------------------------------------

    fn readPayload(self: *Session, buf: []u8) Error!usize {
        var off: usize = 0;
        while (off < buf.len) {
            if (self.cancelled()) return Error.Cancelled;
            const n = try self.io.read(buf[off..], cmd_timeout_ms);
            if (n == 0) break;
            off += n;
        }
        return off;
    }

    /// Run one command-mode client command; returns the payload length.
    pub fn exec(self: *Session, client_cmd: u32, out: []u8) Error!usize {
        var req: [EXECUTE_LENGTH]u8 = @splat(0);
        putHeader(&req, EXECUTE, EXECUTE_LENGTH);
        std.mem.writeInt(u32, req[8..12], client_cmd, .little);
        _ = try self.io.write(&req, cmd_timeout_ms);

        var rx: [64]u8 = undefined;
        const n = try self.io.read(&rx, cmd_timeout_ms);
        if (n < 16 or std.mem.readInt(u32, rx[0..4], .little) != EXECUTE_RESP) {
            self.logger.debug("Sahara: unexpected reply to exec cmd {x}", .{client_cmd});
            return Error.Io;
        }
        const data_len = std.mem.readInt(u32, rx[12..16], .little);
        if (data_len == 0 or data_len > out.len) {
            self.logger.debug("Sahara: exec cmd {x} reported invalid length {d}", .{ client_cmd, data_len });
            return Error.Io;
        }

        putHeader(&req, EXECUTE_DATA, EXECUTE_LENGTH);
        std.mem.writeInt(u32, req[8..12], client_cmd, .little);
        _ = try self.io.write(&req, cmd_timeout_ms);

        const got = try self.readPayload(out[0..data_len]);
        if (got < data_len) return Error.Timeout;
        return data_len;
    }

    /// Query chip identity over command mode (pre-v3 via MSM_HW_ID_READ,
    /// v3+ via READ_CHIP_ID_V3). Requires being in command mode, i.e. the
    /// device's HELLO must have requested MODE_COMMAND.
    pub fn commandInfo(self: *Session) Error!ChipInfo {
        var info = ChipInfo{ .protocol_version = self.protocol_version };
        var payload: [512]u8 = undefined;

        if (self.exec(EXEC_CMD_SERIAL_NUM_READ, &payload) catch 0 >= 4) {
            info.serial = std.mem.readInt(u32, payload[0..4], .little);
        }

        const version = self.protocol_version;
        if (version < 3) {
            const n = self.exec(EXEC_CMD_MSM_HW_ID_READ, &payload) catch 0;
            if (n >= 8) {
                const hwid = std.mem.readInt(u64, payload[0..8], .little);
                info.hwid = hwid;
                info.msm_id = @intCast(hwid >> 32);
                info.oem_id = @intCast((hwid >> 16) & 0xffff);
                info.model_id = @intCast(hwid & 0xffff);
            }
        } else {
            const n = self.exec(EXEC_CMD_READ_CHIP_ID_V3, &payload) catch 0;
            if (n >= 44) {
                info.msm_id = std.mem.readInt(u32, payload[36..40], .little);
                info.oem_id = std.mem.readInt(u16, payload[40..42], .little);
                info.model_id = std.mem.readInt(u16, payload[42..44], .little);
                if (info.oem_id == 0 and n >= 46) {
                    info.oem_id = std.mem.readInt(u16, payload[44..46], .little);
                }
                info.hwid = (@as(u64, info.msm_id) << 32) | (@as(u64, info.oem_id) << 16) | info.model_id;
            }
        }

        const n = self.exec(EXEC_CMD_OEM_PK_HASH_READ, &payload) catch 0;
        if (n > 0) {
            const trimmed = pkhashTrim(payload[0..n]);
            const hex = std.fmt.bufPrint(&info.pkhash.buf, "{x}", .{trimmed}) catch "";
            info.pkhash.len = hex.len;
        }

        return info;
    }
};

/// Port of qdl's sahara_pkhash_trim: collapse repeated prefix, strip trailing
/// zero bytes, then snap to a known digest size (32/48/64).
fn pkhashTrim(buf_in: []const u8) []const u8 {
    var len = buf_in.len;
    const orig_len = len;
    const buf = buf_in;

    var i: usize = 4;
    while (i * 2 <= len) : (i += 1) {
        if (std.mem.eql(u8, buf[0..i], buf[i .. i * 2])) {
            len = i;
            break;
        }
    }
    while (len > 0 and buf[len - 1] == 0) len -= 1;

    const digest_sizes = [_]usize{ 32, 48, 64 };
    for (digest_sizes) |ds| {
        if (len <= ds and ds <= orig_len) {
            len = ds;
            break;
        }
    }
    return buf[0..len];
}

test "hello response wire format" {
    var logger = log.Logger{ .mirror_stderr = false };
    const H = @import("../../transport/sim.zig").Harness;
    var h = try H.init(std.testing.allocator, &.{});
    defer h.deinit();
    var io = transport.Io.init(std.testing.allocator, h.transport());
    defer io.deinit();

    var sess = Session{ .io = &io, .logger = &logger, .images = &.{} };
    sess.sendHelloResp(VERSION, 0x3);

    const expected = [_]u8{
        0x02, 0x00, 0x00, 0x00, // HELLO_RESP
        0x30, 0x00, 0x00, 0x00, // length 0x30
        0x02, 0x00, 0x00, 0x00, // version 2
        0x01, 0x00, 0x00, 0x00, // compatible 1
        0x00, 0x00, 0x00, 0x00, // status success
        0x03, 0x00, 0x00, 0x00, // mode echoed
    } ++ [_]u8{0} ** 24;
    try std.testing.expectEqualSlices(u8, &expected, h.written.items);
}

test "run: full transfer with dynamic hello response check" {
    const H = @import("../../transport/sim.zig").Harness;
    const image = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0x01, 0x02, 0x03 };
    const images = [_]Image{.{ .id = 13, .name = "prog.elf", .data = &image }};

    var hello: [0x30]u8 = @splat(0);
    std.mem.writeInt(u32, hello[0..4], HELLO, .little);
    std.mem.writeInt(u32, hello[4..8], 0x30, .little);
    std.mem.writeInt(u32, hello[8..12], 2, .little);
    std.mem.writeInt(u32, hello[12..16], 1, .little);
    std.mem.writeInt(u32, hello[16..20], 4096, .little);
    std.mem.writeInt(u32, hello[20..24], MODE_IMAGE_TX_PENDING, .little);

    var read_pkt: [0x14]u8 = @splat(0);
    std.mem.writeInt(u32, read_pkt[0..4], READ_DATA, .little);
    std.mem.writeInt(u32, read_pkt[4..8], 0x14, .little);
    std.mem.writeInt(u32, read_pkt[8..12], 13, .little);
    std.mem.writeInt(u32, read_pkt[12..16], 0, .little);
    std.mem.writeInt(u32, read_pkt[16..20], 8, .little);

    var eoi: [0x10]u8 = @splat(0);
    std.mem.writeInt(u32, eoi[0..4], END_OF_IMAGE, .little);
    std.mem.writeInt(u32, eoi[4..8], 0x10, .little);
    std.mem.writeInt(u32, eoi[8..12], 13, .little);

    var done: [0x0c]u8 = @splat(0);
    std.mem.writeInt(u32, done[0..4], DONE_RESP, .little);
    std.mem.writeInt(u32, done[4..8], 0x0c, .little);
    std.mem.writeInt(u32, done[8..12], 1, .little);

    var h = try H.init(std.testing.allocator, &.{
        .{ .respond = &hello },
        .{ .expect_write_len = 0x30 }, // hello response
        .{ .respond = &read_pkt },
        .{ .expect_write = &image }, // image slice
        .{ .respond = &eoi },
        .{ .expect_write_len = 8 }, // DONE
        .{ .respond = &done },
    });
    defer h.deinit();

    var logger = log.Logger{ .mirror_stderr = false };
    var io = transport.Io.init(std.testing.allocator, h.transport());
    defer io.deinit();

    var sess = Session{ .io = &io, .logger = &logger, .images = &images };
    try sess.run(.{ .detect_firehose = false });

    // HELLO_RESP echoes the device's requested mode.
    const resp = h.written.items[0..0x30];
    try std.testing.expectEqual(@as(u32, HELLO_RESP), std.mem.readInt(u32, resp[0..4], .little));
    try std.testing.expectEqual(@as(u32, MODE_IMAGE_TX_PENDING), std.mem.readInt(u32, resp[20..24], .little));
    // Second write is the image slice, third is DONE.
    try std.testing.expectEqualSlices(u8, &image, h.written.items[0x30 .. 0x30 + 8]);
    try std.testing.expectEqual(@as(u32, DONE), std.mem.readInt(u32, h.written.items[0x38 .. 0x38 + 4], .little));
}

test "pkhashTrim snaps to digest sizes" {
    var buf: [80]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(0xA0 + i);
    // Exactly 32 distinct bytes → digest size 32.
    try std.testing.expectEqual(@as(usize, 32), pkhashTrim(buf[0..32]).len);
    // Shorter than the smallest digest: no snapping possible.
    try std.testing.expectEqual(@as(usize, 20), pkhashTrim(buf[0..20]).len);
    // Exactly 48 distinct bytes → 48.
    try std.testing.expectEqual(@as(usize, 48), pkhashTrim(buf[0..48]).len);
    // No snap when longer than every digest.
    try std.testing.expectEqual(@as(usize, 64), pkhashTrim(buf[0..64]).len);

    // 32 distinct bytes + trailing zeros → collapsed to 32.
    var zbuf: [80]u8 = @splat(0);
    for (0..32) |i| zbuf[i] = @truncate(0xA0 + i);
    try std.testing.expectEqual(@as(usize, 32), pkhashTrim(zbuf[0..40]).len);
}
