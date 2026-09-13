test {
    _ = @import("core/log.zig");
    _ = @import("core/event.zig");
    _ = @import("core/util.zig");
    _ = @import("core/fileio.zig");
    _ = @import("transport/transport.zig");
    _ = @import("transport/sim.zig");
    _ = @import("transport/usb.zig");
    _ = @import("protocol/protocol.zig");
    _ = @import("protocol/qualcomm/usb_ids.zig");
    _ = @import("protocol/qualcomm/xml.zig");
    _ = @import("protocol/qualcomm/rawprogram.zig");
    _ = @import("protocol/qualcomm/sahara.zig");
    _ = @import("protocol/qualcomm/firehose.zig");
    _ = @import("firmware/sparse.zig");
    _ = @import("firmware/updateapp.zig");
    _ = @import("protocol/qualcomm/vip.zig");
    _ = @import("protocol/qualcomm/ufs.zig");
    _ = @import("protocol/qualcomm/digestgen.zig");
    _ = @import("protocol/qualcomm/session.zig");
    _ = @import("protocol/qualcomm/gpt.zig");
    _ = @import("protocol/qualcomm/manager.zig");
    _ = @import("device/scanner.zig");
}
