//! Unisoc (Spreadtrum) download-mode USB identity policy.
//!
//! spd_dump opens VID 1782 PID 4d00 (bootrom). Structural bulk-pair
//! interface rule, like the other vendor modules.

const usb = @import("../../transport/usb.zig");
const proto_mod = @import("../protocol.zig");

const std = @import("std");

pub const vendor_id: u16 = 0x1782;
/// Bootrom / BSL download mode (spd_dump's target).
pub const pid_bootrom: u16 = 0x4d00;

pub fn matchDevice(desc: usb.DeviceDesc) bool {
    return desc.vid == vendor_id and desc.pid == pid_bootrom;
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
    if (input.pid != pid_bootrom) return .unknown;
    return .spd_brom;
}

pub const policy = usb.Policy{
    .matchDevice = matchDevice,
    .matchInterface = matchInterface,
};

pub const protocol = proto_mod.Protocol{
    .name = "spd",
    .display_name = "Unisoc",
    .classify = classify,
};

test "classify tags the bootrom PID" {
    try std.testing.expectEqual(proto_mod.ModeTag.spd_brom, classify(.{ .vid = 0x1782, .pid = 0x4d00 }));
    try std.testing.expectEqual(proto_mod.ModeTag.unknown, classify(.{ .vid = 0x1782, .pid = 0x1234 }));
}
