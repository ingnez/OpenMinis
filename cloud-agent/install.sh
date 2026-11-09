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

echo "[+] 检查 Python3 环境..."
if ! command -v python3 &> /dev/null; then
    echo "[-] 未检测到 python3，正在通过 apt 安装..."
    apt-get update && apt-get install -y python3 curl
fi

if ! command -v curl &> /dev/null; then
    echo "[+] 安装 curl 用于健康状态校验..."
    apt-get update && apt-get install -y curl
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
mkdir -p "$CONFIG_DIR"

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 仅复制核心服务与文档，避免污染测试数据或密钥文件
cp -f "$CURRENT_DIR/cloud_agent_server.py" "$INSTALL_DIR/"
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

echo "=== 5. 配置 Systemd 服务文件 (openminis-cloud-agent.service) ==="
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=OpenMinis Cloud Agent Service
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$VAR_LIB_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/cloud_agent_server.py
Restart=always
RestartSec=5
Environment=OPENMINIS_HOST=127.0.0.1
Environment=OPENMINIS_PORT=18765
Environment=OPENMINIS_DB=$VAR_LIB_DIR/data/openminis_agent.db
Environment=OPENMINIS_WORKSPACE=$VAR_LIB_DIR/workspace
Environment=OPENMINIS_TOKEN_FILE=$TOKEN_FILE

# 基本安全加固（非安全虚拟化沙箱：同 UID 下 shell 拥有该用户系统权限）
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

echo "[+] Systemd 服务已写入: $SERVICE_FILE"

echo "=== 6. 启动并启用服务 ==="
systemctl daemon-reload
systemctl enable openminis-cloud-agent
systemctl restart openminis-cloud-agent

echo "=== 7. 使用 Python 严格校验健康状态与 JSON 响应 ==="
sleep 2

if ! systemctl is-active --quiet openminis-cloud-agent; then
  echo "[-] 错误: openminis-cloud-agent 服务未能成功启动！"
  journalctl -u openminis-cloud-agent --no-pager -n 30
  exit 1
fi

# 使用 python 进行严格的 HTTP 请求与 JSON 结构验证（不依赖 grep，使用 curl -f 及 JSON 解析）
HEALTH_CHECK_OK=$(python3 -c '
import urllib.request, json, sys
try:
    req = urllib.request.Request("http://127.0.0.1:18765/health", method="GET")
    with urllib.request.urlopen(req, timeout=5) as resp:
        if resp.status != 200:
            sys.exit(1)
        data = json.loads(resp.read().decode("utf-8"))
        if data.get("status") == "ok" and data.get("service") == "openminis-cloud-agent":
            print("OK")
            sys.exit(0)
        else:
            sys.exit(1)
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(1)
' || echo "FAIL")

if [ "$HEALTH_CHECK_OK" = "OK" ]; then
  echo "[+] 健康检查成功 (HTTP 200 OK, JSON status == ok)"
else
  echo "[-] 错误: 健康检查 JSON 校验失败！"
  journalctl -u openminis-cloud-agent --no-pager -n 30
  exit 1
fi

echo ""
echo "=============================================================================="
echo " [OK] OpenMinis Cloud Agent 安装成功！"
echo " 服务监听地址: 127.0.0.1:18765 (标准统一端口)"
echo " 认证 Token 文件: $TOKEN_FILE (600 权限，归属 $SERVICE_USER)"
echo " 工作目录: $VAR_LIB_DIR"
echo "=============================================================================="
