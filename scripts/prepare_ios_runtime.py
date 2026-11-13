#!/usr/bin/env python3
"""Verify Mac-58's installed iOS 27.0 runtime without installing or changing it."""
import json
import re
import subprocess


def supported(runtime):
    version = tuple(int(n) for n in re.findall(r"\d+", runtime.get("version", ""))[:2])
    identifier = runtime.get("identifier", "")
    return (runtime.get("isAvailable", False) and ".iOS-" in identifier
            and "-iPhone" not in identifier and version == (27, 0))


def inventory():
    result = subprocess.run(["xcrun", "simctl", "list", "runtimes", "-j"],
                            check=True, capture_output=True, text=True, timeout=30)
    runtimes = json.loads(result.stdout)["runtimes"]
    for runtime in runtimes:
        if supported(runtime):
            print("Installed iOS 27.0 simulator runtime is available.", flush=True)
    return runtimes


def main():
    if not any(supported(runtime) for runtime in inventory()):
        raise RuntimeError("Mac-58 needs its configured iOS 27.0 simulator runtime; no download was attempted")


if __name__ == "__main__":
    main()
