#!/usr/bin/env bash
# build-appimage.sh - build a Sony Head Tracker AppImage (Linux, any distro).
#
# STATUS: starting point, needs a test run. A GTK4 + PyGObject app is the fiddly
# case for AppImage because the Python interpreter and the GObject-introspection
# bindings have to be bundled too. This script uses the standard tooling
# (linuxdeploy + its GTK plugin) and bundles Python; expect to iterate on your
# machine. If it proves fragile, the simplest cross-distro path is still
# `sudo make install` after installing gtk4/libadwaita/python-gobject (see
# ../../docs/LINUX.md). See ./README.md for details.
#
# Requires: wget, a working build toolchain, GTK4/libadwaita/python-gobject
# installed on the build host (so their libraries and typelibs can be bundled).
set -euo pipefail

ARCH="${ARCH:-x86_64}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APPDIR="$ROOT/AppDir"
TOOLS="$ROOT/.appimage-tools"
cd "$ROOT"

echo "==> Building the CLI and staging a system install into AppDir"
make
rm -rf "$APPDIR"
make install DESTDIR="$APPDIR" PREFIX=/usr

echo "==> Fetching AppImage tooling"
mkdir -p "$TOOLS"
fetch() { [ -f "$TOOLS/$1" ] || wget -q --show-progress -O "$TOOLS/$1" "$2"; chmod +x "$TOOLS/$1"; }
fetch linuxdeploy "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$ARCH.AppImage"
fetch linuxdeploy-plugin-gtk.sh "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"

echo "==> Bundling the Python interpreter and PyGObject (gi)"
# linuxdeploy's GTK plugin bundles GTK4, libadwaita, gdk-pixbuf loaders, the
# GObject-introspection typelibs, and GSettings schemas. It does NOT bundle
# Python, so copy the interpreter and the gi bindings in ourselves.
PYBIN="$(command -v python3)"
PYVER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
install -Dm755 "$PYBIN" "$APPDIR/usr/bin/python3"
# The gi package (Python side of PyGObject); the C typelibs come from the GTK plugin.
GI_DIR="$(python3 -c 'import gi, os; print(os.path.dirname(gi.__file__))')"
mkdir -p "$APPDIR/usr/lib/python$PYVER/site-packages"
cp -r "$GI_DIR" "$APPDIR/usr/lib/python$PYVER/site-packages/"

echo "==> Writing AppRun"
cat > "$APPDIR/AppRun" <<EOF
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
export PATH="\$HERE/usr/bin:\$PATH"
export LD_LIBRARY_PATH="\$HERE/usr/lib:\$HERE/usr/lib/$ARCH-linux-gnu:\$LD_LIBRARY_PATH"
export GI_TYPELIB_PATH="\$HERE/usr/lib/girepository-1.0:\$HERE/usr/lib/$ARCH-linux-gnu/girepository-1.0:\$GI_TYPELIB_PATH"
export XDG_DATA_DIRS="\$HERE/usr/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export PYTHONHOME="\$HERE/usr"
export PYTHONPATH="\$HERE/usr/lib/python$PYVER/site-packages:\$PYTHONPATH"
exec "\$HERE/usr/bin/python3" "\$HERE/usr/share/sony-head-tracker/sony_head_tracker_gui.py" "\$@"
EOF
chmod +x "$APPDIR/AppRun"

echo "==> Running linuxdeploy with the GTK plugin"
export DEPLOY_GTK_VERSION=4
export OUTPUT="Sony_Head_Tracker-$ARCH.AppImage"
"$TOOLS/linuxdeploy" --appdir "$APPDIR" \
    --plugin gtk \
    --custom-apprun "$APPDIR/AppRun" \
    --desktop-file "$APPDIR/usr/share/applications/io.github.sonyheadtracker.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/io.github.sonyheadtracker.svg" \
    --output appimage

echo "==> Done: $ROOT/$OUTPUT"
echo "    Note: the CLI needs /dev/hidraw access (the bundled udev rule is at"
echo "    AppDir/usr/lib/udev/rules.d/); install it once on the host or run the"
echo "    app's Grant device access. See docs/LINUX.md."
