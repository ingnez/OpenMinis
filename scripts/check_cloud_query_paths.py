#!/usr/bin/env python3
"""每个带查询参数（?）的云端 API 调用，都要在 scripts/CloudPathPolicyTests.swift 里有一条「允许」的测试用例。
CloudConnection 会拒绝没有规则的带 ? 请求；漏加规则时调用会一直静默失败（以前 /v1/notifications 就是这样）。"""
import glob
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..")
SRC = glob.glob(os.path.join(ROOT, "src/ios/Views/Chat/AIChatView/Cloud/*.swift"))
TESTS = open(os.path.join(ROOT, "scripts/CloudPathPolicyTests.swift"), encoding="utf-8").read()
allowed = [m.group(1) for m in re.finditer(r'\("(/v1/[^"?]+)\?[^"]*", true\)', TESTS)]


def route_regex(route):
    out, i = "", 0
    while i < len(route):
        if route.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(route) and depth:
                depth += {"(": 1, ")": -1}.get(route[j], 0)
                j += 1
            out += "[^/]+"
            i = j
        else:
            out += re.escape(route[i])
            i += 1
    return "^" + out + "$"


missing = []
for f in SRC:
    text = open(f, encoding="utf-8").read()
    for m in re.finditer(r'"(/v1/[^"?]*)\?', text):
        rx = route_regex(m.group(1))
        if not any(re.match(rx, a) for a in allowed):
            missing.append(f"{os.path.basename(f)}: {m.group(1)}?…")
if missing:
    print("这些带 ? 的云端调用在 CloudPathPolicyTests 里没有允许用例（多半也没在 CloudPathPolicy 里加规则）：")
    print("\n".join("  " + x for x in sorted(set(missing))))
    sys.exit(1)
print(f"ok：带 ? 的云端调用都有路径规则用例（{len(allowed)} 条）")
