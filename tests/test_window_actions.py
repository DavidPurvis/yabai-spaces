import copy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "config"))
import window_actions as actions


def window(wid, space=2, **overrides):
    result = {"id": wid, "space": space, "has-ax-reference": True,
              "can-move": True, "can-resize": True, "is-floating": False,
              "role": "AXWindow", "subrole": "AXStandardWindow",
              "split-type": "vertical", "stack-index": 0,
              "frame": {"x": 0, "y": 0, "w": 100, "h": 100}}
    result.update(overrides)
    return result


class FakeYabai:
    def __init__(self, windows, reverse=False, fail=False):
        self.windows = {w["id"]: copy.deepcopy(w) for w in windows}
        self.commands = []
        self.queries = []
        self.reverse = reverse
        self.fail = fail
        self.direction = None

    def query(self, *args):
        self.queries.append(args)
        if args[0] == "--spaces":
            return {"type": "bsp", "uuid": "space-" + str(args[-1]),
                    "id": 100 + args[-1], "first-window": 10}
        if args[1] == "--window":
            return copy.deepcopy(self.windows[args[2] if len(args) == 3 else 20])
        return [copy.deepcopy(w) for w in self.windows.values() if w["space"] == args[-1]]

    def call(self, *args):
        self.commands.append(args)
        _, wid, command, *rest = args
        if command == "--insert":
            self.direction = rest[0]
        elif command == "--warp":
            if self.fail:
                raise RuntimeError("simulated vanished window")
            target = self.windows[rest[0]]
            new = self.windows[wid]
            axis = "x" if self.direction in ("east", "west") else "y"
            sign = 1 if self.direction in ("east", "south") else -1
            if self.reverse:
                sign *= -1
            new["frame"][axis] = target["frame"][axis] + sign * 100
        elif command == "--swap":
            other = self.windows[rest[0]]
            self.windows[wid]["frame"], other["frame"] = other["frame"], self.windows[wid]["frame"]
        elif command == "--toggle":
            self.windows[wid]["is-floating"] = not self.windows[wid]["is-floating"]


class WindowActionTests(unittest.TestCase):
    def test_all_spiral_directions_and_natural_warp_correction(self):
        for step, direction in enumerate(("east", "south", "west", "north")):
            for reverse in (False, True):
                with self.subTest(direction=direction, reverse=reverse):
                    api = FakeYabai([window(10), window(20)], reverse=reverse)
                    state = {"space-2": {"last": 10, "step": step}}
                    actions.created(api, state, 20, "spiral")
                    self.assertIn(("window", 10, "--insert", direction), api.commands)
                    self.assertTrue(actions.on_correct_side(api.windows[20], api.windows[10], direction))
                    self.assertEqual(state["space-2"], {"last": 20, "step": step + 1})
                    self.assertEqual(any(c[2] == "--swap" for c in api.commands), reverse)

    def test_space_and_observed_order_not_highest_id(self):
        api = FakeYabai([window(10), window(20), window(999), window(1000, space=1)])
        state = {"space-2": {"last": 10, "step": 1}, "space-1": {"last": 1000, "step": 9}}
        actions.created(api, state, 20, "dwindle")
        self.assertIn(("window", 20, "--warp", 10), api.commands)
        self.assertIn(("window", 10, "--insert", "south"), api.commands)
        self.assertEqual(state["space-1"]["step"], 9)
        self.assertFalse(any("--focus" in c for c in api.commands))

    def test_floating_window_centered_without_spiral(self):
        api = FakeYabai([window(20, **{"is-floating": True})])
        state = {}
        actions.created(api, state, 20, "spiral")
        self.assertEqual(api.commands, [("window", 20, "--grid", "2000:2000:293:293:1414:1414")])
        rows, columns, x, y, width, height = map(int, api.commands[0][-1].split(":"))
        self.assertEqual(2 * x + width, columns)
        self.assertEqual(2 * y + height, rows)
        self.assertAlmostEqual((width / columns) * (height / rows), 0.5, delta=0.001)
        self.assertEqual(state, {})

    def test_ineligible_windows_skipped(self):
        for flag in ("is-minimized", "is-hidden", "is-native-fullscreen", "is-sticky"):
            api = FakeYabai([window(10), window(20, **{flag: True})])
            actions.created(api, {}, 20, "spiral")
            self.assertEqual(api.commands, [])

    def test_ineligible_targets_ignored(self):
        api = FakeYabai([window(10, **{"is-floating": True}), window(20)])
        state = {}
        actions.created(api, state, 20, "spiral")
        self.assertEqual(api.commands, [])
        self.assertEqual(state["space-2"], {"last": 20, "step": 0})

    def test_duplicate_event_is_ignored(self):
        api = FakeYabai([window(10), window(20)])
        actions.created(api, {"space-2": {"last": 20, "step": 1}}, 20, "spiral")
        self.assertEqual(api.commands, [])

    def test_failed_move_does_not_advance_state(self):
        api = FakeYabai([window(10), window(20)], fail=True)
        state = {"space-2": {"last": 10, "step": 0}}
        with self.assertRaises(RuntimeError):
            actions.created(api, state, 20, "spiral")
        self.assertEqual(state["space-2"], {"last": 10, "step": 0})
        self.assertEqual(api.commands[-2:], [("window", 10, "--insert", "stack")] * 2)

    def test_float_both_directions(self):
        api = FakeYabai([window(20)])
        actions.toggle_float(api)
        self.assertEqual(api.commands[-1], ("window", 20, "--grid", "2000:2000:293:293:1414:1414"))
        api.commands.clear()
        actions.toggle_float(api)
        self.assertEqual(api.commands, [("window", 20, "--toggle", "float")])

    def test_json_transport_and_daemon_error(self):
        result = type("Result", (), {"returncode": 0, "stdout": '{"id":20}', "stderr": ""})()
        with patch("subprocess.run", return_value=result) as run:
            self.assertEqual(actions.Yabai().query("--windows", "--window", 20), {"id": 20})
            self.assertEqual(run.call_args.args[0][-1], "20")
            result.returncode = 1
            result.stderr = "failed to connect to socket"
            with self.assertRaisesRegex(RuntimeError, "failed to connect"):
                actions.Yabai().query("--windows")


if __name__ == "__main__":
    unittest.main()
