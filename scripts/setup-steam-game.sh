#!/usr/bin/env bash
# setup-steam-game.sh - one-shot head-tracking setup for a Steam/Proton game.
#
# Running a Windows game under Proton means the head-tracking data has to be
# relayed *inside* the game's Wine prefix, which is why the manual setup is
# fiddly. This script automates all of it:
#   - installs a Wine-friendly (Qt5) OpenTrack once, into ~/.local/share,
#   - writes a launcher that starts OpenTrack inside the game's own Proton
#     session (so it shares the TrackIR/freetrack channel and doesn't lock the
#     prefix),
#   - pre-configures OpenTrack (UDP in from sony-head-tracker, freetrack out),
#   - prints the single Steam "launch options" line to paste.
#
# Usage:
#   setup-steam-game.sh <appid> [--port 4242]
#   setup-steam-game.sh capture <appid>     # save this game's working OpenTrack
#                                             config as the reusable template
#
# Find a game's AppID from its Steam store URL, or `steam://` right-click > Properties.
set -euo pipefail

OT_VERSION="opentrack-2023.2.0"   # last Qt5 build; runs under Proton without ICU DLLs
OT_URL="https://github.com/opentrack/opentrack/releases/download/${OT_VERSION}/${OT_VERSION}-win32-portable.7z"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/sony-head-tracker"
OT_DIR="$DATA/opentrack"
OT_EXE="$OT_DIR/install/opentrack.exe"
WRAPPER="$DATA/proton-launch.sh"
TEMPLATE="$DATA/opentrack-profile.ini"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

steam_roots() {
    for r in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" \
             "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
        [ -d "$r/steamapps" ] && readlink -f "$r"
    done | sort -u
}

# Echo the game's Proton prefix (…/compatdata/<appid>/pfx) or return 1.
find_prefix() {
    local appid="$1" root vdf p
    for root in $(steam_roots); do
        [ -d "$root/steamapps/compatdata/$appid/pfx" ] && { echo "$root/steamapps/compatdata/$appid/pfx"; return 0; }
        vdf="$root/steamapps/libraryfolders.vdf"
        [ -f "$vdf" ] || continue
        while IFS= read -r p; do
            [ -n "$p" ] && [ -d "$p/steamapps/compatdata/$appid/pfx" ] && { echo "$p/steamapps/compatdata/$appid/pfx"; return 0; }
        done < <(grep -oE '"path"[[:space:]]+"[^"]+"' "$vdf" | sed -E 's/.*"path"[[:space:]]+"([^"]+)".*/\1/')
    done
    return 1
}

game_name() {
    local appid="$1" root acf
    for root in $(steam_roots); do
        acf="$root/steamapps/appmanifest_$appid.acf"
        [ -f "$acf" ] && { grep -oE '"name"[[:space:]]+"[^"]+"' "$acf" | head -1 | sed -E 's/.*"name"[[:space:]]+"([^"]+)".*/\1/'; return; }
    done
    echo "app $appid"
}

ensure_opentrack() {
    [ -f "$OT_EXE" ] && { info "OpenTrack already installed ($OT_DIR)"; return; }
    command -v curl >/dev/null 2>&1 || die "need curl to download OpenTrack (install curl)."
    command -v 7z >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1 || die "need 7z/7za to extract OpenTrack (install p7zip)."
    local sevenz; sevenz=$(command -v 7z || command -v 7za)
    info "Downloading Wine-friendly OpenTrack ($OT_VERSION)..."
    mkdir -p "$OT_DIR"
    curl -L -f --progress-bar -o "$DATA/opentrack.7z" "$OT_URL" || die "download failed."
    "$sevenz" x -y -o"$OT_DIR" "$DATA/opentrack.7z" >/dev/null || die "extract failed."
    rm -f "$DATA/opentrack.7z"
    [ -f "$OT_EXE" ] || die "OpenTrack extracted but opentrack.exe not found."
    info "OpenTrack installed."
}

write_wrapper() {
    mkdir -p "$DATA"
    cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
# Run OpenTrack inside the game's OWN Proton session so they share one Wine
# session (required for the TrackIR/freetrack channel) WITHOUT locking the prefix.
#
# The trick: start the GAME first (it owns the wineserver), then attach OpenTrack
# with Proton's 'run' verb, which JOINS the running session instead of the
# 'waitforexitandrun' verb, which restarts and locks it (that lock is why the game
# wouldn't launch). Written by sony-head-tracker's setup-steam-game.sh. Set as a
# game's Steam launch options:
#     ~/.local/share/sony-head-tracker/proton-launch.sh %command%
OPENTRACK="${XDG_DATA_HOME:-$HOME/.local/share}/sony-head-tracker/opentrack/install/opentrack.exe"

if [[ -f "$OPENTRACK" && $# -ge 1 ]]; then
    # Derive an OpenTrack launch from the game's command: swap the game .exe for
    # opentrack.exe, and the 'waitforexitandrun' verb for 'run' (attach, no restart).
    ot=("$@")
    ot[$(($#-1))]="$OPENTRACK"
    for i in "${!ot[@]}"; do
        case "${ot[$i]}" in
            waitforexitandrun)       ot[$i]="run" ;;
            --verb=waitforexitandrun) ot[$i]="--verb=run" ;;
        esac
    done
    ( sleep 20; "${ot[@]}" ) &   # attach OpenTrack after the game's session is up
    otpid=$!
    trap 'kill "$otpid" 2>/dev/null' EXIT
fi

"$@"   # start the game first, in the foreground; it owns the session
EOF
    chmod +x "$WRAPPER"
}

write_profile() {
    local pfx="$1" port="$2"
    local dir="$pfx/drive_c/users/steamuser/Documents/opentrack-2.3"
    mkdir -p "$dir"
    if [ -f "$TEMPLATE" ]; then
        info "Applying saved OpenTrack profile (captured template)."
        cp "$TEMPLATE" "$dir/default.ini"
    else
        info "Writing default OpenTrack profile (UDP in on $port, freetrack out)."
        cat > "$dir/default.ini" <<EOF
[migrations]
last-migration-at=20220126_00~

[modules]
tracker-dll=udp
protocol-dll=freetrack
filter-dll=accela

[udp-tracker]
port=$port

[opentrack-ui]
center-at-startup=false
EOF
        return
    fi
    # Patch the UDP port in the copied template.
    if grep -q '^\[udp-tracker\]' "$dir/default.ini"; then
        sed -i -E "/^\[udp-tracker\]/,/^\[/ s/^port=.*/port=$port/" "$dir/default.ini"
    fi
}

do_capture() {
    local appid="$1" pfx ini
    pfx=$(find_prefix "$appid") || die "no Proton prefix for app $appid (install + run it once)."
    ini="$pfx/drive_c/users/steamuser/Documents/opentrack-2.3/default.ini"
    [ -f "$ini" ] || die "no OpenTrack profile found at $ini yet."
    mkdir -p "$DATA"
    cp "$ini" "$TEMPLATE"
    info "Saved this game's OpenTrack config as the reusable template:"
    echo "    $TEMPLATE"
    echo "Future 'setup-steam-game.sh <appid>' runs will apply it automatically."
}

main() {
    [ $# -ge 1 ] || die "usage: setup-steam-game.sh <appid> [--port N]  |  setup-steam-game.sh capture <appid>"

    if [ "$1" = "capture" ]; then
        [ $# -eq 2 ] || die "usage: setup-steam-game.sh capture <appid>"
        do_capture "$2"; exit 0
    fi

    local appid="$1"; shift
    [[ "$appid" =~ ^[0-9]+$ ]] || die "AppID must be numeric (got '$appid')."
    local port=4242
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) port="${2:?}"; shift 2 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    local name pfx
    name=$(game_name "$appid")
    pfx=$(find_prefix "$appid") || die "couldn't find a Proton prefix for $name (app $appid).
Make sure the game is installed and you have launched it at least once (that creates the prefix)."

    info "Game:   $name (app $appid)"
    info "Prefix: $pfx"
    ensure_opentrack
    write_wrapper
    write_profile "$pfx" "$port"

    cat <<EOF

$(printf '\033[1;32mSetup complete.\033[0m') Two steps left, both one-time:

1) In Steam, right-click $name > Properties > General > Launch Options, paste:

       $WRAPPER %command%

2) Start the tracker before playing:

       sony-head-tracker bridge --port $port

Then just launch the game from Steam. OpenTrack starts hidden inside the game,
pre-set to receive on UDP $port and output freetrack (TrackIR). Alt-Tab to it and
press Start once if tracking doesn't move; then run:

       $0 capture $appid

to save that working config so every future game is zero-config.
EOF
}

main "$@"
