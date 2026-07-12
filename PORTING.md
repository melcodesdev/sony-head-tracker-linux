# Linux port: roadmap & status

Adapting NicholasSlattery/sony-head-tracker (Windows/C++20) to Linux. The device
speaks the standard **Android Head Tracker HID protocol** over Bluetooth, which
Linux exposes as a `/dev/hidraw*` node; so the port is an I/O-layer rewrite, not
a protocol reverse-engineering job.

## Strategy

Keep the portable core untouched; replace only the Windows I/O layer. The upstream
code is already cleanly split: OS types never leak into the tracking maths or the
`MotionSample` pipeline, so the whole "brain" builds and runs on Linux as-is.

Target first milestone: a **headless CLI** (`bridge`/`probe`/`dump`) that streams
to OpenTrack over UDP. GUI comes later, if at all.

## Status

| Area | Upstream file | Linux plan | State |
| --- | --- | --- | --- |
| Quaternion / Euler maths | `math.cpp` | unchanged | ✅ builds + tests pass |
| Orientation filter, axis remap | `orientation.cpp` | unchanged | ✅ builds + tests pass |
| OpenTrack + JSON serialisation | `protocol.cpp` | unchanged | ✅ builds + tests pass |
| HID descriptor value decode | `hid_descriptor.cpp` | unchanged | ✅ builds + tests pass |
| Config model | `app_config.cpp` | unchanged | ✅ compiles |
| Diagnostics model | `diagnostics.cpp` | unchanged | ✅ compiles |
| Logger sink / error strings | `logger.cpp` | `#ifdef` POSIX guards | ✅ done |
| UTF-8 / socket shims | (new) `platform_compat.*` | BSD sockets + UTF-32↔8 | ✅ done |
| UDP transport | `output_udp.cpp` | Winsock → BSD sockets | ✅ done |
| **HID report-descriptor parse** | (was `HidP_GetValueCaps`) | new `hid_report_parser.*` from `HIDIOCGRDESC` | ✅ done + tested (synthetic + real descriptors) |
| **HID enumerate + config + read** | `hid_backend.cpp` | `hid_backend_linux.cpp` (sysfs + hidraw ioctls) | ✅ validated on a real WH-1000XM5 (streams at ~25 Hz) |
| CLI entry point | `main.cpp` (`wmain`) | `main_linux.cpp` (narrow argv) | ✅ done (probe/dump/bridge) |
| Config load/save path | `app_config_store.cpp` | POSIX shim (`~/.config`) | ⬜ deferred (bridge uses flags) |
| Diagnostics report | `diagnostics_report.cpp` | `uname` instead of registry | ⬜ deferred |
| GUI | `gui.cpp` | dropped for now | ⛔ out of scope |
| Windows Bluetooth pair/rebind | `bluetooth.cpp` | `bluetoothctl` by hand | ⛔ not needed |
| Windows Sensor API backend | `sensor_api_backend.cpp` | dropped (hidraw is primary) | ⛔ out of scope |

**Milestone reached:** headless CLI builds and links; 33/33 tests pass. Enumeration,
descriptor parsing, feature-enable, and the decode path are **validated on a real
WH-1000XM5**; `bridge` streams live orientation over UDP at ~25 Hz. Note the XM5's
Reporting/Power selectors are 1-bit NAry fields; the parser records each array's
usage list so selectors resolve by index (`SET_FEATURE report 1 = 01 A3`). hidraw
reads work even though the kernel `hid-sensor-hub` driver is also bound.

## Build

`cmake` is not required. Use the Makefile:

```sh
make test     # builds + runs the 28 pure-core tests (all passing on this box)
make          # builds what currently compiles
```

Toolchain present on this machine: g++ 16, clang++ 22, libudev 261, hidapi,
BlueZ 5.87, `/dev/hidraw*` nodes.

## The two hard parts

### 1. HID report-descriptor parser (replaces `HidP_*`)

On Windows, `HidD_GetPreparsedData` + `HidP_GetValueCaps` did all the descriptor
parsing and told the code which usage lives at which bit offset in each report.
Linux's hidraw gives only the **raw** descriptor via `ioctl(fd, HIDIOCGRDESC)`.

So we must write a small HID item parser that walks the descriptor and emits the
existing `DescriptorField` struct (see `device.hpp`); usage page/usage, report
ID, **bit offset within the report**, bit size, report count, logical/physical
min-max, unit exponent. Everything downstream already consumes `DescriptorField`
(`hid_descriptor.cpp::decodePackedDescriptorValuesInto`), so once the field map
and bit offsets are correct, decoding is free and already unit-tested.

Note vs. Windows: `HidP_GetValueCaps` does **not** expose bit offsets (Windows
addressed fields by usage). Our parser must additionally track the running bit
offset per report ID as it walks Input/Feature main-items; that's the one piece
of new logic with no upstream analogue.

### 2. Feature-report configuration (replaces `configureHeadTrackerFeatures`)

The headset does **not** stream until it's configured via Feature reports. Upstream
`hid_backend.cpp` sets, via `HidP_SetUsageValue`/`HidD_SetFeature`:

- report interval → 10–20 ms
- transport = ACL (`0xF800`)
- power = Full (`0x0851`)
- reporting = All Events (`0x0841`)

On Linux we build those Feature report byte buffers ourselves (using the parsed
field bit offsets), then `ioctl(fd, HIDIOCSFEATURE)` to write and `HIDIOCGFEATURE`
to read back. The verification marker `#AndroidHeadTracker#` (usage `0x20:0x0308`,
a Feature string) is read the same way. Usage IDs are already in `hid_usages.hpp`.

## Access & pairing (runtime)

1. Pair the headset once: `bluetoothctl` → `pair`/`trust`/`connect`.
2. Because the tracker uses a **vendor usage page** (`0x20:0xE1`), the kernel does
   not bind it as an input device; it appears as `/dev/hidraw*`, readable directly.
3. hidraw nodes are root-only by default. Ship a udev rule to grant access. Note:
   Bluetooth HID (uhid) devices carry NO `ATTRS{idVendor}`, so match the parent HID
   device's kernel name instead:
   `SUBSYSTEM=="hidraw", KERNELS=="0005:054C:*", TAG+="uaccess"` (bus 0005 =
   Bluetooth, 0003 = USB; 054C = Sony). See `extras/70-sony-head-tracker.rules`.
   The CLI/GUI also identify the tracker from sysfs without access, to prompt for
   the one-time grant.

## Remaining work

1. **Hardware validation (blocking real use).** Pair a WH-1000XM5, install the udev
   rule (`extras/70-sony-head-tracker.rules`), and run `sony-head-tracker probe`. If
   the tracker verifies but `bridge` produces no motion, capture the descriptor and
   a `dump`, then check the feature-report encoding in
   `hid_backend_linux.cpp::configureFeatures` (see hard part #2; the selector
   indices are the most likely thing to need adjusting against a real descriptor).
2. Once a real XM5 descriptor is captured, add it as a fixture to
   `tests/report_parser_tests.cpp` and assert the rotation/gyro/interval fields.
3. Optional: port `app_config_store.cpp` + `diagnostics_report.cpp` (POSIX shims) to
   restore the `diagnostics` command and config persistence.
4. Optional: a GTK/Qt or web GUI, if a headless CLI isn't enough.
