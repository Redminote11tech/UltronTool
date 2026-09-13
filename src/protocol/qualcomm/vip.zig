//! VIP (Vendor Image Programming) digest tables — Zig port of
//! linux-msm/qdl src/vip.c (BSD-3-Clause, © 2025 Qualcomm Innovation Center).
//!
//! Some programmers enforce per-packet authentication ("VIP"): every
//! Firehose packet (each XML command document and each data chunk) must
//! match the next SHA-256 digest in a vendor-signed table that the host
//! streams over the wire. The programmer announces this policy with a
//! startup log line (see `programmer_marker`).
//!
//! Workflow (mirrors qdl):
//!   1. `ultron --create-digests DIR …` replays the flash plan offline and
//!      hashes every packet into `DIGEST_TABLE.bin`, then splits it into
//!      `DigestsToSign.bin` (first 53 digests + chain hash) and
//!      `ChainedTableOfDigests<N>.bin` (255 digests each, chain-hashed
//!      backwards, final one 0-terminated).
//!   2. `DigestsToSign.bin` is signed by the vendor; the signed image is
//!      saved as `DigestsToSign.bin.mbn` next to the chained tables.
//!   3. A flashing run with a VIP tables folder streams the signed table
//!      before the first packet and a chained table whenever the previous
//!      one's digests are exhausted.

const std = @import("std");
const transport = @import("../../transport/transport.zig");
const log = @import("../../core/log.zig");
const fileio = @import("../../core/fileio.zig");

const Io = transport.Io;
const Error = transport.Error;

/// Stable prefix of the log line VIP programmers emit (the trailing text
/// varies per programmer build, so only the prefix is matched — same policy
/// as qdl's VIP_PROGRAMMER_MARKER).
pub const programmer_marker = "VIP is enabled, receiving the signed table";

/// Capacity of each VIP digest table file. The last slot of a table holds a
/// chain hash linking to the next table, so the *_TABLE constants are the
/// number of actual data-chunk digests per table.
pub const max_digests_per_signed_file: usize = 54;
pub const max_digests_per_chained_file: usize = 256;
pub const max_digests_per_signed_table: usize = max_digests_per_signed_file - 1; // 53
pub const max_digests_per_chained_table: usize = max_digests_per_chained_file - 1; // 255
pub const max_chained_files: usize = 32;

const digest_len = 32; // SHA-256

const digest_table_file = "DIGEST_TABLE.bin";
const digests_to_sign_file = "DigestsToSign.bin";
const digests_to_sign_mbn = "DigestsToSign.bin.mbn";
const chained_prefix = "ChainedTableOfDigests";

pub fn chainedCountFor(total_digests: usize) usize {
    if (total_digests <= max_digests_per_signed_table) return 0;
    const remaining = total_digests - max_digests_per_signed_table;
    return (remaining + max_digests_per_chained_table - 1) / max_digests_per_chained_table;
}

fn joinPath(buf: []u8, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name });
}

/// Write `bytes` to `dir/name`, appending to existing content (the chain
/// hashes are appended to already-written tables, like qdl's
/// write_output_file(append=true)).
fn writeFileAppend(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try joinPath(&pbuf, dir, name);
    var old: []const u8 = &.{};
    var owned = false;
    if (fileio.readFileAlloc(alloc, path, 1 << 20)) |data| {
        old = data;
        owned = true;
    } else |_| {}
    defer if (owned) alloc.free(old);

    var out = try fileio.File.create(path);
    const ok = (out.writeAll(old) catch 0) == old.len and (out.writeAll(bytes) catch 0) == bytes.len;
    out.close();
    if (!ok) return error.WriteFailed;
}

// ----------------------------------------------------------------------
// Digest table generator (offline dry runs)
// ----------------------------------------------------------------------

/// Offline digest-table generator: hashes every Firehose packet and writes
/// the signable table set into a directory. Port of qdl's
/// vip_table_generator (the digest_gen_* family).
pub const Generator = struct {
    alloc: std.mem.Allocator,
    dir: []const u8,
    file: ?fileio.File = null,
    digest_num_written: usize = 0,
    ctx: std.crypto.hash.sha2.Sha256 = undefined,

    /// Create DIGEST_TABLE.bin in `dir` and start collecting digests.
    pub fn init(alloc: std.mem.Allocator, dir: []const u8) !Generator {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try joinPath(&pbuf, dir, digest_table_file);
        var g = Generator{ .alloc = alloc, .dir = dir };
        g.ctx = std.crypto.hash.sha2.Sha256.init(.{});
        g.file = try fileio.File.create(path);
        return g;
    }

    pub fn deinit(self: *Generator) void {
        if (self.file) |*f| f.close();
        self.file = null;
    }

    /// Start a new packet hash (port of vip_gen_chunk_init).
    pub fn chunkInit(self: *Generator) void {
        self.ctx = std.crypto.hash.sha2.Sha256.init(.{});
    }

    /// Feed bytes into the current packet hash (vip_gen_chunk_update).
    pub fn chunkUpdate(self: *Generator, bytes: []const u8) void {
        self.ctx.update(bytes);
    }

    /// Finalize the current packet's digest and append it to the table
    /// (vip_gen_chunk_store). Like qdl, a write error closes the file and
    /// further stores become no-ops.
    pub fn chunkStore(self: *Generator) void {
        var digest: [digest_len]u8 = undefined;
        self.ctx.final(&digest);
        const f = &(self.file orelse return);
        const n = f.writeAll(&digest) catch 0;
        if (n != digest.len) {
            f.close();
            self.file = null;
            return;
        }
        self.digest_num_written += 1;
    }

    /// Close DIGEST_TABLE.bin and split it into the signable table set
    /// (port of vip_gen_finalize + create_chained_tables).
    pub fn finalize(self: *Generator) !void {
        if (self.file) |*f| f.close();
        self.file = null;
        try createChainedTables(self.alloc, self.dir, self.digest_num_written);
    }
};

fn createChainedTables(alloc: std.mem.Allocator, dir: []const u8, total: usize) !void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path = try joinPath(&pbuf, dir, digest_table_file);
    const all = try fileio.readFileAlloc(alloc, src_path, 1 << 24);
    defer alloc.free(all);
    if (all.len != total * digest_len) return error.DigestTableCorrupt;

    const signed_count: usize = @min(total, max_digests_per_signed_table);
    const chained_num = chainedCountFor(total);

    // SHA-256 contexts over each chained file's payload (plus the trailing
    // zero byte on the final file). Finalized backwards in step 3 with the
    // next file's chain hash folded in — qdl's cached chain_ctxs trick,
    // which avoids re-reading the files.
    const ctxs = try alloc.alloc(std.crypto.hash.sha2.Sha256, chained_num);
    defer alloc.free(ctxs);

    // Step 1: DigestsToSign.bin = the first `signed_count` digests.
    {
        try writeFileAppend(alloc, dir, digests_to_sign_file, all[0 .. signed_count * digest_len]);
    }

    // Step 2: the remaining digests, 255 per chained table; the final table
    // gets a trailing zero byte (a bare multiple of 512 bytes would be
    // ambiguous as a packet on the wire — qdl's rationale).
    var remaining = total - signed_count;
    var chain_idx: usize = 0;
    while (remaining > 0) : (chain_idx += 1) {
        const count: usize = @min(remaining, max_digests_per_chained_table);
        const start = (total - remaining) * digest_len;
        const payload = all[start .. start + count * digest_len];

        var nbuf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&nbuf, "{s}{d}.bin", .{ chained_prefix, chain_idx });
        try writeFileAppend(alloc, dir, name, payload);

        ctxs[chain_idx] = std.crypto.hash.sha2.Sha256.init(.{});
        ctxs[chain_idx].update(payload);
        remaining -= count;
        if (remaining == 0) {
            const zero = [_]u8{0};
            try writeFileAppend(alloc, dir, name, &zero);
            ctxs[chain_idx].update(&zero);
        }
    }

    // Step 3: hash backwards. Each file's chain hash covers its own complete
    // content (payload, plus the already-appended hash of the next file for
    // non-final tables); hash_0 lands on DigestsToSign.bin.
    var hash: [digest_len]u8 = undefined;
    var i: usize = chained_num;
    while (i > 0) {
        i -= 1;
        var ctx = ctxs[i];
        if (i < chained_num - 1) ctx.update(&hash);
        ctx.final(&hash);

        var nbuf: [64]u8 = undefined;
        const name = if (i == 0)
            digests_to_sign_file
        else
            try std.fmt.bufPrint(&nbuf, "{s}{d}.bin", .{ chained_prefix, i - 1 });
        try writeFileAppend(alloc, dir, name, &hash);
    }
}

// ----------------------------------------------------------------------
// Runtime transfer (real flashing runs)
// ----------------------------------------------------------------------

/// Per-session VIP state: the signed + chained tables to stream, and the
/// frame accounting that decides when the next table is due. Port of
/// struct vip_transfer_data + vip_transfer_init/handle_tables.
pub const Transfer = struct {
    pub const State = enum { init, send_data, send_next_table };

    alloc: std.mem.Allocator,
    signed_table: []u8,
    chained: [max_chained_files][]u8 = undefined,
    chained_num: usize = 0,
    chained_cur: usize = 0,
    state: State = .init,
    frames_sent: usize = 0,
    frames_left: usize = 0,
    /// Set whenever a table was actually sent, so the Firehose layer knows
    /// to consume the table's ACK (firehose_vip_send_table's status check).
    fh_parse_status: bool = false,

    /// Load `dir`/DigestsToSign.bin.mbn plus every ChainedTableOfDigests<N>.bin
    /// that exists (up to max_chained_files).
    pub fn init(alloc: std.mem.Allocator, dir: []const u8) !Transfer {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const signed_path = try joinPath(&pbuf, dir, digests_to_sign_mbn);
        const signed = try fileio.readFileAlloc(alloc, signed_path, 1 << 20);
        errdefer alloc.free(signed);

        var t = Transfer{ .alloc = alloc, .signed_table = signed };
        var i: usize = 0;
        while (i < max_chained_files) : (i += 1) {
            var nbuf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&nbuf, "{s}{d}.bin", .{ chained_prefix, i });
            const cpath = try joinPath(&pbuf, dir, name);
            const data = fileio.readFileAlloc(alloc, cpath, 1 << 20) catch break; // no more chained tables
            t.chained[t.chained_num] = data;
            t.chained_num += 1;
        }
        return t;
    }

    pub fn deinit(self: *Transfer) void {
        self.alloc.free(self.signed_table);
        for (self.chained[0..self.chained_num]) |data| self.alloc.free(data);
        self.chained_num = 0;
    }

    fn sendRaw(self: *Transfer, io: *Io, logger: *log.Logger, data: []const u8) Error!void {
        _ = self;
        const n = io.write(data, 1000) catch |e| {
            logger.err("VIP: USB write failed for digest table", .{});
            return e;
        };
        if (n != data.len) {
            logger.err("VIP: digest table write truncated", .{});
            return Error.Io;
        }
    }

    /// Called before every packet write. Sends the signed table once at the
    /// start, then a chained table whenever the previous one's digests are
    /// exhausted (port of vip_transfer_handle_tables).
    pub fn handleTables(self: *Transfer, io: *Io, logger: *log.Logger) Error!void {
        switch (self.state) {
            .init => {
                try self.sendRaw(io, logger, self.signed_table);
                logger.info("VIP: signed digest table sent", .{});
                self.state = .send_data;
                self.frames_sent = 0;
                self.frames_left = max_digests_per_signed_table;
                self.fh_parse_status = true;
            },
            .send_next_table => {
                if (self.chained_cur >= self.chained_num) {
                    logger.err("VIP: the required quantity of chained tables is missing", .{});
                    return Error.Io;
                }
                try self.sendRaw(io, logger, self.chained[self.chained_cur]);
                logger.info("VIP: chained digest table {d} sent", .{self.chained_cur});
                self.state = .send_data;
                self.frames_sent = 0;
                self.frames_left = max_digests_per_chained_table;
                self.fh_parse_status = true;
                self.chained_cur += 1;
            },
            .send_data => {},
        }
        self.frames_sent += 1;
        if (self.frames_sent >= self.frames_left) self.state = .send_next_table;
    }

    pub fn statusCheckNeeded(self: *const Transfer) bool {
        return self.fh_parse_status;
    }

    pub fn clearStatus(self: *Transfer) void {
        self.fh_parse_status = false;
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const Harness = @import("../../transport/sim.zig").Harness;
const SimStep = @import("../../transport/sim.zig").Step;

/// Hash `count` distinct fake packets through `gen`, as the firehose layer
/// would during a dry run.
fn hashPackets(gen: *Generator, count: usize) void {
    var pkt: [16]u8 = undefined;
    for (0..count) |i| {
        gen.chunkInit();
        for (&pkt, 0..) |*b, k| b.* = @truncate(i * 31 + k);
        gen.chunkUpdate(&pkt);
        gen.chunkStore();
    }
}

test "generator splits digests into signed table + chained table with chain hash" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();

    var gen = try Generator.init(std.testing.allocator, tmp.path());
    defer gen.deinit();
    hashPackets(&gen, 60); // 53 signed slots + 7 chained digests
    try gen.finalize();

    // DigestsToSign.bin: 53 digests + SHA256(ChainedTableOfDigests0.bin).
    var pbuf: [176]u8 = undefined;
    const sign_path = try tmp.filePath(&pbuf, digests_to_sign_file);
    const signed = try fileio.readFileAlloc(std.testing.allocator, sign_path, 1 << 20);
    defer std.testing.allocator.free(signed);
    try std.testing.expectEqual(@as(usize, 53 * 32 + 32), signed.len);

    const chained_path = try tmp.filePath(&pbuf, "ChainedTableOfDigests0.bin");
    const chained = try fileio.readFileAlloc(std.testing.allocator, chained_path, 1 << 20);
    defer std.testing.allocator.free(chained);
    // 7 digests + trailing zero byte, and the chain hash over it matches.
    try std.testing.expectEqual(@as(usize, 7 * 32 + 1), chained.len);
    var expect_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(chained, &expect_hash, .{});
    try std.testing.expectEqualSlices(u8, &expect_hash, signed[53 * 32 ..]);

    // First digests in DigestsToSign.bin match the packets' SHA-256s.
    var digest: [32]u8 = undefined;
    var pkt: [16]u8 = undefined;
    for (0..53) |i| {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        for (&pkt, 0..) |*b, k| b.* = @truncate(i * 31 + k);
        h.update(&pkt);
        h.final(&digest);
        try std.testing.expectEqualSlices(u8, &digest, signed[i * 32 ..][0..32]);
    }
}

test "generator with few digests produces only DigestsToSign.bin" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();

    var gen = try Generator.init(std.testing.allocator, tmp.path());
    defer gen.deinit();
    hashPackets(&gen, 10);
    try gen.finalize();

    var pbuf: [176]u8 = undefined;
    const sign_path = try tmp.filePath(&pbuf, digests_to_sign_file);
    const signed = try fileio.readFileAlloc(std.testing.allocator, sign_path, 1 << 20);
    defer std.testing.allocator.free(signed);
    try std.testing.expectEqual(@as(usize, 10 * 32), signed.len);
    try std.testing.expect(!fileio.exists(try tmp.filePath(&pbuf, "ChainedTableOfDigests0.bin")));
}

test "transfer streams the signed table, then chained tables at frame boundaries" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();

    var signed_content: [53 * 32]u8 = undefined;
    for (&signed_content, 0..) |*b, i| b.* = @truncate(i + 1);
    var chained_content: [255 * 32 + 1]u8 = undefined;
    for (&chained_content, 0..) |*b, i| b.* = @truncate(i + 200);
    try tmp.writeFile(digests_to_sign_mbn, &signed_content);
    try tmp.writeFile("ChainedTableOfDigests0.bin", &chained_content);

    var pbuf: [176]u8 = undefined;
    const dir = try tmp.filePath(&pbuf, "");
    var t = try Transfer.init(std.testing.allocator, dir);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.chained_num);

    var h = try Harness.init(std.testing.allocator, &.{});
    defer h.deinit();
    var io = transport.Io.init(std.testing.allocator, h.transport());
    defer io.deinit();

    const logger = try std.testing.allocator.create(log.Logger);
    defer std.testing.allocator.destroy(logger);
    logger.* = .{ .mirror_stderr = false };

    // Calls 1..308 consume the signed table (53 frames) and chained table 0
    // (255 frames); only calls 1 and 54 transmit a table. The firehose layer
    // clears the status flag after consuming each table's ACK.
    for (0..308) |_| {
        try t.handleTables(&io, logger);
        t.clearStatus();
    }
    // Exactly two table writes happened, signed table first.
    try std.testing.expectEqualSlices(u8, &signed_content, h.written.items[0..signed_content.len]);
    try std.testing.expectEqualSlices(u8, &chained_content, h.written.items[signed_content.len..][0..chained_content.len]);
    try std.testing.expectEqual(@as(usize, signed_content.len + chained_content.len), h.written.items.len);

    // The 309th packet needs a third chained table that does not exist.
    try std.testing.expectError(error.Io, t.handleTables(&io, logger));
}

test "transfer round-trips generator output" {
    var tmp = try fileio.TmpDir.init();
    defer tmp.cleanup();

    var gen = try Generator.init(std.testing.allocator, tmp.path());
    defer gen.deinit();
    hashPackets(&gen, 60);
    try gen.finalize();

    // The user's signing step: DigestsToSign.bin → DigestsToSign.bin.mbn.
    var pbuf: [176]u8 = undefined;
    const sign_path = try tmp.filePath(&pbuf, digests_to_sign_file);
    const signed = try fileio.readFileAlloc(std.testing.allocator, sign_path, 1 << 20);
    defer std.testing.allocator.free(signed);
    try tmp.writeFile(digests_to_sign_mbn, signed);

    const dir = try tmp.filePath(&pbuf, "");
    var t = try Transfer.init(std.testing.allocator, dir);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.chained_num);
    try std.testing.expectEqual(@as(usize, 53 * 32 + 32), t.signed_table.len);
}

