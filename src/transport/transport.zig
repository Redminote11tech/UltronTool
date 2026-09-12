//! Transport abstraction — the interface protocol modules talk to.
//!
//! Ported from linux-msm/qdl (BSD-3-Clause): `include/qdl.h` (vtable-based
//! device struct) and `src/io.c` (pushback-buffered reads). Backends live in
//! `usb.zig` (libusb) and `sim.zig` (scripted, for tests and dry runs).

const std = @import("std");
const log = @import("../core/log.zig");

pub const Error = error{
    /// Operation aborted by a cancellation request.
    Cancelled,
    /// Timed out with zero bytes transferred.
    Timeout,
    /// Device detached mid-transfer.
    Gone,
    /// Device visible but not openable (permissions / claimed elsewhere).
    Busy,
    /// No matching device present.
    NoDevice,
    /// Transfer or claim failed.
    Io,
    OutOfMemory,
};

pub const PacketSizes = struct {
    in_max: usize,
    out_max: usize,
};

/// Vtable-based transport handle (the equivalent of qdl's `struct qdl_device`).
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read up to buf.len bytes. Returns bytes actually read; 0 means a
        /// zero-length packet. Partial data on timeout is success (qdl
        /// semantics); Timeout is only returned when nothing at all arrived.
        read: *const fn (ptr: *anyopaque, buf: []u8, timeout_ms: u32) Error!usize,
        /// Write the whole buffer. Returns bytes written.
        write: *const fn (ptr: *anyopaque, buf: []const u8, timeout_ms: u32) Error!usize,
        close: *const fn (ptr: *anyopaque) void,
        packetSizes: *const fn (ptr: *anyopaque) PacketSizes,
    };

    pub fn read(self: Transport, buf: []u8, timeout_ms: u32) Error!usize {
        return self.vtable.read(self.ptr, buf, timeout_ms);
    }

    pub fn write(self: Transport, buf: []const u8, timeout_ms: u32) Error!usize {
        return self.vtable.write(self.ptr, buf, timeout_ms);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }

    pub fn packetSizes(self: Transport) PacketSizes {
        return self.vtable.packetSizes(self.ptr);
    }
};

/// Pushback-buffered wrapper around a Transport — port of qdl's qdl_read /
/// qdl_push_back (src/io.c). A read that crossed a Firehose message boundary
/// (XML envelope followed by rawmode binary in one transport read) pushes the
/// trailing bytes back; they surface on the next read before any new
/// transport I/O happens.
pub const Io = struct {
    transport: Transport,
    allocator: std.mem.Allocator,
    pending: std.ArrayList(u8) = .empty,
    logger: ?*log.Logger = null,

    pub fn init(alloc: std.mem.Allocator, transport: Transport) Io {
        return .{ .transport = transport, .allocator = alloc };
    }

    pub fn deinit(self: *Io) void {
        self.pending.deinit(self.allocator);
    }

    /// Read a message from the device. Drains the pushback buffer before
    /// touching the underlying transport.
    pub fn read(self: *Io, buf: []u8, timeout_ms: u32) Error!usize {
        if (self.pending.items.len > 0) {
            const copy = @min(self.pending.items.len, buf.len);
            @memcpy(buf[0..copy], self.pending.items[0..copy]);
            std.mem.copyForwards(u8, self.pending.items[0 .. self.pending.items.len - copy], self.pending.items[copy..]);
            self.pending.items.len -= copy;
            return copy;
        }
        return self.transport.read(buf, timeout_ms);
    }

    /// Stash unread bytes for a future read(), concatenating onto whatever is
    /// already pending.
    pub fn pushBack(self: *Io, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.pending.appendSlice(self.allocator, bytes) catch {
            if (self.logger) |l| l.err("transport: out of memory stashing pushback data", .{});
        };
    }

    pub fn write(self: *Io, buf: []const u8, timeout_ms: u32) Error!usize {
        return self.transport.write(buf, timeout_ms);
    }

    pub fn packetSizes(self: *Io) PacketSizes {
        return self.transport.packetSizes();
    }
};

test "io serves pushback before transport and preserves order" {
    const H = @import("sim.zig").Harness;
    var h = try H.init(std.testing.allocator, &.{
        .{ .respond = "world" },
    });
    defer h.deinit();

    var io = Io.init(std.testing.allocator, h.transport());
    defer io.deinit();
    io.pushBack("hello ");

    var buf: [16]u8 = undefined;
    var n = try io.read(&buf, 100);
    try std.testing.expectEqualStrings("hello ", buf[0..n]);
    n = try io.read(&buf, 100);
    try std.testing.expectEqualStrings("world", buf[0..n]);
}

test "io pushback concatenation and chunked serving" {
    const H = @import("sim.zig").Harness;
    var h = try H.init(std.testing.allocator, &.{});
    defer h.deinit();

    var io = Io.init(std.testing.allocator, h.transport());
    defer io.deinit();
    io.pushBack("ab");
    io.pushBack("cdefg");

    var buf: [8]u8 = undefined;
    var n = try io.read(buf[0..3], 100);
    try std.testing.expectEqualStrings("abc", buf[0..n]);
    n = try io.read(&buf, 100);
    try std.testing.expectEqualStrings("defg", buf[0..n]);
}
