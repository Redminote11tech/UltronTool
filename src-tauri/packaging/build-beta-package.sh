#!/usr/bin/env bash
# Build the UltronTool-BETA package for Arch/CachyOS for the native Material 3 frontend.
#
# Contents: the self-contained Tauri release binary (embeds ui-ts/dist) as
# /usr/bin/ultrontool-beta, the Zig IPC daemon (ultrontool-beta-daemon) it
# spawns, udev rules for download-mode devices, desktop entry, icons, license.
#
# Hand-rolled like the stable ultron package (makepkg's pkg/ handling is
# unreliable in this environment): plain staging + .PKGINFO/.INSTALL/.MTREE
# + bsdtar. Verify with `pacman -Qip <artifact>` before distributing.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
ver="0.3.0"
pkgrel="10"
name="ultrontool-beta"
out="UltronTool-BETA-${ver}-${pkgrel}-x86_64.pkg.tar.zst"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# Rebuild every shipped component from this checkout. Never package a stale
# devUrl shell or silently omit the backend.
npm --prefix "${root}/ui-ts" run build
(cd "$root" && zig build -Doptimize=ReleaseSafe)
cargo build --offline --release --features custom-protocol --manifest-path "${root}/src-tauri/Cargo.toml"
bin="${root}/src-tauri/target/release/ultron-ui"
[[ -x "$bin" ]] || { echo "release GUI missing" >&2; exit 1; }

install -Dm755 "$bin" "$stage/usr/bin/${name}"

# The Zig IPC daemon rides along as a sibling of the GUI binary — the shell
# resolves it via exe_dir at startup. udev rules grant device access.
daemon="${root}/zig-out/bin/ultron-daemon"
[[ -x "$daemon" ]] || { echo "release daemon missing" >&2; exit 1; }
install -Dm755 "$daemon" "$stage/usr/bin/${name}-daemon"
# udev rules under the beta's own filename: the stable `ultron` package owns
# 70-ultron.rules, and pacman refuses two packages owning one file. Both
# files carry identical directives — udev applies them idempotently.
install -Dm644 "${root}/data/70-ultron.rules" "$stage/usr/lib/udev/rules.d/70-ultrontool-beta.rules"

install -Dm644 "${root}/LICENSE" "$stage/usr/share/licenses/${name}/LICENSE"
install -Dm644 "${root}/src-tauri/packaging/${name}.desktop" "$stage/usr/share/applications/${name}.desktop"
install -Dm644 "${root}/src-tauri/icons/icon.png" "$stage/usr/share/icons/hicolor/128x128/apps/${name}.png"
install -Dm644 "${root}/src-tauri/icons/icon512.png" "$stage/usr/share/icons/hicolor/512x512/apps/${name}.png"
install -Dm644 "${root}/src-tauri/icons/icon.svg" "$stage/usr/share/icons/hicolor/scalable/apps/${name}.svg"

size="$(du -sb "$stage" | cut -f1)"
builddate="$(date +%s)"

cat > "$stage/.PKGINFO" <<EOF
pkgname = ${name}
pkgbase = ${name}
pkgver = ${ver}-${pkgrel}
pkgdesc = Ultron Beta — Material 3 UI in a native Tauri window, wired to the real Zig flashing core (Qualcomm EDL; hardware required)
url = https://github.com/Redminote11tech/UltronTool
builddate = ${builddate}
packager = jade <jade@localhost>
size = ${size}
arch = x86_64
license = GPL-3.0
depend = webkit2gtk-4.1
depend = gtk3
depend = hicolor-icon-theme
depend = libusb
depend = systemd-libs
EOF

cat > "$stage/.INSTALL" <<'EOF'
post_install() {
  update-desktop-database -q 2>/dev/null || true
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
  if [ -d /usr/lib/udev/rules.d ]; then
    udevadm control --reload 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
  fi
}
post_upgrade() {
  post_install
}
pre_remove() {
  post_install
}
EOF

(cd "$stage" && bsdtar -cf - --format=mtree --options='sha256' usr .PKGINFO .INSTALL | gzip > .MTREE)
(cd "$stage" && bsdtar --zstd -cf "${root}/${out}" .PKGINFO .MTREE .INSTALL usr)

echo "built: ${root}/${out}"
pacman -Qip "${root}/${out}"

echo "Install: sudo pacman -U ${root}/${out}"
