//! Scripted "device" transport for unit tests and dry runs.
//!
//! A Harness runs through a list of steps: writes from the host are matched
//! against expectations, and respond steps queue bytes that surface on
//! subsequent reads. Reads with an empty queue return Timeout (device not
//! talking), which is what protocol layers must handle.

const std = @import("std");
const transport_mod = @import("transport.zig");

const Transport = transport_mod.Transport;
const Error = transport_mod.Error;

pub const Step = union(enum) {
    /// Host must write exactly these bytes next; mismatches fail the write.
    expect_write: []const u8,
    /// Host must write this many bytes next (content not checked) — for
    /// binary streams whose chunking may vary.
    expect_write_len: usize,
    /// Queue data for subsequent host reads.
    respond: []const u8,
    /// Next host reads time out until a later respond step is reached.
    read_timeout: void,
    /// A write of any content advances the script (paces respond steps that
    /// belong to the command issued by that write).
    any_write: void,
};

pub const Harness = struct {
    allocator: std.mem.Allocator,
    steps: []const Step,
    step_idx: usize = 0,
    queue: std.ArrayList(u8) = .empty,
    written: std.ArrayList(u8) = .empty,
    failure: ?[]u8 = null, // first mismatch message (owned)

    pub fn init(alloc: std.mem.Allocator, steps: []const Step) !Harness {
        var h = Harness{ .allocator = alloc, .steps = steps };
        h.advance();
        return h;
    }

    pub fn deinit(self: *Harness) void {
        self.queue.deinit(self.allocator);
        self.written.deinit(self.allocator);
        if (self.failure) |f| self.allocator.free(f);
    }

    pub fn transport(self: *Harness) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Transport.VTable{
        .read = readVt,
        .write = writeVt,
        .close = closeVt,
        .packetSizes = packetSizesVt,
    };

    /// Consume any immediately-reachable respond steps into the read queue.
    fn advance(self: *Harness) void {
        while (self.step_idx < self.steps.len) {
            switch (self.steps[self.step_idx]) {
                .respond => |data| {
                    self.queue.appendSlice(self.allocator, data) catch {};
                    self.step_idx += 1;
                },
                else => break,
            }
        }
    }

    fn fail(self: *Harness, comptime fmt: []const u8, args: anytype) void {
        if (self.failure != null) return;
        self.failure = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
    }

    fn readVt(ptr: *anyopaque, buf: []u8, timeout_ms: u32) Error!usize {
        _ = timeout_ms;
        const self: *Harness = @ptrCast(@alignCast(ptr));
        if (self.queue.items.len == 0) {
            // Consume any scheduled timeouts before giving up.
            while (self.step_idx < self.steps.len) {
                switch (self.steps[self.step_idx]) {
                    .read_timeout => {
                        self.step_idx += 1;
                        self.advance();
                        if (self.queue.items.len > 0) return self.serve(buf);
                    },
                    else => break,
                }
            }
            return Error.Timeout;
        }
        return self.serve(buf);
    }

    fn serve(self: *Harness, buf: []u8) usize {
        const n = @min(buf.len, self.queue.items.len);
        @memcpy(buf[0..n], self.queue.items[0..n]);
        std.mem.copyForwards(u8, self.queue.items[0 .. self.queue.items.len - n], self.queue.items[n..]);
        self.queue.items.len -= n;
        return n;
    }

    fn writeVt(ptr: *anyopaque, buf: []const u8, timeout_ms: u32) Error!usize {
        _ = timeout_ms;
        const self: *Harness = @ptrCast(@alignCast(ptr));
        self.written.appendSlice(self.allocator, buf) catch {};

        if (self.step_idx < self.steps.len) {
            switch (self.steps[self.step_idx]) {
                .any_write => {
                    self.step_idx += 1;
                    self.advance();
                },
                .expect_write => |expect| {
                    if (!std.mem.eql(u8, buf, expect)) {
                        self.fail("expected write {s}, got {s}", .{ expect, buf });
                        return Error.Io;
                    }
                    self.step_idx += 1;
                    self.advance();
                },
                .expect_write_len => |len| {
                    if (buf.len != len) {
                        self.fail("expected write of {d} bytes, got {d}", .{ len, buf.len });
                        return Error.Io;
                    }
                    self.step_idx += 1;
                    self.advance();
                },
                else => {}, // writes not covered by an expectation are ignored
            }
        }
        return buf.len;
    }

    fn closeVt(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn packetSizesVt(ptr: *anyopaque) transport_mod.PacketSizes {
        _ = ptr;
        return .{ .in_max = 512, .out_max = 512 };
    }
};

test "harness matches writes and serves responses in order" {
    var h = try Harness.init(std.testing.allocator, &.{
        .{ .expect_write = "PING" },
        .{ .respond = "PONG" },
        .{ .expect_write_len = 4 },
        .{ .respond = "ACK" },
    });
    defer h.deinit();

    const t = h.transport();
    var n = try t.write("PING", 100);
    try std.testing.expectEqual(@as(usize, 4), n);

    var buf: [8]u8 = undefined;
    n = try t.read(&buf, 100);
    try std.testing.expectEqualStrings("PONG", buf[0..n]);

    n = try t.write("abcd", 100);
    try std.testing.expectEqual(@as(usize, 4), n);
    n = try t.read(&buf, 100);
    try std.testing.expectEqualStrings("ACK", buf[0..n]);

    // Queue empty → timeout.
    try std.testing.expectError(Error.Timeout, t.read(&buf, 100));
    try std.testing.expect(h.failure == null);
}

test "harness reports write mismatch" {
    var h = try Harness.init(std.testing.allocator, &.{
        .{ .expect_write = "RIGHT" },
        .{ .respond = "ok" },
    });
    defer h.deinit();
    const t = h.transport();
    try std.testing.expectError(Error.Io, t.write("WRONG", 100));
    try std.testing.expect(h.failure != null);
}
