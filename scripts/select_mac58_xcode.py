#!/usr/bin/env python3
"""Select Xcode 27.0 for this job without changing the Mac's global selection."""
import os
from pathlib import Path
import subprocess


def main():
    active = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True, check=True).stdout.strip()
    candidates = [Path(active), *sorted(Path("/Applications").glob("Xcode*.app/Contents/Developer"))]
    for candidate in dict.fromkeys(candidates):
        env = dict(os.environ, DEVELOPER_DIR=str(candidate))
        version = subprocess.run(["xcodebuild", "-version"], env=env, capture_output=True, text=True)
        if version.returncode == 0 and version.stdout.splitlines()[0] == "Xcode 27.0":
            if "\n" in str(candidate):
                raise RuntimeError("Invalid Xcode path")
            with open(os.environ["GITHUB_ENV"], "a") as output:
                output.write(f"DEVELOPER_DIR={candidate}\n")
            print("Selected Xcode 27.0 for this Actions job; global selection unchanged.")
            return
    raise RuntimeError("The configured Xcode 27.0 installation was not found on Mac-58")


if __name__ == "__main__":
    main()
