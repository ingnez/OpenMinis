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
# 11-11：左上角改成用户首字母圆头像，轻点打开 Bot 设置，中间不再有「Minis Bot ⌄」切换器
if "CloudUserAvatarButton(onTap: openBotSettings" not in home:
    errors.append("左上角头像轻点应打开 Bot 设置（openBotSettings）")
header = open(os.path.join(ROOT, "src/ios/Views/Chat/AIChatView/Cloud/CloudHomeHeader.swift"), encoding="utf-8").read()
m = re.search(r"primaryAction:\s*\{(.*?)\}", header, re.S)
if not m or "onTap()" not in m.group(1):
    errors.append("头像的 primaryAction 应调用 onTap()")
principal = re.search(r"ToolbarItem\(placement: \.principal\)\s*\{(.*?)\n                \}", home, re.S)
if not principal or "Minis Bot" in principal.group(1) or "Menu" in principal.group(1):
    errors.append("Bot 首页顶栏中间不应再有「Minis Bot ⌄」切换器")
if "HomeModeRow(current: .bots" not in hub:
    errors.append("Bot 设置页缺少「模式」一行")
for banner in ("CloudLinkBanner(onOpenSettings:",):
    for hit in re.finditer(re.escape(banner) + r"\s*([A-Za-z_]+)\)", home):
        if hit.group(1) != "openCloudSettings":
            errors.append(f"{banner} 应传 openCloudSettings，现在是 {hit.group(1)}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("ok：Bot 模式齿轮打开 Bot 设置，云电脑设置 / 安装更新 / 保管库都在，修复按钮直达云电脑设置")
