#!/usr/bin/env python3
"""Require a final PASS for every requested XCTest method, including retries."""
import re
import sys
from pathlib import Path

SUITES = ("MinisSmokeUITests", "ComposerVoiceButtonUITests", "E2EFlowsUITests", "MiscControlsUITests",
          "ReplyModeUITests", "DeliverablesUITests", "ImageExperienceUITests", "BotToBotUITests", "GroupChatUITests",
          "Ideas12UITests", "FrogP0UITests", "Frog1850UITests", "Frog1850Chunk2UITests", "Frog1850Chunk3UITests", "BackupUXUITests")


def expected(selectors, source=None):
    source = Path(source or Path(__file__).resolve().parents[1] / "src/ios/MinisUITests")
    names = set()
    for selector in selectors:
        parts = selector.split("/")
        if len(parts) not in (2, 3) or parts[0] != "MinisUITests" or not re.fullmatch(r"[A-Za-z0-9_]+", parts[1]):
            raise ValueError("Unknown UI test selector: " + selector)
        suite = parts[1]
        if not (source / (suite + ".swift")).is_file():
            raise ValueError("Unknown UI test suite: " + suite)
        methods = set(re.findall(r"\bfunc\s+(test\w+)\s*\(", (source / (suite + ".swift")).read_text()))
        selected = methods if len(parts) == 2 else {parts[2]} & methods
        if not selected:
            raise ValueError("Selector has no declared XCTest methods: " + selector)
        names.update(suite + "." + method for method in selected)
    return names


def verify(log, names):
    pattern = (r"Test Case '-\[MinisUITests\.(\w+) (\w+)\]' (passed|failed|skipped)"
               r"|Test case '(\w+)\.(\w+)\(\)' (passed|failed|skipped) on")
    results = {}
    for found in re.finditer(pattern, log):
        suite, method, verdict = found.groups()[:3] if found.group(1) else found.groups()[3:]
        results[suite + "." + method] = verdict
    missing = sorted(name for name in names if results.get(name) != "passed")
    if not names or missing:
        raise ValueError("UI methods without final PASS: " + ", ".join(missing or ["no methods selected"]))
    return len(names)


if __name__ == "__main__":
    try:
        count = verify(Path(sys.argv[1]).read_text(errors="replace"), expected(sys.argv[2:]))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
    print(f"Verified {count}/{count} named UI methods")
