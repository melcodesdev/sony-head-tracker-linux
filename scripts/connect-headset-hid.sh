#!/usr/bin/env bash
# connect-headset-hid.sh - make a connected Sony headset expose its head-tracker.
#
# Sony headsets advertise the Bluetooth HID service (UUID 0x1124) that carries the
# Android Head Tracker sensor, but BlueZ often connects only the audio profiles, so
# no /dev/hidraw* node appears and the tracker looks "not detected". This asks
# BlueZ to connect the HID profile on any connected Sony device that offers it,
# which creates the node. It is a no-op if the profile is already connected or no
# such headset is present. Prints the number of devices it nudged.
set -euo pipefail

HID_UUID="00001124-0000-1000-8000-00805f9b34fb"
nudged=0

command -v gdbus >/dev/null 2>&1 || { echo 0; exit 0; }

# Device object paths from BlueZ's object manager (…/dev_AA_BB_CC_DD_EE_FF).
paths=$(gdbus call --system --dest org.bluez --object-path / \
    --method org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null \
    | grep -oE "/org/bluez/hci[0-9]+/dev(_[0-9A-Fa-f]{2}){6}" | sort -u || true)

for path in $paths; do
    props=$(gdbus call --system --dest org.bluez --object-path "$path" \
        --method org.freedesktop.DBus.Properties.GetAll org.bluez.Device1 2>/dev/null) || continue
    # Must be connected, advertise HID, and be a Sony device (VID 054C, or a known name).
    case "$props" in *"'Connected': <true>"*) : ;; *) continue ;; esac
    case "$props" in *"$HID_UUID"*) : ;; *) continue ;; esac
    case "$props" in
        *v054C*|*v054c*|*"WH-"*|*"WF-"*|*ULT*|*LinkBuds*|*Sony*) : ;;
        *) continue ;;
    esac
    if gdbus call --system --dest org.bluez --object-path "$path" \
        --method org.bluez.Device1.ConnectProfile "$HID_UUID" >/dev/null 2>&1; then
        nudged=$((nudged + 1))
    fi
done

echo "$nudged"
