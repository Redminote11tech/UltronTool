//! Ultron GUI — libadwaita window, pages, worker management and the
//! event/log pumps that keep the UI updated from background threads.
//!
//! UI layout: an AdwViewStack with three pages (Device, Flash, Console) and
//! an AdwViewSwitcher in the header bar. Protocol work runs on a worker
//! thread; updates arrive through the core event channel drained on a GLib
//! timeout, so the UI thread never blocks.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gdk = @import("gdk");
const gtk = @import("gtk");
const adw = @import("adw");

const log_mod = @import("../core/log.zig");
const ev = @import("../core/event.zig");
const fileio = @import("../core/fileio.zig");
const scanner_mod = @import("../device/scanner.zig");
const session = @import("../protocol/qualcomm/session.zig");
const firehose = @import("../protocol/qualcomm/firehose.zig");
const style = @import("style.zig");

pub const app_id = "io.github.redminote11tech.Ultron";
pub const version = "0.1.0";

const EventChannel = ev.Channel(ev.Event, 256);
const storage_names: [6]?[*:0]const u8 = .{ "ufs", "emmc", "spinor", "nand", "nvme", null };
const storage_values = [_]firehose.StorageType{ .ufs, .emmc, .spinor, .nand, .nvme };

pub const Ui = struct {
    alloc: std.mem.Allocator,
    logger: *log_mod.Logger,
    channel: *EventChannel,
    scanner: ?*scanner_mod.Scanner = null,
    app: ?*adw.Application = null,

    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    busy: bool = false,
    worker: ?std.Thread = null,
    worker_ctx: ?*WorkerCtx = null,

    device: ?ev.DeviceInfo = null,
    programmer_path: ?[]u8 = null,
    xml_paths: std.ArrayList([]u8) = .empty,
    storage: firehose.StorageType = .ufs,
    allow_missing: bool = false,
    skip_reset: bool = false,

    // Widget references (filled by buildWindow and page builders).
    window: ?*adw.ApplicationWindow = null,
    toast_overlay: ?*adw.ToastOverlay = null,

    dev_status: ?*adw.StatusPage = null,
    dev_card: ?*gtk.Box = null,
    dev_mode_label: ?*gtk.Label = null,
    dev_vidpid_label: ?*gtk.Label = null,
    dev_path_label: ?*gtk.Label = null,
    dev_chip_label: ?*gtk.Label = null,
    probe_btn: ?*gtk.Button = null,

    prog_row: ?*adw.ActionRow = null,
    xml_row: ?*adw.ActionRow = null,
    storage_drop: ?*gtk.DropDown = null,
    allow_missing_sw: ?*gtk.Switch = null,
    skip_reset_sw: ?*gtk.Switch = null,
    start_btn: ?*gtk.Button = null,
    cancel_btn: ?*gtk.Button = null,
    progress: ?*gtk.ProgressBar = null,
    progress_label: ?*gtk.Label = null,

    console_view: ?*gtk.TextView = null,
    pending_chooser: ?*const fn (*Ui, *gtk.FileChooserNative, c_int) void = null,
    log_seq: u64 = 0,
    log_drop_seen: u64 = 0,

    fn setBusy(self: *Ui, busy: bool) void {
        self.busy = busy;
        if (self.start_btn) |b| gtk.Widget.setSensitive(b.as(gtk.Widget), @intFromBool(!busy));
        if (self.probe_btn) |b| gtk.Widget.setSensitive(b.as(gtk.Widget), @intFromBool(!busy));
        if (self.cancel_btn) |b| gtk.Widget.setVisible(b.as(gtk.Widget), @intFromBool(busy));
    }

    fn toast(self: *Ui, msg: []const u8) void {
        const overlay = self.toast_overlay orelse return;
        var buf: [256]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{msg}) catch return;
        const t = adw.Toast.new(z.ptr);
        adw.ToastOverlay.addToast(overlay, t);
    }
};

const WorkerCtx = struct {
    ui: *Ui,
    kind: enum { flash, chipinfo },
    req: session.FlashRequest,
};

// ----------------------------------------------------------------------
// Entry (called from main.zig)
// ----------------------------------------------------------------------

pub fn mainRun(init: std.process.Init) !void {
    // libc allocator: we link libc anyway and the UI lives for the process lifetime.
    const alloc = std.heap.c_allocator;

    const logger = try alloc.create(log_mod.Logger);
    logger.* = .{ .min_level = .info, .mirror_stderr = false };
    // std.err mirroring only with --debug (kept quiet for a clean GUI launch).
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

    const app = adw.Application.new(app_id, .{});
    defer app.unref();
    _ = gio.Application.signals.activate.connect(app, *Ui, &onActivate, ui, .{});
    // Args were already handled above; don't forward unknown options to GApplication.
    const status = gio.Application.run(app.as(gio.Application), 0, null);

    // Shutdown: stop any running session and the scanner.
    ui.cancel.store(true, .release);
    if (ui.worker) |w| w.join();
    if (ui.scanner) |sc| sc.deinit();
    ui.xml_paths.deinit(alloc);
    if (ui.programmer_path) |p| alloc.free(p);
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
    gtk.Window.setDefaultSize(window.as(gtk.Window), 880, 640);
    ui.window = window;

    const overlay = adw.ToastOverlay.new();
    ui.toast_overlay = overlay;

    const stack = adw.ViewStack.new();
    stackAdd(stack, buildDevicePage(ui), "device", "Device", "phone-symbolic");
    stackAdd(stack, buildFlashPage(ui), "flash", "Flash", "drive-multidisk-symbolic");
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

    // AdwApplicationWindow (unlike GtkApplicationWindow) has no set_child;
    // its content lives on the inherited AdwWindow "content" property.
    var value = std.mem.zeroes(gobject.Value);
    _ = gobject.Value.init(&value, gobject.typeFromName("GtkWidget"));
    gobject.Value.setObject(&value, toolbar.as(gobject.Object));
    gobject.Object.setProperty(window.as(gobject.Object), "content", &value);
    gobject.Value.unset(&value);
    gtk.Window.present(window.as(gtk.Window));

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

// ----------------------------------------------------------------------
// Device page
// ----------------------------------------------------------------------

fn buildDevicePage(ui: *Ui) *gtk.Widget {
    const page = gtk.Box.new(.vertical, 18);
    setMargins(page.as(gtk.Widget), 18, 18, 18, 18);
    gtk.Widget.setVexpand(page.as(gtk.Widget), 1);

    // Empty state.
    const status = adw.StatusPage.new();
    adw.StatusPage.setIconName(status, "usb-plug-symbolic");
    adw.StatusPage.setTitle(status, "No device detected");
    adw.StatusPage.setDescription(status, "Connect your device in EDL (download) mode.\nOn Qualcomm devices this is 9008 mode — usually holding volume keys while plugging in USB.");
    ui.dev_status = status;
    gtk.Box.append(page, status.as(gtk.Widget));

    // Device card.
    const card = gtk.Box.new(.vertical, 12);
    ui.dev_card = card;

    const group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(group, "Detected device");
    adw.PreferencesGroup.setDescription(group, "Qualcomm Emergency Download mode");

    const mode_row = adw.ActionRow.new();
    addRow(mode_row, "Mode");
    const mode_val = gtk.Label.new("-");
    gtk.Widget.addCssClass(mode_val.as(gtk.Widget), "device-badge");
    gtk.Widget.addCssClass(mode_val.as(gtk.Widget), "accent");
    adw.ActionRow.addSuffix(mode_row, mode_val.as(gtk.Widget));
    ui.dev_mode_label = mode_val;
    adw.PreferencesGroup.add(group, mode_row.as(gtk.Widget));

    const vidpid_row = adw.ActionRow.new();
    addRow(vidpid_row, "USB device");
    const vidpid_val = gtk.Label.new("-");
    adw.ActionRow.addSuffix(vidpid_row, vidpid_val.as(gtk.Widget));
    ui.dev_vidpid_label = vidpid_val;
    adw.PreferencesGroup.add(group, vidpid_row.as(gtk.Widget));

    const path_row = adw.ActionRow.new();
    addRow(path_row, "Sysfs path");
    const path_val = gtk.Label.new("-");
    gtk.Widget.addCssClass(path_val.as(gtk.Widget), "dim-label");
    adw.ActionRow.addSuffix(path_row, path_val.as(gtk.Widget));
    ui.dev_path_label = path_val;
    adw.PreferencesGroup.add(group, path_row.as(gtk.Widget));

    gtk.Box.append(card, group.as(gtk.Widget));

    const chip_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(chip_group, "Chip identity");
    adw.PreferencesGroup.setDescription(chip_group, "Read over Sahara command mode");

    const probe_btn = gtk.Button.newWithLabel("Read chip info");
    gtk.Button.setHasFrame(probe_btn, 1);
    gtk.Widget.addCssClass(probe_btn.as(gtk.Widget), "suggested-action");
    _ = gtk.Button.signals.clicked.connect(probe_btn, *Ui, &onProbeClicked, ui, .{});
    ui.probe_btn = probe_btn;

    const chip_row = adw.ActionRow.new();
    addRow(chip_row, "Sahara chip info");
    adw.ActionRow.addSuffix(chip_row, probe_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(chip_group, chip_row.as(gtk.Widget));

    const chip_label = gtk.Label.new("Not read yet");
    gtk.Label.setXalign(chip_label, 0);
    gtk.Label.setWrap(chip_label, 1);
    gtk.Widget.addCssClass(chip_label.as(gtk.Widget), "chip-grid");
    ui.dev_chip_label = chip_label;
    gtk.Box.append(card, chip_label.as(gtk.Widget));

    gtk.Box.append(card, chip_group.as(gtk.Widget));
    gtk.Widget.setVisible(card.as(gtk.Widget), 0);
    gtk.Box.append(page, card.as(gtk.Widget));

    return page.as(gtk.Widget);
}

fn addRow(row: *adw.ActionRow, title: [:0]const u8) void {
    adw.PreferencesRow.setTitle(row.as(adw.PreferencesRow), title.ptr);
}

fn refreshDevicePage(ui: *Ui) void {
    if (ui.device) |dev| {
        gtk.Widget.setVisible(ui.dev_status.?.as(gtk.Widget), 0);
        gtk.Widget.setVisible(ui.dev_card.?.as(gtk.Widget), 1);
        labelTextZ(ui.dev_mode_label.?, dev.mode.displayName());
        var buf: [64]u8 = undefined;
        const vp = std.fmt.bufPrint(&buf, "{x:0>4}:{x:0>4}  (bus {d:0>3} device {d:0>3})", .{ dev.vid, dev.pid, dev.bus, dev.devnum }) catch "-";
        labelTextZ(ui.dev_vidpid_label.?, vp);
        labelTextZ(ui.dev_path_label.?, dev.key.path.slice());
    } else {
        gtk.Widget.setVisible(ui.dev_status.?.as(gtk.Widget), 1);
        gtk.Widget.setVisible(ui.dev_card.?.as(gtk.Widget), 0);
        gtk.Label.setText(ui.dev_chip_label.?, "Not read yet");
    }
}

// ----------------------------------------------------------------------
// Flash page
// ----------------------------------------------------------------------

fn buildFlashPage(ui: *Ui) *gtk.Widget {
    const scrolled = gtk.ScrolledWindow.new();
    gtk.ScrolledWindow.setPolicy(scrolled, .never, .automatic);

    const page = gtk.Box.new(.vertical, 18);
    setMargins(page.as(gtk.Widget), 18, 18, 18, 18);
    gtk.ScrolledWindow.setChild(scrolled, page.as(gtk.Widget));

    const files_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(files_group, "Files");
    adw.PreferencesGroup.setDescription(files_group, "Use your device's own signed programmer and flash layout");

    const prog_row = adw.ActionRow.new();
    addRow(prog_row, "Programmer (firehose .mbn/.elf)");
    adw.ActionRow.setSubtitle(prog_row, "None selected");
    const prog_btn = gtk.Button.newWithLabel("Choose…");
    gtk.Button.setHasFrame(prog_btn, 0);
    _ = gtk.Button.signals.clicked.connect(prog_btn, *Ui, &onPickProgrammer, ui, .{});
    adw.ActionRow.addSuffix(prog_row, prog_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(files_group, prog_row.as(gtk.Widget));
    ui.prog_row = prog_row;

    const xml_row = adw.ActionRow.new();
    addRow(xml_row, "Flash layout XML (rawprogram / patch)");
    adw.ActionRow.setSubtitle(xml_row, "None selected");
    const xml_add_btn = gtk.Button.newWithLabel("Add…");
    gtk.Button.setHasFrame(xml_add_btn, 0);
    _ = gtk.Button.signals.clicked.connect(xml_add_btn, *Ui, &onAddXml, ui, .{});
    adw.ActionRow.addSuffix(xml_row, xml_add_btn.as(gtk.Widget));
    const xml_clear_btn = gtk.Button.newWithLabel("Clear");
    gtk.Button.setHasFrame(xml_clear_btn, 0);
    _ = gtk.Button.signals.clicked.connect(xml_clear_btn, *Ui, &onClearXml, ui, .{});
    adw.ActionRow.addSuffix(xml_row, xml_clear_btn.as(gtk.Widget));
    adw.PreferencesGroup.add(files_group, xml_row.as(gtk.Widget));
    ui.xml_row = xml_row;

    gtk.Box.append(page, files_group.as(gtk.Widget));

    const opts_group = adw.PreferencesGroup.new();
    adw.PreferencesGroup.setTitle(opts_group, "Options");

    const storage_row = adw.ActionRow.new();
    addRow(storage_row, "Storage type");
    const drop = gtk.DropDown.newFromStrings(@ptrCast(&storage_names));
    adw.ActionRow.addSuffix(storage_row, drop.as(gtk.Widget));
    ui.storage_drop = drop;
    adw.PreferencesGroup.add(opts_group, storage_row.as(gtk.Widget));

    const missing_row = adw.ActionRow.new();
    addRow(missing_row, "Skip missing image files");
    const missing_sw = gtk.Switch.new();
    gtk.Widget.setValign(missing_sw.as(gtk.Widget), .center);
    adw.ActionRow.addSuffix(missing_row, missing_sw.as(gtk.Widget));
    ui.allow_missing_sw = missing_sw;
    adw.PreferencesGroup.add(opts_group, missing_row.as(gtk.Widget));

    const reset_row = adw.ActionRow.new();
    addRow(reset_row, "Skip final reset");
    const reset_sw = gtk.Switch.new();
    gtk.Widget.setValign(reset_sw.as(gtk.Widget), .center);
    adw.ActionRow.addSuffix(reset_row, reset_sw.as(gtk.Widget));
    ui.skip_reset_sw = reset_sw;
    adw.PreferencesGroup.add(opts_group, reset_row.as(gtk.Widget));

    gtk.Box.append(page, opts_group.as(gtk.Widget));

    // Action area.
    const action_group = gtk.Box.new(.vertical, 10);
    const start_btn = gtk.Button.newWithLabel("Start flashing");
    gtk.Widget.addCssClass(start_btn.as(gtk.Widget), "suggested-action");
    gtk.Widget.addCssClass(start_btn.as(gtk.Widget), "big-start");
    gtk.Widget.setHalign(start_btn.as(gtk.Widget), .center);
    _ = gtk.Button.signals.clicked.connect(start_btn, *Ui, &onStartClicked, ui, .{});
    ui.start_btn = start_btn;
    gtk.Box.append(action_group, start_btn.as(gtk.Widget));

    const cancel_btn = gtk.Button.newWithLabel("Cancel");
    gtk.Widget.addCssClass(cancel_btn.as(gtk.Widget), "destructive-action");
    gtk.Widget.setHalign(cancel_btn.as(gtk.Widget), .center);
    gtk.Widget.setVisible(cancel_btn.as(gtk.Widget), 0);
    _ = gtk.Button.signals.clicked.connect(cancel_btn, *Ui, &onCancelClicked, ui, .{});
    ui.cancel_btn = cancel_btn;
    gtk.Box.append(action_group, cancel_btn.as(gtk.Widget));

    const progress = gtk.ProgressBar.new();
    gtk.ProgressBar.setText(progress, null);
    gtk.Widget.setVisible(progress.as(gtk.Widget), 0);
    ui.progress = progress;
    gtk.Box.append(action_group, progress.as(gtk.Widget));

    const progress_label = gtk.Label.new("");
    gtk.Widget.setVisible(progress_label.as(gtk.Widget), 0);
    ui.progress_label = progress_label;
    gtk.Box.append(action_group, progress_label.as(gtk.Widget));

    gtk.Box.append(page, action_group.as(gtk.Widget));

    return scrolled.as(gtk.Widget);
}

// ----------------------------------------------------------------------
// Console page
// ----------------------------------------------------------------------

fn buildConsolePage(ui: *Ui) *gtk.Widget {
    const page = gtk.Box.new(.vertical, 0);

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
// File pickers
// ----------------------------------------------------------------------

fn openChooser(ui: *Ui, title: [:0]const u8, action: gtk.FileChooserAction) void {
    const window = ui.window orelse return;
    const chooser = gtk.FileChooserNative.new(title.ptr, window.as(gtk.Window), action, null, null);
    _ = gtk.NativeDialog.signals.response.connect(chooser, *Ui, &onChooserResponse, ui, .{});
    gtk.NativeDialog.show(chooser.as(gtk.NativeDialog));
}

fn onChooserResponse(chooser: *gtk.FileChooserNative, response_id: c_int, ui: *Ui) callconv(.c) void {
    // The pending handler is dispatched through a small trampoline table.
    if (ui.pending_chooser) |handler| {
        handler(ui, chooser, response_id);
        ui.pending_chooser = null;
    }
}

fn onPickProgrammer(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    ui.pending_chooser = &handleProgrammerResponse;
    openChooser(ui, "Select programmer image", .open);
}

fn handleProgrammerResponse(ui: *Ui, chooser: *gtk.FileChooserNative, response_id: c_int) void {
    if (response_id != @intFromEnum(gtk.ResponseType.accept)) return;
    const file = gtk.FileChooser.getFile(chooser.as(gtk.FileChooser)) orelse return;
    defer file.unref();
    const path_c = gio.File.getPath(file) orelse return;
    defer glib.free(path_c);
    const path = std.mem.span(path_c);
    if (ui.programmer_path) |old| ui.alloc.free(old);
    ui.programmer_path = ui.alloc.dupe(u8, path) catch null;
    if (ui.programmer_path) |p| {
        setSubtitleZ(ui.prog_row.?, p);
    }
}

fn onAddXml(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    ui.pending_chooser = &handleXmlResponse;
    openChooser(ui, "Select rawprogram / patch XML", .open);
}

fn handleXmlResponse(ui: *Ui, chooser: *gtk.FileChooserNative, response_id: c_int) void {
    if (response_id != @intFromEnum(gtk.ResponseType.accept)) return;
    const file = gtk.FileChooser.getFile(chooser.as(gtk.FileChooser)) orelse return;
    defer file.unref();
    const path_c = gio.File.getPath(file) orelse return;
    defer glib.free(path_c);
    const path = std.mem.span(path_c);
    const dup = ui.alloc.dupe(u8, path) catch return;
    ui.xml_paths.append(ui.alloc, dup) catch {
        ui.alloc.free(dup);
        return;
    };
    refreshXmlRow(ui);
}

fn onClearXml(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    for (ui.xml_paths.items) |p| ui.alloc.free(p);
    ui.xml_paths.clearRetainingCapacity();
    refreshXmlRow(ui);
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

fn setSubtitleZ(row: *adw.ActionRow, text: []const u8) void {
    var zbuf: [540]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{text}) catch return;
    adw.ActionRow.setSubtitle(row, z.ptr);
}

// ----------------------------------------------------------------------
// Session start / cancel / worker
// ----------------------------------------------------------------------

fn onStartClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy) return;

    if (ui.device == null) {
        ui.toast("No device detected — connect the device in EDL mode first");
        return;
    }
    if (ui.programmer_path == null and ui.xml_paths.items.len == 0) {
        ui.toast("Select a programmer and/or flash XML files first");
        return;
    }
    if (ui.storage_drop) |d| {
        const idx = gtk.DropDown.getSelected(d);
        ui.storage = storage_values[@min(idx, storage_values.len - 1)];
    }
    if (ui.allow_missing_sw) |sw| ui.allow_missing = gtk.Switch.getActive(sw) != 0;
    if (ui.skip_reset_sw) |sw| ui.skip_reset = gtk.Switch.getActive(sw) != 0;

    const req = session.FlashRequest{
        .programmer = ui.programmer_path,
        .xml_files = ui.xml_paths.items,
        .storage = ui.storage,
        .allow_missing = ui.allow_missing,
        .skip_reset = ui.skip_reset,
        .wait_ms = 8000,
    };

    spawnWorker(ui, .{ .ui = ui, .kind = .flash, .req = req }) catch {
        ui.toast("Failed to start worker thread");
        return;
    };

    ui.setBusy(true);
    gtk.Widget.setVisible(ui.progress.?.as(gtk.Widget), 1);
    gtk.Widget.setVisible(ui.progress_label.?.as(gtk.Widget), 1);
    gtk.ProgressBar.setFraction(ui.progress.?, 0);
    gtk.Label.setText(ui.progress_label.?, "starting…");
    ui.logger.info("flash session started", .{});
}

fn onProbeClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    if (ui.busy) return;
    if (ui.device == null) {
        ui.toast("No device detected");
        return;
    }
    spawnWorker(ui, .{ .ui = ui, .kind = .chipinfo, .req = .{} }) catch {
        ui.toast("Failed to start worker thread");
        return;
    };
    ui.setBusy(true);
    gtk.Label.setText(ui.dev_chip_label.?, "Reading chip identity…");
}

fn onCancelClicked(_: *gtk.Button, ui: *Ui) callconv(.c) void {
    ui.cancel.store(true, .release);
    ui.logger.info("cancel requested — aborting between transfers", .{});
}

fn spawnWorker(ui: *Ui, ctx: WorkerCtx) !void {
    ui.cancel = std.atomic.Value(bool).init(false);
    const ctx_mem = try ui.alloc.create(WorkerCtx);
    ctx_mem.* = ctx;
    ui.worker_ctx = ctx_mem;
    ui.worker = try std.Thread.spawn(.{}, workerRun, .{ctx_mem});
}

fn workerRun(ctx: *WorkerCtx) void {
    const ui = ctx.ui;
    switch (ctx.kind) {
        .flash => session.flash(ui.alloc, ui.logger, &ui.cancel, ui.channel, &ctx.req),
        .chipinfo => {
            const info = session.chipInfo(ui.alloc, ui.logger, &ui.cancel, null, 8000) catch |e| {
                pushFinished(ui.channel, false, @errorName(e));
                return;
            };
            ui.channel.push(.{ .chip_info = .{
                .protocol_version = info.protocol_version,
                .serial = info.serial,
                .hwid = info.hwid,
                .msm_id = info.msm_id,
                .oem_id = info.oem_id,
                .model_id = info.model_id,
                .pkhash = ev.FixedStr(140).fromSlice(info.pkhash.slice()),
            } });
            pushFinished(ui.channel, true, "chip info read");
        },
    }
}

fn pushFinished(channel: *EventChannel, success: bool, msg: []const u8) void {
    var m = ev.FixedStr(512){};
    m.set(msg);
    channel.push(.{ .finished = .{ .success = success, .message = m } });
}

// ----------------------------------------------------------------------
// Event / log pumps (GLib main loop side)
// ----------------------------------------------------------------------

fn onTick(ud: ?*anyopaque) callconv(.c) c_int {
    const ui: *Ui = @ptrCast(@alignCast(ud orelse return 0));
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
            refreshDevicePage(ui);
            ui.logger.info("device connected: {s} ({x:0>4}:{x:0>4})", .{ dev.mode.displayName(), dev.vid, dev.pid });
        },
        .device_removed => |key| {
            if (ui.device) |dev| {
                if (dev.key.eql(key)) {
                    ui.device = null;
                    refreshDevicePage(ui);
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
        .finished => |fin| {
            ui.setBusy(false);
            gtk.Widget.setVisible(ui.progress.?.as(gtk.Widget), 0);
            gtk.Widget.setVisible(ui.progress_label.?.as(gtk.Widget), 0);
            if (ui.worker) |w| {
                w.join();
                ui.worker = null;
            }
            if (ui.worker_ctx) |ctx| {
                ui.alloc.destroy(ctx);
                ui.worker_ctx = null;
            }
            if (fin.success) {
                ui.toast(fin.message.slice());
                ui.logger.info("session finished: {s}", .{fin.message.slice()});
            } else {
                var buf: [540]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "session failed: {s}", .{fin.message.slice()}) catch "session failed";
                ui.toast(msg);
                ui.logger.err("{s}", .{msg});
            }
        },
    }
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
