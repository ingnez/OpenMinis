# OpenMinis 云电脑桌面接管与 VPS 架构设计规范 (desktop-interface.md)

本文档定义了 OpenMinis 云电脑桌面接管、Xvfb + Openbox + x11vnc + websockify/noVNC、虚拟环境 (venv) 与 Playwright Chromium 浏览器持久化配置的标准接口与部署规范。

---

## 1. 核心目录与路径规范
- **代码安装目录**: `/opt/openminis-cloud-agent` (root 所有)
- **服务工作目录**: `/var/lib/openminis-cloud-agent` (专用用户 `openminis` 所有)
- **Python 虚拟环境**: `/opt/openminis-cloud-agent/venv`
- **Playwright 浏览器持久化目录 (`PLAYWRIGHT_BROWSERS_PATH`)**: `/var/lib/openminis-cloud-agent/ms-playwright`
- **浏览器用户 Profile 目录**: `/var/lib/openminis-cloud-agent/chromium-profile`
- **认证 Token 文件**: `/etc/openminis/token` (600 权限，归属 `openminis`)

---

## 2. 桌面守护进程与环境变量
云电脑采用单例统一虚拟桌面（`DISPLAY=:99`），供 Agent 执行、图形自动化测试及浏览器接管共享。

### systemd 服务配置 (`/etc/systemd/system/openminis-cloud-agent.service`)
```ini
[Unit]
Description=OpenMinis Cloud Agent Service with Desktop & noVNC
After=network.target

[Service]
Type=simple
User=openminis
Group=openminis
WorkingDirectory=/var/lib/openminis-cloud-agent
ExecStart=/opt/openminis-cloud-agent/venv/bin/python3 /opt/openminis-cloud-agent/cloud_agent_server.py
Restart=always
RestartSec=5

# 桌面与浏览器环境变量
Environment=DISPLAY=:99
Environment=PLAYWRIGHT_BROWSERS_PATH=/var/lib/openminis-cloud-agent/ms-playwright
Environment=HOME=/var/lib/openminis-cloud-agent
Environment=OPENMINIS_HOST=127.0.0.1
Environment=OPENMINIS_PORT=18765
Environment=OPENMINIS_DB=/var/lib/openminis-cloud-agent/data/openminis_agent.db
Environment=OPENMINIS_WORKSPACE=/var/lib/openminis-cloud-agent/workspace
Environment=OPENMINIS_TOKEN_FILE=/etc/openminis/token

# 安全加固
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

---

## 3. 安装脚本职责划分 (`cloud-agent/install-desktop.sh`)
- 由主 Agent 的 `install.sh` 或独立 `--computer` 参数触发。
- 幂等安装：
  1. 安装系统依赖：`xvfb openbox x11vnc websockify python3-pip python3-venv xdotool scrot curl`
  2. 建立虚拟环境 `/opt/openminis-cloud-agent/venv` 并通过 pip 安装 `playwright`。
  3. 执行 `/opt/openminis-cloud-agent/venv/bin/python3 -m playwright install chromium`，指定 `PLAYWRIGHT_BROWSERS_PATH=/var/lib/openminis-cloud-agent/ms-playwright`。
  4. 配置 Xvfb (`DISPLAY=:99`)、Openbox 窗口管理器、`x11vnc`（仅限 `127.0.0.1:5901`）与 `websockify`（仅限 `127.0.0.1:18766` 转接 5901）。
  5. 注册并启用 systemd 服务。

---

## 4. iOS 客户端接管界面 (`CloudDesktopView.swift` / `CloudConnection.swift`)
- **SSH 隧道转发**：连接 VPS 时同时转发 API (`18765`) 与无VNC桌面 (`18766`)。
- **WebView 加载**：使用 `WKWebView` 加载经本地 SSH 隧道的 `http://127.0.0.1:18766/vnc.html?autoconnect=1&resize=remote`。
- **安全红线**：禁止在 URL Query 中明文传递 Token；采用本地 loopback 隔离及 cookies 隔离。
