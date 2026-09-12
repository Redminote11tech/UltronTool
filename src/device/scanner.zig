//! Hot-plug device scanner built on libudev.
//!
//! Enumerates existing USB devices once, then watches the udev netlink
//! socket; every discovered device is run through the protocol registry's
//! classifier and surfaced on the event channel (device_added /
//! device_removed). A slow periodic re-enumeration covers races the monitor
//! can miss. All state lives on the scanner thread; the UI only sees events.

const std = @import("std");
const glib = @import("glib");
const c = @cImport({
    @cInclude("libudev.h");
    @cInclude("stdio.h");
});
const log = @import("../core/log.zig");
const ev = @import("../core/event.zig");
const proto = @import("../protocol/protocol.zig");

const EventChannel = ev.Channel(ev.Event, 256);

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    logger: *log.Logger,
    channel: *EventChannel,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    udev: ?*c.struct_udev = null,
    monitor: ?*c.struct_udev_monitor = null,
    monitor_fd: std.posix.fd_t = -1,
    known: std.StringArrayHashMapUnmanaged(ev.DeviceInfo) = .empty,
    /// Interface descriptors seen on usb_interface events, keyed by the
    /// parent usb_device sysfs path.
    ifaces: std.StringHashMapUnmanaged(InterfaceInfo) = .empty,
    want_scan: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, logger: *log.Logger, channel: *EventChannel) !*Scanner {
        const self = try allocator.create(Scanner);
        errdefer allocator.destroy(self);

        const udev = c.udev_new() orelse return error.UdevInitFailed;
        errdefer _ = c.udev_unref(udev);

        // The netlink monitor is optional: if it cannot be created (restricted
        // sessions, containers), the periodic re-enumeration sweep still
        // detects every device. Detection must never depend on it.
        const monitor = c.udev_monitor_new_from_netlink(udev, "udev");
        var monitor_fd: std.posix.fd_t = -1;
        if (monitor) |m| {
            _ = c.udev_monitor_filter_add_match_subsystem_devtype(m, "usb", "usb_device");
            if (c.udev_monitor_enable_receiving(m) == 0) {
                monitor_fd = c.udev_monitor_get_fd(m);
            } else {
                logger.warn("scanner: udev monitor unavailable (will rescan every 500 ms)", .{});
                _ = c.udev_monitor_unref(m);
                self.* = .{
                    .allocator = allocator,
                    .logger = logger,
                    .channel = channel,
                    .udev = udev,
                };
                return self;
            }
        } else {
            logger.warn("scanner: udev monitor creation failed (will rescan every 500 ms)", .{});
        }

        self.* = .{
            .allocator = allocator,
            .logger = logger,
            .channel = channel,
            .udev = udev,
            .monitor = monitor,
            .monitor_fd = monitor_fd,
        };
        return self;
    }

    /// Force an immediate re-enumeration from any thread.
    pub fn requestScan(self: *Scanner) void {
        self.want_scan.store(true, .release);
    }

    pub fn start(self: *Scanner) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *Scanner) void {
        self.stopping.store(true, .release);
        if (self.thread) |t| t.join();
        for (self.known.keys()) |k| self.allocator.free(k);
        self.known.deinit(self.allocator);
        {
            var kit = self.ifaces.keyIterator();
            while (kit.next()) |k| self.allocator.free(k.*);
        }
        self.ifaces.deinit(self.allocator);
        if (self.monitor) |m| _ = c.udev_monitor_unref(m);
        if (self.udev) |u| _ = c.udev_unref(u);
        self.allocator.destroy(self);
    }

    fn run(self: *Scanner) void {
        self.logger.debug("scanner: initial enumeration", .{});
        self.enumerate();
        var last_enum = glibMonoNow();

        var fds = [_]std.posix.pollfd{.{
            .fd = self.monitor_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        while (!self.stopping.load(.acquire)) {
            if (self.monitor != null) {
                const ready = std.posix.poll(&fds, 300) catch 0;
                if (ready > 0) {
                    while (true) {
                        const dev = c.udev_monitor_receive_device(self.monitor) orelse break;
                        defer _ = c.udev_device_unref(dev);
                        self.handleDevice(dev);
                    }
                }
            } else {
                glib.usleep(50 * std.time.us_per_ms);
            }

            // Periodic re-enumeration: the safety net that makes detection
            // independent of the monitor. 500 ms keeps hot-plug snappy.
            const force = self.want_scan.swap(false, .acq_rel);
            const now = glibMonoNow();
            if (force or now - last_enum > 500 * std.time.us_per_ms) {
                last_enum = now;
                self.enumerate();
            }
        }
        self.logger.debug("scanner: stopped", .{});
    }

    fn enumerate(self: *Scanner) void {
        const e = c.udev_enumerate_new(self.udev) orelse return;
        defer _ = c.udev_enumerate_unref(e);
        _ = c.udev_enumerate_add_match_subsystem(e, "usb");
        if (c.udev_enumerate_scan_devices(e) != 0) {
            self.logger.warn("scanner: udev enumeration failed", .{});
            return;
        }

        var it = c.udev_enumerate_get_list_entry(e);
        while (it != null) : (it = c.udev_list_entry_get_next(it)) {
            const syspath = c.udev_list_entry_get_name(it) orelse continue;
            const dev = c.udev_device_new_from_syspath(self.udev, syspath) orelse continue;
            defer _ = c.udev_device_unref(dev);
            self.handleDevice(dev);
        }
    }

    /// Process one udev device (from enumeration or monitor). Interface
    /// nodes feed the descriptor cache; only usb_device nodes classify.
    fn handleDevice(self: *Scanner, dev: *c.struct_udev_device) void {
        const devtype = c.udev_device_get_devtype(dev) orelse return;
        if (!std.mem.eql(u8, std.mem.span(devtype), "usb_device")) {
            self.noteInterface(dev);
            return;
        }

        const syspath = c.udev_device_get_syspath(dev) orelse return;
        const action_ptr = c.udev_device_get_action(dev);
        const action: []const u8 = if (action_ptr) |a| std.mem.span(a) else "add";
        const path_slice = std.mem.span(syspath);

        if (std.mem.eql(u8, action, "remove")) {
            self.removeKnown(path_slice);
            return;
        }

        const info = self.buildInfo(dev) orelse return;
        if (info.mode == .unknown) {
            self.removeKnown(path_slice);
            return;
        }

        const gop = self.known.getOrPut(self.allocator, info.key.path.slice()) catch return;
        if (gop.found_existing) {
            if (std.meta.eql(gop.value_ptr.*, info)) return; // no change
            gop.value_ptr.* = info;
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, info.key.path.slice()) catch {
                _ = self.known.pop();
                return;
            };
            gop.value_ptr.* = info;
            self.logger.info("device: {s} ({x:0>4}:{x:0>4}) at {s}", .{ info.mode.displayName(), info.vid, info.pid, info.key.path.slice() });
        }
        self.channel.push(.{ .device_added = info });
    }

    /// Record an interface node's descriptor against its parent device path.
    fn noteInterface(self: *Scanner, dev: *c.struct_udev_device) void {
        const parent = c.udev_device_get_parent(dev) orelse return;
        const parent_path = c.udev_device_get_syspath(parent) orelse return;
        const class = blk: {
            const v = c.udev_device_get_sysattr_value(dev, "bInterfaceClass") orelse return;
            break :blk std.fmt.parseInt(u8, std.mem.trim(u8, std.mem.span(v), " \t\r\n"), 16) catch null;
        };
        const subclass: ?u8 = blk: {
            const v = c.udev_device_get_sysattr_value(dev, "bInterfaceSubClass") orelse break :blk null;
            break :blk std.fmt.parseInt(u8, std.mem.trim(u8, std.mem.span(v), " \t\r\n"), 16) catch null;
        };
        const protocol: ?u8 = blk: {
            const v = c.udev_device_get_sysattr_value(dev, "bInterfaceProtocol") orelse break :blk null;
            break :blk std.fmt.parseInt(u8, std.mem.trim(u8, std.mem.span(v), " \t\r\n"), 16) catch null;
        };

        const info = InterfaceInfo{ .class = class, .subclass = subclass, .protocol = protocol };
        const key = self.allocator.dupe(u8, std.mem.span(parent_path)) catch return;
        const gop = self.ifaces.getOrPut(self.allocator, key) catch {
            self.allocator.free(key);
            return;
        };
        if (gop.found_existing) {
            self.allocator.free(key);
        } else {
            gop.key_ptr.* = key;
        }
        gop.value_ptr.* = info;
    }

    fn removeKnown(self: *Scanner, path: []const u8) void {
        if (self.known.fetchSwapRemove(path)) |kv| {
            self.allocator.free(kv.key);
            self.logger.debug("scanner: removed {s}", .{path});
            self.channel.push(.{ .device_removed = .{ .path = ev.FixedStr(160).fromSlice(path) } });
        }
    }

    fn buildInfo(self: *Scanner, dev: *c.struct_udev_device) ?ev.DeviceInfo {
        var info = ev.DeviceInfo{};

        const syspath = c.udev_device_get_syspath(dev) orelse return null;
        info.key.path.set(std.mem.span(syspath));

        info.vid = parseHexU16(sysattr(dev, "idVendor")) orelse return null;
        info.pid = parseHexU16(sysattr(dev, "idProduct")) orelse return null;
        info.bus = parseDecU8(sysattr(dev, "busnum")) orelse 0;
        info.devnum = parseDecU8(sysattr(dev, "devnum")) orelse 0;
        if (sysattr(dev, "manufacturer")) |s| info.manufacturer.set(s);
        if (sysattr(dev, "product")) |s| info.product.set(s);
        if (sysattr(dev, "serial")) |s| info.serial.set(s);

        // Interface descriptor from the cache, when interface events have
        // been processed for this device.
        const ifc: ?InterfaceInfo = blk: {
            if (self.ifaces.fetchRemove(info.key.path.slice())) |kv| {
                self.allocator.free(kv.key);
                break :blk kv.value;
            }
            break :blk null;
        };
        if (ifc) |i| {
            info.mode = proto.classify(.{
                .vid = info.vid,
                .pid = info.pid,
                .interface_class = i.class,
                .interface_subclass = i.subclass,
                .interface_protocol = i.protocol,
            });
        } else {
            info.mode = proto.classify(.{ .vid = info.vid, .pid = info.pid });
        }
        return info;
    }
};

const InterfaceInfo = struct {
    class: ?u8,
    subclass: ?u8,
    protocol: ?u8,
};

/// Read the first child interface's class attributes straight from sysfs
/// (children of a usb_device node are named like "1-2:1.0"). libc-based so
/// it works from the scanner thread without the new Io handle.
fn readFirstInterface(syspath: []const u8) ?InterfaceInfo {
    const c_dirent = @cImport({
        @cInclude("dirent.h");
    });
    var spbuf: [std.fs.max_path_bytes]u8 = undefined;
    const spz = std.fmt.bufPrintZ(&spbuf, "{s}", .{syspath}) catch return null;
    const dir = c_dirent.opendir(spz.ptr) orelse return null;
    defer _ = c_dirent.closedir(dir);

    while (true) {
        const entry = c_dirent.readdir(dir) orelse return null;
        const name = std.mem.span(entry.name);
        if (std.mem.indexOfScalar(u8, name, ':') == null) continue;
        if (readHexSysattrFile(spz, name, "bInterfaceClass")) |class| {
            return .{
                .class = class,
                .subclass = readHexSysattrFile(spz, name, "bInterfaceSubClass"),
                .protocol = readHexSysattrFile(spz, name, "bInterfaceProtocol"),
            };
        }
    }
}

fn readHexSysattrFile(syspath: [:0]const u8, child: []const u8, attr: []const u8) ?u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pbuf, "{s}/{s}/{s}", .{ syspath, child, attr }) catch return null;
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var buf: [32]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    buf[n] = 0;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.fmt.parseInt(u8, trimmed, 16) catch null;
}

fn sysattr(dev: *c.struct_udev_device, name: [*c]const u8) ?[]const u8 {
    const v = c.udev_device_get_sysattr_value(dev, name) orelse return null;
    return std.mem.span(v);
}

fn parseHexU16(s: ?[]const u8) ?u16 {
    const str = std.mem.trim(u8, s orelse return null, " \t\r\n");
    return std.fmt.parseInt(u16, str, 16) catch null;
}

fn parseDecU8(s: ?[]const u8) ?u8 {
    const str = std.mem.trim(u8, s orelse return null, " \t\r\n");
    return std.fmt.parseInt(u8, str, 10) catch null;
}

fn glibMonoNow() i64 {
    return glib.getMonotonicTime();
}

test "classify registry route check" {
    // Covered in protocol.zig tests; here just ensure the registry imports.
    try std.testing.expect(proto.registry.len >= 1);
}
