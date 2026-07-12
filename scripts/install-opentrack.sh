#!/usr/bin/env bash
# install-opentrack.sh
# Convenience helper to install OpenTrack, the app this project streams head
# tracking to over UDP. OpenTrack is a separate project
# (https://github.com/opentrack/opentrack); this script only runs your distro's
# native install command for you. It is opt-in and prints every command before
# running it; nothing is piped from the internet.
#
# Usage:
#   scripts/install-opentrack.sh            detect package manager, confirm, install
#   scripts/install-opentrack.sh --dry-run  print what it would do, run nothing
#   scripts/install-opentrack.sh --yes      skip the per-command confirmation
#
# For the rare case where the Arch/AUR build fails on OpenCV 5, see the
# "Installing OpenTrack" section of the README for a from-source fallback.
set -u

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

if have opentrack; then
    echo "OpenTrack is already installed: $(command -v opentrack)"
    exit 0
fi

# Print a command, then run it unless --dry-run, asking first unless --yes.
# Returns non-zero if the user declines or the command fails.
run() {
    echo "+ $*"
    [ "$DRY_RUN" -eq 1 ] && return 0
    if [ "$ASSUME_YES" -ne 1 ]; then
        printf 'Run this command? [y/N] '
        read -r reply
        case "$reply" in
            y|Y|yes|YES) ;;
            *) echo "skipped."; return 1 ;;
        esac
    fi
    "$@"
}

# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
id_all=" ${ID:-} ${ID_LIKE:-} "
echo "Detected: ${PRETTY_NAME:-unknown distro}"

case "$id_all" in
    *" arch "*|*" cachyos "*|*" manjaro "*|*" endeavouros "*|*" arch "*)
        helper=""
        for h in paru yay; do have "$h" && helper="$h" && break; done
        if [ -z "$helper" ]; then
            echo "OpenTrack is on the AUR but no AUR helper (paru/yay) was found." >&2
            echo "Install one, then run: paru -S opentrack" >&2
            exit 1
        fi
        echo "Note: on very new Arch systems shipping OpenCV 5, the 'opentrack'"
        echo "package may fail to build (its camera trackers predate the OpenCV 5"
        echo "API). If it does, try 'opentrack-git', or use the from-source"
        echo "fallback in the README."
        if ! run "$helper" -S opentrack; then
            echo
            echo "If the build failed on OpenCV/calib3d, try: $helper -S opentrack-git"
            exit 1
        fi
        ;;
    *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*)
        run sudo apt-get update || true
        run sudo apt-get install -y opentrack || exit 1
        ;;
    *" fedora "*|*" rhel "*|*" centos "*)
        echo "OpenTrack is not in Fedora's default repositories. Options:"
        echo "  - Enable a COPR / RPM Fusion that provides it, then: sudo dnf install opentrack"
        echo "  - Or build from source: https://github.com/opentrack/opentrack"
        exit 1
        ;;
    *" opensuse "*|*" suse "*)
        echo "Search your repos:  zypper se opentrack"
        echo "If present:         sudo zypper install opentrack"
        echo "Otherwise build from source: https://github.com/opentrack/opentrack"
        exit 1
        ;;
    *)
        echo "Unrecognised distro. Install OpenTrack from your package manager, or:"
        echo "  https://github.com/opentrack/opentrack"
        exit 1
        ;;
esac

if have opentrack; then
    echo "Done. OpenTrack installed: $(command -v opentrack)"
else
    echo "Install finished, but 'opentrack' is not on PATH yet; open a new shell and retry."
fi
