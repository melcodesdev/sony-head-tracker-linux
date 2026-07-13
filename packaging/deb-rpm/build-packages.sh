#!/usr/bin/env bash
# build-packages.sh - build native .deb and .rpm packages from `make install`.
#
# Produces downloadable packages for apt/dnf-based distros:
#   sudo apt install ./sony-head-tracker_*.deb
#   sudo dnf install ./sony-head-tracker-*.rpm
# Attach them to a GitHub release. For proper "install by name from a repo"
# (apt/dnf update integration) use a hosted build service (Fedora COPR, openSUSE
# OBS); see packaging/deb-rpm/README.md.
#
# Requires fpm (https://fpm.readthedocs.io): `gem install --user-install fpm`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-2.2.0}"
ARCH_DEB="${ARCH_DEB:-amd64}"
ARCH_RPM="${ARCH_RPM:-x86_64}"

command -v fpm >/dev/null 2>&1 || { echo "error: fpm not found. Install it: gem install --user-install fpm" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Building and staging a system install"
make
make install DESTDIR="$STAGE" PREFIX=/usr

common=(
    -s dir -C "$STAGE" --force
    --name sony-head-tracker
    --version "$VERSION"
    --license MIT
    --maintainer "melcodesdev"
    --url "https://github.com/melcodesdev/sony-head-tracker-linux"
    --description "Use Sony headphones as a head tracker for OpenTrack (CLI + GTK app)"
    --after-install "$ROOT/packaging/deb-rpm/postinst.sh"
    --after-upgrade "$ROOT/packaging/deb-rpm/postinst.sh"
)

echo "==> Building .deb (Debian/Ubuntu/Mint)"
fpm "${common[@]}" -t deb -a "$ARCH_DEB" \
    --depends libgtk-4-1 --depends libadwaita-1-0 --depends python3 \
    --depends python3-gi --depends gir1.2-gtk-4.0 --depends gir1.2-adw-1 \
    --deb-recommends opentrack \
    --package "sony-head-tracker_${VERSION}_${ARCH_DEB}.deb" \
    usr

echo "==> Building .rpm (Fedora/RHEL/openSUSE)"
fpm "${common[@]}" -t rpm -a "$ARCH_RPM" \
    --depends gtk4 --depends libadwaita --depends python3 --depends python3-gobject \
    --package "sony-head-tracker-${VERSION}-1.${ARCH_RPM}.rpm" \
    usr

echo "==> Done:"
ls -1 sony-head-tracker*.deb sony-head-tracker*.rpm 2>/dev/null | sed 's/^/  /'
