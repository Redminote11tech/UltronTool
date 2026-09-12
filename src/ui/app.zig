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
const usb_ids = @import("../protocol/qualcomm/usb_ids.zig");
const style = @import("style.zig");

pub const app_id = "io.github.redminote11tech.Ultron";
pub const version = "0.2.0";

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
    xml_add: void,
    read_partition: ev.PartitionRow,
    write_partition: ev.PartitionRow,
};

const PendingWrite = struct {
    row: ev.PartitionRow,
    path: []u8, // owned by Ui
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
    session: ev.SessionState = .disconnected,
    parts: ?ev.PartitionsEvent = null,

    programmer_path: ?[]u8 = null, // loader chosen in needs_loader state
    pending_writes: std.ArrayList(PendingWrite) = .empty,
    xml_paths: std.ArrayList([]u8) = .empty,
    storage: firehose.StorageType = .ufs,
    allow_missing: bool = false,

    // Widget references.
    window: ?*adw.ApplicationWindow = null,
    toast_overlay: ?*adw.ToastOverlay = null,
    cancel_button: ?*gtk.Button = null,
    progress: ?*gtk.ProgressBar = null,
    progress_label: ?*gtk.Label = null,
    console_view: ?*gtk.TextView = null,

    // Main page sections.
    status_page: ?*adw.StatusPage = null,
    dev_card: ?*gtk.Box = null,
    dev_mode_label: ?*gtk.Label = null,
    dev_vidpid_label: ?*gtk.Label = null,
    dev_path_label: ?*gtk.Label = null,
    dev_chip_label: ?*gtk.Label = null,
    probe_btn: ?*gtk.Button = null,
    connect_btn: ?*gtk.Button = null,
    storage_drop: ?*gtk.DropDown = null,

    loader_section: ?*gtk.Widget = null,
    loader_row: ?*adw.ActionRow = null,
    upload_btn: ?*gtk.Button = null,

    conn_section: ?*gtk.Widget = null,
    storage_info_label: ?*gtk.Label = null,
    lun_row: ?*gtk.Widget = null,
    lun_drop: ?*gtk.DropDown = null,
    refresh_btn: ?*gtk.Button = null,
    parts_list: ?*gtk.ListBox = null,
    parts_empty: ?*gtk.Label = null,
    pending_row: ?*adw.ActionRow = null,
    write_all_btn: ?*gtk.Button = null,
    xml_row: ?*adw.ActionRow = null,
    flash_xml_btn: ?*gtk.Button = null,
    allow_missing_sw: ?*gtk.Switch = null,
    reset_btn: ?*gtk.Button = null,
    disconnect_btn: ?*gtk.Button = null,

    chooser: ?ChooserKind = null,
    /// Set when the window is fully built; event handlers refuse to touch
    /// widgets before that (belt-and-braces against early events).
    ready: bool = false,
    log_seq: u64 = 0,
    log_drop_seen: u64 = 0,

    // Per-partition-row signal contexts, freed when the list is rebuilt.
    row_ctxs: std.ArrayList(*RowCtx) = .empty,

    fn setBusy(self: *Ui, busy_now: bool) void {
        const enable: c_int = @intFromBool(!busy_now);
        inline for (.{ self.connect_btn, self.probe_btn, self.upload_btn, self.write_all_btn, self.flash_xml_btn, self.reset_btn, self.disconnect_btn, self.refresh_btn }) |maybe_btn| {
            if (maybe_btn) |b| gtk.Widget.setSensitive(b.as(gtk.Widget), enable);
        }
        if (self.cancel_button) |b| gtk.Widget.setVisible(b.as(gtk.Widget), @intFromBool(busy_now));
    }

    fn busy(self: *Ui) bool {
        return self.outstanding > 0;
    }

    fn toast(self: *Ui, msg: []const u8) void {
        const overlay = self.toast_overlay orelse return;
        var buf: [256]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{msg}) catch return;
        const t = adw.Toast.new(z.ptr);
        adw.ToastOverlay.addToast(overlay, t);
    }

    fn startJob(self: *Ui) void {
        self.outstanding += 1;
        self.setBusy(true);
        if (self.progress) |p| {
            gtk.Widget.setVisible(p.as(gtk.Widget), 1);
            gtk.ProgressBar.setFraction(p, 0);
        }
        if (self.progress_label) |l| gtk.Widget.setVisible(l.as(gtk.Widget), 1);
    }

    fn jobDone(self: *Ui) void {
        if (self.outstanding > 0) self.outstanding -= 1;
        if (self.outstanding == 0) {
            self.setBusy(false);
            if (self.progress) |p| gtk.Widget.setVisible(p.as(gtk.Widget), 0);
            if (self.progress_label) |l| gtk.Widget.setVisible(l.as(gtk.Widget), 0);
        }
    }
};

const WorkerCtx = struct {
    ui: *Ui,
};

const RowCtx = struct {
    ui: *Ui,
    row: ev.PartitionRow,
};

const ConfirmCtx = struct {
    ui: *Ui,
    kind: ConfirmKind,
};

const ConfirmKind = enum { apply_writes, flash_xml };

// ----------------------------------------------------------------------
// Entry (called from main.zig)
// ----------------------------------------------------------------------

fn usbOpen(ctx: *anyopaque, logger: *log_mod.Logger, wait_ms: u32, alloc: std.mem.Allocator) transport.Error!transport.Transport {
    _ = ctx;
    const u = try alloc.create(usb.Usb);
    errdefer alloc.destroy(u);
    u.* = try usb.open(&usb_ids.policy, null, wait_ms, logger, alloc);
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

    // Shutdown: stop the manager and scanner, free UI state.
    ui.cancel.store(true, .release);
    if (ui.manager) |m| m.shutdown();
    if (ui.scanner) |sc| sc.deinit();
    clearPendingWrites(ui);
    ui.pending_writes.deinit(alloc);
    for (ui.xml_paths.items) |p| alloc.free(p);
    ui.xml_paths.deinit(alloc);
    if (ui.programmer_path) |p| alloc.free(p);
    for (ui.row_ctxs.items) |ctx| alloc.destroy(ctx);
    ui.row_ctxs.deinit(alloc);
    alloc.destroy(ui);
    alloc.destroy(channel);
    alloc.destroy(logger);

    std.process.exit(@intCast(status));
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
    gtk.ScrolledWindow.setChild(scrolled, page.as(gtk.Widget));

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

    const chip_row = adw.ActionRow.new();
    rowTitle(chip_row, "Sahara chip identity");
    const probe_btn = gtk.Button.newWithLabel("Read chip info");
    _ = gtk.Button.signals.clicked.connect(probe_btn, *Ui, &onProbeClicked, ui, .{});
    adw.ActionRow.addSuffix(chip_row, probe_btn.as(gtk.Widget));
    ui.probe_btn = probe_btn;
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

    const storage_label = gtk.Label.new("");
    gtk.Label.setXalign(storage_label, 0);
    gtk.Widget.addCssClass(storage_label.as(gtk.Widget), "dim-label");
    ui.storage_info_label = storage_label;
    gtk.Box.append(conn, storage_label.as(gtk.Widget));

    const parts_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(parts_group, "Partitions");
    adw.PreferencesGroup.setDescription(parts_group, "Read makes a backup; write overwrites the partition after confirmation");

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

    // --- Progress + cancel -----------------------------------------------
    const progress = gtk.ProgressBar.new();
    gtk.Widget.setVisible(progress.as(gtk.Widget), 0);
    ui.progress = progress;
    gtk.Box.append(page, progress.as(gtk.Widget));

    const progress_label = gtk.Label.new("");
    gtk.Widget.setVisible(progress_label.as(gtk.Widget), 0);
    ui.progress_label = progress_label;
    gtk.Box.append(page, progress_label.as(gtk.Widget));

    const cancel_button = gtk.Button.newWithLabel("Cancel (disconnects)");
    gtk.Widget.addCssClass(cancel_button.as(gtk.Widget), "destructive-action");
    gtk.Widget.setHalign(cancel_button.as(gtk.Widget), .center);
    gtk.Widget.setVisible(cancel_button.as(gtk.Widget), 0);
    _ = gtk.Button.signals.clicked.connect(cancel_button, *Ui, &onCancelClicked, ui, .{});
    ui.cancel_button = cancel_button;
    gtk.Box.append(page, cancel_button.as(gtk.Widget));

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

    if (ui.loader_section) |w| gtk.Widget.setVisible(w, @intFromBool(has_device and ui.session == .needs_loader));
    if (ui.conn_section) |w| gtk.Widget.setVisible(w, @intFromBool(has_device and ui.session == .firehose_ready));

    // The chip probe and Connect only make sense before a session exists.
    if (ui.dev_chip_label) |l| gtk.Widget.setVisible(l.as(gtk.Widget), @intFromBool(ui.session == .disconnected));
    if (ui.storage_drop) |d| gtk.Widget.setVisible(d.as(gtk.Widget), @intFromBool(ui.session == .disconnected));
    if (ui.connect_btn) |b| gtk.Widget.setVisible(b.as(gtk.Widget), @intFromBool(ui.session == .disconnected));

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

    var info_buf: [160]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "LUN {d} · sector size {d} B · {d} LUN(s)", .{ parts.lun, parts.sector_size, parts.luns }) catch "";
    labelTextZ(ui.storage_info_label.?, info);

    // LUN switcher only matters on multi-LUN devices.
    gtk.Widget.setVisible(ui.lun_row.?, @intFromBool(parts.luns > 1));

    if (parts.count == 0) {
        gtk.Label.setText(ui.parts_empty.?, "No partitions found (empty GPT?)");
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

        const read_btn = gtk.Button.newWithLabel("Read");
        _ = gtk.Button.signals.clicked.connect(read_btn, *RowCtx, &onReadClicked, ctx, .{});
        adw.ActionRow.addSuffix(action_row, read_btn.as(gtk.Widget));

        const write_btn = gtk.Button.newWithLabel("Write");
        gtk.Widget.addCssClass(write_btn.as(gtk.Widget), "destructive-action");
        _ = gtk.Button.signals.clicked.connect(write_btn, *RowCtx, &onWriteClicked, ctx, .{});
        adw.ActionRow.addSuffix(action_row, write_btn.as(gtk.Widget));

        gtk.ListBox.append(ui.parts_list.?, action_row.as(gtk.Widget));
    }
}

fn listBoxClear(list: *gtk.ListBox) void {
    while (true) {
        const child = gtk.Widget.getFirstChild(list.as(gtk.Widget)) orelse break;
        gtk.ListBox.remove(list, @ptrCast(@alignCast(child)));
    }
}

fn refreshPendingWrites(ui: *Ui) void {
    const n = ui.pending_writes.items.len;
    if (n == 0) {
        adw.ActionRow.setSubtitle(ui.pending_row.?, "None — click Write on a partition to queue one");
        gtk.Button.setLabel(ui.write_all_btn.?, "Write");
        gtk.Widget.setSensitive(ui.write_all_btn.?.as(gtk.Widget), 0);
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
    setSubtitleZ(ui.pending_row.?, buf[0..len]);
    var label_buf: [32]u8 = undefined;
    const lbl = std.fmt.bufPrintZ(&label_buf, "Write {d}…", .{n}) catch "Write…";
    gtk.Button.setLabel(ui.write_all_btn.?, lbl.ptr);
    gtk.Widget.setSensitive(ui.write_all_btn.?.as(gtk.Widget), @intFromBool(!ui.busy()));
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
    const window = ui.window orelse return;
    const chooser = gtk.FileChooserNative.new(
        title.ptr,
        window.as(gtk.Window),
        if (save) .save else .open,
        null,
        null,
    );
    if (suggested) |s| gtk.FileChooser.setCurrentName(chooser.as(gtk.FileChooser), s.ptr);
    ui.chooser = kind;
    _ = gtk.NativeDialog.signals.response.connect(chooser, *Ui, &onChooserResponse, ui, .{});
    gtk.NativeDialog.show(chooser.as(gtk.NativeDialog));
}

fn onChooserResponse(chooser: *gtk.FileChooserNative, response_id: c_int, ui: *Ui) callconv(.c) void {
    const kind = ui.chooser orelse return;
    ui.chooser = null;
    if (response_id != @intFromEnum(gtk.ResponseType.accept)) return;
    const file = gtk.FileChooser.getFile(chooser.as(gtk.FileChooser)) orelse {
        ui.logger.err("file chooser returned no file", .{});
        ui.toast("Could not read the selected file");
        return;
    };
    defer file.unref();
    // Portal-backed choosers may return URI-backed files without a native
    // path; fall back to the URI (file:// only).
    var path: []const u8 = undefined;
    if (gio.File.getPath(file)) |p| {
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

    switch (kind) {
        .loader => {
            if (ui.programmer_path) |old| ui.alloc.free(old);
            ui.programmer_path = ui.alloc.dupe(u8, path) catch null;
            if (ui.programmer_path) |p| setSubtitleZ(ui.loader_row.?, p);
            gtk.Widget.setSensitive(ui.upload_btn.?.as(gtk.Widget), @intFromBool(!ui.busy()));
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
        .read_partition => |row| {
            if (ui.busy()) {
                ui.toast("Another operation is running — wait for it to finish");
                return;
            }
            ui.startJob();
            ui.manager.?.enqueue(.{ .read_partition = .{
                .path = path,
                .first_lba = row.first_lba,
                .num_sectors = row.sectors(),
                .lun = currentLun(ui),
                .label = row.name.slice(),
            } });
        },
        .write_partition => |row| {
            const dup = ui.alloc.dupe(u8, path) catch return;
            ui.pending_writes.append(ui.alloc, .{ .row = row, .path = dup }) catch {
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
    if (ui.allow_missing_sw) |sw| ui.allow_missing = gtk.Switch.getActive(sw) != 0;
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
    readStorageSelection(ui);
    ui.startJob();
    ui.manager.?.enqueue(.{ .connect = .{ .storage = ui.storage } });
}

fn onPickLoader(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    openChooser(ui, .loader, "Select firehose programmer", false, null);
}

fn onUploadLoaderClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.manager == null) return;
    const path = ui.programmer_path orelse return;
    readStorageSelection(ui);
    ui.startJob();
    ui.manager.?.enqueue(.{ .upload_loader = .{ .programmer = path, .storage = ui.storage } });
}

fn onProbeClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.device == null) return;
    spawnChipProbe(ui) catch ui.toast("Failed to start worker thread");
    ui.setBusy(true);
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
    var name_buf: [96]u8 = undefined;
    const suggested = std.fmt.bufPrintZ(&name_buf, "{s}.img", .{ctx.row.name.slice()}) catch "partition.img";
    openChooser(ui, .{ .read_partition = ctx.row }, "Save partition backup", true, suggested);
}

fn onWriteClicked(_: *gtk.Button, ctx: *RowCtx) callconv(.c) void {
    openChooser(ctx.ui, .{ .write_partition = ctx.row }, "Select image to write", false, null);
}

fn onClearWritesClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    clearPendingWrites(ui);
}

fn onWriteAllClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy() or ui.pending_writes.items.len == 0) return;

    var body_buf: [1400]u8 = undefined;
    var len: usize = 0;
    for (ui.pending_writes.items) |pw| {
        var size_buf: [32]u8 = undefined;
        const size_txt = util.formatBytes(&size_buf, pw.row.sectors() * sectorSizeOf(ui));
        const line = std.fmt.bufPrint(body_buf[len..], "• {s} ({s}) ← {s}\n", .{
            pw.row.name.slice(),
            size_txt,
            std.fs.path.basename(pw.path),
        }) catch break;
        len += line.len;
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
    if (!std.mem.eql(u8, std.mem.span(response), "apply")) return;

    switch (kind) {
        .apply_writes => {
            if (ui.busy() or ui.manager == null) return;
            for (ui.pending_writes.items) |pw| {
                ui.startJob();
                ui.manager.?.enqueue(.{ .write_partition = .{
                    .path = pw.path,
                    .first_lba = pw.row.first_lba,
                    .max_sectors = pw.row.sectors(),
                    .lun = currentLun(ui),
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
    }
}

// ----------------------------------------------------------------------
// Chip identity probe (one-shot worker, pre-connect only)
// ----------------------------------------------------------------------

fn spawnChipProbe(ui: *Ui) !void {
    const ctx = try ui.alloc.create(WorkerCtx);
    ctx.* = .{ .ui = ui };
    const thread = try std.Thread.spawn(.{}, chipProbeRun, .{ctx});
    thread.detach();
}

fn chipProbeRun(ctx: *WorkerCtx) void {
    const ui = ctx.ui;
    defer ui.alloc.destroy(ctx);
    const channel = ui.channel;
    const info = session_mod.chipInfo(ui.alloc, ui.logger, &ui.cancel, null, 8000) catch |e| {
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
            ui.device = dev;
            refreshMainPage(ui);
            ui.logger.info("device connected: {s} ({x:0>4}:{x:0>4})", .{ dev.mode.displayName(), dev.vid, dev.pid });
        },
        .device_removed => |key| {
            if (ui.device) |dev| {
                if (dev.key.eql(key)) {
                    ui.device = null;
                    if (ui.session != .disconnected and ui.manager != null and !ui.busy()) {
                        ui.manager.?.enqueue(.{ .disconnect = {} });
                    } else if (ui.session != .disconnected) {
                        ui.cancel.store(true, .release);
                    }
                    ui.session = .disconnected;
                    refreshMainPage(ui);
                    ui.logger.info("device disconnected", .{});
                }
            }
        },
        .progress => |p| {
            if (ui.progress) |bar| {
                if (p.fraction < 0) {
                    gtk.ProgressBar.pulse(bar);
                } else {
                    gtk.ProgressBar.setFraction(bar, @min(p.fraction, 1.0));
                }
            }
            if (ui.progress_label) |l| labelTextZ(l, p.label.slice());
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
            }
            refreshMainPage(ui);
        },
        .partitions => |parts| {
            ui.parts = parts;
            rebuildPartitions(ui, &parts);
        },
        .finished => |fin| {
            ui.jobDone();
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
    const suffixes = [_][]const u8{ "read finished", "write finished", "flash finished" };
    for (suffixes) |sfx| {
        if (std.mem.endsWith(u8, msg, sfx)) return true;
    }
    const names = [_][]const u8{ "device reset", "loader required", "disconnected", "connected" };
    for (names) |n| {
        if (std.mem.eql(u8, msg, n)) return true;
    }
    return false;
}

// ----------------------------------------------------------------------
// Small helpers
// ----------------------------------------------------------------------

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
