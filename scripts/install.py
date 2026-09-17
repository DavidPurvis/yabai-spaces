#!/usr/bin/env python3
"""Install a locally built app; optional configuration changes are always explicit."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
LABEL = "local.davidpurvis.yabaispaces"


def agent_data(home):
    logs = home / "Library/Logs/YabaiSpaces"
    return plistlib.dumps({
        "Label": LABEL,
        "ProgramArguments": [str(home / "Applications/YabaiSpaces.app/Contents/MacOS/YabaiSpaces")],
        "RunAtLoad": True,
        "ProcessType": "Interactive",
        "StandardOutPath": str(logs / "output.log"),
        "StandardErrorPath": str(logs / "error.log"),
    }, sort_keys=True)


def install_plan(home, project, with_configs):
    # (destination, source path or literal bytes, permissions)
    plan = [
        (home / "Applications/YabaiSpaces.app", project / "build/YabaiSpaces.app", None),
        (home / "Library/LaunchAgents" / (LABEL + ".plist"), agent_data(home), 0o644),
    ]
    if with_configs:
        for name, target, mode in [
            ("yabairc", ".yabairc", 0o755), ("skhdrc", ".skhdrc", 0o644),
            ("window_actions.py", ".config/yabai/window_actions.py", 0o644),
            ("spiral.sh", ".config/yabai/spiral.sh", 0o755),
            ("toggle-float.sh", ".config/yabai/toggle-float.sh", 0o755),
        ]:
            plan.append((home / target, project / "config" / name, mode))
    return plan


def preflight(plan, replace):
    for target, source, _ in plan:
        if target.is_symlink():
            raise ValueError(f"Refusing to replace symlink: {target}. Merge your managed dotfiles manually.")
        if target.exists() and not replace:
            raise FileExistsError(f"Already exists: {target}. Use --replace to back up and replace it.")
        if isinstance(source, Path) and not source.exists():
            raise FileNotFoundError(f"Missing build/source: {source}. Run sh scripts/build.sh first.")


def install_files(plan, home, replace=False):
    """Stage everything before replacing targets; restore originals on write failure."""
    preflight(plan, replace)
    backup = None
    staged = []
    applied = []
    try:
        for target, source, mode in plan:
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = Path(tempfile.mkdtemp(prefix=".yabaispaces-stage-", dir=target.parent))
            payload = temporary / target.name
            staged.append((target, payload, temporary))
            if isinstance(source, bytes):
                payload.write_bytes(source)
            elif source.is_dir():
                shutil.copytree(source, payload)
            else:
                shutil.copy2(source, payload)
            if mode is not None:
                payload.chmod(mode)
        existing = [target for target, _, _ in plan if target.exists()]
        if existing:
            base = home / "Library/Application Support/YabaiSpaces/backups"
            base.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
            backup = Path(tempfile.mkdtemp(prefix=stamp, dir=base))
            (backup / "manifest.json").write_text(json.dumps({
                "originals": [str(path.relative_to(home)) for path in existing]
            }, indent=2) + "\n")
        for target, payload, _ in staged:
            original = None
            if target.exists():
                original = backup / target.relative_to(home)
                original.parent.mkdir(parents=True, exist_ok=True)
                target.rename(original)
            applied.append((target, original))
            payload.rename(target)
    except Exception:
        for target, original in reversed(applied):
            if target.is_dir():
                shutil.rmtree(target)  # Only this transaction's newly installed bundle.
            elif target.exists():
                target.unlink()
            if original is not None and original.exists():
                original.rename(target)
        raise
    finally:
        for _, _, temporary in staged:
            shutil.rmtree(temporary)
    return backup


def check_alternate_configs(home):
    roots = {home / ".config", Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")}
    for root in roots:
        for name in ("yabai/yabairc", "skhd/skhdrc"):
            candidate = root / name
            if candidate.exists():
                raise ValueError(f"Higher-priority config exists: {candidate}. Merge config/ manually instead.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true", help="back up and replace existing app/config files")
    parser.add_argument("--with-configs", action="store_true", help="also install the opinionated yabai/skhd config")
    parser.add_argument("--no-start", action="store_true", help="install without loading/restarting the menu-bar app")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.geteuid() == 0:
        raise ValueError("Run this as your normal macOS user, without sudo.")
    home = Path.home()
    if args.with_configs:
        check_alternate_configs(home)
    plan = install_plan(home, PROJECT, args.with_configs)
    preflight(plan, args.replace)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(PROJECT / "build/YabaiSpaces.app")], check=True)
    service = f"gui/{os.getuid()}/{LABEL}"
    agent = home / "Library/LaunchAgents" / (LABEL + ".plist")
    was_running = False
    if not args.no_start:
        was_running = subprocess.run(["launchctl", "print", service], stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL).returncode == 0
        if was_running:
            subprocess.run(["launchctl", "bootout", service], check=True)
    try:
        backup = install_files(plan, home, args.replace)
    except Exception:
        if was_running:
            subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(agent)], check=False)
        raise
    (home / "Library/Logs/YabaiSpaces").mkdir(parents=True, exist_ok=True)
    print(f"Installed {home / 'Applications/YabaiSpaces.app'}")
    if backup:
        print(f"Previous files saved in {backup}")
    if args.with_configs:
        print("Installed yabai/skhd settings. This does not install dependencies, change macOS preferences, or restart either service.")
        print("skhd may hot-reload these bindings immediately. Follow docs/SETUP.md before restarting yabai.")
    if not args.no_start:
        subprocess.run(["launchctl", "enable", service], check=True)
        subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(agent)], check=True)
        print("Menu-bar indicator started and enabled at login.")
    else:
        print("Not started. An already-running indicator continues using its previous executable until restarted.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Install failed: {error}", file=sys.stderr)
        sys.exit(1)
