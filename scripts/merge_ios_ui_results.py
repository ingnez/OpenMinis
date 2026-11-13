#!/usr/bin/env python3
"""Archive available suite evidence and fail if any full-suite method is absent."""
import shutil
import subprocess
from pathlib import Path

from check_ui_coverage import SUITES, expected, verify

logs, bundles = [], []
for suite in SUITES:
    log = Path("ui-suites", suite + ".log")
    if log.exists():
        logs.append(log.read_text(errors="replace"))
    bundle = Path("ui-suites", suite + ".xcresult")
    if bundle.exists():
        bundles.append(str(bundle))
text = "\n".join(logs)
Path("ui-tests.log").write_text(text)
if len(bundles) == 1:
    shutil.copytree(bundles[0], "ui-tests.xcresult")
elif bundles:
    try:
        subprocess.run(["xcrun", "xcresulttool", "merge", "--output-path", "ui-tests.xcresult", *bundles], check=True)
    except subprocess.CalledProcessError:
        shutil.copytree("ui-suites", "ui-merge-failure")
        raise
count = verify(text, expected(["MinisUITests/" + suite for suite in SUITES]))
print(f"Full suite complete: {count}/{count} named UI methods")
