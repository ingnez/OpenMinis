#!/bin/bash
# ==============================================================================
# OpenMinis Cloud Agent & Desktop Installation Script (install-desktop.sh)
# 作用: 在 Debian / Ubuntu VPS 上幂等安装 Xvfb + Openbox + x11vnc + novnc + Playwright Chromium
# 架构: 专用用户 openminis 运行，DISPLAY=:99，拆分独立 systemd 服务避免冲突。
# ==============================================================================

set -e

SERVICE_USER="openminis"
INSTALL_DIR="/opt/openminis-cloud-agent"
VAR_LIB_DIR="/var/lib/openminis-cloud-agent"
CONFIG_DIR="/etc/openminis"
TOKEN_FILE="$CONFIG_DIR/token"
MASTER_KEY_FILE="$CONFIG_DIR/master.key"
VENV_DIR="$INSTALL_DIR/venv"
PW_BROWSERS="$VAR_LIB_DIR/ms-playwright"

echo "=== [Desktop] 1. 检查 root 权限与系统支持 ==="
if [ "$EUID" -ne 0 ]; then
  echo "[-] 错误: 请以 root 权限运行此安装脚本 (sudo bash install-desktop.sh)"
  exit 1
fi

if ! command -v systemctl &> /dev/null; then
  echo "[-] 错误: 未检测到 systemd。"
  exit 1
fi

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$CURRENT_DIR/install.sh" ]; then
    bash "$CURRENT_DIR/install.sh"
fi

echo "[+] 检查并安装系统级桌面、VNC、novnc 与 x11-utils 依赖包..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    xvfb \
    openbox \
    x11vnc \
    novnc \
    websockify \
    xdotool \
    scrot \
    curl \
    git \
    net-tools \
    x11-utils \
    xauth \
    xclip \
    openssl

echo "=== [Desktop] 2. 创建或核验专用用户 ($SERVICE_USER) ==="
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -s /bin/bash -m -d "$VAR_LIB_DIR" "$SERVICE_USER"
    echo "[+] 创建用户 $SERVICE_USER 成功 (Home: $VAR_LIB_DIR)。"
else
    echo "[+] 用户 $SERVICE_USER 已存在。"
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$VAR_LIB_DIR/workspace"
mkdir -p "$VAR_LIB_DIR/data"
mkdir -p "$PW_BROWSERS"
mkdir -p "$CONFIG_DIR"
mkdir -p "$VAR_LIB_DIR/.config" "$VAR_LIB_DIR/.cache"
chown -R "$SERVICE_USER:$SERVICE_USER" "$VAR_LIB_DIR/.config" "$VAR_LIB_DIR/.cache"

echo "=== [Desktop] 3. 配置 Python 虚拟环境与 pinned Playwright Chromium ==="
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install playwright==1.49.0
# 凭据加密 (AES-256-GCM)；服务以 venv 解释器运行，系统包对其不可见
"$VENV_DIR/bin/pip" install "cryptography>=41,<46"

echo "[+] 正在通过 playwright install --with-deps chromium 安装浏览器及依赖..."
env HOME="$VAR_LIB_DIR" PLAYWRIGHT_BROWSERS_PATH="$PW_BROWSERS" "$VENV_DIR/bin/python3" -m playwright install --with-deps chromium

echo "=== [Desktop] 4. 配置独立 Systemd 服务 (Display :99, x11vnc, novnc, agent) ==="
AUTH_FILE="$VAR_LIB_DIR/.Xauthority"
if [ ! -s "$AUTH_FILE" ]; then
    touch "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    xauth -f "$AUTH_FILE" add :99 . "$(openssl rand -hex 16)"
fi
chown "$SERVICE_USER:$SERVICE_USER" "$AUTH_FILE"

# 4.1 Xvfb Display 服务
cat << EOF > /etc/systemd/system/openminis-display.service
[Unit]
Description=OpenMinis Virtual X11 Display (:99)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=HOME=$VAR_LIB_DIR
Environment=XDG_CONFIG_HOME=$VAR_LIB_DIR/.config
Environment=XDG_CACHE_HOME=$VAR_LIB_DIR/.cache
ExecStart=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -auth $AUTH_FILE +extension GLX +render -noreset -nolisten tcp
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 4.2 Openbox 窗口管理器与 x11vnc 服务
cat << EOF > /etc/systemd/system/openminis-vnc.service
[Unit]
Description=OpenMinis Openbox & x11vnc Service
After=openminis-display.service
Requires=openminis-display.service

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=DISPLAY=:99
Environment=XAUTHORITY=$AUTH_FILE
Environment=HOME=$VAR_LIB_DIR
Environment=XDG_CONFIG_HOME=$VAR_LIB_DIR/.config
Environment=XDG_CACHE_HOME=$VAR_LIB_DIR/.cache
ExecStartPre=/bin/sleep 2
ExecStart=/bin/bash -c 'openbox & exec x11vnc -display :99 -rfbport 5901 -listen 127.0.0.1 -nopw -forever -shared -auth /var/lib/openminis-cloud-agent/.Xauthority'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 4.3 noVNC / websockify 服务
NOVNC_WEB_PATH=""
for d in /usr/share/novnc /usr/share/websockify/obs-websockify /usr/local/share/novnc; do
    if [ -f "$d/vnc.html" ]; then NOVNC_WEB_PATH="$d"; break; fi
done
if [ -z "$NOVNC_WEB_PATH" ]; then
    echo "[-] noVNC vnc.html 未安装，无法提供桌面接管"
    exit 1
fi

cat << EOF > /etc/systemd/system/openminis-novnc.service
[Unit]
Description=OpenMinis noVNC Web & Websockify Proxy
After=openminis-vnc.service
Requires=openminis-vnc.service

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=HOME=$VAR_LIB_DIR
Environment=XDG_CONFIG_HOME=$VAR_LIB_DIR/.config
Environment=XDG_CACHE_HOME=$VAR_LIB_DIR/.cache
ExecStart=/usr/bin/websockify --web=$NOVNC_WEB_PATH 127.0.0.1:18766 127.0.0.1:5901
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 4.4 Cloud Agent 主服务（依赖桌面，但不因桌面重启而终止）
SERVICE_FILE="/etc/systemd/system/openminis-cloud-agent.service"
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=OpenMinis Cloud Agent Core Service
After=network.target openminis-novnc.service

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$VAR_LIB_DIR
ExecStart=$VENV_DIR/bin/python3 $INSTALL_DIR/cloud_agent_server.py
Restart=always
RestartSec=5

Environment=DISPLAY=:99
Environment=XAUTHORITY=$AUTH_FILE
Environment=PLAYWRIGHT_BROWSERS_PATH=$PW_BROWSERS
Environment=HOME=$VAR_LIB_DIR
Environment=XDG_CONFIG_HOME=$VAR_LIB_DIR/.config
Environment=XDG_CACHE_HOME=$VAR_LIB_DIR/.cache
Environment=OPENMINIS_HOST=127.0.0.1
Environment=OPENMINIS_PORT=18765
Environment=OPENMINIS_DB=$VAR_LIB_DIR/data/openminis_agent.db
Environment=OPENMINIS_WORKSPACE=$VAR_LIB_DIR/workspace
Environment=OPENMINIS_TOKEN_FILE=$TOKEN_FILE
Environment=OPENMINIS_MASTER_KEY_FILE=$MASTER_KEY_FILE

NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

chown -R "$SERVICE_USER:$SERVICE_USER" "$VAR_LIB_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$PW_BROWSERS"

echo "=== [Desktop] 5. 重新加载并启用所有 Systemd 服务 ==="
systemctl daemon-reload
systemctl enable openminis-display openminis-vnc openminis-novnc openminis-cloud-agent
systemctl restart openminis-display
systemctl restart openminis-vnc
systemctl restart openminis-novnc
systemctl restart openminis-cloud-agent

sleep 3

echo "=== [Desktop] 6. 严格健康与功能检查 ==="
env XAUTHORITY="$AUTH_FILE" python3 -c '
import urllib.request, json, sys, subprocess

# 1. Check API health (18765)
try:
    req = urllib.request.Request("http://127.0.0.1:18765/health", method="GET")
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        assert data.get("status") == "ok"
    print("[+] API 健康检查通过 (18765)")
except Exception as e:
    print(f"[-] API 检查失败: {e}")
    sys.exit(1)

# 2. Check Xvfb DISPLAY=:99 via xdpyinfo
if subprocess.run("xdpyinfo -display :99 >/dev/null 2>&1", shell=True).returncode != 0:
    print("[-] Xvfb DISPLAY=:99 检查失败 (xdpyinfo)")
    sys.exit(1)
print("[+] Xvfb :99 运行检查通过")

# 3. Check noVNC port 18766 & exact vnc.html / core/rfb.js content
try:
    req = urllib.request.Request("http://127.0.0.1:18766/vnc.html", method="GET")
    with urllib.request.urlopen(req, timeout=5) as resp:
        assert resp.status == 200
        html_content = resp.read().decode("utf-8")
        assert "noVNC" in html_content or "RFB" in html_content
    print("[+] noVNC vnc.html 检查通过 (HTTP 200, 包含 noVNC 标识)")
except Exception as e:
    print(f"[-] noVNC vnc.html 检查失败: {e}")
    sys.exit(1)

print("[+] 所有桌面服务与健康检查 100% 通过！")
'
