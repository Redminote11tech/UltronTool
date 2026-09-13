//! rawprogram*.xml / patch*.xml loader — port of linux-msm/qdl src/program.c
//! and src/patch.c (BSD-3-Clause), for the file subset Ultron supports.
//!
//! File type is detected from the root element, mirroring qdl's detect_type():
//! root `data` → program file (program/erase tags), root `patches` → patch
//! file. Image filenames are resolved relative to the XML file's directory
//! (qdl's program_resolve_path); a missing image aborts unless
//! `allow_missing` is set, in which case the op is dropped like qdl does.

const std = @import("std");
const xml = @import("xml.zig");
const log = @import("../../core/log.zig");
const fileio = @import("../../core/fileio.zig");

pub const Loader = struct {
    arena: std.heap.ArenaAllocator,
    ops: std.ArrayList(Op) = .empty,

    pub fn init(alloc: std.mem.Allocator) Loader {
        return .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *Loader) void {
        self.ops.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    pub fn opsSlice(self: *Loader) []Op {
        return self.ops.items;
    }

    /// Load one rawprogram or patch XML file (type detected from root).
    pub fn loadFile(self: *Loader, path: []const u8, allow_missing: bool, logger: *log.Logger) !void {
        const a = self.arena.allocator();
        const contents = fileio.readFileAlloc(a, path, 16 * 1024 * 1024) catch |e| {
            logger.err("unable to read {s}: {s}", .{ path, @errorName(e) });
            return e;
        };
        const doc = xml.parse(a, contents) catch {
            logger.err("failed to parse XML file {s}", .{path});
            return error.Malformed;
        };

        const xml_dir = std.fs.path.dirname(path) orelse ".";

        if (std.mem.eql(u8, doc.root.name, "patches")) {
            try self.loadPatchTags(doc.root, logger);
        } else if (std.mem.eql(u8, doc.root.name, "data")) {
            try self.loadProgramTags(doc.root, xml_dir, allow_missing, logger);
        } else {
            logger.err("failed to detect file type of {s} (root element <{s}>)", .{ path, doc.root.name });
            return error.UnknownFileType;
        }
    }

    fn loadProgramTags(self: *Loader, root: *xml.Element, xml_dir: []const u8, allow_missing: bool, logger: *log.Logger) !void {
        const a = self.arena.allocator();
        for (root.children) |node| {
            if (std.mem.eql(u8, node.name, "program")) {
                var op = Op{ .tag = .{ .program = .{} } };
                const p = &op.tag.program;
                p.sector_size = attrU32(node, "SECTOR_SIZE_IN_BYTES") orelse 0;
                p.num_sectors = attrU32(node, "num_partition_sectors") orelse 0;
                p.partition = attrU32(node, "physical_partition_number") orelse 0;
                p.file_offset = attrU32(node, "file_sector_offset") orelse 0;
                p.start_sector = try self.dupStr(attr(node, "start_sector") orelse "");
                p.label = try self.dupOptStr(attr(node, "label"));

                const filename = attr(node, "filename");
                if (filename) |fname| {
                    p.filename = try self.resolvePath(xml_dir, fname);
                    // Missing image handling, mirroring qdl load_program_tag.
                    if (!fileio.exists(p.filename.?)) {
                        logger.info("unable to open {s}", .{p.filename.?});
                        if (!allow_missing) {
                            logger.info("...failing", .{});
                            return error.MissingImage;
                        }
                        logger.info("...ignoring", .{});
                        p.filename = null;
                    }
                }
                _ = a;
                try self.ops.append(self.arena.child_allocator, op);
            } else if (std.mem.eql(u8, node.name, "erase")) {
                const num_sectors = attrU32(node, "num_partition_sectors") orelse 0;
                if (num_sectors == 0) {
                    logger.err("erase tag with num_partition_sectors=0 not allowed", .{});
                    return error.Malformed;
                }
                var op = Op{ .tag = .{ .erase = .{} } };
                const e = &op.tag.erase;
                e.sector_size = attrU32(node, "SECTOR_SIZE_IN_BYTES") orelse 0;
                e.num_sectors = num_sectors;
                e.partition = attrU32(node, "physical_partition_number") orelse 0;
                e.start_sector = try self.dupStr(attr(node, "start_sector") orelse "");
                try self.ops.append(self.arena.child_allocator, op);
            } else {
                logger.warn("unrecognized tag <{s}> in program-type file, ignoring", .{node.name});
            }
        }
    }

    fn loadPatchTags(self: *Loader, root: *xml.Element, logger: *log.Logger) !void {
        for (root.children) |node| {
            if (!std.mem.eql(u8, node.name, "patch")) {
                logger.warn("unrecognized tag <{s}> in patch-type file, ignoring", .{node.name});
                continue;
            }
            var op = Op{ .tag = .{ .patch = .{} } };
            const p = &op.tag.patch;
            p.sector_size = attrU32(node, "SECTOR_SIZE_IN_BYTES") orelse 0;
            p.byte_offset = attrU32(node, "byte_offset") orelse 0;
            p.filename = try self.dupOptStr(attr(node, "filename"));
            p.partition = attrU32(node, "physical_partition_number") orelse 0;
            p.size_in_bytes = attrU32(node, "size_in_bytes") orelse 0;
            p.start_sector = try self.dupStr(attr(node, "start_sector") orelse "");
            p.value = try self.dupStr(attr(node, "value") orelse "");
            p.what = try self.dupOptStr(attr(node, "what"));
            try self.ops.append(self.arena.child_allocator, op);
        }
    }

    fn dupStr(self: *Loader, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }

    fn dupOptStr(self: *Loader, s: ?[]const u8) !?[]const u8 {
        const str = s orelse return null;
        return try self.dupStr(str);
    }

    /// Resolve an image path: absolute as-is, otherwise relative to the XML
    /// file's directory (qdl program_resolve_path).
    fn resolvePath(self: *Loader, xml_dir: []const u8, fname: []const u8) !?[]const u8 {
        if (std.fs.path.isAbsolute(fname)) return try self.dupStr(fname);
        const joined = try std.fs.path.join(self.arena.allocator(), &.{ xml_dir, fname });
        return joined;
    }
};

pub const Op = struct {
    tag: union(enum) {
        program: Program,
        erase: Erase,
        patch: Patch,
    },
};

pub const Program = struct {
    /// Absolute byte offset of the payload (set by the UPDATE.APP path,
    /// which carves payloads out of a container). When non-zero it
    /// overrides file_offset×sector_size for the local file seek.
    file_byte_offset: u64 = 0,
    sector_size: u32 = 0,
    num_sectors: u32 = 0,
    partition: u32 = 0,
    file_offset: u32 = 0,
    start_sector: []const u8 = "",
    filename: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

pub const Erase = struct {
    sector_size: u32 = 0,
    num_sectors: u32 = 0,
    partition: u32 = 0,
    start_sector: []const u8 = "",
};

pub const Patch = struct {
    sector_size: u32 = 0,
    byte_offset: u32 = 0,
    size_in_bytes: u32 = 0,
    partition: u32 = 0,
    start_sector: []const u8 = "",
    filename: ?[]const u8 = null,
    value: []const u8 = "",
    what: ?[]const u8 = null,
};

fn attr(node: *xml.Element, name: []const u8) ?[]const u8 {
    return node.attr(name);
}

fn attrU32(node: *xml.Element, name: []const u8) ?u32 {
    const v = node.attr(name) orelse return null;
    // strtoul semantics: leading whitespace, decimal (qdl uses base 0 for
    // start_sector elsewhere; these numeric attrs are decimal in practice).
    const trimmed = std.mem.trim(u8, v, " \t");
    return std.fmt.parseInt(u32, trimmed, 0) catch null;
}

test "load rawprogram and patch files from fixture" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("rawprogram0.xml",
        \\<?xml version="1.0" ?><data>
        \\<program SECTOR_SIZE_IN_BYTES="512" file_sector_offset="0" filename="boot.img" label="boot" num_partition_sectors="16384" physical_partition_number="0" start_sector="8192"/>
        \\<erase SECTOR_SIZE_IN_BYTES="512" num_partition_sectors="64" physical_partition_number="0" start_sector="2048"/>
        \\</data>
    );
    try tmp.writeFile("patch0.xml",
        \\<?xml version="1.0" ?><patches>
        \\  <patch SECTOR_SIZE_IN_BYTES="512" byte_offset="72" filename="DISK" physical_partition_number="0" size_in_bytes="8" start_sector="1" value="0x99" what="primary GPT header backup location"/>
        \\</patches>
    );
    try tmp.writeFile("boot.img", "x");

    const logger = try std.testing.allocator.create(log.Logger);
    defer std.testing.allocator.destroy(logger);
    logger.* = .{ .mirror_stderr = false };

    var loader = Loader.init(std.testing.allocator);
    defer loader.deinit();

    var pbuf: [176]u8 = undefined;
    const xml_path = try tmp.filePath(&pbuf, "rawprogram0.xml");
    try loader.loadFile(xml_path, false, logger);

    const ops = loader.opsSlice();
    try std.testing.expectEqual(@as(usize, 2), ops.len);
    switch (ops[0].tag) {
        .program => |p| {
            try std.testing.expectEqual(@as(u32, 512), p.sector_size);
            try std.testing.expectEqual(@as(u32, 16384), p.num_sectors);
            try std.testing.expect(std.mem.endsWith(u8, p.filename.?, "boot.img"));
            try std.testing.expectEqualStrings("boot", p.label.?);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (ops[1].tag) {
        .erase => |e| try std.testing.expectEqual(@as(u32, 64), e.num_sectors),
        else => return error.TestUnexpectedResult,
    }

    var ploader = Loader.init(std.testing.allocator);
    defer ploader.deinit();
    var ppbuf: [176]u8 = undefined;
    const patch_path = try tmp.filePath(&ppbuf, "patch0.xml");
    try ploader.loadFile(patch_path, false, logger);
    try std.testing.expectEqual(@as(usize, 1), ploader.opsSlice().len);
    switch (ploader.opsSlice()[0].tag) {
        .patch => |pt| try std.testing.expectEqualStrings("DISK", pt.filename.?),
        else => return error.TestUnexpectedResult,
    }
}

test "allow_missing drops programs with absent images" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();
    try tmp.writeFile("rawprogram1.xml",
        \\<?xml version="1.0" ?><data>
        \\<program SECTOR_SIZE_IN_BYTES="512" filename="exists.img" label="a" num_partition_sectors="1" physical_partition_number="0" start_sector="1"/>
        \\<program SECTOR_SIZE_IN_BYTES="512" filename="nope.img" label="b" num_partition_sectors="1" physical_partition_number="0" start_sector="2"/>
        \\</data>
    );
    try tmp.writeFile("exists.img", "x");

    const logger = try std.testing.allocator.create(log.Logger);
    defer std.testing.allocator.destroy(logger);
    logger.* = .{ .mirror_stderr = false };

    var loader = Loader.init(std.testing.allocator);
    defer loader.deinit();
    var pbuf: [176]u8 = undefined;
    const xml_path = try tmp.filePath(&pbuf, "rawprogram1.xml");
    try loader.loadFile(xml_path, true, logger);
    const ops = loader.opsSlice();
    try std.testing.expectEqual(@as(usize, 2), ops.len);
    try std.testing.expect(ops[0].tag.program.filename != null);
    try std.testing.expect(ops[1].tag.program.filename == null);
}
