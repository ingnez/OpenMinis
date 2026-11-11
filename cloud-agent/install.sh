#!/bin/bash
# ==============================================================================
# OpenMinis Cloud Agent Service - 安装与部署脚本 (install.sh)
# 作用: 在 VPS 服务器上安装/配置 OpenMinis 常驻 Agent 后台服务 (systemd)
# 支持发行版: 仅支持 Debian / Ubuntu（尚需目标 VPS 实际环境验证）
# 特点: 非 root 运行（创建专用用户 openminis），配置 600 权限 Token 文件，
#       仅复制必要服务与文档文件至 /opt/openminis-cloud-agent (root 所有)，
#       工作目录 /var/lib/openminis-cloud-agent (openminis 所有)。
# ==============================================================================

set -e

SERVICE_USER="openminis"
INSTALL_DIR="/opt/openminis-cloud-agent"
VAR_LIB_DIR="/var/lib/openminis-cloud-agent"
CONFIG_DIR="/etc/openminis"
TOKEN_FILE="$CONFIG_DIR/token"
MASTER_KEY_FILE="$CONFIG_DIR/master.key"
SERVICE_FILE="/etc/systemd/system/openminis-cloud-agent.service"

echo "=== 1. 检查权限与操作系统支持 ==="
if [ "$EUID" -ne 0 ]; then
  echo "[-] 错误: 请以 root 权限运行此安装脚本 (sudo bash install.sh)"
  exit 1
fi

if [ ! -f /etc/debian_version ] && [ ! -f /etc/lsb-release ]; then
  echo "[-] 警告: 本安装脚本仅支持 Debian / Ubuntu 系统，尚需目标 VPS 环境验证。"
fi

if ! command -v systemctl &> /dev/null; then
  echo "[-] 错误: 未检测到 systemd (systemctl)。本服务依赖 systemd 守护进程管理。"
  exit 1
fi

# apt 带超时与重试：国内 VPS 访问官方源可能很慢或不通，避免安装无限期挂起
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o Acquire::Retries=2 -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 -o DPkg::Lock::Timeout=120"
apt_update() { timeout 300 apt-get $APT_OPTS update || echo "[-] 警告: apt-get update 未完成（网络慢或软件源不可达），继续使用本地缓存"; }
apt_install() { timeout 900 apt-get $APT_OPTS install -y "$@"; }

echo "[+] 检查 Python3 环境..."
if ! command -v python3 &> /dev/null; then
    echo "[-] 未检测到 python3，正在通过 apt 安装..."
    apt_update; apt_install python3 curl
fi

if ! command -v curl &> /dev/null; then
    echo "[+] 安装 curl 用于健康状态校验..."
    apt_update; apt_install curl || echo "[-] 警告: curl 安装失败（健康检查使用 python，不受影响）"
fi

# 凭据加密 (AES-256-GCM) 依赖系统 cryptography 包；缺失时服务仍可运行，但拒绝保存凭据
if ! python3 -c "import cryptography.hazmat.primitives.ciphers.aead" &> /dev/null; then
    echo "[+] 安装 python3-cryptography 用于加密保存服务商凭据..."
    { apt_update; apt_install python3-cryptography; } || echo "[-] 警告: python3-cryptography 安装失败，云端将无法保存凭据"
fi

# 图片压缩：手机发来的大照片（保留原图时可能 >8 MB）要在服务器缩小后再给模型，没有 Pillow 只能原图直发或放弃
if ! python3 -c "import PIL.Image" &> /dev/null; then
    echo "[+] 安装 python3-pil 用于压缩发给模型的图片..."
    { apt_update; apt_install python3-pil; } || echo "[-] 警告: python3-pil 安装失败，超过 8 MB 的图片模型看不到（App 默认会先压缩）"
fi

echo "=== 2. 创建专用服务用户 ($SERVICE_USER) ==="
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -s /bin/false -M -d "$VAR_LIB_DIR" "$SERVICE_USER"
    echo "[+] 创建用户 $SERVICE_USER 成功。"
else
    echo "[+] 用户 $SERVICE_USER 已存在。"
fi

echo "=== 3. 部署源码与目录结构 ==="
mkdir -p "$INSTALL_DIR"
mkdir -p "$VAR_LIB_DIR/workspace"
mkdir -p "$VAR_LIB_DIR/data"
mkdir -p "$VAR_LIB_DIR/data/plugin-files"
# 2.46.0 之前插件工作目录在安装目录里（root 所有，服务用户写不进去 → [Errno 13]）；把旧内容复制到数据目录
if [ -d "$INSTALL_DIR/plugin-files" ]; then
    cp -an "$INSTALL_DIR/plugin-files/." "$VAR_LIB_DIR/data/plugin-files/" 2>/dev/null || true
fi
mkdir -p "$CONFIG_DIR"

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 仅复制核心服务与文档，避免污染测试数据或密钥文件
cp -f "$CURRENT_DIR/cloud_agent_server.py" "$INSTALL_DIR/"
# 升级时先删掉新版本里已经不存在的旧模块（只动 cloud_*.py，不碰 venv 等其它文件）
for old in "$INSTALL_DIR"/cloud_*.py; do
    [ -f "$old" ] || continue
    [ -f "$CURRENT_DIR/$(basename "$old")" ] || { rm -f "$old"; echo "[+] 删除旧版本遗留模块 $(basename "$old")"; }
done
# 所有服务模块 (cloud_browser / cloud_desktop / cloud_secrets 等)
for module in "$CURRENT_DIR"/cloud_*.py; do
    [ -f "$module" ] && cp -f "$module" "$INSTALL_DIR/"
done
cp -f "$CURRENT_DIR/PROTOCOL.md" "$INSTALL_DIR/"
cp -f "$CURRENT_DIR/README.md" "$INSTALL_DIR/"
if [ -f "$CURRENT_DIR/install.sh" ]; then
    cp -f "$CURRENT_DIR/install.sh" "$INSTALL_DIR/"
fi
chmod +x "$INSTALL_DIR/cloud_agent_server.py"

# 代码目录属于 root，工作目录属于 openminis
chown -R root:root "$INSTALL_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$VAR_LIB_DIR"

echo "=== 4. 生成或配置安全 Bearer Token (600 权限，归属 openminis) ==="
if [ ! -f "$TOKEN_FILE" ]; then
    SECRET_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    echo "$SECRET_TOKEN" > "$TOKEN_FILE"
    echo "[+] 已生成新的安全 Token 并写入 $TOKEN_FILE"
else
    echo "[+] 检测到现有 Token 文件: $TOKEN_FILE"
fi

chmod 600 "$TOKEN_FILE"
chown "$SERVICE_USER:$SERVICE_USER" "$TOKEN_FILE"

echo "=== 4b. 生成凭据加密主密钥 (AES-256，600 权限，归属 openminis) ==="
if [ ! -s "$MASTER_KEY_FILE" ]; then
    (umask 077; python3 -c "import base64, secrets; print(base64.b64encode(secrets.token_bytes(32)).decode())" > "$MASTER_KEY_FILE")
    echo "[+] 已生成新的主密钥并写入 $MASTER_KEY_FILE（丢失后已保存的云端凭据无法解密，需要重新上传）"
else
    echo "[+] 检测到现有主密钥文件: $MASTER_KEY_FILE"
fi
chmod 600 "$MASTER_KEY_FILE"
chown "$SERVICE_USER:$SERVICE_USER" "$MASTER_KEY_FILE"

echo "=== 4c. 安装代理内核 sing-box（GitHub release，依次试镜像，sha256 校验；失败不影响主服务）==="
SB_DIR="$VAR_LIB_DIR/data/proxy/bin"
SB_WANT=$(python3 -c "import sys; sys.path.insert(0, '$INSTALL_DIR'); import cloud_proxy; print(cloud_proxy.SINGBOX_VERSION)" 2>/dev/null || echo "")
if [ "${OPENMINIS_SKIP_SINGBOX:-0}" = "1" ]; then
    echo "[+] 已按 OPENMINIS_SKIP_SINGBOX=1 跳过（可在 App 的代理设置里再安装）"
elif [ -n "$SB_WANT" ] && [ -x "$SB_DIR/sing-box" ] && "$SB_DIR/sing-box" version 2>/dev/null | head -1 | grep -q " $SB_WANT\$"; then
    echo "[+] sing-box $SB_WANT 已安装"
elif timeout 240 python3 "$INSTALL_DIR/cloud_proxy.py" install "$SB_DIR"; then
    chown -R "$SERVICE_USER:$SERVICE_USER" "$VAR_LIB_DIR/data/proxy"
    echo "[+] sing-box $SB_WANT 已安装到 $SB_DIR"
else
    echo "[-] 警告: sing-box 下载失败（可稍后在 App「云电脑资源设置 → 代理」里重试），继续安装"
fi

echo "=== 5. 配置 Systemd 服务文件 (openminis-cloud-agent.service) ==="
# 已装过云电脑桌面时，服务配置由 install-desktop.sh 写（venv 里的 Python、DISPLAY、浏览器路径）。
# 只「更新服务器 Agent」时保留它，否则浏览器和桌面工具会在升级后失效。
if [ -f /etc/systemd/system/openminis-display.service ] && [ -x "$INSTALL_DIR/venv/bin/python3" ] \
   && grep -q "^Environment=DISPLAY=" "$SERVICE_FILE" 2>/dev/null; then
  echo "[+] 检测到已安装云电脑桌面：保留带桌面环境的服务配置 $SERVICE_FILE"
else
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=OpenMinis Cloud Agent Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$VAR_LIB_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/cloud_agent_server.py
Restart=always
RestartSec=5
WatchdogSec=90
NotifyAccess=main
Environment=OPENMINIS_HOST=127.0.0.1
Environment=OPENMINIS_PORT=18765
Environment=OPENMINIS_DB=$VAR_LIB_DIR/data/openminis_agent.db
Environment=OPENMINIS_WORKSPACE=$VAR_LIB_DIR/workspace
Environment=OPENMINIS_PLUGIN_DIR=$VAR_LIB_DIR/data/plugin-files
Environment=OPENMINIS_TOKEN_FILE=$TOKEN_FILE
Environment=OPENMINIS_MASTER_KEY_FILE=$MASTER_KEY_FILE

# 基本安全加固（非安全虚拟化沙箱：同 UID 下 shell 拥有该用户系统权限）
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

echo "[+] Systemd 服务已写入: $SERVICE_FILE"
fi

echo "=== 6. 启动并启用服务 ==="
systemctl daemon-reload
systemctl enable openminis-cloud-agent
systemctl restart openminis-cloud-agent

echo "=== 7. 使用 Python 严格校验健康状态与 JSON 响应（最长等待 ${HEALTH_WAIT_SECONDS:-45} 秒）==="
# 服务启动时要做数据库迁移、加载插件注册表与定时任务，首次可能需要十几秒：轮询而不是固定 sleep
HEALTH_WAIT_SECONDS="${HEALTH_WAIT_SECONDS:-45}"
HEALTH_CHECK_OK="FAIL"
LAST_HEALTH_ERROR=""
for i in $(seq 1 "$HEALTH_WAIT_SECONDS"); do
  if systemctl is-failed --quiet openminis-cloud-agent; then
    LAST_HEALTH_ERROR="systemd 报告服务启动失败"
  fi
  if systemctl is-active --quiet openminis-cloud-agent; then
    if LAST_HEALTH_ERROR=$(python3 -c '
import urllib.request, json, sys
try:
    with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:18765/health", method="GET"), timeout=3) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    if resp.status == 200 and data.get("status") == "ok" and data.get("service") == "openminis-cloud-agent":
        sys.exit(0)
    print("unexpected /health response: " + json.dumps(data)[:200])
except Exception as e:
    print(type(e).__name__ + ": " + str(e)[:200])
sys.exit(1)
' 2>&1); then
      HEALTH_CHECK_OK="OK"
      break
    fi
  else
    LAST_HEALTH_ERROR="服务尚未处于 active 状态"
  fi
  if [ $((i % 10)) -eq 0 ]; then echo "[.] 等待服务就绪… ${i}s（${LAST_HEALTH_ERROR}）"; fi
  sleep 1
done

if [ "$HEALTH_CHECK_OK" = "OK" ]; then
  echo "[+] 健康检查成功 (HTTP 200 OK, JSON status == ok)"
  echo "=== 7b. 预热内置 Python MCP 插件（uvx 拉包，避免首次打开「时间与时区」超时）==="
  if timeout 300 sudo -u "$SERVICE_USER" -H env HOME="$VAR_LIB_DIR" PATH="$VAR_LIB_DIR/.local/bin:$PATH" \
      python3 "$INSTALL_DIR/cloud_plugin_catalog.py" --warm; then
    echo "[+] 内置 uvx 插件已预热"
  else
    echo "[-] 警告: 插件预热未完成（可能还没安装 uv，或 PyPI 较慢）。首次打开「时间与时区」可能仍需等待；可在插件市场安装 uv 后，再执行一次本安装脚本。"
  fi
else
  echo "[-] 错误: ${HEALTH_WAIT_SECONDS} 秒内服务未通过健康检查：${LAST_HEALTH_ERROR}"
  systemctl status openminis-cloud-agent --no-pager -l 2>&1 | tail -n 15 || true
  echo "----- journalctl -u openminis-cloud-agent（最近 40 行）-----"
  journalctl -u openminis-cloud-agent --no-pager -n 40 2>&1 || true
  exit 1
fi

echo ""
echo "=============================================================================="
echo " [OK] OpenMinis Cloud Agent 安装成功！"
echo " 服务监听地址: 127.0.0.1:18765 (标准统一端口)"
echo " 认证 Token 文件: $TOKEN_FILE (600 权限，归属 $SERVICE_USER)"
echo " 凭据主密钥文件: $MASTER_KEY_FILE (600 权限，归属 $SERVICE_USER)"
echo " 工作目录: $VAR_LIB_DIR"
echo "=============================================================================="
