//! Event channel between background threads (device scanner, protocol
//! sessions) and the UI thread. Events are fixed-size values so the producer
//! never allocates; the ring overwrites the oldest entry when full (with a
//! drop counter so the UI can notice).

const std = @import("std");
const glib = @import("glib");

/// Truncated, allocation-free fixed-capacity string.
pub fn FixedStr(comptime N: usize) type {
    return struct {
        const Self = @This();
        len: usize = 0,
        buf: [N]u8 = undefined,

        pub fn fromSlice(s: []const u8) Self {
            var out = Self{};
            out.set(s);
            return out;
        }

        pub fn set(self: *Self, s: []const u8) void {
            self.len = @min(s.len, N);
            @memcpy(self.buf[0..self.len], s[0..self.len]);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

/// What kind of device the scanner found, decided purely from USB
/// descriptors. Protocol modules own the matching rules; this enum is the
/// UI-facing summary.
pub const ModeTag = enum {
    qualcomm_edl,
    qualcomm_crash,
    mtk_brom,
    mtk_preloader,
    samsung_odin,
    unknown,

    pub fn displayName(self: ModeTag) []const u8 {
        return switch (self) {
            .qualcomm_edl => "Qualcomm EDL",
            .qualcomm_crash => "Qualcomm crash dump",
            .mtk_brom => "MediaTek BROM",
            .mtk_preloader => "MediaTek preloader",
            .samsung_odin => "Samsung download mode",
            .unknown => "Unknown USB device",
        };
    }
};

/// Stable identity of a USB device node (from its udev/sysfs path).
pub const DeviceKey = struct {
    path: FixedStr(160) = .{},

    pub fn eql(self: DeviceKey, other: DeviceKey) bool {
        return std.mem.eql(u8, self.path.slice(), other.path.slice());
    }
};

pub const DeviceInfo = struct {
    key: DeviceKey = .{},
    vid: u16 = 0,
    pid: u16 = 0,
    bus: u8 = 0,
    devnum: u8 = 0,
    mode: ModeTag = .unknown,
    manufacturer: FixedStr(96) = .{},
    product: FixedStr(96) = .{},
    serial: FixedStr(96) = .{},
};

pub const Progress = struct {
    /// 0..1; a negative value means "indeterminate".
    fraction: f32 = -1.0,
    label: FixedStr(160) = .{},
    /// Raw progress counters for throughput display.
    done: u64 = 0,
    total: u64 = 0,
};

pub const ChipInfoEvent = struct {
    protocol_version: u32 = 0,
    serial: ?u32 = null,
    hwid: ?u64 = null,
    msm_id: u32 = 0,
    oem_id: u16 = 0,
    model_id: u16 = 0,
    /// Hex string of the OEM PK hash ("" when unavailable).
    pkhash: FixedStr(140) = .{},
};

pub const Finished = struct {
    success: bool,
    message: FixedStr(512) = .{},
};

/// One GPT partition entry as shown in the UI.
pub const PartitionRow = struct {
    index: u32 = 0,
    first_lba: u64 = 0,
    last_lba: u64 = 0,
    name: FixedStr(72) = .{},

    pub fn sectors(self: *const PartitionRow) u64 {
        if (self.last_lba < self.first_lba) return 0;
        return self.last_lba - self.first_lba + 1;
    }
};

pub const max_partition_rows = 128;

pub const PartitionsEvent = struct {
    lun: u32 = 0,
    count: u32 = 0,
    sector_size: u32 = 0,
    luns: u32 = 1,
    /// VIP session: every packet must match the signed digest table, so
    /// partition browsing and single-partition reads/writes are unavailable.
    vip: bool = false,
    parts: [max_partition_rows]PartitionRow = undefined,
};

/// Lifecycle of the persistent Firehose session owned by the manager.
pub const SessionState = enum {
    /// No transport open (initial state, or after disconnect/reset/error).
    disconnected,
    /// Device answered Sahara HELLO: a firehose programmer must be uploaded.
    needs_loader,
    /// Firehose programmer is alive and configured: partitions available.
    firehose_ready,
};

/// One image entry inside a Huawei UPDATE.APP container (parse result).
pub const HuaweiAppEvent = struct {
    pub const max_entries = 64;

    pub const EntryInfo = struct {
        name: FixedStr(36) = .{},
        data_size: u64 = 0,
        raw_size: u64 = 0,
        sparse: bool = false,
    };

    entries: [max_entries]EntryInfo = undefined,
    count: u32 = 0,
    /// Parse-run generation: the UI bumps the counter whenever a new file is
    /// picked and drops events carrying an older value, so a slow parse of a
    /// previously chosen file can never pair stale entries with the new path.
    gen: u32 = 0,
};

pub const Event = union(enum) {
    device_added: DeviceInfo,
    device_removed: DeviceKey,
    progress: Progress,
    chip_info: ChipInfoEvent,
    finished: Finished,
    session_state: SessionState,
    partitions: PartitionsEvent,
    huawei_app: HuaweiAppEvent,
};

/// Overwriting ring channel. Single producer, single consumer (the UI drains
/// on the main loop), both sides lock the same mutex.
pub fn Channel(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        mutex: glib.Mutex = .{ .f_i = .{ 0, 0 } }, // zeroed GMutex = statically initialized
        ring: [capacity]T = undefined,
        head: usize = 0, // next write slot
        len: usize = 0,
        dropped: u64 = 0,

        pub fn push(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.ring[self.head] = value;
            self.head = (self.head + 1) % capacity;
            if (self.len < capacity) {
                self.len += 1;
            } else {
                self.dropped += 1;
            }
        }

        /// Pop all pending events, calling `cb(ctx, event)` for each in order.
        /// The snapshot is consumed under the lock BEFORE callbacks run, so
        /// events pushed by producers during a callback are retained for the
        /// next drain (dropping a `finished` would wedge the UI busy forever).
        pub fn drain(self: *Self, ctx: anytype, comptime cb: fn (@TypeOf(ctx), T) void) void {
            self.mutex.lock();
            const n = self.len;
            const scratch = std.heap.page_allocator.alloc(T, n) catch {
                // OOM: fall back to oldest-first per-event pops (still cannot
                // lose producer events mid-callback). GMutex is not recursive,
                // so the snapshot lock must be released before popping.
                self.mutex.unlock();
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    self.mutex.lock();
                    if (self.len == 0) {
                        self.mutex.unlock();
                        return;
                    }
                    const popped = self.ring[(self.head + capacity - self.len) % capacity];
                    self.len -= 1;
                    self.mutex.unlock();
                    cb(ctx, popped);
                }
                return;
            };
            const base = (self.head + capacity - n) % capacity;
            for (0..n) |i| scratch[i] = self.ring[(base + i) % capacity];
            self.len = 0; // consumed while locked
            self.mutex.unlock();

            for (0..n) |i| cb(ctx, scratch[i]);
            std.heap.page_allocator.free(scratch);
        }

        pub fn takeDropped(self: *Self) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            const d = self.dropped;
            self.dropped = 0;
            return d;
        }
    };
}

const CollectCtx = struct {
    items: [8]u32 = undefined,
    n: usize = 0,
    overflow_seen: u64 = 0,
};

fn collectCb(ctx: *CollectCtx, v: u32) void {
    if (ctx.n < ctx.items.len) {
        ctx.items[ctx.n] = v;
    }
    ctx.n += 1;
}

test "channel preserves order and reports overflow" {
    const Ch = Channel(u32, 4);
    var ch = Ch{};
    for (0..6) |i| ch.push(@intCast(i));

    var ctx = CollectCtx{};
    ch.drain(&ctx, collectCb);
    try std.testing.expectEqual(@as(usize, 4), ctx.n);
    try std.testing.expectEqual(@as(u32, 2), ctx.items[0]);
    try std.testing.expectEqual(@as(u32, 5), ctx.items[3]);
    try std.testing.expectEqual(@as(u64, 2), ch.takeDropped());
}

test "fixedstr truncates" {
    const S = FixedStr(4);
    const s = S.fromSlice("abcdef");
    try std.testing.expectEqualStrings("abcd", s.slice());
}
