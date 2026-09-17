# Development and technical notes

## Repository map

```text
app/           Native AppKit source and bundle metadata
config/        Optional yabai/skhd settings and Python helper
scripts/       Local build and backup-aware installer
tests/         Helper and installer unit tests
docs/          Setup, reference, and technical notes
.github/       macOS CI
```

No package manager or third-party runtime dependencies are needed for the source itself. The Swift app uses AppKit, CoreGraphics, Foundation, and dynamically resolved SkyLight symbols. The optional helper and installer use Python's standard library.

## Data flow

The app first queries yabai's Spaces and windows, joining each Space's window IDs to app names. If unavailable or malformed, it falls back to native macOS queries. A snapshot holds the source, Space IDs/indices, display number, fullscreen/focused/visible flags, and app window counts.

The fallback resolves `SLSMainConnectionID`, `SLSCopyManagedDisplaySpaces`, `SLSCopyActiveMenuBarDisplayIdentifier`, and `SLSCopySpacesForWindows` at runtime. Missing symbols return an unavailable state rather than an unchecked function call. Window metadata comes from `CGWindowListCopyWindowInfo`; ordinary regular-app windows are filtered by layer and bounds. These are read-only queries, not Space-switching calls or Dock injection.

Queries run off the main thread. Only one refresh runs at a time. The UI redraws on changed snapshots. A hung yabai process gets a termination request after two seconds and a forced stop after three; stdout is drained while it runs and stderr is discarded to avoid filling an unread pipe. Commands are launched as argument arrays, not interpolated shell strings.

The indicator is a template image: 20-point numbered squares with three-point gaps and 50% opacity for inactive Spaces. For numbers without a system symbol, a rounded rectangle and numeral are drawn. The app has no Dock icon and does not reserve screen space.

## Privacy

There are no network calls or analytics in the app/helper. The yabai JSON response can include window titles, but this app does not use, persist, or display them. The native path similarly uses only app/window membership metadata, not titles or images. No screen images are captured and the app does not request Screen Recording.

The local status file contains only indices, focused indices, source, visibility, width, and last-change time. `--snapshot` prints app names/counts and Space identifiers; inspect that output before posting it. Runtime state, build products, logs, and machine-specific audit reports are excluded from this repository.

## Build and test

```sh
python3 -B -m unittest discover -s tests -v
sh scripts/build.sh
build/YabaiSpaces.app/Contents/MacOS/YabaiSpaces --self-test
codesign --verify --strict build/YabaiSpaces.app
```

Helper tests simulate yabai and cover directional placement/correction, independent Spaces, eligibility, floating geometry, duplicates, failed moves, and JSON/daemon errors. Installer tests use isolated temporary homes, not real dotfiles, and check generated plists, overwrite refusal, backups, symlinks, alternate configs, and rollback. Native self-tests cover model decoding, counts, symbols, geometry, and snapshot round-trips.

The build targets macOS 13+ on the host architecture, bundles the offline reference, and applies a local ad-hoc signature. It is not a notarized or universal release binary. CI builds on macOS without installing the app or changing desktop settings.

Read-only live checks in a logged-in macOS session:

```sh
build/YabaiSpaces.app/Contents/MacOS/YabaiSpaces --snapshot
build/YabaiSpaces.app/Contents/MacOS/YabaiSpaces --render-preview /tmp/yabai-spaces-preview.png
```

Rendered previews verify drawing, not the real menu's accessibility or Space-switching behavior. For UI validation, manually switch Spaces, add/remove a Space, open the menu, and check a second display. Test tiling and ⌥⌘F separately with disposable windows; simulated tests do not prove actual macOS frames.

## Compatibility and known limits

- Development baseline: Apple Silicon, macOS 26.6.2, yabai 7.1.16, skhd 0.3.9.
- Intel paths are supported in code but have not been tested on Intel hardware.
- The minimum deployment target is not a claim that every fallback API works on every macOS version.
- SkyLight is private API and may change without notice.
- Fallback app lists may miss hidden/minimized windows or small windows excluded by the metadata filter.
- Window membership and Space queries are separate snapshots, so fast app movement can briefly produce stale counts.
- Native fullscreen Spaces participate in numbering. Multiple displays have their own visible Spaces but one focused Space.
- Many Spaces can overflow available menu-bar room; there is no compact/overflow mode yet.
- The menu uses the last completed snapshot while requesting a refresh; updates may take up to the timer interval.
- The Python spiral state is a lightweight placement history, not a persistent window database. Window closures and daemon restarts can force target fallback.

## Upstream references

- [yabai 7.1.16 manual](https://github.com/asmvik/yabai/blob/v7.1.16/doc/yabai.asciidoc)
- [yabai native API declarations](https://github.com/asmvik/yabai/blob/v7.1.16/src/misc/extern.h)
- [skhd](https://github.com/asmvik/skhd)
- [AeroSpace's menu-bar label](https://github.com/nikitabobko/AeroSpace/blob/v0.21.3-Beta/Sources/AppBundle/ui/MenuBarLabel.swift)
