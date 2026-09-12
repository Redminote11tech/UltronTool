//! Small shared helpers used by core, protocol and UI layers.

const std = @import("std");

/// "1234567" -> "1.2 MiB" style formatting for progress UI.
pub fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) {
        value /= 1024.0;
        unit += 1;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "…";
}

/// Parse a VID:PID string like "05c6:9008". Returns null on malformed input.
pub fn parseVidPid(s: []const u8) ?struct { vid: u16, pid: u16 } {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    const vid = std.fmt.parseInt(u16, s[0..colon], 16) catch return null;
    const pid = std.fmt.parseInt(u16, s[colon + 1 ..], 16) catch return null;
    return .{ .vid = vid, .pid = pid };
}

test "formatBytes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.0 KiB", formatBytes(&buf, 1024));
    try std.testing.expectEqualStrings("512.0 B", formatBytes(&buf, 512));
}

test "parseVidPid" {
    const got = parseVidPid("05c6:9008").?;
    try std.testing.expectEqual(@as(u16, 0x05c6), got.vid);
    try std.testing.expectEqual(@as(u16, 0x9008), got.pid);
    try std.testing.expectEqual(@as(?@TypeOf(got), null), parseVidPid("nonsense"));
}
