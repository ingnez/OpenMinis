#!/usr/bin/env python3
"""每个 src/ios 下的 .swift 都必须在 Xcode 工程里：要么在「同步文件夹」里，要么在 pbxproj 里有文件引用。
之前 CloudIntents.swift 漏加，快速检查发现不了，完整构建才报错——这个脚本让快速检查也能拦住。"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..", "src", "ios")
PBX = os.path.join(ROOT, "Minis.xcodeproj", "project.pbxproj")
# 不属于任何 target 的目录（脚本、示例等）
IGNORE_DIRS = {"Minis.xcodeproj", "build", "Pods", "DerivedData"}
# 上游本来就不编译的旧文件 / 示例
KNOWN_UNBUILT = {
    "ISHCommandExecutionExample.swift",
    "Views/Chat/AIChatView.swift",
}


def main():
    text = open(PBX, encoding="utf-8").read()
    synced = set()
    for line in text.splitlines():
        if "isa = PBXFileSystemSynchronizedRootGroup;" in line:
            m = re.search(r"\bpath = ([^;]+);", line)
            if m:
                synced.add(m.group(1).strip('"'))
    referenced = set(os.path.basename(p.strip('"')) for p in re.findall(r"path = ([^;]+\.swift);", text))
    referenced |= set(re.findall(r"/\* ([^*]+\.swift) \*/", text))
    missing = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in IGNORE_DIRS]
        parts = os.path.relpath(dirpath, ROOT).split(os.sep)
        # 同步文件夹只按名字认，会把同名的普通分组（比如 Agent/Markdown 和 Views/Chat/Markdown）也当成同步的；
        # 目录里已有文件是逐个引用的，就说明它是普通分组，新文件也得逐个加
        explicit = any(f.endswith(".swift") and f in referenced for f in filenames)
        if any(p in synced for p in parts) and not explicit:
            continue
        for f in filenames:
            rel = os.path.relpath(os.path.join(dirpath, f), ROOT)
            if f.endswith(".swift") and f not in referenced and rel not in KNOWN_UNBUILT:
                missing.append(rel)
    if missing:
        print("这些 Swift 文件不在 Xcode 工程里（完整构建会漏编译）：")
        for m in sorted(missing):
            print("  " + m)
        return 1
    print(f"ok：所有 Swift 文件都在工程里（同步文件夹 {len(synced)} 个）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
