#!/usr/bin/env python3
"""完整构建的云端类型检查不包含 Agent/Intents 和 AgentWidget，快速检查却包含：
云端目录如果用到只在那两处声明的类型 / 静态成员，快速检查绿、完整构建红（2026-11-11 撞过一次）。
这里静态找出这种引用，提前在快速检查里失败。"""
import glob
import re
import sys

EXTRA = sorted(glob.glob("src/ios/Agent/Intents/*.swift")) + ["src/ios/AgentWidget/CloudBotsWidget.swift"]
CLOUD = sorted(glob.glob("src/ios/Views/Chat/AIChatView/Cloud/*.swift") + glob.glob("src/ios/Views/Chat/AIChatView/Images/*.swift")
               + glob.glob("src/ios/WatchShared/*.swift") + glob.glob("scripts/*TypecheckSupport.swift"))
DECL = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:public |private |fileprivate |internal |final |nonisolated )*"
                  r"(?:struct|enum|class|actor|protocol|typealias)\s+([A-Z]\w*)", re.M)
STATIC = re.compile(r"^\s*(?:public |internal )?static (?:let|var) (\w+)", re.M)


def strip_comments(src):
    src = re.sub(r'""".*?"""', '""', src, flags=re.S)
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', src)      # 字符串字面量里的词不算引用
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


def declared(paths):
    types, statics = set(), set()
    for p in paths:
        try:
            s = strip_comments(open(p, encoding="utf-8").read())
        except OSError:
            continue
        types |= set(DECL.findall(s))
        # 只看扩展里的静态成员（如 extension Notification.Name { static let x }），类型内部的成员通过类型名引用
        for m in re.finditer(r"extension\s+[\w.]+\s*(?::[^{]*)?\{(.*?)\n\}", s, re.S):
            statics |= set(STATIC.findall(m.group(1)))
    return types, statics


def main():
    ext_types, ext_statics = declared(EXTRA)
    cloud_types, cloud_statics = declared(CLOUD)
    only_types = ext_types - cloud_types
    only_statics = ext_statics - cloud_statics
    bad = []
    for p in CLOUD:
        s = strip_comments(open(p, encoding="utf-8").read())
        for t in only_types:
            if re.search(r"\b%s\b" % re.escape(t), s):
                bad.append(f"{p}: 用到 {t}（只在 Intents / Widget 里声明）")
        for n in only_statics:
            if re.search(r"\.%s\b" % re.escape(n), s):
                bad.append(f"{p}: 用到 .{n}（只在 Intents / Widget 的扩展里声明）")
    if bad:
        print("\n".join(bad))
        print("::error::云端目录引用了完整构建类型检查里不存在的声明，请把声明挪到云端目录")
        return 1
    print(f"ok：云端目录没有引用只在 Intents / Widget 里的声明（检查了 {len(only_types)} 个类型、{len(only_statics)} 个扩展静态成员）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
