#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""模拟器端到端测试用的本地云端：真的云端 Agent 服务（127.0.0.1:18765）+ 假的 OpenAI 兼容模型。
全部假数据：令牌、Bot、凭据都是测试用的。GET http://127.0.0.1:18799/_e2e/requests 看模型收到了什么（每次几张 image_url）。
用法：python3 scripts/e2e_cloud_stack.py <工作目录>   （前台运行，Ctrl-C 结束）"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "cloud-agent"))

TOKEN = "e2e-fake-token-0000000000000000"
MODEL = "e2e-vision-model"
BOT_ID = "e2ebot"
BOT_NAME = "E2E小助手"


def last_user_text(data):
    for m in reversed(data.get("messages", [])):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, list):
                return " ".join(p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text")
            return c or ""
    return ""


def image_count(data):
    n = 0
    for m in data.get("messages", []):
        if m.get("role") == "user" and isinstance(m.get("content"), list):
            n += sum(1 for p in m["content"] if isinstance(p, dict) and p.get("type") == "image_url")
    return n


def script(data):
    from test_phase1_support import tool_call, tool_turns
    text = last_user_text(data)
    if "跑个命令" in text and not tool_turns(data):
        return tool_call("c1", "shell_execute", {"command": "echo e2e-shell-ok; sleep 2"})
    if "加粗" in text:
        return {"role": "assistant", "content": "> 这是**结论：**引用里的中文加粗，还有**「重点」**和**加粗的中文**。\n\n正文第二段。"}
    n = image_count(data)
    if n:
        return {"role": "assistant", "content": f"收到 {n} 张图片"}
    return {"role": "assistant", "content": "收到：" + text[:30]}


def main():
    work = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "/tmp/openminis-e2e")
    os.makedirs(os.path.join(work, "conf"), exist_ok=True)
    token_file = os.path.join(work, "conf", "token")
    with open(token_file, "w") as f:
        f.write(TOKEN)
    os.environ.update({
        "OPENMINIS_TOKEN_FILE": token_file,
        "OPENMINIS_MASTER_KEY_FILE": os.path.join(work, "conf", "master.key"),
        "OPENMINIS_DB": os.path.join(work, "data", "agent.db"),
        "OPENMINIS_WORKSPACE": os.path.join(work, "workspace"),
        "OPENMINIS_PLUGIN_DIR": os.path.join(work, "data", "plugin-files"),
    })
    os.makedirs(os.path.join(work, "data"), exist_ok=True)
    os.makedirs(os.path.join(work, "workspace"), exist_ok=True)

    import test_phase1_support as sup
    sup.FakeModelHandler.scripts[MODEL] = script
    model_srv = ThreadingHTTPServer(("127.0.0.1", 0), sup.FakeModelHandler)
    threading.Thread(target=model_srv.serve_forever, daemon=True).start()
    model_base = f"http://127.0.0.1:{model_srv.server_address[1]}/v1"

    class Probe(BaseHTTPRequestHandler):
        def do_GET(self):
            reqs = [{"model": r.get("model"), "images": image_count(r), "text": last_user_text(r)[:200]}
                    for r in sup.FakeModelHandler.requests if r.get("model") == MODEL]
            body = json.dumps({"requests": reqs}, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    probe = ThreadingHTTPServer(("127.0.0.1", 18799), Probe)
    threading.Thread(target=probe.serve_forever, daemon=True).start()

    import cloud_agent_server as srv
    srv.SERVER_TOKEN = TOKEN
    srv.init_db()
    api = ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("OPENMINIS_E2E_PORT", "18765"))), srv.CloudAgentHandler)
    threading.Thread(target=api.serve_forever, daemon=True).start()

    import urllib.request

    def call(method, path, body):
        req = urllib.request.Request(f"http://127.0.0.1:{api.server_address[1]}{path}", method=method,
                                     data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read() or b"{}")

    call("PUT", "/v1/credentials/e2e", {"api_key": "sk-e2e-fake-000000000000", "base_url": model_base})
    call("PUT", f"/v1/bots/{BOT_ID}", {"name": BOT_NAME, "instructions": "端到端测试 Bot", "model": MODEL, "credential": "e2e"})
    print(f"E2E 云端就绪：API 127.0.0.1:{api.server_address[1]}，假模型 {model_base}，探针 127.0.0.1:18799", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
