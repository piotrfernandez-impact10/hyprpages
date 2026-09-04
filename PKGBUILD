# Maintainer: see the repository
pkgname=hyprpages
pkgver=0.1.0
pkgrel=1
pkgdesc="Visual editor for Hyprland spaces: see what is running, arrange it, generate the config"
arch=('any')
url="https://github.com/OWNER/hyprpages"
license=('MIT')
depends=('python' 'hyprland')
optdepends=(
  'kitty: per-window detail for kitty terminals'
  'gtk4: launching applications by desktop entry'
)
makedepends=('python-build' 'python-installer' 'python-setuptools' 'python-wheel')
source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
  cd "$pkgname-$pkgver"
  python -m build --wheel --no-isolation
}

package() {
  cd "$pkgname-$pkgver"
  python -m installer --destdir="$pkgdir" dist/*.whl
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"

  # The Quickshell editor plugin, for Omarchy-based setups.
  install -d "$pkgdir/usr/share/$pkgname/plugin"
  cp -r plugin/kvark.hyprpages "$pkgdir/usr/share/$pkgname/plugin/"
}
