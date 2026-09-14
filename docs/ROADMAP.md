# Ultron roadmap — protocol modules

Priority order is owner-set: **1) Samsung (Odin) → 2) MediaTek → 3) Unisoc (FDL) → 4) LG (LAF)**.
Every module follows the same landing rules (see "Landing a module"): GUI only, logic
ported from the listed references, one atomic commit per step, sim-harness tests before
hardware.

## Landing a module (same checklist every time)

1. `src/protocol/<name>/` behind the `Protocol` vtable, registered in `protocol.zig`.
   Nothing outside `protocol/qualcomm/` may change to accommodate a new vendor.
2. USB match rules go in `usb_ids.zig` policy entries — detection table in `docs/PROTOCOL.md` §7.
3. Transport work reuses `transport/usb.zig`; vendor quirks (ZLP, timeouts, reset) live in
   the protocol module, not the backend.
4. A scripted sim harness proves the flow end-to-end before any hardware attempt.
5. `docs/PROTOCOL.md` gains a section for the wire protocol + a support-matrix row.
6. Hardware validation is done by jade; commits land even when hardware validation is pending
   (state it in the commit message).

---

## 1. Samsung — Odin / Thor protocol (phases 1–3 landed)

**Status:** protocol module, USB policy and GUI shipped (`src/protocol/samsung/`,
`docs/PROTOCOL.md` §10); **hardware validation pending**. Remaining phases: 4
(repartition with PIT, PIT flashing) and 5 (tar.md5 firmware bundles), plus the
v2+ compressed-download path.

**References (working, in trust order):**
- `Samsung-Loki/Thor` — from-scratch C#/.NET implementation of the Thor/Odin USB protocol,
  active and device-tested. Primary porting reference.
- `Llucs/odin4` — modern open-source Linux flasher speaking the same Thor USB protocol.
  Cross-check for packet/session details.
- `Adrilaw/OdinV4` — mirror of Samsung's official Odin v4.1.2.1 (Java, Linux terminal) —
  ground truth for behavior Thor documents ambiguously.
- **Heimdall: documentation only. Do NOT port from it.** Its protocol write-up is useful;
  its implementation history is exactly the "burned" path the owner wants avoided.

**Scope, phased:**
1. Session/handshake: bulk endpoints, Odin handshake, device info exchange.
2. PIT: receive + parse PIT, render as the partition list (reuses the existing
   partition-table UI shape from the Firehose GPT view).
3. Flash: file→partition writes (BL/AP/CP/CSC single files first), progress + verify.
4. Ops: erase / nand-erase, repartition with PIT, reboot-to-download.
5. UI: firmware bundle picker (tar.md5), per-file rows, odin-mode status chip.

## 2. MediaTek — BROM / Download Agent

**Status:** planned · Detection IDs already in the table (`0e8d:0003/2000/2001`).

**References:**
- `bkerler/mtkclient` — the only complete open-source reference (active). Port BROM sync,
  HW identification, preloader/DA stages, auth (SLA/DAA) handling, and the V6 protocol for
  patched-bootrom chipsets (loader-file dependent).

**Scope, phased:**
1. BROM sync (`0xE0` start handshake, echo check), HW config read.
2. Auth phase: SLA/DAA challenge handling where keys are user-supplied; exploit paths only
   as separate opt-in features (they are device-specific).
3. DA upload (preloader + DA1/DA2), memory/session setup.
4. Partition ops over the DA: read/write/erase, format, RPMB as stretch.
5. UI mirrors the EDL flow (loader stage for preloader+DA files, partition browser).

## 3. Unisoc — FDL1/FDL2 (Factory Download)

**Status:** planned · Detection IDs to be confirmed from references during implementation
(bootrom/BSL vs FDL1 vs FDL2 present different VID:PID pairs).

**References:**
- `ilyakurdyukov/spreadtrum_flash` (`spd_dump`) — original Linux FDL tool (archived but
  complete): FDL1→FDL2 chain, partition read/write/erase, repartition.
- `TomKing062/spreadtrum_flash` — the actively maintained fork; use for deltas and
  currently-shipping devices.
- `kagaimiq/sprdproto` — BootROM/FDL1 upload protocol in isolation (clean to port first).
- ersa.dev "Unisoc BSL protocol, FDL1 and FDL2" deep-dive — protocol narrative for
  orientation; code above is the porting source.

**Scope, phased:** BSL/BootROM session → FDL1 upload (SRAM) → FDL2 upload (DRAM/flash) →
partition ops → PAC parsing as a separate later feature (Huawei-style container work informs it).

## 4. LG — LAF (Download Mode)

**Status:** planned, lowest priority (applies to LG devices only; community tooling is dated).

**References:**
- `Lekensteyn/lglaf` (LGLAF.py, MIT) — the LAF protocol: 32-byte header (command, args,
  length, CRC, signature), commands EXEC / OPEN / CLOSE / READ / WRITE / CTRL(RSET) /
  POWR; ships `protocol.md` and a Wireshark dissector. `partitions.py` demonstrates the
  open/read/write/close partition flow we would expose in the UI.

**Scope, phased:** session + CRC/signature handling → partition open/read/write/close →
reboot/power control → shell-exec feature only as an explicit opt-in (security surface).

---

Sequencing note: Samsung and MTK come first because they cover the largest number of
bricked-device rescues and both have actively-tested references. Unisoc follows (reference
exists, smaller audience), LG last (oldest device population). Re-evaluate whenever hardware
land in jade's hands dictates otherwise — hardware availability outranks this order.
