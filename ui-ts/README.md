# Ultron — TS UI experiment (`ts-ui` branch)

A design experiment: the same Ultron flashing tool, reimagined with a
TypeScript frontend rendered in a **native desktop window** (Tauri 2 +
webkit2gtk on Linux) — not a website in a browser. The Zig flashing core on
`main` is untouched; nothing here is wired to hardware yet.

![device page](docs/device-connected.png)

## Why this exists

GTK4/libadwaita is correct for the shipped app (native, fast, dependency-free
runtime) but its animation and layout vocabulary is limited. This branch
explores what the product could feel like with a web-grade rendering stack:
springs everywhere, shared-element transitions, hold-to-confirm destructives.
If the experiment lands, the frontend stays; the backend becomes a thin IPC
bridge to the existing Zig `manager.zig` (phase 2).

## Art direction — "Precision Dark"

A control-room instrument panel, not a consumer app:

- **Surfaces** — layered near-blacks (`#07080b` → `#1f2431`), hairline
  separators at 6–12% white. Depth comes from elevation, not shadows.
- **One accent** — arc cyan `#22d3ee` owns all interaction (focus, progress,
  primary actions). Red is **reserved for destructive actions** and never used
  as decoration; amber = caution; emerald = success. Vendor identities
  (Qualcomm cyan, Samsung blue, LG red, MTK orange, Unisoc green) appear only
  in status dots and badges.
- **Type** — Inter Variable for UI, JetBrains Mono with tabular numerals for
  anything that is data (paths, sizes, rates, hex, logs).
- **Motion** — springs for anything physical (300–480 stiffness, ≤34 damping),
  tweens ≤220ms for fades. Every button presses (scale 0.965); cards lift 1px
  on hover; the nav-rail active pill glides between icons via a shared
  `layoutId`; pages cross-fade with a 4px blur; progress bars follow values on
  a soft spring with a sheen sweep. `prefers-reduced-motion` collapses all of
  it to linear.

## UX logic worth stealing for mainline

- **Hold-to-confirm** for destructive ops: enabling "Erase user data" replaces
  Start with a red button whose fill sweeps while held (~900ms). Release early
  and it drains back. Commitment is visualized instead of nagging with dialogs.
- **Slot staging** mirrors what each vendor module actually consumes (programmer
  + rawprogram/patch for Qualcomm; BL/AP/CP/CSC/PIT for Samsung; FDL1/FDL2 for
  Unisoc, with the unlanded PAC parser shown locked "SOON" instead of hidden).
- **Job telemetry** is byte-accurate: percent, bytes, throughput, ETA and the
  current protocol step in one strip, with cancel always one click away.
- **Console** separates protocol chatter (violet mono) from app events, with
  level filters, autoscroll and save.

## Status: simulated

The device bus (`src/state/bus.tsx`) is a mock that mirrors the Zig core's
event channel semantics (log / progress / state-change / job-finished). The
"Sim device" selector fabricates connections; flash scenarios replay realistic
protocol log lines. **No USB, no hardware, no flashing.**

## Run it

Frontend only (design iteration, in a browser tab):

```sh
cd ui-ts && npm install && npm run dev   # http://localhost:5173
```

Native window (Tauri 2 shell in `../src-tauri`, uses webkit2gtk-4.1):

```sh
cd src-tauri && cargo run        # debug build loads the dev server
# release, self-contained (embeds ../ui-ts/dist):
cd src-tauri && cargo build --release && ./target/release/ultron-ui
```

Requires: node ≥ 20, rust, `webkit2gtk-4.1` (all present on a stock Arch dev
setup; `libayatana-appindicator3` only if tray support is ever added).

## Map

```
ui-ts/
├── src/
│   ├── styles/tokens.css     # the entire design system lives here
│   ├── styles/app.css        # layout + component micro-detail
│   ├── state/vendors.ts      # vendor meta, per-vendor file slots, scenarios
│   ├── state/bus.tsx         # mock event bus (mirrors core/event.zig)
│   ├── components/           # rail, buttons + hold-to-confirm, switch,
│   │                         # progress, modal, toasts, brand mark
│   ├── pages/                # device / flash / console
│   └── lib/                  # motion presets, byte/rate/eta formatting
└── docs/                     # screenshots from the design pass
src-tauri/                    # native shell (Tauri 2, webkit2gtk)
```

## Phase 2 (not started)

1. IPC bridge: Zig `manager.zig` exposes a local JSON events/commands socket
   (or stdio pipe); `bus.tsx` swaps scenarios for the real channel.
2. Drag-and-drop onto slots, real file pickers through Tauri APIs.
3. Decision point: keep GTK mainline and treat this as a parallel skin, or
   promote it — that call belongs to the owner after trying both on hardware.
