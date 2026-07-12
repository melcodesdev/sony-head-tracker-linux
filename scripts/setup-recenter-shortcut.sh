#!/usr/bin/env bash
# setup-recenter-shortcut.sh - bind a global key that recenters the head tracker,
# on whatever desktop you run. On Wayland (and cleanly on X11 too) an app cannot
# grab a global key for itself, so the key is registered with the desktop's own
# shortcut system and runs recenter.sh. That command is the universal entry point:
# anything (a shortcut, a Stream Deck, a script) can recenter by running it.
#
# Usage:
#   setup-recenter-shortcut.sh detect          # prints: de=<id> mode=<auto|assist|manual>
#   setup-recenter-shortcut.sh explain         # human explanation for this desktop
#   setup-recenter-shortcut.sh status          # "enabled:F9" or "disabled"
#   setup-recenter-shortcut.sh enable [KEY]    # KEY defaults to F9
#   setup-recenter-shortcut.sh disable
#   setup-recenter-shortcut.sh command         # print the recenter command to bind by hand
#
# Supported automatically: KDE Plasma, GNOME (and GTK-based like Cinnamon via
# gsettings), XFCE. Assisted (edits your config + applies live): Hyprland, Sway.
# KDE is registered through KGlobalAccel's live D-Bus API. Merely writing
# kglobalshortcutsrc does not activate a new shortcut in an already-running
# Plasma Wayland session.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECENTER="$DIR/recenter.sh"
NAME="Recenter head tracker view"
ID="sony-head-tracker-recenter"

# ---- desktop detection -----------------------------------------------------
detect_de() {
    local d="${XDG_CURRENT_DESKTOP:-}${XDG_SESSION_DESKTOP:-}${DESKTOP_SESSION:-}"
    d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
    if   [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || [[ "$d" == *hyprland* ]]; then echo hyprland
    elif [ -n "${SWAYSOCK:-}" ] || [[ "$d" == *sway* ]]; then echo sway
    elif [[ "$d" == *kde* || "$d" == *plasma* ]]; then echo kde
    elif [[ "$d" == *gnome* || "$d" == *unity* ]]; then echo gnome
    elif [[ "$d" == *cinnamon* ]]; then echo cinnamon
    elif [[ "$d" == *xfce* ]]; then echo xfce
    elif [[ "$d" == *mate* ]]; then echo mate
    else echo unknown
    fi
}

mode_for() {
    case "$1" in
        kde)              command -v gdbus >/dev/null 2>&1 && echo auto || echo manual ;;
        gnome|cinnamon)   command -v gsettings     >/dev/null 2>&1 && echo auto || echo manual ;;
        xfce)             command -v xfconf-query   >/dev/null 2>&1 && echo auto || echo manual ;;
        hyprland)         command -v hyprctl        >/dev/null 2>&1 && echo assist || echo manual ;;
        sway)             command -v swaymsg        >/dev/null 2>&1 && echo assist || echo manual ;;
        *)                echo manual ;;
    esac
}

explain() {
    local de mode; de=$(detect_de); mode=$(mode_for "$de")
    case "$de" in
        kde)      echo "KDE Plasma detected. I register Recenter view live through Plasma's shortcut service and verify it before reporting success. If that service is unavailable, use System Settings > Shortcuts." ;;
        gnome)    echo "GNOME detected. I can add a custom keyboard shortcut via gsettings; it applies immediately." ;;
        cinnamon) echo "Cinnamon detected. gsettings custom shortcuts usually work; if not, bind the command by hand in Keyboard settings." ;;
        xfce)     echo "XFCE detected. I can add the shortcut with xfconf-query; it applies immediately." ;;
        hyprland) echo "Hyprland detected. I can append a bind line to your hyprland.conf and apply it live with hyprctl." ;;
        sway)     echo "Sway detected. I can append a bindsym to your sway config and apply it live with swaymsg." ;;
        *)        echo "Desktop not auto-detected. Bind the printed command to a key in your desktop's keyboard settings." ;;
    esac
    echo "mode=$mode"
}

# ---- KDE --------------------------------------------------------------------
# Preferred: expose "Recenter view" as a Desktop Action on the installed app, so
# KDE lists it as a bindable action right under "Sony Head Tracker" (and as a
# right-click jump-list action). Fallback, if the app is not installed: a
# self-contained, visible command-shortcut launcher.
APP_DESK="${XDG_DATA_HOME:-$HOME/.local/share}/applications/io.github.sonyheadtracker.desktop"
APP_GROUP="io.github.sonyheadtracker.desktop"
SELF_DESK="${XDG_DATA_HOME:-$HOME/.local/share}/applications/${ID}.desktop"

kde_ensure_action() {  # add a Recenter desktop action to the app if missing
    [ -f "$APP_DESK" ] || return 1
    grep -q '^Actions=.*recenter' "$APP_DESK" && return 0
    if grep -q '^Actions=' "$APP_DESK"; then
        sed -i 's/^Actions=/Actions=recenter;/' "$APP_DESK"
    else
        awk '1; /^\[Desktop Entry\]/{print "Actions=recenter;"}' "$APP_DESK" > "$APP_DESK.tmp" && mv "$APP_DESK.tmp" "$APP_DESK"
    fi
    printf '\n[Desktop Action recenter]\nName=Recenter view\nExec=%s\n' "$RECENTER" >> "$APP_DESK"
}
# KGlobalAccel identifies an action with four strings: component ID, action ID,
# component name, and action name. The app desktop action has the stable ID
# "recenter". The fallback launcher uses KDE's conventional "_launch" action.
kde_action_id() {
    if kde_ensure_action; then
        printf "['%s', 'recenter', 'Sony Head Tracker', 'Recenter view']" "$APP_GROUP"
    else
        mkdir -p "$(dirname "$SELF_DESK")"
        cat > "$SELF_DESK" <<EOF
[Desktop Entry]
Type=Application
Name=Sony Head Tracker: Recenter view
Comment=Recenter the head tracker (look forward from your current pose)
Exec=$RECENTER
Icon=view-restore
Terminal=false
X-KDE-GlobalAccel-CommandShortcut=true
EOF
        printf "['%s.desktop', '_launch', 'Sony Head Tracker: Recenter view', 'Sony Head Tracker: Recenter view']" "$ID"
    fi
}

# Convert the key string produced by the GTK capture button (for example F9 or
# Meta+Ctrl+F9) into Qt::Key | Qt::KeyboardModifier. KGlobalAccel stores a
# QKeySequence as *four* integers. A one-integer setShortcutKeys payload is not
# a valid QKeySequence and has caused Plasma to disconnect in the past.
kde_key_code() {
    local key="$1" main part code=0 mods=0
    local -a parts
    IFS='+' read -r -a parts <<< "$key"
    [ "${#parts[@]}" -gt 0 ] || return 1
    main="${parts[${#parts[@]}-1]}"
    for part in "${parts[@]:0:${#parts[@]}-1}"; do
        case "${part,,}" in
            shift) mods=$((mods | 0x02000000)) ;;
            ctrl|control) mods=$((mods | 0x04000000)) ;;
            alt) mods=$((mods | 0x08000000)) ;;
            meta|super|win) mods=$((mods | 0x10000000)) ;;
            *) return 1 ;;
        esac
    done
    main="${main^^}"
    case "$main" in
        [A-Z]) printf -v code '%d' "'$main" ;;
        [0-9]) code=$((10#$main)) ;;
        F[1-9]|F[12][0-9]|F3[0-5]) code=$((0x01000030 + ${main#F} - 1)) ;;
        ESC|ESCAPE) code=$((0x01000000)) ;;
        TAB) code=$((0x01000001)) ;;
        BACKSPACE) code=$((0x01000003)) ;;
        RETURN) code=$((0x01000004)) ;;
        ENTER) code=$((0x01000005)) ;;
        INSERT) code=$((0x01000006)) ;;
        DELETE) code=$((0x01000007)) ;;
        HOME) code=$((0x01000010)) ;;
        END) code=$((0x01000011)) ;;
        PAGE_UP|PAGEUP|PRIOR) code=$((0x01000016)) ;;
        PAGE_DOWN|PAGEDOWN|NEXT) code=$((0x01000017)) ;;
        LEFT) code=$((0x01000012)) ;;
        UP) code=$((0x01000013)) ;;
        RIGHT) code=$((0x01000014)) ;;
        DOWN) code=$((0x01000015)) ;;
        SPACE) code=$((0x20)) ;;
        PLUS) code=$((0x2b)) ;;
        MINUS) code=$((0x2d)) ;;
        EQUAL) code=$((0x3d)) ;;
        COMMA) code=$((0x2c)) ;;
        PERIOD) code=$((0x2e)) ;;
        SLASH) code=$((0x2f)) ;;
        SEMICOLON) code=$((0x3b)) ;;
        APOSTROPHE) code=$((0x27)) ;;
        BRACKETLEFT) code=$((0x5b)) ;;
        BRACKETRIGHT) code=$((0x5d)) ;;
        BACKSLASH) code=$((0x5c)) ;;
        GRAVE) code=$((0x60)) ;;
        *) return 1 ;;
    esac
    printf '%u\n' "$((code | mods))"
}

kde_dbus_xml() {
    gdbus introspect --session --dest org.kde.kglobalaccel --object-path /kglobalaccel --xml 2>/dev/null
}

kde_dbus_method() {
    local method="$1"
    kde_dbus_xml | grep -q "method name=\"$method\""
}

kde_shortcut_keys() {
    local action="$1"
    gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
        --method org.kde.KGlobalAccel.shortcutKeys "$action" 2>/dev/null
}

kde_key_is_live() {
    local action="$1" code="$2" keys owner
    keys=$(kde_shortcut_keys "$action") || return 1
    # First ensure the service reports the exact four-slot sequence, then ask
    # which action owns its first key. Both are read-only calls.
    [[ "$keys" == *"[$code, 0, 0, 0]"* ]] || return 1
    owner=$(gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
        --method org.kde.KGlobalAccel.action "$code" 2>/dev/null) || return 1
    [[ "$owner" == *"'recenter'"* || "$owner" == *"'_launch'"* ]]
}

kde_key_is_available() {
    local action="$1" code="$2" owner
    owner=$(gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
        --method org.kde.KGlobalAccel.action "$code" 2>/dev/null) || return 1
    # An unassigned key returns an empty action list. Reassigning this app's own
    # key is also safe; any other owner is left alone for the user to resolve in
    # System Settings.
    [[ "$owner" == *"[]"* || "$owner" == *"'recenter'"* || "$owner" == *"'_launch'"* ]]
}

kde_set_live_key() {
    local action="$1" code="$2"
    if kde_dbus_method setShortcutKeys; then
        # a(ai): one QKeySequence, represented by exactly four Qt key codes.
        gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
            --method org.kde.KGlobalAccel.setShortcutKeys "$action" \
            "[([$code, 0, 0, 0],)]" 4 >/dev/null 2>&1
    elif kde_dbus_method setShortcut; then
        # Compatibility with older KGlobalAccel services (ai rather than a(ai)).
        gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
            --method org.kde.KGlobalAccel.setShortcut "$action" "[$code]" 4 >/dev/null 2>&1
    else
        return 1
    fi
}

kde_clear_live_key() {
    local action="$1"
    if kde_dbus_method setShortcutKeys; then
        gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
            --method org.kde.KGlobalAccel.setShortcutKeys "$action" \
            "[([0, 0, 0, 0],)]" 4 >/dev/null 2>&1
    elif kde_dbus_method setShortcut; then
        gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
            --method org.kde.KGlobalAccel.setShortcut "$action" "[0]" 4 >/dev/null 2>&1
    else
        return 1
    fi
}

kde_enable() {
    local key="$1" code action
    code=$(kde_key_code "$key") || { echo "error: unsupported KDE shortcut '$key'" >&2; return 1; }
    action=$(kde_action_id)
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    kde_key_is_available "$action" "$code" || { echo "error: shortcut '$key' is already in use" >&2; return 1; }
    kde_set_live_key "$action" "$code" || return 1
    kde_key_is_live "$action" "$code"
}
kde_disable() {
    local action
    action=$(kde_action_id)
    kde_clear_live_key "$action" || return 1
    rm -f "$SELF_DESK"
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
}
kde_status() {
    local action keys v
    action=$(kde_action_id)
    keys=$(kde_shortcut_keys "$action" || true)
    # Do not claim a config-file shortcut is active. The service has to report a
    # non-zero four-slot sequence for this action.
    [[ "$keys" =~ \[[1-9][0-9]*,\ 0,\ 0,\ 0\] ]] || { echo "disabled"; return; }
    v=$(kreadconfig6 --file kglobalshortcutsrc --group services --group "$APP_GROUP" --key recenter 2>/dev/null || true)
    [ -z "$v" ] && v=$(kreadconfig6 --file kglobalshortcutsrc --group services --group "${ID}.desktop" --key _launch 2>/dev/null || true)
    echo "enabled:${v%%,*}"
}

# Translate a captured combo ("Meta+C", "F9", "Ctrl+Alt+F9") to a GTK accelerator
# ("<Super>c", "F9", "<Control><Alt>F9") for GNOME/XFCE.
gtk_accel_key() {
    local k="$1" out="" main
    IFS='+' read -ra parts <<< "$k"; main="${parts[-1]}"
    for m in "${parts[@]:0:${#parts[@]}-1}"; do
        case "${m,,}" in
            meta|super|win) out="$out<Super>";;
            ctrl|control)   out="$out<Control>";;
            alt)            out="$out<Alt>";;
            shift)          out="$out<Shift>";;
        esac
    done
    [ ${#main} -eq 1 ] && main="${main,,}"
    echo "$out$main"
}

# ---- GNOME / Cinnamon (gsettings) ------------------------------------------
GNOME_SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
GNOME_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/${ID}/"
gnome_enable() {
    local key="$1"
    local list; list=$(python3 - "$GNOME_PATH" "$GNOME_SCHEMA" <<'PY'
import subprocess, sys, ast
path, schema = sys.argv[1], sys.argv[2]
cur = subprocess.check_output(["gsettings","get",schema,"custom-keybindings"]).decode().strip()
try: lst = ast.literal_eval(cur)
except Exception: lst = []
if not isinstance(lst, list): lst = []
if path not in lst: lst.append(path)
print("[" + ", ".join("'%s'" % p for p in lst) + "]")
PY
)
    gsettings set "$GNOME_SCHEMA" custom-keybindings "$list"
    gsettings set "${GNOME_SCHEMA}.custom-keybinding:${GNOME_PATH}" name "$NAME"
    gsettings set "${GNOME_SCHEMA}.custom-keybinding:${GNOME_PATH}" command "$RECENTER"
    gsettings set "${GNOME_SCHEMA}.custom-keybinding:${GNOME_PATH}" binding "$(gtk_accel_key "$key")"
}
gnome_disable() {
    python3 - "$GNOME_PATH" "$GNOME_SCHEMA" <<'PY'
import subprocess, sys, ast
path, schema = sys.argv[1], sys.argv[2]
cur = subprocess.check_output(["gsettings","get",schema,"custom-keybindings"]).decode().strip()
try: lst = ast.literal_eval(cur)
except Exception: lst = []
lst = [p for p in lst if p != path]
subprocess.run(["gsettings","set",schema,"custom-keybindings",
                "[" + ", ".join("'%s'" % p for p in lst) + "]"])
PY
    gsettings reset-recursively "${GNOME_SCHEMA}.custom-keybinding:${GNOME_PATH}" 2>/dev/null || true
}
gnome_status() {
    local b; b=$(gsettings get "${GNOME_SCHEMA}.custom-keybinding:${GNOME_PATH}" binding 2>/dev/null | tr -d "'" || true)
    [ -n "$b" ] && [ "$b" != "@as []" ] && echo "enabled:$b" || echo "disabled"
}

# ---- XFCE (xfconf) ----------------------------------------------------------
xfce_enable() {
    local key p; key="$1"; p="/commands/custom/$(gtk_accel_key "$key")"
    xfconf-query -c xfce4-keyboard-shortcuts -p "$p" -n -t string -s "$RECENTER" 2>/dev/null \
        || xfconf-query -c xfce4-keyboard-shortcuts -p "$p" -t string -s "$RECENTER"
}
xfce_disable() {
    # Remove any custom command bindings that point at our recenter command.
    while IFS= read -r p; do
        [ -n "$p" ] && xfconf-query -c xfce4-keyboard-shortcuts -p "$p" -r 2>/dev/null || true
    done < <(xfconf-query -c xfce4-keyboard-shortcuts -l -v 2>/dev/null | awk -v c="$RECENTER" '$0 ~ c {print $1}')
}
xfce_status() {
    local p; p=$(xfconf-query -c xfce4-keyboard-shortcuts -l -v 2>/dev/null | awk -v c="$RECENTER" '$0 ~ c {print $1; exit}')
    [ -n "$p" ] && echo "enabled:${p##*/}" || echo "disabled"
}

# ---- Hyprland / Sway (managed block in the config + live apply) -------------
BEGIN="# >>> sony-head-tracker recenter >>>"
END="# <<< sony-head-tracker recenter <<<"
strip_block() { [ -f "$1" ] && sed -i "/$BEGIN/,/$END/d" "$1" || true; }

hypr_key() {  # "Meta+C" -> "SUPER, C"   "F9" -> ", F9"
    local k="$1" mods="" main
    IFS='+' read -ra parts <<< "$k"; main="${parts[-1]}"
    for m in "${parts[@]:0:${#parts[@]}-1}"; do
        case "${m,,}" in meta|super|win) mods="$mods SUPER";; ctrl|control) mods="$mods CTRL";; alt) mods="$mods ALT";; shift) mods="$mods SHIFT";; esac
    done
    echo "$(echo "$mods" | xargs echo -n | tr ' ' ' '), $main"
}
hypr_conf() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.conf"; }
hypr_enable() {
    local key="$1" conf; conf=$(hypr_conf); mkdir -p "$(dirname "$conf")"; touch "$conf"
    strip_block "$conf"
    { echo "$BEGIN"; echo "bind = $(hypr_key "$key"), exec, $RECENTER"; echo "$END"; } >> "$conf"
    hyprctl keyword bind "$(hypr_key "$key"), exec, $RECENTER" >/dev/null 2>&1 || true
}
hypr_disable() { strip_block "$(hypr_conf)"; hyprctl reload >/dev/null 2>&1 || true; }
hypr_status() { grep -q "$BEGIN" "$(hypr_conf)" 2>/dev/null && echo "enabled:configured" || echo "disabled"; }

sway_key() {  # "Meta+C" -> "Mod4+c"   "F9" -> "F9"
    local k="$1"; k="${k//Meta/Mod4}"; k="${k//Super/Mod4}"; k="${k//Ctrl/Control}"; echo "$k"
}
sway_conf() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/sway/config"; }
sway_enable() {
    local key="$1" conf; conf=$(sway_conf); mkdir -p "$(dirname "$conf")"; touch "$conf"
    strip_block "$conf"
    { echo "$BEGIN"; echo "bindsym $(sway_key "$key") exec $RECENTER"; echo "$END"; } >> "$conf"
    swaymsg "bindsym $(sway_key "$key") exec $RECENTER" >/dev/null 2>&1 || true
}
sway_disable() { strip_block "$(sway_conf)"; swaymsg reload >/dev/null 2>&1 || true; }
sway_status() { grep -q "$BEGIN" "$(sway_conf)" 2>/dev/null && echo "enabled:configured" || echo "disabled"; }

# ---- dispatch ---------------------------------------------------------------
de=$(detect_de); mode=$(mode_for "$de")
case "${1:-}" in
  detect)  echo "de=$de mode=$mode" ;;
  explain) explain ;;
  command) echo "$RECENTER" ;;
  status)
    case "$de" in
      kde) [ "$mode" = auto ] && kde_status || echo "disabled" ;;
      gnome|cinnamon) [ "$mode" = auto ] && gnome_status || echo "disabled" ;;
      xfce) [ "$mode" = auto ] && xfce_status || echo "disabled" ;;
      hyprland) [ "$mode" != manual ] && hypr_status || echo "disabled" ;;
      sway) [ "$mode" != manual ] && sway_status || echo "disabled" ;;
      *) echo "disabled" ;;
    esac ;;
  enable)
    [ -f "$RECENTER" ] || { echo "error: recenter.sh not found next to this script" >&2; exit 1; }
    key="${2:-F9}"
    case "$de" in
      kde)            [ "$mode" = auto ]   && { kde_enable "$key"; echo "enabled:$key"; }   || { echo "manual"; exit 3; } ;;
      gnome|cinnamon) [ "$mode" = auto ]   && { gnome_enable "$key"; echo "enabled:$key"; } || { echo "manual"; exit 3; } ;;
      xfce)           [ "$mode" = auto ]   && { xfce_enable "$key"; echo "enabled:$key"; }  || { echo "manual"; exit 3; } ;;
      hyprland)       [ "$mode" = assist ] && { hypr_enable "$key"; echo "enabled:$key"; }  || { echo "manual"; exit 3; } ;;
      sway)           [ "$mode" = assist ] && { sway_enable "$key"; echo "enabled:$key"; }  || { echo "manual"; exit 3; } ;;
      *)              echo "manual"; exit 3 ;;
    esac ;;
  disable)
    case "$de" in
      kde) kde_disable ;;
      gnome|cinnamon) gnome_disable ;;
      xfce) xfce_disable ;;
      hyprland) hypr_disable ;;
      sway) sway_disable ;;
    esac
    echo "disabled" ;;
  *) echo "usage: setup-recenter-shortcut.sh detect|explain|status|enable [KEY]|disable|command" >&2; exit 2 ;;
esac
