#!/usr/bin/env python3
"""Check an OpenMinis IPA's bundle layout and, on macOS, its signed capabilities."""

import argparse
import plistlib
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path

REQUIRED_IOS_EXTENSIONS = {"ShareExtension", "FileProvider", "AgentWidget"}
WORKSPACE_RESOURCE = "cloud_workspace_tools.py"
ENTITLEMENTS = {
    "": "Minis.entitlements",
    "ShareExtension": "ShareExtension/ShareExtension.entitlements",
    "FileProvider": "FileProvider/FileProvider.entitlements",
    "AgentWidget": "AgentWidget/AgentWidget.entitlements",
    "Watch": "MinisWatch/MinisWatch.entitlements",
    "WatchWidgets": "MinisWatchWidgets/WatchStatusWidget.entitlements",
}
CAPABILITIES = {
    "com.apple.security.application-groups",
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.ubiquity-container-identifiers",
    "com.apple.developer.icloud-services",
    "com.apple.developer.icloud-container-environment",
}


def bundle_layout(archive, expect_workspace_tools=False, expect_watch_widgets=False):
    names = set(archive.namelist())
    roots = [name[:-len("/Info.plist")] for name in names
             if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
    if len(roots) != 1:
        raise ValueError("Expected exactly one main app in Payload")
    root = roots[0]
    extensions = [name[:-len("/Info.plist")] for name in names
                  if name.startswith(root + "/PlugIns/") and name.endswith(".appex/Info.plist")
                  and name.count("/") == root.count("/") + 3]
    by_suffix = {}
    main_info = plistlib.loads(archive.read(root + "/Info.plist"))
    bundle_id = main_info.get("CFBundleIdentifier")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise ValueError("Main app bundle identifier is missing")
    for ext in extensions:
        info = plistlib.loads(archive.read(ext + "/Info.plist"))
        identifier = info.get("CFBundleIdentifier", "")
        if not identifier.startswith(bundle_id + "."):
            raise ValueError(f"Extension identifier {identifier} is outside {bundle_id}")
        by_suffix[identifier.removeprefix(bundle_id + ".")] = ext
    missing = REQUIRED_IOS_EXTENSIONS - by_suffix.keys()
    if missing:
        raise ValueError("Missing extensions: " + ", ".join(sorted(missing)))
    if expect_workspace_tools and root + "/" + WORKSPACE_RESOURCE not in names:
        raise ValueError(f"Main app does not contain {WORKSPACE_RESOURCE}")
    bundles = {"": root, **by_suffix}
    if expect_watch_widgets:
        watch = root + "/Watch/MinisWatch.app"
        widget = watch + "/PlugIns/MinisWatchWidgets.appex"
        for path in (watch, widget):
            if path + "/Info.plist" not in names:
                raise ValueError("Missing embedded Watch bundle: " + path)
            info = plistlib.loads(archive.read(path + "/Info.plist"))
            executable = info.get("CFBundleExecutable")
            if not executable or path + "/" + executable not in names or not archive.read(path + "/" + executable):
                raise ValueError("Watch bundle has no executable: " + path)
        watch_info = plistlib.loads(archive.read(watch + "/Info.plist"))
        widget_info = plistlib.loads(archive.read(widget + "/Info.plist"))
        if widget_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
            raise ValueError("Watch widget extension point is invalid")
        watch_id = watch_info.get("CFBundleIdentifier", "")
        if not watch_id.startswith(bundle_id + ".") or not widget_info.get("CFBundleIdentifier", "").startswith(watch_id + "."):
            raise ValueError("Watch bundle identifiers do not match their containing apps")
        if watch_info.get("CFBundleVersion") != widget_info.get("CFBundleVersion"):
            raise ValueError("Watch app and widget versions differ")
        for key in ("CFBundleVersion", "CFBundleShortVersionString"):
            if main_info.get(key) != watch_info.get(key):
                raise ValueError("Watch and iOS app versions differ: " + key)
        bundles.update(Watch=watch, WatchWidgets=widget)
    return bundles


def verify_signed(ipa, bundles):
    source = Path(__file__).resolve().parents[1] / "src" / "ios"
    with tempfile.TemporaryDirectory(prefix="openminis-ipa-check-") as tmp:
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(ipa.resolve()), tmp], check=True)
        app = Path(tmp) / bundles[""]
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        for suffix, template in ENTITLEMENTS.items():
            if suffix not in bundles:
                continue
            bundle = Path(tmp) / bundles[suffix]
            signed = subprocess.run(
                ["/usr/bin/codesign", "-d", "--entitlements", "-", str(bundle)],
                check=True, capture_output=True,
            ).stdout
            expected = plistlib.loads((source / template).read_bytes())
            actual = plistlib.loads(signed)
            for key in CAPABILITIES.intersection(expected):
                wanted, present = expected[key], actual.get(key)
                matches = set(wanted).issubset(present) if isinstance(wanted, list) and isinstance(present, list) else wanted == present
                if not matches:
                    raise ValueError(f"{bundle.name} is missing or changed entitlement {key}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--workspace-tools", action="store_true")
    parser.add_argument("--watch-widgets", action="store_true")
    parser.add_argument("--signed", action="store_true", help="Also verify signatures and capabilities on macOS")
    args = parser.parse_args()
    try:
        with zipfile.ZipFile(args.ipa) as archive:
            bundles = bundle_layout(archive, args.workspace_tools, args.watch_widgets)
        if args.signed:
            verify_signed(args.ipa, bundles)
    except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
    print("IPA bundle layout verified" + (" and signed capabilities verified" if args.signed else ""))


if __name__ == "__main__":
    main()
