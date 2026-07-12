# Sony Head Tracker - desktop GUI

A GTK4 / libadwaita front end for people who would rather click than type. It
drives the `sony-head-tracker` CLI and shows a live attitude indicator plus
yaw/pitch/roll, with a Start/Stop button, **Recenter view**, a guided **Calibrate
axes** wizard, a **Set up a game** helper (Steam/Proton or native), a one-click
"Grant device access" (installs the udev rule via `pkexec`), and a settings dialog
(invert per axis, smoothing, port, and a desktop-aware global recenter shortcut).

It runs the CLI as a subprocess and reads the JSON telemetry it emits on UDP, so
it stays fully decoupled from the C++ build.

## Features

- **Calibrate axes wizard.** Instead of guessing axis maps, click **Calibrate
  axes**, move your head as prompted (look right, look up, tilt), and it learns the
  correct yaw/pitch/roll mapping and applies it live over a loopback control socket.
  No restart, no manual axis fiddling.
- **Recenter view.** Makes wherever you are looking the new forward. Available as a
  button, and as a global shortcut you can press from inside a game (see below).
- **Global recenter shortcut.** In **Settings > Recenter shortcut**, the app detects
  your desktop and binds a key (default `F9`, click to capture any key). It sets this
  up automatically on KDE, GNOME, and XFCE; edits the config live on Hyprland and
  Sway; and shows a command to bind by hand elsewhere. The underlying command is
  `scripts/recenter.sh`, so anything (a Stream Deck, a macro) can recenter too.
- **Set up a game.** Wires OpenTrack for a Steam/Proton title (pick it from a list)
  or points you at a native game, so head tracking works per game. Titles known to
  work with TrackIR/OpenTrack are marked with a check; the list is best-effort, so
  unmarked games may still work and not every game supports head tracking at all.
- **Start tracking on launch.** An optional **Settings** toggle (off by default) that
  starts tracking automatically once the headset is ready, so you do not have to
  press Start every time.
- **Live settings.** Invert per axis, smoothing, and the recenter all apply while
  tracking, without stopping the stream.

## Requirements

- The built CLI (`make` in the repo root, produces `build/sony-head-tracker`).
- Python 3, PyGObject, GTK 4, and libadwaita 1.4+.

Install the runtime on common distros:

| Distro | Command |
| ------ | ------- |
| Arch / CachyOS | `sudo pacman -S python-gobject gtk4 libadwaita` |
| Debian / Ubuntu | `sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1` |
| Fedora | `sudo dnf install python3-gobject gtk4 libadwaita` |

## Run

From the repo root:

```sh
make gui            # runs the GUI against ./build/sony-head-tracker
```

or directly: `python3 gui/sony_head_tracker_gui.py`.

## Install as a desktop app

```sh
make install-gui    # installs a launcher, .desktop entry, and icon into ~/.local
```

This adds **Sony Head Tracker** to your application menu. It installs a small
launcher at `~/.local/bin/sony-head-tracker-gui` and a `sony-head-tracker-recenter`
command (used by the global recenter shortcut), both pointing back at this repo, so
keep the repo in place (or re-run after moving it). Remove with `make uninstall-gui`.

## Notes

- If the headset needs permission, the GUI shows a banner with a **Grant access**
  button (runs `pkexec` to install `extras/70-sony-head-tracker.rules`). You can
  also just run the CLI with `sudo` once to test.
- The GUI binds the JSON port (tracking port + 1, default 4243) to read live data;
  OpenTrack uses the tracking port (4242). They don't conflict.
