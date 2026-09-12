//! Qualcomm EDL USB identity policy.
//!
//! Ported from linux-msm/qdl (BSD-3-Clause): the device-level rule is VID
//! 0x05c6 with *any* PID ("Product ids are deliberately not filtered — EDL,
//! crash-mode and ramdump devices enumerate with a growing set of ids that no
//! allowlist keeps up with", qdl src/usb.c). The interface-level rule is a
//! vendor-specific interface (class 0xff, subclass 0xff) with Sahara
//! protocol codes 0x10/0x11/0x13 on modern devices and 0xff on older ones,

//! exposing exactly one bulk IN + one bulk OUT with non-zero max packet size.

const usb = @import("../../transport/usb.zig");
const proto_mod = @import("../protocol.zig");

const std = @import("std");

pub const vendor_id: u16 = 0x05c6;

/// PIDs with user-facing meaning (informational; the open policy matches VID only).
pub const pid_edl: u16 = 0x9008;
pub const pid_crash_dump: u16 = 0x900e;

pub fn matchDevice(desc: usb.DeviceDesc) bool {
    return desc.vid == vendor_id;
}

pub fn matchInterface(ifc: usb.InterfaceDesc) ?usb.EpPair {
    if (ifc.class != 0xff) return null;
    if (ifc.subclass != 0xff) return null;

    // Sahara is identified by bInterfaceProtocol 0x10, 0x11, or 0x13 on
    // modern devices, and 0xff on older targets.
    const ok_proto = ifc.protocol == 0xff or ifc.protocol == 0x10 or ifc.protocol == 0x11 or ifc.protocol == 0x13;
    if (!ok_proto) return null;

    var in_ep: ?usb.EndpointDesc = null;
    var out_ep: ?usb.EndpointDesc = null;
    for (ifc.endpoints) |ep| {
        const is_bulk = (ep.attributes & 0x03) == 0x02; // USB transfer type bulk
        if (!is_bulk) continue;
        if (ep.address & 0x80 != 0) {
            if (in_ep == null) in_ep = ep;
        } else {
            if (out_ep == null) out_ep = ep;
        }
    }

    // A matching interface is only usable with both bulk endpoints present
    // and non-zero max packet sizes (qdl guards a divide-by-zero here).
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
    if (input.pid == pid_crash_dump) return .qualcomm_crash;
    if (input.pid == pid_edl) return .qualcomm_edl;

    // Other Qualcomm PIDs count as EDL only when they expose the
    // vendor-specific Sahara interface.
    if (input.interface_class == 0xff and input.interface_subclass == 0xff) return .qualcomm_edl;
    return .unknown;
}

pub const policy = usb.Policy{
    .matchDevice = matchDevice,
    .matchInterface = matchInterface,
};

pub const protocol = proto_mod.Protocol{
    .name = "qualcomm",
    .display_name = "Qualcomm EDL",
    .classify = classify,
};

test "matchInterface accepts the Sahara vendor-specific interface" {
    const eps = [_]usb.EndpointDesc{
        .{ .address = 0x81, .attributes = 0x02, .max_packet_size = 512 },
        .{ .address = 0x01, .attributes = 0x02, .max_packet_size = 512 },
    };
    const pair = matchInterface(.{ .class = 0xff, .subclass = 0xff, .protocol = 0x10, .endpoints = &eps }).?;
    try std.testing.expectEqual(@as(u8, 0x81), pair.in_ep);
    try std.testing.expectEqual(@as(u8, 0x01), pair.out_ep);
    try std.testing.expectEqual(@as(u16, 512), pair.in_max);
}

test "matchInterface rejects wrong class, protocol, or missing bulk pair" {
    const bulk = [_]usb.EndpointDesc{
        .{ .address = 0x81, .attributes = 0x02, .max_packet_size = 512 },
        .{ .address = 0x01, .attributes = 0x02, .max_packet_size = 512 },
    };
    try std.testing.expectEqual(@as(?usb.EpPair, null), matchInterface(.{ .class = 0x03, .subclass = 0xff, .protocol = 0x10, .endpoints = &bulk }));
    try std.testing.expectEqual(@as(?usb.EpPair, null), matchInterface(.{ .class = 0xff, .subclass = 0xff, .protocol = 0x02, .endpoints = &bulk }));

    // Interrupt-only endpoints are not usable.
    const irq = [_]usb.EndpointDesc{
        .{ .address = 0x81, .attributes = 0x03, .max_packet_size = 64 },
        .{ .address = 0x01, .attributes = 0x03, .max_packet_size = 64 },
    };
    try std.testing.expectEqual(@as(?usb.EpPair, null), matchInterface(.{ .class = 0xff, .subclass = 0xff, .protocol = 0x10, .endpoints = &irq }));
}
