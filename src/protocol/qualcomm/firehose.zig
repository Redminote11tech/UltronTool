//! Firehose protocol — Zig port of linux-msm/qdl src/firehose.c (BSD-3-Clause).
//!
//! XML commands over the same bulk endpoints as Sahara. Deliberate small
//! deviation: the configure-response parser is lenient about which payload
//! size attribute is present (bkerler/edl behavior) so that programmer builds
//! that omit MaxPayloadSizeToTargetInBytesSupported still work; qdl requires
//! it on ACK.

const std = @import("std");
const transport = @import("../../transport/transport.zig");
const log = @import("../../core/log.zig");
const xml = @import("xml.zig");
const rawprogram = @import("rawprogram.zig");
const vip = @import("vip.zig");
const fileio = @import("../../core/fileio.zig");

const Io = transport.Io;
const Error = transport.Error;

pub const StorageType = enum {
    emmc,
    ufs,
    spinor,
    nand,
    nvme,

    pub fn memoryName(self: StorageType) []const u8 {
        return switch (self) {
            .emmc => "emmc",
            .ufs => "ufs",
            .spinor => "spinor",
            .nand => "nand",
            .nvme => "nvme",
        };
    }

    pub fn fromMemoryName(s: []const u8) ?StorageType {
        inline for (@typeInfo(StorageType).@"enum".fields) |f| {
            const st: StorageType = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(s, st.memoryName())) return st;
        }
        // Programmers write "eMMC"/"UFS" with random casing — the
        // case-insensitive compare above already covers those spellings.
        return null;
    }
};

pub const default_max_payload_size: usize = 1048576;

pub const Response = struct {
    pub const Kind = enum { ack, nak, timeout, io };
    kind: Kind = .timeout,
    rawmode: bool = false,
    /// A <log> line announced a write failure (UFS error) — the device may
    /// keep consuming the data phase while refusing every write.
    error_seen: bool = false,
    /// A <log> line said the configure MemoryName is not supported.
    memory_name_rejected: bool = false,
    /// MemoryName the programmer reports it actually supports (if any).
    memory_name_buf: [12]u8 = undefined,
    memory_name_len: usize = 0,
    /// Payload size reported by the target (either attribute).
    max_payload_size: ?u64 = null,
    /// 64-char hex digest, when the responses contained one (getsha256digest).
    digest: [64]u8 = undefined,
    digest_len: usize = 0,

    pub fn isAck(self: *const Response) bool {
        return self.kind == .ack;
    }
};

pub const StorageInfo = struct {
    sector_size: u64 = 0,
    num_sectors: u64 = 0,
    page_size: u64 = 0,
    num_physical: u64 = 0,
    mem_type: [64]u8 = undefined,
    mem_type_len: usize = 0,
    prod_name: [64]u8 = undefined,
    prod_name_len: usize = 0,

    pub fn memType(self: *const StorageInfo) []const u8 {
        return self.mem_type[0..self.mem_type_len];
    }

    pub fn prodName(self: *const StorageInfo) []const u8 {
        return self.prod_name[0..self.prod_name_len];
    }
};

pub const ProgressHook = struct {
    ctx: ?*anyopaque = null,
    cb: ?*const fn (ctx: ?*anyopaque, name: []const u8, done: u64, total: u64) void = null,

    fn report(self: ProgressHook, name: []const u8, done: u64, total: u64) void {
        if (self.cb) |cb| cb(self.ctx, name, done, total);
    }
};

const read_buf_size = 4096;

pub const Session = struct {
    alloc: std.mem.Allocator,
    io: *Io,
    logger: *log.Logger,
    cancel: ?*const std.atomic.Value(bool) = null,
    max_payload_size: usize = default_max_payload_size,
    sector_size: u32 = 0,
    storage: StorageType = .ufs,
    progress: ProgressHook = .{},
    /// Active VIP digest-table transfer (set by the manager when the user
    /// chose a VIP tables folder). Null = VIP disabled.
    vip: ?*vip.Transfer = null,
    /// Offline digest generator (GUI digest-table generation). Null = hashing off.
    digest_gen: ?*vip.Generator = null,
    /// The programmer's logs announced VIP (it expects a signed digest table).
    programmer_requires_vip: bool = false,
    /// Force-skip the sector-size probe (used by digest generation, which
    /// must not emit packets the VIP digest table does not cover).
    no_probe: bool = false,

    /// Free the VIP transfer (contents + allocation). The transfer object is
    /// allocated by the manager but the session owns it for the session's
    /// lifetime; demotion inside configure() goes through here so the
    /// manager's teardown can always call it safely.
    pub fn destroyVip(self: *Session) void {
        if (self.vip) |v| {
            v.deinit();
            self.alloc.destroy(v);
            self.vip = null;
        }
    }

    fn cancelled(self: *Session) bool {
        return self.cancel != null and self.cancel.?.load(.acquire);
    }

    // ------------------------------------------------------------------
    // Response loop (port of firehose_read)
    // ------------------------------------------------------------------

    /// Read and consume messages until a <response/> arrives (then wait for
    /// trailing logs until a 100 ms timeout) or the overall deadline passes.
    /// Handles concatenated XML documents, log-before/after-response
    /// ordering, and rawmode responses with pushed-back binary payload.
    pub fn readResponse(self: *Session, timeout_ms: u32) Error!Response {
        var buf: [read_buf_size]u8 = undefined;
        var resp: Response = .{};
        var have_resp = false;
        const deadline = monoNow() + @as(i64, timeout_ms) * std.time.us_per_ms;

        while (true) {
            if (self.cancelled()) return Error.Cancelled;
            const n = self.io.read(&buf, 100) catch |e| switch (e) {
                Error.Timeout => {
                    // Timeout after seeing a response: done waiting for logs.
                    if (have_resp) return resp;
                    if (monoNow() >= deadline) return Response{ .kind = .timeout };
                    continue;
                },
                else => {
                    // On transport error return the response seen so far, if any.
                    if (have_resp) return resp;
                    return Response{ .kind = .io };
                },
            };

            if (monoNow() >= deadline) {
                if (have_resp) return resp;
                return Response{ .kind = .timeout };
            }
            if (n == 0) continue;

            self.logger.debug("FIREHOSE READ: {s}", .{buf[0..n]});

            // Walk the buffer splitting concatenated "<?xml ... </data>"
            // documents; the closing tag bounds each message so rawmode
            // binary arriving spliced onto the same read is not parsed as XML.
            var cursor: usize = 0;
            while (cursor < n) {
                const start = std.mem.indexOfPos(u8, buf[0..n], cursor, "<?xml") orelse break;
                var chunk_end: usize = undefined;
                if (std.mem.indexOfPos(u8, buf[0..n], start, "</data>")) |close| {
                    chunk_end = close + "</data>".len;
                } else {
                    chunk_end = n; // truncated; let the parser report the error
                }

                var elems = std.ArrayList(xml.Element).empty;
                defer elems.deinit(self.alloc);
                self.parseResponseElements(buf[start..chunk_end], &elems) catch {
                    self.logger.err("failed to parse firehose response", .{});
                    return Response{ .kind = .io };
                };

                for (elems.items) |*elem| {
                    if (try self.consumeElement(elem, &resp)) resp.rawmode = true;
                }
                if (resp.kind == .ack or resp.kind == .nak) have_resp = true;

                cursor = chunk_end;

                if (resp.rawmode) {
                    // The response switched us to raw mode; push back any
                    // binary payload spliced onto this read.
                    if (cursor < n) self.io.pushBack(buf[cursor..n]);
                    break;
                }
            }

            if (resp.rawmode) break;
        }

        return resp;
    }

    /// Parse one response document and copy ALL <data> child elements into
    /// self-owned memory (the parse arena dies on return). Devices commonly
    /// bundle <log> lines and the <response> in a single document.
    fn parseResponseElements(self: *Session, bytes: []const u8, out: *std.ArrayList(xml.Element)) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const doc = try xml.parse(arena.allocator(), bytes);
        const root = doc.root;
        if (!std.mem.eql(u8, root.name, "data")) return error.Malformed;
        if (root.children.len == 0) return error.EmptyResponse;

        for (root.children) |el| {
            var copy = xml.Element{ .name = "", .attrs = &.{}, .children = &.{} };
            copy.name = try self.alloc.dupe(u8, el.name);
            const attrs = try self.alloc.alloc(xml.Attr, el.attrs.len);
            for (el.attrs, 0..) |a, k| {
                attrs[k] = .{ .name = try self.alloc.dupe(u8, a.name), .value = try self.alloc.dupe(u8, a.value) };
            }
            copy.attrs = attrs;
            try out.append(self.alloc, copy);
        }
    }

    /// Non-blocking response poll for streaming loops: drains whatever has
    /// already arrived (1 ms transport timeout), splitting concatenated XML
    /// documents exactly like readResponse. Used to catch a mid-stream NAK
    /// immediately instead of after the full stream times out.
    fn pollResponse(self: *Session) Error!Response {
        var buf: [read_buf_size]u8 = undefined;
        const n = self.io.read(&buf, 1) catch |e| switch (e) {
            Error.Timeout => return Response{ .kind = .timeout },
            else => return e,
        };
        if (n == 0) return Response{ .kind = .timeout };

        self.logger.debug("FIREHOSE READ: {s}", .{buf[0..n]});
        var resp: Response = .{};
        var cursor: usize = 0;
        while (cursor < n) {
            const start = std.mem.indexOfPos(u8, buf[0..n], cursor, "<?xml") orelse break;
            var chunk_end: usize = undefined;
            if (std.mem.indexOfPos(u8, buf[0..n], start, "</data>")) |close| {
                chunk_end = close + "</data>".len;
            } else {
                chunk_end = n;
            }

            var elems = std.ArrayList(xml.Element).empty;
            defer elems.deinit(self.alloc);
            self.parseResponseElements(buf[start..chunk_end], &elems) catch {
                self.logger.err("failed to parse firehose response", .{});
                return Response{ .kind = .io };
            };
            for (elems.items) |*elem| {
                if (try self.consumeElement(elem, &resp)) resp.rawmode = true;
            }
            cursor = chunk_end;
            if (resp.rawmode) {
                if (cursor < n) self.io.pushBack(buf[cursor..n]);
                break;
            }
        }
        return resp;
    }

    /// Port of firehose_generic_parser + attribute collection.
    /// Returns whether rawmode was signaled.
    fn consumeElement(self: *Session, elem: *xml.Element, resp: *Response) Error!bool {
        defer self.freeElement(elem);

        const value = elem.attr("value");

        if (std.mem.eql(u8, elem.name, "log")) {
            if (value) |v| {
                self.logger.info("LOG: {s}", .{v});
                self.scanDigest(v, resp);
                // Programmers report storage refusals via log lines BEFORE
                // (or instead of) the final NAK — treat them as a mid-stream
                // failure signal.
                if (std.mem.indexOf(u8, v, "Write Failed") != null or
                    std.mem.indexOf(u8, v, "UFS Error") != null)
                {
                    resp.error_seen = true;
                }
                // bkerler-delta: programmers that lack a storage type say
                // so in a log line ("Not support configure MemoryName …").
                if (!resp.memory_name_rejected and
                    std.mem.indexOf(u8, v, "Not support configure MemoryName") != null)
                {
                    resp.memory_name_rejected = true;
                }
                // VIP programmers announce their digest-table policy in the
                // startup logs (qdl's firehose_check_vip_marker).
                if (!self.programmer_requires_vip and
                    std.mem.indexOf(u8, v, vip.programmer_marker) != null)
                {
                    self.programmer_requires_vip = true;
                    self.logger.info("VIP: programmer expects a signed digest table", .{});
                }
            }
            return false; // keep waiting for the response
        }

        if (value) |v| {
            if (std.mem.eql(u8, v, "ACK")) {
                resp.kind = .ack;
            } else if (std.mem.eql(u8, v, "NAK")) {
                resp.kind = .nak;
            }
        }

        if (elem.attr("rawmode")) |rm| {
            if (std.mem.eql(u8, rm, "true")) return true;
        }

        // Some programmers state the memory type they support (bkerler).
        if (elem.attr("MemoryName")) |mn| {
            const n = @min(mn.len, resp.memory_name_buf.len);
            @memcpy(resp.memory_name_buf[0..n], mn[0..n]);
            resp.memory_name_len = n;
        }

        if (resp.kind == .ack) {
            if (elem.attr("MaxPayloadSizeToTargetInBytesSupported")) |v| {
                resp.max_payload_size = std.fmt.parseInt(u64, v, 10) catch null;
            }
        }
        if (resp.max_payload_size == null) {
            if (elem.attr("MaxPayloadSizeToTargetInBytes")) |v| {
                resp.max_payload_size = std.fmt.parseInt(u64, v, 10) catch null;
            }
        }

        return false;
    }

    fn freeElement(self: *Session, elem: *xml.Element) void {
        for (elem.attrs) |a| {
            self.alloc.free(a.name);
            self.alloc.free(a.value);
        }
        self.alloc.free(elem.attrs);
        self.alloc.free(elem.name);
    }

    /// Port of extract_sha256_hex: scan for a contiguous run of exactly 64
    /// hex characters bounded by non-hex characters or string boundaries.
    fn scanDigest(self: *Session, s: []const u8, resp: *Response) void {
        if (resp.digest_len != 0) return; // keep first digest
        var i: usize = 0;
        while (i + 64 <= s.len) : (i += 1) {
            if (!isHex(s[i])) continue;
            if (i > 0 and isHex(s[i - 1])) continue;
            if (i + 64 < s.len and isHex(s[i + 64])) continue;
            if (!allHex(s[i .. i + 64])) continue;
            @memcpy(resp.digest[0..64], s[i .. i + 64]);
            resp.digest_len = 64;
            self.logger.debug("FIREHOSE: extracted SHA-256 digest from log", .{});
            return;
        }
    }

    // ------------------------------------------------------------------
    // Request write (port of firehose_write)
    // ------------------------------------------------------------------

    /// Port of firehose_vip_send_table: push a digest table when one is due,
    /// and wait for its ACK (only right after a table was actually sent —
    /// the device verifies every subsequent packet against it).
    fn sendVipTable(self: *Session) Error!void {
        const v = self.vip orelse return;
        v.handleTables(self.io, self.logger) catch |e| {
            self.logger.err("VIP: digest table transmission failed", .{});
            return e;
        };
        if (!v.statusCheckNeeded()) return;
        const r = try self.readResponse(30000);
        if (!r.isAck()) {
            self.logger.err("VIP: the programmer rejected the digest table", .{});
            return Error.Io;
        }
        self.logger.info("VIP: digest table accepted", .{});
        v.clearStatus();
    }

    fn writeRequest(self: *Session, req: []const u8) Error!void {
        // VIP tables are pushed before every packet (XML commands included).
        try self.sendVipTable();
        self.logger.debug("FIREHOSE WRITE: {s}", .{req});
        // Digest generation covers every packet exactly once, retries
        // included in the same hash like qdl's firehose_write.
        if (self.digest_gen) |g| g.chunkInit();
        defer if (self.digest_gen) |g| g.chunkStore();
        var retries: u32 = 0;
        while (true) {
            if (self.cancelled()) return Error.Cancelled;
            if (self.digest_gen) |g| g.chunkUpdate(req);
            _ = self.io.write(req, 1000) catch |e| switch (e) {
                Error.Timeout => {
                    // Some programmers send <response> + <log> entries and
                    // refuse writes until drained; read pending data, retry.
                    retries += 1;
                    if (retries > 30) return Error.Timeout;
                    _ = self.readResponse(100) catch {};
                    continue;
                },
                else => return e,
            };
            return;
        }
    }

    // ------------------------------------------------------------------
    // Configure (port of firehose_send_configure / try_configure /
    // detect_and_configure)
    // ------------------------------------------------------------------

    fn buildConfigure(self: *Session, payload_size: usize, skip_storage_init: bool) Error![]const u8 {
        var esc_buf: [128]u8 = undefined;
        var buf: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><configure MemoryName=\"{s}\" MaxPayloadSizeToTargetInBytes=\"{d}\" Verbose=\"0\" ZlpAwareHost=\"1\" SkipStorageInit=\"{d}\" /></data>", .{
            xml.escapeAttr(&esc_buf, self.storage.memoryName()),
            payload_size,
            @intFromBool(skip_storage_init),
        }) catch return Error.Io;
        return self.alloc.dupe(u8, s) catch return Error.OutOfMemory;
    }

    fn sendConfigure(self: *Session, payload_size: usize, skip_storage_init: bool) Error!Response {
        const req = try self.buildConfigure(payload_size, skip_storage_init);
        defer self.alloc.free(req);
        try self.writeRequest(req);
        return self.readResponse(100);
    }

    /// Configure the target, retrying speculatively until the programmer
    /// answers (5 s deadline, port of firehose_detect_and_configure), then
    /// honor the negotiated payload size with a single re-configure, then
    /// probe the sector size. A NAK aborts immediately (qdl semantics);
    /// only timeouts are retried while the programmer boots.
    pub fn configure(self: *Session, storage: StorageType, skip_storage_init: bool) Error!void {
        self.storage = storage;

        // VIP: the signed table can only be sent once per session, so the
        // speculative retry loop must not run (a premature configure would
        // burn the table on a session the programmer was not ready for).
        // Port of firehose_detect_and_configure's VIP branch: drain the
        // startup logs, confirm the programmer really wants VIP (demote
        // otherwise), then a single configure attempt.
        var vip_single = false;
        if (self.vip != null) {
            _ = self.readResponse(5000) catch {};
            if (!self.programmer_requires_vip) {
                self.logger.info("VIP: tables provided but the programmer did not announce VIP — continuing without VIP", .{});
                self.destroyVip();
            } else {
                vip_single = true;
            }
        }

        const deadline = monoNow() + 5 * std.time.us_per_s;

        var resp: Response = .{ .kind = .timeout };
        var fallback_tried = false;
        while (true) {
            if (self.cancelled()) return Error.Cancelled;
            resp = try self.sendConfigure(self.max_payload_size, skip_storage_init);
            // The programmer wants VIP but the host has no tables: bail now
            // instead of waiting out the configure deadline.
            if (self.programmer_requires_vip and self.vip == null) {
                self.logger.err("programmer requires VIP, but no digest tables were provided", .{});
                return Error.VipRequired;
            }
            // Storage-type fallback (bkerler deltas): adopt the MemoryName
            // the programmer reports, or swap ufs<->emmc when it rejected
            // ours. One fallback attempt per configure.
            if (!fallback_tried) {
                if (resp.memory_name_len > 0) {
                    if (StorageType.fromMemoryName(resp.memory_name_buf[0..resp.memory_name_len])) |st| {
                        if (st != self.storage) {
                            self.logger.info("firehose: programmer supports {s} — retrying configure", .{st.memoryName()});
                            self.storage = st;
                            fallback_tried = true;
                            continue;
                        }
                    }
                }
                if (resp.memory_name_rejected and (self.storage == .ufs or self.storage == .emmc)) {
                    self.storage = if (self.storage == .ufs) .emmc else .ufs;
                    fallback_tried = true;
                    self.logger.info("firehose: programmer rejected the memory type — retrying configure as {s}", .{self.storage.memoryName()});
                    continue;
                }
            }
            // A NAK that carries MaxPayloadSizeToTargetInBytes is the
            // programmer proposing a size it can handle (e.g. 16 KiB) — qdl's
            // configure parser accepts it and renegotiates below. Only a NAK
            // without any size attribute is a hard failure.
            if (resp.max_payload_size != null) break;
            if (resp.isAck()) break;
            if (resp.kind == .nak) {
                self.logger.err("configure request failed", .{});
                return Error.Io;
            }
            if (resp.kind == .io) return Error.Io;
            // .timeout: retry until the deadline — except under VIP, where
            // every extra configure would consume a digest.
            if (vip_single or monoNow() > deadline) {
                self.logger.err("failed to detect firehose programmer", .{});
                return Error.Timeout;
            }
        }

        // Re-configure once when the remote proposed a different payload size
        // (ACK: MaxPayloadSizeToTargetInBytesSupported, NAK: the Bytes attr).
        if (resp.max_payload_size) |size| {
            if (size != self.max_payload_size and size > 0) {
                self.logger.info("firehose: target negotiated max payload size {d} -> {d}", .{ self.max_payload_size, size });
                const r2 = try self.sendConfigure(@intCast(size), skip_storage_init);
                if (!r2.isAck()) {
                    self.logger.err("configure request with updated payload size failed", .{});
                    return Error.Io;
                }
                self.max_payload_size = @intCast(size);
            }
        }

        self.logger.debug("accepted max payload size: {d}", .{self.max_payload_size});

        // Probe the sector size by reading sector 1 at 512 then 4096. Skipped
        // under VIP: the probe's packets are not in the digest table, so
        // sending them would cause a VIP hash mismatch on the device.
        if (!skip_storage_init and storage != .nand and self.sector_size == 0 and
            self.vip == null and !self.no_probe)
        {
            self.probeSectorSize();
        }
        if (self.sector_size != 0) {
            self.logger.debug("detected sector size of: {d}", .{self.sector_size});
        }
    }

    fn probeSectorSize(self: *Session) void {
        const sector_sizes = [_]u32{ 512, 4096 };
        var buf: [4096]u8 = undefined;
        for (sector_sizes) |ss| {
            const op = rawprogram.Program{
                .sector_size = ss,
                .num_sectors = 1,
                .partition = 0,
                .start_sector = "1",
            };
            const ok = self.readSectors(&op, &buf) catch continue;
            if (ok) {
                self.sector_size = ss;
                return;
            }
        }
    }

    // ------------------------------------------------------------------
    // Operations
    // ------------------------------------------------------------------

    /// Port of firehose_program: send <program>, stream the file in
    /// max_payload_size chunks (zero-padded to sector boundaries), consume
    /// the final ACK. Returns the number of sectors actually streamed (file
    /// size, clamped by the op's num_partition_sectors) so callers can
    /// verify the write via getsha256digest.
    pub fn program(self: *Session, op: *const rawprogram.Program, file: *fileio.File) Error!u64 {
        const fname = op.filename orelse return 0;
        var zlp_timeout: u32 = 10000;
        // ZLP has been measured to take up to 15 seconds on SPINOR devices.
        if (self.storage == .spinor) zlp_timeout = 60000;

        const sector_size: u64 = if (op.sector_size != 0) op.sector_size else self.sector_size;
        if (sector_size == 0) {
            self.logger.err("unable to determine sector size for {s}", .{fname});
            return Error.Io;
        }
        if (sector_size > self.max_payload_size) {
            self.logger.err("sector size {d} exceeds negotiated payload {d} — aborting", .{ sector_size, self.max_payload_size });
            return Error.Io;
        }

        const file_size = file.size() catch return Error.Io;
        var num_sectors: u64 = (file_size + sector_size - 1) / sector_size;
        if (op.num_sectors != 0 and num_sectors > op.num_sectors) {
            self.logger.err("{s} too big for {s}, truncated to {d} bytes", .{ fname, op.label orelse "?", @as(u64, op.num_sectors) * sector_size });
            num_sectors = op.num_sectors;
        }

        const buf = self.alloc.alloc(u8, self.max_payload_size) catch return Error.OutOfMemory;
        defer self.alloc.free(buf);
        @memset(buf, 0);

        var esc1: [256]u8 = undefined;
        var esc2: [256]u8 = undefined;
        var xml_buf: [8192]u8 = undefined;
        const req = std.fmt.bufPrint(&xml_buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><program SECTOR_SIZE_IN_BYTES=\"{d}\" num_partition_sectors=\"{d}\" physical_partition_number=\"{d}\" start_sector=\"{s}\" filename=\"{s}\"/></data>", .{
            sector_size,
            num_sectors,
            op.partition,
            xml.escapeAttr(&esc1, op.start_sector),
            xml.escapeAttr(&esc2, fname),
        }) catch return Error.Io;

        try self.writeRequest(req);
        const setup = try self.readResponse(10000);
        if (!setup.isAck()) {
            self.logger.err("failed to setup programming of {s}", .{fname});
            return Error.Io;
        }

        file.seekTo(@as(u64, op.file_offset) * sector_size) catch return Error.Io;

        var left: u64 = num_sectors;
        var ack_seen = false; // ACK may arrive while our last chunks are in flight
        var drain_mode = false; // op failed device-side: keep feeding the data phase to finish it
        var drain_deadline: i64 = 0;
        var write_timeouts: u32 = 0;
        while (left > 0) {
            if (self.cancelled()) return Error.Cancelled;
            if (self.digest_gen) |g| g.chunkInit();

            const chunk_sectors = @min(self.max_payload_size / sector_size, left);
            const chunk_bytes = chunk_sectors * sector_size;
            if (drain_mode and monoNow() > drain_deadline) {
                self.logger.err("drain deadline exceeded — the device stopped responding entirely", .{});
                return Error.Timeout;
            }
            // Drain keeps streaming the image's OWN remaining bytes — the
            // file position sits exactly at the failure point — instead of
            // zeros: whatever the device stores past the refusal is real
            // image content, so a partially written partition may still be
            // usable (e.g. oeminfo with intact headers).
            const got = file.readAll(buf[0..@intCast(chunk_bytes)]) catch return Error.Io;
            // Zero-pad short reads: the wire expects exactly chunk_bytes.
            if (got < chunk_bytes) @memset(buf[@intCast(got)..@intCast(chunk_bytes)], 0);

            // The VIP digest covers the exact bytes on the wire (including
            // the zero-padded tail); hash before the table send, matching
            // qdl's firehose_stream_out ordering.
            if (self.digest_gen) |g| g.chunkUpdate(buf[0..@intCast(chunk_bytes)]);
            try self.sendVipTable();

            _ = self.io.write(buf[0..@intCast(chunk_bytes)], zlp_timeout) catch |e| switch (e) {
                Error.Timeout => {
                    // A VIP session cannot recover here: the device counts
                    // packets against the digest table, so a skipped or
                    // repeated chunk desyncs the stream (qdl aborts too).
                    if (self.vip != null) {
                        self.logger.err("device stopped consuming the write during a VIP session — aborting", .{});
                        return Error.Timeout;
                    }
                    write_timeouts += 1;
                    if (!drain_mode) {
                        self.logger.err("device stopped consuming the write — attempting to drain the data phase", .{});
                        drain_mode = true;
                        drain_deadline = monoNow() + 120 * std.time.us_per_s;
                    }
                    // Three strikes with zero consumption: nothing more to
                    // drain over USB; escalate to the reset recovery chain.
                    if (write_timeouts >= 3) {
                        self.logger.err("device is not consuming data at all", .{});
                        return Error.Timeout;
                    }
                    continue;
                },
                else => return e,
            };
            write_timeouts = 0;
            if (self.digest_gen) |g| g.chunkStore();

            // Mid-stream failure handling: a UFS write refusal makes some
            // programmers NAK the operation while still consuming the data
            // phase. There is no cancel command, so the only graceful exit
            // is to keep feeding the declared remaining bytes until the op
            // completes and the programmer returns to command mode — using
            // the image's own data so anything stored past the refusal is
            // real content rather than zeros.
            const mid = self.pollResponse() catch |e| switch (e) {
                Error.Cancelled => return e,
                else => Response{ .kind = .timeout },
            };
            if (mid.isAck()) ack_seen = true;
            // Under VIP a refusal means the digest stream desynced — there
            // is no way to resume against a signed table.
            if (self.vip != null and (mid.error_seen or mid.kind == .nak)) {
                self.logger.err("VIP: the device refused a data packet — the session cannot recover", .{});
                return Error.Io;
            }
            if (mid.error_seen or mid.kind == .nak) {
                if (!drain_mode) {
                    drain_mode = true;
                    drain_deadline = monoNow() + 120 * std.time.us_per_s;
                    self.logger.err("device reported a write failure — draining the data phase with the image's remaining bytes so the session survives", .{});
                }
                // Indeterminate progress with an explicit label: the bar must
                // NOT pretend the write is progressing.
                self.progress.report("write failed — draining", 0, 0);
            }
            if (mid.kind == .io) {
                self.logger.err("unparseable response mid-stream — aborting", .{});
                return Error.Io;
            }

            left -= chunk_sectors;
            self.progress.report(op.label orelse fname, num_sectors - left, num_sectors);
        }

        if (!ack_seen) {
            const final = try self.readResponse(120000);
            if (!final.isAck()) {
                self.logger.err("flashing of {s} failed", .{op.label orelse fname});
                // The data phase completed, so the programmer is back in
                // command mode — the session survives the failed write.
                return error.WriteFailed;
            }
        }
        self.logger.info("flashed \"{s}\" successfully", .{op.label orelse fname});
        return num_sectors;
    }

    /// Port of firehose_erase. num_sectors == 0 erases the full physical
    /// partition (attributes omitted).
    pub fn erase(self: *Session, op: *const rawprogram.Erase) Error!void {
        const sector_size = if (op.sector_size != 0) op.sector_size else self.sector_size;
        var esc_buf: [128]u8 = undefined;
        var xml_buf: [8192]u8 = undefined;

        var req: []const u8 = undefined;
        if (op.num_sectors > 0) {
            req = std.fmt.bufPrint(&xml_buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><erase SECTOR_SIZE_IN_BYTES=\"{d}\" physical_partition_number=\"{d}\" num_partition_sectors=\"{d}\" start_sector=\"{s}\"/></data>", .{
                sector_size,
                op.partition,
                op.num_sectors,
                xml.escapeAttr(&esc_buf, op.start_sector),
            }) catch return Error.Io;
        } else {
            req = std.fmt.bufPrint(&xml_buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><erase SECTOR_SIZE_IN_BYTES=\"{d}\" physical_partition_number=\"{d}\"/></data>", .{
                sector_size,
                op.partition,
            }) catch return Error.Io;
        }

        try self.writeRequest(req);
        const resp = try self.readResponse(30000);
        if (resp.isAck()) {
            self.logger.info("successfully erased {s}+0x{d}", .{ op.start_sector, op.num_sectors });
        } else {
            self.logger.err("failed to erase {s}+0x{d}", .{ op.start_sector, op.num_sectors });
            return Error.Io;
        }
    }

    /// Port of firehose_apply_patch: only patches with filename == "DISK"
    /// are executed on the device (others reference image files).
    pub fn applyPatch(self: *Session, op: *const rawprogram.Patch) Error!void {
        const fname = op.filename orelse return;
        if (!std.mem.eql(u8, fname, "DISK")) return;

        self.logger.debug("applying patch \"{s}\"", .{op.what orelse "?"});
        var esc1: [128]u8 = undefined;
        var esc2: [256]u8 = undefined;
        var esc3: [256]u8 = undefined;
        var xml_buf: [8192]u8 = undefined;
        const req = std.fmt.bufPrint(&xml_buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><patch SECTOR_SIZE_IN_BYTES=\"{d}\" byte_offset=\"{d}\" filename=\"{s}\" physical_partition_number=\"{d}\" size_in_bytes=\"{d}\" start_sector=\"{s}\" value=\"{s}\"/></data>", .{
            op.sector_size,
            op.byte_offset,
            xml.escapeAttr(&esc1, fname),
            op.partition,
            op.size_in_bytes,
            xml.escapeAttr(&esc2, op.start_sector),
            xml.escapeAttr(&esc3, op.value),
        }) catch return Error.Io;

        try self.writeRequest(req);
        const resp = try self.readResponse(5000);
        if (!resp.isAck()) {
            self.logger.err("patch application failed", .{});
            return Error.Io;
        }
    }

    pub fn setBootable(self: *Session, part: u32) Error!void {
        var xml_buf: [512]u8 = undefined;
        const req = std.fmt.bufPrint(&xml_buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><setbootablestoragedrive value=\"{d}\"/></data>", .{part}) catch return Error.Io;
        try self.writeRequest(req);
        const resp = try self.readResponse(5000);
        if (!resp.isAck()) {
            self.logger.err("failed to mark partition {d} as bootable", .{part});
            return Error.Io;
        }
        self.logger.info("partition {d} is now bootable", .{part});
    }

    /// Port of firehose_getsha256digest: ask the programmer for the SHA-256
    /// of a storage range. The hex digest arrives inside a <log> line (the
    /// response parser extracts it). Returns false when no digest came back.
    pub fn getSha256Digest(self: *Session, op: *const rawprogram.Program, out: *[64]u8) Error!bool {
        var esc_buf: [128]u8 = undefined;
        var xml_buf: [8192]u8 = undefined;
        const req = std.fmt.bufPrint(&xml_buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><getsha256digest SECTOR_SIZE_IN_BYTES=\"{d}\" num_partition_sectors=\"{d}\" physical_partition_number=\"{d}\" start_sector=\"{s}\"/></data>", .{
            op.sector_size,
            op.num_sectors,
            op.partition,
            xml.escapeAttr(&esc_buf, op.start_sector),
        }) catch return Error.Io;

        try self.writeRequest(req);
        const resp = try self.readResponse(30000);
        if (resp.digest_len != 64) return false;
        @memcpy(out, resp.digest[0..64]);
        return true;
    }

    /// Port of firehose_reset: <power value="reset" DelayInSeconds="10"/>,
    /// then drain remaining log messages.
    pub fn reset(self: *Session) Error!void {
        const req = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><power value=\"reset\" DelayInSeconds=\"10\"/></data>";
        try self.writeRequest(req);
        const resp = try self.readResponse(5000);
        if (resp.kind == .io) {
            self.logger.err("failed to request device reset", .{});
            return Error.Io;
        }
        // Drain any remaining log messages for the reset.
        _ = self.readResponse(1000) catch {};
    }

    // ------------------------------------------------------------------
    // Read-back (used for the sector-size probe; reusable for backups later)
    // ------------------------------------------------------------------

    /// Port of firehose_issue_read: send <read>, consume the ACK signaling
    /// rawmode, stream the binary data, then consume the final ACK.
    /// Reads into `out` (must fit num_sectors × sector_size).
    pub fn readSectors(self: *Session, op: *const rawprogram.Program, out: []u8) Error!bool {
        const rx = try self.issueRead(op);
        if (!rx) return false;

        const need: u64 = @as(u64, op.num_sectors) * op.sector_size;
        if (out.len < need) return Error.Io;
        var got: u64 = 0;
        while (got < need) {
            if (self.cancelled()) return Error.Cancelled;
            const n = try self.io.read(out[@intCast(got)..@intCast(need)], 30000);
            got += n;
            if (n == 0) break; // ZLP-delimited end of data
        }
        self.progress.report("read", got, need);

        const final = try self.readResponse(10000);
        return final.isAck();
    }

    /// Same exchange, streaming into a file — used for partition reads
    /// (backups), which can be far larger than a buffer we want to hold.
    /// `chunk` is scratch space of any reasonable size (e.g. 1 MiB).
    pub fn readSectorsToFile(self: *Session, op: *const rawprogram.Program, file: *fileio.File, chunk: []u8, label: []const u8) Error!bool {
        const rx = try self.issueRead(op);
        if (!rx) return false;

        const need: u64 = @as(u64, op.num_sectors) * op.sector_size;
        var got: u64 = 0;
        while (got < need) {
            if (self.cancelled()) return Error.Cancelled;
            const n = try self.io.read(chunk, 30000);
            if (n == 0) break; // ZLP-delimited end of data
            const written = file.writeAll(chunk[0..n]) catch {
                var ebuf: [128]u8 = undefined;
                self.logger.err("failed writing to {s}: {s}", .{ label, file.errorMessage(&ebuf) });
                return Error.Io;
            };
            if (written != n) {
                var ebuf: [128]u8 = undefined;
                self.logger.err("write to {s} truncated after {d}/{d} bytes: {s}", .{ label, written, n, file.errorMessage(&ebuf) });
                return Error.Io;
            }
            got += n;
            self.progress.report(label, got, need);
        }

        const final = try self.readResponse(10000);
        file.flush() catch {
            self.logger.err("failed flushing {s} to disk (data may be incomplete)", .{label});
            return Error.Io;
        };
        if (final.isAck() and got != need) {
            self.logger.warn("read of {s} ended early ({d}/{d} bytes)", .{ label, got, need });
        }
        return final.isAck();
    }

    /// Send the <read> request and consume the setup ACK. Returns false when
    /// the target did not signal rawmode (read refused).
    fn issueRead(self: *Session, op: *const rawprogram.Program) Error!bool {
        var esc_buf: [128]u8 = undefined;
        var xml_buf: [8192]u8 = undefined;
        const req = std.fmt.bufPrint(&xml_buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><read SECTOR_SIZE_IN_BYTES=\"{d}\" num_partition_sectors=\"{d}\" physical_partition_number=\"{d}\" start_sector=\"{s}\"/></data>", .{
            op.sector_size,
            op.num_sectors,
            op.partition,
            xml.escapeAttr(&esc_buf, op.start_sector),
        }) catch return Error.Io;

        try self.writeRequest(req);
        const setup = try self.readResponse(10000);
        if (!setup.isAck() or !setup.rawmode) return false;
        return true;
    }

    // ------------------------------------------------------------------
    // Storage info (device page display)
    // ------------------------------------------------------------------

    /// Port of firehose_getstorageinfo: the storage details arrive as a JSON
    /// blob inside a <log> line (entity-escaped on the wire).
    pub fn getStorageInfo(self: *Session, lun: u32) Error!StorageInfo {
        var xml_buf: [512]u8 = undefined;
        const req = std.fmt.bufPrint(&xml_buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><getstorageinfo physical_partition_number=\"{d}\"/></data>", .{lun}) catch return Error.Io;
        try self.writeRequest(req);

        var info = StorageInfo{};
        var buf: [read_buf_size]u8 = undefined;
        const deadline = monoNow() + 30 * std.time.us_per_s;
        while (true) {
            if (self.cancelled()) return Error.Cancelled;
            if (monoNow() >= deadline) return Error.Timeout;
            const n = self.io.read(&buf, 100) catch |e| switch (e) {
                Error.Timeout => continue,
                else => return Error.Io,
            };
            if (n == 0) continue;

            var elems = std.ArrayList(xml.Element).empty;
            defer elems.deinit(self.alloc);
            self.parseResponseElements(buf[0..n], &elems) catch continue;

            for (elems.items) |*elem| {
                const value = elem.attr("value") orelse {
                    self.freeElement(elem);
                    continue;
                };
                if (std.mem.eql(u8, elem.name, "log")) {
                    self.logger.info("LOG: {s}", .{value});
                    if (std.mem.indexOf(u8, value, "\"total_blocks\":") != null) {
                        parseStorageJson(value, &info);
                    }
                    self.freeElement(elem);
                    continue;
                }
                if (std.mem.eql(u8, elem.name, "response")) {
                    const is_ack = std.mem.eql(u8, value, "ACK");
                    self.freeElement(elem);
                    if (is_ack) return info;
                    self.logger.err("getstorageinfo failed", .{});
                    return Error.Io;
                }
                self.freeElement(elem);
            }
        }
    }
};

fn isHex(ch: u8) bool {
    return std.ascii.isHex(ch);
}

fn allHex(s: []const u8) bool {
    for (s) |ch| {
        if (!isHex(ch)) return false;
    }
    return true;
}

fn monoNow() i64 {
    const glib = @import("glib");
    return glib.getMonotonicTime();
}

/// Extract storage_info fields from a log line containing the JSON blob.
fn parseStorageJson(text: []const u8, info: *StorageInfo) void {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return;
    info.num_sectors = extractJsonNumber(text[start..], "total_blocks") orelse 0;
    info.sector_size = extractJsonNumber(text[start..], "block_size") orelse 0;
    info.page_size = extractJsonNumber(text[start..], "page_size") orelse 0;
    info.num_physical = extractJsonNumber(text[start..], "num_physical") orelse 0;
    if (extractJsonString(text[start..], "mem_type")) |s| {
        info.mem_type_len = @min(s.len, info.mem_type.len);
        @memcpy(info.mem_type[0..info.mem_type_len], s[0..info.mem_type_len]);
    }
    if (extractJsonString(text[start..], "prod_name")) |s| {
        info.prod_name_len = @min(s.len, info.prod_name.len);
        @memcpy(info.prod_name[0..info.prod_name_len], s[0..info.prod_name_len]);
    }
}

fn extractJsonNumber(s: []const u8, key: []const u8) ?u64 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const idx = std.mem.indexOf(u8, s, needle) orelse return null;
    var rest = s[idx + needle.len ..];
    rest = std.mem.trim(u8, rest, " ");
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '-')) end += 1;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

fn extractJsonString(s: []const u8, key: []const u8) ?[]const u8 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const idx = std.mem.indexOf(u8, s, needle) orelse return null;
    var rest = s[idx + needle.len ..];
    rest = std.mem.trim(u8, rest, " ");
    if (rest.len < 2 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
    return rest[1..end];
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const Harness = @import("../../transport/sim.zig").Harness;
const SimStep = @import("../../transport/sim.zig").Step;

const TestEnv = struct {
    h: Harness,
    io: transport.Io,
    logger: *log.Logger,
    sess: Session,

    fn init(alloc: std.mem.Allocator, steps: []const SimStep) !*TestEnv {
        const env = try alloc.create(TestEnv);
        errdefer alloc.destroy(env);
        env.h = try Harness.init(alloc, steps);
        env.io = transport.Io.init(alloc, env.h.transport());
        env.logger = try alloc.create(log.Logger);
        env.logger.* = .{ .mirror_stderr = false };
        env.sess = Session{ .alloc = alloc, .io = &env.io, .logger = env.logger };
        return env;
    }

    fn deinit(env: *TestEnv, alloc: std.mem.Allocator) void {
        env.h.deinit();
        env.io.deinit();
        alloc.destroy(env.logger);
        alloc.destroy(env);
    }
};

test "configure with payload renegotiation and sector probe" {
    var probe_data: [512]u8 = @splat(0xAB);

    const steps = [_]SimStep{
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><configure MemoryName=\"ufs\" MaxPayloadSizeToTargetInBytes=\"1048576\" Verbose=\"0\" ZlpAwareHost=\"1\" SkipStorageInit=\"0\" /></data>" },
        .{ .respond = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"INFO: Calling handler for configure\"/><response value=\"ACK\" MaxPayloadSizeToTargetInBytes=\"1048576\" MaxPayloadSizeToTargetInBytesSupported=\"262144\" Version=\"1\"/></data>" },
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><configure MemoryName=\"ufs\" MaxPayloadSizeToTargetInBytes=\"262144\" Verbose=\"0\" ZlpAwareHost=\"1\" SkipStorageInit=\"0\" /></data>" },
        .{ .respond = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\" MaxPayloadSizeToTargetInBytes=\"262144\"/></data>" },
        // Sector-size probe at 512: read → ACK rawmode → data → final ACK.
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><read SECTOR_SIZE_IN_BYTES=\"512\" num_partition_sectors=\"1\" physical_partition_number=\"0\" start_sector=\"1\"/></data>" },
        .{ .respond = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\" rawmode=\"true\"/></data>" },
        .{ .respond = &probe_data },
        .{ .respond = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\"/></data>" },
    };

    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);
    errdefer if (env.h.failure) |f| std.debug.print("SIM MISMATCH: expected vs got: {s}\n", .{f});

    try env.sess.configure(.ufs, false);
    try std.testing.expectEqual(@as(usize, 262144), env.sess.max_payload_size);
    try std.testing.expectEqual(@as(u32, 512), env.sess.sector_size);
}

test "configure accepts NAK size hint and renegotiates once" {
    // Mirrors the nv9_firehose programmer: 1 MiB offered -> NAK proposing
    // 16384 -> re-configure with 16384 -> ACK. Sector probe skipped.
    const nak_size = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"WARN: NAK: MaxPayloadSizeToTargetInBytes sent by host 1048576 larger than supported 16384\"/><response value=\"NAK\" MaxPayloadSizeToTargetInBytes=\"16384\"/></data>";
    const ack_16k = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\" MaxPayloadSizeToTargetInBytes=\"16384\"/></data>";

    const steps = [_]SimStep{
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><configure MemoryName=\"ufs\" MaxPayloadSizeToTargetInBytes=\"1048576\" Verbose=\"0\" ZlpAwareHost=\"1\" SkipStorageInit=\"1\" /></data>" },
        .{ .respond = nak_size },
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><configure MemoryName=\"ufs\" MaxPayloadSizeToTargetInBytes=\"16384\" Verbose=\"0\" ZlpAwareHost=\"1\" SkipStorageInit=\"1\" /></data>" },
        .{ .respond = ack_16k },
    };

    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);

    try env.sess.configure(.ufs, true);
    try std.testing.expectEqual(@as(usize, 16384), env.sess.max_payload_size);
    try std.testing.expect(env.h.failure == null);
}

test "configure retries on timeout until programmer answers" {
    const ack = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\" MaxPayloadSizeToTargetInBytes=\"1048576\"/></data>";
    const steps = [_]SimStep{
        .{ .read_timeout = {} },
        .{ .respond = ack },
    };

    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);
    // Skip the sector probe for this test (skip_storage_init = true).
    try env.sess.configure(.ufs, true);
    try std.testing.expectEqual(@as(usize, 1048576), env.sess.max_payload_size);
}

test "program streams file chunks and consumes final ack" {
    const image_len = 700; // with 512-byte sectors → 2 sectors
    const image = try std.testing.allocator.alloc(u8, image_len);
    defer std.testing.allocator.free(image);
    for (image, 0..) |*b, i| b.* = @truncate(i);

    var padded: [1024]u8 = @splat(0);
    @memcpy(padded[0..image_len], image);

    const ack = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\"/></data>";
    const setup = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"Startprogramming\"/><response value=\"ACK\" rawmode=\"false\"/></data>";

    var tmp_dir = try fileio.TmpDir.init();
    defer tmp_dir.cleanup();
    try tmp_dir.writeFile("boot.img", image);
    var pbuf: [176]u8 = undefined;
    const path = try tmp_dir.filePath(&pbuf, "boot.img");

    const expected_setup = try std.fmt.allocPrint(std.testing.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><program SECTOR_SIZE_IN_BYTES=\"{d}\" num_partition_sectors=\"{d}\" physical_partition_number=\"{d}\" start_sector=\"{s}\" filename=\"{s}\"/></data>", .{ 512, 2, 0, "8192", path });
    defer std.testing.allocator.free(expected_setup);

    const steps = [_]SimStep{
        .{ .expect_write = expected_setup },
        .{ .respond = setup },
        .{ .expect_write = padded[0..1024] },
        .{ .respond = ack },
    };

    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);
    env.sess.max_payload_size = 1024; // chunk = 2 sectors exactly
    env.sess.sector_size = 512;

    var file = try fileio.File.open(path);
    defer file.close();

    const op = rawprogram.Program{
        .sector_size = 512,
        .num_sectors = 2,
        .partition = 0,
        .start_sector = "8192",
        .filename = path,
        .label = "boot",
    };
    _ = try env.sess.program(&op, &file);
    try std.testing.expect(env.h.failure == null);
}

test "erase full partition and ranged erase" {
    const ack = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\"/></data>";
    const steps = [_]SimStep{
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><erase SECTOR_SIZE_IN_BYTES=\"4096\" physical_partition_number=\"0\" num_partition_sectors=\"32\" start_sector=\"8128\"/></data>" },
        .{ .respond = ack },
    };
    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);
    env.sess.sector_size = 4096;
    const op = rawprogram.Erase{
        .sector_size = 4096,
        .num_sectors = 32,
        .partition = 0,
        .start_sector = "8128",
    };
    try env.sess.erase(&op);
}

test "reset sends power with delay and drains logs" {
    const steps = [_]SimStep{
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><power value=\"reset\" DelayInSeconds=\"10\"/></data>" },
        .{ .respond = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"Requesting reset\"/><response value=\"ACK\"/></data>" },
        .{ .respond = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"Powering off in 10s\"/></data>" },
    };
    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);
    try env.sess.reset();
}

test "storage info parses json from log line" {
    const steps = [_]SimStep{
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><getstorageinfo physical_partition_number=\"0\"/></data>" },
        .{ .respond = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"{ &quot;storage_info&quot;: { &quot;storage_type&quot;: &quot;UFS&quot;, &quot;total_blocks&quot;: 30777343, &quot;num_physical&quot;: 6, &quot;block_size&quot;: 4096, &quot;page_size&quot;: 4096, &quot;mem_type&quot;: &quot;ufs&quot;, &quot;prod_name&quot;: &quot;THGAF8G9T43BAIR&quot; }, &quot;card_error&quot;: false }\"/><response value=\"ACK\"/></data>" },
    };
    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);
    const info = try env.sess.getStorageInfo(0);
    try std.testing.expectEqual(@as(u64, 30777343), info.num_sectors);
    try std.testing.expectEqual(@as(u64, 4096), info.sector_size);
    try std.testing.expectEqualStrings("ufs", info.memType());
    try std.testing.expectEqualStrings("THGAF8G9T43BAIR", info.prodName());
}

test "extract json number helper" {
    try std.testing.expectEqual(@as(u64, 42), extractJsonNumber("{\"total_blocks\": 42, \"x\":1}", "total_blocks").?);
    try std.testing.expectEqual(@as(u64, 7), extractJsonNumber("{\"block_size\":7}", "block_size").?);
    try std.testing.expectEqual(@as(?u64, null), extractJsonNumber("{\"other\":1}", "total_blocks"));
}

test "drain streams the image's remaining bytes instead of zeros" {
    const image_len = 2048; // 512-byte sectors → 4 sectors → 2 chunks
    const image = try std.testing.allocator.alloc(u8, image_len);
    defer std.testing.allocator.free(image);
    for (image, 0..) |*b, i| b.* = @truncate(i * 7 + 3);

    const setup_ack = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\"/></data>";
    // nv9-style refusal: a log line mid-data-phase instead of an immediate NAK.
    const faillog = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"Write Failed sector 2, size 2 result 3\"/><response value=\"NAK\"/></data>";
    const nak = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"NAK\"/></data>";

    var tmp_dir = try fileio.TmpDir.init();
    defer tmp_dir.cleanup();
    try tmp_dir.writeFile("oeminfo.img", image);
    var pbuf: [176]u8 = undefined;
    const path = try tmp_dir.filePath(&pbuf, "oeminfo.img");

    const expected_setup = try std.fmt.allocPrint(std.testing.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><program SECTOR_SIZE_IN_BYTES=\"{d}\" num_partition_sectors=\"{d}\" physical_partition_number=\"{d}\" start_sector=\"{s}\" filename=\"{s}\"/></data>", .{ 512, 4, 0, "8192", path });
    defer std.testing.allocator.free(expected_setup);

    const steps = [_]SimStep{
        .{ .expect_write = expected_setup },
        .{ .respond = setup_ack },
        .{ .expect_write = image[0..1024] },
        .{ .respond = faillog },
        // Drain chunk: must be the image's own second half, NOT zeros.
        .{ .expect_write = image[1024..2048] },
        .{ .respond = nak },
        .{ .respond = nak },
    };

    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);
    errdefer if (env.h.failure) |f| std.debug.print("SIM MISMATCH: expected vs got: {s}\n", .{f});
    env.sess.max_payload_size = 1024;
    env.sess.sector_size = 512;

    var file = try fileio.File.open(path);
    defer file.close();

    const op = rawprogram.Program{
        .sector_size = 512,
        .num_sectors = 4,
        .partition = 0,
        .start_sector = "8192",
        .filename = path,
        .label = "oeminfo",
    };
    try std.testing.expectError(error.WriteFailed, env.sess.program(&op, &file));
    try std.testing.expect(env.h.failure == null);
}

test "VIP: marker detected and signed table sent before configure" {
    var tmp_dir = try fileio.TmpDir.init();
    defer tmp_dir.cleanup();
    var signed: [64]u8 = undefined;
    for (&signed, 0..) |*b, i| b.* = @truncate(i + 1);
    try tmp_dir.writeFile("DigestsToSign.bin.mbn", &signed);
    var pbuf: [176]u8 = undefined;
    const vip_dir = try tmp_dir.filePath(&pbuf, "");

    const marker_doc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"INFO: VIP is enabled, receiving the signed table (8192 bytes)\"/><response value=\"ACK\"/></data>";
    const cfg_ack = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\" MaxPayloadSizeToTargetInBytes=\"16384\"/></data>";
    const expected_configure = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><configure MemoryName=\"ufs\" MaxPayloadSizeToTargetInBytes=\"16384\" Verbose=\"0\" ZlpAwareHost=\"1\" SkipStorageInit=\"1\" /></data>";

    const steps = [_]SimStep{
        // Startup output drained by configure's VIP prelude; the marker in
        // the log line keeps VIP active.
        .{ .respond = marker_doc },
        // The signed table precedes the configure packet.
        .{ .expect_write = &signed },
        .{ .respond = cfg_ack },
        .{ .expect_write = expected_configure },
        .{ .respond = cfg_ack },
    };

    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);
    errdefer if (env.h.failure) |f| std.debug.print("SIM MISMATCH: expected vs got: {s}\n", .{f});

    const v = try std.testing.allocator.create(vip.Transfer);
    v.* = try vip.Transfer.init(std.testing.allocator, vip_dir);
    env.sess.vip = v;
    defer env.sess.destroyVip();

    env.sess.max_payload_size = 16384;
    try env.sess.configure(.ufs, true);
    try std.testing.expect(env.sess.programmer_requires_vip);
    try std.testing.expectEqual(@as(usize, 16384), env.sess.max_payload_size);
    try std.testing.expect(env.h.failure == null);
}

test "VIP: program consumes table slots for setup and data packets" {
    var tmp_dir = try fileio.TmpDir.init();
    defer tmp_dir.cleanup();
    var signed: [64]u8 = undefined;
    for (&signed, 0..) |*b, i| b.* = @truncate(i + 1);
    try tmp_dir.writeFile("DigestsToSign.bin.mbn", &signed);
    const image = [_]u8{'A'} ** 512;
    try tmp_dir.writeFile("boot.img", &image);
    var pbuf: [176]u8 = undefined;
    const vip_dir = try tmp_dir.filePath(&pbuf, "");
    const path = try tmp_dir.filePath(&pbuf, "boot.img");

    const v = try std.testing.allocator.create(vip.Transfer);
    v.* = try vip.Transfer.init(std.testing.allocator, vip_dir);

    const ack = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\"/></data>";
    const expected_setup = try std.fmt.allocPrint(std.testing.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><program SECTOR_SIZE_IN_BYTES=\"{d}\" num_partition_sectors=\"{d}\" physical_partition_number=\"{d}\" start_sector=\"{s}\" filename=\"{s}\"/></data>", .{ 512, 1, 0, "8192", path });
    defer std.testing.allocator.free(expected_setup);

    const steps = [_]SimStep{
        .{ .expect_write = &signed }, // pushed before the setup packet
        .{ .respond = ack },
        .{ .expect_write = expected_setup },
        .{ .respond = ack },
        .{ .expect_write = &image }, // the data chunk itself
        .{ .respond = ack },
    };

    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);
    errdefer if (env.h.failure) |f| std.debug.print("SIM MISMATCH: expected vs got: {s}\n", .{f});
    env.sess.max_payload_size = 1024;
    env.sess.sector_size = 512;
    env.sess.vip = v;
    defer env.sess.destroyVip();

    var file = try fileio.File.open(path);
    defer file.close();

    const op = rawprogram.Program{
        .sector_size = 512,
        .num_sectors = 1,
        .partition = 0,
        .start_sector = "8192",
        .filename = path,
        .label = "boot",
    };
    _ = try env.sess.program(&op, &file);
    // Two packets (setup + chunk) consumed digest slots after the table.
    try std.testing.expectEqual(@as(usize, 2), v.frames_sent);
    try std.testing.expect(!v.statusCheckNeeded());
    try std.testing.expect(env.h.failure == null);
}

test "VIP required without tables fails configure clearly" {
    const marker_doc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"INFO: VIP is enabled, receiving the signed table (8192 bytes)\"/><response value=\"ACK\"/></data>";
    const nak = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"NAK\"/></data>";

    const steps = [_]SimStep{
        .{ .respond = marker_doc },
        .{ .any_write = {} }, // configure goes out without a table
        .{ .respond = nak },
    };

    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);
    env.sess.max_payload_size = 16384;
    try std.testing.expectError(error.VipRequired, env.sess.configure(.ufs, true));
}

test "configure falls back to the other memory type on rejection" {
    const reject_ufs = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><log value=\"ERROR: Not support configure MemoryName ufs\"/><response value=\"NAK\"/></data>";
    const ack_emmc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\" MaxPayloadSizeToTargetInBytes=\"1048576\"/></data>";

    const steps = [_]SimStep{
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><configure MemoryName=\"ufs\" MaxPayloadSizeToTargetInBytes=\"1048576\" Verbose=\"0\" ZlpAwareHost=\"1\" SkipStorageInit=\"1\" /></data>" },
        .{ .respond = reject_ufs },
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><configure MemoryName=\"emmc\" MaxPayloadSizeToTargetInBytes=\"1048576\" Verbose=\"0\" ZlpAwareHost=\"1\" SkipStorageInit=\"1\" /></data>" },
        .{ .respond = ack_emmc },
    };

    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);

    try env.sess.configure(.ufs, true);
    try std.testing.expectEqual(StorageType.emmc, env.sess.storage);
    try std.testing.expect(env.h.failure == null);
}

test "configure adopts the MemoryName the programmer reports" {
    const report = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><response value=\"ACK\" MemoryName=\"spinor\" MaxPayloadSizeToTargetInBytes=\"1048576\"/></data>";

    const steps = [_]SimStep{
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><configure MemoryName=\"ufs\" MaxPayloadSizeToTargetInBytes=\"1048576\" Verbose=\"0\" ZlpAwareHost=\"1\" SkipStorageInit=\"1\" /></data>" },
        .{ .respond = report },
        .{ .expect_write = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><data><configure MemoryName=\"spinor\" MaxPayloadSizeToTargetInBytes=\"1048576\" Verbose=\"0\" ZlpAwareHost=\"1\" SkipStorageInit=\"1\" /></data>" },
        .{ .respond = report },
    };

    const env = try TestEnv.init(std.testing.allocator, &steps);
    defer env.deinit(std.testing.allocator);

    try env.sess.configure(.ufs, true);
    try std.testing.expectEqual(StorageType.spinor, env.sess.storage);
    try std.testing.expect(env.h.failure == null);
}
