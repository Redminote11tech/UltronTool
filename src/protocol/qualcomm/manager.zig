//! Persistent Firehose session manager.
//!
//! One worker thread owns the USB transport for as long as a Firehose session
//! lives. The UI posts requests (connect, upload loader, list partitions,
//! read/write partition, flash XML, reset, disconnect) into a queue; the
//! thread executes them sequentially over the open transport and reports
//! through the event channel. Device state machine:
//!
//!   disconnected --connect--> (device greets "<?xml" or silence) --> firehose_ready
//!   disconnected --connect--> (device greets Sahara HELLO)       --> needs_loader
//!   needs_loader --upload_loader--> firehose_ready
//!
//! Any transport error, cancel, reset or disconnect tears the session down
//! and returns to `disconnected`.

const std = @import("std");
const glib = @import("glib");
const transport = @import("../../transport/transport.zig");
const log = @import("../../core/log.zig");
const ev = @import("../../core/event.zig");
const fileio = @import("../../core/fileio.zig");
const sahara = @import("sahara.zig");
const firehose = @import("firehose.zig");
const rawprogram = @import("rawprogram.zig");
const gpt = @import("gpt.zig");

const Error = transport.Error;
const EventChannel = ev.Channel(ev.Event, 256);
const heap = std.heap.page_allocator;

/// Opens a transport for the protocol's devices. Production wires this to
/// the libusb backend + Qualcomm policy; tests inject a sim harness.
/// The returned Transport must support destroy() if it is heap-allocated.
pub const OpenFn = *const fn (ctx: *anyopaque, logger: *log.Logger, wait_ms: u32, alloc: std.mem.Allocator) Error!transport.Transport;

pub const Request = union(enum) {
    /// Open the transport and probe what is running. `programmer` may be
    /// provided up front (uploaded only when the device is in EDL).
    connect: struct {
        programmer: ?[]const u8 = null,
        storage: firehose.StorageType = .ufs,
        skip_storage_init: bool = false,
    },
    /// Upload the firehose programmer over Sahara (state: needs_loader).
    upload_loader: struct {
        programmer: []const u8,
        storage: firehose.StorageType = .ufs,
        skip_storage_init: bool = false,
    },
    /// Read the GPT of `lun` and emit a .partitions event.
    list_partitions: struct { lun: u32 },
    /// Read a partition range into a file (backup).
    read_partition: struct {
        path: []const u8,
        first_lba: u64,
        num_sectors: u64,
        lun: u32,
        label: []const u8,
    },
    /// Write a file onto a partition range.
    write_partition: struct {
        path: []const u8,
        first_lba: u64,
        max_sectors: u64,
        lun: u32,
        label: []const u8,
    },
    /// Flash rawprogram/patch XML files (qdl parity; no auto-reset).
    flash_xml: struct {
        files: []const []const u8,
        allow_missing: bool,
    },
    /// Reboot the device (ends the session).
    reset: void,
    /// Close the transport without touching the device.
    disconnect: void,
    /// Stop the worker thread (app shutdown).
    shutdown: void,
};

/// A queued request plus heap-allocated string storage. The ArrayList header
/// may be copied by value, but its buffer (and therefore the string pointers
/// referenced by `req`) stays put, keeping `req` valid while queued.
const QueueItem = struct {
    req: Request,
    strings: std.ArrayList([]u8) = .empty,
    files: ?[]const []const u8 = null, // heap array for .flash_xml

    fn dupe(item: *QueueItem, s: []const u8) ![]const u8 {
        const d = try heap.dupe(u8, s);
        try item.strings.append(heap, d);
        return d;
    }

    fn deinit(item: *QueueItem) void {
        for (item.strings.items) |s| heap.free(s);
        item.strings.deinit(heap);
        if (item.files) |f| heap.free(f);
        item.files = null;
    }
};

pub const Manager = struct {
    alloc: std.mem.Allocator,
    logger: *log.Logger,
    channel: *EventChannel,
    cancel: *const std.atomic.Value(bool),
    opener: OpenFn,
    opener_ctx: *anyopaque,

    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Control-plane queue (guarded; worker polls every 50 ms).
    mutex: glib.Mutex = .{ .f_i = .{ 0, 0 } }, // zeroed GMutex = statically initialized
    pending: std.ArrayList(QueueItem) = .empty,

    // Session state — only touched by the worker thread.
    t: ?transport.Transport = null,
    io: ?*transport.Io = null,
    fh: ?*firehose.Session = null,
    sector_size: u32 = 0,
    num_luns: u32 = 1,
    state: ev.SessionState = .disconnected,

    pub fn init(
        alloc: std.mem.Allocator,
        logger: *log.Logger,
        channel: *EventChannel,
        cancel: *const std.atomic.Value(bool),
        opener: OpenFn,
        opener_ctx: *anyopaque,
    ) !*Manager {
        const self = try alloc.create(Manager);
        self.* = .{
            .alloc = alloc,
            .logger = logger,
            .channel = channel,
            .cancel = cancel,
            .opener = opener,
            .opener_ctx = opener_ctx,
        };
        return self;
    }

    pub fn start(self: *Manager) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Duplicate `req`'s strings and hand the request to the worker thread.
    pub fn enqueue(self: *Manager, req: Request) void {
        var item = QueueItem{ .req = req };
        dupeRequest(&item) catch {
            item.deinit();
            self.logger.err("manager: out of memory queuing request", .{});
            return;
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending.append(self.alloc, item) catch {
            item.deinit();
            self.logger.err("manager: failed to queue request", .{});
        };
    }

    /// Stop the worker and free the manager.
    pub fn shutdown(self: *Manager) void {
        self.stopping.store(true, .release);
        if (self.thread) |t| t.join();
        for (self.pending.items) |*item| item.deinit();
        self.pending.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn dupeRequest(item: *QueueItem) !void {
        switch (item.req) {
            .connect => |*c| {
                if (c.programmer) |p| c.programmer = try item.dupe(p);
            },
            .upload_loader => |*u| u.programmer = try item.dupe(u.programmer),
            .read_partition => |*r| {
                r.path = try item.dupe(r.path);
                r.label = try item.dupe(r.label);
            },
            .write_partition => |*w| {
                w.path = try item.dupe(w.path);
                w.label = try item.dupe(w.label);
            },
            .flash_xml => |*f| {
                const files = try heap.alloc([]const u8, f.files.len);
                errdefer heap.free(files);
                for (f.files, 0..) |file, i| files[i] = try item.dupe(file);
                f.files = files;
                item.files = files;
            },
            else => {},
        }
    }

    // ------------------------------------------------------------------
    // Worker thread
    // ------------------------------------------------------------------

    fn run(self: *Manager) void {
        while (true) {
            self.mutex.lock();
            while (self.pending.items.len == 0 and !self.stopping.load(.acquire)) {
                self.mutex.unlock();
                glib.usleep(50 * std.time.us_per_ms);
                self.mutex.lock();
            }
            if (self.pending.items.len == 0) {
                self.mutex.unlock();
                break; // stopping
            }
            var item = self.pending.orderedRemove(0);
            self.mutex.unlock();

            self.runJob(&item);
            item.deinit();
        }
        self.teardown();
    }

    fn runJob(self: *Manager, item: *QueueItem) void {
        switch (item.req) {
            .connect => |c| self.connect(c.programmer, c.storage, c.skip_storage_init),
            .upload_loader => |u| self.uploadLoader(u.programmer, u.storage, u.skip_storage_init),
            .list_partitions => |lp| self.listPartitions(lp.lun),
            .read_partition => |r| self.readPartition(r.path, r.first_lba, r.num_sectors, r.lun, r.label),
            .write_partition => |w| self.writePartition(w.path, w.first_lba, w.max_sectors, w.lun, w.label),
            .flash_xml => |fx| self.flashXml(fx.files, fx.allow_missing),
            .reset => {
                if (self.requireSession()) |fh| {
                    self.logger.info("resetting device", .{});
                    fh.reset() catch |e| {
                        self.logger.warn("reset request failed: {s}", .{@errorName(e)});
                    };
                }
                self.teardown();
                self.emitState(.disconnected);
                pushFinished(self.channel, true, "device reset");
            },
            .disconnect => {
                self.teardown();
                self.emitState(.disconnected);
                pushFinished(self.channel, true, "disconnected");
            },
            .shutdown => {},
        }
    }

    // ------------------------------------------------------------------
    // Session lifecycle
    // ------------------------------------------------------------------

    fn emitState(self: *Manager, state: ev.SessionState) void {
        self.state = state;
        self.channel.push(.{ .session_state = state });
    }

    fn pushFinished(channel: *EventChannel, success: bool, msg: []const u8) void {
        var m = ev.FixedStr(512){};
        m.set(msg);
        channel.push(.{ .finished = .{ .success = success, .message = m } });
    }

    fn requireSession(self: *Manager) ?*firehose.Session {
        if (self.fh) |fh| return fh;
        pushFinished(self.channel, false, "not connected");
        return null;
    }

    /// Allocate the per-session IO wrapper around the open transport.
    fn makeIo(self: *Manager, t: transport.Transport) ?*transport.Io {
        const io = self.alloc.create(transport.Io) catch {
            pushFinished(self.channel, false, "OutOfMemory");
            return null;
        };
        io.* = transport.Io.init(self.alloc, t);
        return io;
    }

    /// Open a transport and probe what is running.
    fn connect(self: *Manager, programmer: ?[]const u8, storage: firehose.StorageType, skip_storage_init: bool) void {
        if (self.cancel.load(.acquire)) return;

        // Already waiting for a loader with the HELLO preserved: a re-probe
        // would close the transport and lose the HELLO (the PBL does not
        // re-send it), so just re-announce the state.
        if (self.state == .needs_loader and self.t != null) {
            self.emitState(.needs_loader);
            pushFinished(self.channel, true, "loader required");
            return;
        }

        self.teardown();
        self.logger.info("connecting…", .{});

        const t = self.opener(self.opener_ctx, self.logger, 8000, self.alloc) catch |e| {
            self.logger.err("failed to open device: {s}", .{@errorName(e)});
            pushFinished(self.channel, false, @errorName(e));
            self.emitState(.disconnected);
            return;
        };
        self.t = t;
        self.io = self.makeIo(t) orelse {
            self.teardown();
            self.emitState(.disconnected);
            return;
        };

        // Probe: Firehose programmers greet with XML; a bare EDL device sends
        // a Sahara HELLO immediately. A read timeout is treated as "firehose
        // already running" (qdl detect_firehose semantics).
        var buf: [4096]u8 = undefined;
        const n = self.io.?.read(&buf, 1000) catch 0;

        if (n >= 5 and std.mem.eql(u8, buf[0..5], "<?xml")) {
            self.logger.info("device already runs a Firehose programmer — skipping loader", .{});
            self.configureNow(storage, skip_storage_init);
            return;
        }

        if (n >= 8) {
            const cmd = std.mem.readInt(u32, buf[0..4], .little);
            const length = std.mem.readInt(u32, buf[4..8], .little);
            if (@as(u32, @intCast(n)) == length and cmd == sahara.HELLO) {
                // Bare EDL device: a loader is required. The PBL does NOT
                // re-send HELLO when the host merely reopens the device, so
                // the transport stays open and the consumed HELLO is
                // replayed into the Sahara state machine — the upload then
                // continues on this very connection, exactly like qdl.
                self.io.?.pushBack(buf[0..n]);
                if (programmer) |p| {
                    self.logger.info("device is in EDL mode: uploading the chosen loader", .{});
                    self.uploadLoader(p, storage, skip_storage_init);
                } else {
                    self.logger.info("device is in EDL mode: a firehose loader is required (connection kept open)", .{});
                    self.emitState(.needs_loader);
                    pushFinished(self.channel, true, "loader required");
                }
                return;
            }
        }

        // Timeout or unparsable data: assume a Firehose programmer is already
        // running (qdl semantics) and let configure's retry loop verify.
        self.logger.info("no Sahara HELLO received; assuming Firehose programmer is already running", .{});
        self.configureNow(storage, skip_storage_init);
    }

    fn openTransport(self: *Manager) bool {
        const t = self.opener(self.opener_ctx, self.logger, 8000, self.alloc) catch |e| {
            self.logger.err("failed to open device: {s}", .{@errorName(e)});
            pushFinished(self.channel, false, @errorName(e));
            self.emitState(.disconnected);
            return false;
        };
        self.t = t;
        self.io = self.makeIo(t) orelse {
            self.t = null;
            t.close();
            self.emitState(.disconnected);
            return false;
        };
        return true;
    }

    fn uploadLoader(self: *Manager, programmer: []const u8, storage: firehose.StorageType, skip_storage_init: bool) void {
        if (self.cancel.load(.acquire)) return;

        // Fresh connection if the probe consumed/closed one: the device
        // re-issues its HELLO on reopen.
        if (self.t == null) {
            if (!self.openTransport()) return;
        }
        const io = self.io.?;

        const data = fileio.readFileAlloc(self.alloc, programmer, 64 * 1024 * 1024) catch |e| {
            self.logger.err("unable to read programmer {s}", .{programmer});
            self.teardown();
            pushFinished(self.channel, false, @errorName(e));
            self.emitState(.disconnected);
            return;
        };
        defer self.alloc.free(data);

        var images = [_]sahara.Image{.{
            .id = 13, // SAHARA_ID_EHOSTDL_IMG
            .name = std.fs.path.basename(programmer),
            .data = data,
        }};
        var sa = sahara.Session{
            .io = io,
            .logger = self.logger,
            .images = &images,
            .cancel = self.cancel,
            .progress = .{ .ctx = @constCast(@ptrCast(self.channel)), .cb = saharaProgressCb },
        };
        self.logger.info("uploading loader {s} over Sahara", .{programmer});
        sa.run(.{ .detect_firehose = false }) catch |e| {
            if (e == Error.Timeout) {
                self.logger.err("device did not answer Sahara HELLO — replug the device into EDL mode and retry", .{});
            }
            self.logger.err("Sahara transfer failed: {s}", .{@errorName(e)});
            self.teardown();
            pushFinished(self.channel, false, @errorName(e));
            self.emitState(.disconnected);
            return;
        };

        self.configureNow(storage, skip_storage_init);
    }

    /// Configure Firehose on the open transport, then announce readiness and
    /// load the LUN 0 partition table.
    fn configureNow(self: *Manager, storage: firehose.StorageType, skip_storage_init: bool) void {
        const io = self.io orelse return;
        const fh = self.alloc.create(firehose.Session) catch {
            pushFinished(self.channel, false, "OutOfMemory");
            return;
        };
        fh.* = .{
            .alloc = self.alloc,
            .io = io,
            .logger = self.logger,
            .cancel = self.cancel,
        };
        self.fh = fh;

        fh.configure(storage, skip_storage_init) catch |e| {
            self.logger.err("Firehose configure failed: {s}", .{@errorName(e)});
            self.teardown();
            pushFinished(self.channel, false, @errorName(e));
            self.emitState(.disconnected);
            return;
        };
        self.sector_size = fh.sector_size;

        // Storage info: LUN count for the dropdown and a sector-size fallback
        // when the probe could not run.
        if (fh.getStorageInfo(0)) |info| {
            if (self.sector_size == 0 and info.sector_size > 0) self.sector_size = @intCast(info.sector_size);
            if (info.num_physical > 0) self.num_luns = @intCast(@min(info.num_physical, 16));
            self.logger.info("storage: {d} blocks × {d} bytes ({s}/{s}), {d} LUN(s)", .{
                info.num_sectors,
                info.sector_size,
                info.memType(),
                info.prodName(),
                self.num_luns,
            });
        } else |_| {}

        self.emitState(.firehose_ready);
        pushFinished(self.channel, true, "connected");
        self.listPartitions(0);
    }

    /// Close the transport and drop the Firehose session. Safe to call twice.
    fn teardown(self: *Manager) void {
        if (self.fh) |fh| {
            self.alloc.destroy(fh);
            self.fh = null;
        }
        if (self.io) |io| {
            io.deinit();
            self.alloc.destroy(io);
            self.io = null;
        }
        if (self.t) |t| {
            t.close();
            t.destroy();
            self.t = null;
        }
        self.sector_size = 0;
        self.num_luns = 1;
    }

    // ------------------------------------------------------------------
    // Jobs
    // ------------------------------------------------------------------

    fn listPartitions(self: *Manager, lun: u32) void {
        const fh = self.requireSession() orelse return;
        const sector_size = self.sector_size;
        if (sector_size == 0) {
            pushFinished(self.channel, false, "sector size unknown");
            return;
        }

        // 1. LBA 0..1: protective MBR + GPT header.
        const head_buf = self.alloc.alloc(u8, 2 * sector_size) catch return;
        defer self.alloc.free(head_buf);
        const head_op = rawprogram.Program{
            .sector_size = sector_size,
            .num_sectors = 2,
            .partition = lun,
            .start_sector = "0",
        };
        const ok = fh.readSectors(&head_op, head_buf) catch |e| {
            self.sessionError(e);
            return;
        };
        if (!ok) {
            pushFinished(self.channel, false, "GPT read refused by programmer");
            return;
        }

        const header = gpt.parseHeader(head_buf, sector_size) catch |e| {
            self.logger.err("no valid GPT on LUN {d}: {s}", .{ lun, @errorName(e) });
            pushFinished(self.channel, false, "no GPT found");
            return;
        };

        // 2. Entry array.
        const entry_sectors = header.entrySectors(sector_size);
        const ent_buf = self.alloc.alloc(u8, @intCast(entry_sectors * sector_size)) catch return;
        defer self.alloc.free(ent_buf);
        var start_buf: [32]u8 = undefined;
        const ent_op = rawprogram.Program{
            .sector_size = sector_size,
            .num_sectors = @intCast(entry_sectors),
            .partition = lun,
            .start_sector = std.fmt.bufPrint(&start_buf, "{d}", .{header.entry_lba}) catch "2",
        };
        const ok2 = fh.readSectors(&ent_op, ent_buf) catch |e| {
            self.sessionError(e);
            return;
        };
        if (!ok2) {
            pushFinished(self.channel, false, "GPT entries read refused");
            return;
        }

        const list = gpt.parseEntries(self.alloc, ent_buf, header, sector_size) catch |e| {
            self.logger.err("GPT parse failed: {s}", .{@errorName(e)});
            pushFinished(self.channel, false, @errorName(e));
            return;
        };
        defer list.deinit(self.alloc);

        var event = ev.PartitionsEvent{ .lun = lun, .sector_size = sector_size, .luns = self.num_luns };
        for (list.items()) |p| {
            if (event.count >= ev.max_partition_rows) break;
            event.parts[event.count] = .{
                .index = p.index,
                .first_lba = p.first_lba,
                .last_lba = p.last_lba,
                .name = ev.FixedStr(72).fromSlice(p.nameSlice()),
            };
            event.count += 1;
        }
        self.logger.info("LUN {d}: {d} partitions", .{ lun, event.count });
        self.channel.push(.{ .partitions = event });
        pushFinished(self.channel, true, "partitions loaded");
    }

    fn readPartition(self: *Manager, path: []const u8, first_lba: u64, num_sectors: u64, lun: u32, label: []const u8) void {
        const fh = self.requireSession() orelse return;
        const sector_size = self.sector_size;
        if (sector_size == 0) {
            pushFinished(self.channel, false, "sector size unknown");
            return;
        }

        var file = fileio.File.create(path) catch |e| {
            self.logger.err("unable to create {s}: {s}", .{ path, @errorName(e) });
            pushFinished(self.channel, false, @errorName(e));
            return;
        };
        defer file.close();

        var start_buf: [32]u8 = undefined;
        const op = rawprogram.Program{
            .sector_size = sector_size,
            .num_sectors = @intCast(num_sectors),
            .partition = lun,
            .start_sector = std.fmt.bufPrint(&start_buf, "{d}", .{first_lba}) catch "0",
        };
        const chunk = self.alloc.alloc(u8, 1024 * 1024) catch return;
        defer self.alloc.free(chunk);

        self.logger.info("reading {s} ({d} sectors from LBA {d}) to {s}", .{ label, num_sectors, first_lba, path });
        const ok = fh.readSectorsToFile(&op, &file, chunk, label) catch |e| {
            self.sessionError(e);
            return;
        };
        if (ok) {
            self.logger.info("read of {s} finished", .{label});
            pushFinished(self.channel, true, "read finished");
        } else {
            self.logger.err("read of {s} failed", .{label});
            pushFinished(self.channel, false, "read failed");
        }
    }

    fn writePartition(self: *Manager, path: []const u8, first_lba: u64, max_sectors: u64, lun: u32, label: []const u8) void {
        const fh = self.requireSession() orelse return;
        const sector_size = self.sector_size;
        if (sector_size == 0) {
            pushFinished(self.channel, false, "sector size unknown");
            return;
        }

        var file = fileio.File.open(path) catch |e| {
            self.logger.err("unable to open {s}", .{path});
            pushFinished(self.channel, false, @errorName(e));
            return;
        };
        defer file.close();

        const file_size = file.size() catch 0;
        const needed: u64 = (file_size + sector_size - 1) / sector_size;
        if (needed > max_sectors) {
            self.logger.err("{s} ({d} sectors) does not fit partition {s} ({d} sectors) — aborted", .{ path, needed, label, max_sectors });
            pushFinished(self.channel, false, "image larger than partition");
            return;
        }

        var start_buf: [32]u8 = undefined;
        const op = rawprogram.Program{
            .sector_size = sector_size,
            .num_sectors = @intCast(max_sectors), // fh.program clamps to file size
            .partition = lun,
            .start_sector = std.fmt.bufPrint(&start_buf, "{d}", .{first_lba}) catch "0",
            .filename = path,
            .label = label,
        };

        self.logger.info("writing {s} ({d} bytes) to {s} (LBA {d})", .{ path, file_size, label, first_lba });
        fh.program(&op, &file) catch |e| {
            self.sessionError(e);
            return;
        };
        pushFinished(self.channel, true, "write finished");
    }

    fn flashXml(self: *Manager, files: []const []const u8, allow_missing: bool) void {
        const fh = self.requireSession() orelse return;

        var loader = rawprogram.Loader.init(self.alloc);
        defer loader.deinit();
        for (files) |file| {
            loader.loadFile(file, allow_missing, self.logger) catch |e| {
                self.logger.err("failed to load {s}", .{file});
                pushFinished(self.channel, false, @errorName(e));
                return;
            };
        }
        const ops = loader.opsSlice();
        if (ops.len == 0) {
            pushFinished(self.channel, false, "no operations in XML files");
            return;
        }

        var op_list = std.ArrayList(ExecOp).empty;
        defer op_list.deinit(self.alloc);
        for (ops) |op| op_list.append(self.alloc, .{ .op = op }) catch return;
        if (findBootablePartition(ops)) |part| {
            self.logger.info("adding set-bootable for partition {d}", .{part});
            op_list.append(self.alloc, .{ .set_bootable = part }) catch return;
        }

        var ectx = ExecCtx{ .channel = self.channel, .op_total = op_list.items.len };
        const saved_progress = fh.progress;
        fh.progress = .{ .ctx = &ectx, .cb = firehoseProgressCb };
        defer fh.progress = saved_progress;

        for (op_list.items, 0..) |item, i| {
            if (self.cancel.load(.acquire)) {
                // A cancelled Firehose write leaves the programmer mid-op;
                // the only safe continuation is a fresh session.
                self.teardown();
                self.emitState(.disconnected);
                pushFinished(self.channel, false, "Cancelled");
                return;
            }
            ectx.op_idx = i;
            switch (item) {
                .op => |op| switch (op.tag) {
                    .program => |*p| {
                        const fname = p.filename orelse continue;
                        self.logger.info("programming {s} (label {s})", .{ fname, p.label orelse "?" });
                        var file = fileio.File.open(fname) catch |e| {
                            self.logger.err("unable to open image {s}", .{fname});
                            pushFinished(self.channel, false, @errorName(e));
                            return;
                        };
                        defer file.close();
                        fh.program(p, &file) catch |e| {
                            self.sessionError(e);
                            return;
                        };
                    },
                    .erase => |*e| {
                        self.logger.info("erasing partition {s} ({d} sectors)", .{ e.start_sector, e.num_sectors });
                        fh.erase(e) catch |e2| {
                            self.sessionError(e2);
                            return;
                        };
                    },
                    .patch => |*pt| {
                        fh.applyPatch(pt) catch |e| {
                            self.sessionError(e);
                            return;
                        };
                    },
                },
                .set_bootable => |part| {
                    fh.setBootable(part) catch |e| {
                        self.sessionError(e);
                        return;
                    };
                },
            }
        }
        pushFinished(self.channel, true, "flash finished");
    }

    /// Transport-level failure: the session is history.
    fn sessionError(self: *Manager, e: Error) void {
        self.logger.err("session error: {s} — disconnecting", .{@errorName(e)});
        self.teardown();
        self.emitState(.disconnected);
        pushFinished(self.channel, false, @errorName(e));
    }
};

const ExecOp = union(enum) {
    op: rawprogram.Op,
    set_bootable: u32,
};

/// Port of program_find_bootable_partition: first match wins with the
/// priority xbl > xbl_a > sbl1.
fn findBootablePartition(ops: []const rawprogram.Op) ?u32 {
    const candidates = [_][]const u8{ "xbl", "xbl_a", "sbl1" };
    for (candidates) |label| {
        for (ops) |op| {
            switch (op.tag) {
                .program => |p| {
                    const l = p.label orelse continue;
                    if (std.mem.eql(u8, l, label)) return p.partition;
                },
                else => {},
            }
        }
    }
    return null;
}

const ExecCtx = struct {
    channel: *EventChannel,
    op_idx: usize = 0,
    op_total: usize = 0,
};

fn saharaProgressCb(ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void {
    const channel: *EventChannel = @ptrCast(@alignCast(ctx orelse return));
    const frac: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    var buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "uploading {s}", .{name}) catch name;
    channel.push(.{ .progress = .{ .fraction = 0.2 * frac, .label = ev.FixedStr(160).fromSlice(text) } });
}

fn firehoseProgressCb(ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void {
    const ectx: *ExecCtx = @ptrCast(@alignCast(ctx orelse return));
    const op_frac: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    const base: f32 = if (ectx.op_total == 0) 0 else @as(f32, @floatFromInt(ectx.op_idx)) / @as(f32, @floatFromInt(ectx.op_total));
    const step: f32 = if (ectx.op_total == 0) 1 else 1.0 / @as(f32, @floatFromInt(ectx.op_total));

    var label = ev.FixedStr(160){};
    label.set(name);
    ectx.channel.push(.{ .progress = .{ .fraction = base + step * op_frac, .label = label } });
}

// ----------------------------------------------------------------------
// Tests (sim transport drives the full manager lifecycle)
// ----------------------------------------------------------------------

const SimHarness = @import("../../transport/sim.zig").Harness;
const SimStep = @import("../../transport/sim.zig").Step;

const SimOpener = struct {
    harness: ?*SimHarness = null,

    fn open(ctx: *anyopaque, logger: *log.Logger, wait_ms: u32, alloc: std.mem.Allocator) Error!transport.Transport {
        _ = logger;
        _ = wait_ms;
        _ = alloc;
        const self: *SimOpener = @ptrCast(@alignCast(ctx));
        return self.harness.?.transport();
    }
};

const ack = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\" MaxPayloadSizeToTargetInBytes=\"1048576\"/></data>";
const rawmode_ack = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\" rawmode=\"true\"/></data>";
const nop_xml = "<?xml version=\"1.0\" ?><data><nop /></data>";
const storage_info_log = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"{ &quot;storage_info&quot;: { &quot;total_blocks&quot;: 1000, &quot;block_size&quot;: 512, &quot;num_physical&quot;: 2 } }\"/><response value=\"ACK\"/></data>";

const Collector = struct {
    states: std.ArrayList(ev.SessionState) = .empty,
    finished: std.ArrayList(ev.Finished) = .empty,
    partitions: ?ev.PartitionsEvent = null,

    fn cb(self: *Collector, event: ev.Event) void {
        switch (event) {
            .session_state => |st| self.states.append(heap, st) catch {},
            .partitions => |p| self.partitions = p,
            .finished => |f| self.finished.append(heap, f) catch {},
            else => {},
        }
    }

    fn deinit(self: *Collector) void {
        self.states.deinit(heap);
        self.finished.deinit(heap);
    }
};

test "manager: already-in-firehose connect loads partitions" {
    const channel = try heap.create(EventChannel);
    channel.* = .{};
    defer heap.destroy(channel);
    var cancel = std.atomic.Value(bool).init(false);

    const logger = try heap.create(log.Logger);
    logger.* = .{ .mirror_stderr = false };

    // GPT fixture: sector size 512 → header read = 2 sectors, entries = 1 sector.
    var gpt_buf: [4096]u8 = undefined;
    _ = gpt.sampleGpt(512, &gpt_buf);
    const head = gpt_buf[0..1024];
    const ents = gpt_buf[1024..1536];

    const steps = [_]SimStep{
        // connect probe: firehose already running (available immediately)
        .{ .respond = nop_xml },
        // configure: plain ACK, no renegotiation
        .{ .any_write = {} },
        .{ .respond = ack },
        // getstorageinfo: storage json + ack in one document
        .{ .any_write = {} },
        .{ .respond = storage_info_log },
        // GPT header read (2 sectors)
        .{ .any_write = {} },
        .{ .respond = rawmode_ack },
        .{ .respond = head },
        .{ .respond = ack },
        // GPT entries read (1 sector)
        .{ .any_write = {} },
        .{ .respond = rawmode_ack },
        .{ .respond = ents },
        .{ .respond = ack },
    };

    var harness = try SimHarness.init(heap, &steps);
    defer harness.deinit();
    var opener = SimOpener{ .harness = &harness };

    const mgr = try Manager.init(std.testing.allocator, logger, channel, &cancel, &SimOpener.open, &opener);
    defer mgr.shutdown();
    try mgr.start();

    mgr.enqueue(.{ .connect = .{ .storage = .ufs, .skip_storage_init = true } });

    var collector = Collector{};
    defer collector.deinit();
    var deadline: usize = 0;
    while (deadline < 200) : (deadline += 1) {
        channel.drain(&collector, Collector.cb);
        if (collector.partitions != null) break;
        glib.usleep(10 * std.time.us_per_ms);
    }

    const parts = collector.partitions orelse {
        for (collector.finished.items) |f| std.debug.print("DBG finished: success={} msg={s}\n", .{ f.success, f.message.slice() });
        for (collector.states.items) |st| std.debug.print("DBG state: {s}\n", .{@tagName(st)});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(@as(u32, 2), parts.count);
    try std.testing.expectEqualStrings("boot", parts.parts[0].name.slice());
    try std.testing.expectEqualStrings("xbl_a", parts.parts[1].name.slice());
    try std.testing.expectEqual(@as(u32, 512), mgr.sector_size);
    try std.testing.expectEqual(@as(u32, 2), mgr.num_luns);
    // Final state fired was firehose_ready.
    try std.testing.expectEqual(ev.SessionState.firehose_ready, collector.states.items[collector.states.items.len - 1]);
}

test "manager: loader upload reuses the probed connection (replayed HELLO)" {
    const channel = try heap.create(EventChannel);
    channel.* = .{};
    defer heap.destroy(channel);
    var cancel = std.atomic.Value(bool).init(false);

    const logger = try heap.create(log.Logger);
    logger.* = .{ .mirror_stderr = false };

    // Tiny fake firehose programmer the device will "request" over Sahara.
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    const image = "FAKE-PROG-IMG!";
    try tmp.writeFile("prog.elf", image);

    // Sahara HELLO the device sends on enumeration (mode: image tx).
    var hello_pkt: [48]u8 = @splat(0);
    std.mem.writeInt(u32, hello_pkt[0..4], sahara.HELLO, .little);
    std.mem.writeInt(u32, hello_pkt[4..8], 48, .little);
    std.mem.writeInt(u32, hello_pkt[8..12], 2, .little);
    std.mem.writeInt(u32, hello_pkt[12..16], 1, .little);
    std.mem.writeInt(u32, hello_pkt[16..20], 4096, .little);
    std.mem.writeInt(u32, hello_pkt[20..24], sahara.MODE_IMAGE_TX_PENDING, .little);

    var read_data: [20]u8 = @splat(0);
    std.mem.writeInt(u32, read_data[0..4], sahara.READ_DATA, .little);
    std.mem.writeInt(u32, read_data[4..8], 20, .little);
    std.mem.writeInt(u32, read_data[8..12], 13, .little); // image id 13
    std.mem.writeInt(u32, read_data[12..16], 0, .little);
    std.mem.writeInt(u32, read_data[16..20], image.len, .little);

    var eoi: [16]u8 = @splat(0);
    std.mem.writeInt(u32, eoi[0..4], sahara.END_OF_IMAGE, .little);
    std.mem.writeInt(u32, eoi[4..8], 16, .little);
    std.mem.writeInt(u32, eoi[8..12], 13, .little);

    var done_resp: [12]u8 = @splat(0);
    std.mem.writeInt(u32, done_resp[0..4], sahara.DONE_RESP, .little);
    std.mem.writeInt(u32, done_resp[4..8], 12, .little);
    std.mem.writeInt(u32, done_resp[8..12], 1, .little); // complete

    var gpt_buf: [4096]u8 = undefined;
    _ = gpt.sampleGpt(512, &gpt_buf);
    const head = gpt_buf[0..1024];
    const ents = gpt_buf[1024..1536];

    const steps = [_]SimStep{
        // connect probe: the device greets with Sahara HELLO (consumed here,
        // replayed by the manager for the upload)
        .{ .respond = &hello_pkt },
        // upload: HELLO_RESP write, then the device requests the image
        .{ .any_write = {} },
        .{ .respond = &read_data },
        .{ .expect_write = image },
        .{ .respond = &eoi },
        // DONE write, device confirms complete
        .{ .any_write = {} },
        .{ .respond = &done_resp },
        // configure (skip_storage_init = true)
        .{ .any_write = {} },
        .{ .respond = ack },
        // getstorageinfo
        .{ .any_write = {} },
        .{ .respond = storage_info_log },
        // GPT header read
        .{ .any_write = {} },
        .{ .respond = rawmode_ack },
        .{ .respond = head },
        .{ .respond = ack },
        // GPT entries read
        .{ .any_write = {} },
        .{ .respond = rawmode_ack },
        .{ .respond = ents },
        .{ .respond = ack },
    };

    var harness = try SimHarness.init(heap, &steps);
    defer harness.deinit();
    var opener = SimOpener{ .harness = &harness };

    const mgr = try Manager.init(std.testing.allocator, logger, channel, &cancel, &SimOpener.open, &opener);
    defer mgr.shutdown();
    try mgr.start();

    // User flow: Connect (no loader chosen) -> needs_loader -> choose file ->
    // Upload loader — all on ONE kept-open connection.
    mgr.enqueue(.{ .connect = .{} });

    var collector = Collector{};
    defer collector.deinit();
    var saw_needs_loader = false;
    var deadline: usize = 0;
    while (deadline < 200 and !saw_needs_loader) : (deadline += 1) {
        channel.drain(&collector, Collector.cb);
        for (collector.states.items) |st| {
            if (st == .needs_loader) saw_needs_loader = true;
        }
        glib.usleep(10 * std.time.us_per_ms);
    }
    try std.testing.expect(saw_needs_loader);
    try std.testing.expect(harness.failure == null);

    var pbuf: [176]u8 = undefined;
    const prog_path = try tmp.filePath(&pbuf, "prog.elf");
    mgr.enqueue(.{ .upload_loader = .{ .programmer = prog_path, .skip_storage_init = true } });

    var got_partitions = false;
    deadline = 0;
    while (deadline < 300) : (deadline += 1) {
        channel.drain(&collector, Collector.cb);
        if (collector.partitions != null) {
            got_partitions = true;
            break;
        }
        glib.usleep(10 * std.time.us_per_ms);
    }

    const parts = collector.partitions orelse {
        for (collector.finished.items) |f| std.debug.print("DBG finished: success={} msg={s}\n", .{ f.success, f.message.slice() });
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(@as(u32, 2), parts.count);
    try std.testing.expectEqualStrings("boot", parts.parts[0].name.slice());
    try std.testing.expectEqual(@as(u32, 512), mgr.sector_size);
    // The whole flow ran on the first transport: no reconnect happened.
    try std.testing.expect(harness.failure == null);
}
