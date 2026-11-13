#!/usr/bin/env python3
"""Reject incomplete Watch deliverables instead of accepting preview source."""
import io
import plistlib
import unittest
import zipfile

from check_ipa_device_install import bundle_layout


def fixture(widget=True, wrong_parent=False, empty_binary=False, watch_version="13"):
    buffer = io.BytesIO()
    root = "Payload/Minis.app"
    watch = root + "/Watch/MinisWatch.app"
    extension = watch + "/PlugIns/MinisWatchWidgets.appex"
    with zipfile.ZipFile(buffer, "w") as archive:
        def put(path, identifier, executable="app", extra=None):
            info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                    "CFBundleVersion": "13", "CFBundleShortVersionString": "1.16"}
            info.update(extra or {})
            archive.writestr(path + "/Info.plist", plistlib.dumps(info))
            archive.writestr(path + "/" + executable, b"" if empty_binary and path == extension else b"synthetic-executable")
        put(root, "com.openminis.app")
        for name in ("ShareExtension", "FileProvider", "AgentWidget"):
            put(root + "/PlugIns/" + name + ".appex", "com.openminis.app." + name)
        put(watch, "com.openminis.app.watchkitapp", extra={"CFBundleVersion": watch_version})
        if widget:
            put(extension, "wrong.parent.widgets" if wrong_parent else "com.openminis.app.watchkitapp.widgets",
                extra={"CFBundleVersion": watch_version, "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}})
    buffer.seek(0)
    return zipfile.ZipFile(buffer)


class WatchLayoutTests(unittest.TestCase):
    def test_actual_nested_widget_executable_is_required(self):
        with fixture() as archive:
            result = bundle_layout(archive, expect_watch_widgets=True)
            self.assertIn("WatchWidgets", result)
        for options in ({"widget": False}, {"wrong_parent": True}, {"empty_binary": True}, {"watch_version": "14"}):
            with self.subTest(options=options), fixture(**options) as archive, self.assertRaises(ValueError):
                bundle_layout(archive, expect_watch_widgets=True)


if __name__ == "__main__":
    unittest.main()
