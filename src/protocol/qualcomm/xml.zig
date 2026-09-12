//! Minimal XML toolkit for the Firehose protocol.
//!
//! Firehose responses and rawprogram/patch files use a tiny XML subset:
//! an XML declaration, nested elements, and attributes with standard entity
//! escapes. Rather than depend on libxml2 (or an unknown std.xml state),
//! Ultron ships this purpose-built parser/writer. Parsing is arena-allocated
//! so a whole document can be dropped with one deinit.

const std = @import("std");

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Element = struct {
    name: []const u8,
    attrs: []Attr,
    children: []*Element,
    text: []const u8 = "",

    pub fn attr(self: *const Element, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }

    pub fn child(self: *const Element, name: []const u8) ?*Element {
        for (self.children) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Element,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{ Malformed, OutOfMemory };

/// Parse an XML document; the returned Document owns all strings.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) ParseError!Document {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    var p = Parser{ .a = a, .bytes = bytes, .pos = 0 };
    p.skipMisc(); // leading whitespace, XML declaration, comments
    const root = try p.parseElement();
    // Trailing content after the root element: allow whitespace and comments.
    p.skipMisc();
    if (p.pos != bytes.len) return error.Malformed;

    return .{ .arena = arena, .root = root };
}

pub fn parseGop(alloc: std.mem.Allocator, bytes: []const u8) !?Document {
    return parse(alloc, bytes) catch |e| switch (e) {
        error.Malformed => null,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

const Parser = struct {
    a: std.mem.Allocator,
    bytes: []const u8,
    pos: usize,

    fn skipMisc(self: *Parser) void {
        while (self.pos < self.bytes.len) {
            switch (self.bytes[self.pos]) {
                ' ', '\t', '\r', '\n' => self.pos += 1,
                '<' => {
                    if (std.mem.startsWith(u8, self.bytes[self.pos..], "<?") or
                        std.mem.startsWith(u8, self.bytes[self.pos..], "<!--"))
                    {
                        const end = std.mem.indexOfPos(u8, self.bytes, self.pos + 2, if (self.bytes[self.pos + 1] == '!') "-->" else "?>") orelse {
                            self.pos = self.bytes.len;
                            break;
                        };
                        self.pos = end + (if (self.bytes[self.pos + 1] == '!') @as(usize, 3) else 2);
                    } else break;
                },
                else => break,
            }
        }
    }

    fn parseElement(self: *Parser) ParseError!*Element {
        try self.expect('<');
        if (self.pos >= self.bytes.len or self.bytes[self.pos] == '?' or self.bytes[self.pos] == '!')
            return error.Malformed;
        const name = try self.readName();
        var attrs = std.ArrayList(Attr).empty;
        var children = std.ArrayList(*Element).empty;
        var text: []const u8 = "";

        // Attributes
        while (true) {
            self.skipMiscInline();
            if (self.pos >= self.bytes.len) return error.Malformed;
            const ch = self.bytes[self.pos];
            if (ch == '>') {
                self.pos += 1;
                break;
            }
            if (ch == '/') {
                // Self-closing
                self.pos += 1;
                try self.expect('>');
                return try self.makeElement(name, attrs, children, text);
            }
            const attr_name = try self.readName();
            self.skipMiscInline();
            try self.expect('=');
            self.skipMiscInline();
            const quote = if (self.pos < self.bytes.len and (self.bytes[self.pos] == '"' or self.bytes[self.pos] == '\''))
                self.bytes[self.pos]
            else
                return error.Malformed;
            self.pos += 1;
            const val_start = self.pos;
            while (self.pos < self.bytes.len and self.bytes[self.pos] != quote) self.pos += 1;
            if (self.pos >= self.bytes.len) return error.Malformed;
            const raw_value = self.bytes[val_start..self.pos];
            self.pos += 1;
            try attrs.append(self.a, .{ .name = attr_name, .value = try self.unescape(raw_value) });
        }

        // Children / text until </name>
        while (true) {
            const rest_start = self.pos;
            // Find next '<'
            while (self.pos < self.bytes.len and self.bytes[self.pos] != '<') self.pos += 1;
            if (self.pos >= self.bytes.len) return error.Malformed;
            const raw_text = self.bytes[rest_start..self.pos];
            if (!isBlank(raw_text)) text = try self.unescape(raw_text);

            if (std.mem.startsWith(u8, self.bytes[self.pos..], "</")) {
                self.pos += 2;
                const close_name = try self.readName();
                if (!std.mem.eql(u8, close_name, name)) return error.Malformed;
                self.skipMiscInline();
                try self.expect('>');
                return try self.makeElement(name, attrs, children, text);
            }
            if (std.mem.startsWith(u8, self.bytes[self.pos..], "<!--")) {
                const end = std.mem.indexOfPos(u8, self.bytes, self.pos + 4, "-->") orelse return error.Malformed;
                self.pos = end + 3;
                continue;
            }
            if (std.mem.startsWith(u8, self.bytes[self.pos..], "<![CDATA[")) {
                const end = std.mem.indexOfPos(u8, self.bytes, self.pos + 9, "]]>") orelse return error.Malformed;
                text = self.bytes[self.pos + 9 .. end];
                self.pos = end + 3;
                continue;
            }
            const child_elem = try self.parseElement();
            try children.append(self.a, child_elem);
        }
    }

    fn makeElement(self: *Parser, name: []const u8, attrs: std.ArrayList(Attr), children: std.ArrayList(*Element), text: []const u8) ParseError!*Element {
        const el = try self.a.create(Element);
        el.* = .{
            .name = name,
            .attrs = try self.a.dupe(Attr, attrs.items),
            .children = try self.a.dupe(*Element, children.items),
            .text = text,
        };
        return el;
    }

    fn skipMiscInline(self: *Parser) void {
        while (self.pos < self.bytes.len and (self.bytes[self.pos] == ' ' or self.bytes[self.pos] == '\t' or self.bytes[self.pos] == '\r' or self.bytes[self.pos] == '\n')) self.pos += 1;
    }

    fn expect(self: *Parser, ch: u8) ParseError!void {
        if (self.pos >= self.bytes.len or self.bytes[self.pos] != ch) return error.Malformed;
        self.pos += 1;
    }

    fn readName(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (self.pos < self.bytes.len and (std.ascii.isAlphanumeric(self.bytes[self.pos]) or self.bytes[self.pos] == '_' or self.bytes[self.pos] == '-' or self.bytes[self.pos] == ':' or self.bytes[self.pos] == '.')) self.pos += 1;
        if (self.pos == start) return error.Malformed;
        return self.bytes[start..self.pos];
    }

    fn unescape(self: *Parser, s: []const u8) ParseError![]const u8 {
        if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.a);
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '&') {
                if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                    try out.append(self.a, '&');
                    i += 5;
                    continue;
                } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                    try out.append(self.a, '<');
                    i += 4;
                    continue;
                } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                    try out.append(self.a, '>');
                    i += 4;
                    continue;
                } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                    try out.append(self.a, '"');
                    i += 6;
                    continue;
                } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
                    try out.append(self.a, '\'');
                    i += 6;
                    continue;
                } else if (i + 1 < s.len and s[i + 1] == '#') {
                    const hash_end = std.mem.indexOfScalarPos(u8, s, i, ';') orelse return error.Malformed;
                    var code: u21 = undefined;
                    if (i + 2 < s.len and (s[i + 2] == 'x' or s[i + 2] == 'X')) {
                        code = std.fmt.parseInt(u21, s[i + 3 .. hash_end], 16) catch return error.Malformed;
                    } else {
                        code = std.fmt.parseInt(u21, s[i + 2 .. hash_end], 10) catch return error.Malformed;
                    }
                    var utf8: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(code, &utf8) catch return error.Malformed;
                    try out.appendSlice(self.a, utf8[0..n]);
                    i = hash_end + 1;
                    continue;
                }
            }
            try out.append(self.a, s[i]);
            i += 1;
        }
        return try self.a.dupe(u8, out.items);
    }
};

fn isBlank(s: []const u8) bool {
    for (s) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') return false;
    }
    return true;
}

/// Escape a string for use inside a double-quoted attribute value.
/// Returns the escaped slice within `buf` (caller must size it: 6x input worst case).
pub fn escapeAttr(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        const rep: []const u8 = switch (ch) {
            '"' => "&quot;",
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => &[_]u8{ch},
        };
        if (n + rep.len > buf.len) break;
        @memcpy(buf[n .. n + rep.len], rep);
        n += rep.len;
    }
    return buf[0..n];
}

test "parse firehose-style response" {
    var doc = try parse(std.testing.allocator,
        \\<?xml version="1.0" encoding="UTF-8"?><data><response value="ACK" MaxPayloadSizeToTargetInBytes="1048576" MaxPayloadSizeToTargetInBytesSupported="1048576" Version="1" /></data>
    );
    defer doc.deinit();
    const resp = doc.root.child("response").?;
    try std.testing.expectEqualStrings("ACK", resp.attr("value").?);
    try std.testing.expectEqualStrings("1048576", resp.attr("MaxPayloadSizeToTargetInBytes").?);
}

test "parse log lines with entities" {
    var doc = try parse(std.testing.allocator, "<data><log value=\"1: Physical Partition Number &lt;num&gt; 0 - it contains &quot;quoted&quot; stuff\"/><response value=\"NAK\"/></data>");
    defer doc.deinit();
    const log_el = doc.root.child("log").?;
    try std.testing.expectEqualStrings("1: Physical Partition Number <num> 0 - it contains \"quoted\" stuff", log_el.attr("value").?);
    try std.testing.expectEqualStrings("NAK", doc.root.child("response").?.attr("value").?);
}

test "parse rawprogram file" {
    var doc = try parse(std.testing.allocator,
        \\<?xml version="1.0" ?><data>
        \\  <program SECTOR_SIZE_IN_BYTES="4096" file_sector_offset="0" filename="xbl.elf" label="xbl" num_partition_sectors="904" physical_partition_number="0" start_sector="6"/>
        \\  <erase SECTOR_SIZE_IN_BYTES="4096" num_partition_sectors="32" physical_partition_number="0" start_sector="8128"/>
        \\</data>
    );
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.root.children.len);
    const prog = doc.root.children[0];
    try std.testing.expectEqualStrings("program", prog.name);
    try std.testing.expectEqualStrings("xbl.elf", prog.attr("filename").?);
    try std.testing.expectEqualStrings("4096", prog.attr("SECTOR_SIZE_IN_BYTES").?);
    const erase = doc.root.children[1];
    try std.testing.expectEqualStrings("erase", erase.name);
}

test "escapeAttr" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("a&quot;b&amp;c", escapeAttr(&buf, "a\"b&c"));
}
