#!/usr/bin/env python3
"""把已测流程 / 需真机验证写成 测试清单.md，打包进 IPA 并作为构建产物。"""
from __future__ import annotations

import argparse
import datetime
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "src/ios/Views/Chat/AIChatView/Cloud/CloudIPAChecklist.swift"


def items(kind: str) -> list[tuple[str, str]]:
    text = SRC.read_text(encoding="utf-8")
    # static let tested / needsDevice 两个数组
    m = re.search(rf"static let {kind}: \[Item\] = \[(.*?)\]", text, re.S)
    if not m:
        raise SystemExit(f"CloudIPAChecklist.swift 里找不到 {kind}")
    return re.findall(r'Item\(name: "([^"]+)", note: "([^"]+)"\)', m.group(1))


def markdown(commit: str | None, built_at: str | None) -> str:
    lines = ["# OpenMinis 测试清单", ""]
    if built_at:
        lines.append(f"- 生成时间：{built_at}")
    if commit:
        lines.append(f"- 源码提交：{commit}")
    lines += ["", "## 已测流程", ""]
    for name, note in items("tested"):
        lines.append(f"- {name}：{note}")
    lines += ["", "## 需真机验证", ""]
    for name, note in items("needsDevice"):
        lines.append(f"- {name}：{note}")
    lines += ["", "本清单随 IPA 一起分发，不包含密钥或个人信息。", ""]
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--commit", default="")
    p.add_argument("--built-at", default="")
    args = p.parse_args()
    built = args.built_at or datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    text = markdown(args.commit or None, built)
    if "sk-" in text or "BEGIN " in text:
        print("清单里出现了可疑密钥片段", file=sys.stderr)
        return 1
    if "## 已测流程" not in text or "## 需真机验证" not in text:
        print("清单缺少必要章节", file=sys.stderr)
        return 1
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(f"wrote {out} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
