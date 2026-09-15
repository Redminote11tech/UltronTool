//! MediaTek download-mode USB identity policy.
//!
//! BROM (0e8d:0003) and preloader (0e8d:2000/2001) VCOM devices per the
//! roadmap's detection table; the interface rule is structural (one bulk
//! IN + one bulk OUT), matching mtkclient's CDC-Data usage.

const usb = @import("../../transport/usb.zig");
const proto_mod = @import("../protocol.zig");

const std = @import("std");

pub const vendor_id: u16 = 0x0e8d;
pub const pid_brom: u16 = 0x0003;
pub const pid_preloader: u16 = 0x2000;
pub const pid_preloader_alt: u16 = 0x2001;

fn isDownloadPid(pid: u16) bool {
    return pid == pid_brom or pid == pid_preloader or pid == pid_preloader_alt;
}

pub fn matchDevice(desc: usb.DeviceDesc) bool {
    return desc.vid == vendor_id and isDownloadPid(desc.pid);
}

pub fn matchInterface(ifc: usb.InterfaceDesc) ?usb.EpPair {
    var in_ep: ?usb.EndpointDesc = null;
    var out_ep: ?usb.EndpointDesc = null;
    for (ifc.endpoints) |ep| {
        const is_bulk = (ep.attributes & 0x03) == 0x02;
        if (!is_bulk) continue;
        if (ep.address & 0x80 != 0) {
            if (in_ep == null) in_ep = ep;
        } else {
            if (out_ep == null) out_ep = ep;
        }
    }

    const i = in_ep orelse return null;
    const o = out_ep orelse return null;
    if (i.max_packet_size == 0 or o.max_packet_size == 0) return null;

    return .{
        .interface_number = 0, // filled in from the descriptor by usb.open
        .in_ep = i.address,
        .out_ep = o.address,
        .in_max = i.max_packet_size,
        .out_max = o.max_packet_size,
    };
}

fn classify(input: proto_mod.ClassifyInput) proto_mod.ModeTag {
    if (input.vid != vendor_id) return .unknown;
    return switch (input.pid) {
        pid_brom => .mtk_brom,
        pid_preloader, pid_preloader_alt => .mtk_preloader,
        else => .unknown,
    };
}

pub const policy = usb.Policy{
    .matchDevice = matchDevice,
    .matchInterface = matchInterface,
};

pub const protocol = proto_mod.Protocol{
    .name = "mtk",
    .display_name = "MediaTek",
    .classify = classify,
};

test "classify tags brom and preloader PIDs" {
    try std.testing.expectEqual(proto_mod.ModeTag.mtk_brom, classify(.{ .vid = 0x0e8d, .pid = 0x0003 }));
    try std.testing.expectEqual(proto_mod.ModeTag.mtk_preloader, classify(.{ .vid = 0x0e8d, .pid = 0x2000 }));
    try std.testing.expectEqual(proto_mod.ModeTag.mtk_preloader, classify(.{ .vid = 0x0e8d, .pid = 0x2001 }));
    // Normal-mode MTK devices must not classify.
    try std.testing.expectEqual(proto_mod.ModeTag.unknown, classify(.{ .vid = 0x0e8d, .pid = 0x1234 }));
}

test "matchInterface accepts a bulk pair" {
    const eps = [_]usb.EndpointDesc{
        .{ .address = 0x81, .attributes = 0x02, .max_packet_size = 512 },
        .{ .address = 0x01, .attributes = 0x02, .max_packet_size = 512 },
    };
    const pair = matchInterface(.{ .class = 0x0a, .subclass = 0x00, .protocol = 0x00, .endpoints = &eps }).?;
    try std.testing.expectEqual(@as(u8, 0x81), pair.in_ep);
    try std.testing.expectEqual(@as(u8, 0x01), pair.out_ep);
}
