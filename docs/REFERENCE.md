# Yabai Spaces reference

This guide describes Yabai Spaces 1.1.0 and its optional configuration, not every upstream yabai/skhd default. The hover-focus menu toggle works with any running yabai instance. Shortcuts and the other window-management settings apply only when the optional configuration is installed.

## Quick memory jog

**Option opens apps. Option–Command–F floats the current window.**

| Keys | Action |
|---|---|
| ⌥ Return | Open a new Terminal window and activate Terminal |
| ⌥ F | Open a new Finder window at your home folder |
| ⌥ V | Request a new Visual Studio Code window |
| ⌥ S | Open a new Safari document/window and activate Safari |
| ⌥ ⌘ F | Toggle the focused window between tiling and floating; center it on entry to floating |

`alt` is Option, `cmd` is Command, and `return` is Return. There are five global bindings and no custom modes. No shortcuts for Space switching, directional focus, swapping, fullscreen, resizing, or balancing are added. Use normal macOS navigation for Spaces.

## Read the menu bar

Every existing Space gets a numbered square. Filled means focused, bright outlined means visible on another display, and dim outlined means inactive. The menu lists desktop/fullscreen counts and apps grouped by Space, with app icons and window counts in submenus. Native fullscreen Spaces are included and labelled. Hover for the desktop count and focused number.

**Focus on hover: Enabled/Disabled** shows yabai's current setting. Click to switch it immediately. Enabling uses `autofocus`; an existing `autoraise` setting also appears enabled and can be disabled. The item is disabled while updating or when yabai cannot be reached, in which case it reads **Focus on hover: Unavailable**. Failed changes show an error and are not saved as successful.

Your first successful menu selection is saved in the app's preferences (`focusOnHoverEnabled` in `local.davidpurvis.yabaispaces`). While Yabai Spaces is running, it restores that selection after the app or yabai restarts or reconnects. Until your first selection, it follows the existing yabai configuration. External runtime changes are reflected in the menu without being repeatedly overwritten; they do not replace your saved menu choice. Restoration does not edit `.yabairc`, require skhd, or restart yabai. Quitting Yabai Spaces leaves the current setting in effect but pauses restoration until the app runs again.

**Refresh** requests new data. **Open reference guide** opens this bundled document. **Quit** hides the app until the next login or manual start. The desktop overview does not switch Spaces or move windows.

Space, app, screen, and wake events trigger refreshes; a five-second timer covers other changes. Opening the menu uses the last completed snapshot and requests another refresh. Desktop numbers follow Mission Control order and can change if you reorder Spaces.

## Layout and focus settings

These are all six settings explicitly set in `config/yabairc`:

| Setting | Value | Meaning |
|---|---|---|
| `layout` | `bsp` | Tile using recursive rectangular splits |
| `auto_balance` | `off` | Keep unequal nested sizes instead of automatically balancing |
| `split_ratio` | `0.50` | Start new splits at 50/50; not all windows get equal area |
| `window_placement` | `second_child` | Initial placement before spiral correction |
| `focus_follows_mouse` | `autofocus` | Sample configuration default; the menu shows and changes the live setting and restores a saved choice after restart |
| `mouse_follows_focus` | `on` | Move the pointer to a newly focused window |

Gaps, padding, opacity, shadows, animations, mouse-drag actions, and other options are not explicitly configured. The sample configuration stops on command errors (`set -eu`); inspect the service logs if it loads only partially.

## Floating and centering

The labelled `utility-float` rule sets `manage=off` for exact application names:

**System Settings, App Store, Music, System Information, Disk Utility, Calculator, Messages, Finder.**

The regular expression is anchored; localized or renamed apps may need an edit. New eligible floating windows are centered by `window_created`. The float shortcut captures the focused window ID, toggles it, then centers that same window only if it is now floating. Returning to tiling does not issue a grid command.

The grid is `2000:2000:293:293:1414:1414`: 70.7% of each usable dimension, centered with 14.65% margins. The area is 49.9849%, approximately **50% of usable screen area**, not 50% of each dimension. Display constraints, future padding/gap settings, and application size limits can affect the actual frame.

Centering skips windows without an Accessibility reference or move/resize support, and hidden, minimized, native-fullscreen, or sticky windows. There is no general `window_floated` signal in the tested yabai version; arbitrary float changes made by other tools are not automatically centered. Existing windows keep their current frames until centered again. If already floating, use ⌥⌘F twice to tile and float again.

## Spiral behavior

New eligible tiled windows are placed **right → below → left → above** their target, with progress tracked independently for each Space. Eligibility additionally requires a standard AX window and no stack membership. Floating windows do not advance the spiral.

The helper uses actual observed creation order, not numeric window-ID order. It prefers the last successfully handled window still eligible on the same Space. The initial/fallback target is the focused eligible window, then the BSP first window, then an eligible candidate. A single-window Space records that window with step zero; repeated events for the recorded window are ignored.

The helper clears any old insertion marker, sets the target's split direction, and warps the new window beside it. Because yabai 7.1.16 may choose the resulting side geometrically, the helper checks frame centers and swaps the siblings if necessary. It checks again and advances state only after success. It never deliberately focuses a window or changes Space.

`spiral.sh` handles `window_created`; `toggle-float.sh` handles the shortcut. A separate `dock_did_restart` signal restarts yabai and does not load a scripting addition. Labels prevent duplicate custom registrations when the configuration is loaded again.

## Files and environment

| Item | Purpose/default |
|---|---|
| `~/.yabairc` | Layout settings, app rule, event registrations |
| `~/.skhdrc` | Five global shortcuts |
| `~/.config/yabai/window_actions.py` | Standard-library Python helper |
| `~/.config/yabai/spiral.sh` | Creation-event entry point |
| `~/.config/yabai/toggle-float.sh` | Floating shortcut entry point |
| `spiral-state.json` | Per-Space UUID: last handled window and direction step |
| `spiral-state.json.pending` | Temporary state, atomically renamed on success |
| `window-actions.lock` | Serializes helper actions; released on exit |
| `YABAI_BIN` | Override executable discovery in app/helper/config |
| `YABAI_STATE_DIR` | Helper state directory; default `~/.config/yabai` |
| `YABAI_SPIRAL_MODE` | `spiral` (default) or `dwindle` (right → below) |
| `YABAI_WINDOW_ID` | Event window ID provided by yabai |

The wrappers use `/usr/bin/python3` and require no pip packages. To select dwindle, change the final line of the installed `spiral.sh` to:

```sh
exec /usr/bin/env YABAI_SPIRAL_MODE=dwindle /usr/bin/python3 "$HOME/.config/yabai/window_actions.py" created
```

An export in an unrelated Terminal session does not change an existing service's environment.

## Inspect and maintain

```sh
# Read-only checks.
yabai -m query --spaces
yabai -m rule --list
yabai -m signal --list
yabai -m config layout
launchctl print "gui/$(id -u)/local.davidpurvis.yabaispaces"
cat "$HOME/Library/Caches/local.davidpurvis.yabaispaces/status.json"
```

The diagnostic timestamp records the last changed snapshot or hover-focus state, not a heartbeat. It contains source, indices, focus, image width, status-item visibility, and the hover-focus mode/title/error; not app names or window titles. An on-demand `--snapshot` includes app names/counts, so review it before sharing publicly.

| Edited item | Apply it |
|---|---|
| `.skhdrc` | Usually hotloads; explicitly use `skhd --reload` |
| `.yabairc` | Syntax-check with `sh -n "$HOME/.yabairc"`, then `yabai --restart-service` |
| Python helper/wrapper | Next invocation; no restart needed |
| Native app | Rebuild, then reinstall with `--replace` |
| Separate Spaces preference | Log out/in after saving work |

Common adjustments: use the menu to toggle hover focus; disable pointer movement with `mouse_follows_focus off`; enable equal-area rebalancing with `auto_balance on`; add exact app names to `utility-float` to float them. Avoid duplicate shortcut definitions. Version 0.3.9 of skhd keeps the first duplicate binding.

## Troubleshooting

| Symptom | Check |
|---|---|
| No desktop numbers | Check the menu's data source, yabai service, Separate Spaces, and indicator error log |
| Native fallback shown | yabai is absent/unreachable; fallback is read-only and may omit hidden/minimized apps |
| `failed to connect to socket` | Check yabai's launch service and error log before restarting |
| Separate Spaces error | Enable Displays have separate Spaces, save work, log out/in |
| App shortcuts work, float does not | yabai must be running as well as skhd |
| No shortcuts work | Check skhd service, Accessibility, and Secure Keyboard Entry |
| One app launcher fails | Check Automation permissions or the installed app name |
| Window will not center | Check eligibility and application minimum sizes |
| Config edits do nothing | Check higher-priority XDG files or a custom service config path |
| Too many menu-bar items | Reduce active Spaces or move other status items; this app has no overflow mode |

Indicator logs live in `~/Library/Logs/YabaiSpaces/`. Upstream service logs typically use `/tmp/yabai_<username>.err.log` and `/tmp/skhd_<username>.err.log`; check your launch-agent configuration for exact paths. Historical log errors alone do not establish current failure.

See the repository's Setup guide for installation, backups, and removal. This offline reference describes shipped settings; your manually edited installed files are authoritative.
