import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cleanup", Path(__file__).with_name("cleanup_ci_simulator.py"))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def run_cleanup(self, name, encoding):
        commands = []
        def run(args, **kwargs):
            commands.append(args)
            if args[2:4] == ["list", "devices"]:
                result = json.dumps({"devices": {"runtime": [{"udid": "owned", "name": name, "state": "Booted"}]}}).encode()
            elif args[2] == "listapps":
                apps = {"com.openminis.app": {}, "com.apple.Preferences": {}, "example.other": {}}
                result = json.dumps(apps).encode() if encoding == "json" else plistlib.dumps(apps)
            else:
                result = b""
            return subprocess.CompletedProcess(args, 0, result, b"")
        with patch.object(cleanup.subprocess, "run", side_effect=run):
            cleanup.cleanup("owned")
        return commands

    def test_uninstalls_only_the_known_test_apps_and_does_not_erase_the_os(self):
        for encoding in ("json", "plist"):
            commands = self.run_cleanup("OpenMinis CI iOS-27-0 1", encoding)
            self.assertEqual([c[-1] for c in commands if c[2] == "uninstall"], ["com.openminis.app"])
            self.assertFalse(any(c[2] in ("erase", "delete") for c in commands))
            self.assertEqual(commands[-1][2], "shutdown")

    def test_refuses_a_personal_simulator(self):
        with self.assertRaises(ValueError):
            self.run_cleanup("My personal iPhone", "json")


if __name__ == "__main__":
    unittest.main()
