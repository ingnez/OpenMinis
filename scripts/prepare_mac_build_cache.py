#!/usr/bin/env python3
"""Reuse only CI compilation outputs on the dedicated serial Mac runner."""
import os
from pathlib import Path
import re
import subprocess
import sys


def main():
    variant = sys.argv[1]
    if variant not in ("device", "simulator"):
        raise ValueError("Unknown build variant")
    version = subprocess.check_output(["xcodebuild", "-version"], text=True).splitlines()[-1].split()[-1]
    if not re.fullmatch(r"[A-Za-z0-9.]+", version):
        raise ValueError("Invalid Xcode build version")
    cache = Path(os.environ["RUNNER_TOOL_CACHE"]) / "OpenMinisDerivedData" / version / variant
    cache.mkdir(parents=True, exist_ok=True)
    build = Path(os.environ["GITHUB_WORKSPACE"]) / "build"
    if build.is_symlink() and build.resolve() == cache.resolve():
        return
    if build.exists() or build.is_symlink():
        raise RuntimeError("Unexpected build directory; refusing to replace it")
    build.symlink_to(cache, target_is_directory=True)
    print(f"CI compilation cache ready for {variant}; source checkout remains clean.")


if __name__ == "__main__":
    main()
