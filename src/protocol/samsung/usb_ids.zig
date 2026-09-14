//! Samsung download-mode USB identity policy.
//!
//! Device rule: VID 04e8 restricted to the download-mode PIDs (the scanner
//! must not tag MTP/ADB phones). Interface rule ported from the OFFICIAL
//! odin4 binary (UsbDeviceImpl constructor, disassembled): no interface
//! class filter — the first interface carrying at least one bulk IN and one
//! bulk OUT wins, taking the LAST bulk endpoint of each direction. (Thor's
//! class-0x0a CDC filter can pick a log/console interface on devices that
//! expose several bulk interfaces; the official tool does not filter.)

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
    // Official odin4 selection: no class filter; the LAST bulk endpoint of
    // each direction on the interface wins.
    var in_ep: ?usb.EndpointDesc = null;
    var out_ep: ?usb.EndpointDesc = null;
    for (ifc.endpoints) |ep| {
        const is_bulk = (ep.attributes & 0x03) == 0x02; // USB transfer type bulk
        if (!is_bulk) continue;
        if (ep.address & 0x80 != 0) {
            in_ep = ep;
        } else {
            out_ep = ep;
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

test "matchInterface accepts any class with a bulk pair" {
    const eps = [_]usb.EndpointDesc{
        .{ .address = 0x81, .attributes = 0x02, .max_packet_size = 512 },
        .{ .address = 0x01, .attributes = 0x02, .max_packet_size = 512 },
    };
    const pair = matchInterface(.{ .class = 0x0a, .subclass = 0x00, .protocol = 0x00, .endpoints = &eps }).?;
    try std.testing.expectEqual(@as(u8, 0x81), pair.in_ep);
    try std.testing.expectEqual(@as(u8, 0x01), pair.out_ep);
    // Vendor-specific interfaces are equally valid (official odin4 behavior).
    const pair2 = matchInterface(.{ .class = 0xff, .subclass = 0x02, .protocol = 0x01, .endpoints = &eps }).?;
    try std.testing.expectEqual(@as(u8, 0x81), pair2.in_ep);
}

test "matchInterface takes the last bulk endpoint of each direction" {
    const eps = [_]usb.EndpointDesc{
        .{ .address = 0x81, .attributes = 0x02, .max_packet_size = 512 },
        .{ .address = 0x02, .attributes = 0x02, .max_packet_size = 512 },
        .{ .address = 0x83, .attributes = 0x02, .max_packet_size = 512 },
        .{ .address = 0x03, .attributes = 0x02, .max_packet_size = 512 },
    };
    const pair = matchInterface(.{ .class = 0x0a, .subclass = 0x00, .protocol = 0x00, .endpoints = &eps }).?;
    try std.testing.expectEqual(@as(u8, 0x83), pair.in_ep);
    try std.testing.expectEqual(@as(u8, 0x03), pair.out_ep);
}

test "matchInterface rejects interfaces without both bulk directions" {
    const irq_only = [_]usb.EndpointDesc{
        .{ .address = 0x82, .attributes = 0x03, .max_packet_size = 64 },
    };
    try std.testing.expectEqual(@as(?usb.EpPair, null), matchInterface(.{ .class = 0x02, .subclass = 0x02, .protocol = 0x01, .endpoints = &irq_only }));
    const out_only = [_]usb.EndpointDesc{
        .{ .address = 0x01, .attributes = 0x02, .max_packet_size = 512 },
    };
    try std.testing.expectEqual(@as(?usb.EpPair, null), matchInterface(.{ .class = 0x0a, .subclass = 0x00, .protocol = 0x00, .endpoints = &out_only }));
}

test "classify tags download-mode PIDs only" {
    try std.testing.expectEqual(proto_mod.ModeTag.samsung_odin, classify(.{ .vid = 0x04e8, .pid = 0x685d }));
    try std.testing.expectEqual(proto_mod.ModeTag.samsung_odin, classify(.{ .vid = 0x04e8, .pid = 0x6601 }));
    try std.testing.expectEqual(proto_mod.ModeTag.samsung_odin, classify(.{ .vid = 0x04e8, .pid = 0x68c3 }));
    // Normal-mode phone (MTP) must not classify as download mode.
    try std.testing.expectEqual(proto_mod.ModeTag.unknown, classify(.{ .vid = 0x04e8, .pid = 0x6860 }));
    try std.testing.expectEqual(proto_mod.ModeTag.unknown, classify(.{ .vid = 0x05c6, .pid = 0x685d }));
}
