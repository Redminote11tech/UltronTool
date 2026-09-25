//! Headless IPC bridge for the TS UI (Tauri shell).
//!
//! Owns exactly what the GTK UI owns — the udev device scanner and the
//! persistent Firehose session manager — and exposes them as line-delimited
//! JSON over stdin/stdout (see ipc/codec.zig for the wire contract). The
//! Tauri shell spawns this process and relays lines to the webview; nothing
//! else may talk to it.
//!
//! There is deliberately NO command-line interface here: arguments are
//! rejected. This binary is an internal service of the GUI, not a user-facing
//! tool — the flashing capabilities stay GUI-only.
//!
//! Logging: the log ring mirrors to stderr (operator console in the shell
//! that started the daemon) AND is forwarded as `log` events so the webview
//! console page shows the same stream the GTK app would.

const std = @import("std");
const glib = @import("glib");
const log = @import("../core/log.zig");
const ev = @import("../core/event.zig");
const transport = @import("../transport/transport.zig");
const scanner_mod = @import("../device/scanner.zig");
const manager_mod = @import("../protocol/qualcomm/manager.zig");
const usb = @import("../transport/usb.zig");
const usb_ids = @import("../protocol/qualcomm/usb_ids.zig");
const codec = @import("codec.zig");

const EventChannel = ev.Channel(ev.Event, 256);

/// Same opener wiring as the GTK app (app.zig usbOpen): production libusb
/// backend with the Qualcomm match policy.
fn usbOpen(ctx: *anyopaque, logger: *log.Logger, target: ?transport.Target, wait_ms: u32, alloc: std.mem.Allocator) transport.Error!transport.Transport {
    _ = ctx;
    const u = try alloc.create(usb.Usb);
    errdefer alloc.destroy(u);
    u.* = try usb.open(&usb_ids.policy, target, wait_ms, logger, alloc, null);
    return u.transport();
}

const Shared = struct {
    alloc: std.mem.Allocator,
    logger: *log.Logger,
    channel: *EventChannel,
    manager: ?*manager_mod.Manager,
    cancel: *std.atomic.Value(bool),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// stdin reader thread: lines → requests. Malformed lines are logged (and
/// mirrored to the UI via the log stream) but never kill the daemon.
fn readerRun(shared: *Shared) void {
    var arena_state = std.heap.ArenaAllocator.init(shared.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [8192]u8 = undefined;
    var pending: [8192]u8 = undefined;
    var pending_len: usize = 0;

    while (!shared.stopping.load(.acquire)) {
        const n = std.posix.read(0, &buf) catch |e| {
            shared.logger.err("daemon: stdin read failed: {s}", .{@errorName(e)});
            break;
        };
        if (n == 0) {
            shared.logger.info("daemon: stdin closed — shutting down", .{});
            break;
        }
        var rest = buf[0..n];
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const line = rest[0..nl];
            rest = rest[nl + 1 ..];
            var full: []const u8 = line;
            if (pending_len > 0) {
                const avail = pending.len - pending_len;
                const take = @min(avail, line.len);
                @memcpy(pending[pending_len..][0..take], line[0..take]);
                pending_len += take;
                full = pending[0..pending_len];
            }
            handleLine(shared, arena, full);
            pending_len = 0;
        }
        // Keep the remainder for the next read.
        const take = @min(pending.len - pending_len, rest.len);
        @memcpy(pending[pending_len..][0..take], rest[0..take]);
        pending_len += take;
        if (rest.len > take) {
            shared.logger.err("daemon: request line exceeds buffer — dropped", .{});
            pending_len = 0;
        }
    }
    shared.stopping.store(true, .release);
}

fn handleLine(shared: *Shared, arena: std.mem.Allocator, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;

    const parsed = codec.parseRequest(arena, trimmed) catch |e| {
        shared.logger.warn("daemon: bad request ({s}): {s}", .{ @errorName(e), trimmed[0..@min(trimmed.len, 120)] });
        return;
    };
    switch (parsed) {
        .cancel => shared.cancel.store(true, .release),
        .shutdown => shared.stopping.store(true, .release),
        .manager => |req| {
            if (shared.manager) |m| {
                m.enqueue(req);
            } else {
                shared.logger.err("daemon: manager unavailable — request dropped", .{});
            }
        },
    }
}

/// stdout writer: one libc write per line, looping over partial writes.
/// (Raw fd write via libc: Zig 0.16's File writer needs the new Io interface,
/// which is exactly the awkwardness this daemon avoids.)
fn writeLine(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(1, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return; // pipe closed — the shell will notice
        off += @intCast(n);
    }
}

/// Process entry — called from src/daemon_main.zig (the executable's module
/// root must be src/ for the ../core imports above to stay in-module).
pub fn daemonMain(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;

    // No CLI, by design: this process is spawned by the GUI shell with an
    // empty argv. Anything else is refused.
    for (init.minimal.args.vector, 0..) |a, i| {
        if (i == 0) continue; // argv[0]
        const arg = std.mem.span(a);
        if (arg.len > 0) {
            std.debug.print("ultron-daemon: no arguments accepted (spawned by the GUI shell)\n", .{});
            std.process.exit(1);
        }
    }

    const logger = try alloc.create(log.Logger);
    logger.* = .{ .min_level = .debug, .mirror_stderr = true };
    const channel = try alloc.create(EventChannel);
    channel.* = .{};
    const cancel = try alloc.create(std.atomic.Value(bool));
    cancel.* = std.atomic.Value(bool).init(false);

    var shared = Shared{
        .alloc = alloc,
        .logger = logger,
        .channel = channel,
        .manager = null,
        .cancel = cancel,
    };

    // hello banner: the shell treats a closed pipe as daemon death.
    {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(alloc);
        try codec.helloLine(&list, alloc);
        try list.append(alloc, '\n');
        writeLine(list.items);
    }

    const scanner = scanner_mod.Scanner.init(alloc, logger, channel) catch |e| blk: {
        logger.warn("device scanner unavailable: {s}", .{@errorName(e)});
        break :blk null;
    };
    if (scanner) |sc| sc.start() catch {
        logger.warn("failed to start device scanner", .{});
    };

    const manager = manager_mod.Manager.init(alloc, logger, channel, cancel, &usbOpen, @ptrCast(logger)) catch |e| blk: {
        logger.warn("session manager unavailable: {s}", .{@errorName(e)});
        break :blk null;
    };
    if (manager) |m| m.start() catch {
        logger.warn("failed to start session manager", .{});
    };
    shared.manager = manager;

    const reader = std.Thread.spawn(.{}, readerRun, .{&shared}) catch |e| {
        logger.err("daemon: cannot start reader thread: {s}", .{@errorName(e)});
        return e;
    };

    // --- event pump -------------------------------------------------------
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var log_since: u64 = 0;
    var log_batch = std.ArrayList(log.Entry).empty;
    defer log_batch.deinit(alloc);

    pump: while (true) {
        // Log ring → log events.
        log_batch.clearRetainingCapacity();
        const res = logger.drainSince(alloc, log_since, &log_batch) catch null;
        if (res) |r| {
            log_since = r.newest;
            for (log_batch.items) |entry| {
                out.clearRetainingCapacity();
                codec.appendLogEvent(&out, alloc, entry) catch break :pump;
                out.append(alloc, '\n') catch break :pump;
                writeLine(out.items);
            }
        }

        // Event channel → events. A `.finished` closes the job: consume the
        // cancel flag, exactly like the GTK UI's jobDone().
        channel.drain(&shared, pumpEvent);

        if (shared.stopping.load(.acquire)) break :pump;
        glib.usleep(10 * std.time.us_per_ms);
    }

    // --- clean shutdown ---------------------------------------------------
    if (manager) |m| {
        m.enqueue(.shutdown);
        m.shutdown();
    }
    if (scanner) |sc| sc.deinit();
    alloc.destroy(logger);
    alloc.destroy(channel);
    alloc.destroy(cancel);
    // The reader thread stays blocked in read(0); it dies with the process.
    _ = reader;
    std.process.exit(0);
}

/// Channel drain callback (runs on the pump thread).
fn pumpEvent(ctx: *Shared, event: ev.Event) void {
    switch (event) {
        .finished => ctx.cancel.store(false, .release),
        else => {},
    }
    var out = std.ArrayList(u8).empty;
    defer out.deinit(ctx.alloc);
    codec.appendEvent(&out, ctx.alloc, event) catch return;
    out.append(ctx.alloc, '\n') catch return;
    writeLine(out.items);
}
