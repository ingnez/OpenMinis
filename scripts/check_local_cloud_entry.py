#!/usr/bin/env python3
"""本地就是本地，Bot 就是 Bot：本地模式的界面里不能再出现云端入口（云电脑开关、云电脑设置 / 保管库、移到云端运行），
两种模式只靠左上角切换。唯一允许的桥是「交给 Bot」（LocalBotHandoff.swift）。输入栏（本地或 Bot）都不能有「云电脑」胶囊。"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..", "src", "ios")
LOCAL_DIRS = ["Views/Chat", "Views/Settings", "Views/ContentView"]
SKIP = ("Views/Chat/AIChatView/Cloud/", "Views/Chat/AIChatView/Realtime/")
ALLOWED = {"Views/Chat/LocalBotHandoff.swift", "Views/Chat/CloudStepBarHost.swift"}
BANNED = [
    (re.compile(r"executionLocationMenuButton"), "本地输入栏的「本机 / 云电脑」切换"),
    (re.compile(r"setCloudExecutionEnabled\(\s*true"), "把本地对话切到云电脑执行"),
    (re.compile(r"\"云电脑设置\""), "本地设置里的云电脑设置（放在 Bot 模式设置里）"),
    (re.compile(r"NavigationLink\s*\{\s*CloudVaultView\(\)"), "本地设置里的保管库（放在 Bot 模式设置里）"),
    (re.compile(r"\"移到云端运行\""), "本地定时任务的「移到云端运行」"),
]
# 任何输入栏都不能出现「云电脑」胶囊
CHIP = re.compile(r"(Text|Label)\(\s*\"云电脑\"|\?\s*\"云电脑\"\s*:")


def main():
    bad = []
    for d in LOCAL_DIRS:
        for dirpath, _dirs, files in os.walk(os.path.join(ROOT, d)):
            for f in files:
                if not f.endswith(".swift"):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, f), ROOT)
                if rel.startswith(SKIP) or rel in ALLOWED:
                    continue
                text = open(os.path.join(dirpath, f), encoding="utf-8").read()
                for pat, why in BANNED:
                    for m in pat.finditer(text):
                        bad.append(f"{rel}:{text.count(chr(10), 0, m.start()) + 1}: {why}")
    for dirpath, _dirs, files in os.walk(ROOT):
        for f in files:
            if f.endswith(".swift"):
                text = open(os.path.join(dirpath, f), encoding="utf-8").read()
                for m in CHIP.finditer(text):
                    rel = os.path.relpath(os.path.join(dirpath, f), ROOT)
                    bad.append(f"{rel}:{text.count(chr(10), 0, m.start()) + 1}: 「云电脑」胶囊")
    if bad:
        print("本地模式里出现了云端入口（本地就是本地，Bot 就是 Bot）：")
        print("\n".join("  " + b for b in bad))
        return 1
    print("ok：本地模式没有云端入口，输入栏没有「云电脑」胶囊")
    return 0


if __name__ == "__main__":
    sys.exit(main())
