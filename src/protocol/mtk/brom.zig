//! MediaTek BROM (boot ROM) serial protocol — port of bkerler/mtkclient
//! (GPL-3.0): Port.py run_handshake/mtk_cmd + devicehandler line coding,
//! and mtk_preloader.py's Cmd table / chip identification.
//!
//! Sync: the host sends the four bytes A0 0A 50 05 one at a time; the BROM
//! echoes each byte bit-inverted (5F F5 AF FA). Commands are echoed too,
//! followed by a big-endian payload (e.g. GET_HW_CODE 0xFD → hwcode u16 +
//! hw_sub_code u16, GET_HW_SW_VER 0xFC → four u16).
//!
//! Before the sync, mtkclient configures the CDC VCOM (921600 8N1) and
//! raises RTS — ported through the transport's control-transfer hook.
//! DA upload / flashing is the roadmap's next phase; this module covers
//! the sync + identification scope.

const std = @import("std");
const transport = @import("../../transport/transport.zig");
const log = @import("../../core/log.zig");

const Io = transport.Io;
const Error = transport.Error;

pub const sync_cmd = [4]u8{ 0xA0, 0x0A, 0x50, 0x05 };
pub const cmd_get_hw_code: u8 = 0xFD;
pub const cmd_get_hw_sw_ver: u8 = 0xFC;
pub const cmd_get_bl_ver: u8 = 0xFE;
/// mtkclient Port.run_handshake's retry budget per connection.
pub const sync_attempts: u32 = 30;
pub const cmd_timeout_ms: u32 = 1000;

pub const ChipInfo = struct {
    hw_code: u16 = 0,
    hw_sub_code: u16 = 0,
    /// GET_HW_SW_VER's four big-endian u16 fields.
    sw_ver: [4]u16 = @splat(0),
};

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

    /// CDC setup done by the opener (needs the control-transfer hook).
    pub fn configurePort(self: *Session) Error!void {
        // SET_LINE_CODING: dwDTERate=921600, 1 stop bit, no parity, 8 bits.
        var coding: [7]u8 = undefined;
        std.mem.writeInt(u32, coding[0..4], 921600, .little);
        coding[4] = 0; // stop bits
        coding[5] = 0; // parity
        coding[6] = 8; // data bits
        _ = self.io.transport.control(0x21, 0x20, 0, 0, &coding) catch |e| {
            self.logger.debug("MTK: SET_LINE_CODING failed ({s}) — continuing", .{@errorName(e)});
        };
        // SET_CONTROL_LINE_STATE: RTS on (DTR off), like mtkclient.
        _ = self.io.transport.control(0x21, 0x22, 0x0002, 0, &{}) catch |e| {
            self.logger.debug("MTK: SET_CONTROL_LINE_STATE failed ({s}) — continuing", .{@errorName(e)});
        };
    }

    fn cancelled(self: *const Session) bool {
        return self.cancel.load(.acquire);
    }

    fn readByte(self: *Session) Error!u8 {
        var b: [1]u8 = undefined;
        try self.readExact(&b);
        return b[0];
    }

    fn readExact(self: *Session, buf: []u8) Error!void {
        var got: usize = 0;
        while (got < buf.len) {
            if (self.cancelled()) return Error.Cancelled;
            const n = try self.io.read(buf[got..], cmd_timeout_ms);
            got += n;
        }
    }

    /// Byte-by-byte inverted-echo sync (Port.run_handshake).
    pub fn sync(self: *Session) Error!void {
        var attempt: u32 = 0;
        while (attempt < sync_attempts) : (attempt += 1) {
            if (self.cancelled()) return Error.Cancelled;
            var ok = true;
            for (sync_cmd) |byte| {
                _ = self.io.write(&[1]u8{byte}, cmd_timeout_ms) catch {
                    ok = false;
                    break;
                };
                const echo = self.readByte() catch {
                    ok = false;
                    break;
                };
                if (echo != ~byte) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                self.logger.info("MTK: BROM sync established", .{});
                return;
            }
            // Drain stale bytes before retrying (the reference flushes too).
            var scratch: [64]u8 = undefined;
            _ = self.io.read(&scratch, 50) catch {};
        }
        return Error.Timeout;
    }

    /// Send a command byte and consume its echo (Port.mtk_cmd semantics).
    fn sendCmd(self: *Session, cmd: u8) Error!void {
        _ = try self.io.write(&[1]u8{cmd}, cmd_timeout_ms);
        const echo = try self.readByte();
        if (echo != cmd) {
            self.logger.err("MTK: command 0x{X:0>2} echo mismatch (0x{X:0>2})", .{ cmd, echo });
            return Error.Io;
        }
    }

    /// GET_HW_CODE (mtk_preloader get_hwcode): echo + 4 big-endian bytes.
    pub fn getHwCode(self: *Session) Error!ChipInfo {
        try self.sync();
        var info = ChipInfo{};
        try self.sendCmd(cmd_get_hw_code);
        var buf: [4]u8 = undefined;
        try self.readExact(&buf);
        info.hw_code = std.mem.readInt(u16, buf[0..2], .big);
        info.hw_sub_code = std.mem.readInt(u16, buf[2..4], .big);
        return info;
    }

    /// GET_HW_SW_VER (0xFC): echo + four big-endian u16.
    pub fn getHwSwVer(self: *Session, info: *ChipInfo) Error!void {
        try self.sendCmd(cmd_get_hw_sw_ver);
        var buf: [8]u8 = undefined;
        try self.readExact(&buf);
        inline for (0..4) |i| {
            info.sw_ver[i] = std.mem.readInt(u16, buf[i * 2 ..][0..2], .big);
        }
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const Harness = @import("../../transport/sim.zig").Harness;
const Step = @import("../../transport/sim.zig").Step;

test "brom sync, hw code and sw version against scripted echo" {
    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);

    // Sync: each byte echoed inverted. Function-scope arrays — the step
    // slices must outlive the loop body.
    const w0 = [_]u8{sync_cmd[0]};
    const r0 = [_]u8{~sync_cmd[0]};
    const w1 = [_]u8{sync_cmd[1]};
    const r1 = [_]u8{~sync_cmd[1]};
    const w2 = [_]u8{sync_cmd[2]};
    const r2 = [_]u8{~sync_cmd[2]};
    const w3 = [_]u8{sync_cmd[3]};
    const r3 = [_]u8{~sync_cmd[3]};
    try steps.append(testing.allocator, .{ .expect_write = &w0 });
    try steps.append(testing.allocator, .{ .respond = &r0 });
    try steps.append(testing.allocator, .{ .expect_write = &w1 });
    try steps.append(testing.allocator, .{ .respond = &r1 });
    try steps.append(testing.allocator, .{ .expect_write = &w2 });
    try steps.append(testing.allocator, .{ .respond = &r2 });
    try steps.append(testing.allocator, .{ .expect_write = &w3 });
    try steps.append(testing.allocator, .{ .respond = &r3 });
    // GET_HW_CODE: echo 0xFD + BE hwcode/subcode.
    const wfd = [_]u8{cmd_get_hw_code};
    const rfd = [_]u8{cmd_get_hw_code};
    try steps.append(testing.allocator, .{ .expect_write = &wfd });
    try steps.append(testing.allocator, .{ .respond = &rfd });
    const hw = [_]u8{ 0x33, 0x77, 0x00, 0x01 }; // 0x3377 / 0x0001
    try steps.append(testing.allocator, .{ .respond = &hw });
    // GET_HW_SW_VER: echo 0xFC + 8 bytes.
    const wfc = [_]u8{cmd_get_hw_sw_ver};
    const rfc = [_]u8{cmd_get_hw_sw_ver};
    try steps.append(testing.allocator, .{ .expect_write = &wfc });
    try steps.append(testing.allocator, .{ .respond = &rfc });
    const sw = [_]u8{ 0xca, 0xfe, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03 };
    try steps.append(testing.allocator, .{ .respond = &sw });

    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };

    var h = try Harness.init(testing.allocator, steps.items);
    defer h.deinit();
    var io = Io.init(testing.allocator, h.transport());
    defer io.deinit();
    const cancel = std.atomic.Value(bool).init(false);
    var sess = Session{ .alloc = testing.allocator, .io = &io, .logger = l, .cancel = &cancel };

    var info = try sess.getHwCode();
    try sess.getHwSwVer(&info);
    try testing.expectEqual(@as(u16, 0x3377), info.hw_code);
    try testing.expectEqual(@as(u16, 0x0001), info.hw_sub_code);
    try testing.expectEqual(@as(u16, 0xcafe), info.sw_ver[0]);
    try testing.expectEqual(@as(u16, 3), info.sw_ver[3]);
}
