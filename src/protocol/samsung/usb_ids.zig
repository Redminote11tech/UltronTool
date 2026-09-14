//! Samsung download-mode USB identity policy.
//!
//! Ported from TheAirBlow.Thor.Library Platform/Linux.cs (MIT): the device
//! in Odin download mode exposes a CDC-Data interface (class 0x0a) with one
//! bulk IN + one bulk OUT. Thor matches every Samsung VID, but the scanner
//! sees phones in normal mode too (MTP/ADB share the vendor id), so the
//! device-level rule is restricted to the download-mode PIDs.

const usb = @import("../../transport/usb.zig");
const proto_mod = @import("../protocol.zig");

const std = @import("std");

pub const vendor_id: u16 = 0x04e8;

/// Odin download-mode PIDs (classic Loke, older download mode, modem
/// download mode). Normal-mode PIDs (MTP/ADB/…) must not classify here.
pub const pid_odin: u16 = 0x685d;
pub const pid_odin_legacy: u16 = 0x6601;
pub const pid_odin_modem: u16 = 0x68c3;

fn isDownloadModePid(pid: u16) bool {
    return pid == pid_odin or pid == pid_odin_legacy or pid == pid_odin_modem;
}

pub fn matchDevice(desc: usb.DeviceDesc) bool {
    return desc.vid == vendor_id and isDownloadModePid(desc.pid);
}

pub fn matchInterface(ifc: usb.InterfaceDesc) ?usb.EpPair {
    // USB_CLASS_CDC_DATA — the interface Loke serves the Odin protocol on.
    if (ifc.class != 0x0a) return null;

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
    if (!isDownloadModePid(input.pid)) return .unknown;
    return .samsung_odin;
}

pub const policy = usb.Policy{
    .matchDevice = matchDevice,
    .matchInterface = matchInterface,
};

pub const protocol = proto_mod.Protocol{
    .name = "samsung",
    .display_name = "Samsung Odin",
    .classify = classify,
};

test "matchInterface accepts the CDC-Data bulk pair" {
    const eps = [_]usb.EndpointDesc{
        .{ .address = 0x81, .attributes = 0x02, .max_packet_size = 512 },
        .{ .address = 0x01, .attributes = 0x02, .max_packet_size = 512 },
    };
    const pair = matchInterface(.{ .class = 0x0a, .subclass = 0x00, .protocol = 0x00, .endpoints = &eps }).?;
    try std.testing.expectEqual(@as(u8, 0x81), pair.in_ep);
    try std.testing.expectEqual(@as(u8, 0x01), pair.out_ep);
}

test "matchInterface rejects other interface classes" {
    const bulk = [_]usb.EndpointDesc{
        .{ .address = 0x81, .attributes = 0x02, .max_packet_size = 512 },
        .{ .address = 0x01, .attributes = 0x02, .max_packet_size = 512 },
    };
    try std.testing.expectEqual(@as(?usb.EpPair, null), matchInterface(.{ .class = 0xff, .subclass = 0x02, .protocol = 0x01, .endpoints = &bulk }));
}

test "classify tags download-mode PIDs only" {
    try std.testing.expectEqual(proto_mod.ModeTag.samsung_odin, classify(.{ .vid = 0x04e8, .pid = 0x685d }));
    try std.testing.expectEqual(proto_mod.ModeTag.samsung_odin, classify(.{ .vid = 0x04e8, .pid = 0x6601 }));
    try std.testing.expectEqual(proto_mod.ModeTag.samsung_odin, classify(.{ .vid = 0x04e8, .pid = 0x68c3 }));
    // Normal-mode phone (MTP) must not classify as download mode.
    try std.testing.expectEqual(proto_mod.ModeTag.unknown, classify(.{ .vid = 0x04e8, .pid = 0x6860 }));
    try std.testing.expectEqual(proto_mod.ModeTag.unknown, classify(.{ .vid = 0x05c6, .pid = 0x685d }));
}
