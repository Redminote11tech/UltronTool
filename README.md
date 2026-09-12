# Ultron

<p align="center">
  <img src="data/icons/hicolor/scalable/apps/io.github.redminote11tech.Ultron.svg" width="96" alt="Ultron icon"/>
</p>

A beautiful, native Linux GUI flashing/unbricking tool for Qualcomm EDL (9008)
devices — the graphical successor to [`qdl`](https://github.com/linux-msm/qdl),
written in Zig with GTK4/libadwaita.

> **Status: v0.1.0** — Qualcomm EDL is fully working (full qdl parity). The
> architecture is plugin-based: **MediaTek (BROM/mtkclient-style)** and
> **Samsung (Odin/Heimdall-style)** protocol modules are planned on top of the
> same protocol registry.

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
- Storage types: UFS, eMMC, Spinor, NAND, NVMe

## Requirements

- Linux with libusb 1.0, GTK4 + libadwaita, libudev
- USB access to the device in EDL mode — udev rules ship with the package
  (`/usr/lib/udev/rules.d/70-ultron.rules`, installed by the PKGBUILD). On
  other distros copy it manually, then:
  `sudo udevadm control --reload && sudo udevadm trigger`
- Your device's own signed **programmer** (firehose) file and flash-layout XML
  files — these are vendor-specific and **not included**

## Building

Requires **Zig 0.16.x** (the GUI uses zig-gobject v0.3.2, GNOME 50 bindings).

```
zig build --release=fast
zig build test      # unit tests (Sahara/Firehose/XML over a simulated device)
```

## Packaging (Arch / CachyOS)

Two equivalent ways to build the installable package:

```
# with makepkg (creates pkg/ staging, then installs):
makepkg -sri

# or with the standalone script (no pkg/ staging needed):
./tools/make-package.sh
sudo pacman -U ultron-0.1.0-1-x86_64.pkg.tar.zst
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
│   └── qualcomm/  sahara · firehose · xml · rawprogram · session
└── ui/         libadwaita app (device / flash / console pages)
```

Protocol logic is ported line-by-line from the reference implementations;
see [docs/PROTOCOL.md](docs/PROTOCOL.md) for the full spec and sources.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). Protocol logic is ported from
linux-msm/qdl (BSD-3-Clause) and cross-checked against bkerler/edl and
strongtz/edl-ng.
