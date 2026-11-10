#!/usr/bin/env python3
"""快速类型检查用替身（stub）代替另一半代码；替身的声明一旦和真实代码对不上，
快速检查会通过而完整构建失败。这里核对：替身里列出的类型，其每条 func / var / init 声明
都原样出现在真实源文件里（只比较到函数体之前，空白归一）。"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "src/ios/Views/Chat/AIChatView"
# (替身文件, 类型名, 真实源文件)
CHECKS = [
    ("scripts/RealtimeTypecheckSupport.swift", "CloudVoiceBridge", IOS / "Cloud/CloudVoiceBridge.swift"),
    ("scripts/CloudRealtimeTypecheckSupport.swift", "CloudBotRealtimeAvailability", IOS / "Realtime/CloudBotRealtimeCall.swift"),
    ("scripts/CloudRealtimeTypecheckSupport.swift", "CloudBotRealtimeCallView", IOS / "Realtime/CloudBotRealtimeCall.swift"),
]
DECL = re.compile(r"^\s*((?:@MainActor\s+)?(?:static\s+)?(?:func|var|init)\b.*)$")


def norm(text):
    return re.sub(r"\s+", " ", text).strip()


def type_block(source, name):
    m = re.search(r"\b(?:enum|struct|class)\s+" + re.escape(name) + r"\b[^{]*\{", source)
    if not m:
        return None
    depth, i = 1, m.end()
    while i < len(source) and depth:
        depth += {"{": 1, "}": -1}.get(source[i], 0)
        i += 1
    return source[m.end():i - 1]


def signature(line):
    # 声明到函数体 / 计算属性体的「 {」为止
    cut = line.find(" {")
    return norm(line if cut < 0 else line[:cut])


def main():
    failures = []
    for stub_path, name, real_path in CHECKS:
        stub = type_block((ROOT / stub_path).read_text(), name)
        if stub is None:
            failures.append(f"{stub_path}: 找不到替身类型 {name}")
            continue
        real = real_path.read_text()
        if type_block(real, name) is None:
            failures.append(f"{real_path.relative_to(ROOT)}: 找不到真实类型 {name}")
            continue
        real_norm = norm(type_block(real, name))
        for line in stub.splitlines():
            m = DECL.match(line)
            if not m or line.startswith("  " * 3):
                continue
            sig = signature(m.group(1))
            if sig.startswith("var body"):
                continue
            if sig not in real_norm:
                failures.append(f"{name}: 替身声明在真实代码里找不到 → {sig}")
    if failures:
        print("\n".join("::error::" + f for f in failures))
        sys.exit(1)
    print(f"替身声明与真实代码一致（{len(CHECKS)} 个类型）")


if __name__ == "__main__":
    main()
