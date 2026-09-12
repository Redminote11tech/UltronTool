#!/bin/sh
# Build an installable pacman package (.pkg.tar.zst) without makepkg.
#
# Equivalent to `makepkg` but stages under $STAGE instead of pkg/, which keeps
# it usable in sandboxed build environments. The resulting package is
# installed with:
#
#     sudo pacman -U ultron-<version>-<arch>.pkg.tar.zst
#
# (Plain `makepkg -sri` from the repo root works too.)
set -eu

cd "$(dirname "$0")/.."

PKGNAME=ultron
PKGVER=0.2.0
PKGREL=5
ARCH=$(uname -m)
STAGE="${STAGE:-$(mktemp -d)}"

echo "==> Building (ReleaseFast) into $STAGE"
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$STAGE/zig-cache}" \
  zig build --prefix "$STAGE/usr" -Doptimize=ReleaseSafe

echo "==> Installing LICENSE"
install -Dm644 LICENSE "$STAGE/usr/share/licenses/$PKGNAME/LICENSE"

echo "==> Writing .PKGINFO"
SIZE=$(du -sk "$STAGE/usr" | cut -f1)
SIZE=$((SIZE * 1024))
BUILD_DATE=$(date +%s)
cat > "$STAGE/.PKGINFO" <<EOF
pkgname = $PKGNAME
pkgbase = $PKGNAME
pkgver = $PKGVER-$PKGREL
pkgdesc = Qualcomm EDL (9008) flashing tool - graphical successor to qdl
url = https://github.com/redminote11tech/UltronTool
builddate = $BUILD_DATE
packager = Ultron build script
size = $SIZE
arch = $ARCH
license = GPL-3.0-or-later
depend = gtk4
depend = libadwaita
depend = libusb
depend = hicolor-icon-theme
depend = systemd-libs
EOF

echo "==> Writing .MTREE"
(cd "$STAGE" && LC_ALL=C bsdtar --format=mtree \
  --options='!all,use-set,type,uid,gid,mode,time,size,sha256,link' \
  -czf .MTREE .PKGINFO usr)

echo "==> Compressing package"
OUT="ultron-$PKGVER-$PKGREL-$ARCH.pkg.tar.zst"
bsdtar -cf "$OLDPWD/$OUT" --zstd -C "$STAGE" \
  .PKGINFO .MTREE usr

echo "==> Built $OUT"
echo "    Install it with: sudo pacman -U $OUT"
