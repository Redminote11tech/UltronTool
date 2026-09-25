//! ultron-daemon entry point. The executable's module root is src/ so the
//! IPC layer can import core/transport/protocol modules; the actual daemon
//! lives in ipc/daemon.zig. No CLI: arguments are rejected there.

const daemon = @import("ipc/daemon.zig");

pub fn main(init: std.process.Init) !void {
    try daemon.daemonMain(init);
}

const std = @import("std");
