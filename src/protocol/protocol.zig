//! Protocol plugin interface and registry.
//!
//! A protocol module plugs in by exporting a `Protocol` value: it owns the
//! USB match policy (how to recognize and open its devices) and the
//! classification of a discovered USB device into a user-facing ModeTag.
//! The registry currently carries qualcomm, samsung, lg, mtk and spd;
//! adding a module touches nothing outside protocol/.

const core_event = @import("../core/event.zig");

pub const ModeTag = core_event.ModeTag;

/// Everything the classifier may look at, gathered by the device scanner from
/// sysfs/udev. Interface values are from the device's (first) interface and
/// may be null if the interface nodes were not readable yet.
pub const ClassifyInput = struct {
    vid: u16,
    pid: u16,
    interface_class: ?u8 = null,
    interface_subclass: ?u8 = null,
    interface_protocol: ?u8 = null,
    has_bulk_pair: bool = false,
};

pub const Protocol = struct {
    /// Short machine name ("qualcomm", "mtk", ...).
    name: []const u8,
    /// User-facing module name.
    display_name: []const u8,
    /// Classify a discovered USB device. Return .unknown to decline it.
    classify: *const fn (input: ClassifyInput) ModeTag,
};

/// The plugin registry. Order matters only for overlapping classifiers.
pub const registry = [_]Protocol{
    @import("qualcomm/usb_ids.zig").protocol,
    @import("samsung/usb_ids.zig").protocol,
    @import("lg/usb_ids.zig").protocol,
    @import("mtk/usb_ids.zig").protocol,
    @import("spd/usb_ids.zig").protocol,
};

/// Run the registry over a discovered device; first non-unknown wins.
pub fn classify(input: ClassifyInput) ModeTag {
    for (registry) |p| {
        const tag = p.classify(input);
        if (tag != .unknown) return tag;
    }
    return .unknown;
}

test "classify dispatches to the owning protocol" {
    const edl = classify(.{ .vid = 0x05c6, .pid = 0x9008 });
    try std.testing.expectEqual(ModeTag.qualcomm_edl, edl);
    const crash = classify(.{ .vid = 0x05c6, .pid = 0x900e });
    try std.testing.expectEqual(ModeTag.qualcomm_crash, crash);
    const not_ours = classify(.{ .vid = 0x1d6b, .pid = 0x0002 });
    try std.testing.expectEqual(ModeTag.unknown, not_ours);
}

const std = @import("std");
