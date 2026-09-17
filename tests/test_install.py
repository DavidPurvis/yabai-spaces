import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("installer", Path(__file__).resolve().parents[1] / "scripts/install.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="yabaispaces-tests-")
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name) / "Example User & Files"
        self.home.mkdir()

    def test_plist_handles_spaces_and_xml_characters(self):
        agent = plistlib.loads(installer.agent_data(self.home))
        self.assertTrue(agent["RunAtLoad"])
        self.assertNotIn("KeepAlive", agent)
        self.assertEqual(agent["ProgramArguments"], [str(self.home / "Applications/YabaiSpaces.app/Contents/MacOS/YabaiSpaces")])

    def test_app_only_does_not_install_dotfiles(self):
        plan = installer.install_plan(self.home, installer.PROJECT, False)
        self.assertEqual(len(plan), 2)
        self.assertEqual(len(installer.install_plan(self.home, installer.PROJECT, True)), 7)

    def test_no_overwrite_without_explicit_replace(self):
        target = self.home / ".yabairc"
        target.write_text("original")
        with self.assertRaises(FileExistsError):
            installer.install_files([(target, b"new", 0o755)], self.home)
        self.assertEqual(target.read_text(), "original")

    def test_replacement_is_backed_up_and_permissions_set(self):
        target = self.home / ".yabairc"
        target.write_text("original")
        backup = installer.install_files([(target, b"new", 0o755)], self.home, replace=True)
        self.assertEqual(target.read_text(), "new")
        self.assertEqual((backup / ".yabairc").read_text(), "original")
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)

    def test_symlink_refused_even_with_replace(self):
        original = self.home / "managed"
        original.write_text("original")
        target = self.home / ".yabairc"
        target.symlink_to(original)
        with self.assertRaises(ValueError):
            installer.install_files([(target, b"new", 0o755)], self.home, replace=True)
        self.assertEqual(original.read_text(), "original")

    def test_missing_source_does_not_change_any_target(self):
        target = self.home / ".yabairc"
        target.write_text("original")
        with self.assertRaises(FileNotFoundError):
            installer.install_files([(target, b"new", 0o755),
                                     (self.home / ".skhdrc", self.home / "missing", 0o644)], self.home, True)
        self.assertEqual(target.read_text(), "original")

    def test_write_failure_restores_original(self):
        target = self.home / ".yabairc"
        target.write_text("original")
        real_rename = Path.rename

        def fail_payload(path, destination):
            if path.parent.name.startswith(".yabaispaces-stage-"):
                raise OSError("simulated install failure")
            return real_rename(path, destination)

        with patch.object(Path, "rename", fail_payload), self.assertRaises(OSError):
            installer.install_files([(target, b"new", 0o755)], self.home, True)
        self.assertEqual(target.read_text(), "original")
        self.assertFalse(list(self.home.glob(".yabaispaces-stage-*")))

    def test_alternate_config_refused(self):
        config = self.home / ".config/skhd/skhdrc"
        config.parent.mkdir(parents=True)
        config.write_text("existing settings")
        with patch.dict("os.environ", {"XDG_CONFIG_HOME": str(self.home / ".config")}), self.assertRaises(ValueError):
            installer.check_alternate_configs(self.home)

    def test_app_bundle_replacement_preserves_old_bundle(self):
        target = self.home / "Applications/YabaiSpaces.app"
        target.mkdir(parents=True)
        (target / "old-resource").write_text("old")
        source = self.home / "build/YabaiSpaces.app"
        source.mkdir(parents=True)
        (source / "new-resource").write_text("new")
        backup = installer.install_files([(target, source, None)], self.home, True)
        self.assertEqual((target / "new-resource").read_text(), "new")
        self.assertFalse((target / "old-resource").exists())
        self.assertEqual((backup / "Applications/YabaiSpaces.app/old-resource").read_text(), "old")

    def test_later_failure_rolls_back_every_applied_target(self):
        existing = self.home / "existing"
        existing.write_text("original")
        added = self.home / "new"
        failing = self.home / "failure"
        real_rename = Path.rename

        def fail_last(path, destination):
            if path.parent.name.startswith(".yabaispaces-stage-") and Path(destination) == failing:
                raise OSError("simulated late failure")
            return real_rename(path, destination)

        with patch.object(Path, "rename", fail_last), self.assertRaises(OSError):
            installer.install_files([(existing, b"replacement", 0o644), (added, b"new", 0o644),
                                     (failing, b"fail", 0o644)], self.home, True)
        self.assertEqual(existing.read_text(), "original")
        self.assertFalse(added.exists())
        self.assertFalse(failing.exists())

    def test_staging_failure_leaves_originals_untouched(self):
        existing = self.home / "existing"
        existing.write_text("original")
        with patch.object(Path, "write_bytes", side_effect=OSError("disk full")), self.assertRaises(OSError):
            installer.install_files([(existing, b"replacement", 0o644)], self.home, True)
        self.assertEqual(existing.read_text(), "original")
        self.assertFalse(list(self.home.glob(".yabaispaces-stage-*")))


if __name__ == "__main__":
    unittest.main()
