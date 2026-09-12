# Ultron

A beautiful, native Linux GUI flashing/unbricking tool for Qualcomm EDL (9008) devices —
the graphical successor to [`qdl`](https://github.com/linux-msm/qdl), written in Zig with
GTK4/libadwaita.

> Status: early development. Protocol modules are plugin-based: Qualcomm EDL (Sahara +
> Firehose) first, with MediaTek (BROM) and Samsung (Odin) modules planned.

## Features (v1, Qualcomm EDL)

- Automatic detection of EDL-mode devices (Qualcomm VID `05c6`, incl. `9008` / `900e`)
- Firehose programmer upload over Sahara (`.mbn` / `.elf`)
- Flashing via qdl-compatible `rawprogram*.xml` + `patch*.xml`
- Partition erase, storage info, device reset
- Live console with full protocol logs, progress, and cancel

## Requirements

- Linux with libusb 1.0 and GTK4 + libadwaita
- USB access to the device in EDL mode — udev rules are shipped as
  `data/70-ultron.rules` (install to `/usr/lib/udev/rules.d/`, then
  `sudo udevadm control --reload && sudo udevadm trigger`)
- Your device's own signed **programmer** (firehose) file and flashing XMLs —
  these are vendor-specific and not included

## Building

```
zig build --release=fast
```

## Packaging (Arch/CachyOS)

```
makepkg -sri
```

See `PKGBUILD`.

## License

GPL-3.0 — see [LICENSE](LICENSE). Protocol logic is ported from linux-msm/qdl (BSD-3-Clause)
and cross-checked against bkerler/edl and strongtz/edl-ng; see `docs/PROTOCOL.md`.
