#!/usr/bin/env python3
"""Verify a compiled Watch app embeds its actual WidgetKit executable."""
import argparse
import plistlib
from pathlib import Path


def verify(app):
    app = Path(app)
    extension = app / "PlugIns/MinisWatchWidgets.appex"
    infos = []
    for bundle in (app, extension):
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        executable = bundle / info["CFBundleExecutable"]
        if not executable.is_file() or executable.stat().st_size == 0:
            raise ValueError("Missing Watch executable: " + str(executable))
        infos.append(info)
    parent, widget = infos
    if not widget["CFBundleIdentifier"].startswith(parent["CFBundleIdentifier"] + "."):
        raise ValueError("Watch widget identifier must belong to its Watch app")
    if parent["CFBundleVersion"] != widget["CFBundleVersion"]:
        raise ValueError("Watch app and widget versions must match")
    if widget.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        raise ValueError("Watch extension is not a WidgetKit extension")
    print("Compiled Watch app and embedded WidgetKit executable verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    verify(parser.parse_args().app)
