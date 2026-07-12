# Linux guide

Sony Head Tracker on Linux is a command-line bridge plus a GTK (libadwaita)
desktop app. It reads the Android Head Tracker HID sensor that compatible Sony
headphones expose over Bluetooth (surfaced as a `/dev/hidraw*` node), and streams
yaw/pitch/roll to [OpenTrack](https://github.com/opentrack/opentrack) and to your
own apps over loopback UDP. No webcam, IR clip, extra hardware, firmware change,
or custom kernel driver.

Validated end to end on a Sony WH-1000XM5, including Assetto Corsa Competizione
through Proton. For how the pipeline works internally, see
[ARCHITECTURE.md](ARCHITECTURE.md); for the wire format, see
[PROTOCOL.md](PROTOCOL.md).

## Contents

- [Install the runtime](#install-the-runtime)
- [Quick start (desktop app)](#quick-start-desktop-app)
- [Quick start (command line)](#quick-start-command-line)
- [Device access (udev)](#device-access-udev)
- [The desktop app](#the-desktop-app)
- [Global recenter shortcut](#global-recenter-shortcut)
- [OpenTrack](#opentrack)
- [Games through Proton](#games-through-proton)
- [Troubleshooting](#troubleshooting)

## Install the runtime

The CLI backend builds with just a C++20 compiler and Linux headers; the GTK app
needs Python 3, PyGObject, GTK 4, and libadwaita 1.4+.

| Distro | Command |
| ------ | ------- |
| Arch / CachyOS / Manjaro | `sudo pacman -S base-devel python-gobject gtk4 libadwaita` |
| Debian / Ubuntu / Mint | `sudo apt install build-essential python3-gi gir1.2-gtk-4.0 gir1.2-adw-1` |
| Fedora | `sudo dnf install gcc-c++ python3-gobject gtk4 libadwaita` |

Then build the CLI backend the app drives:

```bash
make          # -> build/sony-head-tracker
make test     # run the Linux test suite
```

A CMake build is also available (`cmake -S . -B build/linux -DCMAKE_BUILD_TYPE=Release && cmake --build build/linux --target sony-head-tracker`).

## Quick start (desktop app)

```bash
make gui           # run against ./build/sony-head-tracker
make install-gui   # optional: add "Sony Head Tracker" to your app menu
```

1. **Pair** your Sony headset over Bluetooth in your desktop's Bluetooth settings,
   and make sure it is connected to this computer (not only your phone).
2. **Grant device access:** when the app shows a banner, click **Grant device
   access** (installs a udev rule with a single password prompt), then reconnect
   the headset. One-time.
3. **Start:** press **Start**; the attitude indicator follows your head.
4. **Calibrate** if the axes feel wrong: **Calibrate axes** learns the mapping from
   a few guided head movements and applies it live.
5. **Set up a game:** **Set up a game** wires OpenTrack for a Steam/Proton title or
   a native game.

## Quick start (command line)

```bash
make
./build/sony-head-tracker probe    # verify the tracker
./build/sony-head-tracker bridge   # stream to OpenTrack (UDP 4242) + JSON (4243)
```

Then in OpenTrack, choose **UDP over network** input on port `4242` and press
**Start**. Command reference:

```text
sony-head-tracker probe                      list HID devices, flag the tracker
sony-head-tracker dump [--seconds N]         hex-dump raw input reports
sony-head-tracker bridge [--port 4242] [--seconds N]
                         [--axis-map YXZ] [--invert XZ] [--smoothing 0.18]
sony-head-tracker help | version
```

## Device access (udev)

hidraw nodes are root-only by default. Install the bundled rule once so the
logged-in user gets access without root:

```bash
sudo cp extras/70-sony-head-tracker.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Reconnect the headset afterwards. The rule grants access via `uaccess`
(systemd-logind or elogind). On a system without either, it also opens the device
to the `input` group, so run `sudo usermod -aG input $USER` and log back in. The
GUI's **Grant device access** button runs the same steps for you. For a one-off
test you can also run the CLI with `sudo`.

The tracker uses a vendor HID usage page, so the kernel does not bind it as an
input device; it appears as a plain `/dev/hidraw*` node this program reads.

## The desktop app

A GTK4 / libadwaita front end that runs the CLI as a subprocess and reads its JSON
telemetry, so it stays decoupled from the C++ build. Features:

- **Live attitude indicator** and yaw/pitch/roll readout.
- **Calibrate axes** wizard: move your head as prompted, it learns the
  yaw/pitch/roll mapping and applies it live over a control socket.
- **Recenter view** (and a global shortcut, below).
- **Set up a game** for Steam/Proton or native titles; titles known to support
  head tracking are flagged.
- **Live settings** (invert per axis, smoothing) that apply without stopping.
- **Start tracking on launch** (optional).

See [`gui/README.md`](../gui/README.md) for more.

## Global recenter shortcut

"Recenter" makes wherever you are looking the new forward. Bind it to a key you
can press from inside a game via **Settings > Recenter shortcut**. The app detects
your desktop and registers it the right way:

- **KDE Plasma** through KGlobalAccel's live D-Bus API (verified before it reports
  success), exposed as a **Recenter view** action on the app.
- **GNOME / XFCE** via gsettings / xfconf.
- **Hyprland / Sway** by editing the compositor config and applying it live.
- **Anything else** prints a command to bind by hand.

The underlying entry point is [`scripts/recenter.sh`](../scripts/recenter.sh),
which sends `RECENTER` to the bridge's control socket, so any tool (a Stream Deck,
a macro) can recenter too. From a terminal:

```bash
scripts/setup-recenter-shortcut.sh detect     # your desktop, and whether it is automatic
scripts/setup-recenter-shortcut.sh enable F9   # bind F9 (or Meta+C, etc.)
scripts/setup-recenter-shortcut.sh disable
```

## OpenTrack

OpenTrack receives the UDP stream and drives the in-game camera. Install it with
your package manager, or the bundled helper (it detects your package manager and
prints every command first):

```bash
scripts/install-opentrack.sh      # add --dry-run to preview, --yes to skip prompts
```

Then set OpenTrack's input to **UDP over network** on port `4242`, run
`sony-head-tracker bridge`, and press **Start**. The bundled
[`extras/opentrack-sony-head-tracker.ini`](../extras/opentrack-sony-head-tracker.ini)
is a starting profile.

## Games through Proton

For Steam games under Proton, OpenTrack has to run inside the game's own Wine
prefix. The app's **Set up a game** button (or
[`scripts/setup-steam-game.sh`](../scripts/setup-steam-game.sh)) automates it:
installs a Wine-friendly OpenTrack, writes a Proton launch wrapper, and
pre-configures the OpenTrack profile (UDP in, freetrack out, and
`center-at-startup=false` so the tracker's own recenter is authoritative). Paste
the printed launch line into the game's Steam **Launch Options**, start the
tracker, and play.

## Troubleshooting

**No head tracker found.** The sensor only appears once the headset is connected to
*this* computer as a HID device. Check `bluetoothctl devices Connected`; if the
headset is on your phone (multipoint), connect it to the PC. Some models only
expose the sensor once head tracking or spatial audio is enabled in Sony's Sound
Connect app. Run `sony-head-tracker probe` to see every HID device and whether the
tracker is flagged.

**`access denied`.** Install the udev rule (above) and reconnect the headset, or
run the CLI with `sudo` once to test.

**Detected, but no motion.** Run `sony-head-tracker dump --seconds 5` and move your
head; the bytes should change. If they do not, the sensor never started streaming,
so include that output in a bug report.

**Wrong axes** (looking left turns you right, etc.). Use **Calibrate axes** in the
app, or remap on the CLI: `sony-head-tracker bridge --invert xz --axis-map YXZ`
(those are the defaults).

**Filing a bug.** Include your distro and `uname -r`, `bluetoothctl --version`, the
full `sony-head-tracker probe` output, and `ls -l /dev/hidraw*`.
