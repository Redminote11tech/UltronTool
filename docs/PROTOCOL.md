# Ultron protocol reference — Qualcomm EDL (Sahara + Firehose)

This document records the protocol constants and rules Ultron implements. Everything
here was verified against actual source code of the reference implementations:

- **linux-msm/qdl** (C, BSD-3-Clause) — primary reference, `refs/qdl` (`src/sahara.c`, `src/firehose.c`, `src/usb.c`, `src/io.c`, `src/qdl.c`)
- **bkerler/edl** (Python, GPL-3.0) — cross-check, `refs/edl` (`edlclient/Library/sahara_defs.py`, `sahara.py`, `firehose.py`)
- **qualcomm/qdlrs** (Rust, BSD-3-Clause) — cross-check, `refs/qdlrs` (`qdl/src/sahara.rs`, `usb.rs`)
- **strongtz/edl-ng** (C#, MIT) — "edl-ng", feature cross-check

## 1. Sahara

All values little-endian. Every packet starts with `u32 cmd; u32 length;`.

### 1.1 Packet commands

| Value | Name (qdl define) | Wire length |
|---|---|---|
| 0x01 | HELLO | 0x30 |
| 0x02 | HELLO_RESPONSE | 0x30 |
| 0x03 | READ_DATA | 0x14 |
| 0x04 | END_OF_IMAGE | 0x10 |
| 0x05 | DONE | 0x08 |
| 0x06 | DONE_RESPONSE | 0x0c |
| 0x07 | RESET | 0x08 |
| 0x08 | RESET_RESPONSE | 0x08 |
| 0x09 | MEM_DEBUG (32-bit) | — |
| 0x0a | MEM_READ (32-bit) | — |
| 0x0b | CMD_READY | — |
| 0x0c | SWITCH_MODE | 0x0c |
| 0x0d | EXECUTE | 0x0c |
| 0x0e | EXECUTE_RESPONSE | 16 |
| 0x0f | EXECUTE_DATA | 0x0c |
| 0x10 | MEM_DEBUG64 | 0x18 |
| 0x11 | MEM_READ64 | 0x18 |
| 0x12 | READ_DATA64 | 0x20 |
| 0x13 | RESET_STATE | — |
| 0x14 | WRITE_DATA | — |

`0x6d783f3c` = bytes of `"<?xm"` — first dword of a Firehose XML greeting arriving
on the wire (device is already running a programmer).

### 1.2 Modes (carried in HELLO / HELLO_RESPONSE)

- `IMAGE_TX_PENDING = 0`, `IMAGE_TX_COMPLETE = 1`, `MEMORY_DEBUG = 2`, `COMMAND = 3`

### 1.3 Struct layouts

```
HELLO_REQ:    u32 version, compatible, max_len, mode, reserved[6]   (total 0x30)
HELLO_RESP:   u32 version, compatible, status,  mode, reserved[6]   (total 0x30)
READ_DATA:    u32 image, offset, length                             (total 0x14)
READ_DATA64:  u64 image, offset, length                             (total 0x20)
END_OF_IMAGE: u32 image, status                                     (total 0x10)
DONE:         (empty)                                               (total 0x08)
DONE_RESPONSE:u32 status                                            (total 0x0c)
EXECUTE:      u32 client_cmd                                        (total 0x0c)
EXECUTE_RESP: u32 client_cmd, data_length                           (16 bytes)
EXECUTE_DATA: u32 client_cmd                                        (total 0x0c)
SWITCH_MODE:  u32 mode                                              (total 0x0c)
MEM_READ64:   u64 addr, length                                      (total 0x18)
debug region64 entry: u64 type, addr, length; char region[20]; char filename[20]  (64 B)
debug region32 entry: u32 type, addr, length; char region[20]; char filename[20]  (52 B)
```

### 1.4 Hello negotiation

- Host protocol version = **2**, compatible = **1** (qdl `SAHARA_VERSION 2`, bkerler 2/1).
- On HELLO: validate `length == 0x30`, log device version/compatible/max_len/mode,
  reply with `status = 0` and `mode = <mode the device requested>`.

### 1.5 Image transfer (`sahara_run` state machine)

1. Read (1 s timeout). First read starting with `<?xml` → device already in
   Firehose mode, skip Sahara entirely.
2. Validate `n == pkt.length` exactly, else fatal.
3. Dispatch on cmd: HELLO / READ_DATA / END_OF_IMAGE / DONE_RESPONSE /
   MEM_DEBUG64 / READ_DATA64 / RESET_RESPONSE (end of ramdump). Unknown → error.
4. READ_DATA: look up image id (reject id ≥ 128 or unknown → error + reset),
   range-check `offset + length <= image.len`, write the slice (device-driven
   offset/length). Same for READ_DATA64.
5. END_OF_IMAGE: `status != 0` → fatal; else send DONE.
6. DONE_RESPONSE: status 0 = "more images pending", 1 = complete.
   (MSM8916 quirk: single image with id 13 → treat done.)

### 1.6 Command mode (chip identity)

- Execute transaction: send EXECUTE(client_cmd) → read reply (≥16 B,
  EXECUTE_RESPONSE, nonzero data_length) → send EXECUTE_DATA → read data_length bytes.
- Protocol version < 3: `MSM_HW_ID_READ = 0x02` (8 B: msm_id = high u32,
  oem/model = low u32). Version ≥ 3: `READ_CHIP_ID_V3 = 0x0a` (resp ≥ 44 B;
  msm_id @36, oem_id @40, model_id @42; fallback oem @44 when oem_id==0 and len ≥ 46).
- Other opcodes: SERIAL_NUM_READ=0x01, OEM_PK_HASH_READ=0x03.
- Sahara status codes: 0 = success, otherwise NAK (0x02 PROTOCOL_MISMATCH,
  0x06 UNEXPECTED_IMAGE_ID, 0x1D CMD_EXEC_FAILURE, 0x25 IMAGE_AUTH_FAILURE, …).

## 2. Firehose (XML over the same bulk endpoints)

### 2.1 Envelope

Requests: `<?xml version="1.0" encoding="UTF-8"?><data>…</data>`.
Responses: root `<data>`, first child element is the response tag; `value="ACK"|"NAK"`;
`<log value="…">` lines may precede/follow the response. Response loop: 100 ms polls
against an overall deadline; concatenated XML docs split on `<?xml` / `</data>`;
`rawmode="true"` → push back leftover bytes and stop XML parsing.

### 2.2 Commands

| Command | Key attributes | ACK timeout |
|---|---|---|
| configure | MemoryName, MaxPayloadSizeToTargetInBytes, Verbose=0, ZlpAwareHost=1, SkipStorageInit | retried until ACK, 5 s deadline |
| program | SECTOR_SIZE_IN_BYTES, num_partition_sectors, physical_partition_number, start_sector, filename | setup 10 s; stream chunks; final 120 s |
| patch | SECTOR_SIZE_IN_BYTES, byte_offset, filename(=="DISK"), physical_partition_number, size_in_bytes, start_sector, value | 5 s |
| erase | SECTOR_SIZE_IN_BYTES, physical_partition_number [, num_partition_sectors, start_sector] | 30 s |
| read | SECTOR_SIZE_IN_BYTES, num_partition_sectors, physical_partition_number, start_sector, filename | setup 10 s; data 30 s; final 10 s |
| getstorageinfo | physical_partition_number | 30 s (storage_info JSON arrives in a log line) |
| setbootablestoragedrive | value=%d | 5 s |
| power (reset) | value="reset", DelayInSeconds="10" | 5 s + 1 s drain |

- Configure negotiation: send 1 MiB; if the response carries
  `MaxPayloadSizeToTargetInBytesSupported` different from what was sent, re-configure
  once with the negotiated size. After configure, probe sector size (512, then 4096).
- Program streaming: `chunk = min(max_payload / sector_size, remaining)` sectors;
  short final reads zero-padded to chunk × sector_size; ZLP write timeout 10 s
  (60 s for SPINOR); final ACK 120 s.
- Program XML has `file_sector_offset` (file pre-seeked by offset × sector_size).

### 2.3 bkerler deltas worth honoring

- `nop` (`<data><nop /></data>`) as probe/handshake.
- MemoryName fallback eMMC → UFS on "Not support configure MemoryName" errors.
- `MaxXMLSizeInBytes`, `MaxPayloadSizeFromTargetInBytes`, Version, TargetName are
  parsed from the configure *response*, not sent.
- Mode detection on first bytes: hello → Sahara; `<?xml` → Firehose; 0x7E → streaming (out of scope v1).

## 3. USB (libusb semantics, from qdl src/usb.c + io.c)

- Device match: **VID 0x05c6, any PID** (EDL PIDs keep growing: 9008, 900e, 901d, 90db…).
  Interface must be vendor-specific: `bInterfaceClass == 0xff`, `bInterfaceSubClass == 0xff`,
  `bInterfaceProtocol ∈ {0xff, 0x10, 0x11, 0x13}`, exactly one bulk IN + one bulk OUT,
  nonzero `wMaxPacketSize` on both.
- 9008 → "EDL", 900e → crash-dump/ramdump.
- Open: retry loop every 250 ms; detach kernel driver; claim interface.
- Write: split into ≤ 1 MiB out-chunks; after the loop, if `total % out_maxpktsize == 0`
  send a **zero-length packet** (ZLP); failure → EIO.
- Read: if `len == actual` and that is an exact multiple of `in_maxpktsize`, issue an
  extra zero-length read to consume the ZLP (failure tolerated). Timeout with 0 bytes →
  ETIMEDOUT; **partial data on timeout = success**.
- Pushback buffer: reads that crossed a Firehose message boundary (XML envelope +
  trailing rawmode binary in one transport read) deliver leftovers on the next read.

## 4. Session orchestration (qdl op-list design)

1. Parse selected files in user-given order → flat op list (program / patch / erase / …).
2. Prepend CONFIGURE op if any ops need one.
3. Append SET_BOOTABLE if a boot partition was programmed.
4. Append RESET unless disabled.
5. Run: Sahara (programmer upload, device-driven) → Firehose (configure → ops). The persistent session stays open for further jobs; the device resets only when the user asks (Reset button) or a job needs recovery.

## 5. VIP — Vendor Image Programming (digest-table auth)

Some programmers enforce per-packet authentication ("VIP"): every Firehose packet
(each XML command document **and** each data chunk) must match the next SHA-256
digest in a vendor-signed table that the host streams over the wire. Ported from
`refs/qdl/src/vip.c` (BSD-3-Clause, © 2025 Qualcomm Innovation Center).

### 5.1 Wire behavior (`vip.zig` Transfer, `firehose.zig` hooks)

- The programmer announces its policy with a startup log line; only the stable
  prefix is matched: `VIP is enabled, receiving the signed table` …
- The signed table (`DigestsToSign.bin.mbn`) is streamed raw before the very
  first Firehose packet; the device ACKs it (30 s deadline).
- Every subsequent packet consumes one digest ("frame"): after 53 frames the
  host streams `ChainedTableOfDigests0.bin`; then 255 frames per chained table,
  up to 32 chained tables (`MAX_CHAINED_FILES`).
- Constraints while VIP is active (all ported from qdl):
  - configure is sent **exactly once** — the speculative retry loop is disabled
    (the table send is one-way; a premature send breaks the session), preceded
    by a 5 s startup-log drain that confirms the marker;
  - the sector-size probe is skipped (its packets are not in the table);
  - no other reads may occur: storage-info queries and GPT reads are not in the
    table, so Ultron disables the partition browser for VIP sessions;
  - a refused data packet is unrecoverable (the digest stream desynced).
- If tables were provided but the programmer never announces VIP, they are
  dropped with a warning; if the programmer announces VIP with no tables,
  configure fails with a clear message.

### 5.2 Table files (`vip.zig` Generator; GUI "Create VIP digest tables")

| File | Content |
|---|---|
| `DIGEST_TABLE.bin` | every packet's SHA-256, in order (32 B each) |
| `DigestsToSign.bin` | first 53 digests + SHA-256 of the complete `ChainedTableOfDigests0.bin` |
| `ChainedTableOfDigests<N>.bin` | next 255 digests each; non-final ones end with the next file's SHA-256, the final one ends with a single `0x00` byte (a bare 512 B multiple would be an ambiguous packet) |
| `DigestsToSign.bin.mbn` | the vendor-signed image of `DigestsToSign.bin` (external signing step) |

Generation (GUI → loader stage → "Create VIP digest tables") replays the
flash plan offline against an auto-ACK loopback device (`digestgen.zig`) while
hashing every packet — exactly the packets a real run
sends. The table is therefore bound to the plan: same XML files, same images,
same order, same storage type, same payload size **with no renegotiation** (pick it in the loader
stage's digest payload dropdown, e.g. 16 KiB, matching what the real run
negotiates), same SkipStorageInit setting. GUI runs pick the folder as "VIP digest tables" on the
loader stage; VIP requires the fresh-boot loader-upload flow.

## 6. Ultron support matrix & roadmap

| Feature | Status | Notes |
|---|---|---|
| Sahara loader upload (v1/v2/v3 devices) | ✅ | Host replies version 2 / compatible 1 with the device's requested mode — qdl's policy, works for all versions; chip identity adapts (HW_ID pre-v3, CHIP_ID_V3 v3+) |
| Firehose configure negotiation | ✅ | 1 MiB offer; ACK-with-Supported and NAK-with-Bytes size hints both renegotiated once; storage-type fallback (ufs↔emmc on rejection, or adopt the MemoryName the programmer reports — bkerler deltas) |
| Sector-size probing | ✅ | 512 → 4096 trial reads, storage-info fallback |
| rawprogram/patch flashing | ✅ | qdl op-list order, set-bootable, allow-missing |
| Partition browser + per-partition read/write | ✅ | GPT per LUN, CRC-verified |
| Write verification (getsha256digest) | ✅ | after every program op (partition write + rawprogram): device SHA-256 of the written range vs local image digest; skips VIP sessions (extra packet would desync the digest table) |
| Drain-to-complete on refused writes | ✅ | Protected partitions fail cleanly; session survives; the drain streams the image's own remaining bytes (not zeros), so whatever lands past a refusal is real image content |
| Stuck-programmer recovery | ✅ | nop probe → USB reset → fresh EDL → auto loader re-upload |
| Huawei UPDATE.APP flashing | ✅ | container parse (55AA5AA5 chunks, splitupdate/`huextract` reference format), Android sparse→raw conversion, image→GPT-partition matching, digest-verified writes; checksum tables not verified (device-side SHA-256 covers it) |
| Multi-device targeting | ✅ | bus/devnum + `_SN:` product-string serial filter (qdl --serial semantics), picker appears with 2+ visible devices |
| Multi-image Sahara archives (zip / id:file) | ⏳ planned | qdl decode_programmer; explicitly deferred |
| RAM dump / Memory Debug (900E crash dumps) | ✅ | MEM_DEBUG64 region table + filtered dumps (minidump.elf assembly deferred) |
| UFS provisioning (<ufs> XML) | ✅ | full qdl ufs.c port: validation pass (commit=0) then commit; the GUI's Finalize switch must match the XML's bConfigDescrLock, and OTP commits require an explicit destructive confirmation |
| VIP (Vendor Image Programming) | ✅ | full qdl vip.c port: GUI digest generation, table streaming, single-configure rule; the vendor signing step stays external; untested against VIP hardware so far |
| Streaming (nandprg/enandprg), Diag | ❌ n/a | NAND-target legacy paths |

## 7. Detection table (Ultron device scanner)

| VID:PID | Meaning | Module (v1 / future) |
|---|---|---|
| 05c6:9008 | Qualcomm EDL | qualcomm |
| 05c6:900e | Qualcomm crash-dump | qualcomm |
| 05c6:* (any other PID, vendor-specific interface) | Qualcomm | qualcomm |
| 0e8d:0003 | MediaTek BROM | mtk (future) |
| 0e8d:2000 / 2001 | MediaTek preloader | mtk (future) |
| 04e8:685d / 6601 / 68c3 | Samsung download mode | samsung/odin (future) |

## 8. Huawei UPDATE.APP (firmware container)

Reference: the classic `splitupdate`/`split_updata.pl` community tools and
the `echo-devim/huextract` layout description. The file is a flat sequence of chunks;
each starts with the magic bytes `55 AA 5A A5` and a variable-length header
(little-endian):

| offset | size | field |
|---|---|---|
| 0 | 4 | magic `55 AA 5A A5` |
| 4 | 4 | header length (>= 98; payload follows it) |
| 8 | 4 | unknown |
| 12 | 8 | hardware id |
| 20 | 4 | file sequence |
| 24 | 4 | payload size |
| 28 | 16 | date string |
| 44 | 16 | time string |
| 60 | 32 | entry name ("BOOT", "SYSTEM", …, NUL-padded) |
| 92 | 2 | header checksum |
| 94 | 4 | checksum block size |
| 98 | len-98 | file checksum table |

Ultron indexes chunks by scanning for the magic (robust against padding,
like the Perl reference). Raw payloads stream straight out of the container
(program supports an absolute byte offset); sparse payloads (Android sparse
`ED26FF3A`) are expanded to raw temp files first — RAW/FILL/DON'T CARE
chunks, holes reading back as zeros. Images are matched to the currently
loaded GPT partitions by name (case-insensitive, ignoring `.img`), and every
write is digest-verified like a partition write. Entries without a matching
partition (SHA256RSA, VERLIST, …) are skipped. The container's checksum
tables are not verified — device-side SHA-256 verification covers the flash.
