#!/usr/bin/env python3
"""Serialize yabai window actions and keep spiral progress per Space.

Uses only the Python standard library supplied with the installed developer tools.
The helper never focuses windows or switches Spaces. YABAI_BIN and YABAI_STATE_DIR
can point to an isolated test environment. YABAI_SPIRAL_MODE may be spiral/dwindle.
"""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


class Yabai:
    def __init__(self):
        self.binary = os.environ.get("YABAI_BIN") or next(
            (path for path in ("/opt/homebrew/bin/yabai", "/usr/local/bin/yabai")
             if os.access(path, os.X_OK)), shutil.which("yabai") or "yabai")

    def call(self, *args):
        result = subprocess.run(
            [self.binary, "-m", *map(str, args)], capture_output=True,
            text=True, timeout=10, check=False,
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip()
                               or "yabai command failed")
        return result.stdout

    def query(self, *args):
        return json.loads(self.call("query", *args))


def available(window):
    return (window.get("has-ax-reference", False)
            and window.get("can-move", False)
            and window.get("can-resize", False)
            and not any(window.get(key, False) for key in
                        ("is-minimized", "is-hidden", "is-native-fullscreen", "is-sticky")))


def tiled(window):
    return (available(window) and not window.get("is-floating", True)
            and window.get("role") == "AXWindow"
            and window.get("subrole") == "AXStandardWindow"
            and window.get("stack-index", 0) == 0)


def center(api, window):
    if available(window) and window.get("is-floating", False):
        # 70.7% on each axis covers approximately 50% of the usable screen area.
        api.call("window", window["id"], "--grid", "2000:2000:293:293:1414:1414")


def toggle_float(api):
    window = api.query("--windows", "--window")
    if not available(window):
        return
    wid = window["id"]
    api.call("window", wid, "--toggle", "float")
    center(api, api.query("--windows", "--window", wid))


def on_correct_side(new, target, direction):
    axis, size = ("x", "w") if direction in ("east", "west") else ("y", "h")
    delta = (new["frame"][axis] + new["frame"][size] / 2
             - target["frame"][axis] - target["frame"][size] / 2)
    return delta > 0 if direction in ("east", "south") else delta < 0


def created(api, state, wid, mode):
    window = api.query("--windows", "--window", wid)
    if window.get("is-floating", False):
        center(api, window)
        return
    if not tiled(window):
        return

    # A window's space field is a Mission Control index, not a native Space ID.
    space = api.query("--spaces", "--space", window["space"])
    if space["type"] != "bsp":
        return
    key = space.get("uuid") or str(space["id"])
    windows = [w for w in api.query("--windows", "--space", window["space"])
               if tiled(w) and w["space"] == window["space"]]
    if not any(w["id"] == wid for w in windows):
        return  # Window disappeared or changed state while the event was queued.
    others = [w for w in windows if w["id"] != wid
              and w.get("split-type") in ("vertical", "horizontal")]
    previous = state.get(key, {})
    if not others:
        state[key] = {"last": wid, "step": 0}
        return
    if previous.get("last") == wid:
        return  # Ignore a repeated event for the most recently handled window.

    # Prefer actual observed creation order, never numerical window-ID order.
    # At startup, fall back to the focused eligible window or BSP first window.
    target = next((w for w in others if w["id"] == previous.get("last")), None)
    if target is None:
        target = next((w for w in others if w.get("has-focus")), None)
    if target is None:
        target = next((w for w in others if w["id"] == space.get("first-window")), others[0])
    step = previous.get("step", 0)
    if not isinstance(step, int) or step < 0:
        step = 0
    directions = ("east", "south") if mode == "dwindle" else ("east", "south", "west", "north")
    direction = directions[step % len(directions)]
    target_id = target["id"]

    # --insert sets the target's split; --warp actually moves the existing window.
    # Clear any prior marker first: repeating the same --insert toggles it off.
    api.call("window", target_id, "--insert", "stack")
    api.call("window", target_id, "--insert", direction)
    try:
        api.call("window", wid, "--warp", target_id)
    except Exception:
        # Do not leave an insertion marker behind when the move fails.
        api.call("window", target_id, "--insert", "stack")
        api.call("window", target_id, "--insert", "stack")
        raise

    # yabai 7.1.16's non-sibling warp can choose the side geometrically.
    # The two windows are now siblings: swap them if that choice disagrees.
    new = api.query("--windows", "--window", wid)
    target = api.query("--windows", "--window", target_id)
    if not on_correct_side(new, target, direction):
        api.call("window", wid, "--swap", target_id)
        new = api.query("--windows", "--window", wid)
        target = api.query("--windows", "--window", target_id)
        if not on_correct_side(new, target, direction):
            raise RuntimeError("spiral placement did not reach the requested side")
    state[key] = {"last": wid, "step": step + 1}


def main():
    action = sys.argv[1] if len(sys.argv) == 2 else ""
    if action not in ("created", "toggle-float"):
        raise ValueError("expected created or toggle-float")
    mode = os.environ.get("YABAI_SPIRAL_MODE", "spiral")
    if mode not in ("spiral", "dwindle"):
        raise ValueError("YABAI_SPIRAL_MODE must be spiral or dwindle")
    wid = os.environ.get("YABAI_WINDOW_ID", "")
    if action == "created" and not wid:
        return

    directory = Path(os.environ.get("YABAI_STATE_DIR", str(Path.home() / ".config/yabai")))
    directory.mkdir(parents=True, exist_ok=True)
    # flock is automatically released on process exit, including crashes.
    with (directory / "window-actions.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        api = Yabai()
        if action == "toggle-float":
            toggle_float(api)
            return
        state_file = directory / "spiral-state.json"
        try:
            state = json.loads(state_file.read_text())
            if not isinstance(state, dict) or not all(isinstance(v, dict) for v in state.values()):
                state = {}
        except (FileNotFoundError, json.JSONDecodeError):
            state = {}
        created(api, state, int(wid), mode)
        pending = directory / "spiral-state.json.pending"
        pending.write_text(json.dumps(state) + "\n")
        pending.replace(state_file)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
        print("yabai window actions: " + str(exc), file=sys.stderr)
        sys.exit(1)
