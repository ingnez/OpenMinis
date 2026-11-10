#!/usr/bin/env python3
"""把 CloudDesktopHealth.swift 里 App 自己的 noVNC 画面页（含 window.om）原样渲染成 HTML，给真浏览器端到端测试用。

用法：python3 scripts/render_novnc_page.py <输出 html> [--port 18766] [--path websockify]
页面里 window.webkit.messageHandlers 换成记录到 window.__msgs / window.__st 的替身（浏览器里没有 WKWebView）。
"""
import argparse
import pathlib

SRC = pathlib.Path(__file__).resolve().parent.parent / "src/ios/Views/Chat/AIChatView/Cloud/CloudDesktopHealth.swift"


def render(port, path, view_only=False):
    s = SRC.read_text()
    a = s.index('static let omScript = """') + len('static let omScript = """')
    om = s[a:s.index('    """', a)]
    p0 = s.index('return """', s.index("static func page(for url: URL)")) + len('return """')
    page = s[p0:s.index('        """', p0)]
    page = (page.replace("\\(omScript)", om).replace("\\(port)", str(port)).replace("\\(safePath)", path)
            .replace('\\(viewOnly ? "true" : "false")', "true" if view_only else "false"))
    assert "\\(" not in page, "还有没替换的 Swift 插值"
    stub = ("<script>window.__msgs=[];window.__st=[];window.webkit={messageHandlers:{"
            "om:{postMessage:m=>window.__msgs.push(JSON.parse(m))},vncState:{postMessage:m=>window.__st.push(m)}}};</script>")
    return page.replace("<head>", "<head>" + stub, 1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--port", type=int, default=18766)
    ap.add_argument("--path", default="websockify")
    a = ap.parse_args()
    pathlib.Path(a.out).write_text(render(a.port, a.path))
    print("wrote", a.out)
