#!/usr/bin/env python3
"""
Sony Head Tracker - GTK4 / libadwaita desktop front end.

A friendly, clickable wrapper around the `sony-head-tracker` CLI for people who
don't want a terminal. It runs the CLI's `probe` and `bridge` commands, reads the
JSON telemetry the bridge emits on UDP, and shows a live attitude indicator plus
yaw/pitch/roll. It does not link the C++ code, so it stays decoupled from the build.

Requires: python-gobject, gtk4, libadwaita. Run with `make gui` or directly.
"""
from __future__ import annotations

import json
import math
import os
import re
import shutil
import socket
import subprocess
import threading
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk, Gdk  # noqa: E402

APP_ID = "io.github.sonyheadtracker"
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
CONFIG_PATH = Path(GLib.get_user_config_dir()) / "sony-head-tracker" / "gui.json"


def _data_dir() -> Path:
    """Directory holding scripts/ and extras/. When installed system-wide the GUI
    script sits at the data root (e.g. /usr/share/sony-head-tracker/) with those
    beside it; in a repo checkout gui/ is one level below that root."""
    if (SCRIPT_DIR / "scripts").is_dir():
        return SCRIPT_DIR
    return REPO_ROOT


DATA_DIR = _data_dir()
SCRIPTS_DIR = DATA_DIR / "scripts"
EXTRAS_DIR = DATA_DIR / "extras"

KEYS = ("yaw", "pitch", "roll")

DEFAULTS = {
    "port": 4242,
    "axis_map": "YXZ",
    "invert_x": True,
    "invert_y": False,
    "invert_z": True,
    "smoothing": 0.18,
    # Final Euler-space correction the bridge applies live (identity by default, so
    # it changes nothing until Calibrate runs). out_sign flips Yaw/Pitch/Roll;
    # out_src reassigns which base axis feeds each output. Sent over the control
    # socket, so changing it never restarts the stream.
    "out_src": [0, 1, 2],
    "out_sign": [1, 1, -1],  # yaw normal, pitch normal, roll inverted (default)
    "auto_start": False,     # start tracking automatically once the headset is ready
    "level_output": False,   # experimental: world-frame output (cancels mounting tilt)
}


def find_tracker_binary() -> str | None:
    for cand in (
        os.environ.get("SONY_HEAD_TRACKER_BIN"),
        str(REPO_ROOT / "build" / "sony-head-tracker"),
        shutil.which("sony-head-tracker"),
    ):
        if cand and Path(cand).is_file() and os.access(cand, os.X_OK):
            return cand
    return None


def load_config() -> dict:
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    except Exception:
        pass
    return cfg


def save_config(cfg: dict) -> None:
    try:
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(json.dumps(cfg, indent=2))
    except Exception:
        pass


def steam_roots() -> list[Path]:
    roots: list[Path] = []
    for r in ("~/.local/share/Steam", "~/.steam/steam", "~/.steam/root",
              "~/.var/app/com.valvesoftware.Steam/data/Steam"):
        p = Path(r).expanduser()
        if (p / "steamapps").is_dir():
            rp = p.resolve()
            if rp not in roots:
                roots.append(rp)
    return roots


def steam_libraries() -> list[Path]:
    libs: list[Path] = []
    for root in steam_roots():
        if root not in libs:
            libs.append(root)
        vdf = root / "steamapps" / "libraryfolders.vdf"
        try:
            for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text()):
                p = Path(m.group(1))
                if (p / "steamapps").is_dir() and p not in libs:
                    libs.append(p)
        except Exception:
            pass
    return libs


_TOOL_APPIDS = {"228980"}  # Steamworks Common Redistributables (not a game)


def list_proton_games() -> list[tuple[str, str]]:
    """Return (appid, name) for installed Steam games that run under Proton (have a
    compatdata prefix), so the user can pick one instead of typing an AppID."""
    games: dict[str, str] = {}
    for lib in steam_libraries():
        sa = lib / "steamapps"
        try:
            manifests = list(sa.glob("appmanifest_*.acf"))
        except Exception:
            continue
        for acf in manifests:
            try:
                text = acf.read_text(errors="ignore")
            except Exception:
                continue
            aid = re.search(r'"appid"\s+"(\d+)"', text)
            nm = re.search(r'"name"\s+"([^"]+)"', text)
            if not aid or not nm:
                continue
            appid, name = aid.group(1), nm.group(1)
            if appid in _TOOL_APPIDS or appid in games:
                continue
            if "Proton" in name or "Steam Linux Runtime" in name:
                continue
            if (sa / "compatdata" / appid / "pfx").is_dir():
                games[appid] = name
    return sorted(games.items(), key=lambda g: g[1].lower())


def add_escape_to_close(window):
    """Close `window` when Escape is pressed (Adw.Window doesn't do this itself)."""
    ctrl = Gtk.EventControllerKey()

    def on_key(_c, keyval, _keycode, _state):
        if keyval == Gdk.KEY_Escape:
            window.close()
            return True
        return False

    ctrl.connect("key-pressed", on_key)
    window.add_controller(ctrl)


def shortest_angle_lerp(current: float, target: float, t: float) -> float:
    """Interpolate degrees along the shortest path (handles the +/-180 wrap)."""
    delta = (target - current + 180.0) % 360.0 - 180.0
    return current + delta * t


class AttitudeIndicator(Gtk.DrawingArea):
    """An artificial-horizon widget: roll rotates the horizon, pitch slides it,
    yaw is shown as a heading. Fixed centre reticle. Cairo-drawn, no assets."""

    def __init__(self):
        super().__init__()
        self.set_content_width(360)
        self.set_content_height(300)
        self.set_hexpand(True)
        self.set_vexpand(True)
        self.yaw = 0.0
        self.pitch = 0.0
        self.roll = 0.0
        self.active = False
        self.set_draw_func(self._draw)

    def _draw(self, area, cr, width, height, *_):
        radius = 18
        self._rounded_rect(cr, 0, 0, width, height, radius)
        cr.clip()

        if not self.active:
            cr.set_source_rgb(0.13, 0.14, 0.17)
            cr.paint()
            cr.set_source_rgba(1, 1, 1, 0.35)
            cr.select_font_face("sans-serif", 0, 0)
            cr.set_font_size(15)
            text = "Not tracking"
            ext = cr.text_extents(text)
            cr.move_to(width / 2 - ext.width / 2, height / 2)
            cr.show_text(text)
            return

        cx, cy = width / 2, height / 2
        pitch_px_per_deg = height / 70.0

        cr.save()
        cr.translate(cx, cy)
        # Display-only: tilt the horizon the intuitive way for a head tilt. This
        # does not affect the values sent to the game; it is purely the on-screen
        # artificial-horizon feedback.
        cr.rotate(math.radians(self.roll))
        cr.translate(0, self.pitch * pitch_px_per_deg)

        big = max(width, height) * 2.4
        # Sky
        sky = self._gradient(0, -big, 0, 0, (0.15, 0.45, 0.75), (0.42, 0.68, 0.92))
        cr.set_source(sky)
        cr.rectangle(-big, -big, 2 * big, big)
        cr.fill()
        # Ground
        ground = self._gradient(0, 0, 0, big, (0.36, 0.26, 0.15), (0.20, 0.13, 0.07))
        cr.set_source(ground)
        cr.rectangle(-big, 0, 2 * big, big)
        cr.fill()
        # Horizon line
        cr.set_source_rgb(1, 1, 1)
        cr.set_line_width(2)
        cr.move_to(-big, 0)
        cr.line_to(big, 0)
        cr.stroke()
        # Pitch ladder
        cr.set_line_width(1.4)
        cr.select_font_face("sans-serif", 0, 0)
        cr.set_font_size(11)
        for deg in range(-60, 61, 10):
            if deg == 0:
                continue
            y = -deg * pitch_px_per_deg
            half = 34 if deg % 20 == 0 else 20
            cr.set_source_rgba(1, 1, 1, 0.85)
            cr.move_to(-half, y)
            cr.line_to(half, y)
            cr.stroke()
            if deg % 20 == 0:
                label = str(abs(deg))
                cr.move_to(half + 6, y + 4)
                cr.show_text(label)
                cr.move_to(-half - 6 - cr.text_extents(label).width, y + 4)
                cr.show_text(label)

        # Landmarks (trees) on the horizon: they scroll horizontally as you yaw, so
        # left/right head movement is obvious. Placed at fixed world angles.
        fov = 90.0
        px_per_deg = width / fov
        for ang in range(0, 360, 15):
            d = ((ang - self.yaw + 180) % 360) - 180
            if abs(d) > fov / 2 + 6:
                continue
            x = d * px_per_deg
            h = 15 + 5 * ((ang // 15) % 3)
            cr.set_source_rgb(0.30, 0.21, 0.12)
            cr.rectangle(x - 1.3, -h * 0.30, 2.6, h * 0.30)
            cr.fill()
            cr.set_source_rgb(0.16, 0.47, 0.22)
            cr.move_to(x, -h)
            cr.line_to(x - h * 0.42, -h * 0.26)
            cr.line_to(x + h * 0.42, -h * 0.26)
            cr.close_path()
            cr.fill()
        cr.restore()

        # Fixed centre reticle (amber)
        cr.set_source_rgb(0.96, 0.72, 0.24)
        cr.set_line_width(3)
        cr.move_to(cx - 46, cy)
        cr.line_to(cx - 16, cy)
        cr.move_to(cx + 16, cy)
        cr.line_to(cx + 46, cy)
        cr.move_to(cx, cy - 16)
        cr.line_to(cx, cy - 4)
        cr.stroke()
        cr.arc(cx, cy, 3.5, 0, 2 * math.pi)
        cr.fill()

        # Roll arc + pointer at top
        cr.set_source_rgba(1, 1, 1, 0.9)
        cr.set_line_width(2)
        arc_r = min(width, height) / 2 - 14
        cr.arc(cx, cy, arc_r, math.radians(-125), math.radians(-55))
        cr.stroke()
        for tick in (-60, -45, -30, -15, 0, 15, 30, 45, 60):
            a = math.radians(-90 + tick)
            r1 = arc_r
            r2 = arc_r - (10 if tick == 0 else 6)
            cr.move_to(cx + r1 * math.cos(a), cy + r1 * math.sin(a))
            cr.line_to(cx + r2 * math.cos(a), cy + r2 * math.sin(a))
            cr.stroke()
        # roll pointer (rotates with roll; same display-only sign as the horizon)
        a = math.radians(-90 - self.roll)
        cr.set_source_rgb(0.96, 0.72, 0.24)
        pr = arc_r - 12
        cr.move_to(cx + pr * math.cos(a), cy + pr * math.sin(a))
        cr.line_to(cx + (pr - 9) * math.cos(a - 0.05), cy + (pr - 9) * math.sin(a - 0.05))
        cr.line_to(cx + (pr - 9) * math.cos(a + 0.05), cy + (pr - 9) * math.sin(a + 0.05))
        cr.close_path()
        cr.fill()

        # Heading (yaw) chip, top-centre
        heading = f"{(self.yaw + 360) % 360:05.1f}°"
        cr.select_font_face("monospace", 0, 1)
        cr.set_font_size(14)
        ext = cr.text_extents(heading)
        pad = 8
        bw, bh = ext.width + 2 * pad, 22
        bx, by = cx - bw / 2, 8
        cr.set_source_rgba(0, 0, 0, 0.45)
        self._rounded_rect(cr, bx, by, bw, bh, 8)
        cr.fill()
        cr.set_source_rgb(1, 1, 1)
        cr.move_to(cx - ext.width / 2, by + bh - 6)
        cr.show_text(heading)

    @staticmethod
    def _gradient(x0, y0, x1, y1, c0, c1):
        import cairo

        g = cairo.LinearGradient(x0, y0, x1, y1)
        g.add_color_stop_rgb(0, *c0)
        g.add_color_stop_rgb(1, *c1)
        return g

    @staticmethod
    def _rounded_rect(cr, x, y, w, h, r):
        cr.new_sub_path()
        cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
        cr.close_path()


class TrackerWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Sony Head Tracker")
        self.set_default_size(440, 640)
        self.cfg = load_config()
        self.binary = find_tracker_binary()
        self.proc: subprocess.Popen | None = None
        self.sock: socket.socket | None = None
        self.tick_id = 0
        self.target = {"yaw": 0.0, "pitch": 0.0, "roll": 0.0, "pps": 0.0, "device": None}
        self.last_packet_time = 0.0
        self._probing = False
        self._ready = False
        self._auto_started = False  # so auto-start fires once, not on every rescan
        self._apply_id = 0  # debounce timer for live settings changes
        self._last_hid_nudge = 0.0  # rate-limit the auto Bluetooth HID connect
        self._hid_nudging = False

        self._build_ui()
        # Never leave an orphaned bridge process or a bound UDP port behind.
        self.connect("close-request", self._on_close_request)
        # Escape dismisses a shown banner notification (without closing the app).
        esc = Gtk.EventControllerKey()
        esc.connect("key-pressed", self._on_main_key)
        self.add_controller(esc)
        self._refresh_device()
        # Keep an eye out for the headset appearing/disappearing while idle, so the
        # user never has to click anything to re-detect it.
        GLib.timeout_add_seconds(4, self._auto_rescan)

    def _auto_rescan(self):
        if not self.proc and not self._probing:
            self._refresh_device()
        return True

    # ---- UI construction ---------------------------------------------------
    def _build_ui(self):
        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        menu_btn = Gtk.MenuButton(icon_name="open-menu-symbolic")
        menu = Gio.Menu()
        menu.append("Reconnect head tracker", "app.reconnect_hid")
        menu.append("Grant device access", "app.grant")
        menu.append("Install OpenTrack", "app.install_opentrack")
        menu.append("About", "app.about")
        menu_btn.set_menu_model(menu)
        header.pack_end(menu_btn)
        settings_btn = Gtk.Button(icon_name="emblem-system-symbolic", tooltip_text="Settings")
        settings_btn.connect("clicked", self._open_settings)
        header.pack_end(settings_btn)
        toolbar.add_top_bar(header)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        content.set_margin_top(14)
        content.set_margin_bottom(18)
        content.set_margin_start(16)
        content.set_margin_end(16)

        self.banner = Adw.Banner(revealed=False)
        self.banner.connect("button-clicked", self._on_banner_action)
        content.append(self.banner)

        # Status pill row
        self.status_icon = Gtk.Image(icon_name="content-loading-symbolic")
        self.status_label = Gtk.Label(label="Checking...", xalign=0)
        self.status_label.add_css_class("title-4")
        pill = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        pill.append(self.status_icon)
        pill.append(self.status_label)
        content.append(pill)

        # Attitude indicator card
        self.attitude = AttitudeIndicator()
        card = Gtk.Frame()
        card.add_css_class("card")
        card.set_child(self.attitude)
        content.append(card)

        # Numeric YPR readouts
        grid = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10, homogeneous=True)
        self.val_labels = {}
        for key, name in (("yaw", "Yaw"), ("pitch", "Pitch"), ("roll", "Roll")):
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            box.add_css_class("card")
            box.set_margin_top(2)
            v = Gtk.Label(label="0.0°")
            v.add_css_class("title-1")
            v.set_margin_top(8)
            n = Gtk.Label(label=name)
            n.add_css_class("dim-label")
            n.set_margin_bottom(8)
            box.append(v)
            box.append(n)
            self.val_labels[key] = v
            grid.append(box)
        content.append(grid)

        self.pps_label = Gtk.Label(label="")
        self.pps_label.add_css_class("dim-label")
        content.append(self.pps_label)

        content.append(Gtk.Box(vexpand=True))  # spacer

        # Action buttons
        self.start_btn = Gtk.Button(label="Start tracking")
        self.start_btn.add_css_class("suggested-action")
        self.start_btn.add_css_class("pill")
        self.start_btn.set_size_request(-1, 44)
        self.start_btn.connect("clicked", self._toggle_tracking)
        content.append(self.start_btn)

        self.recenter_btn = Gtk.Button(label="Recenter view")
        self.recenter_btn.add_css_class("pill")
        self.recenter_btn.set_tooltip_text("Make your current head position the new forward (0, 0)")
        self.recenter_btn.connect("clicked", self._on_recenter)
        content.append(self.recenter_btn)

        self.cal_btn = Gtk.Button(label="Calibrate axes")
        self.cal_btn.add_css_class("pill")
        self.cal_btn.set_tooltip_text("Guided setup so your head movements map correctly")
        self.cal_btn.connect("clicked", lambda _b: self._open_calibration())
        content.append(self.cal_btn)

        self.ot_btn = Gtk.Button(label="Set up a game…")
        self.ot_btn.add_css_class("pill")
        self.ot_btn.set_tooltip_text("Configure head tracking for a Steam/Proton or native game")
        self.ot_btn.connect("clicked", lambda _b: SetupGameDialog(self).present())
        content.append(self.ot_btn)

        toolbar.set_content(content)
        self.set_content(toolbar)

        if not self.binary:
            self._set_status("error", "sony-head-tracker not found. Run `make` first.")
            self.start_btn.set_sensitive(False)

    # ---- Device probing ----------------------------------------------------
    def _set_status(self, kind: str, text: str):
        icons = {
            "ok": "emblem-ok-symbolic",
            "error": "dialog-error-symbolic",
            "warn": "dialog-warning-symbolic",
            "busy": "content-loading-symbolic",
            "live": "media-record-symbolic",
        }
        self.status_icon.set_from_icon_name(icons.get(kind, "content-loading-symbolic"))
        self.status_label.set_label(text)

    def _refresh_device(self):
        if not self.binary or self._probing:
            return
        self._probing = True
        if not self._ready:
            self._set_status("busy", "Looking for your headset...")

        def worker():
            try:
                res = subprocess.run(
                    [self.binary, "probe"], capture_output=True, text=True, timeout=15
                )
                out = (res.stdout or "") + (res.stderr or "")
                code = res.returncode
            except Exception as exc:  # noqa: BLE001
                out, code = str(exc), 1
            GLib.idle_add(self._probe_done, code, out)

        threading.Thread(target=worker, daemon=True).start()

    def _probe_done(self, code: int, out: str):
        self._probing = False
        m = re.search(r"head tracker on '([^']+)'", out)
        name = m.group(1) if m else None
        verified = "Verified Android head tracker on" in out

        if verified and name:  # detected and accessible
            self._ready = True
            self.banner.set_revealed(False)
            self._set_status("ok", f"Ready: {name}")
            self.start_btn.set_sensitive(True)
            # Start automatically once, if the user opted in (never fights a manual stop).
            if self.cfg.get("auto_start") and not self.proc and not self._auto_started:
                self._auto_started = True
                self._start_tracking()
            return False

        self._ready = False
        self.start_btn.set_sensitive(False)
        if name:  # detected but no device access yet (one-time grant)
            self._set_status("warn", f"Found {name}, access needed")
            self.banner.set_title(f"{name} found. Grant one-time access to start tracking.")
            self.banner.set_button_label("Grant access")
            self._banner_action = "grant"
            self.banner.set_revealed(True)
        elif "permission denied" in out.lower():
            self._set_status("warn", "Permission needed to read the headset")
            self.banner.set_title("The app needs permission to read your headset.")
            self.banner.set_button_label("Grant access")
            self._banner_action = "grant"
            self.banner.set_revealed(True)
        else:  # nothing found
            self._set_status("warn", "No head tracker found")
            self.banner.set_title("No head tracker found. Make sure your Sony headset is connected to this computer.")
            self.banner.set_button_label("Reconnect headset")
            self._banner_action = "reconnect_hid"
            self.banner.set_revealed(True)
            # Sony headsets often connect audio only; nudge BlueZ to attach the
            # head-tracker HID profile, then re-scan. Rate-limited so the idle
            # rescan loop does not spam it.
            self._nudge_hid()
        return False

    def _on_banner_action(self, _banner):
        action = getattr(self, "_banner_action", "recheck")
        if action == "grant":
            self.grant_access()
        elif action == "reconnect_hid":
            self._nudge_hid(manual=True)
        else:
            self._refresh_device()

    # ---- Bluetooth HID connect ---------------------------------------------
    def _nudge_hid(self, manual: bool = False):
        """Ask BlueZ to connect the Sony headset's head-tracker HID profile (which
        it often leaves unconnected, so no /dev/hidraw node appears), then re-scan.
        Auto-called on a failed detection (rate-limited); also a manual action."""
        if self._hid_nudging:
            return
        now = time.monotonic()
        if not manual and now - self._last_hid_nudge < 12:
            return
        self._last_hid_nudge = now
        self._hid_nudging = True
        self._set_status("busy", "Connecting head tracker...")

        def worker():
            count = "0"
            try:
                r = subprocess.run([str(SCRIPTS_DIR / "connect-headset-hid.sh")],
                                   capture_output=True, text=True, timeout=15)
                count = (r.stdout or "0").strip()
            except Exception:  # noqa: BLE001
                pass
            GLib.idle_add(self._nudge_done, count, manual)

        threading.Thread(target=worker, daemon=True).start()

    def _nudge_done(self, count: str, manual: bool):
        self._hid_nudging = False
        try:
            n = int(count or "0")
        except ValueError:
            n = 0
        if manual and n == 0:
            self._toast("No connected Sony headset found. Connect it over Bluetooth, then try again.")
        # Give BlueZ a moment to create the hidraw node, then re-scan.
        GLib.timeout_add(1500, self._refresh_device)
        return False

    # ---- Tracking ----------------------------------------------------------
    def _toggle_tracking(self, _btn):
        if self.proc:
            self._stop_tracking()
        else:
            self._start_tracking()

    def _bridge_args(self) -> list[str]:
        args = [self.binary, "bridge", "--port", str(self.cfg["port"]),
                "--axis-map", self.cfg["axis_map"], "--smoothing", str(self.cfg["smoothing"])]
        inv = "".join(a for a, k in (("x", "invert_x"), ("y", "invert_y"), ("z", "invert_z")) if self.cfg[k])
        args += ["--invert", inv if inv else "none"]
        return args

    # ---- Live control (no restart) -----------------------------------------
    def _control(self, msg: str):
        # Send a control datagram to the running bridge (port + 3). Best-effort UDP.
        if not self.proc:
            return
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.sendto(msg.encode(), ("127.0.0.1", int(self.cfg["port"]) + 3))
            s.close()
        except OSError:
            pass

    def _control_apply(self):
        src = self.cfg.get("out_src", [0, 1, 2])
        sign = self.cfg.get("out_sign", [1, 1, 1])
        self._control(f"OUT {src[0]} {src[1]} {src[2]} {sign[0]} {sign[1]} {sign[2]} "
                      f"{self.cfg.get('smoothing', 0.18)}")

    def _control_level(self):
        self._control(f"LEVEL {1 if self.cfg.get('level_output') else 0}")

    def _push_control_once(self):
        self._control_apply()
        self._control_level()
        return False

    def _on_recenter(self, _btn):
        if not self.proc:
            self._toast("Start tracking first, then recenter.")
            return
        self._control("RECENTER")
        self._toast("View recentered. You're now looking forward.")

    # Spawn the bridge subprocess + JSON reader. Returns False on failure (and
    # leaves the UI to the caller). Reused by start and live-restart.
    def _spawn_stream(self) -> bool:
        json_port = int(self.cfg["port"]) + 1
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.sock.bind(("127.0.0.1", json_port))
            self.sock.setblocking(False)
        except OSError as exc:
            self.sock = None
            self._set_status("error", f"Cannot open UDP {json_port}: {exc}")
            return False
        try:
            self.proc = subprocess.Popen(
                self._bridge_args(), stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True
            )
        except Exception as exc:  # noqa: BLE001
            self._set_status("error", f"Could not start: {exc}")
            self._cleanup_socket()
            return False
        threading.Thread(target=self._watch_stderr, args=(self.proc,), daemon=True).start()
        if not self.tick_id:
            self.tick_id = GLib.timeout_add(16, self._tick)
        return True

    # Tear down the subprocess + socket + tick, without touching the UI state.
    def _teardown_stream(self):
        if self.tick_id:
            GLib.source_remove(self.tick_id)
            self.tick_id = 0
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except Exception:  # noqa: BLE001
                try:
                    self.proc.kill()
                except Exception:  # noqa: BLE001
                    pass
            self.proc = None
        self._cleanup_socket()

    def _start_tracking(self):
        if not self._spawn_stream():
            self._cleanup_socket()
            return
        self.attitude.active = True
        self.start_btn.set_label("Stop tracking")
        self.start_btn.remove_css_class("suggested-action")
        self.start_btn.add_css_class("destructive-action")
        self._set_status("live", "Tracking")
        # Push the saved axis correction once the bridge's control socket is up.
        GLib.timeout_add(2500, self._push_control_once)

    # Apply new settings to a running session by relaunching the bridge in place.
    def _restart_tracking(self):
        if not self.proc:
            return
        self._teardown_stream()
        self._spawn_stream()

    def _stop_tracking(self):
        self._teardown_stream()
        self.attitude.active = False
        self.attitude.queue_draw()
        self.start_btn.set_label("Start tracking")
        self.start_btn.remove_css_class("destructive-action")
        self.start_btn.add_css_class("suggested-action")
        self.pps_label.set_label("")
        self._refresh_device()

    def _cleanup_socket(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def _watch_stderr(self, proc):
        problem = None
        for line in proc.stderr:
            if "Permission denied" in line or "open failed" in line:
                problem = "permission"
        if problem == "permission":
            GLib.idle_add(self._on_permission_problem)

    def _on_permission_problem(self):
        if self.proc:
            self._stop_tracking()
        self._set_status("warn", "Permission needed to read the headset")
        self.banner.set_title("The app needs permission to read your headset.")
        self.banner.set_button_label("Grant access")
        self._banner_action = "grant"
        self.banner.set_revealed(True)
        return False

    def _tick(self):
        try:
            if self.sock:
                got = False
                while True:
                    try:
                        data, _ = self.sock.recvfrom(2048)
                    except (BlockingIOError, OSError):
                        break
                    got = True
                    self._ingest(data)
                if got:
                    self.last_packet_time = GLib.get_monotonic_time() / 1e6
            # Smoothly interpolate the displayed attitude toward the latest sample.
            a = self.attitude
            a.yaw = shortest_angle_lerp(a.yaw, self.target["yaw"], 0.25)
            a.pitch += (self.target["pitch"] - a.pitch) * 0.25
            a.roll += (self.target["roll"] - a.roll) * 0.25
            a.queue_draw()
            self.val_labels["yaw"].set_label(f"{self.target['yaw']:.1f}°")
            self.val_labels["pitch"].set_label(f"{self.target['pitch']:.1f}°")
            self.val_labels["roll"].set_label(f"{self.target['roll']:.1f}°")
            dev = self.target.get("device") or "headset"
            self.pps_label.set_label(f"{dev}  •  {self.target['pps']:.0f} packets/s")
        except Exception:  # never let a transient error kill the render loop
            pass
        return True

    def _ingest(self, data: bytes):
        try:
            obj = json.loads(data)
        except (ValueError, TypeError):
            return
        if not isinstance(obj, dict):
            return
        ypr = obj.get("yprDegrees")
        if isinstance(ypr, list) and len(ypr) == 3 and all(isinstance(v, (int, float)) for v in ypr):
            self.target["yaw"], self.target["pitch"], self.target["roll"] = (float(v) for v in ypr)
        pps = obj.get("packetsPerSecond")
        if isinstance(pps, (int, float)):
            self.target["pps"] = float(pps)
        dev = obj.get("device")
        if dev is None or isinstance(dev, str):
            self.target["device"] = dev

    # ---- Helpers -----------------------------------------------------------
    def grant_access(self):
        rule = EXTRAS_DIR / "70-sony-head-tracker.rules"
        if not rule.is_file():
            self._toast("udev rule not found in extras/")
            return
        cmd = ("cp '%s' /etc/udev/rules.d/ && udevadm control --reload-rules && "
               "udevadm trigger --subsystem-match=hidraw --action=add" % rule)

        def worker():
            try:
                r = subprocess.run(["pkexec", "sh", "-c", cmd], capture_output=True, text=True)
                ok = r.returncode == 0
            except Exception:  # noqa: BLE001
                ok = False
            GLib.idle_add(self._grant_done, ok)

        threading.Thread(target=worker, daemon=True).start()

    def _grant_done(self, ok: bool):
        if ok:
            # The udev ACL applies asynchronously; give it a moment, then re-probe.
            # This is a one-time step: once the rule is installed, no more prompts.
            self._set_status("busy", "Access granted, checking...")
            self.banner.set_revealed(False)
            GLib.timeout_add(1800, self._post_grant_recheck)
            self._grant_retries = 4
        else:
            self.banner.set_title("Could not grant access. You can still run the CLI with sudo.")
            self.banner.set_button_label("Re-check")
            self._banner_action = "recheck"
            self.banner.set_revealed(True)
        return False

    def _post_grant_recheck(self):
        # Re-probe a few times; if the headset was already connected before the rule
        # existed, it may need a reconnect for the ACL to land.
        self._refresh_device()
        self._grant_retries = getattr(self, "_grant_retries", 0) - 1
        if not self._ready and self._grant_retries > 0:
            GLib.timeout_add(1500, self._post_grant_recheck)
        elif not self._ready:
            self.banner.set_title("Almost there: unplug/reconnect the headset once to finish granting access.")
            self.banner.set_button_label("Re-check")
            self._banner_action = "recheck"
            self.banner.set_revealed(True)
        return False

    def _launch_opentrack(self, _btn):
        ot = shutil.which("opentrack")
        if ot:
            try:
                subprocess.Popen([ot])
                self._toast("OpenTrack launched. Use UDP over network input, port %d." % self.cfg["port"])
            except Exception as exc:  # noqa: BLE001
                self._toast(f"Could not launch OpenTrack: {exc}")
        else:
            self.install_opentrack()

    def install_opentrack(self):
        script = SCRIPTS_DIR / "install-opentrack.sh"
        if not script.is_file():
            self._toast("Install OpenTrack from your package manager.")
            return
        term = next((t for t in ("x-terminal-emulator", "kgx", "gnome-terminal",
                                 "konsole", "ptyxis", "alacritty", "kitty", "xterm")
                     if shutil.which(t)), None)
        if not term:
            self._toast(f"Run this in a terminal: bash {script}")
            return
        try:
            subprocess.Popen([term, "-e", "bash", str(script)])
        except Exception as exc:  # noqa: BLE001
            self._toast(f"Run this in a terminal: bash {script} ({exc})")

    def _toast(self, text: str):
        # Adw.ToastOverlay would be ideal; keep it simple with the banner.
        self.banner.set_title(text)
        self.banner.set_button_label("Dismiss")
        self._banner_action = "recheck"
        self.banner.set_revealed(True)

    # ---- Settings ----------------------------------------------------------
    def _open_settings(self, _btn):
        win = Adw.PreferencesWindow(transient_for=self, modal=True)
        add_escape_to_close(win)
        page = Adw.PreferencesPage()
        group = Adw.PreferencesGroup(title="Tracking")

        autostart = Adw.SwitchRow(title="Start tracking on launch",
                                  subtitle="Begin automatically once the headset is ready",
                                  active=bool(self.cfg.get("auto_start")))
        autostart.connect("notify::active", lambda r, _p: self._set_cfg("auto_start", r.get_active()))
        group.add(autostart)

        level = Adw.SwitchRow(title="Level compensation (experimental)",
                              subtitle="Stops looking up/down from adding roll. Recenter with "
                                       "your head level and forward after turning it on.",
                              active=bool(self.cfg.get("level_output")))
        level.connect("notify::active", lambda r, _p: self._set_cfg("level_output", r.get_active()))
        group.add(level)

        port_adj = Gtk.Adjustment(lower=1, upper=65534, step_increment=1, value=self.cfg["port"])
        port = Adw.SpinRow(title="UDP port", subtitle="JSON telemetry uses port + 1", adjustment=port_adj)
        port_adj.connect("value-changed", lambda a: self._set_cfg("port", int(a.get_value())))
        group.add(port)

        cal = Adw.ActionRow(title="Calibrate axes",
                            subtitle="Guided: move your head, it learns the mapping")
        cal.set_activatable(True)
        cal.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
        cal.connect("activated", lambda r: self._open_calibration())
        group.add(cal)

        for idx, label in ((0, "Invert Yaw (look left/right)"),
                           (1, "Invert Pitch (look up/down)"),
                           (2, "Invert Roll (tilt)")):
            inverted = self.cfg.get("out_sign", [1, 1, 1])[idx] < 0
            row = Adw.SwitchRow(title=label, active=inverted)
            row.connect("notify::active", lambda r, _p, i=idx: self._set_invert(i, r.get_active()))
            group.add(row)

        smooth_adj = Gtk.Adjustment(lower=0.01, upper=1.0, step_increment=0.01, value=self.cfg["smoothing"])
        smooth = Adw.SpinRow(title="Smoothing", subtitle="0.01 (sharp) to 1.0 (smooth)",
                             digits=2, adjustment=smooth_adj)
        smooth_adj.connect("value-changed", lambda a: self._set_cfg("smoothing", round(a.get_value(), 2)))
        group.add(smooth)

        page.add(group)

        # ---- Recenter shortcut (global) ------------------------------------
        # An app cannot grab a global key for itself on Wayland, so the recenter
        # command is registered with the desktop's own shortcut system. The helper
        # detects the desktop: KDE/GNOME/XFCE it sets up automatically, Hyprland/
        # Sway it edits the config and applies live, anything else falls back to
        # binding the command by hand.
        de, mode = self._shortcut_detect()
        sc = Adw.PreferencesGroup(
            title="Recenter shortcut",
            description=self._shortcut_explain() or
            "A key that recenters the view from inside any game.")
        cmd = str(SCRIPTS_DIR / "recenter.sh")
        if mode in ("auto", "assist"):
            enabled, key = self._shortcut_status()
            default_key = key if (enabled and key and key != "configured") else "F9"
            state = {"key": default_key, "capturing": False}

            sw = Adw.SwitchRow(title="Global shortcut",
                               subtitle="Recenter from any game, even fullscreen",
                               active=enabled)
            key_row = Adw.ActionRow(title="Shortcut", subtitle="Click, then press the key")
            cap = Gtk.Button(label=default_key, valign=Gtk.Align.CENTER)
            cap.add_css_class("pill")
            key_row.add_suffix(cap)
            key_row.set_activatable_widget(cap)

            def apply_now():
                if self._shortcut_set(True, state["key"]):
                    self._toast(f"Recenter bound to {state['key']}.")
                else:
                    sw.set_active(False)
                    self._toast("Could not set that key (it may already be in use). "
                                "Try another, or Set it manually below.")

            def on_switch(*_a):
                if sw.get_active():
                    apply_now()
                else:
                    self._shortcut_set(False, state["key"])

            sw.connect("notify::active", on_switch)

            def start_capture(_b):
                state["capturing"] = True
                cap.set_label("Press the key…")
                cap.add_css_class("suggested-action")

            cap.connect("clicked", start_capture)

            _MODS = ("Control_L", "Control_R", "Alt_L", "Alt_R", "Shift_L", "Shift_R",
                     "Super_L", "Super_R", "Meta_L", "Meta_R", "ISO_Level3_Shift", "")

            def on_capture_key(_c, keyval, _kc, mstate):
                if not state["capturing"]:
                    return False  # let Escape-to-close and others work normally
                name = Gdk.keyval_name(keyval) or ""
                if name in _MODS:
                    return True  # wait for a non-modifier key
                state["capturing"] = False
                cap.remove_css_class("suggested-action")
                if keyval == Gdk.KEY_Escape:
                    cap.set_label(state["key"])  # cancel, keep the old key
                    return True
                mods = []
                if mstate & Gdk.ModifierType.SUPER_MASK:
                    mods.append("Meta")
                if mstate & Gdk.ModifierType.CONTROL_MASK:
                    mods.append("Ctrl")
                if mstate & Gdk.ModifierType.ALT_MASK:
                    mods.append("Alt")
                if mstate & Gdk.ModifierType.SHIFT_MASK:
                    mods.append("Shift")
                main = name.upper() if len(name) == 1 else name
                state["key"] = "+".join(mods + [main])
                cap.set_label(state["key"])
                if sw.get_active():
                    apply_now()
                else:
                    sw.set_active(True)  # enabling applies the new key
                return True

            kc = Gtk.EventControllerKey()
            kc.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
            kc.connect("key-pressed", on_capture_key)
            win.add_controller(kc)

            sc.add(sw)
            sc.add(key_row)

        man = Adw.ActionRow(title="Set it manually",
                            subtitle="Open your desktop's keyboard shortcut settings")
        man.set_activatable(True)
        man.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
        man.connect("activated", lambda r: self._open_de_shortcuts(de))
        sc.add(man)

        cmd_row = Adw.ActionRow(title="Recenter command", subtitle=cmd)
        cmd_row.set_subtitle_selectable(True)
        copy = Gtk.Button(label="Copy", valign=Gtk.Align.CENTER)
        copy.add_css_class("flat")
        copy.connect("clicked", lambda _b: (
            Gdk.Display.get_default().get_clipboard().set(cmd),
            self._toast("Command copied. Bind it to a key in your desktop settings.")))
        cmd_row.add_suffix(copy)
        sc.add(cmd_row)
        page.add(sc)

        win.add(page)
        win.present()

    def _set_cfg(self, key, value):
        if self.cfg.get(key) == value:
            return
        self.cfg[key] = value
        save_config(self.cfg)
        if key in ("out_src", "out_sign", "smoothing"):
            # Applied live over the control socket: tracking never stops.
            self._control_apply()
        elif key == "level_output":
            self._control_level()
        elif self.proc and key == "port":
            # The port lives in the bridge command, so it needs a (debounced) restart.
            if self._apply_id:
                GLib.source_remove(self._apply_id)
            self._apply_id = GLib.timeout_add(500, self._apply_live)

    def _set_invert(self, idx, inverted):
        sign = list(self.cfg.get("out_sign", [1, 1, 1]))
        sign[idx] = -1 if inverted else 1
        self._set_cfg("out_sign", sign)

    def _open_calibration(self):
        if not self.proc:
            self._toast("Start tracking first, then open Calibrate.")
            return
        CalibrationDialog(self).present()

    # ---- Global recenter shortcut (desktop-aware) --------------------------
    def _shortcut_script(self):
        return str(SCRIPTS_DIR / "setup-recenter-shortcut.sh")

    def _shortcut_detect(self):
        """Return (desktop_id, mode) where mode is auto|assist|manual."""
        try:
            out = subprocess.run([self._shortcut_script(), "detect"],
                                 capture_output=True, text=True, timeout=10).stdout.strip()
        except Exception:
            return ("unknown", "manual")
        de, mode = "unknown", "manual"
        for tok in out.split():
            if tok.startswith("de="):
                de = tok[3:]
            elif tok.startswith("mode="):
                mode = tok[5:]
        return (de, mode)

    def _shortcut_explain(self):
        try:
            out = subprocess.run([self._shortcut_script(), "explain"],
                                 capture_output=True, text=True, timeout=10).stdout.strip().splitlines()
            return out[0] if out else ""
        except Exception:
            return ""

    def _shortcut_status(self):
        """Return (enabled, key). Defaults to (False, "F9") on any error."""
        try:
            out = subprocess.run([self._shortcut_script(), "status"],
                                 capture_output=True, text=True, timeout=10).stdout.strip()
        except Exception:
            return (False, "F9")
        if out.startswith("enabled:"):
            return (True, out.split(":", 1)[1] or "F9")
        return (False, "F9")

    def _shortcut_set(self, enabled, key):
        try:
            args = ([self._shortcut_script(), "enable", key] if enabled
                    else [self._shortcut_script(), "disable"])
            return subprocess.run(args, capture_output=True, text=True, timeout=15).returncode == 0
        except Exception as e:
            self._toast(f"Could not update the shortcut: {e}")
            return False

    def _open_de_shortcuts(self, de):
        candidates = {
            "kde": [["systemsettings", "kcm_keys"], ["kcmshell6", "kcm_keys"]],
            "gnome": [["gnome-control-center", "keyboard"]],
            "cinnamon": [["cinnamon-settings", "keyboard"]],
            "xfce": [["xfce4-keyboard-settings"]],
        }.get(de, [])
        for cmd in candidates:
            if shutil.which(cmd[0]):
                try:
                    subprocess.Popen(cmd)
                    return
                except Exception:
                    pass
        self._toast("Open your desktop's keyboard shortcut settings and bind the recenter command.")

    def _apply_live(self):
        self._apply_id = 0
        if self.proc:
            self._restart_tracking()
        return False

    def _on_close_request(self, *_):
        if self._apply_id:
            GLib.source_remove(self._apply_id)
            self._apply_id = 0
        self._teardown_stream()
        return False  # allow the window to close

    def _on_main_key(self, _c, keyval, _keycode, _state):
        if keyval == Gdk.KEY_Escape and self.banner.get_revealed():
            self.banner.set_revealed(False)
            return True
        return False


CAL_STEPS = [
    ("Turn your head to the RIGHT and hold it.",                       "does the view move RIGHT?"),
    ("Look UP and hold it.",                                           "does the view look UP?"),
    ("Tilt your head to the RIGHT, ear toward shoulder, and hold it.", "does the view tilt RIGHT?"),
]


class CalibrationDialog(Adw.Window):
    """Guided calibration. Measures which base-output axis each head movement drives
    and in which direction, then sets the live Euler correction (out_src/out_sign)
    via the parent, which pushes it to the bridge over the control socket. Never
    restarts the stream."""

    def __init__(self, parent):
        super().__init__(transient_for=parent, modal=True, title="Calibrate",
                         default_width=460, default_height=340)
        self.parent = parent
        self.ref = [0.0, 0.0, 0.0]
        self.i = 0
        # Measure against a clean identity correction so we see the base output.
        parent.cfg["out_src"] = [0, 1, 2]
        parent.cfg["out_sign"] = [1, 1, 1]
        parent._control_apply()

        tv = Adw.ToolbarView()
        tv.add_top_bar(Adw.HeaderBar())
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        for side in ("top", "bottom", "start", "end"):
            getattr(box, f"set_margin_{side}")(28)
        box.set_valign(Gtk.Align.CENTER)
        self.title = Gtk.Label(); self.title.add_css_class("title-2")
        self.title.set_wrap(True); self.title.set_justify(Gtk.Justification.CENTER)
        self.body = Gtk.Label(); self.body.add_css_class("dim-label")
        self.body.set_wrap(True); self.body.set_justify(Gtk.Justification.CENTER)
        self.buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10, halign=Gtk.Align.CENTER)
        for w in (self.title, self.body, self.buttons):
            box.append(w)
        note = Gtk.Label(label="Not all games support head tracking. Calibration only "
                               "maps your head movement to the tracker output; it cannot "
                               "add head tracking to a game that does not support it.")
        note.add_css_class("caption"); note.add_css_class("dim-label")
        note.set_wrap(True); note.set_justify(Gtk.Justification.CENTER)
        box.append(note)
        tv.set_content(box)
        self.set_content(tv)
        add_escape_to_close(self)
        self._intro()

    def _btn(self, label, cb, suggested=False):
        b = Gtk.Button(label=label); b.add_css_class("pill")
        if suggested:
            b.add_css_class("suggested-action")
        b.connect("clicked", cb)
        return b

    def _set_buttons(self, *btns):
        while (c := self.buttons.get_first_child()) is not None:
            self.buttons.remove(c)
        for b in btns:
            self.buttons.append(b)

    def _snapshot(self):
        t = self.parent.target
        return [float(t.get(k, 0.0)) for k in KEYS]

    def _intro(self):
        self.title.set_label("Look straight ahead")
        self.body.set_label("Face forward and relax, then click Start.")
        self._set_buttons(self._btn("Start", self._on_start, suggested=True))

    def _on_start(self, _b):
        self.ref = self._snapshot()
        self.i = 0
        self._motion()

    def _motion(self):
        instr, _q = CAL_STEPS[self.i]
        self.title.set_label(f"Step {self.i + 1} of 3")
        self.body.set_label(instr + "\nClick Record, then do the movement.")
        self._set_buttons(self._btn("Record", self._on_record, suggested=True))

    def _on_record(self, _b):
        self._peak = [0.0, 0.0, 0.0]
        self._frames = 0
        self._set_buttons()
        self._cap = GLib.timeout_add(40, self._sample)

    def _sample(self):
        cur = self._snapshot()
        for j in range(3):
            d = ((cur[j] - self.ref[j] + 180.0) % 360.0) - 180.0
            if abs(d) > abs(self._peak[j]):
                self._peak[j] = d
        self._frames += 1
        self.body.set_label("Recording… move now.\n" +
                            "    ".join(f"{KEYS[j][0].upper()} {self._peak[j]:+5.0f}°" for j in range(3)))
        if self._frames >= 75:  # ~3 seconds
            GLib.source_remove(self._cap)
            self._finish()
            return False
        return True

    def _finish(self):
        dom = max(range(3), key=lambda j: abs(self._peak[j]))
        if abs(self._peak[dom]) < 2.0:
            self.body.set_label("No movement detected. Are the values in the app moving? "
                                "Make a clear movement, then Retry.")
            self._set_buttons(self._btn("Retry", lambda _b: self._motion(), suggested=True))
            return
        sign = 1 if self._peak[dom] >= 0 else -1
        src = list(self.parent.cfg.get("out_src", [0, 1, 2]))
        sg = list(self.parent.cfg.get("out_sign", [1, 1, 1]))
        src[self.i] = dom
        sg[self.i] = sign
        self.parent._set_cfg("out_src", src)
        self.parent._set_cfg("out_sign", sg)
        self._confirm()

    def _confirm(self):
        _instr, q = CAL_STEPS[self.i]
        self.title.set_label("Check it")
        self.body.set_label(f"Do that movement again and watch the preview / game: {q}")
        self._set_buttons(self._btn("Yes", self._on_yes, suggested=True),
                          self._btn("No, flip it", self._on_flip))

    def _on_flip(self, _b):
        sg = list(self.parent.cfg.get("out_sign", [1, 1, 1]))
        sg[self.i] = -sg[self.i]
        self.parent._set_cfg("out_sign", sg)
        self._on_yes(None)

    def _on_yes(self, _b):
        self.i += 1
        if self.i < 3:
            self._motion()
        else:
            self.title.set_label("Calibrated")
            self.body.set_label("Your head now maps correctly. Fine-tune anytime with the Invert toggles.")
            self._set_buttons(self._btn("Done", lambda _b: self.close(), suggested=True))


# A best-effort list of titles known to support head tracking through the
# TrackIR / freetrack protocol (which is what OpenTrack emits). Matched as
# case-insensitive name fragments. It is not exhaustive: a game not listed here
# may still work, and this makes no promise about any specific title. Extend
# freely as people confirm more games.
_HEAD_TRACKING_TITLES = (
    "assetto corsa", "iracing", "rfactor", "automobilista", "project cars",
    "dirt rally", "raceroom", "beamng", "live for speed", "richard burns rally",
    "le mans ultimate", "wrc", "euro truck simulator", "american truck simulator",
    "microsoft flight simulator", "flight simulator", "x-plane", "dcs world",
    "il-2", "war thunder", "falcon bms", "falcon 4.0", "elite dangerous",
    "star citizen", "flightgear", "prepar3d", "aerofly", "arma", "squad", "dayz",
)


def supports_head_tracking(name: str) -> bool:
    """True if the title is on the curated head-tracking list. A False only means
    'not on our list', never 'confirmed unsupported'."""
    n = name.lower()
    return any(frag in n for frag in _HEAD_TRACKING_TITLES)


class SetupGameDialog(Adw.Window):
    """Two-path game setup: pick an installed Steam (Proton) game to configure
    automatically, or launch OpenTrack for a native/other game. The tracker itself
    is game-agnostic; this only wires up OpenTrack per game."""

    def __init__(self, parent):
        super().__init__(transient_for=parent, modal=True, title="Set up a game",
                         default_width=500, default_height=560)
        self.parent = parent
        self.toolbar = Adw.ToolbarView()
        self.toolbar.add_top_bar(Adw.HeaderBar())
        self.set_content(self.toolbar)
        add_escape_to_close(self)
        self._show_list()

    def _show_list(self):
        page = Adw.PreferencesPage()
        g = Adw.PreferencesGroup(
            title="Steam (Proton) games",
            description="Pick a game to set it up. Not all games support head "
                        "tracking. A check marks titles known to work with "
                        "TrackIR/OpenTrack; unmarked games may still work.")
        games = list_proton_games()
        if games:
            for appid, name in games:
                known = supports_head_tracking(name)
                subtitle = f"App {appid}  •  head tracking supported" if known else f"App {appid}"
                row = Adw.ActionRow(title=name, subtitle=subtitle)
                row.set_activatable(True)
                if known:
                    check = Gtk.Image(icon_name="emblem-ok-symbolic")
                    check.set_tooltip_text("Known to support head tracking (TrackIR/OpenTrack)")
                    check.add_css_class("success")
                    row.add_suffix(check)
                row.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
                row.connect("activated", lambda r, a=appid, n=name: self._setup_game(a, n))
                g.add(row)
        else:
            g.add(Adw.ActionRow(title="No Proton games found",
                                subtitle="Launch a game once so Steam creates its prefix, then reopen this."))
        page.add(g)

        other = Adw.PreferencesGroup(title="Other")
        native = Adw.ActionRow(title="Native Linux or other game",
                               subtitle="Opens OpenTrack so you can set its Output for your game")
        native.set_activatable(True)
        native.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
        native.connect("activated", lambda r: (self.parent._launch_opentrack(None), self.close()))
        other.add(native)
        page.add(other)
        self.toolbar.set_content(page)

    def _setup_game(self, appid, name):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16, valign=Gtk.Align.CENTER)
        for side in ("top", "bottom", "start", "end"):
            getattr(box, f"set_margin_{side}")(28)
        spinner = Gtk.Spinner(); spinner.start(); spinner.set_size_request(32, 32)
        lbl = Gtk.Label(label=f"Setting up {name}…\nFirst run downloads OpenTrack (about a minute).")
        lbl.set_justify(Gtk.Justification.CENTER); lbl.set_wrap(True)
        box.append(spinner); box.append(lbl)
        self.toolbar.set_content(box)

        script = str(SCRIPTS_DIR / "setup-steam-game.sh")

        def worker():
            try:
                r = subprocess.run([script, appid], capture_output=True, text=True, timeout=900)
                ok, out = r.returncode == 0, (r.stdout or "") + (r.stderr or "")
            except Exception as exc:  # noqa: BLE001
                ok, out = False, str(exc)
            GLib.idle_add(self._setup_done, name, ok, out)

        threading.Thread(target=worker, daemon=True).start()

    def _setup_done(self, name, ok, out):
        page = Adw.PreferencesPage()
        if ok:
            # User-specific path, computed from this user's data dir (never hardcoded).
            wrapper = str(Path(GLib.get_user_data_dir()) / "sony-head-tracker" / "proton-launch.sh")
            launch = f"{wrapper} %command%"

            g = Adw.PreferencesGroup(title=f"{name} is ready",
                                     description="A one-time setup in Steam. Do these three steps:")
            step1 = Adw.ActionRow(
                title="1.  Open the game's Launch Options in Steam",
                subtitle=f"In your Library, right-click {name} → Properties → General → "
                         "Launch Options. That box is where the line below goes.")
            step1.set_subtitle_lines(0)
            g.add(step1)

            step2 = Adw.ActionRow(title="2.  Paste this exact line into that box")
            step2.set_subtitle(launch)
            step2.set_subtitle_selectable(True)   # user can also select it manually
            step2.set_subtitle_lines(0)
            copy = Gtk.Button(label="Copy", valign=Gtk.Align.CENTER)
            copy.add_css_class("suggested-action")
            copy.connect("clicked", lambda b: (
                Gdk.Display.get_default().get_clipboard().set(launch),
                self.parent._toast("Copied. Click the Launch Options box in Steam and press Ctrl+V.")))
            step2.add_suffix(copy)
            g.add(step2)

            step3 = Adw.ActionRow(
                title="3.  Play",
                subtitle=f"Press Start here, then launch {name} from Steam. OpenTrack "
                         "starts inside the game on its own; press Recenter here while looking forward.")
            step3.set_subtitle_lines(0)
            g.add(step3)
            page.add(g)

            tip = Adw.PreferencesGroup()
            tip.add(Adw.ActionRow(
                title="Notes",
                subtitle="Paste replaces anything already in Launch Options. You only do this "
                         "once per game; the line is the same for every game."))
            page.add(tip)
        else:
            g = Adw.PreferencesGroup(title="Setup failed")
            g.add(Adw.ActionRow(title="Something went wrong",
                                subtitle=(out.strip()[-160:] if out.strip() else "unknown error")))
            page.add(g)
        self.toolbar.set_content(page)


class TrackerApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.win = None

    def do_activate(self):
        if not self.win:
            self.win = TrackerWindow(self)
            for name, cb in (("about", self._about), ("grant", lambda *_: self.win.grant_access()),
                             ("reconnect_hid", lambda *_: self.win._nudge_hid(manual=True)),
                             ("install_opentrack", lambda *_: self.win.install_opentrack())):
                act = Gio.SimpleAction.new(name, None)
                act.connect("activate", cb)
                self.add_action(act)
        self.win.present()

    def _about(self, *_):
        about = Adw.AboutWindow(
            transient_for=self.win,
            application_name="Sony Head Tracker",
            application_icon=APP_ID,
            developer_name="Linux port (community)",
            version="linux",
            comments="Head tracking from Sony headphones over UDP to OpenTrack.\n"
                     "Linux port of Nicholas Slattery's Sony Head Tracker.",
            website="https://github.com/NicholasSlattery/sony-head-tracker",
            license_type=Gtk.License.MIT_X11,
        )
        about.present()


def main():
    # On Wayland the compositor derives the window's app-id from the program name,
    # and uses it to match the .desktop file for the taskbar/search icon. Without
    # this it would be "python3" and the icon would not stick. Must run before GTK
    # connects to the display.
    GLib.set_prgname(APP_ID)
    Adw.init()
    app = TrackerApp()
    return app.run(None)


if __name__ == "__main__":
    raise SystemExit(main())
