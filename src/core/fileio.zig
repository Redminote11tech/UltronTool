//! libc-backed file I/O helpers.
//!
//! Zig 0.16 routes std file operations through the new `Io` capability
//! handle, which is awkward to thread through worker threads. Ultron links
//! libc anyway, so the few file operations it needs (read XML/programmer
//! files, stream image files during flashing) go through this thin, stable
//! wrapper instead.

const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

/// Read a whole file into an allocated buffer (max_size cap).
pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    var pathz_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pathz = std.fmt.bufPrintZ(&pathz_buf, "{s}", .{path}) catch return error.NameTooLong;

    const f = c.fopen(pathz.ptr, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(f);

    if (c.fseek(f, 0, c.SEEK_END) != 0) return error.Unexpected;
    const sz = c.ftell(f);
    if (sz < 0) return error.Unexpected;
    if (c.fseek(f, 0, c.SEEK_SET) != 0) return error.Unexpected;
    if (@as(usize, @intCast(sz)) > max_size) return error.FileTooBig;

    const buf = try alloc.alloc(u8, @intCast(sz));
    errdefer alloc.free(buf);
    const got = c.fread(buf.ptr, 1, buf.len, f);
    if (got != buf.len) return error.ReadFailed;
    return buf;
}

pub fn exists(path: []const u8) bool {
    var pathz_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pathz = std.fmt.bufPrintZ(&pathz_buf, "{s}", .{path}) catch return false;
    const f = c.fopen(pathz.ptr, "rb") orelse return false;
    _ = c.fclose(f);
    return true;
}

/// Sequential-read file handle for streaming image data to the device.
pub const File = struct {
    handle: *c.FILE,

    pub fn open(path: []const u8) !File {
        var pathz_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pathz = std.fmt.bufPrintZ(&pathz_buf, "{s}", .{path}) catch return error.NameTooLong;
        const f = c.fopen(pathz.ptr, "rb") orelse return error.FileNotFound;
        return .{ .handle = f };
    }

    pub fn close(self: *File) void {
        _ = c.fclose(self.handle);
        self.handle = undefined;
    }

    pub fn size(self: *File) !u64 {
        const saved = c.ftell(self.handle);
        if (saved < 0) return error.Unexpected;
        if (c.fseek(self.handle, 0, c.SEEK_END) != 0) return error.Unexpected;
        const end = c.ftell(self.handle);
        if (end < 0) return error.Unexpected;
        if (c.fseek(self.handle, saved, c.SEEK_SET) != 0) return error.Unexpected;
        return @intCast(end);
    }

    pub fn seekTo(self: *File, pos: u64) !void {
        if (c.fseek(self.handle, @intCast(pos), c.SEEK_SET) != 0) return error.Unexpected;
    }

    /// fread the entire buffer; returns bytes read (short only at EOF).
    pub fn readAll(self: *File, buf: []u8) !usize {
        var total: usize = 0;
        while (total < buf.len) {
            const n = c.fread(buf.ptr + total, 1, buf.len - total, self.handle);
            total += n;
            if (n == 0) break; // EOF or error
        }
        return total;
    }

    /// fwrite the entire buffer; returns bytes written (short on error).
    pub fn writeAll(self: *File, buf: []const u8) !usize {
        const n = c.fwrite(buf.ptr, 1, buf.len, self.handle);
        return n;
    }
};

/// Minimal temp-dir helper for tests (mkdtemp-based, files unlinked on cleanup).
pub const TmpDir = struct {
    path_buf: [80]u8 = undefined,
    path_len: usize = 0,
    files: [8][64]u8 = undefined,
    file_lens: [8]usize = @splat(0),

    pub fn init() !TmpDir {
        var pattern: [64]u8 = undefined;
        const tmpl = std.fmt.bufPrintZ(&pattern, "/tmp/ultron-test-XXXXXX", .{}) catch return error.NameTooLong;
        var buf: [80]u8 = undefined;
        @memcpy(buf[0..tmpl.len], tmpl);
        buf[tmpl.len] = 0;
        const dir = c.mkdtemp(&buf) orelse return error.Unexpected;
        var self = TmpDir{};
        self.path_len = std.mem.len(dir);
        @memcpy(self.path_buf[0..self.path_len], dir[0..self.path_len]);
        return self;
    }

    pub fn path(self: *const TmpDir) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn filePath(self: *const TmpDir, buf: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.path(), name });
    }

    pub fn writeFile(self: *TmpDir, name: []const u8, data: []const u8) !void {
        var fbuf: [176]u8 = undefined;
        const fp = try self.filePath(&fbuf, name);
        var pathz_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pathz = try std.fmt.bufPrintZ(&pathz_buf, "{s}", .{fp});
        const f = c.fopen(pathz.ptr, "wb") orelse return error.Unexpected;
        _ = c.fwrite(data.ptr, 1, data.len, f);
        _ = c.fclose(f);
        for (&self.files, &self.file_lens) |*slot, *l| {
            if (l.* == 0) {
                l.* = @min(name.len, slot.len);
                @memcpy(slot.*[0..l.*], name[0..l.*]);
                return;
            }
        }
        return error.TooManyFiles;
    }

    pub fn cleanup(self: *TmpDir) void {
        for (&self.files, &self.file_lens) |*slot, *l| {
            if (l.* == 0) continue;
            var fbuf: [176]u8 = undefined;
            const fp = std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ self.path(), slot.*[0..l.*] }) catch continue;
            var pathz_buf: [std.fs.max_path_bytes]u8 = undefined;
            const pathz = std.fmt.bufPrintZ(&pathz_buf, "{s}", .{fp}) catch continue;
            _ = c.remove(pathz.ptr);
            l.* = 0;
        }
        var pathz_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pathz = std.fmt.bufPrintZ(&pathz_buf, "{s}", .{self.path()}) catch return;
        _ = c.rmdir(pathz.ptr);
    }
};

test "readFileAlloc and File streaming" {
    var tmp = TmpDir.init() catch return; // skip gracefully in odd sandboxes
    defer tmp.cleanup();

    const image = "0123456789";
    try tmp.writeFile("data.bin", image);
    var pbuf: [176]u8 = undefined;
    const path = try tmp.filePath(&pbuf, "data.bin");

    const data = try readFileAlloc(std.testing.allocator, path, 100);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings(image, data);

    try std.testing.expect(exists(path));

    var file = try File.open(path);
    defer file.close();
    try std.testing.expectEqual(@as(u64, 10), try file.size());
    try file.seekTo(4);
    var buf: [4]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("4567", &buf);
}
