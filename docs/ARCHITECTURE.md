# Architecture

How the Linux port works, end to end, for anyone reading the code. It covers the
data flow from the headset's Bluetooth sensor all the way to the in-game camera,
the layering that keeps the tracking maths hardware-free and unit-testable, and
how the desktop app drives it all.

If you only want the wire format, see [PROTOCOL.md](PROTOCOL.md). If you want the
Windows-to-Linux mapping (what was reused vs rewritten), see
[../PORTING.md](../PORTING.md).

## The one-paragraph version

Compatible Sony headphones expose an [Android Head Tracker HID
sensor](https://source.android.com/docs/core/interaction/sensors/head-tracker-hid-protocol)
over Bluetooth. Linux surfaces that sensor as a `/dev/hidraw*` node. The tracker
opens the node, writes the feature reports that make the sensor start streaming,
reads its input reports, decodes them into a normalized orientation sample, runs a
small filter (smoothing, recenter, axis mapping), and sends the result over
loopback UDP: six doubles that OpenTrack reads as a head pose, plus a JSON copy
for anything else. OpenTrack drives the in-game camera. The GTK app is a thin
front end that runs the CLI as a subprocess and reads that JSON.

## Data flow

```
  Sony headset (Bluetooth)
        │  Android Head Tracker HID sensor
        ▼
  /dev/hidraw*  ───────────────────────────────────────────────┐
        │  input reports (raw bytes)                            │ feature reports
        ▼                                                       │ (start streaming)
  HidBackend (src/hid_backend_linux.cpp)                        │
        │  parse descriptor, decode fields                      ┘
        ▼
  MotionSample  { rotationVector, gyro?, accel?, resetCounter, receivedAt }
        │
        ▼
  OrientationFilter (src/orientation.cpp)
        │  axis map → quaternion → smoothing → recenter → drift → Euler → output correction
        ▼
  MotionSample  { orientation (quat), euler (yaw/pitch/roll), ... }
        │
        ├─────────────► UDP 127.0.0.1:N     six little-endian doubles  ──► OpenTrack ──► game
        └─────────────► UDP 127.0.0.1:N+1   JSON telemetry             ──► GUI, scripts

  Control (GUI → bridge):  UDP 127.0.0.1:N+3   "RECENTER" / "OUT ..."  (live, no restart)
```

`N` is the base port (`--port`, default `4242`). See [Ports](#ports-and-control).

## Layering

The code is split so the tracking maths never touches the operating system. That
is what lets the whole decode-and-filter path be unit tested without a headset,
and what makes porting a matter of swapping one layer.

| Layer | Files | Depends on |
| ----- | ----- | ---------- |
| **Portable core** (OS-free, pure) | `math`, `orientation`, `protocol`, `hid_descriptor`, `hid_report_parser`, `app_config`, `diagnostics` | only `types.hpp` and the C++ standard library |
| **Platform layer** (Linux) | `hid_backend_linux`, `output_udp`, `logger`, `platform_compat` | POSIX: hidraw ioctls, BSD sockets |
| **Entry point** | `main_linux.cpp` | the two layers above |
| **Desktop app** | `gui/sony_head_tracker_gui.py`, `scripts/*` | runs the CLI as a subprocess |

Everything in the portable core operates on one value type, `MotionSample`
([`types.hpp`](../include/sony_head_tracker/types.hpp)), so recenter, smoothing,
axis mapping, Euler conversion, and serialisation all work identically regardless
of how the sample was captured. The `HidBackend` public interface
([`hid_backend.hpp`](../include/sony_head_tracker/hid_backend.hpp)) exposes no OS
types at all; the platform state hides behind a forward-declared `Context`.

## Stage 1: finding the tracker

`HidBackend::enumerate()` lists `/dev/hidraw*` (via `/sys/class/hidraw`) and probes
each node (`probeNode`). For every node it:

1. Reads the HID **report descriptor** with the `HIDIOCGRDESC` ioctl and parses it
   ourselves in [`hid_report_parser.cpp`](../src/hid_report_parser.cpp). This is
   the Linux stand-in for Windows' `HidP_*` API: it walks the descriptor items and
   produces a `ParsedDescriptor` of `ParsedField`s, each carrying its report id,
   usage, bit offset, bit size, logical/physical ranges, and (for NAry array
   fields) the list of selectable usages.
2. Checks the **signature**: a custom sensor collection (usage page `kSensorPage`,
   usage `kOtherCustom`) that contains the rotation-vector input usage.
3. Confirms with the **`#AndroidHeadTracker#` marker** (`readTrackerMarker`), a
   constant string the sensor exposes in a feature report. If the marker reads
   back, the device is verified; if the node is present but the marker cannot be
   read, the descriptor signature alone still registers it.

### Detection without access

hidraw nodes are root-only until a udev rule grants the logged-in user access
(`extras/70-sony-head-tracker.rules`, `TAG+="uaccess"`). Before that rule is
installed, `open()` fails, so `probeViaSysfs` identifies and names the headset
from world-readable sysfs (`uevent`, `report_descriptor`) and sets
`accessDenied = true`. That is what lets the CLI and GUI say "found your headset,
grant access" instead of "nothing here". The marker cannot be read this way (it
needs the device), so sysfs detection relies on the descriptor signature.

## Stage 2: starting the stream

A freshly connected sensor is idle. `configureFeatures` (called from
`HidBackend::connect`) builds and writes the feature reports that make it stream:

- **Report interval**: the sensor-page `kReportInterval` feature field, written to
  a 10-20 ms target so the headset reports at ~25-50 Hz. The value is encoded
  using the field's physical range and unit exponent from the descriptor.
- **Selectors** (NAry array fields): reporting = *All Events*, power = *Full*,
  transport = *ACL*. For each, the value written is the target usage's **index**
  within that field's usage list (`logicalMin + index`), which is how HID NAry
  selectors work.

Reports are read-modify-written: existing feature contents are fetched with
`HIDIOCGFEATURE`, the relevant bits are packed in (`packBits`), and the whole
report is sent back with `HIDIOCSFEATURE`. If nothing is accepted, the code logs a
warning; some models start streaming anyway once head tracking is enabled in
Sony's app.

## Stage 3: reading and decoding

`connect()` spawns a `std::jthread` reader. Its loop:

1. `poll()` the fd with a 100 ms timeout (so `disconnect()` stays responsive),
   then `read()` one input report.
2. Hand the raw bytes to the optional `RawCallback` (this is what `dump` prints).
3. For each sensor-page input field, extract its bits at the field's absolute bit
   offset (`extractBits`) and decode them to physical values with the shared,
   unit-tested `decodePackedDescriptorValuesInto`
   ([`hid_descriptor.cpp`](../src/hid_descriptor.cpp)), which applies the
   logical-to-physical scaling from the descriptor.
4. Assemble a `MotionSample`: `rotationVector` (required), plus `angularVelocity`
   (gyro) and `acceleration` if the device reports them, plus `resetCounter`.
5. Track packets-per-second and stamp `receivedAt`, then emit the sample through
   the `SampleCallback` (only when a rotation vector was present).

Bit offsets account for the leading report-id byte when the descriptor uses report
ids (`base = usesReportIds ? 8 : 0`). Everything here is bounds-checked against a
malformed or truncated report.

## Stage 4: the orientation filter

[`OrientationFilter::process`](../src/orientation.cpp) turns a raw sample into a
stable head pose. In order:

1. **Axis map**: remap and sign-flip the raw rotation vector (and gyro/accel) into
   the app's convention. Default is **YXZ with X and Z inverted**, the mapping that
   is correct on the WH-1000XM5 (`FilterConfig::axes` in
   [`types.hpp`](../include/sony_head_tracker/types.hpp)).
2. **Quaternion**: convert the rotation vector (axis-angle) to a quaternion.
3. **Adaptive smoothing**: SLERP the filtered quaternion toward the latest one.
   The blend factor rises with angular speed, so fast turns stay responsive while a
   held pose stays steady.
4. **Recenter**: when a recenter is pending, capture the current orientation as the
   new center. Output is `conjugate(drift) * conjugate(center) * filtered`, so
   "forward" is wherever you were looking at the last recenter.
5. **Gentle drift correction**: while nearly still, estimate a tiny gyro bias and
   integrate it out. It never pulls a deliberately held pose back toward center.
6. **Euler**: convert the recentered quaternion to yaw/pitch/roll degrees.
7. **Output correction**: a final per-output Euler remap,
   `euler[i] = outputSign[i] * baseEuler[outputSource[i]]`. Identity by default, so
   it changes nothing until the **Calibrate** wizard measures your movements and
   sets it. This is the layer the GUI adjusts live.

The filter holds all of its own state (`filtered_`, `center_`, `drift_`, gyro bias)
and is driven purely by `MotionSample` in and out, which is why
`tests/orientation_tests.cpp` can exercise it with synthetic samples.

## Stage 5: output

[`UdpOutput::send`](../src/output_udp.cpp) emits two datagrams per sample to
loopback:

- **Port `N`**: `toOpenTrackPose` returns six native doubles
  `{0, 0, 0, yaw, pitch, roll}` (translation is always zero; this protocol is
  orientation-only). OpenTrack's "UDP over network" input reads them straight into
  its pose array.
- **Port `N+1`**: `toJsonTo` writes a compact JSON object (`version: 2`) with the
  rotation vector, quaternion, yaw/pitch/roll, gyro, accel, reset counter, and rate.
  Serialisation is pure and allocation-light (`std::to_chars` into reused buffers).

Both formats come from the *same* filtered sample, so the GUI's readout and the
game always agree. Output is loopback-only and unauthenticated by design.

### Ports and control

| Port | Direction | Payload |
| ---- | --------- | ------- |
| `N` (default 4242) | bridge → OpenTrack | six little-endian doubles |
| `N+1` | bridge → GUI/scripts | JSON telemetry |
| `N+3` | GUI → bridge | control datagrams |

The **control socket** (`N+3`) is how settings apply without restarting the stream.
The bridge binds it in [`main_linux.cpp`](../src/main_linux.cpp) and, each loop,
parses:

- `RECENTER` → `filter.recenter()`
- `OUT s0 s1 s2 g0 g1 g2 smoothing` → update `outputSource`, `outputSign`, and
  smoothing on a live copy of the config under a mutex, then `filter.setConfig`.

This is purely additive: if the bind fails the stream still runs, just without live
control.

## The desktop app

[`gui/sony_head_tracker_gui.py`](../gui/sony_head_tracker_gui.py) is a GTK4 /
libadwaita front end that stays fully decoupled from the C++ build: it **runs the
CLI as a subprocess** and never links against it.

- **Start** spawns `sony-head-tracker bridge --port N ...` and opens a UDP reader
  on `N+1`. It parses the JSON telemetry to drive the attitude indicator and the
  yaw/pitch/roll readout. It never reads the OpenTrack doubles.
- **Live settings** (invert, smoothing) and **Recenter** are sent on `N+3`, so the
  stream never stops. Only changing the port restarts the subprocess.
- **Calibrate axes** temporarily sets an identity output correction, asks you to
  move your head, measures which base-output axis each movement drives and in which
  direction from the live JSON, and writes the resulting `outputSource`/`outputSign`
  back over the control socket.
- **Set up a game** runs `scripts/setup-steam-game.sh` to install a Wine-friendly
  OpenTrack and a Proton launch wrapper per Steam title, or opens OpenTrack for a
  native game.
- **Recenter shortcut** binds a global key to `scripts/recenter.sh` (which just
  sends `RECENTER` to `N+3`). `scripts/setup-recenter-shortcut.sh` detects the
  desktop and registers it the right way: KDE through KGlobalAccel's live D-Bus API,
  GNOME/XFCE via gsettings/xfconf, Hyprland/Sway by editing the compositor config
  and applying it live, or by printing the command to bind by hand elsewhere.

## Concurrency model

- **CLI**: the main thread parses args, opens the device, and runs a poll loop for
  the control socket and shutdown. The `HidBackend` reader runs on its own
  `jthread`; its `SampleCallback` (which calls `filter.process` and `udp.send`) runs
  on that reader thread. The control socket updates the filter config under a mutex
  shared with the reader.
- **GUI**: a single GLib main loop drives the UI. Blocking work (device probe, game
  setup) runs on worker threads that marshal results back with `GLib.idle_add`. The
  JSON reader is a GLib IO watch on the UDP socket.

## Coordinate frames and conventions

- Raw device orientation arrives as a rotation vector (axis-angle, radians).
- The **axis map** (`AxisMapping`, default YXZ with X/Z inverted) brings it into the
  app's frame; the same map is applied to gyro and accel so all streams share one
  frame.
- The filter emits a recentered **quaternion** and its **Euler** decomposition in
  degrees. Euler is inherently subject to gimbal coupling near +/-90 degrees of
  pitch; consumers that want a singularity-free signal should use the quaternion
  from the JSON.
- The **output correction** (`outputSource`/`outputSign`) is a final per-axis Euler
  remap on top of the base map, and is what the Calibrate wizard sets per game.

## Testing

The portable core is covered without hardware (`make test`, `tests/`):

- `descriptor_tests`, `report_parser_tests`: descriptor parsing, bit extraction,
  NAry selectors, truncated-buffer safety.
- `orientation_tests`: smoothing, recenter, drift, axis mapping on synthetic samples.
- `protocol_tests`: exact OpenTrack and JSON byte output.
- `math_tests`, `config_tests`, `diagnostics_tests`: quaternion maths, config
  round-trips, log redaction.

Because the decode path (`hid_report_parser` + `hid_descriptor`) is shared between
the live backend and the tests, a captured descriptor can be replayed in a test
without a headset.

## Extending it

- **Another platform**: implement the `HidBackend` interface for that OS (its own
  `Context`, enumeration, feature-report enable, and read loop) and a socket layer
  in `output_udp`. The core and the filter are reused unchanged. This is exactly the
  shape the macOS support upstream follows (`src/macos/`), and the direction this
  Linux port is aligning to.
- **Another output**: `MotionSample` plus the pure serialisers in `protocol.cpp` are
  all a new sink needs; add a serialiser and a transport without touching capture or
  filtering.
