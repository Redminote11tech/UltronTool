//! LG download-mode (LAF) USB identity policy.
//!
//! Ported from Lekensteyn/lglaf: LAF devices enumerate with VID 1004; the
//! G3 (D855) reference uses PID 633e and carries the LAF bulk pair on its
//! CDC-Data interface. Like the official Samsung rule, the interface match
//! is structural (a bulk IN + bulk OUT pair), not class-bound.

const usb = @import("../../transport/usb.zig");
const proto_mod = @import("../protocol.zig");

const std = @import("std");

pub const vendor_id: u16 = 0x1004;
/// LAF / download mode (G2/G3/G4-class devices per the lglaf docs).
pub const pid_laf: u16 = 0x633e;

pub fn matchDevice(desc: usb.DeviceDesc) bool {
    return desc.vid == vendor_id and desc.pid == pid_laf;
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
    if (input.pid != pid_laf) return .unknown;
    return .lg_laf;
}

pub const policy = usb.Policy{
    .matchDevice = matchDevice,
    .matchInterface = matchInterface,
};

pub const protocol = proto_mod.Protocol{
    .name = "lg",
    .display_name = "LG LAF",
    .classify = classify,
};

test "matchInterface accepts the LAF bulk pair" {
    const eps = [_]usb.EndpointDesc{
        .{ .address = 0x81, .attributes = 0x02, .max_packet_size = 512 },
        .{ .address = 0x01, .attributes = 0x02, .max_packet_size = 512 },
    };
    const pair = matchInterface(.{ .class = 0x0a, .subclass = 0x00, .protocol = 0x00, .endpoints = &eps }).?;
    try std.testing.expectEqual(@as(u8, 0x81), pair.in_ep);
    try std.testing.expectEqual(@as(u8, 0x01), pair.out_ep);
}

test "classify tags the LAF PID only" {
    try std.testing.expectEqual(proto_mod.ModeTag.lg_laf, classify(.{ .vid = 0x1004, .pid = 0x633e }));
    // Normal-mode LG devices (ADB/MTP PIDs) must not classify as LAF.
    try std.testing.expectEqual(proto_mod.ModeTag.unknown, classify(.{ .vid = 0x1004, .pid = 0x61f1 }));
    try std.testing.expectEqual(proto_mod.ModeTag.unknown, classify(.{ .vid = 0x04e8, .pid = 0x633e }));
}
