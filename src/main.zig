//! Ultron — Qualcomm EDL flashing tool (GUI).
//!
//! SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const ui = @import("ui/app.zig");

pub fn main(init: std.process.Init) !void {
    try ui.mainRun(init);
}

test {
    _ = @import("test_root.zig");
}
