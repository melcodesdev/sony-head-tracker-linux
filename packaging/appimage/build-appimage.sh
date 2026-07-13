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
fetch appimagetool "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
# GTK4 has no loadable-modules dir on some distros (unlike GTK3); make the plugin
# tolerate its absence instead of aborting on a missing /usr/lib/gtk-4.0.
sed -i 's#copy_lib_tree "$gtk4_libdir" "$APPDIR/"#[ -d "$gtk4_libdir" ] \&\& copy_lib_tree "$gtk4_libdir" "$APPDIR/" || echo "no gtk-4.0 modules dir, skipping"#' \
    "$TOOLS/linuxdeploy-plugin-gtk.sh"
# So linuxdeploy finds the gtk plugin and appimagetool, and so the tools run
# without a FUSE mount (works in containers and on fuse3-only systems).
export PATH="$TOOLS:$PATH"
export APPIMAGE_EXTRACT_AND_RUN=1

echo "==> Bundling the Python interpreter, standard library, and PyGObject (gi)"
# linuxdeploy's GTK plugin bundles GTK4, libadwaita, gdk-pixbuf loaders, the
# GObject-introspection typelibs, and GSettings schemas. It does NOT bundle
# Python, so bring the interpreter, its full standard library (encodings,
# lib-dynload C extensions, ssl, ...), and the gi bindings in ourselves.
PYBIN="$(command -v python3)"
PYVER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PYSTD="$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
GI_DIR="$(python3 -c 'import gi, os; print(os.path.dirname(gi.__file__))')"
CAIRO_DIR="$(python3 -c 'import cairo, os; print(os.path.dirname(cairo.__file__))' 2>/dev/null || true)"
PYDST="$APPDIR/usr/lib/python$PYVER"
install -Dm755 "$PYBIN" "$APPDIR/usr/bin/python3"
mkdir -p "$PYDST"
# Full stdlib (encodings, lib-dynload, ssl, ...), but WITHOUT the host's
# site-packages (which would drag in every unrelated system Python package), the
# test suite, or bytecode caches.
cp -a "$PYSTD/." "$PYDST/"
rm -rf "$PYDST/site-packages" "$PYDST/test"
find "$PYDST" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
# Only the two Python packages the GUI needs: gi (PyGObject) and cairo (pycairo,
# which PyGObject's drawing goes through). The C typelibs come from the GTK plugin.
mkdir -p "$PYDST/site-packages"
cp -a "$GI_DIR" "$PYDST/site-packages/"
[ -n "$CAIRO_DIR" ] && cp -a "$CAIRO_DIR" "$PYDST/site-packages/"

echo "==> Bundling the Adwaita icon theme (symbolic icons the UI uses)"
# Without this the menu / arrow / checkmark symbolic icons render broken.
mkdir -p "$APPDIR/usr/share/icons"
for theme in Adwaita hicolor; do
    [ -d "/usr/share/icons/$theme" ] && cp -a "/usr/share/icons/$theme" "$APPDIR/usr/share/icons/"
done
# The SVG pixbuf loader (librsvg) so SVG icons actually rasterise.
GDK_LOADERS="$(pkg-config --variable=gdk_pixbuf_moduledir gdk-pixbuf-2.0 2>/dev/null || true)"
if [ -n "$GDK_LOADERS" ] && [ -d "$GDK_LOADERS" ]; then
    dest="$APPDIR/usr/lib/$(basename "$(dirname "$GDK_LOADERS")")/$(basename "$GDK_LOADERS")"
    mkdir -p "$dest"; cp -a "$GDK_LOADERS"/*svg* "$dest/" 2>/dev/null || true
fi

echo "==> Writing AppRun"
# Must live OUTSIDE the AppDir: linuxdeploy copies --custom-apprun into AppDir/AppRun.
APPRUN="$ROOT/AppRun.custom"
cat > "$APPRUN" <<EOF
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
export APPDIR="\$HERE"
# Source the linuxdeploy GTK hooks (GTK theme, GI_TYPELIB_PATH, GDK_PIXBUF loaders,
# GSettings schemas) before launching; they key off \$APPDIR.
for hook in "\$HERE"/apprun-hooks/*.sh; do [ -r "\$hook" ] && . "\$hook"; done
# libadwaita styles its own widgets; the GTK plugin forces GTK_THEME, which breaks
# that (and warns). Clear it so the app looks native, and let libadwaita follow the
# desktop's light/dark preference.
unset GTK_THEME GTK_THEME_VARIANT
export PATH="\$HERE/usr/bin:\$PATH"
export LD_LIBRARY_PATH="\$HERE/usr/lib:\$LD_LIBRARY_PATH"
export XDG_DATA_DIRS="\$HERE/usr/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export PYTHONHOME="\$HERE/usr"
export PYTHONPATH="\$HERE/usr/lib/python$PYVER:\$HERE/usr/lib/python$PYVER/site-packages"
export PYTHONDONTWRITEBYTECODE=1
exec "\$HERE/usr/bin/python3" "\$HERE/usr/share/sony-head-tracker/sony_head_tracker_gui.py" "\$@"
EOF
chmod +x "$APPRUN"

echo "==> Running linuxdeploy with the GTK plugin"
export DEPLOY_GTK_VERSION=4
export OUTPUT="Sony_Head_Tracker-$ARCH.AppImage"
"$TOOLS/linuxdeploy" --appdir "$APPDIR" \
    --plugin gtk \
    --custom-apprun "$APPRUN" \
    --desktop-file "$APPDIR/usr/share/applications/io.github.sonyheadtracker.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/io.github.sonyheadtracker.svg" \
    --output appimage

echo "==> Done: $ROOT/$OUTPUT"
echo "    Note: the CLI needs /dev/hidraw access (the bundled udev rule is at"
echo "    AppDir/usr/lib/udev/rules.d/); install it once on the host or run the"
echo "    app's Grant device access. See docs/LINUX.md."
