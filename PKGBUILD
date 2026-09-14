# Maintainer: redminote11tech <redminote11tech@users.noreply.github.com>
# Ultron — Qualcomm EDL (9008) flashing tool (Zig + GTK4/libadwaita).
#
# Local build:   makepkg -sri        (from a release tarball or the repo root)
# Requirements:  zig 0.16.x in makedepends; the zig-gobject dependency is
#                fetched once in prepare() (see the note below).

pkgname=ultron
pkgver=0.5.1
pkgrel=1
pkgdesc='Qualcomm EDL (9008) flashing tool — graphical successor to qdl'
arch=(x86_64)
url='https://github.com/redminote11tech/UltronTool'
license=(GPL-3.0-or-later)
depends=(gtk4 libadwaita libusb hicolor-icon-theme systemd-libs)
makedepends=(git zig)
install=$pkgname.install
# Local build: tarball created with `git archive` from the v$pkgver tag.
# For AUR: switch to
#   source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
# and pin sha256sums.
source=("ultron-$pkgver.tar.gz")
sha256sums=('SKIP')

prepare() {
  cd "$pkgname-$pkgver"
  # Warm the zig package cache so build() does not need the network.
  # (Only needed once per machine; a populated ~/.cache/zig is reused.)
  export ZIG_GLOBAL_CACHE_DIR="$srcdir/zig-global-cache"
  zig fetch --save=gobject \
    "https://github.com/ianprime0509/zig-gobject/releases/download/v0.3.2/bindings-gnome50.tar.zst" || true
}

build() {
  cd "$pkgname-$pkgver"
  export ZIG_GLOBAL_CACHE_DIR="$srcdir/zig-global-cache"
  zig build --prefix "$pkgdir/usr" -Doptimize=ReleaseSafe
}

package() {
  # zig build --prefix already staged bin/ share/ lib/udev into $pkgdir.
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
