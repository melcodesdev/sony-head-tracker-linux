# AppImage build

A single-file, distro-agnostic build of the desktop app. Unlike Flatpak it is
**not sandboxed**, so the app's host integration (Steam/Proton game setup, the
KDE/GNOME global recenter shortcut, launching OpenTrack) keeps working.

## Status

Starting point, needs a test run. A **GTK4 + PyGObject** app is the hard case for
AppImage: `linuxdeploy-plugin-gtk` bundles GTK4, libadwaita, the gdk-pixbuf
loaders, the GObject-introspection typelibs, and GSettings schemas, but **not the
Python interpreter**, which `build-appimage.sh` bundles separately. Python + `gi`
bundling is fragile, so expect to iterate.

## Build

```bash
packaging/appimage/build-appimage.sh
```

It downloads `linuxdeploy` + the GTK plugin, stages a system install into
`AppDir/` via `make install`, bundles Python and `gi`, writes an `AppRun`, and
produces `Sony_Head_Tracker-x86_64.AppImage`.

Requirements on the build host: `wget`, a C++20 toolchain, and gtk4 / libadwaita /
python-gobject installed (so their libraries and typelibs can be bundled).

## If the AppImage proves too fragile

The most reliable cross-distro path is a normal system install:

```bash
sudo pacman -S gtk4 libadwaita python-gobject   # or the apt/dnf equivalents
make && sudo make install PREFIX=/usr
```

On Arch/CachyOS, use the [AUR package](../aur/) instead: `makepkg -si`. See
[docs/LINUX.md](../../docs/LINUX.md) for the per-distro package names.
