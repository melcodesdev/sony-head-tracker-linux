#!/usr/bin/env bash
# recenter.sh - tell a running sony-head-tracker to recenter the view ("look
# forward from where you are now"). This is what the GUI's "Recenter view" button
# does; as a standalone command it can be bound to a global shortcut (e.g. F9) so
# you can recenter without alt-tabbing out of a game.
#
# It sends the text "RECENTER" to the bridge's control socket on UDP
# 127.0.0.1:<port+3>, where <port> is the tracker's configured output port
# (default 4242, so control is 4245). No effect unless tracking is running.
set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/sony-head-tracker/gui.json"
port=4242
if [ -f "$CONFIG" ]; then
    p=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$CONFIG" | grep -oE '[0-9]+' | head -1 || true)
    [ -n "${p:-}" ] && port="$p"
fi
ctrl=$((port + 3))

# bash's /dev/udp: a single datagram, no dependencies. A UDP send succeeds even
# if nothing is listening, so a missing bridge simply does nothing (as intended).
if ! exec 3<>"/dev/udp/127.0.0.1/$ctrl" 2>/dev/null; then
    echo "recenter: could not open UDP 127.0.0.1:$ctrl" >&2
    exit 1
fi
printf 'RECENTER' >&3
exec 3>&-
