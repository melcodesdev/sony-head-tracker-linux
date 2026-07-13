#!/bin/sh
# Reload udev so the head-tracker rule takes effect; reconnect the headset once.
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
exit 0
