#!/usr/bin/env bash
# 云电脑画面页 window.om 真浏览器端到端：独立的 Xvfb :77 + x11vnc（与安装脚本同参数）+ websockify，
# 被控端开假输入页，headless Chrome 打开 App 渲染出来的画面页，逐项验证指针 / 点击 / 按键 / 剪贴板 / 滚轮 / 缩放 / 画质 / 截图 / 录屏。
set -euo pipefail
cd "$(dirname "$0")/.."
W=$(mktemp -d)
CHROME=$(command -v google-chrome || command -v chromium || command -v chromium-browser)
NOVNC=$(for d in /usr/share/novnc /usr/local/share/novnc; do [ -f "$d/core/rfb.js" ] && echo "$d" && break; done)
[ -n "$NOVNC" ] || { echo "没有 noVNC"; exit 1; }
cleanup() { kill $(jobs -p) 2>/dev/null || true; sleep 1; rm -rf "$W" 2>/dev/null || true; }
trap cleanup EXIT
Xvfb :77 -screen 0 1280x800x24 -nolisten tcp >"$W/xvfb.log" 2>&1 &
sleep 1
x11vnc -display :77 -rfbport 5977 -listen 127.0.0.1 -nopw -forever -shared -quiet ${VNCFLAGS--wait 5 -defer 5} >"$W/vnc.log" 2>&1 &
mkdir -p "$W/web" && cp -r "$NOVNC"/* "$W/web/"
python3 scripts/render_novnc_page.py "$W/web/om-test.html" --port 18778
websockify --web="$W/web" 127.0.0.1:18778 127.0.0.1:5977 >"$W/ws.log" 2>&1 &
cat > "$W/input.html" <<'HTML'
<html><body style="margin:0;background:#fff"><input id="t" style="position:absolute;left:100px;top:100px;width:600px;height:60px;font-size:30px"><div id="log" style="position:absolute;left:100px;top:200px;font-size:20px"></div><div style="height:3000px"></div>
<script>let n=0;document.addEventListener('mousedown',e=>{document.getElementById('log').textContent='down '+e.button+' '+e.clientX+','+e.clientY+' '+(++n)});document.addEventListener('contextmenu',e=>e.preventDefault());</script></body></html>
HTML
DISPLAY=:77 "$CHROME" --no-sandbox --no-first-run --disable-gpu --kiosk --window-position=0,0 --window-size=1280,800 --remote-debugging-port=9333 --user-data-dir="$W/t" "file://$W/input.html" >"$W/target.log" 2>&1 &
"$CHROME" --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9334 --user-data-dir="$W/v" about:blank >"$W/viewer.log" 2>&1 &
for i in $(seq 1 60); do curl -fs http://127.0.0.1:9334/json >/dev/null && curl -fs http://127.0.0.1:9333/json >/dev/null && break; sleep 0.5; done
DISPLAY=:77 node scripts/desktop_bridge_e2e.mjs 9334 http://127.0.0.1:18778/om-test.html 9333 :77 || {
  echo "--- viewer.log"; tail -20 "$W/viewer.log"; echo "--- target.log"; tail -20 "$W/target.log"; exit 1; }
