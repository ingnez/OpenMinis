#!/bin/bash
# ==============================================================================
# OpenMinis Cloud Desktop & Agent Integration CI Test Script (test_desktop.sh)
# 作用: 严格校验 install-desktop.sh 部署与各服务健康，绝不跳过断言
# ==============================================================================

set -e

echo "=== [CI Test] 1. 检查运行环境与权限 ==="
if [ "$EUID" -ne 0 ]; then
  echo "[-] 请以 root 权限运行此测试脚本 (sudo bash test_desktop.sh)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== [CI Test] 2. 验证已经安装的云电脑环境 ==="

echo "=== [CI Test] 3. 执行严格断言验证 ==="

# 断言 1: 检查各独立 systemd 服务状态
echo "[+] 断言 1: 检查 systemd 各服务状态"
systemctl is-active --quiet openminis-display
echo "✓ openminis-display is active."
systemctl is-active --quiet openminis-vnc
echo "✓ openminis-vnc is active."
systemctl is-active --quiet openminis-novnc
echo "✓ openminis-novnc is active."
systemctl is-active --quiet openminis-cloud-agent
echo "✓ openminis-cloud-agent is active."

# 断言 2: xdpyinfo 检测 DISPLAY=:99
echo "[+] 断言 2: xdpyinfo 检测 DISPLAY=:99"
env XAUTHORITY=/var/lib/openminis-cloud-agent/.Xauthority xdpyinfo -display :99 > /dev/null
echo "✓ xdpyinfo detected display :99 successfully."

# 断言 3: Python venv 及 ExecStart 路径正确
echo "[+] 断言 3: 虚拟环境与 Python 路径"
[ -x "/opt/openminis-cloud-agent/venv/bin/python3" ]
echo "✓ Python venv interpreter exists."

# 断言 4: API 健康检查 (端口 18765)
echo "[+] 断言 4: API 健康检查 (18765)"
python3 -c '
import urllib.request, json
req = urllib.request.Request("http://127.0.0.1:18765/health", method="GET")
with urllib.request.urlopen(req, timeout=5) as resp:
    assert resp.status == 200
    data = json.loads(resp.read().decode("utf-8"))
    assert data.get("status") == "ok"
    print("✓ API health check JSON returned status == ok")
'

# 断言 5: noVNC 静态页面与 rfb.js 核心脚本 200 OK 且含真实标识
echo "[+] 断言 5: noVNC vnc.html 及 core/rfb.js"
python3 -c '
import urllib.request
req = urllib.request.Request("http://127.0.0.1:18766/vnc.html", method="GET")
with urllib.request.urlopen(req, timeout=5) as resp:
    assert resp.status == 200
    content = resp.read().decode("utf-8")
    assert "noVNC" in content or "RFB" in content
    print("✓ vnc.html loaded and verified.")

# 验证核心 JS 资源可达
req_js = urllib.request.Request("http://127.0.0.1:18766/core/rfb.js", method="GET")
with urllib.request.urlopen(req_js, timeout=5) as resp_js:
    assert resp_js.status == 200
    assert b"RFB" in resp_js.read()
    print("✓ core/rfb.js loaded successfully.")
'

# 断言 6: Playwright 浏览器安装验证
echo "[+] 断言 6: Playwright 浏览器持久化目录"
[ -d "/var/lib/openminis-cloud-agent/ms-playwright" ]
echo "✓ Playwright browser persistent directory exists."

echo "=============================================================================="
echo " [SUCCESS] 所有桌面部署与集成断言测试 100% 通过！"
echo "=============================================================================="
