#!/usr/bin/env bash
# App 自己的 noVNC 画面页（含 window.om）JS 语法检查：Swift 字符串里的 JS 写错不会在编译期报出来
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/render_novnc_page.py /tmp/om-page.html >/dev/null
python3 - <<'PY'
s = open('/tmp/om-page.html').read()
a = s.index('<script type="module">') + len('<script type="module">')
open('/tmp/om-page.mjs', 'w').write(s[a:s.index('</script>', a)])
PY
node --check /tmp/om-page.mjs
echo "noVNC 画面页 JS 语法 ok"
