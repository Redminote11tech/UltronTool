# Material 3 UI consolidation

Material 3 is the primary UI direction, approved on 2026-10-09. Precision Dark
is retired from active development. Historical branches remain recoverable.
GTK stays available during migration so supported operations remain accessible.

The TypeScript frontend runs in a native Tauri/WebKitGTK window. Browser preview
is a separate simulation environment. Protocol implementations remain in Zig;
new frontend capabilities use the internal daemon and never add public CLI
commands or duplicate protocol logic in TypeScript/Rust.

## Migration checklist

- [x] Clean Material 3 layout, light/dark palettes and accessible controls.
- [x] Qualcomm device detection, connect, programmer upload, XML/VIP flash,
  logs, progress, cancellation, reset and disconnect.
- [x] Explicit device targeting, request identity, backend-owned removal handling,
  immutable flash review and cooperative shutdown.
- [x] Self-contained frontend and daemon package with truthful launcher metadata.
- [x] Qualcomm partition browsing across LUNs and backups.
- [x] Standalone loader connection and read-only XML operation review.
- [ ] Qualcomm verified partition writes and erase.
- [ ] UFS provisioning, with separate validation/commit and explicit OTP-lock gate.
- [ ] Huawei UPDATE.APP inspection and flashing.
- [ ] Sahara crash-dump region selection and export.
- [ ] Samsung PIT browsing, image/partition operations, tar.md5 bundles,
  reboot controls and factory reset.
- [ ] MediaTek BROM identification, DA upload and legacy DA read/write/format.
- [ ] Unisoc FDL upload and raw-address/partition operations.
- [ ] LG GPT browsing, backup, write, erase and reboot/power-off.

Vendor migration follows Samsung → MediaTek → Unisoc → LG. Extract existing
one-shot orchestration from the GTK layer into vendor-specific backend modules
before exposing it to the daemon. Preserve transport/session lifetime, USB
quirks, cancellation and exactly one job completion. GTK and the daemon should
call the same backend jobs during transition. Port wire behavior from existing
protocol modules and their reference-backed tests, not from a new implementation.

Every destructive UI operation reviews the immutable device, operation and
inputs. Pickers and confirmations must reject stale targets. Existing VIP,
sparse-input and verification restrictions remain visible and enforced.
Each capability lands as an atomic commit with appropriate backend/IPC/frontend
regressions and successful Zig tests.

## GTK retirement gates

GTK is removed only when all currently supported operations are accessible in
Material 3, the native package works without a development server, keyboard and
picker/dialog behavior is verified, and device operations are validated on real
hardware. Sim tests establish protocol regression coverage; they do not establish
hardware support. Known vendor hardware-validation gaps remain documented even
when their UI port is complete.

After validation, remove GTK entry points, bindings and package assets while
keeping the shared Zig backend and historical Git commits. Do not remove GTK
first and leave unsupported vendors with no usable interface.
