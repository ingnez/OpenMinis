#!/usr/bin/env python3
"""Remove test apps on a dedicated CI device without erasing its system data."""
import json
import plistlib
import subprocess
import sys

TEST_APPS = {"com.openminis.app", "com.openminis.MinisTestHost",
             "com.openminis.MinisUITests.xctrunner", "com.openminis.MinisTests.xctrunner"}


def cleanup(device):
    def run(*args):
        return subprocess.run(["xcrun", "simctl", *args], check=True, capture_output=True, timeout=60)

    inventory = json.loads(run("list", "devices", "-j").stdout)
    entry = next((d for devices in inventory["devices"].values() for d in devices if d["udid"] == device), None)
    if not entry or not entry.get("name", "").startswith("OpenMinis CI "):
        raise ValueError("Refusing to clean a device outside the dedicated OpenMinis CI set")
    if entry.get("state") != "Booted":
        print("CI device is already shut down; no system data was erased.")
        return
    try:
        raw = run("listapps", device).stdout
        try:
            apps = json.loads(raw)
        except ValueError:
            try:
                apps = plistlib.loads(raw)
            except plistlib.InvalidFileException:
                # simctl versions that print an OpenStep property list need
                # Apple's parser, rather than Python's XML/binary-only parser.
                converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", "-"],
                    input=raw, check=True, capture_output=True, timeout=15)
                apps = json.loads(converted.stdout)
        for bundle_id in sorted(TEST_APPS.intersection(apps)):
            run("uninstall", device, bundle_id)
    finally:
        run("shutdown", device)
    print("Removed test apps and shut down only this job's dedicated CI simulator.")


if __name__ == "__main__":
    cleanup(sys.argv[1])
