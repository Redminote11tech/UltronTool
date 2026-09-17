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

## 6. Ultron support matrix (Qualcomm)

Cross-vendor plans live in `docs/ROADMAP.md`.

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
| Samsung Odin (Thor protocol) | ⚠️ implemented, hardware untested | PIT dump → partition browser, image→partition flash, PIT flash, partition zero-fill erase, reboot / reboot-to-download, factory reset, tar.md5 bundle flashing (md5-verified, sparse-aware); protocol v0/1 and v2+ (1 MiB parts); compressed download (v2+ flag) not implemented |
| LG LAF (download mode) | ⚠️ implemented, hardware untested | GPT read → partition browser, partition backup (read-back works), image→partition flash, ERSE/TRIM erase (lands on reboot), reboot/power-off; chunked at the reference's 15.5 KiB; shell EXEC deliberately not implemented |
| MediaTek BROM | ⚠️ sync/DA/flash, hardware untested | inverted-echo sync, chip identification, SEND_DA/JUMP_DA, and legacy-DA flash ops (READ_CMD / SDMMC_WRITE_DATA / FORMAT_CMD with checksums, eMMC scope) |
| Unisoc BSL | ⚠️ implemented, hardware untested | bootrom handshake + version, FDL1/FDL2 upload (stage checksum switch), address-based and partition-name (UTF-16LE select) flash read/write/erase, HDLC framing |

## 7. Detection table (Ultron device scanner)

| VID:PID | Meaning | Module (v1 / future) |
|---|---|---|
| 05c6:9008 | Qualcomm EDL | qualcomm |
| 05c6:900e | Qualcomm crash-dump | qualcomm |
| 05c6:* (any other PID, vendor-specific interface) | Qualcomm | qualcomm |
| 0e8d:0003 | MediaTek BROM | mtk |
| 0e8d:2000 / 2001 | MediaTek preloader | mtk |
| 04e8:685d / 6601 / 68c3 | Samsung download mode | samsung/odin |
| 1004:633e | LG download mode (LAF) | lg/laf |
| 1782:4d00 | Unisoc bootrom (BSL) | spd |
| Unisoc download mode | BootROM/BSL + FDL1/FDL2 stages | unisoc (planned — IDs to confirm from references) |
| LG download mode | LAF daemon | lg/laf (planned — IDs to confirm from references) |

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

## 9. Planned protocol modules

Priority order and per-module references live in `docs/ROADMAP.md` (owner-set). Summary:

| # | Module | Direction | Primary reference |
|---|---|---|---|
| 1 | Samsung — Odin/Thor | download-mode flashing, PIT | `Samsung-Loki/Thor`, cross-checked with `Llucs/odin4` and Samsung's Odin4; Heimdall docs only, no code ported |
| 2 | MediaTek — BROM/DA | BROM sync, DA upload, flash ops | `bkerler/mtkclient` |
| 3 | Unisoc — FDL1/FDL2 | BSL session, FDL chain, flash ops | `ilyakurdyukov/spreadtrum_flash` + active fork `TomKing062/spreadtrum_flash` |
| 4 | LG — LAF | download-mode partition ops | `Lekensteyn/lglaf` (protocol.md + dissector) |

All Qualcomm-specific sections above (§1–§8) describe the shipped module and are
unaffected by these plans.

## 10. Samsung Odin (Thor protocol) — `protocol/samsung/`

Ported from `Samsung-Loki/Thor` (C#, MIT) `Protocols/Odin.cs` + `PIT/*` +
`Platform/Linux.cs`, cross-checked against odin4's `src/protocol/thor_protocol.h`.

USB: VID 04e8, download-mode PIDs 685d/6601/68c3; the Loke bootloader serves the
protocol on a **CDC-Data interface (class 0x0a)** with one bulk IN + one bulk OUT.
The host must NOT send qdl-style trailing ZLPs — the transport's write ZLP is
disabled for Samsung sessions (`set_write_zlp`).

Handshake: host sends ASCII `ODIN` (4 bytes), device answers `LOKE`.

Requests are 1024-byte zero-padded boxes `[region u32][param u32][int args…]`
(little-endian); responses are 8 bytes `[id u32][ack u32]`. `id = 0xFFFFFFFF`
marks a bootloader failure with the code in `ack` (Thor's OdinFailCheck); a
wrong region id is also rejected (odin4). Regions:

| Region | Params (ack meaning) |
|---|---|
| `0x64` init | 0 = BeginSession (ack packs `[unk1 u8][unk2 u8][protocol i16]`), 1 = reset flash counter, 2 = SetTotalBytes (u64 arg), 5 = announce part size (v2+), 7 = erase userdata (10 min timeout) |
| `0x65` PIT | 0 = flash PIT, 1 = dump request (ack = PIT size), 2 = one 500-byte block / begin, 3 = complete |
| `0x66` xmit | 0 = request file flash, 2 = request sequence (arg: aligned size), 3 = end sequence |
| `0x67` close | 0 = end session, 1 = reboot, 2 = reboot to download mode, 3 = power off |

Protocol versions: the host offers `0x7FFFFFFF` and the bootloader reports its own
(0/1 → 128 KiB parts, 240-part sequences, 30 s end-sequence timeout; v2+ → 1 MiB
parts announced by the host, 30-part sequences, 120 s). The v2+ compressed-download
capability flag (ack bit 15) is documented but not implemented.

File transfer: per sequence — request (aligned size) → N part writes, each ACKed
with the part index (mismatch = hard error) → end sequence packet. Phone
partitions: `[0x66][3][0][realSize][binaryType][deviceType][partitionId][last]
[efsClear][bootloaderUpdate]`; modem partitions (binary type 1) use the short
form without partition id. The device writes nothing until end sequence.
Failure codes at end sequence: -2 write-protected, -3 erase, -4 write,
-5 auth, -6 size, -7 ext4 — mapped to typed transport errors (session survives).

Erase = flash zeros of the partition size with a null file (Thor's
ErasePartition). Every flash/erase job re-dumps the PIT in-session to resolve
the entry, exactly like Thor's CLI flow.

PIT format: magic `0x12349876`, u32 entry count, 8-byte unknown, 8-byte project,
u32 reserved; then 132-byte entries: binary type, device type, partition id,
attributes, update attributes, block size, block count, file offset, file size
(u32 LE each) + partition/file/delta names (32-byte ASCII). Blocks are 512-byte
device blocks on eMMC/UFS targets.

## 11. LG LAF — `protocol/lg/`

Ported from `Lekensteyn/lglaf` (lglaf.py + protocol.md, MIT).

USB: VID 1004 PID 633e; LAF runs as a bulk pair (CDC-Data interface on the
reference dumps). Interface matching is structural (bulk IN + OUT), not
class-bound.

Framing: 32-byte header — command[4], four u32 arguments, body length u32,
CRC-16-CCITT reflected (poly 0x8408, init/final XOR 0xFFFF) stored in a 4-byte
field, and a bit-wise inversion of the command — followed by the body. `FAIL`
responses carry the error code in arg1. Commands: HELO (version 0x01000001,
re-sent per the reference), OPEN (empty body = /dev/block/mmcblk0 rw) → fd,
CLSE, READ (arg2 = 512-byte block offset, arg3 = length, ≤ 15.5 KiB chunks —
larger reads hang lafd), WRTE (response byte offset must match, wrapping),
ERSE (TRIM — old data reads back until reboot), CTRL (RSET/POFF/ONRS). Writes
refuse the GPT area (first 34 sectors) — reference guard, extended to erases.
Shell EXEC is deliberately not implemented.

## 12. MediaTek BROM — `protocol/mtk/`

Ported from `bkerler/mtkclient` (Port.py run_handshake/mtk_cmd, mtk_preloader
Cmd table).

USB: VID 0e8d, PIDs 0003 (BROM) / 2000, 2001 (preloader), structural bulk pair.
CDC VCOM setup before sync: SET_LINE_CODING 921600 8N1 + SET_CONTROL_LINE_STATE
RTS (control-transfer hook; degrades to a debug note when unsupported).

Sync: bytes A0 0A 50 05 sent one at a time, each echoed bit-inverted
(5F F5 AF FA); 30 attempts with stale-byte drain. Commands are echoed then
answered big-endian: GET_HW_CODE (0xFD) → hwcode u16 + hw_sub_code u16,
GET_HW_SW_VER (0xFC) → four u16. SEND_DA (0xD7): BE address/size/sig_len
echo-verified, u16 status (0x1D0D = SLA locked — refused), XOR-of-LE-words
checksum, EP-paced streaming with ZLPs every 0x2000 + the final one, then
BE u16 checksum+status. JUMP_DA (0xD5): BE address echoed back + u16 status.
Legacy-DA flash operations (`protocol/mtk/daflash.zig`): the Rsp character
protocol (ACK 0x5A, NACK 0xA5, CONT 0x69), SDMMC_SWITCH_PART (0x60) hardware
partition select, READ_CMD (0xD6, eMMC: host id 0x0C, storage 0x02, BE
addr/len, 1 MiB packets with BE u16 per-packet checksums, ACK each),
SDMMC_WRITE_DATA (0x62: BE storage/part/addr/len + 1 MiB packet size; per
packet host-ACK → data + byte-sum → device-CONT; length 512-padded),
FORMAT_CMD (0xD4) with the ACK/progress-% pump, USB_CHECK_STATUS (0x72) and
FINISH (0xD9). NOR/NAND paths unported — eMMC/UFS devices only.

## 13. Unisoc BSL bootrom — `protocol/spd/`

Ported from `ilyakurdyukov/spreadtrum_flash` (spd_dump.c + spd_cmd.h, MIT).

USB: VID 1782 PID 4d00 (bootrom). CDC SET_CONTROL_LINE_STATE with wValue
0x601 first (smartphone bootroms require it). Frames: type u16 BE, length u16
BE, payload, checksum u16 BE — bootrom uses CRC-16/XMODEM (poly 0x1021), FDL2
uses a folded byte sum — HDLC-encoded with 0x7E delimiters and 0x7D stuffing.
Probe: CHECK_BAUD (bare 0x7E bytes) → BSL_REP_VER version string, CONNECT →
ACK. FDL upload: START_DATA (BE addr + size) → 528-byte MIDST chunks →
END_DATA → EXEC_DATA (15 s boot delay; the INCOMPATIBLE_PARTITION answer is
tolerated). Checksum stage: the bootrom speaks CRC-16/XMODEM, FDL2 speaks a
folded byte sum with byte-swap on even lengths. Flash ops (FDL2): READ_FLASH
(BE addr/size/offset, 1024-byte chunks, BSL_REP_READ_FLASH payloads),
START/MIDST/END writes, ERASE_FLASH (BE addr + size). Virtual partitions are
selected by UTF-16LE name (36 u16 + LE size, high word for 64-bit mode):
READ_START/READ_MIDST (LE len/offset)/READ_END for by-name reads,
START_DATA/MIDST_DATA/END_DATA for by-name writes (15 s per-chunk timeout),
and ERASE_FLASH carrying the selection itself.
