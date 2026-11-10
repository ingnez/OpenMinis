#!/usr/bin/env python3
"""Bot 模式的设置入口回归：齿轮打开 Bot 设置（不是 App 设置），里面直接有云电脑设置、安装 / 更新服务器 Agent 服务、保管库；
连接横幅 / 状态点的修复按钮直接到云电脑设置（以前走 App 设置，那里已经没有云电脑设置，是死路）。"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..")
home = open(os.path.join(ROOT, "src/ios/Views/Chat/AIChatView/Cloud/CloudBotHome.swift"), encoding="utf-8").read()
errors = []
hub = home[home.index("struct CloudBotHubView"):home.index("struct CloudBotChatView")]
for needle in ("CloudAgentSettingsView()", "安装 / 更新服务器 Agent 服务", "CloudVaultSettingsRow()"):
    if needle not in hub:
        errors.append(f"Bot 设置页缺少 {needle}")
m = re.search(r"primaryAction:\s*\{(.*?)\}", home, re.S)
if not m or "openBotSettings()" not in m.group(1):
    errors.append("齿轮轻点应打开 Bot 设置（openBotSettings）")
for banner in ("CloudLinkBanner(onOpenSettings:", "CloudLinkDot(onOpenSettings:"):
    for hit in re.finditer(re.escape(banner) + r"\s*([A-Za-z_]+)\)", home):
        if hit.group(1) != "openCloudSettings":
            errors.append(f"{banner} 应传 openCloudSettings，现在是 {hit.group(1)}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("ok：Bot 模式齿轮打开 Bot 设置，云电脑设置 / 安装更新 / 保管库都在，修复按钮直达云电脑设置")
