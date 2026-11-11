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
# 本地模式的假服务商（App 用 OPENMINIS_E2E_LOCAL_PROVIDER 指过来）：单独端口、单独模型名，和云端那边的请求分开数
LOCAL_MODEL = "e2e-local-model"
LOCAL_MODEL_PORT = 18797


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
    if "慢任务" in text and not tool_turns(data):
        return tool_call("c2", "shell_execute", {"command": "sleep 40; echo e2e-slow-done"})
    if "跑个命令" in text and not tool_turns(data):
        return tool_call("c1", "shell_execute", {"command": "echo e2e-shell-ok; sleep 2"})
    if "加粗" in text:
        return {"role": "assistant", "content": "> 这是**结论：**引用里的中文加粗，还有**「重点」**和**加粗的中文**。\n\n正文第二段。"}
    n = image_count(data)
    if n:
        return {"role": "assistant", "content": f"收到 {n} 张图片"}
    return {"role": "assistant", "content": "收到：" + text[:30]}


def local_script(data):
    text = last_user_text(data)
    reply = "本地收到：" + text[:30]
    if "加粗" in text:
        md = "> 这是**结论：**引用里的中文加粗，还有**「重点」**和**加粗的中文**。\n\n本地正文第二段。"
        return {"_chunks": [md]} if data.get("stream") else {"role": "assistant", "content": md}
    slow = "慢" in text      # 本地慢任务：约 16 秒流完，测试趁它还在跑时切到云端
    if data.get("stream"):
        return {"_chunks": ["本地收到：", text[:30]] + ["。"] * (6 if slow else 0), "_delay": 2.0 if slow else 0.3}
    if slow:
        time.sleep(16)
    return {"role": "assistant", "content": reply}


REALTIME_PORT = 18796
# 假实时服务（OpenAI Realtime 协议，标准库手写 WebSocket）：App 发 input_audio_buffer.append，够 1 秒后回一段字幕 + 声音
REALTIME = {"connections": 0, "session_updates": 0, "appends": 0, "audio_bytes_in": 0, "replies": 0, "events": []}
REALTIME_REPLY = "e2e-realtime-ok 我听到了"


def start_fake_realtime():
    import base64, hashlib, math, socketserver, struct

    def send(sock, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        n = len(data)
        head = bytes([0x81]) + (bytes([n]) if n < 126 else (bytes([126]) + struct.pack(">H", n) if n < 65536 else bytes([127]) + struct.pack(">Q", n)))
        sock.sendall(head + data)

    def recv_exact(f, n):
        b = f.read(n)
        if len(b) < n:
            raise EOFError
        return b

    def recv(f):
        b1, b2 = recv_exact(f, 2)
        op, n = b1 & 0x0F, b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", recv_exact(f, 2))[0]
        elif n == 127:
            n = struct.unpack(">Q", recv_exact(f, 8))[0]
        mask = recv_exact(f, 4) if b2 & 0x80 else b"\0\0\0\0"
        data = bytes(c ^ mask[i % 4] for i, c in enumerate(recv_exact(f, n)))
        return op, data

    tone = b"".join(int(6000 * math.sin(2 * math.pi * 330 * i / 24000)).to_bytes(2, "little", signed=True) for i in range(12000))

    class H(socketserver.StreamRequestHandler):
        def handle(self):
            head = b""
            while b"\r\n\r\n" not in head:
                c = self.request.recv(1024)
                if not c:
                    return
                head += c
            key = ""
            for line in head.decode("latin-1").split("\r\n"):
                if line.lower().startswith("sec-websocket-key:"):
                    key = line.split(":", 1)[1].strip()
            acc = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.request.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                  f"Sec-WebSocket-Accept: {acc}\r\n\r\n").encode())
            REALTIME["connections"] += 1
            sock = self.request
            send(sock, {"type": "session.created", "session": {"id": "sess_e2e"}})
            appends, replied = 0, False
            try:
                while True:
                    op, data = recv(self.rfile)
                    if op == 8:
                        return
                    if op == 9:
                        sock.sendall(bytes([0x8A, len(data)]) + data)
                        continue
                    if op != 1:
                        continue
                    ev = json.loads(data)
                    ty = ev.get("type", "")
                    if len(REALTIME["events"]) < 200:
                        REALTIME["events"].append(ty)
                    if ty == "session.update":
                        REALTIME["session_updates"] += 1
                        send(sock, {"type": "session.updated", "session": ev.get("session", {})})
                    elif ty == "input_audio_buffer.append":
                        appends += 1
                        REALTIME["appends"] += 1
                        REALTIME["audio_bytes_in"] += len(base64.b64decode(ev.get("audio", "")))
                        if appends >= 10 and not replied:
                            replied = True
                            REALTIME["replies"] += 1
                            send(sock, {"type": "input_audio_buffer.speech_started", "item_id": "u1"})
                            send(sock, {"type": "input_audio_buffer.committed", "item_id": "u1"})
                            send(sock, {"type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "（假）用户说话"})
                            send(sock, {"type": "response.created", "response": {"id": "r1"}})
                            send(sock, {"type": "response.output_audio_transcript.delta", "response_id": "r1", "item_id": "a1", "delta": REALTIME_REPLY})
                            for i in range(0, len(tone), 4800):
                                send(sock, {"type": "response.output_audio.delta", "response_id": "r1", "item_id": "a1",
                                            "content_index": 0, "delta": base64.b64encode(tone[i:i + 4800]).decode()})
                            send(sock, {"type": "response.output_audio_transcript.done", "response_id": "r1", "item_id": "a1", "transcript": REALTIME_REPLY})
                            send(sock, {"type": "response.done", "response": {"id": "r1", "status": "completed"}})
            except (EOFError, ConnectionError, OSError, ValueError):
                return

    class S(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    srv = S(("127.0.0.1", REALTIME_PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()


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
    sup.FakeModelHandler.scripts[LOCAL_MODEL] = local_script
    local_srv = ThreadingHTTPServer(("127.0.0.1", LOCAL_MODEL_PORT), sup.FakeModelHandler)
    threading.Thread(target=local_srv.serve_forever, daemon=True).start()
    model_srv = ThreadingHTTPServer(("127.0.0.1", 0), sup.FakeModelHandler)
    threading.Thread(target=model_srv.serve_forever, daemon=True).start()
    model_base = f"http://127.0.0.1:{model_srv.server_address[1]}/v1"

    class Probe(BaseHTTPRequestHandler):
        def do_GET(self):
            # ?model=e2e-local-model 看本地那边；默认看云端模型。imports = 云端从手机导入的本地会话数（应为 0：本地不进云端）
            from urllib.parse import urlparse, parse_qs
            if urlparse(self.path).path == "/_e2e/reset":
                # 每个流程开头清空假 Bot 的对话：历史越积越长，控件树大到 XCUITest 取快照超时（test08 实测）
                import sqlite3
                db = sqlite3.connect(os.environ["OPENMINIS_DB"])
                sids = [r[0] for r in db.execute("SELECT session_id FROM sessions WHERE persona_id = ?", (BOT_ID,))]
                for sid in sids:
                    db.execute("DELETE FROM messages WHERE session_id = ?", (sid,))
                db.commit()
                db.close()
                body = json.dumps({"cleared_sessions": len(sids)}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if urlparse(self.path).path == "/_e2e/realtime":
                body = json.dumps(REALTIME, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            want = (parse_qs(urlparse(self.path).query).get("model") or [MODEL])[0]
            reqs = [{"model": r.get("model"), "images": image_count(r), "text": last_user_text(r)[:200]}
                    for r in sup.FakeModelHandler.requests if r.get("model") == want]
            all_texts = [last_user_text(r)[:200] for r in sup.FakeModelHandler.requests if r.get("model") != LOCAL_MODEL]
            imports = 0
            try:
                import sqlite3
                db = sqlite3.connect(os.environ["OPENMINIS_DB"])
                imports = db.execute("SELECT COUNT(*) FROM sessions WHERE local_session_id IS NOT NULL AND local_session_id != ''").fetchone()[0]
                db.close()
            except Exception:
                imports = -1
            body = json.dumps({"requests": reqs, "cloud_texts": all_texts, "imports": imports}, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    start_fake_realtime()
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
    print(f"E2E 云端就绪：API 127.0.0.1:{api.server_address[1]}，假模型 {model_base}，本地假模型 127.0.0.1:{LOCAL_MODEL_PORT}/v1，探针 127.0.0.1:18799", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
