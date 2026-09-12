//! Hot-plug device scanner built on libudev.
//!
//! Enumerates existing USB devices once, then watches the udev netlink
//! socket; every discovered device is run through the protocol registry's
//! classifier and surfaced on the event channel (device_added /
//! device_removed). A slow periodic re-enumeration covers races the monitor
//! can miss. All state lives on the scanner thread; the UI only sees events.

const std = @import("std");
const c = @cImport({
    @cInclude("libudev.h");
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

    pub fn init(allocator: std.mem.Allocator, logger: *log.Logger, channel: *EventChannel) !*Scanner {
        const self = try allocator.create(Scanner);
        errdefer allocator.destroy(self);

        const udev = c.udev_new() orelse return error.UdevInitFailed;
        errdefer c.udev_unref(udev);

        const monitor = c.udev_monitor_new_from_netlink(udev, "udev") orelse return error.UdevMonitorFailed;
        errdefer c.udev_monitor_unref(monitor);
        _ = c.udev_monitor_filter_add_match_subsystem_devtype(monitor, "usb", "usb_device");
        _ = c.udev_monitor_enable_receiving(monitor);

        self.* = .{
            .allocator = allocator,
            .logger = logger,
            .channel = channel,
            .udev = udev,
            .monitor = monitor,
            .monitor_fd = c.udev_monitor_get_fd(monitor),
        };
        return self;
    }

    pub fn start(self: *Scanner) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *Scanner) void {
        self.stopping.store(true, .release);
        if (self.thread) |t| t.join();
        for (self.known.keys()) |k| self.allocator.free(k);
        self.known.deinit(self.allocator);
        if (self.monitor) |m| c.udev_monitor_unref(m);
        if (self.udev) |u| c.udev_unref(u);
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
            const ready = std.posix.poll(&fds, 300) catch 0;
            if (ready > 0) {
                while (true) {
                    const dev = c.udev_monitor_receive_device(self.monitor) orelse break;
                    defer c.udev_device_unref(dev);
                    self.handleDevice(dev);
                }
            }
            // Periodic re-enumeration to cover missed/racy events.
            const now = glibMonoNow();
            if (now - last_enum > 2 * std.time.us_per_s) {
                last_enum = now;
                self.enumerate();
            }
        }
        self.logger.debug("scanner: stopped", .{});
    }

    fn enumerate(self: *Scanner) void {
        const e = c.udev_enumerate_new(self.udev) orelse return;
        defer c.udev_enumerate_unref(e);
        _ = c.udev_enumerate_add_match_subsystem(e, "usb");
        if (c.udev_enumerate_scan_devices(e) != 0) return;

        var it = c.udev_enumerate_get_list_entry(e);
        while (it != null) : (it = c.udev_list_entry_get_next(it)) {
            const syspath = c.udev_list_entry_get_name(it) orelse continue;
            const dev = c.udev_device_new_from_syspath(self.udev, syspath) orelse continue;
            defer c.udev_device_unref(dev);
            self.handleDevice(dev);
        }
    }

    /// Process one udev device (from enumeration or monitor). Interfaces
    /// (devtype usb_interface) are ignored; only usb_device nodes classify.
    fn handleDevice(self: *Scanner, dev: *c.struct_udev_device) void {
        const devtype = c.udev_device_get_devtype(dev) orelse return;
        if (!std.mem.eql(u8, std.mem.span(devtype), "usb_device")) return;

        const syspath = c.udev_device_get_syspath(dev) orelse return;
        const action = c.udev_device_get_action(dev) orelse "add";
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

    fn removeKnown(self: *Scanner, path: []const u8) void {
        if (self.known.fetchSwapRemove(path)) |kv| {
            self.allocator.free(kv.key);
            self.logger.debug("scanner: removed {s}", .{path});
            self.channel.push(.{ .device_removed = .{ .path = ev.FixedStr(160).fromSlice(path) } });
        }
    }

    fn buildInfo(self: *Scanner, dev: *c.struct_udev_device) ?ev.DeviceInfo {
        _ = self;
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

        // First child interface's descriptor, when the sysfs nodes are there.
        const ifc = readFirstInterface(info.key.path.slice());
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
/// (children of a usb_device node are named like "1-2:1.0").
fn readFirstInterface(syspath: []const u8) ?InterfaceInfo {
    var dir = std.fs.openDirAbsolute(syspath, .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.indexOfScalar(u8, entry.name, ':') == null) continue;

        var sub = dir.openDir(entry.name, .{}) catch continue;
        defer sub.close();
        const class = readHexSysattr(&sub, "bInterfaceClass");
        if (class == null) continue;
        return .{
            .class = class,
            .subclass = readHexSysattr(&sub, "bInterfaceSubClass"),
            .protocol = readHexSysattr(&sub, "bInterfaceProtocol"),
        };
    }
    return null;
}

fn readHexSysattr(dir: *std.fs.Dir, name: []const u8) ?u8 {
    var buf: [32]u8 = undefined;
    const contents = dir.readFile(name, &buf) catch return null;
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
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
    const glib = @import("glib");
    return glib.getMonotonicTime();
}

test "classify registry route check" {
    // Covered in protocol.zig tests; here just ensure the registry imports.
    try std.testing.expect(proto.registry.len >= 1);
}
