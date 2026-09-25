# Ultron — TS UI experiment (`ts-ui` branch)

A UI experiment for the same Ultron flashing tool: a TypeScript frontend
rendered in a **native desktop window** (Tauri 2 + webkit2gtk on Linux) —
not a website in a browser. The proven Zig GTK app on `main` is untouched;
this branch additively adds a headless IPC daemon (`src/ipc/`) and, since
**0.3.0, the TS UI is wired to the real flashing core** for Qualcomm EDL
(see Status below).

![device page](docs/device-connected.png)
*Browser preview of the device page. In the native window the same page
lists real detected devices (daemon mode) instead of this simulated card.*

> **Design history:** the first skin, "Precision Dark" (custom near-black
> surfaces, springs everywhere, glow accents), is preserved on branch
> `ts-ui-precision-dark` and ships in the `UltronTool-BETA-0.1.0` artifact.
> The current skin is **Material 3** (below).

## Why this exists

GTK4/libadwaita is correct for the shipped app (native, fast, dependency-free
runtime) but its animation and layout vocabulary is limited. This branch
explores what the product could feel like with a web-grade rendering stack:
state layers, shared-element transitions, hold-to-confirm destructives.
The backend question turned out to have a small answer: a headless Zig
daemon (`ultron-daemon`, line-JSON over stdio, spawned by the shell) exposes
the existing scanner + manager — no protocol logic moved, no second
implementation, the GTK app keeps working unchanged.

## Art direction — Material 3

Authentic M3, not M3-flavored: the color roles are **generated** from seed
`#22d3ee` with Google's `@material/material-color-utilities` (HCT tonal
palettes) and checked in as static CSS — dark scheme by default, light scheme
flips on `prefers-color-scheme`. Components follow the spec:

- **Shape** — pill buttons (full radius), 12dp cards, 28dp dialogs, 4dp chips.
- **State layers** — interaction is answered with the spec's 8% hover / 12%
  press current-color overlays instead of scale-and-glow. Calm by design.
- **Type** — Roboto on the M3 type scale (24dp regular headlines, 14/500
  labels); JetBrains Mono survives only for data (console, hex, sizes).
- **Motion** — M3 easing curves, no springs: fade-through page transitions
  (90ms out, 210ms in + 92→100 scale), morphing rail indicator, snackbar
  slide. Everything answers in ≤350ms.
- **Components** — M3 navigation rail (icon-in-pill + labels), filled/tonal/
  outlined/text/error buttons, M3 switches, linear progress with stop-dot,
  snackbars on inverse-surface, segmented buttons, filter chips with
  checkmarks.

Kept from the first skin because the logic is sound (owner-approved):
hold-to-confirm destructives, byte-accurate job telemetry, slot staging that
mirrors each vendor module's real inputs, and protocol/app log separation.

## UX logic worth stealing for mainline

- **Hold-to-confirm** for destructive ops: enabling "Erase user data" replaces
  Start with a red button whose fill sweeps while held (~900ms). Release early
  and it drains back. Commitment is visualized instead of nagging with dialogs.
- **Slot staging** mirrors what each vendor module actually consumes (programmer
  + rawprogram/patch for Qualcomm; BL/AP/CP/CSC/PIT for Samsung; FDL1/FDL2 for
  Unisoc, with the unlanded PAC parser shown locked "SOON" instead of hidden).
  The sim mode renders every vendor's layout for design review; the
  daemon-wired flow is currently Qualcomm's.
- **Job telemetry** is byte-accurate: percent, bytes, throughput, ETA and the
  current protocol step in one strip, with cancel always one click away.
- **Console** separates protocol chatter (violet mono) from app events, with
  level filters, autoscroll and save.

## Status: real (Qualcomm EDL vertical slice)

Since 0.3.0 the app talks to the **actual Zig flashing core**: a headless
`ultron-daemon` (src/ipc/, spawned by the Tauri shell, line-JSON over stdio —
see `src/ipc/codec.zig` for the wire contract) owns the udev device scanner
and the persistent Firehose session manager. The UI shows real hotplug
detection, connects, uploads the programmer over Sahara, flashes rawprogram/
patch XML with digest verification, streams real protocol logs and progress,
and resets/disconnects. Native file pickers stage real paths.

Scope notes:
- **Qualcomm EDL is wired end-to-end.** Other vendors' flows still live in
  the GTK app's UI layer; their cards honestly say "TS flow pending".
- In a plain browser (`npm run dev`) the daemon isn't reachable and the bus
  falls back to the simulated scenarios — that's the design-review mode.
- Partition ops, UFS provisioning and the Huawei UPDATE.APP path are exposed
  by the daemon protocol but not yet surfaced in this UI.

## Run it

Frontend only (design iteration, in a browser tab — runs the simulated bus):

```sh
cd ui-ts && npm install && npm run dev   # http://localhost:5173
```

Native window with the real core (Tauri 2 shell in `../src-tauri`):

```sh
zig build                 # repo root — also produces zig-out/bin/ultron-daemon
cd src-tauri && cargo run # debug shell loads the dev server, spawns the daemon
# release, self-contained (embeds ../ui-ts/dist):
cd src-tauri && cargo build --release && ./target/release/ultron-ui
```

The shell resolves the daemon from `ULTRON_DAEMON_PATH`, the executable
directory, or a `zig-out/` tree above it. The packaged version ships it as
`ultrontool-beta-daemon` next to the GUI binary plus the udev rules.

Requires: node ≥ 20, rust, zig 0.16, `webkit2gtk-4.1` (all present on a
stock Arch dev setup; `libayatana-appindicator3` only if tray support is
ever added).

## Map

```
src/                          # Zig core (branch additions only)
├── ipc/codec.zig             # the wire contract: events/requests + tests
├── ipc/daemon.zig            # scanner + manager behind stdio (no CLI, refuses argv)
└── daemon_main.zig           # ultron-daemon executable entry
ui-ts/src/
├── styles/                   # tokens.css (generated M3 palette) + app.css
├── state/                    # bus.tsx (reducer, both transports) · daemon.ts
│                             #   (wire mirror) · vendors.ts (meta, slots, sim scenarios)
├── lib/                      # tauri.ts (ipc + file pickers) · motion.ts · format.ts
├── components/               # rail, buttons + hold-to-confirm, switch, progress,
│                             # dialog, snackbars, brand mark
└── pages/                    # device / flash / console
src-tauri/                    # Tauri 2 shell: daemon spawn + relay, capabilities,
└── packaging/                #   build-beta-package.sh (Arch/CachyOS artifact)
```

## Troubleshooting: blank/garbled window on NVIDIA + Wayland

WebKitGTK's DMABUF renderer has a known failure class on proprietary NVIDIA
drivers (blank/corrupted windows, `WebKitWebProcess` SIGSEGVs inside
`libEGL_nvidia` — see the [Tauri Linux graphics notes](https://v2.tauri.app/develop/debug/linux-graphics/)
and [WebKit bug 261874](https://bugs.webkit.org/show_bug.cgi?id=261874)).
The shell therefore defaults to `WEBKIT_DISABLE_DMABUF_RENDERER=1` at
startup (escape hatches: set that variable yourself, or
`ULTRON_WEBKIT_COMPAT=off` to disable all defaults).

Diagnosed 2026-09-25 on CachyOS + NVIDIA 615.71.09 (GTX 1660 SUPER) + a
Hyprland-family Wayland compositor: the frontend renders perfectly in a
plain browser, in stock `MiniBrowser`, and in a bare Tauri builder — but
shows garbage inside the Tauri shell, and none of the documented fallbacks
(`WEBKIT_DISABLE_DMABUF_RENDERER`, `WEBKIT_DISABLE_COMPOSITING_MODE`,
`WEBKIT_DMABUF_RENDERER_FORCE_SHM`, `WEBKIT_SKIA_ENABLE_CPU_RENDERING`,
sandbox off, Mesa EGL vendor, `GDK_BACKEND=x11`, `GSK_RENDERER=cairo`)
change it. Wayland-protocol capture shows the app stalls committing frames
~1.3 s after start while the WebProcess stays alive. This is upstream
territory (wry / WebKitGTK / compositor); the GTK app is unaffected.

## What's next (not started)

1. Port the vendor one-shot flows (Samsung tar.md5, LG, MTK, Unisoc) from the
   GTK UI layer into daemon jobs, then light up their pages here.
2. Surface partition ops, UFS provisioning and the Huawei UPDATE.APP path
   (the daemon protocol already carries them).
3. Drag-and-drop onto slots.
4. Decision point: promote the TS UI or keep it as a parallel skin — the
   owner's call after trying both on hardware.
