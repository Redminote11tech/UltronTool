//! libusb transport backend — port of linux-msm/qdl src/usb.c (BSD-3-Clause).
//!
//! Semantics preserved exactly:
//!  - writes are split into out_chunk_size transfers, followed by an explicit
//!    zero-length packet when the total length is an exact multiple of the
//!    OUT endpoint's wMaxPacketSize;
//!  - reads issue an extra zero-length read to consume a ZLP when the
//!    transfer filled the buffer with an exact multiple of the IN endpoint's
//!    wMaxPacketSize;
//!  - partial data on timeout is success; Timeout is only returned when
//!    nothing arrived;
//!  - open is a wait loop retrying an enumeration pass every 250 ms.

const std = @import("std");
const transport_mod = @import("transport.zig");
const log = @import("../core/log.zig");

const Transport = transport_mod.Transport;
const Error = transport_mod.Error;
const PacketSizes = transport_mod.PacketSizes;

const c = @cImport({
    @cInclude("libusb.h");
});

/// Plain-description structs the match policy sees (keeps usb.zig
/// protocol-agnostic; qualcomm/usb_ids.zig supplies the Qualcomm policy).
pub const DeviceDesc = struct {
    vid: u16,
    pid: u16,
    product_str: []const u8, // iProduct, ASCII, best effort
};

pub const InterfaceDesc = struct {
    class: u8,
    subclass: u8,
    protocol: u8,
    endpoints: []const EndpointDesc,
};

pub const EndpointDesc = struct {
    address: u8, // bit7 = direction IN
    attributes: u8, // bmAttributes (transfer type in bits 0..1)
    max_packet_size: u16,
};

pub const EpPair = struct {
    interface_number: u8,
    in_ep: u8,
    out_ep: u8,
    in_max: u16,
    out_max: u16,
};

/// Match policy provided by a protocol module (see qualcomm/usb_ids.zig).
pub const Policy = struct {
    /// Device-level check (VID/PID policy).
    matchDevice: *const fn (desc: DeviceDesc) bool,
    /// Interface-level check; returns the bulk endpoint pair to claim, or null.
    matchInterface: *const fn (ifc: InterfaceDesc) ?EpPair,
};

pub const default_out_chunk_size: usize = 1024 * 1024;

pub const Usb = struct {
    handle: *c.libusb_device_handle,
    in_ep: u8,
    out_ep: u8,
    in_maxpktsize: usize,
    out_maxpktsize: usize,
    out_chunk_size: usize = default_out_chunk_size,
    logger: *log.Logger,
    interface_number: u8,
    allocator: std.mem.Allocator,

    pub fn transport(self: *Usb) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Transport.VTable{
        .read = readVt,
        .write = writeVt,
        .close = closeVt,
        .packetSizes = packetSizesVt,
    };

    fn readVt(ptr: *anyopaque, buf: []u8, timeout_ms: u32) Error!usize {
        const self: *Usb = @ptrCast(@alignCast(ptr));
        return self.read(buf, timeout_ms);
    }

    fn writeVt(ptr: *anyopaque, buf: []const u8, timeout_ms: u32) Error!usize {
        const self: *Usb = @ptrCast(@alignCast(ptr));
        return self.write(buf, timeout_ms);
    }

    fn closeVt(ptr: *anyopaque) void {
        const self: *Usb = @ptrCast(@alignCast(ptr));
        self.close();
    }

    fn packetSizesVt(ptr: *anyopaque) PacketSizes {
        const self: *Usb = @ptrCast(@alignCast(ptr));
        return .{ .in_max = self.in_maxpktsize, .out_max = self.out_maxpktsize };
    }

    fn destroyVt(ptr: *anyopaque) void {
        const self: *Usb = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn resetVt(ptr: *anyopaque) void {
        const self: *Usb = @ptrCast(@alignCast(ptr));
        self.logger.info("USB: resetting device (forces a clean EDL re-enumeration)", .{});
        _ = c.libusb_reset_device(self.handle);
    }

    /// Port of usb_read().
    pub fn read(self: *Usb, buf: []u8, timeout_ms: u32) Error!usize {
        if (buf.len == 0) return 0;
        var actual: c_int = 0;
        var ret = c.libusb_bulk_transfer(self.handle, self.in_ep, buf.ptr, @intCast(buf.len), &actual, @intCast(timeout_ms));

        // A stalled IN endpoint (LIBUSB_ERROR_PIPE) is recoverable: clear the
        // halt and retry once. Without this a single stall kills the session.
        if (ret == c.LIBUSB_ERROR_PIPE) {
            self.logger.warn("USB: bulk IN stalled — clearing halt and retrying", .{});
            _ = c.libusb_clear_halt(self.handle, self.in_ep);
            ret = c.libusb_bulk_transfer(self.handle, self.in_ep, buf.ptr, @intCast(buf.len), &actual, @intCast(timeout_ms));
        }

        if (ret != 0 and ret != c.LIBUSB_ERROR_TIMEOUT) {
            self.logger.err("USB bulk read failed: {s} (ep 0x{x})", .{ errName(ret), self.in_ep });
            return if (ret == c.LIBUSB_ERROR_NO_DEVICE) Error.Gone else Error.Io;
        }
        if (ret == c.LIBUSB_ERROR_TIMEOUT and actual == 0) return Error.Timeout;

        // If what we read equals the endpoint's Max Packet Size, consume the
        // ZLP explicitly.
        if (buf.len == @as(usize, @intCast(actual)) and @mod(actual, @as(c_int, @intCast(self.in_maxpktsize))) == 0) {
            const zret = c.libusb_bulk_transfer(self.handle, self.in_ep, null, 0, null, @intCast(timeout_ms));
            if (zret != 0) self.logger.debug("unable to read ZLP: {s}", .{errName(zret)});
        }

        return @intCast(actual);
    }

    /// Port of usb_write().
    pub fn write(self: *Usb, buf: []const u8, timeout_ms: u32) Error!usize {
        var data = buf;
        var count: usize = 0;

        while (data.len > 0) {
            const xfer = @min(data.len, self.out_chunk_size);
            var actual: c_int = 0;
            var ret = c.libusb_bulk_transfer(self.handle, self.out_ep, @constCast(@ptrCast(data.ptr)), @intCast(xfer), &actual, @intCast(timeout_ms));
            if (ret == c.LIBUSB_ERROR_PIPE) {
                self.logger.warn("USB: bulk OUT stalled — clearing halt and retrying", .{});
                _ = c.libusb_clear_halt(self.handle, self.out_ep);
                ret = c.libusb_bulk_transfer(self.handle, self.out_ep, @constCast(@ptrCast(data.ptr)), @intCast(xfer), &actual, @intCast(timeout_ms));
            }
            if (ret != 0 and ret != c.LIBUSB_ERROR_TIMEOUT) {
                self.logger.err("USB bulk write failed: {s} (ep 0x{x})", .{ errName(ret), self.out_ep });
                return if (ret == c.LIBUSB_ERROR_NO_DEVICE) Error.Gone else Error.Io;
            }
            if (ret == c.LIBUSB_ERROR_TIMEOUT and actual == 0) return Error.Timeout;

            const moved: usize = @intCast(actual);
            count += moved;
            data = data[moved..];
        }

        if (buf.len % self.out_maxpktsize == 0) {
            var actual: c_int = 0;
            const ret = c.libusb_bulk_transfer(self.handle, self.out_ep, null, 0, &actual, @intCast(timeout_ms));
            if (ret < 0) return Error.Io;
        }

        return count;
    }

    pub fn close(self: *Usb) void {
        _ = c.libusb_release_interface(self.handle, self.interface_number);
        c.libusb_close(self.handle);
        c.libusb_exit(null);
    }
};

fn errName(ret: c_int) []const u8 {
    const name = c.libusb_error_name(ret);
    if (name == null) return "unknown";
    return std.mem.span(name);
}

/// Iterate all interfaces of all configurations, invoking the policy's
/// interface match until it returns an endpoint pair.
fn findInterface(
    dev: *c.libusb_device,
    desc: *const c.libusb_device_descriptor,
    policy: *const Policy,
) ?EpPair {
    for (0..@intCast(desc.bNumConfigurations)) |ci| {
        var config: ?*c.libusb_config_descriptor = null;
        if (c.libusb_get_config_descriptor(dev, @intCast(ci), &config) != 0) continue;
        defer c.libusb_free_config_descriptor(config);
        const cfg = config.?;

        for (0..@intCast(cfg.bNumInterfaces)) |ii| {
            const libusb_ifc = &cfg.interface[ii]; // altsetting array
            for (0..@intCast(libusb_ifc.num_altsetting)) |ai| {
                const a = &libusb_ifc.altsetting[ai];
                var eps_buf: [16]EndpointDesc = undefined;
                const n_ep = @min(@as(usize, a.bNumEndpoints), eps_buf.len);
                for (0..n_ep) |ei| {
                    const ep = &a.endpoint[ei];
                    eps_buf[ei] = .{
                        .address = ep.bEndpointAddress,
                        .attributes = ep.bmAttributes,
                        .max_packet_size = ep.wMaxPacketSize,
                    };
                }
                const ifc = InterfaceDesc{
                    .class = a.bInterfaceClass,
                    .subclass = a.bInterfaceSubClass,
                    .protocol = a.bInterfaceProtocol,
                    .endpoints = eps_buf[0..n_ep],
                };
                if (policy.matchInterface(ifc)) |pair| {
                    var p = pair;
                    p.interface_number = a.bInterfaceNumber;
                    return p;
                }
            }
        }
    }
    return null;
}

/// Read the iProduct string descriptor as ASCII. Empty slice on failure.
fn readProductString(handle: *c.libusb_device_handle, desc: *const c.libusb_device_descriptor, buf: []u8) []const u8 {
    if (desc.iProduct == 0) return "";
    const n = c.libusb_get_string_descriptor_ascii(handle, desc.iProduct, buf.ptr, @intCast(buf.len));
    if (n < 0) return "";
    return buf[0..@intCast(n)];
}

pub const OpenResult = struct {
    usb: Usb,
    product_str_buf: [128]u8, // the iProduct string of the opened device
    product_len: usize,
};

/// Port of usb_open(): enumerate once per 250 ms until a matching device can
/// be opened, for up to `wait_ms` total. When `target` is given, bus/devnum
/// must match exactly and the serial token after "_SN:" in iProduct
/// (qdl's usb_read_serial policy) must equal the requested serial.
pub fn open(
    policy: *const Policy,
    target: ?transport_mod.Target,
    wait_ms: u32,
    logger: *log.Logger,
    alloc: std.mem.Allocator,
    cancel: ?*const std.atomic.Value(bool),
) Error!Usb {
    const glib = @import("glib");
    const deadline = glib.getMonotonicTime() + @as(i64, wait_ms) * std.time.us_per_ms;
    while (true) {
        if (cancel) |cancel_flag| {
            if (cancel_flag.load(.acquire)) return Error.Cancelled;
        }
        if (openOnce(policy, target, logger, alloc)) |usb| return usb else |err| {
            if (err != Error.NoDevice and err != Error.Busy) return err;
            if (glib.getMonotonicTime() >= deadline) return err;
            glib.usleep(250 * std.time.us_per_ms);
        }
    }
}

/// Port of usb_open_once(): one enumeration pass. NoDevice when nothing
/// matched, Busy when a candidate was visible but unopenable.
fn openOnce(policy: *const Policy, target: ?transport_mod.Target, logger: *log.Logger, alloc: std.mem.Allocator) Error!Usb {
    if (c.libusb_init(null) != 0) return Error.Io;
    errdefer c.libusb_exit(null);

    // libusb_device is opaque to cImport, so carry the list as void pointers
    // and only cast each element to the opaque device type on use.
    var list: [*c]?*anyopaque = null;
    const n = c.libusb_get_device_list(null, @ptrCast(&list));
    if (n < 0) return Error.Io;
    defer _ = c.libusb_free_device_list(@ptrCast(list), 1);

    var saw_candidate = false;

    var li: usize = 0;
    while (li < @as(usize, @intCast(n))) : (li += 1) {
        const dev_opt = list[li] orelse continue;
        const dev: *c.libusb_device = @ptrCast(@alignCast(dev_opt));
        var desc: c.libusb_device_descriptor = undefined;
        if (c.libusb_get_device_descriptor(dev, &desc) != 0) continue;

        const ddesc = DeviceDesc{ .vid = desc.idVendor, .pid = desc.idProduct, .product_str = "" };
        if (!policy.matchDevice(ddesc)) continue;

        saw_candidate = true;

        if (tryOpenCandidate(dev, &desc, policy, target, logger, alloc)) |usb| return usb;
    }

    return if (saw_candidate) Error.Busy else Error.NoDevice;
}

/// Open one enumerated candidate; null means "not usable, keep scanning".
/// Closes the handle on every failure path.
fn tryOpenCandidate(
    dev: *c.libusb_device,
    desc: *const c.libusb_device_descriptor,
    policy: *const Policy,
    target: ?transport_mod.Target,
    logger: *log.Logger,
    alloc: std.mem.Allocator,
) ?Usb {
    // Bus/address filter: cheapest check, before descriptor round-trips.
    if (target) |t| {
        if (t.bus != null or t.devnum != null) {
            const b: u32 = c.libusb_get_bus_number(dev);
            const a: u32 = c.libusb_get_device_address(dev);
            if (t.bus != null and t.bus.? != b) return null;
            if (t.devnum != null and t.devnum.? != a) return null;
        }
    }

    var handle: ?*c.libusb_device_handle = null;
    if (c.libusb_open(dev, &handle) != 0) {
        logger.debug("USB: unable to open candidate device {x:0>4}:{x:0>4}", .{ desc.idVendor, desc.idProduct });
        return null;
    }
    var product_buf: [128]u8 = undefined;
    const product = readProductString(handle.?, desc, &product_buf);

    // Serial filter: token after "_SN:" in iProduct.
    if (target) |t| {
        if (t.serial) |want| {
            const got = serialFromProduct(product);
            if (!std.mem.eql(u8, got, want)) {
                logger.debug("USB: serial mismatch ({s} != {s})", .{ got, want });
                c.libusb_close(handle);
                handle = null;
                return null;
            }
        }
    }

    const pair = findInterface(dev, desc, policy) orelse {
        c.libusb_close(handle);
        handle = null;
        return null;
    };

    // Detach any kernel driver, then claim.
    if (c.libusb_kernel_driver_active(handle.?, pair.interface_number) == 1) {
        _ = c.libusb_detach_kernel_driver(handle.?, pair.interface_number);
    }
    if (c.libusb_claim_interface(handle.?, pair.interface_number) != 0) {
        logger.debug("USB: failed to claim interface {d}", .{pair.interface_number});
        c.libusb_close(handle);
        handle = null;
        return null;
    }

    var usb = Usb{
        .handle = handle.?,
        .in_ep = pair.in_ep,
        .out_ep = pair.out_ep,
        .in_maxpktsize = pair.in_max,
        .out_maxpktsize = pair.out_max,
        .interface_number = pair.interface_number,
        .logger = logger,
        .allocator = alloc,
    };
    if (usb.out_chunk_size % usb.out_maxpktsize != 0) {
        logger.warn("out-chunk-size must be a multiple of wMaxPacketSize {d}; using {d}", .{ usb.out_maxpktsize, usb.out_maxpktsize });
        usb.out_chunk_size = usb.out_maxpktsize;
    }
    logger.debug("USB: using out-chunk-size of {d}", .{usb.out_chunk_size});
    return usb;
}

/// Extract the serial token from iProduct: everything after "_SN:", truncated
/// at the first space or underscore (port of qdl's usb_read_serial).
pub fn serialFromProduct(product: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, product, "_SN:") orelse return "";
    var tail = product[idx + 4 ..];
    if (std.mem.indexOfAny(u8, tail, " _")) |end| tail = tail[0..end];
    return tail;
}

test "serialFromProduct parses qdl-style strings" {
    try std.testing.expectEqualStrings("abc123", serialFromProduct("QUSB_BULK_SN:abc123"));
    try std.testing.expectEqualStrings("abc", serialFromProduct("QUSB_BULK_SN:abc def"));
    try std.testing.expectEqualStrings("abc", serialFromProduct("QUSB_BULK_SN:abc_x"));
    try std.testing.expectEqualStrings("", serialFromProduct("no serial here"));
}
