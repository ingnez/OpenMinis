#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 xcodebuild test 的日志里列出每个 UI 测试流程 PASS / FAIL（附失败原因）。
用法：e2e_summary.py ui-tests.log [xcresult-summary.json] [xcresult-tests.json]
优先用 xcresulttool get test-results tests 的 JSON（每个用例的结果、重试），日志解析是兜底。
日志有两种写法：老的「Test Case '-[MinisUITests.类 方法]' passed (1.0 seconds)」，
Xcode 26 并行 / 克隆模拟器时是「Test case '类.方法()' passed on 'Clone 1 of …' (1.0 seconds)」。
失败原因优先从 xcresulttool get test-results summary 的 JSON 里取（日志里不一定有）。
同一个测试重试过（-retry-tests-on-failure）时按最后一次算，并注明重试次数。"""
import json
import re
import sys

log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
reasons = {}
if len(sys.argv) > 2:
    try:
        summary = json.load(open(sys.argv[2], encoding="utf-8"))
        for f in summary.get("testFailures", []):
            key = (f.get("testIdentifierString") or f.get("testName") or "").replace("/", ".")
            reasons.setdefault(key, (f.get("failureText") or "").strip()[:200])
    except Exception:
        pass

runs = []   # (cls, name, verdict, secs)
for cls, name, verdict, secs in re.findall(r"Test Case '-\[MinisUITests\.(\w+) (\w+)\]' (passed|failed) \(([\d.]+) seconds\)", log):
    runs.append((cls, name, verdict, secs))
for cls, name, verdict, secs in re.findall(r"Test case '(\w+)\.(\w+)\(\)' (passed|failed) on '[^']*' \(([\d.]+) seconds\)", log):
    runs.append((cls, name, verdict, secs))

def walk_tests(node, out):
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            ident = node.get("nodeIdentifier") or node.get("name", "")
            parts = ident.replace("()", "").split("/")
            cls, name = (parts[-2], parts[-1]) if len(parts) >= 2 else ("?", parts[-1])
            reps = [c for c in node.get("children", []) if c.get("nodeType") == "Repetition"]
            verdict = "passed" if node.get("result") == "Passed" else "failed"
            dur = str(node.get("durationInSeconds") or node.get("duration") or "").rstrip("s")
            for _ in range(max(1, len(reps)) - 1):
                out.append((cls, name, "failed", ""))
            out.append((cls, name, verdict, dur))
            if verdict == "failed":
                msgs = [c.get("name", "") for c in node.get("children", []) if c.get("nodeType") == "Failure Message"]
                for r in reps:
                    msgs += [c.get("name", "") for c in r.get("children", []) if c.get("nodeType") == "Failure Message"]
                if msgs:
                    reasons.setdefault(f"{cls}.{name}", msgs[-1][:200])
        for c in node.get("children", []) or node.get("testNodes", []):
            walk_tests(c, out)
    elif isinstance(node, list):
        for c in node:
            walk_tests(c, out)


if len(sys.argv) > 3:
    try:
        from_json = []
        walk_tests(json.load(open(sys.argv[3], encoding="utf-8")), from_json)
        if from_json:
            runs = from_json
    except Exception:
        pass

order, last, tries = [], {}, {}
for cls, name, verdict, secs in runs:
    key = f"{cls}.{name}"
    if key not in last:
        order.append(key)
    last[key] = (verdict, secs)
    tries[key] = tries.get(key, 0) + 1

rows = []
for key in order:
    verdict, secs = last[key]
    why = ""
    if verdict == "failed":
        cls, name = key.split(".", 1)
        why = reasons.get(f"{cls}.{name}()") or reasons.get(key) or ""
        if not why:
            m = re.search(rf"error: -\[MinisUITests\.{cls} {name}\] : (.+)", log)
            why = m.group(1).strip()[:200] if m else ""
    note = f"（重试 {tries[key] - 1} 次）" if tries[key] > 1 else ""
    rows.append(f"| {key} | {'PASS' if verdict == 'passed' else 'FAIL'}{note} | {secs}s | {why.replace('|', '/')} |")
print("| 流程 | 结果 | 用时 | 失败原因 |\n|---|---|---|---|")
print("\n".join(rows) if rows else "| （日志里没有测试结果，可能没编译成功） | FAIL | | |")
passed = sum(1 for r in rows if "| PASS" in r)
print(f"\n共 {len(rows)} 个，通过 {passed} 个")
