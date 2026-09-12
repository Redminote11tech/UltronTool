const std = @import("std");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");

pub const app_id = "io.github.redminote11tech.Ultron";

pub fn main() !void {
    var app = adw.Application.new(app_id, .{});
    defer app.unref();
    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &activate, null, .{});
    const status = gio.Application.run(app.as(gio.Application), 0, null);
    std.process.exit(@intCast(status));
}

fn activate(app: *adw.Application, _: ?*anyopaque) callconv(.c) void {
    const window = adw.ApplicationWindow.new(app.as(gtk.Application));
    gtk.Window.setTitle(window.as(gtk.Window), "Ultron");
    gtk.Window.setDefaultSize(window.as(gtk.Window), 900, 640);

    const toolbar = adw.ToolbarView.new();
    const header = adw.HeaderBar.new();
    adw.ToolbarView.addTopBar(toolbar, header.as(gtk.Widget));

    const label = gtk.Label.new("Ultron — Qualcomm EDL flashing tool");
    gtk.Widget.setValign(label.as(gtk.Widget), gtk.Align.center);
    adw.ToolbarView.setContent(toolbar, label.as(gtk.Widget));

    gtk.Window.setChild(window.as(gtk.Window), toolbar.as(gtk.Widget));
    gtk.Window.present(window.as(gtk.Window));
}
