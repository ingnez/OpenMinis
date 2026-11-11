#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 xcodebuild test 的日志里列出每个 UI 测试流程 PASS / FAIL（附失败原因）。"""
import re
import sys

log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
rows = []
for cls, name, verdict, secs in re.findall(r"Test Case '-\[MinisUITests\.(\w+) (\w+)\]' (passed|failed) \(([\d.]+) seconds\)", log):
    why = ""
    if verdict == "failed":
        m = re.search(rf"error: -\[MinisUITests\.{cls} {name}\] : (.+)", log)
        why = m.group(1).strip()[:200] if m else ""
    rows.append(f"| {cls}.{name} | {'PASS' if verdict == 'passed' else 'FAIL'} | {secs}s | {why} |")
print("| 流程 | 结果 | 用时 | 失败原因 |\n|---|---|---|---|")
print("\n".join(rows) if rows else "| （日志里没有测试结果，可能没编译成功） | FAIL | | |")
total = len(rows)
passed = sum(1 for r in rows if "| PASS |" in r)
print(f"\n共 {total} 个，通过 {passed} 个")
