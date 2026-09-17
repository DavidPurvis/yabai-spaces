# Setup and maintenance

## Choose what to install

| Mode | Changes |
|---|---|
| `python3 scripts/install.py` | Menu-bar app and login agent only |
| `python3 scripts/install.py --with-configs` | App, login agent, `.yabairc`, `.skhdrc`, and three helper files |
| Add `--replace` | Explicitly allow replacement, with timestamped backups |
| Add `--no-start` | Install without loading/restarting the menu-bar app |

Run from a clone after `sh scripts/build.sh`. The installer never installs Homebrew packages, changes SIP, changes macOS preferences, or restarts yabai/skhd. Installing `.skhdrc` can still take effect immediately because skhd normally watches its file.

The app-only mode is suitable if you already have your own tiling configuration. The full mode is an opinionated configuration, not an automatic merge. Review `config/` before choosing it.

## Prerequisites for the full setup

1. Install yabai and skhd using their official instructions: [yabai installation](https://github.com/asmvik/yabai/wiki/Installing-yabai), [skhd](https://github.com/asmvik/skhd).
2. Grant the Accessibility permissions required by both tools. App-launch shortcuts can also trigger macOS Automation prompts.
3. Enable **Displays have separate Spaces** in macOS System Settings. Save work and log out/in if you change it.
4. Install Xcode Command Line Tools. The wrappers use `/usr/bin/python3`; confirm it exists and is Python 3.9+.
5. For ⌥ V, have Visual Studio Code installed under its normal app name.

These configs do not load a scripting addition or require disabling SIP for their configured features. Check upstream requirements before adding features that do.

The app and helper search the common Apple Silicon and Intel Homebrew paths, then `PATH`. `YABAI_BIN` overrides executable discovery. The sample `.yabairc` also adds those Homebrew directories to its own execution environment. If using a custom installation path, make the override available to the relevant launch agent; a Terminal-only export won't change an already-running service.

## Install and activate

```sh
sh scripts/build.sh
python3 scripts/install.py --with-configs
```

Existing files cause a clear refusal before replacement. If you've reviewed them and want these versions:

```sh
python3 scripts/install.py --with-configs --replace
```

The installer stops/reloads only its own menu-bar login agent unless `--no-start` is given. It will not forcibly quit a separately launched app instance; quit that instance before updating to avoid duplicate indicators.

After reviewing the installed settings, start the upstream services if they are not already running:

```sh
yabai --start-service
skhd --start-service
```

For already-running services, apply changes deliberately:

```sh
yabai --restart-service
skhd --reload
```

Restarting yabai can rearrange windows. Helper-only edits are read on the next invocation and need no restart. If you keep configurations in `~/.config/yabai/yabairc`, `~/.config/skhd/skhdrc`, or `$XDG_CONFIG_HOME`, merge the sample files into those instead; the installer refuses to shadow them with lower-priority dotfiles. Custom service `--config` overrides must also be handled manually.

## Installed paths

| Path | Purpose |
|---|---|
| `~/Applications/YabaiSpaces.app` | Native app with bundled offline reference |
| `~/Library/LaunchAgents/local.davidpurvis.yabaispaces.plist` | Per-user login agent |
| `~/Library/Logs/YabaiSpaces/` | Indicator stdout/stderr logs |
| `~/Library/Caches/local.davidpurvis.yabaispaces/status.json` | Local diagnostic summary |
| `~/Library/Application Support/YabaiSpaces/backups/` | Originals retained by `--replace` |
| `~/.yabairc`, `~/.skhdrc` | Optional configuration |
| `~/.config/yabai/window_actions.py` | Optional placement helper |
| `~/.config/yabai/spiral.sh`, `toggle-float.sh` | Optional helper entry points |

The login agent label is kept stable for upgrades from the original local prototype. It has `RunAtLoad` but no `KeepAlive`, so **Quit** works for the rest of the current login session.

## Update

```sh
git pull --ff-only
python3 -B -m unittest discover -s tests -v
sh scripts/build.sh
python3 scripts/install.py --replace
```

This updates only the app and login agent. Add `--with-configs` only if you want to replace the optional configuration too. Building or pulling alone never changes the installed copy.

## Backups and recovery

Each replacement prints a unique backup directory. Original files retain their paths relative to your home directory, and `manifest.json` lists them. The installer stages all payloads before replacing files and rolls filesystem replacements back on a write failure. A login-agent startup failure leaves the successfully installed files in place and reports an error; inspect the logs before retrying.

To restore manually, quit the indicator and unload its agent first. Restore only the desired files from that backup to their matching home-relative paths. Do not copy `manifest.json` to your home directory. Reload the relevant service afterward. Preferences, service registrations for yabai/skhd, and the spiral state are not modified or backed up by this installer.

## Disable or remove

Disable startup and stop the indicator:

```sh
launchctl disable "gui/$(id -u)/local.davidpurvis.yabaispaces"
launchctl bootout "gui/$(id -u)/local.davidpurvis.yabaispaces"
```

If it is already unloaded, `bootout` may report that the service was not found. Then use Finder to move the app and its launch-agent plist to the Trash. Logs and cache are optional cleanup. Keep backups until you no longer need them. Removing the app does not remove yabai, skhd, or your optional configuration.

To re-enable without removing:

```sh
launchctl enable "gui/$(id -u)/local.davidpurvis.yabaispaces"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.davidpurvis.yabaispaces.plist"
```
