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
APT_OPTS="-o Acquire::Retries=2 -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 -o DPkg::Lock::Timeout=120"
timeout 300 apt-get $APT_OPTS update || echo "[-] 警告: apt-get update 未完成（网络慢或软件源不可达），继续使用本地缓存"
timeout 1500 apt-get $APT_OPTS install -y \
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

# pip 依次尝试官方 PyPI 与国内镜像（清华 / 阿里云），每个源带超时，避免国内 VPS 卡死
PIP_INDEXES="${OPENMINIS_PIP_INDEX:-} https://pypi.org/simple https://pypi.tuna.tsinghua.edu.cn/simple https://mirrors.aliyun.com/pypi/simple"
pip_install() {
    for idx in $PIP_INDEXES; do
        echo "[+] pip install $* （源: $idx）"
        if timeout 900 "$VENV_DIR/bin/pip" install --disable-pip-version-check --timeout 30 --retries 2 -i "$idx" "$@"; then
            return 0
        fi
        echo "[-] 该源安装失败，尝试下一个源…"
    done
    return 1
}
pip_install --upgrade pip || echo "[-] 警告: pip 升级失败，继续使用现有版本"
pip_install playwright==1.49.0
# 凭据加密 (AES-256-GCM)；服务以 venv 解释器运行，系统包对其不可见
pip_install "cryptography>=41,<46"

echo "[+] 正在通过 playwright install --with-deps chromium 安装浏览器及依赖..."
# 浏览器下载依次尝试官方 CDN 与 npmmirror 国内镜像
PW_OK=0
for host in "${OPENMINIS_PLAYWRIGHT_HOST:-}" "" "https://cdn.npmmirror.com/binaries/playwright"; do
    if [ -n "$host" ]; then echo "[+] 使用浏览器下载镜像: $host"; fi
    if timeout 1500 env HOME="$VAR_LIB_DIR" PLAYWRIGHT_BROWSERS_PATH="$PW_BROWSERS" ${host:+PLAYWRIGHT_DOWNLOAD_HOST="$host"} \
        "$VENV_DIR/bin/python3" -m playwright install --with-deps chromium; then
        PW_OK=1
        break
    fi
    echo "[-] Chromium 下载失败，尝试下一个下载源…"
done
if [ "$PW_OK" != 1 ]; then
    echo "[-] 错误: 无法下载 Playwright Chromium（官方与国内镜像均失败）"
    exit 1
fi

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
StartLimitIntervalSec=0

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
StartLimitIntervalSec=0

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
ExecStart=/bin/bash -c 'openbox & exec x11vnc -display :99 -rfbport 5901 -listen 127.0.0.1 -nopw -forever -shared -wait 5 -defer 5 -auth /var/lib/openminis-cloud-agent/.Xauthority'
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

# 每个 Bot 的独立屏幕通过 websockify token 区分：main = 主屏 :99，bot-<id> 由 Agent 按需写入
TOKEN_DIR="$VAR_LIB_DIR/vnc-tokens"
mkdir -p "$TOKEN_DIR"
echo "main: 127.0.0.1:5901" > "$TOKEN_DIR/main"
chown -R "$SERVICE_USER:$SERVICE_USER" "$TOKEN_DIR"
WEBSOCKIFY_TARGET="127.0.0.1:5901"
if /usr/bin/websockify --help 2>&1 | grep -q -- "--token-plugin"; then
    WEBSOCKIFY_TARGET="--token-plugin TokenFile --token-source $TOKEN_DIR"
else
    rm -f "$TOKEN_DIR/main"  # 旧版 websockify 不支持 token：手机端回退到只看主屏
fi

# noVNC 网页目录覆盖一层 defaults.json：没带 path 的旧版客户端在 token 模式下也默认连主屏（token=main）
NOVNC_OVERLAY="$VAR_LIB_DIR/novnc-web"
rm -rf "$NOVNC_OVERLAY"
cp -rL "$NOVNC_WEB_PATH" "$NOVNC_OVERLAY"
if [ "$WEBSOCKIFY_TARGET" != "127.0.0.1:5901" ]; then
    echo '{"path": "websockify?token=main", "autoconnect": true, "reconnect": true, "resize": "scale"}' > "$NOVNC_OVERLAY/defaults.json"
else
    echo '{"autoconnect": true, "reconnect": true, "resize": "scale"}' > "$NOVNC_OVERLAY/defaults.json"
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$NOVNC_OVERLAY"
NOVNC_WEB_PATH="$NOVNC_OVERLAY"

cat << EOF > /etc/systemd/system/openminis-novnc.service
[Unit]
Description=OpenMinis noVNC Web & Websockify Proxy
After=openminis-vnc.service
Wants=openminis-vnc.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=HOME=$VAR_LIB_DIR
Environment=XDG_CONFIG_HOME=$VAR_LIB_DIR/.config
Environment=XDG_CACHE_HOME=$VAR_LIB_DIR/.cache
ExecStart=/usr/bin/websockify --web=$NOVNC_WEB_PATH 127.0.0.1:18766 $WEBSOCKIFY_TARGET
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
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$VAR_LIB_DIR
ExecStart=$VENV_DIR/bin/python3 $INSTALL_DIR/cloud_agent_server.py
Restart=always
RestartSec=5
# Agent 每 15 秒自查 /health 后喂狗；HTTP 卡死 90 秒没喂狗时 systemd 重启它
WatchdogSec=90
NotifyAccess=main

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
Environment=OPENMINIS_VNC_TOKENS=$VAR_LIB_DIR/vnc-tokens

NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

chown -R "$SERVICE_USER:$SERVICE_USER" "$VAR_LIB_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$PW_BROWSERS"

# 4.5 自检定时器：每分钟检查 Xvfb / x11vnc / websockify / Agent，哪段不通就重启哪段；
#     手机点「重启桌面」时 Agent 写入请求文件，由 root 的 path 单元执行重启——Agent 本身不需要 sudo
RUN_DIR="$VAR_LIB_DIR/run"
mkdir -p "$RUN_DIR"
chown "$SERVICE_USER:$SERVICE_USER" "$RUN_DIR"
mkdir -p /usr/local/lib/openminis
cat << 'EOF' > /usr/local/lib/openminis/desktop-check.sh
#!/bin/bash
# OpenMinis 桌面与 Agent 自检：不通就重启对应服务（幂等，可随时运行）
port_open() { timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }
log() { echo "[openminis-check] $*"; }
REQ=/var/lib/openminis-cloud-agent/run/desktop-restart.request
if [ -f "$REQ" ]; then
    log "收到手机的重启桌面请求"
    rm -f "$REQ"
    systemctl restart openminis-display openminis-vnc openminis-novnc
    exit 0
fi
if [ ! -S /tmp/.X11-unix/X99 ] || ! systemctl is-active --quiet openminis-display; then
    log "Xvfb :99 未运行，重启桌面"
    systemctl restart openminis-display openminis-vnc openminis-novnc
    exit 0
fi
if ! port_open 5901; then
    log "x11vnc 5901 不通，重启 VNC"
    systemctl restart openminis-vnc openminis-novnc
    exit 0
fi
if ! port_open 18766; then
    log "websockify 18766 不通，重启 noVNC"
    systemctl restart openminis-novnc
fi
if ! curl -fsS --max-time 5 http://127.0.0.1:18765/livez >/dev/null 2>&1; then
    sleep 10
    if ! curl -fsS --max-time 5 http://127.0.0.1:18765/livez >/dev/null 2>&1; then
        log "Agent 无应答，重启 Agent"
        systemctl restart openminis-cloud-agent
    fi
fi
EOF
chmod 755 /usr/local/lib/openminis/desktop-check.sh
cat << EOF > /etc/systemd/system/openminis-check.service
[Unit]
Description=OpenMinis desktop & agent self-check

[Service]
Type=oneshot
ExecStart=/usr/local/lib/openminis/desktop-check.sh
EOF
cat << EOF > /etc/systemd/system/openminis-check.timer
[Unit]
Description=OpenMinis self-check every minute

[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
EOF
cat << EOF > /etc/systemd/system/openminis-desktop-restart.path
[Unit]
Description=OpenMinis desktop restart request from the app

[Path]
PathExists=$RUN_DIR/desktop-restart.request
Unit=openminis-check.service

[Install]
WantedBy=multi-user.target
EOF

echo "=== [Desktop] 5. 重新加载并启用所有 Systemd 服务 ==="
systemctl daemon-reload
systemctl enable openminis-display openminis-vnc openminis-novnc openminis-cloud-agent
systemctl enable --now openminis-check.timer openminis-desktop-restart.path
systemctl restart openminis-display
systemctl restart openminis-vnc
systemctl restart openminis-novnc
systemctl restart openminis-cloud-agent

# 服务启动可能需要十几秒（迁移、插件注册表、定时任务）：轮询最长 45 秒，而不是固定 sleep
for i in $(seq 1 45); do
    if curl -fsS --max-time 3 http://127.0.0.1:18765/health >/dev/null 2>&1 \
       && curl -fsS --max-time 3 http://127.0.0.1:18766/vnc.html >/dev/null 2>&1; then
        break
    fi
    if [ $((i % 10)) -eq 0 ]; then echo "[.] 等待 Agent 与 noVNC 就绪… ${i}s"; fi
    sleep 1
done

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
' || {
    echo "----- 服务状态 -----"
    for u in openminis-cloud-agent openminis-display openminis-vnc openminis-novnc; do
        echo "$u: $(systemctl is-active $u 2>&1)"
    done
    echo "----- journalctl -u openminis-cloud-agent（最近 40 行）-----"
    journalctl -u openminis-cloud-agent --no-pager -n 40 2>&1 || true
    echo "----- journalctl -u openminis-novnc（最近 15 行）-----"
    journalctl -u openminis-novnc --no-pager -n 15 2>&1 || true
    exit 1
}
