//! Thread-safe logging ring buffer.
//!
//! Worker threads (protocol sessions, device scanner) push formatted entries;
//! the UI drains them on the GTK main loop. Entries are stored in a fixed-size
//! ring so logging never allocates and never blocks on the UI.
//!
//! Synchronization uses GLib's mutex because GLib is a hard dependency of the
//! app (the UI main loop runs on it) and its threading primitives are stable.

const std = @import("std");
const glib = @import("glib");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// Maximum characters stored per entry; longer messages are truncated.
pub const max_text_len = 1024;

pub const Entry = struct {
    seq: u64,
    ts_ms: i64,
    level: Level,
    len: usize,
    text: [max_text_len]u8,
};

const ring_capacity = 2048;

pub const Logger = struct {
    mutex: glib.Mutex = .{ .f_i = .{ 0, 0 } }, // zeroed GMutex = statically initialized
    entries: [ring_capacity]Entry = undefined,
    head: usize = 0, // next write slot
    count: usize = 0, // valid entries in ring
    seq: u64 = 1, // monotonically increasing id (first entry is 1; 0 means "nothing")
    dropped: u64 = 0,
    min_level: Level = .debug,
    mirror_stderr: bool = true,
    start_ms: i64 = 0, // glib monotonic µs at first use; 0 = initialize on first push

    pub fn log(self: *Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;

        var buf: [max_text_len]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            // Overflowed: never re-format from the same buffer (aliasing);
            // write a marker instead.
            break :blk std.fmt.bufPrint(&buf, "<log message truncated>", .{}) catch buf[0..0];
        };
        self.push(level, text);
    }

    fn push(self: *Logger, level: Level, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = &self.entries[self.head];
        self.head = (self.head + 1) % ring_capacity;
        if (self.count < ring_capacity) {
            self.count += 1;
        } else {
            self.dropped += 1;
        }

        const now_us = glib.getMonotonicTime();
        if (self.start_ms == 0) self.start_ms = now_us;
        slot.seq = self.seq;
        slot.ts_ms = now_us;
        slot.level = level;
        slot.len = @min(text.len, max_text_len);
        @memcpy(slot.text[0..slot.len], text[0..slot.len]);
        self.seq += 1;

        if (self.mirror_stderr) {
            const elapsed_ms: u64 = @intCast(@divFloor(slot.ts_ms - self.start_ms, 1000));
            std.debug.print("[{d:0>3}.{d:0>3}s] {s}: {s}\n", .{
                elapsed_ms / 1000,
                elapsed_ms % 1000,
                level.label(),
                slot.text[0..slot.len],
            });
        }
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }
    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }
    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }
    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    /// Copy every entry with `seq > since` into `out` (one allocation per
    /// entry), returning the newest seq observed and the total number of
    /// entries dropped by ring overflow so far.
    pub fn drainSince(
        self: *Logger,
        alloc: std.mem.Allocator,
        since_seq: u64,
        out: *std.ArrayList(Entry),
    ) !struct { newest: u64, dropped_total: u64 } {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Walk oldest → newest.
        const start = if (self.count < ring_capacity) 0 else self.head;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const slot = &self.entries[(start + i) % ring_capacity];
            if (slot.seq <= since_seq) continue;
            try out.append(alloc, slot.*);
        }
        return .{ .newest = self.seq - 1, .dropped_total = self.dropped };
    }
};

test "ring logging basic ordering and drain" {
    var logger = Logger{ .mirror_stderr = false };
    logger.info("hello {d}", .{1});
    logger.warn("second", .{});

    var out = std.ArrayList(Entry).empty;
    defer out.deinit(std.testing.allocator);
    const res = try logger.drainSince(std.testing.allocator, 0, &out);
    try std.testing.expectEqual(@as(u64, 2), res.newest);
    try std.testing.expectEqualStrings("hello 1", out.items[0].text[0..out.items[0].len]);
    try std.testing.expectEqual(Level.warn, out.items[1].level);

    // Draining again with the newest seq yields nothing.
    var out2 = std.ArrayList(Entry).empty;
    defer out2.deinit(std.testing.allocator);
    const res2 = try logger.drainSince(std.testing.allocator, res.newest, &out2);
    try std.testing.expectEqual(@as(usize, 0), out2.items.len);
    try std.testing.expectEqual(res.newest, res2.newest);
}

test "ring wraps and counts drops" {
    var logger = Logger{ .mirror_stderr = false };
    var i: usize = 0;
    while (i < ring_capacity + 10) : (i += 1) {
        logger.info("n={d}", .{i});
    }
    try std.testing.expectEqual(@as(u64, 10), logger.dropped);
    var out = std.ArrayList(Entry).empty;
    defer out.deinit(std.testing.allocator);
    _ = try logger.drainSince(std.testing.allocator, 0, &out);
    try std.testing.expectEqual(@as(usize, ring_capacity), out.items.len);
    // Oldest surviving entry is the 10th written.
    try std.testing.expectEqualStrings("n=10", out.items[0].text[0..out.items[0].len]);
}
