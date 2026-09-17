//! Ultron GUI — libadwaita window, main workflow page, console, manager
//! wiring and the event/log pumps that keep the UI updated.
//!
//! One merged main page drives the whole workflow:
//!   1. empty state → device detected → Connect
//!   2. needs_loader → choose a programmer file → Upload loader
//!      (devices already running Firehose skip this automatically)
//!   3. firehose_ready → partition table with per-partition Read/Write,
//!      a queued-writes batch (single confirmation), rawprogram XML
//!      flashing, LUN switcher, reset and disconnect
//!
//! Protocol work runs on the manager worker thread; updates arrive through
//! the core event channel drained on a GLib timeout.

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");
const adw = @import("adw");

const log_mod = @import("../core/log.zig");
const ev = @import("../core/event.zig");
const fileio = @import("../core/fileio.zig");
const util = @import("../core/util.zig");
const transport = @import("../transport/transport.zig");
const usb = @import("../transport/usb.zig");
const scanner_mod = @import("../device/scanner.zig");
const manager_mod = @import("../protocol/qualcomm/manager.zig");
const session_mod = @import("../protocol/qualcomm/session.zig");
const firehose = @import("../protocol/qualcomm/firehose.zig");
const digestgen = @import("../protocol/qualcomm/digestgen.zig");
const updateapp = @import("../firmware/updateapp.zig");
const samsungtar = @import("../firmware/samsungtar.zig");
const sparse_mod = @import("../firmware/sparse.zig");
const usb_ids = @import("../protocol/qualcomm/usb_ids.zig");
const samsung_odin = @import("../protocol/samsung/odin.zig");
const samsung_pit = @import("../protocol/samsung/pit.zig");
const samsung_usb_ids = @import("../protocol/samsung/usb_ids.zig");
const lg_laf = @import("../protocol/lg/laf.zig");
const lg_usb_ids = @import("../protocol/lg/usb_ids.zig");
const mtk_brom = @import("../protocol/mtk/brom.zig");
const mtk_daflash = @import("../protocol/mtk/daflash.zig");
const mtk_usb_ids = @import("../protocol/mtk/usb_ids.zig");
const spd_bsl = @import("../protocol/spd/bsl.zig");
const spd_usb_ids = @import("../protocol/spd/usb_ids.zig");
const gpt_mod = @import("../protocol/qualcomm/gpt.zig");
const style = @import("style.zig");

pub const app_id = "io.github.redminote11tech.Ultron";
pub const version = "0.8.1";

const EventChannel = ev.Channel(ev.Event, 256);
const storage_names: [6]?[*:0]const u8 = .{ "ufs", "emmc", "spinor", "nand", "nvme", null };
const storage_values = [_]firehose.StorageType{ .ufs, .emmc, .spinor, .nand, .nvme };
const max_lun_choices = 8;
const lun_names: [max_lun_choices + 1]?[*:0]const u8 = .{
    "LUN 0", "LUN 1", "LUN 2", "LUN 3",
    "LUN 4", "LUN 5", "LUN 6", "LUN 7",
    null,
};

/// What a pending file chooser is for.
const ChooserKind = union(enum) {
    loader: void,
    vip_tables: void,
    xml_add: void,
    digest_xml_add: void,
    digest_out_dir: void,
    ramdump_dir: void,
    ufs_xml: void,
    huawei_app_file: void,
    /// The row AND the LUN it came from are frozen at chooser-open time:
    /// using the dropdown's LUN at response time could read LUN A's offsets
    /// from LUN B.
    read_partition: struct { row: ev.PartitionRow, lun: u32 },
    write_partition: ev.PartitionRow,
    samsung_pit: void,
    samsung_bundle: void,
    spd_fdl1: void,
    spd_fdl2: void,
    spd_write: void,
    mtk_da: void,
    mtk_read: void,
};

/// Payload-size choices for VIP digest generation. 16 KiB is the default
/// because programmers commonly NAK-renegotiate the 1 MiB protocol default —
/// and under VIP the size must be accepted without renegotiation.
const digest_payload_values = [_]usize{ 16384, 65536, 262144, 1048576 };
const digest_payload_names: [digest_payload_values.len + 1]?[*:0]const u8 = .{
    "16384 (16 KiB)", "65536 (64 KiB)", "262144 (256 KiB)", "1048576 (1 MiB)", null,
};

const PendingWrite = struct {
    row: ev.PartitionRow,
    path: []u8, // owned by Ui
    /// LUN the row came from, captured at queue time — the dropdown may
    /// point elsewhere by the time the batch is applied.
    lun: u32,
};

pub const Ui = struct {
    alloc: std.mem.Allocator,
    logger: *log_mod.Logger,
    channel: *EventChannel,
    scanner: ?*scanner_mod.Scanner = null,
    manager: ?*manager_mod.Manager = null,
    app: ?*adw.Application = null,

    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    outstanding: u32 = 0, // jobs in flight on the manager

    device: ?ev.DeviceInfo = null,
    /// All currently visible matching devices (multi-device targeting).
    devices: std.ArrayList(ev.DeviceInfo) = .empty,
    /// User's target choice: null = automatic (first device found).
    selected_key: ?ev.DeviceKey = null,
    session: ev.SessionState = .disconnected,
    parts: ?ev.PartitionsEvent = null,

    programmer_path: ?[]u8 = null, // loader chosen in needs_loader state
    vip_dir: ?[]u8 = null, // optional folder with signed VIP digest tables
    digest_xmls: std.ArrayList([]u8) = .empty, // flash-plan XMLs for digest generation
    digest_dir: ?[]u8 = null, // digest-table output folder
    pending_writes: std.ArrayList(PendingWrite) = .empty,
    xml_paths: std.ArrayList([]u8) = .empty,
    storage: firehose.StorageType = .ufs,
    skip_storage_init: bool = false,
    allow_missing: bool = false,
    ufs_xml_path: ?[]u8 = null,

    // Widget references.
    window: ?*adw.ApplicationWindow = null,
    toast_overlay: ?*adw.ToastOverlay = null,
    cancel_button: ?*gtk.Button = null,
    progress: ?*gtk.ProgressBar = null,
    spinner: ?*gtk.Spinner = null,
    state_chip: ?*gtk.Label = null,
    console_view: ?*gtk.TextView = null,

    // Main page sections.
    status_page: ?*adw.StatusPage = null,
    dev_card: ?*gtk.Box = null,
    dev_mode_label: ?*gtk.Label = null,
    dev_vidpid_label: ?*gtk.Label = null,
    dev_path_label: ?*gtk.Label = null,
    dev_chip_label: ?*gtk.Label = null,
    probe_btn: ?*gtk.Button = null,
    chip_row: ?*gtk.Widget = null,
    connect_btn: ?*gtk.Button = null,
    storage_drop: ?*gtk.DropDown = null,
    device_sel_row: ?*gtk.Widget = null,
    device_sel_slot: ?*gtk.Box = null,
    skip_init_sw: ?*gtk.Switch = null,
    skip_init_row: ?*gtk.Widget = null,

    loader_section: ?*gtk.Widget = null,
    loader_row: ?*adw.ActionRow = null,
    vip_row: ?*adw.ActionRow = null,
    upload_btn: ?*gtk.Button = null,
    digest_row: ?*adw.ActionRow = null,
    digest_dir_row: ?*adw.ActionRow = null,
    digest_payload_drop: ?*gtk.DropDown = null,
    digest_btn: ?*gtk.Button = null,

    ramdump_section: ?*gtk.Widget = null,
    ramdump_dir_row: ?*adw.ActionRow = null,
    ramdump_filter_entry: ?*gtk.Entry = null,
    ramdump_btn: ?*gtk.Button = null,
    ramdump_dir: ?[]u8 = null,

    conn_section: ?*gtk.Widget = null,
    parts_group: ?*adw.PreferencesGroup = null,
    lun_row: ?*gtk.Widget = null,
    lun_drop: ?*gtk.DropDown = null,
    refresh_btn: ?*gtk.Button = null,
    parts_list: ?*gtk.ListBox = null,
    parts_search: ?*gtk.SearchEntry = null,
    parts_empty: ?*gtk.Label = null,
    pending_row: ?*adw.ActionRow = null,
    write_all_btn: ?*gtk.Button = null,
    xml_row: ?*adw.ActionRow = null,
    flash_xml_btn: ?*gtk.Button = null,
    allow_missing_sw: ?*gtk.Switch = null,
    ufs_row: ?*adw.ActionRow = null,
    ufs_finalize_sw: ?*gtk.Switch = null,
    ufs_btn: ?*gtk.Button = null,
    huawei_row: ?*adw.ActionRow = null,
    huawei_btn: ?*gtk.Button = null,
    huawei_path: ?[]u8 = null,
    huawei_entries: ?ev.HuaweiAppEvent = null,
    /// Bumped whenever a new UPDATE.APP is picked; parse results carry the
    /// generation they belong to and stale ones are dropped on arrival.
    huawei_gen: u32 = 0,
    huawei_pending_mappings: ?std.ArrayList(manager_mod.HuaweiMapping) = null,
    reset_btn: ?*gtk.Button = null,
    disconnect_btn: ?*gtk.Button = null,

    chooser: ?ChooserKind = null,
    /// One-shot worker threads (digest generation, UPDATE.APP parse, RAM
    /// dump, chip probe). Handles are kept so shutdown can wait for them
    /// before freeing the Ui/channel/logger they touch; each kind is
    /// spawn-gated by busy(), so at most one of each is ever live.
    digest_thread: ?std.Thread = null,
    huawei_thread: ?std.Thread = null,
    ramdump_thread: ?std.Thread = null,
    probe_thread: ?std.Thread = null,
    samsung_thread: ?std.Thread = null,
    /// Samsung Odin section (download-mode devices).
    samsung_section: ?*gtk.Widget = null,
    /// LG LAF section (download-mode devices).
    lg_section: ?*gtk.Widget = null,
    lg_thread: ?std.Thread = null,
    mtk_section: ?*gtk.Widget = null,
    mtk_thread: ?std.Thread = null,
    mtk_da_row: ?*adw.ActionRow = null,
    mtk_da_path: ?[]u8 = null,
    mtk_da_addr_entry: ?*gtk.Entry = null,
    mtk_da_ready: bool = false,
    /// Chooser routing markers for write-vs-read picks (single dialog at
    /// a time). Cleared unconditionally when a chooser answers.
    mtk_write_pick: bool = false,
    spd_write_pick: bool = false,
    mtk_flash_addr_entry: ?*gtk.Entry = null,
    mtk_flash_size_entry: ?*gtk.Entry = null,
    mtk_stage_path: ?[]u8 = null,
    mtk_stage_addr: u64 = 0,
    mtk_stage_size: u64 = 0,
    spd_section: ?*gtk.Widget = null,
    spd_thread: ?std.Thread = null,
    spd_fdl1_row: ?*adw.ActionRow = null,
    spd_fdl2_row: ?*adw.ActionRow = null,
    spd_addr_entry: ?*gtk.Entry = null,
    spd_size_entry: ?*gtk.Entry = null,
    spd_name_entry: ?*gtk.Entry = null,
    spd_flash_read_btn: ?*gtk.Button = null,
    spd_flash_write_btn: ?*gtk.Button = null,
    spd_flash_erase_btn: ?*gtk.Button = null,
    spd_fdl1_path: ?[]u8 = null,
    spd_fdl2_path: ?[]u8 = null,
    spd_stage_path: ?[]u8 = null,
    /// Staged flash op: address and size (hex text from the entries).
    spd_stage_addr: u32 = 0,
    spd_stage_size: u32 = 0,
    spd_stage_name: ?[]u8 = null,
    /// Image path staged for a Samsung partition flash (consumed by the
    /// confirm dialog on both paths, like the Huawei mapping list).
    samsung_flash_path: ?[]u8 = null,
    /// Staged PIT file / tar.md5 bundle path (same consumption pattern).
    samsung_stage_path: ?[]u8 = null,
    speed_scratch: [32]u8 = undefined,
    prog_last_ms: i64 = 0,
    prog_last_done: u64 = 0,
    /// Set when the window is fully built; event handlers refuse to touch
    /// widgets before that (belt-and-braces against early events).
    ready: bool = false,
    log_seq: u64 = 0,
    log_drop_seen: u64 = 0,

    // Per-partition-row signal contexts, freed when the list is rebuilt.
    row_ctxs: std.ArrayList(*RowCtx) = .empty,

    fn setBusy(self: *Ui, busy_now: bool) void {
        const enable: c_int = @intFromBool(!busy_now);
        inline for (.{ self.connect_btn, self.probe_btn, self.upload_btn, self.write_all_btn, self.flash_xml_btn, self.reset_btn, self.disconnect_btn, self.refresh_btn, self.digest_btn }) |maybe_btn| {
            if (maybe_btn) |b| gtk.Widget.setSensitive(b.as(gtk.Widget), enable);
        }
        if (self.cancel_button) |b| {
            gtk.Widget.setVisible(b.as(gtk.Widget), @intFromBool(busy_now));
            gtk.Widget.setSensitive(b.as(gtk.Widget), 1);
        }
    }

    fn busy(self: *Ui) bool {
        return self.outstanding > 0;
    }

    fn toast(self: *Ui, msg: []const u8) void {
        const overlay = self.toast_overlay orelse return;
        var buf: [256]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{msg}) catch blk: {
            // Too long for the buffer: truncate rather than lose the message.
            const n = buf.len - 1;
            @memcpy(buf[0..n], msg[0..n]);
            buf[n] = 0;
            break :blk buf[0..n :0];
        };
        const t = adw.Toast.new(z.ptr);
        adw.ToastOverlay.addToast(overlay, t);
    }

    fn startJob(self: *Ui) void {
        self.outstanding += 1;
        self.setBusy(true);
        if (self.spinner) |sp| {
            gtk.Spinner.start(sp);
            gtk.Widget.setVisible(sp.as(gtk.Widget), 1);
        }
        if (self.progress) |p| {
            gtk.Widget.setVisible(p.as(gtk.Widget), 0); // appears on first %
            gtk.ProgressBar.setFraction(p, 0);
            gtk.ProgressBar.setText(p, "working…");
        }
    }

    fn jobDone(self: *Ui) void {
        if (self.outstanding > 0) self.outstanding -= 1;
        if (self.outstanding == 0) {
            self.setBusy(false);
            if (self.progress) |p| gtk.Widget.setVisible(p.as(gtk.Widget), 0);
            if (self.spinner) |sp| {
                gtk.Spinner.stop(sp);
                gtk.Widget.setVisible(sp.as(gtk.Widget), 0);
            }
            // Consume the cancel flag: it must never leak into a LATER job
            // (a cancelled probe used to make the next write fail instantly
            // with "Cancelled — disconnecting").
            self.cancel.store(false, .release);
            if (self.cancel_button) |b| gtk.Widget.setSensitive(b.as(gtk.Widget), 1);
        }
    }
};

const WorkerCtx = struct {
    ui: *Ui,
    target: ?transport.Target = null,
    target_serial_buf: ?[]u8 = null,
};

const RowCtx = struct {
    ui: *Ui,
    row: ev.PartitionRow,
    row_widget: ?*gtk.Widget = null,
};

const ConfirmCtx = struct {
    ui: *Ui,
    kind: ConfirmKind,
};

const ConfirmKind = union(enum) {
    apply_writes: void,
    flash_xml: void,
    erase_partition: ev.PartitionRow,
    provision_ufs: void,
    huawei_app: void,
    samsung_flash: ev.PartitionRow,
    samsung_pit: void,
    samsung_bundle: void,
    samsung_factory: void,
    lg_erase: ev.PartitionRow,
    lg_write: ev.PartitionRow,
    spd_write: void,
    spd_erase: void,
    mtk_write: void,
    mtk_format: void,
};

// ----------------------------------------------------------------------
// Entry (called from main.zig)
// ----------------------------------------------------------------------

fn usbOpen(ctx: *anyopaque, logger: *log_mod.Logger, target: ?transport.Target, wait_ms: u32, alloc: std.mem.Allocator) transport.Error!transport.Transport {
    _ = ctx;
    const u = try alloc.create(usb.Usb);
    errdefer alloc.destroy(u);
    // The manager checks its own cancel between transfers; the open retry
    // loop here stays short-lived and uncancellable.
    u.* = try usb.open(&usb_ids.policy, target, wait_ms, logger, alloc, null);
    return u.transport();
}

pub fn mainRun(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;

    const logger = try alloc.create(log_mod.Logger);
    logger.* = .{ .min_level = .info, .mirror_stderr = false };
    for (init.minimal.args.vector) |a| {
        const arg = std.mem.span(a);
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            logger.min_level = .debug;
            logger.mirror_stderr = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            glib.print("ultron %s\n", version);
            return;
        }
    }

    const channel = try alloc.create(EventChannel);
    channel.* = .{};

    const ui = try alloc.create(Ui);
    ui.* = .{ .alloc = alloc, .logger = logger, .channel = channel };

    // Device hot-plug scanner.
    ui.scanner = scanner_mod.Scanner.init(alloc, logger, channel) catch |e| blk: {
        logger.warn("device scanner unavailable: {s}", .{@errorName(e)});
        break :blk null;
    };
    if (ui.scanner) |sc| sc.start() catch {
        logger.warn("failed to start device scanner", .{});
        ui.scanner = null;
    };

    // Persistent Firehose session manager.
    ui.manager = manager_mod.Manager.init(alloc, logger, channel, &ui.cancel, &usbOpen, @ptrCast(logger)) catch |e| blk: {
        logger.warn("session manager unavailable: {s}", .{@errorName(e)});
        break :blk null;
    };
    if (ui.manager) |m| m.start() catch {
        logger.warn("failed to start session manager", .{});
        ui.manager = null;
    };

    const app = adw.Application.new(app_id, .{});
    defer app.unref();
    _ = gio.Application.signals.activate.connect(app, *Ui, &onActivate, ui, .{});
    const status = gio.Application.run(app.as(gio.Application), 0, null);

    // Shutdown: stop the workers, then free UI state only once they are
    // truly gone — they touch ui.alloc, the logger, the channel and cancel.
    ui.cancel.store(true, .release);
    if (ui.digest_thread) |t| t.join();
    if (ui.huawei_thread) |t| t.join();
    if (ui.ramdump_thread) |t| t.join();
    if (ui.probe_thread) |t| t.join();
    if (ui.samsung_thread) |t| t.join();
    if (ui.lg_thread) |t| t.join();
    if (ui.mtk_thread) |t| t.join();
    if (ui.spd_thread) |t| t.join();
    if (ui.manager) |m| m.shutdown();
    if (ui.scanner) |sc| sc.deinit();
    clearPendingWrites(ui);
    ui.pending_writes.deinit(alloc);
    for (ui.xml_paths.items) |p| alloc.free(p);
    ui.xml_paths.deinit(alloc);
    if (ui.programmer_path) |p| alloc.free(p);
    if (ui.vip_dir) |p| alloc.free(p);
    if (ui.ramdump_dir) |p| alloc.free(p);
    if (ui.ufs_xml_path) |p| alloc.free(p);
    if (ui.huawei_path) |p| alloc.free(p);
    freeHuaweiPending(ui);
    for (ui.digest_xmls.items) |p| alloc.free(p);
    ui.digest_xmls.deinit(alloc);
    if (ui.digest_dir) |p| alloc.free(p);
    for (ui.row_ctxs.items) |ctx| alloc.destroy(ctx);
    ui.row_ctxs.deinit(alloc);
    ui.devices.deinit(alloc);
    alloc.destroy(ui);
    alloc.destroy(channel);
    alloc.destroy(logger);

    std.process.exit(@intCast(@mod(status, 256)));
}

fn onActivate(app: *adw.Application, ud: *Ui) callconv(.c) void {
    buildWindow(ud, app);
}

// ----------------------------------------------------------------------
// Window construction
// ----------------------------------------------------------------------

fn buildWindow(ui: *Ui, app: *adw.Application) void {
    loadCss();

    const window = adw.ApplicationWindow.new(app.as(gtk.Application));
    gtk.Window.setTitle(window.as(gtk.Window), "Ultron");
    gtk.Window.setDefaultSize(window.as(gtk.Window), 880, 720);
    ui.window = window;

    const overlay = adw.ToastOverlay.new();
    ui.toast_overlay = overlay;

    const stack = adw.ViewStack.new();
    stackAdd(stack, buildMainPage(ui), "ultron", "Ultron", "phone-symbolic");
    stackAdd(stack, buildConsolePage(ui), "console", "Console", "utilities-terminal-symbolic");

    const switcher = adw.ViewSwitcher.new();
    adw.ViewSwitcher.setStack(switcher, stack);
    adw.ViewSwitcher.setPolicy(switcher, .wide);

    const header = adw.HeaderBar.new();
    adw.HeaderBar.setTitleWidget(header, switcher.as(gtk.Widget));

    // Live operation strip: progress with label inside + cancel — pinned to
    // the header so it is visible no matter where the page is scrolled.
    const progress_box = gtk.Box.new(.horizontal, 8);
    gtk.Widget.setValign(progress_box.as(gtk.Widget), .center);

    const spinner = gtk.Spinner.new();
    gtk.Spinner.setSpinning(spinner, 0);
    gtk.Widget.setVisible(spinner.as(gtk.Widget), 0);
    ui.spinner = spinner;
    gtk.Box.append(progress_box, spinner.as(gtk.Widget));

    const progress = gtk.ProgressBar.new();
    gtk.ProgressBar.setShowText(progress, 1);
    gtk.ProgressBar.setText(progress, "working…");
    gtk.Widget.setSizeRequest(progress.as(gtk.Widget), 260, -1);
    gtk.Widget.setValign(progress.as(gtk.Widget), .center);
    gtk.Widget.addCssClass(progress.as(gtk.Widget), "ultron-progress");
    gtk.Widget.setVisible(progress.as(gtk.Widget), 0);
    ui.progress = progress;
    gtk.Box.append(progress_box, progress.as(gtk.Widget));

    const cancel_button = gtk.Button.newWithLabel("Cancel");
    gtk.Widget.setVisible(cancel_button.as(gtk.Widget), 0);
    _ = gtk.Button.signals.clicked.connect(cancel_button, *Ui, &onCancelClicked, ui, .{});
    ui.cancel_button = cancel_button;
    gtk.Box.append(progress_box, cancel_button.as(gtk.Widget));

    adw.HeaderBar.packEnd(header, progress_box.as(gtk.Widget));

    const toolbar = adw.ToolbarView.new();
    adw.ToolbarView.addTopBar(toolbar, header.as(gtk.Widget));
    adw.ToolbarView.setContent(toolbar, overlay.as(gtk.Widget));
    adw.ToastOverlay.setChild(overlay, stack.as(gtk.Widget));

    // AdwApplicationWindow has no set_child; content is the AdwWindow
    // "content" property.
    var value = std.mem.zeroes(gobject.Value);
    _ = gobject.Value.init(&value, gobject.typeFromName("GtkWidget"));
    gobject.Value.setObject(&value, toolbar.as(gobject.Object));
    gobject.Object.setProperty(window.as(gobject.Object), "content", &value);
    gobject.Value.unset(&value);

    gtk.Window.present(window.as(gtk.Window));

    ui.ready = true;
    // Kick off the pumps.
    _ = glib.timeoutAdd(50, onTick, ui);
    _ = glib.idleAdd(onFirstLogDrain, ui);
}

fn stackAdd(stack: *adw.ViewStack, child: *gtk.Widget, name: [:0]const u8, title: [:0]const u8, icon: [:0]const u8) void {
    const page = adw.ViewStack.add(stack, child);
    adw.ViewStackPage.setName(page, name.ptr);
    adw.ViewStackPage.setTitle(page, title.ptr);
    adw.ViewStackPage.setIconName(page, icon.ptr);
}

var css_loaded = false;
fn loadCss() void {
    if (css_loaded) return;
    css_loaded = true;
    const provider = gtk.CssProvider.new();
    gtk.CssProvider.loadFromString(provider, style.css);
    if (gdk.Display.getDefault()) |display| {
        gtk.StyleContext.addProviderForDisplay(display, provider.as(gtk.StyleProvider), 600);
    }
}

// ----------------------------------------------------------------------
// Main page
// ----------------------------------------------------------------------

fn buildMainPage(ui: *Ui) *gtk.Widget {
    const scrolled = gtk.ScrolledWindow.new();
    gtk.ScrolledWindow.setPolicy(scrolled, .never, .automatic);

    const page = gtk.Box.new(.vertical, 18);
    setMargins(page.as(gtk.Widget), 18, 18, 18, 18);

    // Center the workflow in a readable column on wide windows.
    const clamp = adw.Clamp.new();
    adw.Clamp.setMaximumSize(clamp, 760);
    adw.Clamp.setChild(clamp, page.as(gtk.Widget));
    gtk.ScrolledWindow.setChild(scrolled, clamp.as(gtk.Widget));

    // --- Empty state --------------------------------------------------
    const status = adw.StatusPage.new();
    adw.StatusPage.setIconName(status, "usb-plug-symbolic");
    adw.StatusPage.setTitle(status, "No device detected");
    adw.StatusPage.setDescription(status, "Connect your device in EDL (download) mode.\nOn Qualcomm devices this is 9008 mode — usually holding volume keys while plugging in USB.\nUltron rescans every 500 ms.");
    ui.status_page = status;

    const rescan_btn = gtk.Button.newWithLabel("Rescan");
    gtk.Widget.addCssClass(rescan_btn.as(gtk.Widget), "suggested-action");
    gtk.Widget.addCssClass(rescan_btn.as(gtk.Widget), "pill");
    gtk.Widget.setHalign(rescan_btn.as(gtk.Widget), .center);
    _ = gtk.Button.signals.clicked.connect(rescan_btn, *Ui, &onRescanClicked, ui, .{});
    adw.StatusPage.setChild(status, rescan_btn.as(gtk.Widget));

    ui.status_page = status;
    gtk.Box.append(page, status.as(gtk.Widget));

    // --- Device card (device detected) ---------------------------------
    const dev_card = gtk.Box.new(.vertical, 12);
    ui.dev_card = dev_card;

    const dev_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(dev_group, "Detected device");
    adw.PreferencesGroup.setDescription(dev_group, "Qualcomm Emergency Download mode");

    const mode_row = adw.ActionRow.new();
    rowTitle(mode_row, "Mode");
    const mode_val = gtk.Label.new("-");
    gtk.Widget.addCssClass(mode_val.as(gtk.Widget), "device-badge");
    gtk.Widget.addCssClass(mode_val.as(gtk.Widget), "accent");
    adw.ActionRow.addSuffix(mode_row, mode_val.as(gtk.Widget));
    ui.dev_mode_label = mode_val;
    adw.PreferencesGroup.add(dev_group, mode_row.as(gtk.Widget));

    const state_row = adw.ActionRow.new();
    rowTitle(state_row, "Session");
    const state_chip = gtk.Label.new("not connected");
    gtk.Widget.addCssClass(state_chip.as(gtk.Widget), "state-chip");
    gtk.Widget.addCssClass(state_chip.as(gtk.Widget), "dim");
    adw.ActionRow.addSuffix(state_row, state_chip.as(gtk.Widget));
    ui.state_chip = state_chip;
    adw.PreferencesGroup.add(dev_group, state_row.as(gtk.Widget));

    const vidpid_row = adw.ActionRow.new();
    rowTitle(vidpid_row, "USB device");
    const vidpid_val = gtk.Label.new("-");
    adw.ActionRow.addSuffix(vidpid_row, vidpid_val.as(gtk.Widget));
    ui.dev_vidpid_label = vidpid_val;
    adw.PreferencesGroup.add(dev_group, vidpid_row.as(gtk.Widget));

    const path_row = adw.ActionRow.new();
    rowTitle(path_row, "Sysfs path");
    const path_val = gtk.Label.new("-");
    gtk.Widget.addCssClass(path_val.as(gtk.Widget), "dim-label");
    adw.ActionRow.addSuffix(path_row, path_val.as(gtk.Widget));
    ui.dev_path_label = path_val;
    adw.PreferencesGroup.add(dev_group, path_row.as(gtk.Widget));

    const storage_row = adw.ActionRow.new();
    rowTitle(storage_row, "Storage type");
    const storage_drop = gtk.DropDown.newFromStrings(@ptrCast(&storage_names));
    adw.ActionRow.addSuffix(storage_row, storage_drop.as(gtk.Widget));
    ui.storage_drop = storage_drop;
    adw.PreferencesGroup.add(dev_group, storage_row.as(gtk.Widget));

    const device_sel_row = adw.ActionRow.new();
    rowTitle(device_sel_row, "Target device");
    adw.ActionRow.setSubtitle(device_sel_row, "Multiple EDL devices visible — pick one");
    const device_sel_slot = gtk.Box.new(.horizontal, 8);
    adw.ActionRow.addSuffix(device_sel_row, device_sel_slot.as(gtk.Widget));
    ui.device_sel_row = device_sel_row.as(gtk.Widget);
    ui.device_sel_slot = device_sel_slot;
    gtk.Widget.setVisible(device_sel_row.as(gtk.Widget), 0);
    adw.PreferencesGroup.add(dev_group, device_sel_row.as(gtk.Widget));

    const skip_init_row = adw.ActionRow.new();
    rowTitle(skip_init_row, "Skip storage init");
    adw.ActionRow.setSubtitle(skip_init_row, "Only for unprovisioned UFS devices — leave off otherwise");
    const skip_init_sw = gtk.Switch.new();
    gtk.Widget.setValign(skip_init_sw.as(gtk.Widget), .center);
    adw.ActionRow.addSuffix(skip_init_row, skip_init_sw.as(gtk.Widget));
    ui.skip_init_sw = skip_init_sw;
    ui.skip_init_row = skip_init_row.as(gtk.Widget);
    adw.PreferencesGroup.add(dev_group, skip_init_row.as(gtk.Widget));

    const chip_row = adw.ActionRow.new();
    rowTitle(chip_row, "Sahara chip identity");
    const probe_btn = gtk.Button.newWithLabel("Read chip info");
    _ = gtk.Button.signals.clicked.connect(probe_btn, *Ui, &onProbeClicked, ui, .{});
    adw.ActionRow.addSuffix(chip_row, probe_btn.as(gtk.Widget));
    ui.probe_btn = probe_btn;
    ui.chip_row = chip_row.as(gtk.Widget);
    adw.PreferencesGroup.add(dev_group, chip_row.as(gtk.Widget));

    gtk.Box.append(dev_card, dev_group.as(gtk.Widget));

    const chip_label = gtk.Label.new("Not read yet");
    gtk.Label.setXalign(chip_label, 0);
    gtk.Label.setWrap(chip_label, 1);
    gtk.Widget.addCssClass(chip_label.as(gtk.Widget), "chip-grid");
    ui.dev_chip_label = chip_label;
    gtk.Box.append(dev_card, chip_label.as(gtk.Widget));

    const connect_btn = gtk.Button.newWithLabel("Connect");
    gtk.Widget.addCssClass(connect_btn.as(gtk.Widget), "suggested-action");
    gtk.Widget.addCssClass(connect_btn.as(gtk.Widget), "big-start");
    gtk.Widget.setHalign(connect_btn.as(gtk.Widget), .center);
    _ = gtk.Button.signals.clicked.connect(connect_btn, *Ui, &onConnectClicked, ui, .{});
    ui.connect_btn = connect_btn;
    gtk.Box.append(dev_card, connect_btn.as(gtk.Widget));

    gtk.Widget.setVisible(dev_card.as(gtk.Widget), 0);
    gtk.Box.append(page, dev_card.as(gtk.Widget));

    // --- RAM dump section (crash-dump devices only) ----------------------
    const ramdump_box = gtk.Box.new(.vertical, 12);

    const ramdump_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(ramdump_group, "RAM dump");
    adw.PreferencesGroup.setDescription(ramdump_group, "This device is in crash-dump mode: download its memory regions over Sahara Memory Debug");

    const ramdump_dir_row = adw.ActionRow.new();
    rowTitle(ramdump_dir_row, "Output folder");
    adw.ActionRow.setSubtitle(ramdump_dir_row, "None selected — one file per memory region");
    const ramdump_dir_btn = gtk.Button.newWithLabel("Choose…");
    _ = gtk.Button.signals.clicked.connect(ramdump_dir_btn, *Ui, &onRamdumpPickDir, ui, .{});
    adw.ActionRow.addSuffix(ramdump_dir_row, ramdump_dir_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(ramdump_group, ramdump_dir_row.as(gtk.Widget));
    ui.ramdump_dir_row = ramdump_dir_row;

    const ramdump_filter_row = adw.ActionRow.new();
    rowTitle(ramdump_filter_row, "Segment filter (optional)");
    adw.ActionRow.setSubtitle(ramdump_filter_row, "Comma-separated, * and ? wildcards — empty dumps everything");
    const ramdump_filter_entry = gtk.Entry.new();
    gtk.Widget.setHexpand(ramdump_filter_entry.as(gtk.Widget), 1);
    gtk.Widget.setValign(ramdump_filter_entry.as(gtk.Widget), .center);
    gtk.Entry.setPlaceholderText(ramdump_filter_entry, "OCIMEM,CODERAM");
    adw.ActionRow.addSuffix(ramdump_filter_row, ramdump_filter_entry.as(gtk.Widget));
    adw.PreferencesGroup.add(ramdump_group, ramdump_filter_row.as(gtk.Widget));
    ui.ramdump_filter_entry = ramdump_filter_entry;

    const ramdump_btn = gtk.Button.newWithLabel("Dump RAM…");
    gtk.Widget.addCssClass(ramdump_btn.as(gtk.Widget), "suggested-action");
    gtk.Widget.addCssClass(ramdump_btn.as(gtk.Widget), "big-start");
    gtk.Widget.setHalign(ramdump_btn.as(gtk.Widget), .center);
    gtk.Widget.setSensitive(ramdump_btn.as(gtk.Widget), 0);
    _ = gtk.Button.signals.clicked.connect(ramdump_btn, *Ui, &onRamdumpClicked, ui, .{});
    ui.ramdump_btn = ramdump_btn;

    adw.PreferencesGroup.add(ramdump_group, ramdump_btn.as(gtk.Widget));
    gtk.Box.append(ramdump_box, ramdump_group.as(gtk.Widget));
    gtk.Widget.setVisible(ramdump_box.as(gtk.Widget), 0);
    gtk.Box.append(page, ramdump_box.as(gtk.Widget));
    ui.ramdump_section = ramdump_box.as(gtk.Widget);

    // --- Samsung Odin section (download-mode devices) -------------------
    const samsung_box = gtk.Box.new(.vertical, 12);

    const samsung_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(samsung_group, "Samsung Odin (download mode)");
    adw.PreferencesGroup.setDescription(samsung_group, "Loke handshake, PIT dump and partition flashing over the Odin protocol");

    const samsung_pit_row = adw.ActionRow.new();
    rowTitle(samsung_pit_row, "Partition table (PIT)");
    adw.ActionRow.setSubtitle(samsung_pit_row, "Loads the device PIT into the partition browser");
    const samsung_pit_btn = gtk.Button.newWithLabel("Dump PIT");
    gtk.Widget.addCssClass(samsung_pit_btn.as(gtk.Widget), "suggested-action");
    _ = gtk.Button.signals.clicked.connect(samsung_pit_btn, *Ui, &onSamsungDumpPit, ui, .{});
    adw.ActionRow.addSuffix(samsung_pit_row, samsung_pit_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(samsung_group, samsung_pit_row.as(gtk.Widget));

    const samsung_ctrl_row = adw.ActionRow.new();
    rowTitle(samsung_ctrl_row, "Device control");
    const samsung_ctrl_box = gtk.Box.new(.horizontal, 6);
    gtk.Widget.setValign(samsung_ctrl_box.as(gtk.Widget), .center);
    const samsung_reboot_dl_btn = gtk.Button.newWithLabel("Reboot to download");
    _ = gtk.Button.signals.clicked.connect(samsung_reboot_dl_btn, *Ui, &onSamsungRebootDownload, ui, .{});
    gtk.Box.append(samsung_ctrl_box, samsung_reboot_dl_btn.as(gtk.Widget));
    const samsung_reboot_btn = gtk.Button.newWithLabel("Reboot");
    _ = gtk.Button.signals.clicked.connect(samsung_reboot_btn, *Ui, &onSamsungReboot, ui, .{});
    gtk.Box.append(samsung_ctrl_box, samsung_reboot_btn.as(gtk.Widget));
    adw.ActionRow.addSuffix(samsung_ctrl_row, samsung_ctrl_box.as(gtk.Widget));
    adw.PreferencesGroup.add(samsung_group, samsung_ctrl_row.as(gtk.Widget));

    const samsung_write_row = adw.ActionRow.new();
    rowTitle(samsung_write_row, "Write to device");
    const samsung_write_box = gtk.Box.new(.horizontal, 6);
    gtk.Widget.setValign(samsung_write_box.as(gtk.Widget), .center);
    const samsung_bundle_btn = gtk.Button.newWithLabel("Flash bundle (tar.md5)…");
    gtk.Widget.addCssClass(samsung_bundle_btn.as(gtk.Widget), "destructive-action");
    _ = gtk.Button.signals.clicked.connect(samsung_bundle_btn, *Ui, &onSamsungPickBundle, ui, .{});
    gtk.Box.append(samsung_write_box, samsung_bundle_btn.as(gtk.Widget));
    const samsung_pitflash_btn = gtk.Button.newWithLabel("Flash PIT…");
    gtk.Widget.addCssClass(samsung_pitflash_btn.as(gtk.Widget), "destructive-action");
    _ = gtk.Button.signals.clicked.connect(samsung_pitflash_btn, *Ui, &onSamsungPickPit, ui, .{});
    gtk.Box.append(samsung_write_box, samsung_pitflash_btn.as(gtk.Widget));
    adw.ActionRow.addSuffix(samsung_write_row, samsung_write_box.as(gtk.Widget));
    adw.PreferencesGroup.add(samsung_group, samsung_write_row.as(gtk.Widget));

    const samsung_factory_btn = gtk.Button.newWithLabel("Factory reset (erase userdata)");
    gtk.Widget.addCssClass(samsung_factory_btn.as(gtk.Widget), "destructive-action");
    gtk.Widget.setHalign(samsung_factory_btn.as(gtk.Widget), .start);
    _ = gtk.Button.signals.clicked.connect(samsung_factory_btn, *Ui, &onSamsungFactoryReset, ui, .{});
    adw.PreferencesGroup.add(samsung_group, samsung_factory_btn.as(gtk.Widget));

    gtk.Box.append(samsung_box, samsung_group.as(gtk.Widget));
    gtk.Widget.setVisible(samsung_box.as(gtk.Widget), 0);
    gtk.Box.append(page, samsung_box.as(gtk.Widget));
    ui.samsung_section = samsung_box.as(gtk.Widget);

    // --- LG LAF section (download-mode devices) -------------------------
    const lg_box = gtk.Box.new(.vertical, 12);

    const lg_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(lg_group, "LG download mode (LAF)");
    adw.PreferencesGroup.setDescription(lg_group, "LAF protocol: GPT browsing, partition backup, flash and TRIM erase");

    const lg_gpt_row = adw.ActionRow.new();
    rowTitle(lg_gpt_row, "Partition table (GPT)");
    adw.ActionRow.setSubtitle(lg_gpt_row, "Reads the GPT of the eMMC into the partition browser");
    const lg_gpt_btn = gtk.Button.newWithLabel("Load GPT");
    gtk.Widget.addCssClass(lg_gpt_btn.as(gtk.Widget), "suggested-action");
    _ = gtk.Button.signals.clicked.connect(lg_gpt_btn, *Ui, &onLgLoadGpt, ui, .{});
    adw.ActionRow.addSuffix(lg_gpt_row, lg_gpt_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(lg_group, lg_gpt_row.as(gtk.Widget));

    const lg_ctrl_row = adw.ActionRow.new();
    rowTitle(lg_ctrl_row, "Device control");
    const lg_ctrl_box = gtk.Box.new(.horizontal, 6);
    gtk.Widget.setValign(lg_ctrl_box.as(gtk.Widget), .center);
    const lg_poweroff_btn = gtk.Button.newWithLabel("Power off");
    gtk.Widget.addCssClass(lg_poweroff_btn.as(gtk.Widget), "destructive-action");
    _ = gtk.Button.signals.clicked.connect(lg_poweroff_btn, *Ui, &onLgPowerOff, ui, .{});
    gtk.Box.append(lg_ctrl_box, lg_poweroff_btn.as(gtk.Widget));
    const lg_reboot_btn = gtk.Button.newWithLabel("Reboot");
    _ = gtk.Button.signals.clicked.connect(lg_reboot_btn, *Ui, &onLgReboot, ui, .{});
    gtk.Box.append(lg_ctrl_box, lg_reboot_btn.as(gtk.Widget));
    adw.ActionRow.addSuffix(lg_ctrl_row, lg_ctrl_box.as(gtk.Widget));
    adw.PreferencesGroup.add(lg_group, lg_ctrl_row.as(gtk.Widget));

    gtk.Box.append(lg_box, lg_group.as(gtk.Widget));
    gtk.Widget.setVisible(lg_box.as(gtk.Widget), 0);
    gtk.Box.append(page, lg_box.as(gtk.Widget));
    ui.lg_section = lg_box.as(gtk.Widget);

    // --- MediaTek BROM section ------------------------------------------
    const mtk_box = gtk.Box.new(.vertical, 12);
    const mtk_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(mtk_group, "MediaTek BROM");
    adw.PreferencesGroup.setDescription(mtk_group, "Boot ROM sync, chip identification and DA upload");

    const mtk_probe_row = adw.ActionRow.new();
    rowTitle(mtk_probe_row, "Chip identification");
    adw.ActionRow.setSubtitle(mtk_probe_row, "Sync + hardware code and software version over the BROM");
    const mtk_probe_btn = gtk.Button.newWithLabel("Read chip info");
    gtk.Widget.addCssClass(mtk_probe_btn.as(gtk.Widget), "suggested-action");
    _ = gtk.Button.signals.clicked.connect(mtk_probe_btn, *Ui, &onMtkProbe, ui, .{});
    adw.ActionRow.addSuffix(mtk_probe_row, mtk_probe_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(mtk_group, mtk_probe_row.as(gtk.Widget));

    const mtk_da_row = adw.ActionRow.new();
    rowTitle(mtk_da_row, "Download Agent (DA)");
    adw.ActionRow.setSubtitle(mtk_da_row, "None selected — device-specific DA binary");
    const mtk_da_btn = gtk.Button.newWithLabel("Choose…");
    _ = gtk.Button.signals.clicked.connect(mtk_da_btn, *Ui, &onMtkPickDa, ui, .{});
    adw.ActionRow.addSuffix(mtk_da_row, mtk_da_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(mtk_group, mtk_da_row.as(gtk.Widget));
    ui.mtk_da_row = mtk_da_row;

    const mtk_addr_row = adw.ActionRow.new();
    rowTitle(mtk_addr_row, "DA load address (hex)");
    const mtk_addr_entry = gtk.Entry.new();
    gtk.Entry.setPlaceholderText(mtk_addr_entry, "0x00200000");
    gtk.Widget.setHexpand(mtk_addr_entry.as(gtk.Widget), 1);
    adw.ActionRow.addSuffix(mtk_addr_row, mtk_addr_entry.as(gtk.Widget));
    adw.PreferencesGroup.add(mtk_group, mtk_addr_row.as(gtk.Widget));
    ui.mtk_da_addr_entry = mtk_addr_entry;

    const mtk_upload_row = adw.ActionRow.new();
    rowTitle(mtk_upload_row, "DA upload");
    adw.ActionRow.setSubtitle(mtk_upload_row, "SEND_DA + JUMP_DA — the device leaves BROM mode on success");
    const mtk_upload_btn = gtk.Button.newWithLabel("Upload DA");
    gtk.Widget.addCssClass(mtk_upload_btn.as(gtk.Widget), "suggested-action");
    _ = gtk.Button.signals.clicked.connect(mtk_upload_btn, *Ui, &onMtkUploadDa, ui, .{});
    adw.ActionRow.addSuffix(mtk_upload_row, mtk_upload_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(mtk_group, mtk_upload_row.as(gtk.Widget));

    gtk.Box.append(mtk_box, mtk_group.as(gtk.Widget));

    const mtk_flash_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(mtk_flash_group, "Flash operations (after DA upload)");
    adw.PreferencesGroup.setDescription(mtk_flash_group, "Address-based eMMC access through the running DA — hex address, decimal size");

    const mtk_faddr_row = adw.ActionRow.new();
    rowTitle(mtk_faddr_row, "Flash address (hex)");
    const mtk_faddr_entry = gtk.Entry.new();
    gtk.Entry.setPlaceholderText(mtk_faddr_entry, "0x00010000");
    gtk.Widget.setHexpand(mtk_faddr_entry.as(gtk.Widget), 1);
    adw.ActionRow.addSuffix(mtk_faddr_row, mtk_faddr_entry.as(gtk.Widget));
    adw.PreferencesGroup.add(mtk_flash_group, mtk_faddr_row.as(gtk.Widget));
    ui.mtk_flash_addr_entry = mtk_faddr_entry;

    const mtk_fsize_row = adw.ActionRow.new();
    rowTitle(mtk_fsize_row, "Size in bytes (dec)");
    const mtk_fsize_entry = gtk.Entry.new();
    gtk.Entry.setPlaceholderText(mtk_fsize_entry, "65536");
    gtk.Widget.setHexpand(mtk_fsize_entry.as(gtk.Widget), 1);
    adw.ActionRow.addSuffix(mtk_fsize_row, mtk_fsize_entry.as(gtk.Widget));
    adw.PreferencesGroup.add(mtk_flash_group, mtk_fsize_row.as(gtk.Widget));
    ui.mtk_flash_size_entry = mtk_fsize_entry;

    const mtk_ops_row = adw.ActionRow.new();
    rowTitle(mtk_ops_row, "Operations");
    const mtk_ops_box = gtk.Box.new(.horizontal, 6);
    gtk.Widget.setValign(mtk_ops_box.as(gtk.Widget), .center);
    const mtk_read_btn = gtk.Button.newWithLabel("Read to file…");
    _ = gtk.Button.signals.clicked.connect(mtk_read_btn, *Ui, &onMtkFlashRead, ui, .{});
    gtk.Box.append(mtk_ops_box, mtk_read_btn.as(gtk.Widget));
    const mtk_write_btn = gtk.Button.newWithLabel("Write image…");
    gtk.Widget.addCssClass(mtk_write_btn.as(gtk.Widget), "destructive-action");
    _ = gtk.Button.signals.clicked.connect(mtk_write_btn, *Ui, &onMtkFlashWrite, ui, .{});
    gtk.Box.append(mtk_ops_box, mtk_write_btn.as(gtk.Widget));
    const mtk_format_btn = gtk.Button.newWithLabel("Format");
    gtk.Widget.addCssClass(mtk_format_btn.as(gtk.Widget), "destructive-action");
    _ = gtk.Button.signals.clicked.connect(mtk_format_btn, *Ui, &onMtkFlashFormat, ui, .{});
    gtk.Box.append(mtk_ops_box, mtk_format_btn.as(gtk.Widget));
    adw.ActionRow.addSuffix(mtk_ops_row, mtk_ops_box.as(gtk.Widget));
    adw.PreferencesGroup.add(mtk_flash_group, mtk_ops_row.as(gtk.Widget));

    gtk.Box.append(mtk_box, mtk_flash_group.as(gtk.Widget));
    gtk.Widget.setVisible(mtk_box.as(gtk.Widget), 0);
    gtk.Box.append(page, mtk_box.as(gtk.Widget));
    ui.mtk_section = mtk_box.as(gtk.Widget);

    // --- Unisoc bootrom section -----------------------------------------
    const spd_box = gtk.Box.new(.vertical, 12);
    const spd_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(spd_group, "Unisoc download mode");
    adw.PreferencesGroup.setDescription(spd_group, "BSL bootrom handshake, FDL upload and flash operations");

    const spd_probe_row = adw.ActionRow.new();
    rowTitle(spd_probe_row, "Bootrom identification");
    adw.ActionRow.setSubtitle(spd_probe_row, "Baud check + version string over the BSL protocol");
    const spd_probe_btn = gtk.Button.newWithLabel("Read bootrom version");
    gtk.Widget.addCssClass(spd_probe_btn.as(gtk.Widget), "suggested-action");
    _ = gtk.Button.signals.clicked.connect(spd_probe_btn, *Ui, &onSpdProbe, ui, .{});
    adw.ActionRow.addSuffix(spd_probe_row, spd_probe_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(spd_group, spd_probe_row.as(gtk.Widget));

    const spd_fdl1_row = adw.ActionRow.new();
    rowTitle(spd_fdl1_row, "FDL1 loader");
    adw.ActionRow.setSubtitle(spd_fdl1_row, "None selected — runs from boot RAM");
    const spd_fdl1_btn = gtk.Button.newWithLabel("Choose…");
    _ = gtk.Button.signals.clicked.connect(spd_fdl1_btn, *Ui, &onSpdPickFdl1, ui, .{});
    adw.ActionRow.addSuffix(spd_fdl1_row, spd_fdl1_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(spd_group, spd_fdl1_row.as(gtk.Widget));
    ui.spd_fdl1_row = spd_fdl1_row;

    const spd_fdl2_row = adw.ActionRow.new();
    rowTitle(spd_fdl2_row, "FDL2 loader");
    adw.ActionRow.setSubtitle(spd_fdl2_row, "None selected — enables flash operations");
    const spd_fdl2_btn = gtk.Button.newWithLabel("Choose…");
    _ = gtk.Button.signals.clicked.connect(spd_fdl2_btn, *Ui, &onSpdPickFdl2, ui, .{});
    adw.ActionRow.addSuffix(spd_fdl2_row, spd_fdl2_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(spd_group, spd_fdl2_row.as(gtk.Widget));
    ui.spd_fdl2_row = spd_fdl2_row;

    const spd_upload_row = adw.ActionRow.new();
    rowTitle(spd_upload_row, "Loader upload");
    adw.ActionRow.setSubtitle(spd_upload_row, "Both FDLs run in sequence (addresses are FDL-internal)");
    const spd_upload_btn = gtk.Button.newWithLabel("Upload FDLs");
    gtk.Widget.addCssClass(spd_upload_btn.as(gtk.Widget), "suggested-action");
    _ = gtk.Button.signals.clicked.connect(spd_upload_btn, *Ui, &onSpdUploadFdl, ui, .{});
    adw.ActionRow.addSuffix(spd_upload_row, spd_upload_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(spd_group, spd_upload_row.as(gtk.Widget));

    gtk.Box.append(spd_box, spd_group.as(gtk.Widget));

    const spd_flash_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(spd_flash_group, "Flash operations (after FDL2)");
    adw.PreferencesGroup.setDescription(spd_flash_group, "Address-based flash access — hex addresses, decimal sizes");

    const spd_addr_row = adw.ActionRow.new();
    rowTitle(spd_addr_row, "Flash address (hex)");
    const spd_addr_entry = gtk.Entry.new();
    gtk.Entry.setPlaceholderText(spd_addr_entry, "0x80000000");
    gtk.Widget.setHexpand(spd_addr_entry.as(gtk.Widget), 1);
    adw.ActionRow.addSuffix(spd_addr_row, spd_addr_entry.as(gtk.Widget));
    adw.PreferencesGroup.add(spd_flash_group, spd_addr_row.as(gtk.Widget));
    ui.spd_addr_entry = spd_addr_entry;

    const spd_name_row = adw.ActionRow.new();
    rowTitle(spd_name_row, "Partition name (optional)");
    adw.ActionRow.setSubtitle(spd_name_row, "FDL2 name-addressed ops override the address above");
    const spd_name_entry = gtk.Entry.new();
    gtk.Entry.setPlaceholderText(spd_name_entry, "wfixnv1");
    gtk.Widget.setHexpand(spd_name_entry.as(gtk.Widget), 1);
    adw.ActionRow.addSuffix(spd_name_row, spd_name_entry.as(gtk.Widget));
    adw.PreferencesGroup.add(spd_flash_group, spd_name_row.as(gtk.Widget));
    ui.spd_name_entry = spd_name_entry;

    const spd_size_row = adw.ActionRow.new();
    rowTitle(spd_size_row, "Size in bytes (dec)");
    const spd_size_entry = gtk.Entry.new();
    gtk.Entry.setPlaceholderText(spd_size_entry, "65536");
    gtk.Widget.setHexpand(spd_size_entry.as(gtk.Widget), 1);
    adw.ActionRow.addSuffix(spd_size_row, spd_size_entry.as(gtk.Widget));
    adw.PreferencesGroup.add(spd_flash_group, spd_size_row.as(gtk.Widget));
    ui.spd_size_entry = spd_size_entry;

    const spd_ops_row = adw.ActionRow.new();
    rowTitle(spd_ops_row, "Operations");
    const spd_ops_box = gtk.Box.new(.horizontal, 6);
    gtk.Widget.setValign(spd_ops_box.as(gtk.Widget), .center);
    const spd_read_btn = gtk.Button.newWithLabel("Read to file…");
    _ = gtk.Button.signals.clicked.connect(spd_read_btn, *Ui, &onSpdFlashRead, ui, .{});
    gtk.Box.append(spd_ops_box, spd_read_btn.as(gtk.Widget));
    const spd_write_btn = gtk.Button.newWithLabel("Write image…");
    gtk.Widget.addCssClass(spd_write_btn.as(gtk.Widget), "destructive-action");
    _ = gtk.Button.signals.clicked.connect(spd_write_btn, *Ui, &onSpdFlashWrite, ui, .{});
    gtk.Box.append(spd_ops_box, spd_write_btn.as(gtk.Widget));
    const spd_erase_btn = gtk.Button.newWithLabel("Erase");
    gtk.Widget.addCssClass(spd_erase_btn.as(gtk.Widget), "destructive-action");
    _ = gtk.Button.signals.clicked.connect(spd_erase_btn, *Ui, &onSpdFlashErase, ui, .{});
    gtk.Box.append(spd_ops_box, spd_erase_btn.as(gtk.Widget));
    adw.ActionRow.addSuffix(spd_ops_row, spd_ops_box.as(gtk.Widget));
    adw.PreferencesGroup.add(spd_flash_group, spd_ops_row.as(gtk.Widget));

    gtk.Box.append(spd_box, spd_flash_group.as(gtk.Widget));
    gtk.Widget.setVisible(spd_box.as(gtk.Widget), 0);
    gtk.Box.append(page, spd_box.as(gtk.Widget));
    ui.spd_section = spd_box.as(gtk.Widget);

    // --- Loader section (needs_loader) ----------------------------------
    const loader_box = gtk.Box.new(.vertical, 12);

    const loader_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(loader_group, "Firehose loader");
    adw.PreferencesGroup.setDescription(loader_group, "This device is in EDL mode and needs its signed programmer uploaded over Sahara");

    const loader_row = adw.ActionRow.new();
    rowTitle(loader_row, "Programmer (.mbn/.elf)");
    adw.ActionRow.setSubtitle(loader_row, "None selected");
    const loader_btn = gtk.Button.newWithLabel("Choose…");
    _ = gtk.Button.signals.clicked.connect(loader_btn, *Ui, &onPickLoader, ui, .{});
    adw.ActionRow.addSuffix(loader_row, loader_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(loader_group, loader_row.as(gtk.Widget));
    ui.loader_row = loader_row;

    // Optional VIP digest tables: only for programmers that enforce
    // per-packet VIP authentication (they announce it in their startup logs).
    const vip_row = adw.ActionRow.new();
    rowTitle(vip_row, "VIP digest tables (optional)");
    adw.ActionRow.setSubtitle(vip_row, "Folder with DigestsToSign.bin.mbn — only for VIP-locked programmers");
    const vip_btn = gtk.Button.newWithLabel("Choose…");
    _ = gtk.Button.signals.clicked.connect(vip_btn, *Ui, &onPickVip, ui, .{});
    adw.ActionRow.addSuffix(vip_row, vip_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(loader_group, vip_row.as(gtk.Widget));
    ui.vip_row = vip_row;

    // Offline VIP digest-table generation: replays a rawprogram flash plan
    // against a loopback device — no device interaction at all. The output
    // DigestsToSign.bin goes to the vendor for signing.
    const digest_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(digest_group, "Create VIP digest tables");
    adw.PreferencesGroup.setDescription(digest_group, "For VIP-locked programmers: hashes a flash plan offline into signed-ready digest tables");

    const digest_row = adw.ActionRow.new();
    rowTitle(digest_row, "Flash plan XML");
    adw.ActionRow.setSubtitle(digest_row, "None selected");
    const digest_add_btn = gtk.Button.newWithLabel("Add…");
    _ = gtk.Button.signals.clicked.connect(digest_add_btn, *Ui, &onDigestAddXml, ui, .{});
    adw.ActionRow.addSuffix(digest_row, digest_add_btn.as(gtk.Widget));
    const digest_clear_btn = gtk.Button.newWithLabel("Clear");
    _ = gtk.Button.signals.clicked.connect(digest_clear_btn, *Ui, &onDigestClearXml, ui, .{});
    adw.ActionRow.addSuffix(digest_row, digest_clear_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(digest_group, digest_row.as(gtk.Widget));
    ui.digest_row = digest_row;

    const digest_dir_row = adw.ActionRow.new();
    rowTitle(digest_dir_row, "Output folder");
    adw.ActionRow.setSubtitle(digest_dir_row, "Receives DigestsToSign.bin + chained tables");
    const digest_dir_btn = gtk.Button.newWithLabel("Choose…");
    _ = gtk.Button.signals.clicked.connect(digest_dir_btn, *Ui, &onDigestPickDir, ui, .{});
    adw.ActionRow.addSuffix(digest_dir_row, digest_dir_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(digest_group, digest_dir_row.as(gtk.Widget));
    ui.digest_dir_row = digest_dir_row;

    const digest_payload_row = adw.ActionRow.new();
    rowTitle(digest_payload_row, "Payload size");
    adw.ActionRow.setSubtitle(digest_payload_row, "Must match the size the real programmer accepts without renegotiating");
    const digest_drop = gtk.DropDown.newFromStrings(@ptrCast(&digest_payload_names));
    adw.ActionRow.addSuffix(digest_payload_row, digest_drop.as(gtk.Widget));
    adw.PreferencesGroup.add(digest_group, digest_payload_row.as(gtk.Widget));
    ui.digest_payload_drop = digest_drop;

    const digest_btn = gtk.Button.newWithLabel("Generate digest tables…");
    gtk.Widget.addCssClass(digest_btn.as(gtk.Widget), "suggested-action");
    gtk.Widget.setHalign(digest_btn.as(gtk.Widget), .start);
    gtk.Widget.setSensitive(digest_btn.as(gtk.Widget), 0);
    _ = gtk.Button.signals.clicked.connect(digest_btn, *Ui, &onDigestGenerate, ui, .{});
    ui.digest_btn = digest_btn;
    adw.PreferencesGroup.add(digest_group, digest_btn.as(gtk.Widget));

    gtk.Box.append(loader_box, digest_group.as(gtk.Widget));

    const upload_btn = gtk.Button.newWithLabel("Upload loader");
    gtk.Widget.addCssClass(upload_btn.as(gtk.Widget), "suggested-action");
    gtk.Widget.addCssClass(upload_btn.as(gtk.Widget), "big-start");
    gtk.Widget.setHalign(upload_btn.as(gtk.Widget), .center);
    gtk.Widget.setSensitive(upload_btn.as(gtk.Widget), 0);
    _ = gtk.Button.signals.clicked.connect(upload_btn, *Ui, &onUploadLoaderClicked, ui, .{});
    ui.upload_btn = upload_btn;

    gtk.Box.append(loader_box, loader_group.as(gtk.Widget));
    gtk.Box.append(loader_box, upload_btn.as(gtk.Widget));
    gtk.Widget.setVisible(loader_box.as(gtk.Widget), 0);
    gtk.Box.append(page, loader_box.as(gtk.Widget));
    ui.loader_section = loader_box.as(gtk.Widget);

    // --- Connected section (firehose_ready) ------------------------------
    const conn = gtk.Box.new(.vertical, 18);

    const parts_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(parts_group, "Partitions");
    adw.PreferencesGroup.setDescription(parts_group, "Read makes a backup; write overwrites the partition after confirmation");
    ui.parts_group = parts_group;

    const lun_row = adw.ActionRow.new();
    rowTitle(lun_row, "Storage LUN");
    const lun_drop = gtk.DropDown.newFromStrings(@ptrCast(&lun_names));
    adw.ActionRow.addSuffix(lun_row, lun_drop.as(gtk.Widget));
    const refresh_btn = gtk.Button.newWithLabel("Refresh");
    _ = gtk.Button.signals.clicked.connect(refresh_btn, *Ui, &onRefreshClicked, ui, .{});
    adw.ActionRow.addSuffix(lun_row, refresh_btn.as(gtk.Widget));
    ui.lun_row = lun_row.as(gtk.Widget);
    ui.lun_drop = lun_drop;
    ui.refresh_btn = refresh_btn;
    adw.PreferencesGroup.add(parts_group, lun_row.as(gtk.Widget));

    const search = gtk.SearchEntry.new();
    gtk.Widget.setVisible(search.as(gtk.Widget), 0); // shown once >15 partitions
    ui.parts_search = search;
    _ = gtk.SearchEntry.signals.search_changed.connect(search, *Ui, &onSearchChanged, ui, .{});
    adw.PreferencesGroup.add(parts_group, search.as(gtk.Widget));

    const parts_list = gtk.ListBox.new();
    gtk.ListBox.setSelectionMode(parts_list, .none);
    gtk.Widget.addCssClass(parts_list.as(gtk.Widget), "boxed-list");
    ui.parts_list = parts_list;
    adw.PreferencesGroup.add(parts_group, parts_list.as(gtk.Widget));

    const parts_empty = gtk.Label.new("Loading partitions…");
    gtk.Widget.addCssClass(parts_empty.as(gtk.Widget), "dim-label");
    setMargins(parts_empty.as(gtk.Widget), 6, 0, 0, 6);
    ui.parts_empty = parts_empty;
    adw.PreferencesGroup.add(parts_group, parts_empty.as(gtk.Widget));

    // Queued writes.
    const pending_row = adw.ActionRow.new();
    rowTitle(pending_row, "Queued writes");
    adw.ActionRow.setSubtitle(pending_row, "None — click Write on a partition to queue one");
    const clear_writes_btn = gtk.Button.newWithLabel("Clear");
    _ = gtk.Button.signals.clicked.connect(clear_writes_btn, *Ui, &onClearWritesClicked, ui, .{});
    adw.ActionRow.addSuffix(pending_row, clear_writes_btn.as(gtk.Widget));
    const write_all_btn = gtk.Button.newWithLabel("Write");
    gtk.Widget.addCssClass(write_all_btn.as(gtk.Widget), "destructive-action");
    gtk.Widget.setSensitive(write_all_btn.as(gtk.Widget), 0);
    _ = gtk.Button.signals.clicked.connect(write_all_btn, *Ui, &onWriteAllClicked, ui, .{});
    adw.ActionRow.addSuffix(pending_row, write_all_btn.as(gtk.Widget));
    ui.pending_row = pending_row;
    ui.write_all_btn = write_all_btn;
    adw.PreferencesGroup.add(parts_group, pending_row.as(gtk.Widget));

    gtk.Box.append(conn, parts_group.as(gtk.Widget));

    // rawprogram support.
    const xml_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(xml_group, "rawprogram flashing");
    adw.PreferencesGroup.setDescription(xml_group, "qdl-compatible rawprogram*.xml + patch*.xml layouts");

    const xml_row = adw.ActionRow.new();
    rowTitle(xml_row, "Flash layout XML");
    adw.ActionRow.setSubtitle(xml_row, "None selected");
    const xml_add_btn = gtk.Button.newWithLabel("Add…");
    _ = gtk.Button.signals.clicked.connect(xml_add_btn, *Ui, &onAddXml, ui, .{});
    adw.ActionRow.addSuffix(xml_row, xml_add_btn.as(gtk.Widget));
    const xml_clear_btn = gtk.Button.newWithLabel("Clear");
    _ = gtk.Button.signals.clicked.connect(xml_clear_btn, *Ui, &onClearXml, ui, .{});
    adw.ActionRow.addSuffix(xml_row, xml_clear_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(xml_group, xml_row.as(gtk.Widget));
    ui.xml_row = xml_row;

    const missing_row = adw.ActionRow.new();
    rowTitle(missing_row, "Skip missing image files");
    const missing_sw = gtk.Switch.new();
    gtk.Widget.setValign(missing_sw.as(gtk.Widget), .center);
    adw.ActionRow.addSuffix(missing_row, missing_sw.as(gtk.Widget));
    ui.allow_missing_sw = missing_sw;
    adw.PreferencesGroup.add(xml_group, missing_row.as(gtk.Widget));

    const flash_xml_btn = gtk.Button.newWithLabel("Flash XMLs…");
    gtk.Widget.addCssClass(flash_xml_btn.as(gtk.Widget), "destructive-action");
    gtk.Widget.setHalign(flash_xml_btn.as(gtk.Widget), .start);
    gtk.Widget.setSensitive(flash_xml_btn.as(gtk.Widget), 0);
    _ = gtk.Button.signals.clicked.connect(flash_xml_btn, *Ui, &onFlashXmlClicked, ui, .{});
    ui.flash_xml_btn = flash_xml_btn;
    adw.PreferencesGroup.add(xml_group, flash_xml_btn.as(gtk.Widget));

    gtk.Box.append(conn, xml_group.as(gtk.Widget));

    // --- UFS provisioning (advanced, destructive) ------------------------
    const ufs_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(ufs_group, "UFS provisioning (advanced)");
    adw.PreferencesGroup.setDescription(ufs_group, "Rewrites the UFS configuration descriptor from a vendor <ufs> XML. With the OTP lock it is irreversible");

    const ufs_row = adw.ActionRow.new();
    rowTitle(ufs_row, "Provisioning XML");
    adw.ActionRow.setSubtitle(ufs_row, "None selected — vendor-provided <ufs> layout");
    const ufs_add_btn = gtk.Button.newWithLabel("Choose…");
    _ = gtk.Button.signals.clicked.connect(ufs_add_btn, *Ui, &onPickUfsXml, ui, .{});
    adw.ActionRow.addSuffix(ufs_row, ufs_add_btn.as(gtk.Widget));
    const ufs_clear_btn = gtk.Button.newWithLabel("Clear");
    _ = gtk.Button.signals.clicked.connect(ufs_clear_btn, *Ui, &onClearUfsXml, ui, .{});
    adw.ActionRow.addSuffix(ufs_row, ufs_clear_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(ufs_group, ufs_row.as(gtk.Widget));
    ui.ufs_row = ufs_row;

    const ufs_fin_row = adw.ActionRow.new();
    rowTitle(ufs_fin_row, "Finalize (OTP lock)");
    adw.ActionRow.setSubtitle(ufs_fin_row, "Must match bConfigDescrLock=1 in the XML — IRREVERSIBLE");
    const ufs_fin_sw = gtk.Switch.new();
    gtk.Widget.setValign(ufs_fin_sw.as(gtk.Widget), .center);
    adw.ActionRow.addSuffix(ufs_fin_row, ufs_fin_sw.as(gtk.Widget));
    adw.PreferencesGroup.add(ufs_group, ufs_fin_row.as(gtk.Widget));
    ui.ufs_finalize_sw = ufs_fin_sw;

    const ufs_btn = gtk.Button.newWithLabel("Provision…");
    gtk.Widget.addCssClass(ufs_btn.as(gtk.Widget), "destructive-action");
    gtk.Widget.setHalign(ufs_btn.as(gtk.Widget), .start);
    gtk.Widget.setSensitive(ufs_btn.as(gtk.Widget), 0);
    _ = gtk.Button.signals.clicked.connect(ufs_btn, *Ui, &onUfsProvisionClicked, ui, .{});
    ui.ufs_btn = ufs_btn;
    adw.PreferencesGroup.add(ufs_group, ufs_btn.as(gtk.Widget));

    gtk.Box.append(conn, ufs_group.as(gtk.Widget));

    // --- Huawei UPDATE.APP ------------------------------------------------
    const huawei_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(huawei_group, "Huawei UPDATE.APP");
    adw.PreferencesGroup.setDescription(huawei_group, "Flash a Huawei firmware package: images are matched to partitions by name (sparse images convert to raw)");

    const huawei_row = adw.ActionRow.new();
    rowTitle(huawei_row, "UPDATE.APP file");
    adw.ActionRow.setSubtitle(huawei_row, "None selected");
    const huawei_add_btn = gtk.Button.newWithLabel("Choose…");
    _ = gtk.Button.signals.clicked.connect(huawei_add_btn, *Ui, &onPickHuaweiApp, ui, .{});
    adw.ActionRow.addSuffix(huawei_row, huawei_add_btn.as(gtk.Widget));
    const huawei_clear_btn = gtk.Button.newWithLabel("Clear");
    _ = gtk.Button.signals.clicked.connect(huawei_clear_btn, *Ui, &onClearHuaweiApp, ui, .{});
    adw.ActionRow.addSuffix(huawei_row, huawei_clear_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(huawei_group, huawei_row.as(gtk.Widget));
    ui.huawei_row = huawei_row;

    const huawei_btn = gtk.Button.newWithLabel("Flash to partitions…");
    gtk.Widget.addCssClass(huawei_btn.as(gtk.Widget), "destructive-action");
    gtk.Widget.setHalign(huawei_btn.as(gtk.Widget), .start);
    gtk.Widget.setSensitive(huawei_btn.as(gtk.Widget), 0);
    _ = gtk.Button.signals.clicked.connect(huawei_btn, *Ui, &onFlashHuaweiClicked, ui, .{});
    ui.huawei_btn = huawei_btn;
    adw.PreferencesGroup.add(huawei_group, huawei_btn.as(gtk.Widget));

    gtk.Box.append(conn, huawei_group.as(gtk.Widget));

    // Session controls.
    const ctrl_box = gtk.Box.new(.horizontal, 10);
    gtk.Widget.setHalign(ctrl_box.as(gtk.Widget), .center);
    const reset_btn = gtk.Button.newWithLabel("Reset device");
    gtk.Widget.addCssClass(reset_btn.as(gtk.Widget), "destructive-action");
    _ = gtk.Button.signals.clicked.connect(reset_btn, *Ui, &onResetClicked, ui, .{});
    gtk.Box.append(ctrl_box, reset_btn.as(gtk.Widget));
    const disconnect_btn = gtk.Button.newWithLabel("Disconnect");
    _ = gtk.Button.signals.clicked.connect(disconnect_btn, *Ui, &onDisconnectClicked, ui, .{});
    gtk.Box.append(ctrl_box, disconnect_btn.as(gtk.Widget));
    ui.reset_btn = reset_btn;
    ui.disconnect_btn = disconnect_btn;
    gtk.Box.append(conn, ctrl_box.as(gtk.Widget));

    gtk.Widget.setVisible(conn.as(gtk.Widget), 0);
    gtk.Box.append(page, conn.as(gtk.Widget));
    ui.conn_section = conn.as(gtk.Widget);

    return scrolled.as(gtk.Widget);
}

fn rowTitle(row: *adw.ActionRow, title: [:0]const u8) void {
    adw.PreferencesRow.setTitle(row.as(adw.PreferencesRow), title.ptr);
}

// ----------------------------------------------------------------------
// Main page state handling
// ----------------------------------------------------------------------

fn refreshMainPage(ui: *Ui) void {
    // Every widget reference is guarded: a null here must never crash the
    // app (events can only arrive via the main loop after buildWindow, but a
    // segfault in the UI is unrecoverable and undebuggable in ReleaseFast).
    const status = ui.status_page orelse return;
    const dev_card = ui.dev_card orelse return;

    const has_device = ui.device != null;
    gtk.Widget.setVisible(status.as(gtk.Widget), @intFromBool(!has_device));
    gtk.Widget.setVisible(dev_card.as(gtk.Widget), @intFromBool(has_device));

    const is_samsung = has_device and ui.device.?.mode == .samsung_odin;
    const is_lg = has_device and ui.device.?.mode == .lg_laf;
    const is_mtk = has_device and ui.device.?.mode == .mtk_brom;
    const is_spd = has_device and ui.device.?.mode == .spd_brom;
    const vendor = is_samsung or is_lg or is_mtk or is_spd;
    const ready = ui.session == .firehose_ready or ui.session == .samsung_ready or ui.session == .lg_ready;

    if (ui.loader_section) |w| gtk.Widget.setVisible(w, @intFromBool(has_device and ui.session == .needs_loader));
    if (ui.conn_section) |w| gtk.Widget.setVisible(w, @intFromBool(has_device and ready));
    if (ui.ramdump_section) |w| {
        const is_crash = has_device and ui.device.?.mode == .qualcomm_crash;
        gtk.Widget.setVisible(w, @intFromBool(is_crash));
    }
    if (ui.samsung_section) |w| gtk.Widget.setVisible(w, @intFromBool(is_samsung));
    if (ui.lg_section) |w| gtk.Widget.setVisible(w, @intFromBool(is_lg));
    if (ui.mtk_section) |w| gtk.Widget.setVisible(w, @intFromBool(is_mtk));
    if (ui.spd_section) |w| gtk.Widget.setVisible(w, @intFromBool(is_spd));
    refreshDeviceSelector(ui);

    // The chip probe and Connect only make sense before a session exists —
    // and are Qualcomm concepts entirely.
    const pre_connect = ui.session == .disconnected and !vendor;
    if (ui.dev_chip_label) |l| gtk.Widget.setVisible(l.as(gtk.Widget), @intFromBool(pre_connect));
    if (ui.chip_row) |w| gtk.Widget.setVisible(w, @intFromBool(pre_connect));
    if (ui.storage_drop) |d| gtk.Widget.setVisible(d.as(gtk.Widget), @intFromBool(pre_connect));
    if (ui.skip_init_sw) |sw| gtk.Widget.setVisible(sw.as(gtk.Widget), @intFromBool(pre_connect));
    if (ui.skip_init_row) |row| gtk.Widget.setVisible(row.as(gtk.Widget), @intFromBool(pre_connect));
    if (ui.connect_btn) |b| gtk.Widget.setVisible(b.as(gtk.Widget), @intFromBool(pre_connect));

    // Qualcomm-only tools inside the connected section: hidden on Samsung
    // and LG.
    if (vendor) {
        if (ui.xml_row) |w| gtk.Widget.setVisible(w.as(gtk.Widget), 0);
        if (ui.ufs_row) |w| gtk.Widget.setVisible(w.as(gtk.Widget), 0);
        if (ui.huawei_row) |w| gtk.Widget.setVisible(w.as(gtk.Widget), 0);
        if (ui.pending_row) |w| gtk.Widget.setVisible(w.as(gtk.Widget), 0);
        if (ui.lun_row) |w| gtk.Widget.setVisible(w, 0);
        inline for (.{ ui.flash_xml_btn, ui.ufs_btn, ui.huawei_btn, ui.write_all_btn, ui.refresh_btn, ui.reset_btn }) |maybe| {
            if (maybe) |b| gtk.Widget.setVisible(b.as(gtk.Widget), 0);
        }
    }

    if (has_device) {
        const dev = ui.device.?;
        if (ui.dev_mode_label) |l| labelTextZ(l, dev.mode.displayName());
        var buf: [96]u8 = undefined;
        const vp = std.fmt.bufPrint(&buf, "{x:0>4}:{x:0>4}  (bus {d:0>3} device {d:0>3})", .{ dev.vid, dev.pid, dev.bus, dev.devnum }) catch "-";
        if (ui.dev_vidpid_label) |l| labelTextZ(l, vp);
        if (ui.dev_path_label) |l| labelTextZ(l, dev.key.path.slice());
    }
}

fn rebuildPartitions(ui: *Ui, parts: *const ev.PartitionsEvent) void {
    // Drop the old rows and their contexts.
    for (ui.row_ctxs.items) |ctx| ui.alloc.destroy(ctx);
    ui.row_ctxs.clearRetainingCapacity();
    listBoxClear(ui.parts_list.?);

    if (ui.parts_group) |g| {
        var info_buf: [200]u8 = undefined;
        const is_samsung = ui.device != null and ui.device.?.mode == .samsung_odin;
        const info = if (parts.vip)
            (std.fmt.bufPrint(&info_buf, "VIP session — every packet must match the signed digest table, so partition reads/writes are unavailable", .{}) catch "")
        else if (is_samsung)
            (std.fmt.bufPrint(&info_buf, "PIT partition table · Write overwrites after confirmation; Erase zero-fills the partition", .{}) catch "")
        else
            (std.fmt.bufPrint(&info_buf, "LUN {d} · sector {d} B · {d} LUN(s) · Read makes a backup; Write overwrites after confirmation", .{ parts.lun, parts.sector_size, parts.luns }) catch "");
        var info_z: [220]u8 = undefined;
        const info_zs = std.fmt.bufPrintZ(&info_z, "{s}", .{info}) catch return;
        adw.PreferencesGroup.setDescription(g, info_zs.ptr);
    }

    // LUN switcher only matters on multi-LUN devices.
    gtk.Widget.setVisible(ui.lun_row.?, @intFromBool(parts.luns > 1));

    if (parts.count == 0) {
        if (parts.vip) {
            gtk.Label.setText(ui.parts_empty.?, "VIP session — flash rawprogram XML files below");
        } else {
            gtk.Label.setText(ui.parts_empty.?, "No partitions found (empty GPT?)");
        }
        gtk.Widget.setVisible(ui.parts_empty.?.as(gtk.Widget), 1);
        return;
    }
    gtk.Widget.setVisible(ui.parts_empty.?.as(gtk.Widget), 0);

    var buf: [128]u8 = undefined;
    for (parts.parts[0..parts.count]) |row| {
        const ctx = ui.alloc.create(RowCtx) catch return;
        ctx.* = .{ .ui = ui, .row = row };
        ui.row_ctxs.append(ui.alloc, ctx) catch {
            ui.alloc.destroy(ctx);
            return;
        };

        const action_row = adw.ActionRow.new();
        var name_buf: [80]u8 = undefined;
        const nm = std.fmt.bufPrintZ(&name_buf, "{s}", .{row.name.slice()}) catch "unnamed";
        adw.PreferencesRow.setTitle(action_row.as(adw.PreferencesRow), nm.ptr);

        const size_bytes = row.sectors() * parts.sector_size;
        var size_buf: [32]u8 = undefined;
        const size_txt = util.formatBytes(&size_buf, size_bytes);
        const sub = std.fmt.bufPrint(&buf, "index {d} · LBA {d}–{d} · {s}", .{ row.index, row.first_lba, row.last_lba, size_txt }) catch "";
        setSubtitleZ(action_row, sub);

        // Read-back does not exist in the Odin protocol — no Read on Samsung.
        if (ui.device == null or ui.device.?.mode != .samsung_odin) {
            const read_btn = gtk.Button.newWithLabel("Read");
            _ = gtk.Button.signals.clicked.connect(read_btn, *RowCtx, &onReadClicked, ctx, .{});
            adw.ActionRow.addSuffix(action_row, read_btn.as(gtk.Widget));
        }

        const write_btn = gtk.Button.newWithLabel("Write");
        gtk.Widget.addCssClass(write_btn.as(gtk.Widget), "destructive-action");
        _ = gtk.Button.signals.clicked.connect(write_btn, *RowCtx, &onWriteClicked, ctx, .{});
        adw.ActionRow.addSuffix(action_row, write_btn.as(gtk.Widget));

        const erase_btn = gtk.Button.newWithLabel("Erase");
        gtk.Widget.addCssClass(erase_btn.as(gtk.Widget), "destructive-action");
        _ = gtk.Button.signals.clicked.connect(erase_btn, *RowCtx, &onEraseClicked, ctx, .{});
        adw.ActionRow.addSuffix(action_row, erase_btn.as(gtk.Widget));

        ctx.row_widget = action_row.as(gtk.Widget);
        gtk.ListBox.append(ui.parts_list.?, action_row.as(gtk.Widget));
    }

    // Filter appears once the list is long enough to matter.
    gtk.Widget.setVisible(ui.parts_search.?.as(gtk.Widget), @intFromBool(parts.count > 15));
    gtk.Editable.setText(@ptrCast(ui.parts_search.?), "");
    applyPartFilter(ui);
}

fn onSearchChanged(search: *gtk.SearchEntry, ui: *Ui) callconv(.c) void {
    _ = search;
    applyPartFilter(ui);
}

fn applyPartFilter(ui: *Ui) void {
    const query_raw = if (ui.parts_search) |se| gtk.Editable.getText(@ptrCast(se)) else return;
    const query = std.mem.span(query_raw);
    for (ui.row_ctxs.items) |ctx| {
        if (ctx.row_widget) |w| {
            const match = query.len == 0 or std.mem.indexOf(u8, ctx.row.name.slice(), query) != null;
            gtk.Widget.setVisible(w, @intFromBool(match));
        }
    }
}

fn listBoxClear(list: *gtk.ListBox) void {
    while (true) {
        const child = gtk.Widget.getFirstChild(list.as(gtk.Widget)) orelse break;
        gtk.ListBox.remove(list, @ptrCast(@alignCast(child)));
    }
}

fn refreshPendingWrites(ui: *Ui) void {
    const row = ui.pending_row orelse return;
    const btn = ui.write_all_btn orelse return;
    const n = ui.pending_writes.items.len;
    if (n == 0) {
        adw.ActionRow.setSubtitle(row, "None — click Write on a partition to queue one");
        gtk.Button.setLabel(btn, "Write");
        gtk.Widget.setSensitive(btn.as(gtk.Widget), 0);
        return;
    }
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    for (ui.pending_writes.items, 0..) |pw, i| {
        const line = std.fmt.bufPrint(buf[len..], "{s}{s} ← {s}", .{
            if (i == 0) "" else ", ",
            pw.row.name.slice(),
            std.fs.path.basename(pw.path),
        }) catch break;
        len += line.len;
        if (len > buf.len - 60) {
            _ = std.fmt.bufPrint(buf[len..], " …", .{}) catch break;
            break;
        }
    }
    setSubtitleZ(row, buf[0..len]);
    var label_buf: [32]u8 = undefined;
    const lbl = std.fmt.bufPrintZ(&label_buf, "Write {d}…", .{n}) catch "Write…";
    gtk.Button.setLabel(btn, lbl.ptr);
    gtk.Widget.setSensitive(btn.as(gtk.Widget), @intFromBool(!ui.busy()));
}

fn clearPendingWrites(ui: *Ui) void {
    for (ui.pending_writes.items) |pw| ui.alloc.free(pw.path);
    ui.pending_writes.clearRetainingCapacity();
    refreshPendingWrites(ui);
}

// ----------------------------------------------------------------------
// Choosers
// ----------------------------------------------------------------------

fn openChooser(ui: *Ui, kind: ChooserKind, title: [:0]const u8, save: bool, suggested: ?[:0]const u8) void {
    openChooserFull(ui, kind, title, save, suggested, false);
}

fn openChooserFull(ui: *Ui, kind: ChooserKind, title: [:0]const u8, save: bool, suggested: ?[:0]const u8, folder: bool) void {
    if (ui.chooser != null) return; // a chooser is already pending
    const window = ui.window orelse return;
    const chooser = gtk.FileChooserNative.new(
        title.ptr,
        window.as(gtk.Window),
        if (folder) .select_folder else if (save) .save else .open,
        null,
        null,
    );
    if (suggested) |s| gtk.FileChooser.setCurrentName(chooser.as(gtk.FileChooser), s.ptr);
    // Modal: the main window must not change state (LUN, device, busy) while
    // a chooser is open — the response handlers act on state captured then.
    gtk.NativeDialog.setModal(chooser.as(gtk.NativeDialog), 1);
    ui.chooser = kind;
    _ = gtk.NativeDialog.signals.response.connect(chooser, *Ui, &onChooserResponse, ui, .{});
    gtk.NativeDialog.show(chooser.as(gtk.NativeDialog));
}

fn onChooserResponse(chooser: *gtk.FileChooserNative, response_id: c_int, ui: *Ui) callconv(.c) void {
    const kind = ui.chooser orelse return;
    ui.chooser = null;
    // Pick-routing markers must never outlive the dialog: a cancelled
    // write pick must not hijack the next read pick (the audit's M2).
    ui.mtk_write_pick = false;
    ui.spd_write_pick = false;
    if (response_id != @intFromEnum(gtk.ResponseType.accept)) return;
    const file = gtk.FileChooser.getFile(chooser.as(gtk.FileChooser)) orelse {
        ui.logger.err("file chooser returned no file", .{});
        ui.toast("Could not read the selected file");
        return;
    };
    defer file.unref();
    // Resolve the path and copy it into our allocator immediately: both
    // g_file_get_path and the URI string are g_malloc-owned and the URI
    // fallback below would otherwise dangle past its glib.free.
    var path: []const u8 = undefined;
    if (gio.File.getPath(file)) |p| {
        defer glib.free(p);
        path = std.mem.span(p);
    } else {
        const uri_c = gio.File.getUri(file);
        defer glib.free(uri_c);
        const uri = std.mem.span(uri_c);
        if (std.mem.startsWith(u8, uri, "file://")) {
            path = uri["file://".len..];
        } else {
            ui.logger.err("selected file URI is not file://: {s}", .{uri});
            ui.toast("Unsupported file location");
            return;
        }
    }
    const path_copy = ui.alloc.dupe(u8, path) catch {
        ui.toast("Out of memory");
        return;
    };
    defer ui.alloc.free(path_copy);
    path = path_copy;

    switch (kind) {
        .loader => {
            if (ui.programmer_path) |old| ui.alloc.free(old);
            ui.programmer_path = ui.alloc.dupe(u8, path) catch null;
            if (ui.programmer_path) |p| setSubtitleZ(ui.loader_row.?, p);
            gtk.Widget.setSensitive(ui.upload_btn.?.as(gtk.Widget), @intFromBool(!ui.busy()));
        },
        .vip_tables => {
            if (ui.vip_dir) |old| ui.alloc.free(old);
            ui.vip_dir = ui.alloc.dupe(u8, path) catch null;
            if (ui.vip_dir) |p| {
                setSubtitleZ(ui.vip_row.?, p);
                ui.logger.info("VIP digest tables folder selected: {s}", .{p});
            }
        },
        .digest_xml_add => {
            const dup = ui.alloc.dupe(u8, path) catch return;
            ui.digest_xmls.append(ui.alloc, dup) catch {
                ui.alloc.free(dup);
                return;
            };
            refreshDigestRow(ui);
        },
        .digest_out_dir => {
            if (ui.digest_dir) |old| ui.alloc.free(old);
            ui.digest_dir = ui.alloc.dupe(u8, path) catch null;
            if (ui.digest_dir) |p| setSubtitleZ(ui.digest_dir_row.?, p);
            refreshDigestRow(ui);
        },
        .ufs_xml => {
            if (ui.ufs_xml_path) |old| ui.alloc.free(old);
            ui.ufs_xml_path = ui.alloc.dupe(u8, path) catch null;
            if (ui.ufs_xml_path) |p| {
                setSubtitleZ(ui.ufs_row.?, p);
                gtk.Widget.setSensitive(ui.ufs_btn.?.as(gtk.Widget), @intFromBool(!ui.busy()));
            }
        },
        .huawei_app_file => {
            if (ui.busy()) {
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            if (ui.huawei_path) |old| ui.alloc.free(old);
            ui.huawei_path = ui.alloc.dupe(u8, path) catch null;
            if (ui.huawei_path) |p| {
                setSubtitleZ(ui.huawei_row.?, p);
                ui.huawei_entries = null;
                // Parse on a worker: the magic scan reads the whole file.
                const ctx = ui.alloc.create(HuaweiParseCtx) catch return;
                ctx.* = .{ .ui = ui, .path = undefined, .gen = ui.huawei_gen + 1 };
                ui.huawei_gen += 1;
                ctx.path = ui.alloc.dupe(u8, p) catch {
                    ui.alloc.destroy(ctx);
                    return;
                };
                ui.startJob();
                const thread = std.Thread.spawn(.{}, huaweiParseRun, .{ctx}) catch {
                    ui.jobDone();
                    ui.alloc.free(ctx.path);
                    ui.alloc.destroy(ctx);
                    ui.toast("Failed to start worker thread");
                    return;
                };
                // busy() gated the spawn, so any stored handle is a finished
                // previous run — joining it is instant.
                if (ui.huawei_thread) |old| old.join();
                ui.huawei_thread = thread;
            }
        },
        .ramdump_dir => {
            if (ui.ramdump_dir) |old| ui.alloc.free(old);
            ui.ramdump_dir = ui.alloc.dupe(u8, path) catch null;
            if (ui.ramdump_dir) |p| {
                setSubtitleZ(ui.ramdump_dir_row.?, p);
                gtk.Widget.setSensitive(ui.ramdump_btn.?.as(gtk.Widget), @intFromBool(!ui.busy()));
            }
        },
        .samsung_pit => {
            if (ui.busy()) {
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            const dup = ui.alloc.dupe(u8, path) catch return;
            if (ui.samsung_stage_path) |old| ui.alloc.free(old);
            ui.samsung_stage_path = dup;
            confirmDialog(ui, "Flash PIT?", "Writing a PIT repartitions the device. A wrong or corrupt PIT can HARD-BRICK it. This is IRREVERSIBLE.", "Flash PIT", .destructive, .samsung_pit);
        },
        .spd_fdl1 => {
            const dup = ui.alloc.dupe(u8, path) catch return;
            if (ui.spd_fdl1_path) |old| ui.alloc.free(old);
            ui.spd_fdl1_path = dup;
            setSubtitleZ(ui.spd_fdl1_row.?, path);
        },
        .mtk_da => {
            const dup = ui.alloc.dupe(u8, path) catch return;
            if (ui.mtk_da_path) |old| ui.alloc.free(old);
            ui.mtk_da_path = dup;
            setSubtitleZ(ui.mtk_da_row.?, path);
        },
        .mtk_read => {
            // onMtkFlashWrite sets mtk_write_pick; a read pick has it clear.
            if (ui.mtk_write_pick) {
                ui.mtk_write_pick = false;
                const dup = ui.alloc.dupe(u8, path) catch return;
                if (ui.mtk_stage_path) |old| ui.alloc.free(old);
                ui.mtk_stage_path = dup;
                var body_buf: [256]u8 = undefined;
                const body = std.fmt.bufPrint(&body_buf, "Write {d} bytes (512-padded) to flash at 0x{X:0>8}?\n\nOverwriting flash is IRREVERSIBLE.", .{ ui.mtk_stage_size, ui.mtk_stage_addr }) catch return;
                confirmDialog(ui, "Write flash?", body, "Write", .destructive, .mtk_write);
                return;
            }
            const ctx = ui.alloc.create(MtkProbeCtx) catch return;
            ctx.* = .{ .ui = ui, .kind = .read, .flash_addr = ui.mtk_stage_addr, .flash_len = ui.mtk_stage_size };
            ctx.path = ui.alloc.dupe(u8, path) catch {
                ctx.free();
                return;
            };
            mtkStageTarget(ui, ctx) catch {
                ctx.free();
                return;
            };
            spawnMtkJob(ui, ctx);
        },
        .spd_fdl2 => {
            const dup = ui.alloc.dupe(u8, path) catch return;
            if (ui.spd_fdl2_path) |old| ui.alloc.free(old);
            ui.spd_fdl2_path = dup;
            setSubtitleZ(ui.spd_fdl2_row.?, path);
        },
        .spd_write => {
            // onSpdFlashWrite sets spd_write_pick; a read pick has it clear.
            if (ui.spd_write_pick) {
                ui.spd_write_pick = false;
                const dup = ui.alloc.dupe(u8, path) catch return;
                if (ui.spd_stage_path) |old| ui.alloc.free(old);
                ui.spd_stage_path = dup;
                var body_buf: [256]u8 = undefined;
                const body = std.fmt.bufPrint(&body_buf, "Write {d} bytes to flash at 0x{X:0>8}?\n\nOverwriting flash is IRREVERSIBLE.", .{ ui.spd_stage_size, ui.spd_stage_addr }) catch return;
                confirmDialog(ui, "Write flash?", body, "Write", .destructive, .spd_write);
                return;
            }
            const ctx = ui.alloc.create(SpdProbeCtx) catch return;
            ctx.* = .{ .ui = ui, .kind = .read, .addr = ui.spd_stage_addr, .size = ui.spd_stage_size, .pname = ui.spd_stage_name };
            ui.spd_stage_name = null; // ownership moves to the ctx
            ctx.path = ui.alloc.dupe(u8, path) catch {
                ctx.free();
                return;
            };
            spdStageTarget(ui, ctx) catch {
                ctx.free();
                return;
            };
            ui.startJob();
            const thread = std.Thread.spawn(.{}, spdProbeRun, .{ctx}) catch {
                ui.jobDone();
                ctx.free();
                ui.toast("Failed to start worker thread");
                return;
            };
            if (ui.spd_thread) |old| old.join();
            ui.spd_thread = thread;
        },
        .samsung_bundle => {
            if (ui.busy()) {
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            // List the image members for the confirmation (header walk only —
            // data is streamed later, so huge archives stay cheap).
            var body_buf: [1200]u8 = undefined;
            var len: usize = 0;
            appendFmt(&body_buf, &len, "Flash the bundle's images to their PIT partitions?\n\n", .{});
            var archive = samsungtar.list(ui.alloc, path, ui.logger) catch {
                ui.toast("Not a valid tar.md5 bundle");
                return;
            };
            defer archive.deinit(ui.alloc);
            var listed: u32 = 0;
            var images: u32 = 0;
            for (archive.members[0..archive.count]) |*m| {
                if (m.isMd5()) continue;
                images += 1;
                if (listed < 10) {
                    var size_buf: [32]u8 = undefined;
                    const size_txt = util.formatBytes(&size_buf, m.size);
                    appendFmt(&body_buf, &len, "· {s} ({s})\n", .{ m.nameSlice(), size_txt });
                    listed += 1;
                }
            }
            if (images == 0) {
                ui.toast("The bundle contains no image members");
                return;
            }
            if (images > listed) appendFmt(&body_buf, &len, "· … and {d} more\n", .{images - listed});
            appendFmt(&body_buf, &len, "\nImages without a PIT file-name match are skipped. Overwriting partitions is IRREVERSIBLE.", .{});

            const dup = ui.alloc.dupe(u8, path) catch return;
            if (ui.samsung_stage_path) |old| ui.alloc.free(old);
            ui.samsung_stage_path = dup;
            confirmDialog(ui, "Flash firmware bundle?", body_buf[0..len], "Flash", .destructive, .samsung_bundle);
        },
        .xml_add => {
            const dup = ui.alloc.dupe(u8, path) catch return;
            ui.xml_paths.append(ui.alloc, dup) catch {
                ui.alloc.free(dup);
                return;
            };
            refreshXmlRow(ui);
            gtk.Widget.setSensitive(ui.flash_xml_btn.?.as(gtk.Widget), @intFromBool(!ui.busy()));
        },
        .read_partition => |rp| {
            if (ui.busy()) {
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            if (ui.device != null and ui.device.?.mode == .lg_laf) {
                const ctx = ui.alloc.create(LgJobCtx) catch return;
                ctx.* = .{ .ui = ui, .kind = .read, .row = rp.row };
                ctx.path = ui.alloc.dupe(u8, path) catch {
                    lgJobCtxFree(ctx);
                    return;
                };
                lgStageTarget(ui, ctx) catch {
                    lgJobCtxFree(ctx);
                    return;
                };
                ui.startJob();
                // The busy gate ran above; spawn directly here.
                const thread = std.Thread.spawn(.{}, lgRun, .{ctx}) catch {
                    ui.jobDone();
                    lgJobCtxFree(ctx);
                    ui.toast("Failed to start worker thread");
                    return;
                };
                if (ui.lg_thread) |old| old.join();
                ui.lg_thread = thread;
                return;
            }
            ui.startJob();
            ui.manager.?.enqueue(.{ .read_partition = .{
                .path = path,
                .first_lba = rp.row.first_lba,
                .num_sectors = rp.row.sectors(),
                .lun = rp.lun,
                .label = rp.row.name.slice(),
            } });
        },
        .write_partition => |row| {
            if (ui.device != null and ui.device.?.mode == .lg_laf) {
                var size_buf: [32]u8 = undefined;
                const size_txt = util.formatBytes(&size_buf, row.sectors() * 512);
                var body_buf: [512]u8 = undefined;
                const body = std.fmt.bufPrint(&body_buf, "Flash \"{s}\" to partition \"{s}\" (LBA {d}–{d}, {s})?\n\nOverwriting a partition is IRREVERSIBLE and can hard-brick the device if the image is wrong.", .{
                    std.fs.path.basename(path),
                    row.name.slice(),
                    row.first_lba,
                    row.last_lba,
                    size_txt,
                }) catch return;
                const dup = ui.alloc.dupe(u8, path) catch return;
                if (ui.samsung_flash_path) |old| ui.alloc.free(old);
                ui.samsung_flash_path = dup; // shared staging slot (modes are exclusive)
                confirmDialog(ui, "Flash image to partition?", body, "Flash", .destructive, .{ .lg_write = row });
                return;
            }
            if (ui.device != null and ui.device.?.mode == .samsung_odin) {
                // Samsung: flash this image straight to the clicked partition
                // after confirmation (no queue — each op opens its own session).
                var size: u64 = 0;
                if (fileio.File.open(path)) |opened| {
                    var img = opened;
                    defer img.close();
                    size = img.size() catch 0;
                } else |_| {}
                var size_buf: [32]u8 = undefined;
                const size_txt = util.formatBytes(&size_buf, size);
                var body_buf: [512]u8 = undefined;
                const body = std.fmt.bufPrint(&body_buf, "Flash \"{s}\" ({s}) to partition \"{s}\" (LBA {d}–{d})?\n\nOverwriting a partition is IRREVERSIBLE and can hard-brick the device if the image is wrong.", .{
                    std.fs.path.basename(path),
                    size_txt,
                    row.name.slice(),
                    row.first_lba,
                    row.last_lba,
                }) catch return;
                const dup = ui.alloc.dupe(u8, path) catch return;
                if (ui.samsung_flash_path) |old| ui.alloc.free(old);
                ui.samsung_flash_path = dup;
                confirmDialog(ui, "Flash image to partition?", body, "Flash", .destructive, .{ .samsung_flash = row });
                return;
            }
            const dup = ui.alloc.dupe(u8, path) catch return;
            ui.pending_writes.append(ui.alloc, .{ .row = row, .path = dup, .lun = currentLun(ui) }) catch {
                ui.alloc.free(dup);
                return;
            };
            refreshPendingWrites(ui);
        },
    }
}

// ----------------------------------------------------------------------
// Click handlers
// ----------------------------------------------------------------------

fn readStorageSelection(ui: *Ui) void {
    if (ui.storage_drop) |d| {
        const idx = gtk.DropDown.getSelected(d);
        ui.storage = storage_values[@min(idx, storage_values.len - 1)];
    }
    if (ui.skip_init_sw) |sw| ui.skip_storage_init = gtk.Switch.getActive(sw) != 0;
    if (ui.allow_missing_sw) |sw| ui.allow_missing = gtk.Switch.getActive(sw) != 0;
}

/// Sync ui.device from the visible-device list and the user's selection.
fn syncActiveDevice(ui: *Ui) void {
    if (ui.selected_key) |want| {
        for (ui.devices.items) |d| {
            if (d.key.eql(want)) {
                ui.device = d;
                return;
            }
        }
    }
    ui.device = if (ui.devices.items.len > 0) ui.devices.items[ui.devices.items.len - 1] else null;
}

/// The transport filter for the currently selected device (null = auto).
fn activeTarget(ui: *Ui) ?transport.Target {
    const dev = ui.device orelse return null;
    if (ui.devices.items.len < 2) return null;
    return .{
        .bus = dev.bus,
        .devnum = dev.devnum,
        .serial = if (dev.serial.len > 0) dev.serial.slice() else null,
    };
}

/// Rebuild the device dropdown (only shown with 2+ devices pre-connect).
fn refreshDeviceSelector(ui: *Ui) void {
    const slot = ui.device_sel_slot orelse return;
    const row = ui.device_sel_row orelse return;
    // Clear previous dropdown (if any).
    while (gtk.Widget.getFirstChild(slot.as(gtk.Widget))) |child| gtk.Widget.unparent(child);
    const show = ui.devices.items.len > 1 and ui.session == .disconnected;
    gtk.Widget.setVisible(row, @intFromBool(show));
    if (!show) return;

    var names_buf: [10][64]u8 = undefined;
    var name_zs: [10]?[*:0]const u8 = .{null} ** 10;
    var n: usize = 0;
    name_zs[n] = "Auto (first found)";
    n += 1;
    for (ui.devices.items) |d| {
        // One slot stays reserved for the null terminator below.
        if (n >= name_zs.len - 1) break;
        const z = std.fmt.bufPrintZ(&names_buf[n], "bus {d:0>3} dev {d:0>3}  {x:0>4}:{x:0>4}", .{ d.bus, d.devnum, d.vid, d.pid }) catch continue;
        name_zs[n] = z.ptr;
        n += 1;
    }
    name_zs[n] = null;

    const drop = gtk.DropDown.newFromStrings(@ptrCast(&name_zs));
    gtk.DropDown.setSelected(drop, 0);
    // Mark the current selection.
    if (ui.selected_key) |want| {
        for (ui.devices.items, 0..) |d, i| {
            if (d.key.eql(want)) {
                gtk.DropDown.setSelected(drop, @intCast(i + 1));
                break;
            }
        }
    }
    _ = gobject.Object.signals.notify.connect(drop, *Ui, &onDeviceSelected, ui, .{ .detail = "selected" });
    gtk.Box.append(slot, drop.as(gtk.Widget));
}

fn onDeviceSelected(drop: *gtk.DropDown, _: *gobject.ParamSpec, ui: *Ui) callconv(.c) void {
    const selected = gtk.DropDown.getSelected(drop);
    if (selected == 0) {
        ui.selected_key = null;
    } else {
        const idx: usize = selected - 1;
        if (idx < ui.devices.items.len) ui.selected_key = ui.devices.items[idx].key;
    }
    syncActiveDevice(ui);
    refreshMainPage(ui);
}

fn currentLun(ui: *Ui) u32 {
    if (ui.lun_drop) |d| return @min(gtk.DropDown.getSelected(d), max_lun_choices - 1);
    return 0;
}

fn sectorSizeOf(ui: *Ui) u32 {
    if (ui.parts) |p| return if (p.sector_size != 0) p.sector_size else 512;
    return 512;
}

fn onRescanClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.scanner) |sc| sc.requestScan();
    ui.logger.info("manual rescan requested", .{});
}

fn onConnectClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.manager == null) return;
    if (ui.device != null and ui.device.?.mode == .samsung_odin) return; // Samsung uses its own flow
    readStorageSelection(ui);
    ui.startJob();
    ui.manager.?.enqueue(.{ .connect = .{
        .storage = ui.storage,
        .skip_storage_init = ui.skip_storage_init,
        .vip_dir = ui.vip_dir,
        .target = activeTarget(ui),
    } });
}

fn onPickLoader(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .loader, "Select firehose programmer", false, null);
}

fn onPickVip(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooserFull(ui, .vip_tables, "Select VIP digest tables folder", false, null, true);
}

fn onDigestAddXml(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .digest_xml_add, "Select rawprogram / patch XML", false, null);
}

fn onDigestClearXml(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    for (ui.digest_xmls.items) |p| ui.alloc.free(p);
    ui.digest_xmls.clearRetainingCapacity();
    refreshDigestRow(ui);
}

fn onDigestPickDir(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooserFull(ui, .digest_out_dir, "Select output folder for digest tables", false, null, true);
}

fn refreshDigestRow(ui: *Ui) void {
    const row = ui.digest_row orelse return;
    if (ui.digest_xmls.items.len == 0) {
        adw.ActionRow.setSubtitle(row, "None selected");
    } else {
        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d} file(s) selected", .{ui.digest_xmls.items.len}) catch "Selected";
        setSubtitleZ(row, s);
    }
    if (ui.digest_btn) |b| {
        gtk.Widget.setSensitive(b.as(gtk.Widget), @intFromBool(!ui.busy() and ui.digest_xmls.items.len > 0 and ui.digest_dir != null));
    }
}

/// Heap context for the offline digest-generation thread (self-freed).
const DigestGenCtx = struct {
    ui: *Ui,
    dir: []u8,
    xmls: [][]u8,
    payload_size: usize,
    storage: firehose.StorageType,
    skip_storage_init: bool,
};

fn digestCtxFree(ctx: *DigestGenCtx) void {
    const alloc = ctx.ui.alloc;
    alloc.free(ctx.dir);
    for (ctx.xmls) |x| alloc.free(x);
    alloc.free(ctx.xmls);
    alloc.destroy(ctx);
}

fn digestGenRun(ctx: *DigestGenCtx) void {
    const ui = ctx.ui;
    defer digestCtxFree(ctx);
    digestgen.run(ui.alloc, ui.logger, .{
        .dir = ctx.dir,
        .xml_files = ctx.xmls,
        .payload_size = ctx.payload_size,
        .storage = ctx.storage,
        // The replay must send the same SkipStorageInit as the flashing run
        // for byte-identical packets.
        .skip_storage_init = ctx.skip_storage_init,
    }) catch |e| {
        var mbuf: [256]u8 = undefined;
        var m = ev.FixedStr(512){};
        m.set(std.fmt.bufPrint(&mbuf, "digest generation failed: {s}", .{@errorName(e)}) catch "digest generation failed");
        ui.channel.push(.{ .finished = .{ .success = false, .message = m } });
        return;
    };
    var m = ev.FixedStr(512){};
    m.set("digest tables created");
    ui.channel.push(.{ .finished = .{ .success = true, .message = m } });
}

fn onDigestGenerate(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    if (ui.digest_xmls.items.len == 0) {
        ui.toast("Add the rawprogram / patch XML files first");
        return;
    }
    const dir = ui.digest_dir orelse {
        ui.toast("Choose an output folder first");
        return;
    };
    readStorageSelection(ui); // storage type comes from the device card dropdown

    var payload: usize = digest_payload_values[0];
    if (ui.digest_payload_drop) |d| {
        payload = digest_payload_values[@min(gtk.DropDown.getSelected(d), digest_payload_values.len - 1)];
    }

    const ctx = ui.alloc.create(DigestGenCtx) catch return;
    ctx.* = .{ .ui = ui, .dir = undefined, .xmls = undefined, .payload_size = payload, .storage = ui.storage, .skip_storage_init = ui.skip_storage_init };
    ctx.dir = ui.alloc.dupe(u8, dir) catch {
        ui.alloc.destroy(ctx);
        return;
    };
    ctx.xmls = ui.alloc.alloc([]u8, ui.digest_xmls.items.len) catch {
        ui.alloc.free(ctx.dir);
        ui.alloc.destroy(ctx);
        return;
    };
    var dup_ok = true;
    for (ui.digest_xmls.items, 0..) |p, i| {
        ctx.xmls[i] = ui.alloc.dupe(u8, p) catch {
            dup_ok = false;
            break;
        };
    }
    if (!dup_ok) {
        digestCtxFree(ctx);
        return;
    }

    ui.startJob();
    const thread = std.Thread.spawn(.{}, digestGenRun, .{ctx}) catch {
        ui.jobDone();
        digestCtxFree(ctx);
        ui.toast("Failed to start worker thread");
        return;
    };
    // busy() gated the spawn, so any stored handle is a finished previous
    // run — joining it is instant (detached handles cannot be joined again;
    // pthread_join of a dead id panics in ReleaseSafe).
    if (ui.digest_thread) |old| old.join();
    ui.digest_thread = thread;
}

fn onUploadLoaderClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.manager == null) return;
    const path = ui.programmer_path orelse return;
    readStorageSelection(ui);
    ui.startJob();
    ui.manager.?.enqueue(.{ .upload_loader = .{
        .programmer = path,
        .storage = ui.storage,
        .skip_storage_init = ui.skip_storage_init,
        .vip_dir = ui.vip_dir,
        .target = activeTarget(ui),
    } });
}

fn onProbeClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.device == null) return;
    // The probe needs the device in bare EDL mode with NO open session: it
    // opens its own USB handle, which is impossible while the manager holds
    // the interface (it would spin and die with Busy).
    if (ui.session != .disconnected) {
        ui.toast("Read chip needs bare EDL mode — Disconnect the session first");
        return;
    }
    ui.startJob();
    spawnChipProbe(ui) catch {
        ui.jobDone();
        ui.toast("Failed to start worker thread");
        return;
    };
    labelTextZ(ui.dev_chip_label.?, "Reading chip identity…");
}

fn onRefreshClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.manager == null) return;
    ui.startJob();
    ui.manager.?.enqueue(.{ .list_partitions = .{ .lun = currentLun(ui) } });
}

fn onReadClicked(_: *gtk.Button, ctx: *RowCtx) callconv(.c) void {
    const ui = ctx.ui;
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    if (ui.device) |d| switch (d.mode) {
        .samsung_odin => {
            ui.toast("Partition read-back is not available in Samsung download mode");
            return;
        },
        .lg_laf => {
            // LG supports read-back: straight to the save chooser.
            var name_buf: [96]u8 = undefined;
            const suggested = std.fmt.bufPrintZ(&name_buf, "{s}.img", .{ctx.row.name.slice()}) catch "partition.img";
            openChooser(ui, .{ .read_partition = .{ .row = ctx.row, .lun = 0 } }, "Save partition backup", true, suggested);
            return;
        },
        else => {},
    };
    var name_buf: [96]u8 = undefined;
    const suggested = std.fmt.bufPrintZ(&name_buf, "{s}.img", .{ctx.row.name.slice()}) catch "partition.img";
    openChooser(ui, .{ .read_partition = .{ .row = ctx.row, .lun = currentLun(ui) } }, "Save partition backup", true, suggested);
}

fn onWriteClicked(_: *gtk.Button, ctx: *RowCtx) callconv(.c) void {
    openChooser(ctx.ui, .{ .write_partition = ctx.row }, "Select image to write", false, null);
}

fn onEraseClicked(_: *gtk.Button, ctx: *RowCtx) callconv(.c) void {
    const ui = ctx.ui;
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    var size_buf: [32]u8 = undefined;
    const size_txt = util.formatBytes(&size_buf, ctx.row.sectors() * sectorSizeOf(ui));
    const is_lg = ui.device != null and ui.device.?.mode == .lg_laf;
    var body_buf: [512]u8 = undefined;
    const body = if (is_lg)
        std.fmt.bufPrint(&body_buf, "Erase \"{s}\" ({s}, LBA {d}–{d})?\n\nEverything in this partition is lost (TRIM lands on reboot). This is IRREVERSIBLE.", .{ ctx.row.name.slice(), size_txt, ctx.row.first_lba, ctx.row.last_lba }) catch return
    else
        std.fmt.bufPrint(&body_buf, "Erase \"{s}\" ({s}, LBA {d}–{d}) on LUN {d}?\n\nEverything in this partition is lost. This is IRREVERSIBLE.", .{ ctx.row.name.slice(), size_txt, ctx.row.first_lba, ctx.row.last_lba, currentLun(ui) }) catch return;
    confirmDialog(ui, "Erase partition?", body, "Erase", .destructive, if (is_lg) .{ .lg_erase = ctx.row } else .{ .erase_partition = ctx.row });
}

fn onClearWritesClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    clearPendingWrites(ui);
}

fn onWriteAllClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.pending_writes.items.len == 0) return;

    var body_buf: [1400]u8 = undefined;
    var len: usize = 0;
    var fit = true;
    for (ui.pending_writes.items) |pw| {
        var size_buf: [32]u8 = undefined;
        const size_txt = util.formatBytes(&size_buf, pw.row.sectors() * sectorSizeOf(ui));
        if (std.fmt.bufPrint(body_buf[len..], "• {s} ({s}) ← {s}\n", .{
            pw.row.name.slice(),
            size_txt,
            std.fs.path.basename(pw.path),
        })) |line| {
            len += line.len;
        } else |_| {
            fit = false;
            break;
        }
    }
    if (!fit) {
        ui.toast("Too many queued writes to display — apply them in smaller batches");
        return;
    }
    _ = std.fmt.bufPrint(body_buf[len..], "\nOverwriting a partition is IRREVERSIBLE and can hard-brick your device if the wrong image is flashed. Double-check every target.", .{}) catch {};

    confirmDialog(ui, "Write partitions?", body_buf[0..len], "Write", .destructive, .apply_writes);
}

fn onFlashXmlClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.xml_paths.items.len == 0) return;

    var body_buf: [1400]u8 = undefined;
    var len: usize = 0;
    for (ui.xml_paths.items) |p| {
        const line = std.fmt.bufPrint(body_buf[len..], "• {s}\n", .{std.fs.path.basename(p)}) catch break;
        len += line.len;
    }
    _ = std.fmt.bufPrint(body_buf[len..], "\nFlashing a layout erases and rewrites the partitions it lists. This is IRREVERSIBLE.", .{}) catch {};

    confirmDialog(ui, "Flash XML layouts?", body_buf[0..len], "Flash", .destructive, .flash_xml);
}

fn onResetClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.manager == null) return;
    ui.startJob();
    ui.manager.?.enqueue(.{ .reset = {} });
}

fn onDisconnectClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.manager == null) return;
    ui.startJob();
    ui.manager.?.enqueue(.{ .disconnect = {} });
}

fn onCancelClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    ui.cancel.store(true, .release);
    ui.logger.info("cancel requested — the session will disconnect", .{});
    if (ui.cancel_button) |b| gtk.Widget.setSensitive(b.as(gtk.Widget), 0);
}

fn onAddXml(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .xml_add, "Select rawprogram / patch XML", false, null);
}

fn onClearXml(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    for (ui.xml_paths.items) |p| ui.alloc.free(p);
    ui.xml_paths.clearRetainingCapacity();
    refreshXmlRow(ui);
    gtk.Widget.setSensitive(ui.flash_xml_btn.?.as(gtk.Widget), 0);
}

fn refreshXmlRow(ui: *Ui) void {
    if (ui.xml_paths.items.len == 0) {
        adw.ActionRow.setSubtitle(ui.xml_row.?, "None selected");
        return;
    }
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    for (ui.xml_paths.items, 1..) |p, i| {
        const line = std.fmt.bufPrint(buf[len..], "{d}. {s}\n", .{ i, std.fs.path.basename(p) }) catch break;
        len += line.len;
    }
    setSubtitleZ(ui.xml_row.?, buf[0..len]);
}

// ----------------------------------------------------------------------
// Confirmation dialog
// ----------------------------------------------------------------------

fn confirmDialog(ui: *Ui, heading: [:0]const u8, body: []const u8, apply_label: [:0]const u8, appearance: adw.ResponseAppearance, kind: ConfirmKind) void {
    const window = ui.window orelse return;
    var head_z: [128]u8 = undefined;
    const hz = std.fmt.bufPrintZ(&head_z, "{s}", .{heading}) catch return;
    var body_z: [1500]u8 = undefined;
    const bz = std.fmt.bufPrintZ(&body_z, "{s}", .{body}) catch return;

    const dlg = adw.MessageDialog.new(window.as(gtk.Window), hz.ptr, bz.ptr);
    adw.MessageDialog.addResponse(dlg, "cancel", "Cancel");
    adw.MessageDialog.addResponse(dlg, "apply", apply_label.ptr);
    adw.MessageDialog.setResponseAppearance(dlg, "apply", appearance);
    adw.MessageDialog.setCloseResponse(dlg, "cancel");

    const ctx = ui.alloc.create(ConfirmCtx) catch return;
    ctx.* = .{ .ui = ui, .kind = kind };
    _ = adw.MessageDialog.signals.response.connect(dlg, *ConfirmCtx, &onConfirmResponse, ctx, .{});
    gtk.Window.present(dlg.as(gtk.Window));
}

fn onConfirmResponse(dlg: *adw.MessageDialog, response: [*:0]const u8, ctx: *ConfirmCtx) callconv(.c) void {
    const ui = ctx.ui;
    const kind = ctx.kind;
    ui.alloc.destroy(ctx);
    gtk.Window.destroy(dlg.as(gtk.Window));
    const applied = std.mem.eql(u8, std.mem.span(response), "apply");
    if (!applied) {
        // Dismissal frees every staged slot this dialog could own.
        if (kind == .huawei_app) {
            if (ui.huawei_pending_mappings) |*list| {
                for (list.items) |m| {
                    ui.alloc.free(m.entry);
                    ui.alloc.free(m.label);
                }
                list.deinit(ui.alloc);
                ui.huawei_pending_mappings = null;
            }
        }
        if (ui.samsung_flash_path) |p| ui.alloc.free(p);
        ui.samsung_flash_path = null;
        if (ui.samsung_stage_path) |p| ui.alloc.free(p);
        ui.samsung_stage_path = null;
        if (ui.spd_stage_path) |p| ui.alloc.free(p);
        ui.spd_stage_path = null;
        if (ui.spd_stage_name) |p| ui.alloc.free(p);
        ui.spd_stage_name = null;
        if (ui.mtk_stage_path) |p| ui.alloc.free(p);
        ui.mtk_stage_path = null;
        return;
    }
    // The pending UPDATE.APP mapping list is consumed on apply only.
    var huawei_maps: ?std.ArrayList(manager_mod.HuaweiMapping) = null;
    if (kind == .huawei_app) {
        huawei_maps = ui.huawei_pending_mappings;
        ui.huawei_pending_mappings = null;
    }

    switch (kind) {
        .apply_writes => {
            if (ui.busy() or ui.manager == null) return;
            for (ui.pending_writes.items) |pw| {
                ui.startJob();
                ui.manager.?.enqueue(.{ .write_partition = .{
                    .path = pw.path,
                    .first_lba = pw.row.first_lba,
                    .max_sectors = pw.row.sectors(),
                    .lun = pw.lun,
                    .label = pw.row.name.slice(),
                } });
            }
            clearPendingWrites(ui);
        },
        .flash_xml => {
            if (ui.busy() or ui.manager == null or ui.xml_paths.items.len == 0) return;
            readStorageSelection(ui);
            ui.startJob();
            ui.manager.?.enqueue(.{ .flash_xml = .{
                .files = ui.xml_paths.items,
                .allow_missing = ui.allow_missing,
            } });
        },
        .erase_partition => |row| {
            if (ui.busy()) return;
            if (ui.device != null and ui.device.?.mode == .samsung_odin) {
                // Odin erase = zero-fill the partition (Thor's ErasePartition).
                const job = ui.alloc.create(SamsungJobCtx) catch return;
                job.* = .{ .ui = ui, .kind = .erase, .partition = undefined, .partition_len = @min(row.name.len, job.partition.len), .length = row.sectors() * 512 };
                @memcpy(job.partition[0..job.partition_len], row.name.slice()[0..job.partition_len]);
                samsungStageTarget(ui, job) catch {
                    samsungJobCtxFree(job);
                    return;
                };
                spawnSamsungJob(ui, job);
                return;
            }
            if (ui.manager == null) return;
            ui.startJob();
            ui.manager.?.enqueue(.{ .erase_partition = .{
                .first_lba = row.first_lba,
                .num_sectors = row.sectors(),
                .lun = currentLun(ui),
                .label = row.name.slice(),
            } });
        },
        .provision_ufs => {
            if (ui.busy() or ui.manager == null) return;
            const path = ui.ufs_xml_path orelse return;
            const finalize = ui.ufs_finalize_sw != null and gtk.Switch.getActive(ui.ufs_finalize_sw.?) != 0;
            ui.startJob();
            ui.manager.?.enqueue(.{ .provision_ufs = .{ .path = path, .finalize = finalize } });
        },
        .samsung_flash => |row| {
            const path = ui.samsung_flash_path orelse return;
            ui.samsung_flash_path = null;
            if (ui.busy()) {
                ui.alloc.free(path);
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            const job = ui.alloc.create(SamsungJobCtx) catch {
                ui.alloc.free(path);
                return;
            };
            job.* = .{ .ui = ui, .kind = .flash, .path = path, .partition = undefined, .partition_len = @min(row.name.len, job.partition.len), .length = 0 };
            @memcpy(job.partition[0..job.partition_len], row.name.slice()[0..job.partition_len]);
            samsungStageTarget(ui, job) catch {
                samsungJobCtxFree(job);
                return;
            };
            spawnSamsungJob(ui, job);
        },
        .lg_erase => |row| {
            if (ui.busy()) {
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            const job = ui.alloc.create(LgJobCtx) catch return;
            job.* = .{ .ui = ui, .kind = .erase, .row = row };
            lgStageTarget(ui, job) catch {
                lgJobCtxFree(job);
                return;
            };
            spawnLgJob(ui, job);
        },
        .lg_write => |row| {
            const path = ui.samsung_flash_path orelse return; // shared staging slot (modes are exclusive)
            ui.samsung_flash_path = null;
            if (ui.busy()) {
                ui.alloc.free(path);
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            const job = ui.alloc.create(LgJobCtx) catch {
                ui.alloc.free(path);
                return;
            };
            job.* = .{ .ui = ui, .kind = .write, .path = path, .row = row };
            lgStageTarget(ui, job) catch {
                lgJobCtxFree(job);
                return;
            };
            spawnLgJob(ui, job);
        },
        .mtk_write, .mtk_format => {
            const mtk_kind: MtkJobKind = if (kind == .mtk_write) .write else .format;
            const staged = ui.mtk_stage_path;
            ui.mtk_stage_path = null;
            if (ui.busy()) {
                if (staged) |p| ui.alloc.free(p);
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            const job = ui.alloc.create(MtkProbeCtx) catch {
                if (staged) |p| ui.alloc.free(p);
                return;
            };
            job.* = .{ .ui = ui, .kind = mtk_kind, .flash_addr = ui.mtk_stage_addr, .flash_len = ui.mtk_stage_size, .path = staged };
            mtkStageTarget(ui, job) catch {
                job.free();
                return;
            };
            spawnMtkJob(ui, job);
        },
        .spd_write, .spd_erase => {
            const job_kind: SpdJobKind = if (kind == .spd_write) .write else .erase;
            const staged = ui.spd_stage_path;
            ui.spd_stage_path = null;
            if (ui.busy()) {
                if (staged) |p| ui.alloc.free(p);
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            const job = ui.alloc.create(SpdProbeCtx) catch {
                if (staged) |p| ui.alloc.free(p);
                return;
            };
            job.* = .{ .ui = ui, .kind = job_kind, .addr = ui.spd_stage_addr, .size = ui.spd_stage_size, .path = staged, .pname = ui.spd_stage_name };
            ui.spd_stage_name = null; // ownership moves to the job
            spdStageTarget(ui, job) catch {
                job.free();
                return;
            };
            ui.startJob();
            const thread = std.Thread.spawn(.{}, spdProbeRun, .{job}) catch {
                ui.jobDone();
                job.free();
                ui.toast("Failed to start worker thread");
                return;
            };
            if (ui.spd_thread) |old| old.join();
            ui.spd_thread = thread;
        },
        .samsung_pit, .samsung_bundle => {
            const job_kind: SamsungJobKind = if (kind == .samsung_pit) .flash_pit else .bundle;
            const staged = ui.samsung_stage_path;
            ui.samsung_stage_path = null;
            if (ui.busy()) {
                if (staged) |p| ui.alloc.free(p);
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            const job = ui.alloc.create(SamsungJobCtx) catch {
                if (staged) |p| ui.alloc.free(p);
                return;
            };
            job.* = .{ .ui = ui, .kind = job_kind, .path = staged, .partition = undefined, .partition_len = 0 };
            samsungStageTarget(ui, job) catch {
                samsungJobCtxFree(job);
                return;
            };
            spawnSamsungJob(ui, job);
        },
        .samsung_factory => {
            if (ui.busy()) {
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            const job = ui.alloc.create(SamsungJobCtx) catch return;
            job.* = .{ .ui = ui, .kind = .factory_reset, .partition = undefined, .partition_len = 0 };
            samsungStageTarget(ui, job) catch {
                samsungJobCtxFree(job);
                return;
            };
            spawnSamsungJob(ui, job);
        },
        .huawei_app => {
            if (ui.busy() or ui.manager == null or huawei_maps == null) {
                if (huawei_maps) |*list| {
                    for (list.items) |m| {
                        ui.alloc.free(m.entry);
                        ui.alloc.free(m.label);
                    }
                    list.deinit(ui.alloc);
                }
                return;
            }
            ui.startJob();
            ui.manager.?.enqueue(.{ .flash_huawei_app = .{
                .path = ui.huawei_path.?,
                .mappings = huawei_maps.?.items,
            } });
            // The manager duplicated the strings into the queue item.
            for (huawei_maps.?.items) |m| {
                ui.alloc.free(m.entry);
                ui.alloc.free(m.label);
            }
            huawei_maps.?.deinit(ui.alloc);
        },
    }
}

// ----------------------------------------------------------------------
// RAM dump (crash-dump devices, Sahara Memory Debug)
// ----------------------------------------------------------------------

fn onRamdumpPickDir(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooserFull(ui, .ramdump_dir, "Select RAM dump output folder", false, null, true);
}

const RamdumpCtx = struct {
    ui: *Ui,
    dir: []u8,
    filter: ?[]u8,
    target: ?transport.Target = null,
    target_serial_buf: ?[]u8 = null,
};

fn ramdumpCtxFree(ctx: *RamdumpCtx) void {
    const alloc = ctx.ui.alloc;
    alloc.free(ctx.dir);
    if (ctx.filter) |f| alloc.free(f);
    if (ctx.target_serial_buf) |s| alloc.free(s);
    alloc.destroy(ctx);
}

fn ramdumpProgressCb(ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void {
    const channel: *EventChannel = @ptrCast(@alignCast(ctx orelse return));
    const frac: f32 = if (total == 0) -1.0 else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    var buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "dumping {s}", .{name}) catch name;
    channel.push(.{ .progress = .{ .fraction = frac, .label = ev.FixedStr(160).fromSlice(text), .done = done, .total = total } });
}

fn ramdumpRun(ctx: *RamdumpCtx) void {
    const ui = ctx.ui;
    defer ramdumpCtxFree(ctx);

    const count = session_mod.ramDump(
        ui.alloc,
        ui.logger,
        &ui.cancel,
        .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &ramdumpProgressCb },
        ctx.target,
        8000,
        ctx.dir,
        ctx.filter,
    ) catch |e| {
        var mbuf: [256]u8 = undefined;
        var m = ev.FixedStr(512){};
        m.set(std.fmt.bufPrint(&mbuf, "RAM dump failed: {s}", .{@errorName(e)}) catch "RAM dump failed");
        ui.channel.push(.{ .finished = .{ .success = false, .message = m } });
        return;
    };

    var mbuf: [128]u8 = undefined;
    var m = ev.FixedStr(512){};
    m.set(std.fmt.bufPrint(&mbuf, "ramdump finished ({d} region(s))", .{count}) catch "ramdump finished");
    ui.channel.push(.{ .finished = .{ .success = true, .message = m } });
}

fn onRamdumpClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    const dir = ui.ramdump_dir orelse {
        ui.toast("Choose an output folder for the dump first");
        return;
    };

    const ctx = ui.alloc.create(RamdumpCtx) catch return;
    ctx.* = .{ .ui = ui, .dir = undefined, .filter = null };
    ctx.dir = ui.alloc.dupe(u8, dir) catch {
        ui.alloc.destroy(ctx);
        return;
    };
    // Snapshot the filter text on the main thread — GTK widgets must not be
    // touched from the worker.
    if (ui.ramdump_filter_entry) |entry| {
        const raw = gtk.Editable.getText(@ptrCast(entry));
        const t = std.mem.trim(u8, std.mem.span(raw), " ");
        if (t.len > 0) ctx.filter = ui.alloc.dupe(u8, t) catch null;
    }
    if (activeTarget(ui)) |t| {
        var copy = t;
        if (t.serial) |s| {
            const dup = ui.alloc.dupe(u8, s) catch null;
            ctx.target_serial_buf = dup;
            copy.serial = dup;
        }
        ctx.target = copy;
    }

    ui.startJob();
    const thread = std.Thread.spawn(.{}, ramdumpRun, .{ctx}) catch {
        ui.jobDone();
        ramdumpCtxFree(ctx);
        ui.toast("Failed to start worker thread");
        return;
    };
    if (ui.ramdump_thread) |old| old.join();
    ui.ramdump_thread = thread;
}

// ----------------------------------------------------------------------
// Samsung Odin (download mode, one-shot jobs)
// ----------------------------------------------------------------------

const SamsungJobKind = enum { pit_dump, flash, erase, reboot, reboot_download, factory_reset, flash_pit, bundle };

const SamsungJobCtx = struct {
    ui: *Ui,
    kind: SamsungJobKind,
    target: ?transport.Target = null,
    target_serial_buf: ?[]u8 = null,
    /// Image file path (flash) — owned.
    path: ?[]u8 = null,
    /// PIT partition name the operation targets (flash/erase).
    partition: [40]u8 = undefined,
    partition_len: usize = 0,
    /// Operation length in bytes (erase: the partition's zero-fill size).
    length: u64 = 0,
};

fn samsungJobCtxFree(ctx: *SamsungJobCtx) void {
    const alloc = ctx.ui.alloc;
    if (ctx.target_serial_buf) |s| alloc.free(s);
    if (ctx.path) |p| alloc.free(p);
    alloc.destroy(ctx);
}

fn vendorProgressCb(ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void {
    const channel: *EventChannel = @ptrCast(@alignCast(ctx orelse return));
    const frac: f32 = if (total == 0) -1.0 else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    channel.push(.{ .progress = .{ .fraction = frac, .label = ev.FixedStr(160).fromSlice(name), .done = done, .total = total } });
}

fn samsungStageTarget(ui: *Ui, ctx: *SamsungJobCtx) !void {
    if (activeTarget(ui)) |t| {
        var copy = t;
        if (t.serial) |s| {
            const dup = try ui.alloc.dupe(u8, s);
            ctx.target_serial_buf = dup;
            copy.serial = dup;
        }
        ctx.target = copy;
    }
}

fn spawnSamsungJob(ui: *Ui, ctx: *SamsungJobCtx) void {
    ui.startJob();
    const thread = std.Thread.spawn(.{}, samsungRun, .{ctx}) catch {
        ui.jobDone();
        samsungJobCtxFree(ctx);
        ui.toast("Failed to start worker thread");
        return;
    };
    // busy() gated the spawn, so any stored handle is a finished run.
    if (ui.samsung_thread) |old| old.join();
    ui.samsung_thread = thread;
}

/// Worker for every Samsung Odin operation: each job opens its own session
/// (handshake → BeginSession → operation → EndSession), like Thor's
/// connect/begin/end command grouping.
fn samsungRun(ctx: *SamsungJobCtx) void {
    const ui = ctx.ui;
    defer samsungJobCtxFree(ctx);
    samsungRunInner(ctx) catch |e| {
        var mbuf: [320]u8 = undefined;
        const name = ctx.partition[0..ctx.partition_len];
        const msg = switch (ctx.kind) {
            .pit_dump => std.fmt.bufPrint(&mbuf, "PIT dump failed: {s}", .{@errorName(e)}) catch "PIT dump failed",
            .flash => std.fmt.bufPrint(&mbuf, "flash to {s} failed: {s}", .{ name, @errorName(e) }) catch "flash failed",
            .erase => std.fmt.bufPrint(&mbuf, "erase of {s} failed: {s}", .{ name, @errorName(e) }) catch "erase failed",
            .reboot, .reboot_download => std.fmt.bufPrint(&mbuf, "reboot failed: {s}", .{@errorName(e)}) catch "reboot failed",
            .factory_reset => std.fmt.bufPrint(&mbuf, "factory reset failed: {s}", .{@errorName(e)}) catch "factory reset failed",
            .flash_pit => std.fmt.bufPrint(&mbuf, "PIT flash failed: {s}", .{@errorName(e)}) catch "PIT flash failed",
            .bundle => std.fmt.bufPrint(&mbuf, "bundle flash failed: {s}", .{@errorName(e)}) catch "bundle flash failed",
        };
        var m = ev.FixedStr(512){};
        m.set(msg);
        ui.channel.push(.{ .finished = .{ .success = false, .message = m } });
        return;
    };
    var m = ev.FixedStr(512){};
    m.set(switch (ctx.kind) {
        .pit_dump => "PIT loaded",
        .flash => "flash finished",
        .erase => "erase finished",
        .reboot, .reboot_download => "device rebooted",
        .factory_reset => "userdata erased (factory reset)",
        .flash_pit => "PIT flash finished",
        .bundle => "bundle flash finished",
    });
    ui.channel.push(.{ .finished = .{ .success = true, .message = m } });
}

fn samsungRunInner(ctx: *SamsungJobCtx) !void {
    const ui = ctx.ui;
    var usb_dev = try usb.open(&samsung_usb_ids.policy, ctx.target, 8000, ui.logger, ui.alloc, &ui.cancel);
    defer usb_dev.close();
    // Loke does not expect the qdl-style trailing ZLP after writes.
    usb_dev.transport().setWriteZlp(false);
    var io = transport.Io.init(ui.alloc, usb_dev.transport());
    defer io.deinit();
    var sess = samsung_odin.Session{ .alloc = ui.alloc, .io = &io, .logger = ui.logger, .cancel = &ui.cancel };
    try sess.handshake();
    _ = try sess.beginSession();

    switch (ctx.kind) {
        .pit_dump => {
            const dump = try sess.dumpPit(ui.alloc);
            defer ui.alloc.free(dump);
            var table = try samsung_pit.parse(ui.alloc, dump, ui.logger);
            defer table.deinit(ui.alloc);
            try sess.endSession();

            var event = ev.PartitionsEvent{ .lun = 0, .sector_size = 512, .luns = 1 };
            for (table.entries[0..table.count]) |*e| {
                if (event.count >= ev.max_partition_rows) {
                    ui.logger.warn("PIT has more than {d} partitions — the rest are not shown", .{ev.max_partition_rows});
                    break;
                }
                event.parts[event.count] = .{
                    .index = e.partition_id,
                    .first_lba = e.block_size,
                    .last_lba = e.block_size + @max(e.block_count, 1) - 1,
                    .name = ev.FixedStr(72).fromSlice(e.nameSlice()),
                };
                event.count += 1;
            }
            ui.logger.info("✓ PIT loaded: {d} partitions", .{event.count});
            ui.channel.push(.{ .partitions = event });
            ui.channel.push(.{ .session_state = .samsung_ready });
        },
        .flash, .erase => {
            // Thor's flow: dump the PIT to resolve the partition entry,
            // SetTotalBytes, then stream the image (or zeros for an erase).
            const dump = try sess.dumpPit(ui.alloc);
            defer ui.alloc.free(dump);
            var table = try samsung_pit.parse(ui.alloc, dump, ui.logger);
            defer table.deinit(ui.alloc);
            const name = ctx.partition[0..ctx.partition_len];
            const entry = table.find(name) orelse {
                ui.logger.err("Odin: partition \"{s}\" is not in the device PIT", .{name});
                return error.PartitionNotFound;
            };

            var file: ?fileio.File = null;
            defer if (file != null) file.?.close();
            if (ctx.kind == .flash) {
                file = try fileio.File.open(ctx.path.?);
                ctx.length = try file.?.size();
            }
            try sess.setTotalBytes(ctx.length);
            try sess.flashPartition(if (file) |*f| f else null, entry.*, ctx.length, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
            try sess.endSession();
        },
        .flash_pit => {
            const data = try fileio.readFileAlloc(ui.alloc, ctx.path.?, 1024 * 1024);
            defer ui.alloc.free(data);
            try sess.flashPit(data);
            try sess.endSession();
        },
        .bundle => {
            var archive = try samsungtar.list(ui.alloc, ctx.path.?, ui.logger);
            defer archive.deinit(ui.alloc);
            const dump = try sess.dumpPit(ui.alloc);
            defer ui.alloc.free(dump);
            var table = try samsung_pit.parse(ui.alloc, dump, ui.logger);
            defer table.deinit(ui.alloc);

            // Resolve every image member against the PIT's file names and
            // verify its .md5 companion before anything touches the device.
            const Job = struct {
                member: *const samsungtar.Member,
                entry: samsung_pit.Entry,
                md5: ?*const samsungtar.Member,
            };
            var jobs = std.ArrayList(Job).empty;
            defer jobs.deinit(ui.alloc);
            for (archive.members[0..archive.count]) |*m| {
                if (m.isMd5()) continue;
                var matched: ?samsung_pit.Entry = null;
                for (table.entries[0..table.count]) |*e| {
                    if (std.ascii.eqlIgnoreCase(e.fileNameSlice(), m.nameSlice())) {
                        matched = e.*;
                        break;
                    }
                }
                const entry = matched orelse {
                    ui.logger.warn("bundle: \"{s}\" matches no PIT file name — skipped", .{m.nameSlice()});
                    continue;
                };
                const md5_member = blk: {
                    var name_buf: [136]u8 = undefined;
                    const md5_name = std.fmt.bufPrint(&name_buf, "{s}.md5", .{m.nameSlice()}) catch break :blk null;
                    break :blk archive.find(md5_name);
                };
                if (md5_member) |mm| {
                    var file = try fileio.File.open(ctx.path.?);
                    defer file.close();
                    var hex_buf: [64]u8 = undefined;
                    file.seekTo(mm.data_offset) catch return error.Io;
                    const n = try file.readAll(hex_buf[0..]);
                    const ok = try samsungtar.verifyMd5(ui.alloc, ctx.path.?, m, hex_buf[0..n], ui.logger);
                    if (!ok) {
                        ui.logger.err("bundle: \"{s}\" failed its md5 checksum — aborting before any write", .{m.nameSlice()});
                        return error.ChecksumMismatch;
                    }
                    ui.logger.info("bundle: \"{s}\" md5 verified", .{m.nameSlice()});
                }
                try jobs.append(ui.alloc, .{ .member = m, .entry = entry, .md5 = md5_member });
            }
            if (jobs.items.len == 0) {
                ui.logger.err("bundle: no image member matched a PIT file name", .{});
                return error.NothingToFlash;
            }

            var tar_file = try fileio.File.open(ctx.path.?);
            defer tar_file.close();

            var tmp = try fileio.TempDirDyn.init(ui.alloc);
            defer tmp.cleanup();

            const total_jobs: u64 = jobs.items.len;
            var done_jobs: u64 = 0;
            for (jobs.items) |j| {
                if (ui.cancel.load(.acquire)) return error.Cancelled;
                ui.logger.info("bundle: flashing {s} ({d}/{d})", .{ j.member.nameSlice(), done_jobs + 1, total_jobs });
                try tar_file.seekTo(j.member.data_offset);

                var raw_len: u64 = j.member.size;

                var probe: [4]u8 = undefined;
                _ = try tar_file.readAll(&probe);
                try tar_file.seekTo(j.member.data_offset);
                const is_sparse = sparse_mod.isSparse(&probe);

                // Sparse members expand to a temp raw file; plain members
                // stream straight from the shared tar handle (the Huawei
                // flow's using_tmp pattern — only close what WE opened).
                var using_tmp = false;
                var member_file: fileio.File = tar_file;
                defer if (using_tmp) member_file.close();
                if (is_sparse) {
                    var raw_path_buf: [300]u8 = undefined;
                    const raw_path = try tmp.filePath(&raw_path_buf, "member.raw");
                    tmp.track("member.raw") catch {};
                    const raw_size = try sparse_mod.convertToFile(ui.alloc, &tar_file, raw_path, ui.logger);
                    member_file = try fileio.File.open(raw_path);
                    using_tmp = true;
                    raw_len = raw_size;
                    ui.logger.info("bundle: \"{s}\" sparse → raw ({d} bytes)", .{ j.member.nameSlice(), raw_size });
                }

                try sess.setTotalBytes(raw_len);
                try sess.flashPartition(&member_file, j.entry, raw_len, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
                done_jobs += 1;
            }
            try sess.endSession();
            ui.logger.info("✓ bundle flashed: {d}/{d} image(s)", .{ done_jobs, total_jobs });
        },
        .reboot => try sess.reboot(),
        .reboot_download => try sess.rebootToDownloadMode(),
        .factory_reset => {
            try sess.eraseUserData();
            try sess.endSession();
        },
    }
}

fn onSamsungDumpPit(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    const ctx = ui.alloc.create(SamsungJobCtx) catch return;
    ctx.* = .{ .ui = ui, .kind = .pit_dump, .partition = undefined, .partition_len = 0 };
    samsungStageTarget(ui, ctx) catch {
        samsungJobCtxFree(ctx);
        return;
    };
    spawnSamsungJob(ui, ctx);
}

fn onSamsungReboot(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    samsungControlClicked(ui, .reboot);
}

fn onSamsungRebootDownload(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    samsungControlClicked(ui, .reboot_download);
}

fn samsungControlClicked(ui: *Ui, kind: SamsungJobKind) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    const ctx = ui.alloc.create(SamsungJobCtx) catch return;
    ctx.* = .{ .ui = ui, .kind = kind, .partition = undefined, .partition_len = 0 };
    samsungStageTarget(ui, ctx) catch {
        samsungJobCtxFree(ctx);
        return;
    };
    spawnSamsungJob(ui, ctx);
}

fn onSamsungPickPit(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .samsung_pit, "Select PIT file to flash", false, null);
}

fn onSamsungPickBundle(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .samsung_bundle, "Select firmware bundle (tar.md5)", false, null);
}

fn onSamsungFactoryReset(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    confirmDialog(ui, "Factory reset?", "This performs the Odin factory reset: the userdata partition is formatted. ALL DATA IS LOST. This is IRREVERSIBLE.", "Erase", .destructive, .samsung_factory);
}

// ----------------------------------------------------------------------
// LG LAF (download mode, one-shot jobs)
// ----------------------------------------------------------------------

const LgJobKind = enum { gpt, read, write, erase, reboot, poweroff };

const LgJobCtx = struct {
    ui: *Ui,
    kind: LgJobKind,
    target: ?transport.Target = null,
    target_serial_buf: ?[]u8 = null,
    /// Local file path (read destination / write source) — owned.
    path: ?[]u8 = null,
    row: ev.PartitionRow = .{},
};

fn lgJobCtxFree(ctx: *LgJobCtx) void {
    const alloc = ctx.ui.alloc;
    if (ctx.target_serial_buf) |b| alloc.free(b);
    if (ctx.path) |p| alloc.free(p);
    alloc.destroy(ctx);
}

fn lgStageTarget(ui: *Ui, ctx: *LgJobCtx) !void {
    if (activeTarget(ui)) |t| {
        var copy = t;
        if (t.serial) |ser| {
            const dup = try ui.alloc.dupe(u8, ser);
            ctx.target_serial_buf = dup;
            copy.serial = dup;
        }
        ctx.target = copy;
    }
}

fn spawnLgJob(ui: *Ui, ctx: *LgJobCtx) void {
    ui.startJob();
    const thread = std.Thread.spawn(.{}, lgRun, .{ctx}) catch {
        ui.jobDone();
        lgJobCtxFree(ctx);
        ui.toast("Failed to start worker thread");
        return;
    };
    if (ui.lg_thread) |old| old.join();
    ui.lg_thread = thread;
}

/// Open a LAF session on the block device: hello → OPEN (empty path =
/// /dev/block/mmcblk0 read-write). The caller closes the session.
fn lgOpenDisk(ctx: *LgJobCtx, sess: *lg_laf.Session) transport.Error!u32 {
    const ui = ctx.ui;
    var usb_dev = try usb.open(&lg_usb_ids.policy, ctx.target, 8000, ui.logger, ui.alloc, &ui.cancel);
    defer usb_dev.close();
    var io = transport.Io.init(ui.alloc, usb_dev.transport());
    errdefer io.deinit();
    sess.* = .{ .alloc = ui.alloc, .io = &io, .logger = ui.logger, .cancel = &ui.cancel };
    try sess.init();
    try sess.hello();
    return try sess.openDevice("");
}

fn lgRun(ctx: *LgJobCtx) void {
    const ui = ctx.ui;
    defer lgJobCtxFree(ctx);
    lgRunInner(ctx) catch |e| {
        var mbuf: [320]u8 = undefined;
        const msg = switch (ctx.kind) {
            .gpt => std.fmt.bufPrint(&mbuf, "GPT read failed: {s}", .{@errorName(e)}) catch "GPT read failed",
            .read => std.fmt.bufPrint(&mbuf, "read of {s} failed: {s}", .{ ctx.row.name.slice(), @errorName(e) }) catch "read failed",
            .write => std.fmt.bufPrint(&mbuf, "write to {s} failed: {s}", .{ ctx.row.name.slice(), @errorName(e) }) catch "write failed",
            .erase => std.fmt.bufPrint(&mbuf, "erase of {s} failed: {s}", .{ ctx.row.name.slice(), @errorName(e) }) catch "erase failed",
            .reboot, .poweroff => std.fmt.bufPrint(&mbuf, "control command failed: {s}", .{@errorName(e)}) catch "control failed",
        };
        var m = ev.FixedStr(512){};
        m.set(msg);
        ui.channel.push(.{ .finished = .{ .success = false, .message = m } });
        return;
    };
    var m = ev.FixedStr(512){};
    m.set(switch (ctx.kind) {
        .gpt => "partitions loaded",
        .read => "read finished",
        .write => "write finished",
        .erase => "erase finished",
        .reboot => "device rebooted",
        .poweroff => "device powered off",
    });
    ui.channel.push(.{ .finished = .{ .success = true, .message = m } });
}

fn lgRunInner(ctx: *LgJobCtx) !void {
    const ui = ctx.ui;
    var sess: lg_laf.Session = undefined;
    var sess_open = false;
    errdefer if (sess_open) sess.deinit();
    // lgOpenDisk assigns sess BEFORE any error return; sess_open must flip
    // only on success or the errdefer deinits an undefined session.
    const fd = try lgOpenDisk(ctx, &sess);
    sess_open = true;
    defer sess.deinit();

    switch (ctx.kind) {
        .gpt => {
            // 34 sectors at LBA 0: protective MBR + GPT header + entry array.
            var buf: [34 * 512]u8 = undefined;
            try sess.readAt(fd, 0, &buf, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
            const header = gpt_mod.parseHeader(&buf, 512) catch |e| {
                ui.logger.err("LG: no valid GPT on the eMMC: {s}", .{@errorName(e)});
                return e;
            };
            const list = try gpt_mod.parseEntries(ui.alloc, buf[2 * 512 ..], header, 512);
            defer list.deinit(ui.alloc);

            var event = ev.PartitionsEvent{ .lun = 0, .sector_size = 512, .luns = 1 };
            for (list.items()) |p| {
                if (event.count >= ev.max_partition_rows) break;
                event.parts[event.count] = .{
                    .index = p.index,
                    .first_lba = p.first_lba,
                    .last_lba = p.last_lba,
                    .name = ev.FixedStr(72).fromSlice(p.nameSlice()),
                };
                event.count += 1;
            }
            ui.logger.info("✓ GPT loaded: {d} partitions", .{event.count});
            ui.channel.push(.{ .partitions = event });
            ui.channel.push(.{ .session_state = .lg_ready });
            try sess.close(fd);
        },
        .read => {
            var out = try fileio.File.create(ctx.path.?);
            defer out.close();
            const total: u64 = ctx.row.sectors() * 512;
            var done: u64 = 0;
            var buf: [lg_laf.chunk_max]u8 = undefined;
            while (done < total) {
                if (ui.cancel.load(.acquire)) return error.Cancelled;
                const want: usize = @intCast(@min(total - done, lg_laf.chunk_max));
                try sess.readAt(fd, ctx.row.first_lba + done / 512, buf[0..want], .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
                if ((try out.writeAll(buf[0..want])) != want) return error.Io;
                done += want;
            }
            try sess.close(fd);
            ui.logger.info("✓ read {s} ({d} bytes) to {s}", .{ ctx.row.name.slice(), total, ctx.path.? });
        },
        .write => {
            var img = try fileio.File.open(ctx.path.?);
            defer img.close();
            const img_size = try img.size();
            const part_size: u64 = ctx.row.sectors() * 512;
            if (img_size > part_size) {
                ui.logger.err("LG: image ({d} bytes) is larger than {s} ({d} bytes)", .{ img_size, ctx.row.name.slice(), part_size });
                return error.ImageTooLarge;
            }
            if (ctx.row.first_lba < 34) {
                ui.logger.err("LG: refusing to write inside the GPT area", .{});
                return error.Io;
            }
            var done: u64 = 0;
            var buf: [lg_laf.chunk_max]u8 = undefined;
            while (done < img_size) {
                if (ui.cancel.load(.acquire)) return error.Cancelled;
                const want: usize = @intCast(@min(img_size - done, lg_laf.chunk_max));
                if ((try img.readAll(buf[0..want])) != want) return error.Io;
                try sess.writeAt(fd, ctx.row.first_lba + done / 512, buf[0..want], .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
                done += want;
            }
            try sess.close(fd);
            ui.logger.info("✓ wrote {d} bytes to {s}", .{ img_size, ctx.row.name.slice() });
        },
        .erase => {
            // TRIM: the reference notes old data reads back until reboot.
            try sess.eraseSectors(fd, @intCast(ctx.row.first_lba), @intCast(ctx.row.sectors()));
            try sess.close(fd);
            ui.logger.info("✓ TRIM issued for {s} — the erase lands on reboot", .{ctx.row.name.slice()});
        },
        .reboot => {
            try sess.ctrl("RSET");
            ui.logger.info("✓ reboot requested", .{});
        },
        .poweroff => {
            try sess.ctrl("POFF");
            ui.logger.info("✓ power-off requested", .{});
        },
    }
}

fn onLgLoadGpt(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    const ctx = ui.alloc.create(LgJobCtx) catch return;
    ctx.* = .{ .ui = ui, .kind = .gpt };
    lgStageTarget(ui, ctx) catch {
        lgJobCtxFree(ctx);
        return;
    };
    spawnLgJob(ui, ctx);
}

fn onLgReboot(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    lgControlClicked(ui, .reboot);
}

fn onLgPowerOff(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    lgControlClicked(ui, .poweroff);
}

fn lgControlClicked(ui: *Ui, kind: LgJobKind) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    const ctx = ui.alloc.create(LgJobCtx) catch return;
    ctx.* = .{ .ui = ui, .kind = kind };
    lgStageTarget(ui, ctx) catch {
        lgJobCtxFree(ctx);
        return;
    };
    spawnLgJob(ui, ctx);
}

// ----------------------------------------------------------------------
// MediaTek / Unisoc probe jobs
// ----------------------------------------------------------------------

const MtkJobKind = enum { probe, da_upload, read, write, format };

const MtkProbeCtx = struct {
    ui: *Ui,
    kind: MtkJobKind = .probe,
    target: ?transport.Target = null,
    target_serial_buf: ?[]u8 = null,
    /// DA file path (da_upload) / image path (write) / dump path (read).
    path: ?[]u8 = null,
    /// DA load address (hex entry, main-thread parsed).
    addr: u32 = 0x00200000,
    /// Flash address/length for the DA flash ops (main-thread parsed).
    flash_addr: u64 = 0,
    flash_len: u64 = 0,

    fn free(self: *MtkProbeCtx) void {
        const alloc = self.ui.alloc;
        if (self.target_serial_buf) |b| alloc.free(b);
        if (self.path) |p| alloc.free(p);
        alloc.destroy(self);
    }
};

fn mtkProbeRun(ctx: *MtkProbeCtx) void {
    const ui = ctx.ui;
    defer ctx.free();
    mtkProbeInner(ctx) catch |e| {
        var m = ev.FixedStr(512){};
        m.set(std.fmt.bufPrint(&m2_buf, "MTK probe failed: {s}", .{@errorName(e)}) catch "MTK probe failed");
        ui.channel.push(.{ .finished = .{ .success = false, .message = m } });
        return;
    };
    if (ctx.kind == .da_upload) {
        // handleEvent owns this flag (worker → main ordering via the event).
        // The finished handler sets it by message match below.
    }
    var m = ev.FixedStr(512){};
    m.set(switch (ctx.kind) {
        .probe => "chip info read",
        .da_upload => "DA uploaded and started",
        .read => "read finished",
        .write => "write finished",
        .format => "format finished",
    });
    ui.channel.push(.{ .finished = .{ .success = true, .message = m } });
}

var m2_buf: [128]u8 = undefined;

fn mtkProbeInner(ctx: *MtkProbeCtx) !void {
    const ui = ctx.ui;
    var usb_dev = try usb.open(&mtk_usb_ids.policy, ctx.target, 8000, ui.logger, ui.alloc, &ui.cancel);
    defer usb_dev.close();
    var io = transport.Io.init(ui.alloc, usb_dev.transport());
    defer io.deinit();
    var sess = mtk_brom.Session{ .alloc = ui.alloc, .io = &io, .logger = ui.logger, .cancel = &ui.cancel };
    try sess.configurePort();
    var info = try sess.getHwCode();
    try sess.getHwSwVer(&info);
    ui.logger.info("✓ MTK chip: HW code 0x{X:0>4} (sub 0x{X:0>4}), SW version {d}.{d}.{d}.{d}", .{
        info.hw_code, info.hw_sub_code, info.sw_ver[0], info.sw_ver[1], info.sw_ver[2], info.sw_ver[3],
    });

    switch (ctx.kind) {
        .probe => {},
        .da_upload => {
            const data = try fileio.readFileAlloc(ui.alloc, ctx.path.?, 64 * 1024 * 1024);
            defer ui.alloc.free(data);
            ui.logger.info("MTK: uploading DA ({d} bytes) to 0x{X:0>8}…", .{ data.len, ctx.addr });
            try sess.sendDa(ctx.addr, data, 0, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
            try sess.jumpDa(ctx.addr);
        },
        .read, .write, .format => {
            // The device has rebooted into the DA after JUMP_DA: a fresh
            // open + DA session (the BROM transport is gone).
            var da_sess: mtk_daflash.Session = undefined;
            var da_usb = try usb.open(&mtk_usb_ids.policy, ctx.target, 15000, ui.logger, ui.alloc, &ui.cancel);
            defer da_usb.close();
            var da_io = transport.Io.init(ui.alloc, da_usb.transport());
            defer da_io.deinit();
            da_sess = .{ .alloc = ui.alloc, .io = &da_io, .logger = ui.logger, .cancel = &ui.cancel };
            try da_sess.checkStatus();

            switch (ctx.kind) {
                .read => {
                    const buf = try ui.alloc.alloc(u8, @intCast(ctx.flash_len));
                    defer ui.alloc.free(buf);
                    try da_sess.readFlash(ctx.flash_addr, buf, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
                    var out = try fileio.File.create(ctx.path.?);
                    defer out.close();
                    if ((try out.writeAll(buf)) != buf.len) return error.Io;
                    try out.flush();
                    ui.logger.info("✓ read {d} bytes from 0x{X:0>8}", .{ ctx.flash_len, ctx.flash_addr });
                },
                .write => {
                    var img = try fileio.File.open(ctx.path.?);
                    defer img.close();
                    const img_size = try img.size();
                    if (img_size > ctx.flash_len) {
                        ui.logger.err("MTK: image ({d} B) exceeds the staged size ({d} B)", .{ img_size, ctx.flash_len });
                        return error.ImageTooLarge;
                    }
                    const buf = try ui.alloc.alloc(u8, @intCast(img_size));
                    defer ui.alloc.free(buf);
                    if ((try img.readAll(buf)) != img_size) return error.Io;
                    try da_sess.writeFlash(ctx.flash_addr, buf, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
                    ui.logger.info("✓ wrote {d} bytes to 0x{X:0>8}", .{ img_size, ctx.flash_addr });
                },
                .format => {
                    try da_sess.formatFlash(ctx.flash_addr, ctx.flash_len, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
                    ui.logger.info("✓ formatted {d} bytes at 0x{X:0>8}", .{ ctx.flash_len, ctx.flash_addr });
                },
                else => unreachable,
            }
        },
    }
}

fn onMtkPickDa(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .mtk_da, "Select Download Agent (DA)", false, null);
}

fn mtkStageTarget(ui: *Ui, ctx: *MtkProbeCtx) !void {
    if (activeTarget(ui)) |t| {
        var copy = t;
        if (t.serial) |ser| {
            const dup = try ui.alloc.dupe(u8, ser);
            ctx.target_serial_buf = dup;
            copy.serial = dup;
        }
        ctx.target = copy;
    }
}

fn onMtkUploadDa(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    const path = ui.mtk_da_path orelse {
        ui.toast("Choose a Download Agent (DA) file first");
        return;
    };
    var addr: u32 = 0x00200000;
    if (ui.mtk_da_addr_entry) |e| {
        const raw = gtk.Editable.getText(@ptrCast(e));
        addr = std.fmt.parseInt(u32, std.mem.trim(u8, std.mem.span(raw), " "), 0) catch {
            ui.toast("Invalid DA load address");
            return;
        };
    }
    const ctx = ui.alloc.create(MtkProbeCtx) catch return;
    ctx.* = .{ .ui = ui, .kind = .da_upload, .addr = addr };
    ctx.path = ui.alloc.dupe(u8, path) catch {
        ctx.free();
        return;
    };
    mtkStageTarget(ui, ctx) catch {
        ctx.free();
        return;
    };
    ui.startJob();
    const thread = std.Thread.spawn(.{}, mtkProbeRun, .{ctx}) catch {
        ui.jobDone();
        ctx.free();
        ui.toast("Failed to start worker thread");
        return;
    };
    if (ui.mtk_thread) |old| old.join();
    ui.mtk_thread = thread;
}

/// Parse the MTK flash address/size entries (main thread). Returns false
/// with a toast when malformed or the DA is not running.
fn mtkStageRange(ui: *Ui) bool {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return false;
    }
    if (!ui.mtk_da_ready) {
        ui.toast("Upload the DA first — flash operations need the agent running");
        return false;
    }
    var addr_txt: []const u8 = "";
    if (ui.mtk_flash_addr_entry) |e| addr_txt = std.mem.span(gtk.Editable.getText(@ptrCast(e)));
    var size_txt: []const u8 = "";
    if (ui.mtk_flash_size_entry) |e| size_txt = std.mem.span(gtk.Editable.getText(@ptrCast(e)));
    ui.mtk_stage_addr = std.fmt.parseInt(u64, std.mem.trim(u8, addr_txt, " "), 0) catch {
        ui.toast("Invalid flash address");
        return false;
    };
    ui.mtk_stage_size = std.fmt.parseInt(u64, std.mem.trim(u8, size_txt, " "), 10) catch {
        ui.toast("Invalid size");
        return false;
    };
    if (ui.mtk_stage_size == 0) {
        ui.toast("Size must be greater than zero");
        return false;
    }
    return true;
}

fn spawnMtkJob(ui: *Ui, ctx: *MtkProbeCtx) void {
    ui.startJob();
    const thread = std.Thread.spawn(.{}, mtkProbeRun, .{ctx}) catch {
        ui.jobDone();
        ctx.free();
        ui.toast("Failed to start worker thread");
        return;
    };
    if (ui.mtk_thread) |old| old.join();
    ui.mtk_thread = thread;
}

fn onMtkFlashRead(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (!mtkStageRange(ui)) return;
    openChooser(ui, .mtk_read, "Save flash dump", true, "flash.bin");
}

fn onMtkFlashWrite(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (!mtkStageRange(ui)) return;
    ui.mtk_write_pick = true;
    openChooser(ui, .mtk_read, "Select image to write", false, null);
}

fn onMtkFlashFormat(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (!mtkStageRange(ui)) return;
    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "Format {d} bytes of flash at 0x{X:0>8}?\n\nThis is IRREVERSIBLE.", .{ ui.mtk_stage_size, ui.mtk_stage_addr }) catch return;
    confirmDialog(ui, "Format flash?", body, "Format", .destructive, .mtk_format);
}

fn onMtkProbe(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    const ctx = ui.alloc.create(MtkProbeCtx) catch return;
    ctx.* = .{ .ui = ui };
    if (activeTarget(ui)) |t| {
        var copy = t;
        if (t.serial) |ser| {
            const dup = ui.alloc.dupe(u8, ser) catch {
                ui.alloc.destroy(ctx);
                return;
            };
            ctx.target_serial_buf = dup;
            copy.serial = dup;
        }
        ctx.target = copy;
    }
    ui.startJob();
    const thread = std.Thread.spawn(.{}, mtkProbeRun, .{ctx}) catch {
        ui.jobDone();
        ctx.free();
        ui.toast("Failed to start worker thread");
        return;
    };
    if (ui.mtk_thread) |old| old.join();
    ui.mtk_thread = thread;
}

const SpdJobKind = enum { probe, fdl_upload, read, write, erase };

const SpdProbeCtx = struct {
    ui: *Ui,
    kind: SpdJobKind = .probe,
    target: ?transport.Target = null,
    target_serial_buf: ?[]u8 = null,
    /// FDL1/FDL2/image file path (owned).
    path: ?[]u8 = null,
    path2: ?[]u8 = null,
    addr: u32 = 0,
    size: u32 = 0,
    /// Partition name for name-addressed ops (owned, null = address mode).
    pname: ?[]u8 = null,

    fn free(self: *SpdProbeCtx) void {
        const alloc = self.ui.alloc;
        if (self.target_serial_buf) |b| alloc.free(b);
        if (self.path) |p| alloc.free(p);
        if (self.path2) |p| alloc.free(p);
        if (self.pname) |p| alloc.free(p);
        alloc.destroy(self);
    }
};

fn spdProbeRun(ctx: *SpdProbeCtx) void {
    const ui = ctx.ui;
    defer ctx.free();
    spdProbeInner(ctx) catch |e| {
        var m = ev.FixedStr(512){};
        m.set(std.fmt.bufPrint(&m3_buf, "Unisoc op failed: {s}", .{@errorName(e)}) catch "Unisoc op failed");
        ui.channel.push(.{ .finished = .{ .success = false, .message = m } });
        return;
    };
    var m = ev.FixedStr(512){};
    m.set(switch (ctx.kind) {
        .probe => "bootrom version read",
        .fdl_upload => "FDLs uploaded — flash operations unlocked",
        .read => "read finished",
        .write => "write finished",
        .erase => "erase finished",
    });
    ui.channel.push(.{ .finished = .{ .success = true, .message = m } });
}

var m3_buf: [160]u8 = undefined;

/// FDL load addresses — the values spreadtrum_flash's own FDL binaries are
/// built for (feature-phone NOR pair; both stay user-visible in the CLI
/// reference). The FDL headers carry their own load info on UMS chips.
const spd_fdl1_addr: u32 = 0x40002000;
const spd_fdl2_addr: u32 = 0x9efffe00;

fn spdProbeInner(ctx: *SpdProbeCtx) !void {
    const ui = ctx.ui;
    var usb_dev = try usb.open(&spd_usb_ids.policy, ctx.target, 8000, ui.logger, ui.alloc, &ui.cancel);
    defer usb_dev.close();
    var io = transport.Io.init(ui.alloc, usb_dev.transport());
    defer io.deinit();
    var sess = spd_bsl.Session{ .alloc = ui.alloc, .io = &io, .logger = ui.logger, .cancel = &ui.cancel };
    defer sess.deinit();
    try sess.configurePort();
    switch (ctx.kind) {
        .probe => {
            var ver_buf: [64]u8 = undefined;
            const n = try sess.probe(ver_buf[0..]);
            ui.logger.info("✓ Unisoc bootrom: {s}", .{ver_buf[0..n]});
        },
        .fdl_upload => {
            const fdl1 = try fileio.readFileAlloc(ui.alloc, ctx.path.?, 8 * 1024 * 1024);
            defer ui.alloc.free(fdl1);
            const fdl2 = try fileio.readFileAlloc(ui.alloc, ctx.path2.?, 8 * 1024 * 1024);
            defer ui.alloc.free(fdl2);
            // The loader consumes the first frame after sync as the version
            // request: CHECK_BAUD + CONNECT precede BOTH stages (spd_dump).
            var ver_buf: [64]u8 = undefined;
            _ = try sess.checkBaudConnect(1, ver_buf[0..]);
            ui.logger.info("SPD: bootrom {s}", .{ver_buf[0..@min(ver_buf.len, 64)]});
            ui.logger.info("SPD: uploading FDL1 ({d} bytes)…", .{fdl1.len});
            try sess.fdlUpload(fdl1, spd_fdl1_addr, spd_bsl.exec_timeout_ms);
            ui.logger.info("✓ FDL1 running — switching to the FDL2 checksum stage", .{});
            sess.setStage(false);
            // FDL1's replacement re-syncs the same way, with 4 bare 0x7E
            // bytes retried up to 10×.
            _ = try sess.checkBaudConnect(4, ver_buf[0..]);
            ui.logger.info("SPD: FDL1 {s}", .{ver_buf[0..@min(ver_buf.len, 64)]});
            ui.logger.info("SPD: uploading FDL2 ({d} bytes)…", .{fdl2.len});
            try sess.fdlUpload(fdl2, spd_fdl2_addr, spd_bsl.exec_timeout_ms);
            ui.logger.info("✓ FDL2 running — flash operations unlocked", .{});
            ui.channel.push(.{ .session_state = .spd_ready });
        },
        .read => {
            if (ctx.pname) |pname| {
                const buf = try ui.alloc.alloc(u8, ctx.size);
                defer ui.alloc.free(buf);
                try sess.partitionRead(pname, buf, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
                var out = try fileio.File.create(ctx.path.?);
                defer out.close();
                if ((try out.writeAll(buf)) != buf.len) return error.Io;
                try out.flush();
                ui.logger.info("✓ read partition \"{s}\" ({d} bytes)", .{ pname, ctx.size });
            } else {
                const buf = try ui.alloc.alloc(u8, ctx.size);
                defer ui.alloc.free(buf);
                try sess.flashRead(ctx.addr, 0, ctx.size, buf, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
                var out = try fileio.File.create(ctx.path.?);
                defer out.close();
                if ((try out.writeAll(buf)) != buf.len) return error.Io;
                try out.flush();
                ui.logger.info("✓ read {d} bytes from 0x{X:0>8}", .{ ctx.size, ctx.addr });
            }
        },
        .write => {
            var img = try fileio.File.open(ctx.path.?);
            defer img.close();
            const img_size = try img.size();
            if (img_size > 0xffff_0000) return error.ImageTooLarge;
            const buf = try ui.alloc.alloc(u8, @intCast(img_size));
            defer ui.alloc.free(buf);
            if ((try img.readAll(buf)) != img_size) return error.Io;
            if (ctx.pname) |pname| {
                try sess.partitionWrite(pname, buf, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
                ui.logger.info("✓ wrote {d} bytes to partition \"{s}\"", .{ img_size, pname });
            } else {
                try sess.flashWrite(ctx.addr, buf, .{ .ctx = @ptrCast(ctx.ui.channel), .cb = &vendorProgressCb });
                ui.logger.info("✓ wrote {d} bytes to 0x{X:0>8}", .{ img_size, ctx.addr });
            }
        },
        .erase => {
            if (ctx.pname) |pname| {
                try sess.partitionErase(pname);
                ui.logger.info("✓ erase issued for partition \"{s}\"", .{pname});
            } else {
                try sess.flashErase(ctx.addr, ctx.size);
                ui.logger.info("✓ erased {d} bytes at 0x{X:0>8}", .{ ctx.size, ctx.addr });
            }
        },
    }
}

fn onSpdPickFdl1(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .spd_fdl1, "Select FDL1 loader", false, null);
}

fn onSpdPickFdl2(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .spd_fdl2, "Select FDL2 loader", false, null);
}

fn onSpdFlashRead(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (!spdStageRange(ui, .read)) return;
    openChooser(ui, .spd_write, "Save flash dump", true, "flash.bin");
}

fn onSpdFlashWrite(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (!spdStageRange(ui, .write)) return;
    ui.spd_write_pick = true;
    openChooser(ui, .spd_write, "Select image to write", false, null);
}

fn onSpdFlashErase(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (!spdStageRange(ui, .erase)) return;
    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "Erase {d} bytes of flash at 0x{X:0>8}?\n\nThis is IRREVERSIBLE.", .{ ui.spd_stage_size, ui.spd_stage_addr }) catch return;
    confirmDialog(ui, "Erase flash?", body, "Erase", .destructive, .spd_erase);
}

/// Parse the address/size entries (main thread) and stage an op; returns
/// false (with a toast) when the entries are missing or malformed.
fn spdStageRange(ui: *Ui, kind: SpdJobKind) bool {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return false;
    }
    if (ui.session != .spd_ready) {
        ui.toast("Upload the FDLs first — flash operations need FDL2 running");
        return false;
    }
    var addr_txt: []const u8 = "";
    if (ui.spd_addr_entry) |e| addr_txt = std.mem.span(gtk.Editable.getText(@ptrCast(e)));
    var size_txt: []const u8 = "";
    if (ui.spd_size_entry) |e| size_txt = std.mem.span(gtk.Editable.getText(@ptrCast(e)));
    ui.spd_stage_addr = std.fmt.parseInt(u32, std.mem.trim(u8, addr_txt, " "), 0) catch {
        ui.toast("Invalid flash address");
        return false;
    };
    ui.spd_stage_size = std.fmt.parseInt(u32, std.mem.trim(u8, size_txt, " "), 10) catch {
        ui.toast("Invalid size");
        return false;
    };
    if (kind != .write and ui.spd_stage_size == 0) {
        ui.toast("Size must be greater than zero");
        return false;
    }
    // A non-empty partition name switches to FDL2 name-addressed ops.
    ui.spd_stage_name = null;
    if (ui.spd_name_entry) |e| {
        const raw = std.mem.trim(u8, std.mem.span(gtk.Editable.getText(@ptrCast(e))), " ");
        if (raw.len > 0) ui.spd_stage_name = ui.alloc.dupe(u8, raw) catch null;
    }
    return true;
}

fn spdStageTarget(ui: *Ui, ctx: *SpdProbeCtx) !void {
    if (activeTarget(ui)) |t| {
        var copy = t;
        if (t.serial) |ser| {
            const dup = try ui.alloc.dupe(u8, ser);
            ctx.target_serial_buf = dup;
            copy.serial = dup;
        }
        ctx.target = copy;
    }
}

fn onSpdUploadFdl(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    if (ui.spd_fdl1_path == null or ui.spd_fdl2_path == null) {
        ui.toast("Choose both FDL1 and FDL2 loaders first");
        return;
    }
    const ctx = ui.alloc.create(SpdProbeCtx) catch return;
    ctx.* = .{ .ui = ui, .kind = .fdl_upload };
    // Both paths are required — a dupe failure aborts the spawn cleanly
    // instead of leaving a null the worker would unwrap.
    if (ui.spd_fdl1_path) |p| {
        ctx.path = ui.alloc.dupe(u8, p) catch {
            ctx.free();
            ui.toast("Out of memory");
            return;
        };
    } else {
        ctx.free();
        return;
    }
    if (ui.spd_fdl2_path) |p| {
        ctx.path2 = ui.alloc.dupe(u8, p) catch {
            ctx.free();
            ui.toast("Out of memory");
            return;
        };
    } else {
        ctx.free();
        return;
    }
    spdStageTarget(ui, ctx) catch {
        ctx.free();
        return;
    };
    ui.startJob();
    const thread = std.Thread.spawn(.{}, spdProbeRun, .{ctx}) catch {
        ui.jobDone();
        ctx.free();
        ui.toast("Failed to start worker thread");
        return;
    };
    if (ui.spd_thread) |old| old.join();
    ui.spd_thread = thread;
}

fn onSpdProbe(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    const ctx = ui.alloc.create(SpdProbeCtx) catch return;
    ctx.* = .{ .ui = ui };
    if (activeTarget(ui)) |t| {
        var copy = t;
        if (t.serial) |ser| {
            const dup = ui.alloc.dupe(u8, ser) catch {
                ui.alloc.destroy(ctx);
                return;
            };
            ctx.target_serial_buf = dup;
            copy.serial = dup;
        }
        ctx.target = copy;
    }
    ui.startJob();
    const thread = std.Thread.spawn(.{}, spdProbeRun, .{ctx}) catch {
        ui.jobDone();
        ctx.free();
        ui.toast("Failed to start worker thread");
        return;
    };
    if (ui.spd_thread) |old| old.join();
    ui.spd_thread = thread;
}

// ----------------------------------------------------------------------
// UFS provisioning
// ----------------------------------------------------------------------

fn onPickUfsXml(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .ufs_xml, "Select UFS provisioning XML", false, null);
}

fn onClearUfsXml(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.ufs_xml_path) |p| ui.alloc.free(p);
    ui.ufs_xml_path = null;
    adw.ActionRow.setSubtitle(ui.ufs_row.?, "None selected — vendor-provided <ufs> layout");
    gtk.Widget.setSensitive(ui.ufs_btn.?.as(gtk.Widget), 0);
}

fn onUfsProvisionClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    if (ui.ufs_xml_path == null) {
        ui.toast("Choose the vendor provisioning XML first");
        return;
    }
    readStorageSelection(ui);
    if (ui.storage != .ufs) {
        ui.toast("UFS provisioning needs the storage type set to UFS");
        return;
    }

    const finalize = ui.ufs_finalize_sw != null and gtk.Switch.getActive(ui.ufs_finalize_sw.?) != 0;
    var body_buf: [700]u8 = undefined;
    const body = if (finalize)
        std.fmt.bufPrint(&body_buf, "Commit the UFS configuration with bConfigDescrLock=1?\n\nThis is an OTP (one-time-programmable) operation: it CANNOT be undone and may permanently lock the storage configuration. The XML is first validated with commit=0, then committed.", .{}) catch return
    else
        std.fmt.bufPrint(&body_buf, "Run UFS provisioning from the selected XML?\n\nThe configuration is first validated (commit=0) and only then committed. Without the OTP lock the operation is repeatable.", .{}) catch return;

    const heading: [:0]const u8 = if (finalize) "IRREVERSIBLE OTP provisioning?" else "Run UFS provisioning?";
    confirmDialog(ui, heading, body, if (finalize) "Lock permanently" else "Provision", .destructive, .provision_ufs);
}

// ----------------------------------------------------------------------
// Huawei UPDATE.APP
// ----------------------------------------------------------------------

const HuaweiParseCtx = struct {
    ui: *Ui,
    path: []u8,
    gen: u32,
};

fn huaweiParseRun(ctx: *HuaweiParseCtx) void {
    const ui = ctx.ui;
    const path = ctx.path;
    defer ui.alloc.free(path);
    defer ui.alloc.destroy(ctx);

    var file = fileio.File.open(path) catch |e| {
        var mbuf: [256]u8 = undefined;
        var m = ev.FixedStr(512){};
        m.set(std.fmt.bufPrint(&mbuf, "unable to open UPDATE.APP: {s}", .{@errorName(e)}) catch "unable to open UPDATE.APP");
        ui.channel.push(.{ .finished = .{ .success = false, .message = m } });
        return;
    };
    defer file.close();

    var index = updateapp.parse(ui.alloc, &file, ui.logger) catch |e| {
        var mbuf: [256]u8 = undefined;
        var m = ev.FixedStr(512){};
        m.set(std.fmt.bufPrint(&mbuf, "UPDATE.APP parse failed: {s}", .{@errorName(e)}) catch "UPDATE.APP parse failed");
        ui.channel.push(.{ .finished = .{ .success = false, .message = m } });
        return;
    };
    defer index.deinit(ui.alloc);

    var event = ev.HuaweiAppEvent{ .gen = ctx.gen };
    for (index.entries.items) |*e| {
        if (event.count >= ev.HuaweiAppEvent.max_entries) break;
        event.entries[event.count] = .{
            .name = ev.FixedStr(36).fromSlice(e.name()),
            .data_size = e.data_size,
            .raw_size = e.raw_size,
            .sparse = e.is_sparse,
        };
        event.count += 1;
    }
    ui.channel.push(.{ .huawei_app = event });
    var m = ev.FixedStr(512){};
    m.set("update.app parsed");
    ui.channel.push(.{ .finished = .{ .success = true, .message = m } });
}

fn onPickHuaweiApp(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .huawei_app_file, "Select Huawei UPDATE.APP", false, null);
}

fn onClearHuaweiApp(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.huawei_path) |p| ui.alloc.free(p);
    ui.huawei_path = null;
    ui.huawei_entries = null;
    adw.ActionRow.setSubtitle(ui.huawei_row.?, "None selected");
    gtk.Widget.setSensitive(ui.huawei_btn.?.as(gtk.Widget), 0);
}

/// Called when the parse worker finishes or the partition list changes.
fn refreshHuaweiRow(ui: *Ui) void {
    const row = ui.huawei_row orelse return;
    if (ui.huawei_entries) |*ent| {
        var buf: [128]u8 = undefined;
        var sparse_count: u32 = 0;
        for (ent.entries[0..ent.count]) |e| {
            if (e.sparse) sparse_count += 1;
        }
        const s = std.fmt.bufPrint(&buf, "{d} images ({d} sparse) — match against LUN {d}", .{ ent.count, sparse_count, currentLun(ui) }) catch "indexed";
        setSubtitleZ(row, s);
        const have_parts = ui.parts != null;
        gtk.Widget.setSensitive(ui.huawei_btn.?.as(gtk.Widget), @intFromBool(!ui.busy() and have_parts));
    } else {
        adw.ActionRow.setSubtitle(row, "None selected");
    }
}

/// Match an UPDATE.APP entry to a partition by name (case-insensitive,
/// ignoring ".img").
fn matchHuaweiEntry(entries: *const ev.HuaweiAppEvent, index: usize, parts: *const ev.PartitionsEvent) ?ev.PartitionRow {
    const ename = entries.entries[index].name.slice();
    for (parts.parts[0..parts.count]) |row| {
        if (updateapp.nameEql(ename, row.name.slice())) return row;
    }
    return null;
}

fn onFlashHuaweiClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy()) {
        ui.toast("Another operation is running — wait for it to finish");
        return;
    }
    if (ui.huawei_path == null) return;
    const entries = &(ui.huawei_entries orelse return);
    const parts = &(ui.parts orelse {
        ui.toast("Load the partition table first (Connect)");
        return;
    });

    // Build the image → partition mapping for the current LUN. Ownership
    // moves to huawei_pending_mappings and is consumed by the dialog
    // response (apply) or freed on dismissal.
    var mappings = std.ArrayList(manager_mod.HuaweiMapping).empty;
    var unmatched: u32 = 0;
    var too_big: u32 = 0;

    var body_buf: [1600]u8 = undefined;
    var len: usize = 0;
    appendFmt(&body_buf, &len, "Flash the following images to LUN {d}?\n\n", .{currentLun(ui)});

    var listed: u32 = 0;
    for (entries.entries[0..entries.count], 0..) |*e, i| {
        const row_opt = matchHuaweiEntry(entries, i, parts);
        const row = row_opt orelse {
            unmatched += 1;
            continue;
        };
        const needed: u64 = (e.raw_size + sectorSizeOf(ui) - 1) / sectorSizeOf(ui);
        if (needed > row.sectors()) {
            too_big += 1;
            continue;
        }
        const dup_entry = ui.alloc.dupe(u8, e.name.slice()) catch continue;
        const dup_label = ui.alloc.dupe(u8, row.name.slice()) catch {
            ui.alloc.free(dup_entry);
            continue;
        };
        mappings.append(ui.alloc, .{
            .entry = dup_entry,
            .first_lba = row.first_lba,
            .max_sectors = row.sectors(),
            .lun = currentLun(ui),
            .label = dup_label,
        }) catch {
            ui.alloc.free(dup_entry);
            ui.alloc.free(dup_label);
            continue;
        };
        if (listed < 8) {
            var size_buf: [32]u8 = undefined;
            const size_txt = util.formatBytes(&size_buf, e.raw_size);
            appendFmt(&body_buf, &len, "· {s} → {s} ({s})\n", .{ e.name.slice(), row.name.slice(), size_txt });
            listed += 1;
        }
    }
    if (entries.count > listed + 0 and unmatched > 0 and listed >= 8) {
        appendFmt(&body_buf, &len, "· …\n", .{});
    }
    if (mappings.items.len == 0) {
        for (mappings.items) |m| {
            ui.alloc.free(m.entry);
            ui.alloc.free(m.label);
        }
        mappings.deinit(ui.alloc);
        ui.toast("No UPDATE.APP image matches a partition on this LUN");
        return;
    }
    if (unmatched > 0) appendFmt(&body_buf, &len, "\n{d} image(s) match no partition and will be skipped.\n", .{unmatched});
    if (too_big > 0) appendFmt(&body_buf, &len, "{d} image(s) are larger than their partition and will be skipped.\n", .{too_big});
    appendFmt(&body_buf, &len, "\nThis overwrites the listed partitions. IRREVERSIBLE. Sparse images are converted to raw first.", .{});

    freeHuaweiPending(ui);
    ui.huawei_pending_mappings = mappings;
    confirmDialog(ui, "Flash Huawei UPDATE.APP?", body_buf[0..len], "Flash", .destructive, .huawei_app);
}

/// Free a stored pending mapping list (dialog dismissed or consumed).
fn freeHuaweiPending(ui: *Ui) void {
    if (ui.huawei_pending_mappings) |*list| {
        for (list.items) |m| {
            ui.alloc.free(m.entry);
            ui.alloc.free(m.label);
        }
        list.deinit(ui.alloc);
        ui.huawei_pending_mappings = null;
    }
}

// ----------------------------------------------------------------------
// Chip identity probe (one-shot worker, pre-connect only)
// ----------------------------------------------------------------------

fn spawnChipProbe(ui: *Ui) !void {
    const ctx = try ui.alloc.create(WorkerCtx);
    ctx.* = .{ .ui = ui };
    if (activeTarget(ui)) |t| {
        var copy = t;
        if (t.serial) |s| {
            const dup = try ui.alloc.dupe(u8, s);
            ctx.target_serial_buf = dup;
            copy.serial = dup;
        }
        ctx.target = copy;
    }
    const thread = try std.Thread.spawn(.{}, chipProbeRun, .{ctx});
    if (ui.probe_thread) |old| old.join();
    ui.probe_thread = thread;
}

fn chipProbeRun(ctx: *WorkerCtx) void {
    const ui = ctx.ui;
    defer {
        if (ctx.target_serial_buf) |b| ui.alloc.free(b);
        ui.alloc.destroy(ctx);
    }
    const channel = ui.channel;
    const info = session_mod.chipInfo(ui.alloc, ui.logger, &ui.cancel, ctx.target, 8000) catch |e| {
        var m = ev.FixedStr(512){};
        m.set(@errorName(e));
        channel.push(.{ .finished = .{ .success = false, .message = m } });
        return;
    };
    channel.push(.{ .chip_info = .{
        .protocol_version = info.protocol_version,
        .serial = info.serial,
        .hwid = info.hwid,
        .msm_id = info.msm_id,
        .oem_id = info.oem_id,
        .model_id = info.model_id,
        .pkhash = ev.FixedStr(140).fromSlice(info.pkhash.slice()),
    } });
    var m = ev.FixedStr(512){};
    m.set("chip info read");
    channel.push(.{ .finished = .{ .success = true, .message = m } });
}

// ----------------------------------------------------------------------
// Console page
// ----------------------------------------------------------------------

fn buildConsolePage(ui: *Ui) *gtk.Widget {
    const page = gtk.Box.new(.vertical, 0);

    const console_header = gtk.Box.new(.horizontal, 8);
    setMargins(console_header.as(gtk.Widget), 8, 12, 12, 8);
    const console_title = gtk.Label.new("Protocol console — every exchange with the device");
    gtk.Widget.setHexpand(console_title.as(gtk.Widget), 1);
    gtk.Widget.setHalign(console_title.as(gtk.Widget), .start);
    gtk.Box.append(console_header, console_title.as(gtk.Widget));
    const copy_btn = gtk.Button.newWithLabel("Copy log");
    _ = gtk.Button.signals.clicked.connect(copy_btn, *Ui, &onCopyLogClicked, ui, .{});
    gtk.Box.append(console_header, copy_btn.as(gtk.Widget));
    gtk.Box.append(page, console_header.as(gtk.Widget));

    const scrolled = gtk.ScrolledWindow.new();
    gtk.ScrolledWindow.setPolicy(scrolled, .automatic, .automatic);
    gtk.Widget.setVexpand(scrolled.as(gtk.Widget), 1);

    const view = gtk.TextView.new();
    gtk.TextView.setEditable(view, 0);
    gtk.TextView.setCursorVisible(view, 0);
    gtk.TextView.setMonospace(view, 1);
    gtk.TextView.setWrapMode(view, .word);
    gtk.TextView.setLeftMargin(view, 8);
    gtk.TextView.setRightMargin(view, 8);
    gtk.Widget.addCssClass(view.as(gtk.Widget), "log-view");
    ui.console_view = view;
    gtk.ScrolledWindow.setChild(scrolled, view.as(gtk.Widget));

    gtk.Box.append(page, scrolled.as(gtk.Widget));

    const buffer = gtk.TextView.getBuffer(view);
    _ = gtk.TextBuffer.createTag(buffer, "t-debug", "foreground", "gray", @as(?*anyopaque, null));
    _ = gtk.TextBuffer.createTag(buffer, "t-warn", "foreground", "orange", @as(?*anyopaque, null));
    _ = gtk.TextBuffer.createTag(buffer, "t-err", "foreground", "red", @as(?*anyopaque, null));

    return page.as(gtk.Widget);
}

fn onCopyLogClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    const view = ui.console_view orelse return;
    const buffer = gtk.TextView.getBuffer(view);
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    gtk.TextBuffer.getStartIter(buffer, &start);
    gtk.TextBuffer.getEndIter(buffer, &end);
    const text_c = gtk.TextBuffer.getText(buffer, &start, &end, 0);
    defer glib.free(text_c);
    const text = std.mem.span(text_c);
    if (text.len == 0) {
        ui.toast("Console is empty");
        return;
    }
    const bytes = glib.Bytes.new(text.ptr, text.len);
    defer glib.Bytes.unref(bytes);
    const provider = gdk.ContentProvider.newForBytes("text/plain", bytes);
    defer provider.unref();
    const clipboard = gtk.Widget.getClipboard(view.as(gtk.Widget));
    _ = gdk.Clipboard.setContent(clipboard, provider);
    ui.toast("Log copied to clipboard");
}

fn consoleAppend(ui: *Ui, text: []const u8, tag: ?[*:0]const u8) void {
    const view = ui.console_view orelse return;
    const buffer = gtk.TextView.getBuffer(view);

    var zbuf: [2100]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{text[0..@min(text.len, zbuf.len - 1)]}) catch return;

    var iter: gtk.TextIter = undefined;
    gtk.TextBuffer.getEndIter(buffer, &iter);
    if (tag) |t| {
        gtk.TextBuffer.insertWithTagsByName(buffer, &iter, z.ptr, -1, t, @as(?*anyopaque, null));
    } else {
        gtk.TextBuffer.insert(buffer, &iter, z.ptr, -1);
    }
    gtk.TextBuffer.placeCursor(buffer, &iter);
    gtk.TextView.scrollMarkOnscreen(view, gtk.TextBuffer.getInsert(buffer));
}

// ----------------------------------------------------------------------
// Event / log pumps (GLib main loop side)
// ----------------------------------------------------------------------

fn onTick(ud: ?*anyopaque) callconv(.c) c_int {
    const ui: *Ui = @ptrCast(@alignCast(ud orelse return 0));
    if (!ui.ready) return 1;
    ui.channel.drain(ui, handleEvent);
    if (ui.channel.takeDropped() > 0) {
        // The 256-slot ring overflowed: the UI missed progress/state events
        // (and possibly a .finished) — say so instead of failing silently.
        ui.logger.warn("event ring overflowed — some progress events were dropped", .{});
    }
    drainLogs(ui);
    return 1; // G_SOURCE_CONTINUE
}

fn onFirstLogDrain(ud: ?*anyopaque) callconv(.c) c_int {
    const ui: *Ui = @ptrCast(@alignCast(ud orelse return 0));
    drainLogs(ui);
    return 0;
}

fn handleEvent(ui: *Ui, event: ev.Event) void {
    switch (event) {
        .device_added => |dev| {
            // Update-or-insert: hotplug events can repeat for one device.
            var replaced = false;
            for (ui.devices.items, 0..) |d, i| {
                if (d.key.eql(dev.key)) {
                    ui.devices.items[i] = dev;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) ui.devices.append(ui.alloc, dev) catch {
                ui.logger.err("out of memory tracking device list", .{});
            };
            syncActiveDevice(ui);
            refreshDeviceSelector(ui);
            refreshMainPage(ui);
            ui.logger.info("device connected: {s} ({x:0>4}:{x:0>4})", .{ dev.mode.displayName(), dev.vid, dev.pid });
        },
        .device_removed => |key| {
            for (ui.devices.items, 0..) |d, i| {
                if (d.key.eql(key)) {
                    _ = ui.devices.orderedRemove(i);
                    break;
                }
            }
            syncActiveDevice(ui);
            refreshDeviceSelector(ui);
            if (ui.device == null and ui.devices.items.len == 0) {
                if (ui.session == .samsung_ready or ui.session == .lg_ready) {
                    // Samsung/LG sessions are one-shot; nothing to tear down.
                } else if (ui.session != .disconnected and ui.manager != null and !ui.busy()) {
                    ui.manager.?.enqueue(.{ .disconnect = {} });
                } else if (ui.session != .disconnected) {
                    ui.cancel.store(true, .release);
                }
                ui.session = .disconnected;
                ui.mtk_da_ready = false;
                refreshMainPage(ui);
                ui.logger.info("device disconnected", .{});
            }
        },
        .progress => |p| {
            if (ui.progress) |bar| {
                gtk.Widget.setVisible(bar.as(gtk.Widget), 1);
                if (ui.spinner) |sp| {
                    gtk.Spinner.stop(sp);
                    gtk.Widget.setVisible(sp.as(gtk.Widget), 0);
                }
                if (p.fraction < 0) {
                    gtk.ProgressBar.pulse(bar);
                    var pz: [200]u8 = undefined;
                    const z = std.fmt.bufPrintZ(&pz, "{s}", .{p.label.slice()}) catch "working…";
                    gtk.ProgressBar.setText(bar, z.ptr);
                } else {
                    const f = @min(p.fraction, 1.0);
                    gtk.ProgressBar.setFraction(bar, f);
                    const pct: u32 = @intFromFloat(f * 100.0);

                    // Throughput: MiB/s over the last progress event (>=250 ms apart).
                    var speed: []const u8 = "";
                    const now = glib.getMonotonicTime();
                    if (p.total > 0 and ui.prog_last_ms != 0 and now > ui.prog_last_ms) {
                        const dt_us = now - ui.prog_last_ms;
                        if (dt_us > 250 * std.time.us_per_ms and p.done >= ui.prog_last_done) {
                            const bytes: f64 = @floatFromInt(p.done - ui.prog_last_done);
                            const mibs = bytes / (f64_from_us(dt_us) * 1024.0 * 1024.0);
                            var sb: [32]u8 = undefined;
                            speed = std.fmt.bufPrint(&sb, "{d:.1} MiB/s", .{mibs}) catch "";
                            // keep the string alive by copying into a static scratch
                            @memcpy(ui.speed_scratch[0..speed.len], speed);
                            speed = ui.speed_scratch[0..speed.len];
                        }
                    }
                    if (p.done != ui.prog_last_done) {
                        ui.prog_last_ms = now;
                        ui.prog_last_done = p.done;
                    }

                    var pz: [220]u8 = undefined;
                    const z = if (speed.len > 0)
                        std.fmt.bufPrintZ(&pz, "{s} · {d}% · {s}", .{ p.label.slice(), pct, speed }) catch "working…"
                    else
                        std.fmt.bufPrintZ(&pz, "{s} · {d}%", .{ p.label.slice(), pct }) catch "working…";
                    gtk.ProgressBar.setText(bar, z.ptr);
                }
            }
        },
        .chip_info => |info| {
            var buf: [512]u8 = undefined;
            var len: usize = 0;
            appendFmt(&buf, &len, "Sahara protocol version: {d}\n", .{info.protocol_version});
            if (info.serial) |s| appendFmt(&buf, &len, "Serial number: 0x{X:0>8}\n", .{s});
            if (info.hwid) |h| {
                appendFmt(&buf, &len, "HW ID: 0x{X:0>16}\n", .{h});
                appendFmt(&buf, &len, "  MSM_ID: 0x{X:0>8}  OEM_ID: 0x{X:0>4}  MODEL_ID: 0x{X:0>4}\n", .{ info.msm_id, info.oem_id, info.model_id });
            }
            if (info.pkhash.len > 0) appendFmt(&buf, &len, "OEM PK hash: 0x{s}\n", .{info.pkhash.slice()});
            labelTextZ(ui.dev_chip_label.?, buf[0..len]);
        },
        .session_state => |state| {
            ui.session = state;
            if (state == .disconnected) {
                ui.parts = null;
                if (ui.parts_list) |list| listBoxClear(list);
                gtk.Label.setText(ui.parts_empty.?, "Not connected");
                // Queued writes belong to the partition table of the device
                // that just went away — carrying them into the next session
                // would flash them at the wrong device's offsets.
                clearPendingWrites(ui);
            }
            refreshMainPage(ui);
        },
        .partitions => |parts| {
            ui.parts = parts;
            rebuildPartitions(ui, &parts);
            refreshHuaweiRow(ui);
        },
        .huawei_app => |ent| {
            // A parse started before the current file was picked: its result
            // must not be paired with the new path.
            if (ent.gen != ui.huawei_gen) return;
            ui.huawei_entries = ent;
            refreshHuaweiRow(ui);
        },
        .finished => |fin| {
            ui.jobDone();
            if (fin.success and std.mem.eql(u8, fin.message.slice(), "DA uploaded and started")) {
                ui.mtk_da_ready = true;
            }
            if (!fin.success) {
                ui.mtk_da_ready = false;
            }
            if (!fin.success) {
                ui.toast(fin.message.slice());
                ui.logger.err("operation failed: {s}", .{fin.message.slice()});
            } else if (isNotable(fin.message.slice())) {
                ui.toast(fin.message.slice());
                ui.logger.info("operation finished: {s}", .{fin.message.slice()});
            }
        },
    }
}

fn isNotable(msg: []const u8) bool {
    const suffixes = [_][]const u8{ "read finished", "write finished", "flash finished", "erase finished" };
    for (suffixes) |sfx| {
        if (std.mem.endsWith(u8, msg, sfx)) return true;
    }
    const names = [_][]const u8{ "device reset", "device rebooted", "loader required", "disconnected", "connected (VIP)", "partitions loaded", "digest tables created", "ramdump finished", "UFS provisioning finished", "huawei app finished", "userdata erased (factory reset)", "PIT loaded", "PIT flash finished", "bundle flash finished", "bootrom version read", "chip info read", "DA uploaded and started", "FDLs uploaded — flash operations unlocked" };
    for (names) |n| {
        if (std.mem.eql(u8, msg, n)) return true;
    }
    return false;
}

// ----------------------------------------------------------------------
// Small helpers
// ----------------------------------------------------------------------

fn f64_from_us(us: i64) f64 {
    return @as(f64, @floatFromInt(us)) / 1_000_000.0;
}

fn appendFmt(buf: []u8, len: *usize, comptime fmt: []const u8, args: anytype) void {
    const out = std.fmt.bufPrint(buf[len.*..], fmt, args) catch return;
    len.* += out.len;
}

fn setMargins(w: *gtk.Widget, top: c_int, start: c_int, end: c_int, bottom: c_int) void {
    gtk.Widget.setMarginTop(w, top);
    gtk.Widget.setMarginStart(w, start);
    gtk.Widget.setMarginEnd(w, end);
    gtk.Widget.setMarginBottom(w, bottom);
}

fn labelTextZ(label: *gtk.Label, text: []const u8) void {
    var zbuf: [540]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{text}) catch return;
    gtk.Label.setText(label, z.ptr);
}

fn setSubtitleZ(row: *adw.ActionRow, text: []const u8) void {
    var zbuf: [540]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{text}) catch return;
    adw.ActionRow.setSubtitle(row, z.ptr);
}

fn drainLogs(ui: *Ui) void {
    var entries = std.ArrayList(log_mod.Entry).empty;
    defer entries.deinit(ui.alloc);
    const res = ui.logger.drainSince(ui.alloc, ui.log_seq, &entries) catch return;
    if (res.dropped_total > ui.log_drop_seen) {
        consoleAppend(ui, "… log ring overflowed, some entries were dropped …\n", "t-warn");
        ui.log_drop_seen = res.dropped_total;
    }
    for (entries.items) |e| {
        const tag: ?[*:0]const u8 = switch (e.level) {
            .debug => "t-debug",
            .info => null,
            .warn => "t-warn",
            .err => "t-err",
        };
        var line: [1100]u8 = undefined;
        const elapsed_ms: u64 = @intCast(@divFloor(e.ts_ms - ui.logger.start_ms, 1000));
        const text = std.fmt.bufPrint(&line, "[{d:0>3}.{d:0>3}s] {s}: {s}\n", .{
            elapsed_ms / 1000,
            elapsed_ms % 1000,
            e.level.label(),
            e.text[0..e.len],
        }) catch continue;
        ui.log_seq = e.seq + 1;
        consoleAppend(ui, text, tag);
    }
}
