<div align="center">

<img src="data/icons/io.github.redminote11tech.Ultron-source.png" width="140" alt="Ultron icon"/>

# Ultron

**Flash and unbrick Qualcomm EDL (9008) devices — natively on Linux.**

A native GTK4/libadwaita GUI, with Sahara and Firehose reimplemented in Zig.

To our knowledge this is the **first native Linux GUI tool** to reimplement the
Qualcomm **Sahara** and **Firehose** protocols in **Zig** — a graphical successor
to the classic [`qdl`](https://github.com/linux-msm/qdl) command-line tool.

GPL-3.0 · Zig 0.16 · GTK4/libadwaita · Linux (Wayland/X11)

</div>

---

> **Status: v0.2.0** — Qualcomm EDL is fully usable. The architecture is
> plugin-based: **MediaTek (BROM/mtkclient-style)** and **Samsung
> (Odin/Heimdall-style)** protocol modules are planned on top of the same
> protocol registry.

## Why Ultron?

Existing EDL tooling on Linux is a pile of Python scripts or a bare CLI.
Ultron is a **real desktop app**: it detects your device the moment you plug it
in, walks you through loader upload and flashing with confirmations on every
destructive action, shows the device's actual partition table, and logs every
byte of protocol traffic in a built-in console — while the protocol core stays
a small, dependency-free Zig library you can audit in an afternoon.

## Features

- **Live device detection** — udev hot-plug monitoring recognizes Qualcomm EDL
  (`05c6:9008`), crash-dump mode (`05c6:900e`), and any Qualcomm PID exposing
  the Sahara vendor-specific interface
- **One workflow page**: Connect → (if the device is a bare EDL target, choose
  your signed firehose programmer and upload it over Sahara — devices already
  running a programmer skip this automatically) → the live partition table
- **Partition browser** — GPT per LUN (LUN switcher on multi-LUN UFS devices),
  each partition with **Read** (stream a backup to a file) and **Write**
  (queues the image; one destructive confirmation dialog lists the whole
  batch before anything touches the device)
- **rawprogram flashing** — qdl-compatible `rawprogram*.xml` + `patch*.xml`
  with the same confirm-first flow, including sector-size probing,
  payload-size negotiation and set-bootable (`xbl`/`xbl_a`/`sbl1`)
- **Persistent session** — the Firehose connection stays open across
  operations; explicit Reset device / Disconnect; cancel aborts and
  disconnects safely
- **Chip identity probe** — serial number, HW ID (MSM/OEM/Model), OEM PK hash
  over Sahara command mode (v2 and v3 targets)
- **Live protocol console** — every XML exchange and device log line is shown
- **VIP digest tables** — for programmers that enforce Vendor Image Programming
  (per-packet SHA-256 auth against a vendor-signed digest table, as upstream
  qdl implements it); see below
- Storage types: UFS, eMMC, Spinor, NAND, NVMe

## VIP programming (digest-table auth)

Some programmers refuse every packet unless it matches the next SHA-256 digest
in a vendor-signed table ("VIP is enabled, receiving the signed table" in their
startup logs). Ultron ports upstream qdl's VIP support end to end — fully from
the GUI, no command line needed:

1. In the loader stage, under **Create VIP digest tables**, add your
   `rawprogram*.xml` / `patch*.xml` files, choose an output folder and the
   payload size, then **Generate digest tables…**. This replays the flash
   plan offline (no device interaction) and hashes every Firehose packet.
2. Have `DigestsToSign.bin` signed by your vendor / signing infrastructure,
   then save the signed image as `DigestsToSign.bin.mbn` in the same folder.
3. Still in the loader stage, choose that folder as **VIP digest tables**,
   pick the programmer, and upload as usual — Ultron streams the signed
   table and the chained tables at the right frame boundaries.

The payload size (default 16 KiB) must match the size the real programmer
ACKs without renegotiating (its `MaxPayloadSizeToTargetInBytes`) — the digest
table is bound to the exact packet sequence. While VIP is active the
partition browser is disabled (reads are not in the table); flash via
rawprogram XML. The table stays valid only for that exact plan: same XML
files, images, storage type and SkipStorageInit setting.

## Requirements

- Linux with libusb 1.0, GTK4 + libadwaita, libudev
- USB access to the device in EDL mode — udev rules ship with the package
  (`/usr/lib/udev/rules.d/70-ultron.rules`, installed by the PKGBUILD). On
  other distros copy it manually, then:
  `sudo udevadm control --reload && sudo udevadm trigger`
- Your device's own signed **programmer** (firehose) file and, for rawprogram
  flashing, its flash-layout XML files — these are vendor-specific and
  **never included**

## Building

Requires **Zig 0.16.x** (the GUI uses zig-gobject v0.3.2, GNOME 50 bindings).

```
zig build --release=fast
zig build test      # unit tests (Sahara/Firehose/GPT over a simulated device)
```

## Packaging (Arch / CachyOS)

Two equivalent ways to build the installable package:

```
# with makepkg (creates pkg/ staging, then installs):
makepkg -sri

# or with the standalone script (no pkg/ staging needed):
./tools/make-package.sh
sudo pacman -U ultron-0.2.0-1-x86_64.pkg.tar.zst
```

The package installs the binary, desktop entry, AppStream metainfo, icon and
udev rules, then reloads udev.

## Architecture

```
src/
├── core/       logging ring, event channel, libc file helpers
├── transport/  Transport vtable · libusb backend (qdl ZLP semantics) · sim backend
├── device/     libudev hot-plug scanner
├── protocol/   Protocol vtable + registry (the plugin point)
│   └── qualcomm/  sahara · firehose · vip · digestgen · gpt · xml · rawprogram · manager
└── ui/         libadwaita app (workflow page + console)
```

Protocol logic is ported line-by-line from the reference implementations;
[docs/PROTOCOL.md](docs/PROTOCOL.md) documents every constant, packet layout,
timeout and quirk with sources.

### Adding a protocol module

A protocol is one `Protocol` value in `src/protocol/protocol.zig`: a
device-USB match policy plus a classifier. The scanner, UI and manager need
zero changes — MediaTek and Samsung modules are planned exactly this way.

## Credits

- [`linux-msm/qdl`](https://github.com/linux-msm/qdl) (BSD-3-Clause) — the
  primary reference; Sahara/Firehose/USB semantics are ported from its source
- [`bkerler/edl`](https://github.com/bkerler/edl) (GPL-3.0) and
  [`strongtz/edl-ng`](https://github.com/strongtz/edl-ng) (MIT) — cross-checks
- [`ianprime0509/zig-gobject`](https://github.com/ianprime0509/zig-gobject)
  (0BSD) — GTK4/libadwaita bindings for Zig

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
