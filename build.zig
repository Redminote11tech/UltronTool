const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gobject = b.dependency("gobject", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "glib", .module = gobject.module("glib2") },
            .{ .name = "gobject", .module = gobject.module("gobject2") },
            .{ .name = "gio", .module = gobject.module("gio2") },
            .{ .name = "gdk", .module = gobject.module("gdk4") },
            .{ .name = "gtk", .module = gobject.module("gtk4") },
            .{ .name = "adw", .module = gobject.module("adw1") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "ultron",
        .root_module = exe_mod,
    });
    exe_mod.linkSystemLibrary("libadwaita-1", .{});
    exe_mod.linkSystemLibrary("libusb-1.0", .{});
    exe_mod.linkSystemLibrary("glib-2.0", .{});
    exe_mod.linkSystemLibrary("libudev", .{});
    b.installArtifact(exe);

    // Desktop integration files.
    const app_id = "io.github.redminote11tech.Ultron";
    b.installFile("data/" ++ app_id ++ ".desktop", "share/applications/" ++ app_id ++ ".desktop",);
    b.installFile("data/" ++ app_id ++ ".metainfo.xml", "share/metainfo/" ++ app_id ++ ".metainfo.xml",);
    b.installFile("data/icons/hicolor/256x256/apps/" ++ app_id ++ ".png", "share/icons/hicolor/256x256/apps/" ++ app_id ++ ".png",);
    b.installFile("data/70-ultron.rules", "lib/udev/rules.d/70-ultron.rules",);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Ultron");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glib", .module = gobject.module("glib2") },
            .{ .name = "gobject", .module = gobject.module("gobject2") },
            .{ .name = "gio", .module = gobject.module("gio2") },
            .{ .name = "gdk", .module = gobject.module("gdk4") },
            .{ .name = "gtk", .module = gobject.module("gtk4") },
            .{ .name = "adw", .module = gobject.module("adw1") },
        },
    });
    test_mod.linkSystemLibrary("glib-2.0", .{});
    test_mod.linkSystemLibrary("libusb-1.0", .{});
    test_mod.linkSystemLibrary("libudev", .{});
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
