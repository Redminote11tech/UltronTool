#!/usr/bin/env bash
# Build the UltronTool-BETA package for Arch/CachyOS from the TS UI experiment.
#
# Contents: the self-contained Tauri release binary (embeds ui-ts/dist) as
# /usr/bin/ultrontool-beta, plus desktop entry, hicolor icons and license.
# Simulated device bus — this package cannot touch hardware.
#
# Hand-rolled like the stable ultron package (makepkg's pkg/ handling is
# unreliable in this environment): plain staging + .PKGINFO/.INSTALL/.MTREE
# + bsdtar. Verify with `pacman -Qip <artifact>` before distributing.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
ver="0.1.0"
pkgrel="1"
name="ultrontool-beta"
out="UltronTool-BETA-${ver}-${pkgrel}-x86_64.pkg.tar.zst"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

bin="${root}/src-tauri/target/release/ultron-ui"
if [[ ! -x "$bin" ]]; then
  echo "release binary missing — run first:" >&2
  echo "  cargo build --release --manifest-path ${root}/src-tauri/Cargo.toml" >&2
  exit 1
fi

install -Dm755 "$bin" "$stage/usr/bin/${name}"
install -Dm644 "${root}/LICENSE" "$stage/usr/share/licenses/${name}/LICENSE"
install -Dm644 "${root}/src-tauri/packaging/${name}.desktop" "$stage/usr/share/applications/${name}.desktop"
install -Dm644 "${root}/src-tauri/icons/icon.png" "$stage/usr/share/icons/hicolor/128x128/apps/${name}.png"
install -Dm644 "${root}/src-tauri/icons/icon512.png" "$stage/usr/share/icons/hicolor/512x512/apps/${name}.png"

size="$(du -sb "$stage" | cut -f1)"
builddate="$(date +%s)"

cat > "$stage/.PKGINFO" <<EOF
pkgname = ${name}
pkgbase = ${name}
pkgver = ${ver}-${pkgrel}
pkgdesc = Ultron Beta — TS UI experiment in a native Tauri window (simulated device bus, no hardware access)
url = https://github.com/Redminote11tech/UltronTool
builddate = ${builddate}
packager = jade <jade@localhost>
size = ${size}
arch = x86_64
license = GPL-3.0
depend = webkit2gtk-4.1
depend = gtk3
depend = hicolor-icon-theme
EOF

cat > "$stage/.INSTALL" <<'EOF'
post_install() {
  update-desktop-database -q 2>/dev/null || true
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
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
