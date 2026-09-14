//! Samsung Odin ("Thor") download-mode protocol session — port of
//! TheAirBlow.Thor.Library Protocols/Odin.cs (MIT), cross-checked against
//! odin4's src/protocol/thor_protocol.h (github.com/Llucs/odin4).
//!
//! Framing: requests are 1024-byte zero-padded boxes — region word, param
//! word, then integer arguments — written as one bulk transfer. Responses
//! are 8 bytes: [id u32][ack u32]. A response id of 0xFFFFFFFF marks a
//! bootloader failure with the error code in `ack` (Thor's OdinFailCheck);
//! odin4 additionally rejects a wrong region id, which we port too. The
//! session opens with the ASCII handshake "ODIN" → "LOKE".
//!
//! Regions: 0x64 init/session, 0x65 PIT, 0x66 file transfer, 0x67 close.
//! RQT_INIT_TARGET's ack packs [unknown1 u8][unknown2 u8][protocol i16]:
//! protocol 0/1 flash in 128 KiB parts with fixed 240-part sequences; v2+
//! flash in 1 MiB parts announced via RQT_INIT_PACKETSIZE with 30-part
//! sequences and a longer end-sequence timeout. The v2+ compressed-download
//! capability (ack bit 15) is a reference-documented delta — uncompressed
//! transfer only, like both references' default path.
//!
//! Unlike Firehose, Loke does not expect host-side ZLPs — callers must
//! disable the transport's write ZLP (transport.Transport.setWriteZlp).

const std = @import("std");
const transport = @import("../../transport/transport.zig");
const log = @import("../../core/log.zig");
const fileio = @import("../../core/fileio.zig");
const pit_mod = @import("pit.zig");

const Io = transport.Io;
const Error = transport.Error;

const glib = @import("glib");

// Region ids (odin4 OdinCommandType).
pub const RQT_INIT: u32 = 0x64;
pub const RQT_PIT: u32 = 0x65;
pub const RQT_XMIT: u32 = 0x66;
pub const RQT_CLOSE: u32 = 0x67;

// RQT_INIT params.
pub const RQT_INIT_TARGET: u32 = 0; // begin session / protocol negotiation
pub const RQT_INIT_RESETTIME: u32 = 1; // reset the flash counter
pub const RQT_INIT_TOTALSIZE: u32 = 2; // total bytes of the whole job
pub const RQT_INIT_PACKETSIZE: u32 = 5; // file part size (protocol v2+)

// RQT_PIT params.
pub const RQT_PIT_SET: u32 = 0; // flash a PIT (not exposed in the GUI yet)
pub const RQT_PIT_GET: u32 = 1; // request a PIT dump
pub const RQT_PIT_START: u32 = 2; // dump one 500-byte block / begin PIT flash
pub const RQT_PIT_COMPLETE: u32 = 3;

// RQT_XMIT params (uncompressed).
pub const RQT_XMIT_DOWNLOAD: u32 = 0; // request a file flash
pub const RQT_XMIT_START: u32 = 2; // request one sequence
pub const RQT_XMIT_COMPLETE: u32 = 3; // end sequence (device starts writing)

// RQT_CLOSE params.
pub const RQT_CLOSE_END: u32 = 0;
pub const RQT_CLOSE_REBOOT: u32 = 1;
pub const RQT_CLOSE_DISCONNECT: u32 = 2; // reboot back into download mode
pub const RQT_CLOSE_REBOOT_RECOVERY: u32 = 3; // power off

/// Sent instead of a response id when the bootloader refuses an operation
/// (Thor's OdinFailCheck: response byte 0 == 0xFF).
const BOOTLOADER_FAIL: u32 = 0xFFFF_FFFF;

pub const handshake_timeout_ms: u32 = 5000;
pub const default_timeout_ms: u32 = 5000;
pub const pit_flash_timeout_ms: u32 = 120_000;
pub const erase_user_data_timeout_ms: u32 = 600_000;
/// Upper bound for a PIT dump (largest real PIT is well under 1 MiB).
pub const max_pit_dump_size: usize = 16 * 1024 * 1024;

pub const ProgressHook = struct {
    ctx: ?*anyopaque = null,
    cb: ?*const fn (ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void = null,

    pub fn report(self: ProgressHook, name: []const u8, done: u64, total: u64) void {
        if (self.cb) |cb| cb(self.ctx, name, done, total);
    }
};

fn monoNow() i64 {
    return glib.getMonotonicTime();
}

/// Protocol/flash parameters reported by the bootloader at BeginSession
/// (Thor's VersionStruct).
pub const Version = struct {
    unknown1: u8 = 0,
    unknown2: u8 = 0,
    protocol: u16 = 0,
};

const Response = struct {
    id: u32,
    ack: u32,
};

pub const Session = struct {
    alloc: std.mem.Allocator,
    io: *Io,
    logger: *log.Logger,
    cancel: *const std.atomic.Value(bool),

    protocol_version: u16 = 0,
    flash_packet_size: usize = 131072,
    flash_sequence_parts: usize = 240,
    flash_timeout_ms: u32 = 30_000,
    /// Odin resets the download-mode flash counter after every flash job
    /// (Thor's ResetFlashCount default).
    reset_flash_count: bool = true,
    /// End-sequence flags Thor supports; the GUI does not expose them yet.
    efs_clear: bool = false,
    bootloader_update: bool = false,

    fn cancelled(self: *const Session) bool {
        return self.cancel.load(.acquire);
    }

    /// ASCII handshake: host sends "ODIN", Loke answers "LOKE".
    pub fn handshake(self: *Session) Error!void {
        _ = try self.io.write("ODIN", handshake_timeout_ms);
        var buf: [4]u8 = undefined;
        try self.readExact(&buf, handshake_timeout_ms);
        if (!std.mem.eql(u8, &buf, "LOKE")) {
            self.logger.err("Odin handshake failed: expected LOKE, got {x}", .{buf[0..4]});
            return Error.Io;
        }
        self.logger.debug("Odin: Loke handshake complete", .{});
    }

    /// Read exactly buf.len bytes, accumulating partial transfers (bounded
    /// by the timeout; a zero-length packet is skipped, which also consumes
    /// any ZLP the device emits between phases).
    fn readExact(self: *Session, buf: []u8, timeout_ms: u32) Error!void {
        var got: usize = 0;
        const deadline = monoNow() + @as(i64, timeout_ms) * std.time.us_per_ms;
        while (got < buf.len) {
            if (self.cancelled()) return Error.Cancelled;
            const left_ms = @min(timeout_ms, @as(u32, @intCast(@max(0, @divFloor(deadline - monoNow(), std.time.us_per_ms)))));
            if (monoNow() >= deadline) return Error.Timeout;
            const n = try self.io.read(buf[got..], @max(1, left_ms));
            got += n; // a ZLP surfaces as n == 0 and just loops
        }
    }

    fn sendRequest(self: *Session, region: u32, param: u32, ints: []const u32) Error!void {
        var buf: [1024]u8 = @splat(0);
        std.mem.writeInt(u32, buf[0..4], region, .little);
        std.mem.writeInt(u32, buf[4..8], param, .little);
        // odin4's OdinRequestBox carries 9 int slots after the two words.
        const n = @min(ints.len, 9);
        for (ints[0..n], 0..) |v, i| {
            std.mem.writeInt(u32, buf[8 + i * 4 ..][0..4], v, .little);
        }
        _ = try self.io.write(&buf, default_timeout_ms);
    }

    /// Read an 8-byte response, fail on the bootloader-fail sentinel or a
    /// wrong region id (odin4's is_valid_response semantics).
    fn response(self: *Session, expected: u32, timeout_ms: u32) Error!Response {
        var buf: [8]u8 = undefined;
        try self.readExact(&buf, timeout_ms);
        const r = Response{
            .id = std.mem.readInt(u32, buf[0..4], .little),
            .ack = std.mem.readInt(u32, buf[4..8], .little),
        };
        if (r.id == BOOTLOADER_FAIL) {
            self.logFail(r.ack, "request");
            return Error.Io;
        }
        if (r.id != expected) {
            self.logger.err("Odin: response id 0x{X} does not match expected 0x{X}", .{ r.id, expected });
            return Error.Io;
        }
        return r;
    }

    /// Human-readable meaning for the bootloader's failure codes — port of
    /// Thor's EndSequenceFlash error table.
    fn logFail(self: *Session, code: u32, where: []const u8) void {
        const meaning: []const u8 = switch (@as(i32, @bitCast(code))) {
            -2 => "write-protected partition",
            -3 => "erase error",
            -4 => "write error",
            -5 => "auth error",
            -6 => "size error",
            -7 => "ext4 error",
            else => "unknown error",
        };
        self.logger.err("Odin: {s} failed on the device (code {d}: {s})", .{ where, code, meaning });
    }

    /// BeginSession: negotiate the protocol and flash-part parameters.
    pub fn beginSession(self: *Session) Error!Version {
        // The maximum protocol version as a catch-all: the bootloader answers
        // with the highest IT supports (Thor's approach).
        try self.sendRequest(RQT_INIT, RQT_INIT_TARGET, &.{0x7FFF_FFFF});
        const r = try self.response(RQT_INIT, default_timeout_ms);
        const v = Version{
            .unknown1 = @truncate(r.ack & 0xFF),
            .unknown2 = @truncate((r.ack >> 8) & 0xFF),
            .protocol = @truncate((r.ack >> 16) & 0xFFFF),
        };
        self.protocol_version = v.protocol;
        self.logger.info("Odin: session open, bootloader protocol v{d}", .{v.protocol});

        switch (v.protocol) {
            0, 1 => {
                self.flash_packet_size = 131072; // 128 KiB
                self.flash_sequence_parts = 240; // 30 MB sequences
                self.flash_timeout_ms = 30_000;
            },
            else => {
                self.flash_packet_size = 1048576; // 1 MiB
                self.flash_sequence_parts = 30; // 30 MiB sequences
                self.flash_timeout_ms = 120_000;
                // Announce the part size we will stream (Thor's
                // SendFilePartSize — only understood by v2+ bootloaders).
                try self.sendRequest(RQT_INIT, RQT_INIT_PACKETSIZE, &.{@intCast(self.flash_packet_size)});
                _ = try self.response(RQT_INIT, default_timeout_ms);
            },
        }
        return v;
    }

    /// Tell the bootloader the total byte count of this job (Thor's
    /// SetTotalBytes — called before every flash/erase operation).
    pub fn setTotalBytes(self: *Session, total: u64) Error!void {
        var buf: [1024]u8 = @splat(0);
        std.mem.writeInt(u32, buf[0..4], RQT_INIT, .little);
        std.mem.writeInt(u32, buf[4..8], RQT_INIT_TOTALSIZE, .little);
        std.mem.writeInt(u64, buf[8..16], total, .little);
        _ = try self.io.write(&buf, default_timeout_ms);
        _ = try self.response(RQT_INIT, default_timeout_ms);
    }

    /// Reset the download-mode flash counter (odin's "flash count" — port of
    /// RQT_INIT_RESETTIME).
    pub fn resetFlashCount(self: *Session) Error!void {
        try self.sendRequest(RQT_INIT, RQT_INIT_RESETTIME, &.{});
        _ = try self.response(RQT_INIT, default_timeout_ms);
    }

    /// Erase the userdata partition (Odin's factory reset). Slow: the device
    /// formats the partition before answering (10-minute timeout, as Thor).
    pub fn eraseUserData(self: *Session) Error!void {
        try self.sendRequest(RQT_INIT, 7, &.{});
        _ = try self.response(RQT_INIT, erase_user_data_timeout_ms);
    }

    fn closeRequest(self: *Session, param: u32) Error!void {
        try self.sendRequest(RQT_CLOSE, param, &.{});
        _ = try self.response(RQT_CLOSE, default_timeout_ms);
    }

    pub fn endSession(self: *Session) Error!void {
        try self.closeRequest(RQT_CLOSE_END);
    }

    /// Reboot the device (leaves download mode).
    pub fn reboot(self: *Session) Error!void {
        try self.closeRequest(RQT_CLOSE_REBOOT);
    }

    /// Reboot straight back into download mode.
    pub fn rebootToDownloadMode(self: *Session) Error!void {
        try self.closeRequest(RQT_CLOSE_DISCONNECT);
    }

    /// Power the device off.
    pub fn shutdown(self: *Session) Error!void {
        try self.closeRequest(RQT_CLOSE_REBOOT_RECOVERY);
    }

    /// Dump the PIT (Thor's DumpPIT): size announcement, then 500-byte
    /// blocks fetched one by one, then the completion handshake.
    pub fn dumpPit(self: *Session, alloc: std.mem.Allocator) Error![]u8 {
        try self.sendRequest(RQT_PIT, RQT_PIT_GET, &.{});
        const head = try self.response(RQT_PIT, default_timeout_ms);
        const size: usize = @intCast(head.ack);
        if (size == 0 or size > max_pit_dump_size) {
            self.logger.err("Odin: PIT dump size {d} is out of range", .{size});
            return Error.Io;
        }
        self.logger.info("Odin: dumping PIT ({d} bytes)", .{size});

        const pit = alloc.alloc(u8, size) catch return Error.OutOfMemory;
        errdefer alloc.free(pit);

        var chunk: [500]u8 = undefined;
        var off: usize = 0;
        while (off < size) {
            if (self.cancelled()) return Error.Cancelled;
            const block: u32 = @intCast(off / 500);
            const want = @min(chunk.len, size - off);
            try self.sendRequest(RQT_PIT, RQT_PIT_START, &.{block});
            try self.readExact(chunk[0..want], default_timeout_ms);
            @memcpy(pit[off .. off + want], chunk[0..want]);
            off += want;
        }

        try self.sendRequest(RQT_PIT, RQT_PIT_COMPLETE, &.{});
        _ = try self.response(RQT_PIT, default_timeout_ms);
        return pit;
    }

    /// Port of FlashPartition: stream `length` bytes (from `file`, or zeros
    /// when null — Thor's erase trick) at the partition described by `entry`,
    /// in sequences of packet-size × sequence-parts. The device writes
    /// nothing until the end-sequence packet of each sequence.
    pub fn flashPartition(
        self: *Session,
        file: ?*fileio.File,
        entry: pit_mod.Entry,
        length: u64,
        progress: ProgressHook,
    ) Error!void {
        progress.report("sending", 0, length);
        try self.sendRequest(RQT_XMIT, RQT_XMIT_DOWNLOAD, &.{});
        _ = try self.response(RQT_XMIT, default_timeout_ms);

        const sequence: u64 = @as(u64, self.flash_packet_size) * self.flash_sequence_parts;
        var sequences: u64 = length / sequence;
        var last_sequence: u64 = length % sequence;
        if (last_sequence != 0) {
            sequences += 1;
        } else {
            last_sequence = sequence;
        }

        var done: u64 = 0;
        const part: []u8 = self.alloc.alloc(u8, self.flash_packet_size) catch return Error.OutOfMemory;
        defer self.alloc.free(part);

        var i: u64 = 0;
        while (i < sequences) : (i += 1) {
            if (self.cancelled()) return Error.Cancelled;
            const last = i + 1 == sequences;
            const real: u64 = if (last) last_sequence else sequence;
            var aligned: u64 = real;
            if (real % self.flash_packet_size != 0)
                aligned += self.flash_packet_size - real % self.flash_packet_size;

            try self.sendRequest(RQT_XMIT, RQT_XMIT_START, &.{@intCast(aligned)});
            _ = try self.response(RQT_XMIT, default_timeout_ms);

            const parts: u64 = aligned / self.flash_packet_size;
            var j: u64 = 0;
            while (j < parts) : (j += 1) {
                if (self.cancelled()) return Error.Cancelled;
                @memset(part, 0);
                if (file) |f| {
                    const n = f.readAll(part) catch |e| {
                        self.logger.err("Odin: failed reading the image file: {s}", .{@errorName(e)});
                        return Error.Io;
                    };
                    done += n;
                } else {
                    done = @min(done + self.flash_packet_size, length);
                }
                _ = try self.io.write(part, default_timeout_ms);
                const r = try self.response(RQT_XMIT, default_timeout_ms);
                if (r.ack != j) {
                    self.logger.err("Odin: expected part index {d}, bootloader sent {d}", .{ j, r.ack });
                    return Error.Io;
                }
                progress.report("sending", @min(done, length), length);
            }

            progress.report("flashing", @min(done, length), length);
            try self.endSequence(entry, real, last);
        }

        if (self.reset_flash_count) try self.resetFlashCount();
    }

    /// EndSequenceFlash: tells the device to write the buffered sequence.
    /// Modem partitions (binary_type 1) use the shorter packet without the
    /// partition id (Thor's FlashPartition tail). Device refusals map to the
    /// typed transport errors (session stays alive, like Firehose refusals).
    fn endSequence(self: *Session, entry: pit_mod.Entry, real: u64, last: bool) Error!void {
        if (entry.binary_type == 1) {
            try self.sendRequest(RQT_XMIT, RQT_XMIT_COMPLETE, &.{
                1,
                @intCast(real),
                entry.binary_type,
                entry.device_type,
                @intFromBool(last),
            });
        } else {
            try self.sendRequest(RQT_XMIT, RQT_XMIT_COMPLETE, &.{
                0,
                @intCast(real),
                entry.binary_type,
                entry.device_type,
                entry.partition_id,
                @intFromBool(last),
                @intFromBool(self.efs_clear),
                @intFromBool(self.bootloader_update),
            });
        }
        var buf: [8]u8 = undefined;
        try self.readExact(&buf, self.flash_timeout_ms);
        const id = std.mem.readInt(u32, buf[0..4], .little);
        const ack = std.mem.readInt(u32, buf[4..8], .little);
        if (id == BOOTLOADER_FAIL) {
            switch (@as(i32, @bitCast(ack))) {
                -3 => {
                    self.logFail(ack, "end sequence");
                    return Error.EraseFailed;
                },
                -4 => {
                    self.logFail(ack, "end sequence");
                    return Error.WriteFailed;
                },
                else => {
                    self.logFail(ack, "end sequence");
                    return Error.Io;
                },
            }
        }
        if (id != RQT_XMIT) {
            self.logger.err("Odin: end-sequence response id 0x{X} (expected 0x{X})", .{ id, RQT_XMIT });
            return Error.Io;
        }
    }
};

// ----------------------------------------------------------------------
// Tests (scripted sim transport)
// ----------------------------------------------------------------------

const testing = std.testing;
const Harness = @import("../../transport/sim.zig").Harness;
const Step = @import("../../transport/sim.zig").Step;

fn respBytes(id: u32, ack: u32) [8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], id, .little);
    std.mem.writeInt(u32, b[4..8], ack, .little);
    return b;
}

fn failBytes(code: i32) [8]u8 {
    return respBytes(0xFFFF_FFFF, @bitCast(code));
}

fn expectSessionOpen(steps: *std.ArrayList(Step), protocol: u16) !void {
    try steps.append(testing.allocator, .{ .expect_write = "ODIN" });
    try steps.append(testing.allocator, .{ .respond = "LOKE" });
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // RQT_INIT_TARGET
    // Ack packs [unknown1][unknown2][protocol i16]; comptime literals so the
    // step slices are static.
    const version_bytes: []const u8 = if (protocol >= 2)
        &[_]u8{ 0x64, 0, 0, 0, 0, 0, 2, 0 }
    else
        &[_]u8{ 0x64, 0, 0, 0, 0, 0, 1, 0 };
    try steps.append(testing.allocator, .{ .respond = version_bytes });
    if (protocol >= 2) {
        try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // RQT_INIT_PACKETSIZE
        try steps.append(testing.allocator, .{ .respond = &[_]u8{ 0x64, 0, 0, 0, 0, 0, 0, 0 } });
    }
}

test "odin handshake and begin session (v1 and v2+)" {
    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };

    // Protocol v1: 128 KiB parts, no part-size announcement.
    {
        var steps = std.ArrayList(Step).empty;
        defer steps.deinit(testing.allocator);
        try expectSessionOpen(&steps, 1);
        var h = try Harness.init(testing.allocator, steps.items);
        defer h.deinit();
        var io = Io.init(testing.allocator, h.transport());
        defer io.deinit();
        const cancel = std.atomic.Value(bool).init(false);
        var sess = Session{ .alloc = testing.allocator, .io = &io, .logger = l, .cancel = &cancel };

        try sess.handshake();
        const v = try sess.beginSession();
        try testing.expectEqual(@as(u16, 1), v.protocol);
        try testing.expectEqual(@as(usize, 131072), sess.flash_packet_size);
        try testing.expectEqual(@as(usize, 240), sess.flash_sequence_parts);
    }

    // Protocol v2: 1 MiB parts + part-size announcement.
    {
        var steps = std.ArrayList(Step).empty;
        defer steps.deinit(testing.allocator);
        try expectSessionOpen(&steps, 2);
        var h = try Harness.init(testing.allocator, steps.items);
        defer h.deinit();
        var io = Io.init(testing.allocator, h.transport());
        defer io.deinit();
        const cancel = std.atomic.Value(bool).init(false);
        var sess = Session{ .alloc = testing.allocator, .io = &io, .logger = l, .cancel = &cancel };

        try sess.handshake();
        _ = try sess.beginSession();
        try testing.expectEqual(@as(usize, 1048576), sess.flash_packet_size);
        try testing.expectEqual(@as(usize, 30), sess.flash_sequence_parts);
        try testing.expectEqual(@as(u32, 120_000), sess.flash_timeout_ms);
    }
}

test "odin dumpPit fetches blocks and the parser reads them" {
    var pit_bytes = std.ArrayList(u8).empty;
    defer pit_bytes.deinit(testing.allocator);
    try @import("pit.zig").buildPit(&pit_bytes);

    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);
    try expectSessionOpen(&steps, 1);
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // RQT_PIT_GET
    const head = respBytes(RQT_PIT, @intCast(pit_bytes.items.len));
    try steps.append(testing.allocator, .{ .respond = &head });
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // block 0
    try steps.append(testing.allocator, .{ .respond = pit_bytes.items });
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // RQT_PIT_COMPLETE
    const tail = respBytes(RQT_PIT, 0);
    try steps.append(testing.allocator, .{ .respond = &tail });

    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };

    var h = try Harness.init(testing.allocator, steps.items);
    defer h.deinit();
    var io = Io.init(testing.allocator, h.transport());
    defer io.deinit();
    const cancel = std.atomic.Value(bool).init(false);
    var sess = Session{ .alloc = testing.allocator, .io = &io, .logger = l, .cancel = &cancel };

    try sess.handshake();
    _ = try sess.beginSession();
    const dump = try sess.dumpPit(testing.allocator);
    defer testing.allocator.free(dump);
    try testing.expectEqualSlices(u8, pit_bytes.items, dump);

    var table = try @import("pit.zig").parse(testing.allocator, dump, l);
    defer table.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), table.count);
}

test "odin flashPartition streams parts and closes with reset" {
    // 320 KiB image on a v1 session: one sequence, 3 aligned 128 KiB parts.
    const image_len: u64 = 320 * 1024;
    var image = std.ArrayList(u8).empty;
    defer image.deinit(testing.allocator);
    try image.appendNTimes(testing.allocator, 0xAB, @intCast(image_len));

    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);
    try expectSessionOpen(&steps, 1);
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // SetTotalBytes
    const tb = respBytes(RQT_INIT, 0);
    try steps.append(testing.allocator, .{ .respond = &tb });
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // RQT_XMIT_DOWNLOAD
    const dl = respBytes(RQT_XMIT, 0);
    try steps.append(testing.allocator, .{ .respond = &dl });
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // RQT_XMIT_START
    const st = respBytes(RQT_XMIT, 0);
    try steps.append(testing.allocator, .{ .respond = &st });
    // Function-scope arrays: the step slices must outlive the loop body.
    const p0 = respBytes(RQT_XMIT, 0);
    const p1 = respBytes(RQT_XMIT, 1);
    const p2 = respBytes(RQT_XMIT, 2);
    for (0..3) |j| {
        try steps.append(testing.allocator, .{ .expect_write_len = 131072 }); // part
        const pj: []const u8 = switch (j) {
            0 => &p0,
            1 => &p1,
            else => &p2,
        };
        try steps.append(testing.allocator, .{ .respond = pj });
    }
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // end sequence
    const es = respBytes(RQT_XMIT, 0);
    try steps.append(testing.allocator, .{ .respond = &es });
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // reset flash count
    const rc = respBytes(RQT_INIT, 0);
    try steps.append(testing.allocator, .{ .respond = &rc });

    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };

    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("image.img", image.items);
    var pbuf: [176]u8 = undefined;
    const img_path = try tmp.filePath(&pbuf, "image.img");

    var h = try Harness.init(testing.allocator, steps.items);
    defer h.deinit();
    var io = Io.init(testing.allocator, h.transport());
    defer io.deinit();
    const cancel = std.atomic.Value(bool).init(false);
    var sess = Session{ .alloc = testing.allocator, .io = &io, .logger = l, .cancel = &cancel };

    try sess.handshake();
    _ = try sess.beginSession();
    try sess.setTotalBytes(image_len);
    var file = try fileio.File.open(img_path);
    defer file.close();
    const entry = @import("pit.zig").Entry{ .binary_type = 0, .device_type = 2, .partition_id = 1 };
    try sess.flashPartition(&file, entry, image_len, .{});

    // The last part must carry the file tail (64 KiB) followed by zero fill.
    // Two 1024-byte requests (end sequence + reset) follow the final part.
    const written = h.written.items;
    const part2 = written[written.len - 2048 - 131072 ..][0..131072];
    try testing.expectEqualSlices(u8, image.items[262144..], part2[0 .. image_len - 262144]);
    try testing.expectEqual(@as(u8, 0), part2[image_len - 262144]);
    // And the reset-flash-count request was the final write.
    try testing.expectEqual(@as(u32, RQT_INIT), std.mem.readInt(u32, written[written.len - 1024 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, written[written.len - 1020 ..][0..4], .little));
}

test "odin flashPartition maps bootloader failure codes" {
    var steps = std.ArrayList(Step).empty;
    defer steps.deinit(testing.allocator);
    try expectSessionOpen(&steps, 1);
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // SetTotalBytes
    const tb = respBytes(RQT_INIT, 0);
    try steps.append(testing.allocator, .{ .respond = &tb });
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // RQT_XMIT_DOWNLOAD
    const dl = respBytes(RQT_XMIT, 0);
    try steps.append(testing.allocator, .{ .respond = &dl });
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // RQT_XMIT_START (aligned 128K)
    const st = respBytes(RQT_XMIT, 0);
    try steps.append(testing.allocator, .{ .respond = &st });
    try steps.append(testing.allocator, .{ .expect_write_len = 131072 }); // part 0
    const p0 = respBytes(RQT_XMIT, 0);
    try steps.append(testing.allocator, .{ .respond = &p0 });
    try steps.append(testing.allocator, .{ .expect_write_len = 1024 }); // end sequence → write error
    const fail = failBytes(-4);
    try steps.append(testing.allocator, .{ .respond = &fail });

    const l = try testing.allocator.create(log.Logger);
    defer testing.allocator.destroy(l);
    l.* = .{ .mirror_stderr = false };

    var h = try Harness.init(testing.allocator, steps.items);
    defer h.deinit();
    var io = Io.init(testing.allocator, h.transport());
    defer io.deinit();
    const cancel = std.atomic.Value(bool).init(false);
    var sess = Session{ .alloc = testing.allocator, .io = &io, .logger = l, .cancel = &cancel };

    try sess.handshake();
    _ = try sess.beginSession();
    try sess.setTotalBytes(4096);
    const entry = @import("pit.zig").Entry{ .binary_type = 0, .device_type = 2, .partition_id = 1 };
    try testing.expectError(error.WriteFailed, sess.flashPartition(null, entry, 4096, .{}));
}
