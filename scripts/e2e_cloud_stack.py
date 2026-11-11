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
# 回复方式（秒回）：前台快模型 + 后台干活模型，都是假的；默认把 e2ebot 设成「详细」，老流程不受影响
FRONT_MODEL = "e2e-front-model"
BACK_MODEL = "e2e-back-model"
API_PORT = int(os.environ.get("OPENMINIS_E2E_PORT", "18765"))


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
    if "危险删除" in text and not tool_turns(data):
        return tool_call("c3", "shell_execute", {"command": "rm -rf /tmp/openminis-e2e-fake-dir && echo e2e-rm-ok"})
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


def _fresh_tools(data):
    msgs = data.get("messages", [])
    users = [i for i, m in enumerate(msgs) if m.get("role") == "user"]
    return [m for m in msgs[(users[-1] if users else 0):] if m.get("role") == "tool"]


def _stream_then_tool(text, call_id, name, args):
    # 先流出一句回话，再在同一条回复里调工具（和真模型一样：文字在前，tool_calls 在后）
    return {"_chunks": [text, {"tool_calls": [{"index": 0, "id": call_id, "type": "function",
                                                "function": {"name": name, "arguments": json.dumps(args, ensure_ascii=False)}}]}],
            "_delay": 0.02}


def front_script(data):
    """秒回前台：「查一下」→ 先回一句再派后台；后台在跑时「插话」→ 先回再转给后台；其余直接秒回。"""
    import re
    text = last_user_text(data)
    if _fresh_tools(data):
        return {"role": "assistant", "content": ""}
    blob = json.dumps(data, ensure_ascii=False)
    # 插话可能不在 last_user_text 的纯文本里（备注接在同一条 user 消息；或 content 是分段）
    all_user = []
    for m in data.get("messages", []):
        if m.get("role") != "user":
            continue
        c = m.get("content")
        if isinstance(c, list):
            all_user.append(" ".join(p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text"))
        else:
            all_user.append(c or "")
    heard = "插话" in text or any("插话" in u for u in all_user)
    m = re.search(r"(wk_[a-f0-9]{10})「[^」]*」进行中", blob)
    if not m:
        m = re.search(r"(wk_[a-f0-9]{10}).{0,80}进行中", blob)
    if heard and m:
        return _stream_then_tool("收到插话，马上转给后台。", "f2", "task_message", {"id": m.group(1), "text": text or " ".join(all_user)})
    if "查一下" in text:
        title = "慢活" if "慢活" in text else "查资料"
        return _stream_then_tool("好，我让后台去查，做完告诉你。", "f1", "spawn_task", {"goal": text, "context": "假数据", "title": title})
    return {"_chunks": ["秒回：", text[:20]], "_delay": 0.02}


def back_script(data):
    """秒回后台：三步带 tool_title 的命令（每步约 4 秒；「慢活」第一步 60 秒），然后给结论（收到插话就注明）。"""
    msgs = data.get("messages", [])
    done = sum(1 for m in msgs if m.get("role") == "tool")
    goal = " ".join(str(m.get("content")) for m in msgs if m.get("role") == "user")
    if done < 3:
        secs = 60 if ("慢活" in goal and done == 0) else 4
        return {"role": "assistant", "content": "", "tool_calls": [{"id": f"b{done}", "type": "function", "function": {
            "name": "shell_execute", "arguments": json.dumps({"command": f"sleep {secs}; echo e2e-back-step{done}",
                                                              "tool_title": ["分析工作方案", "查找资料", "整理结果"][done]}, ensure_ascii=False)}}]}
    heard = any(m.get("role") == "user" and "插话" in str(m.get("content")) for m in msgs)
    return {"role": "assistant", "content": "后台结论：上海晴（假数据）" + ("（已按插话调整）" if heard else "")}


def _api(method, path, body=None):
    import urllib.request
    req = urllib.request.Request(f"http://127.0.0.1:{API_PORT}{path}", method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"{}")


def set_reply(mode):
    """探针 /_e2e/reply?mode=instant|verbose：设 e2ebot 的回复方式、清掉各对话的单独设置、停掉还在跑的后台任务。"""
    import sqlite3
    if mode:
        _api("PUT", f"/v1/bots/{BOT_ID}/reply", {"mode": mode, "front_model": FRONT_MODEL, "back_model": BACK_MODEL})
        for w in _api("GET", f"/v1/workers?bot={BOT_ID}").get("workers", []):
            if w.get("status") in ("queued", "running", "waiting_user", "paused"):
                try:
                    _api("POST", f"/v1/workers/{w['id']}/stop", {})
                except Exception:
                    pass
    db = sqlite3.connect(os.environ["OPENMINIS_DB"])
    sids = [r[0] for r in db.execute("SELECT session_id FROM sessions WHERE persona_id = ?", (BOT_ID,))]
    if mode:
        db.executemany("DELETE FROM session_reply WHERE session_id = ?", [(x,) for x in sids])
        db.commit()
    overrides = {r[0]: r[1] for r in db.execute("SELECT session_id, mode FROM session_reply")}
    db.close()
    return {"bot": _api("GET", f"/v1/bots/{BOT_ID}/reply").get("reply"), "overrides": overrides}


def set_approval(mode):
    """探针 /_e2e/approval?mode=ask|auto：只改 E2E Bot 的覆盖，不改产品默认（新产品仍是先问我）。"""
    if mode in ("ask", "auto"):
        _api("PUT", "/v1/resources", {"bot_overrides": {BOT_ID: {"approval_mode": mode}}})
    import cloud_isolation
    live = _api("GET", "/v1/resources")
    return {"mode": mode, "bot": (live.get("settings") or {}).get("bot_overrides", {}).get(BOT_ID, {}),
            "defaults": cloud_isolation.DEFAULTS["bot_defaults"]}


def simulate_restart():
    """探针 /_e2e/restart：模拟云端进程重启（进行中的后台任务改为暂停并询问是否继续）。"""
    import cloud_agent_server as srv
    srv.init_db()
    return {"ok": True}


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


# 云电脑 E2E 的假桌面（macOS 模拟器机器上没有 Xvfb）：/_e2e/desktop?on=1 打开后，/v1/desktop/input 的
# 剪贴板 / 输入 / 按键落到这里的内存里，UTF-8 原样保存；中文输入像真服务器一样「放进剪贴板再粘贴」，会改掉远端剪贴板。
# 真 X 上的同一套行为由 Linux CI 的 test_cc_clipboard_utf8 验证。全是假数据。
FAKE_DESK = {"on": False, "clip": "", "typed": [], "keys": [], "clip_sets": []}


def install_fake_desktop():
    import cloud_desktop as cd
    real_avail, real_exec, real_read, real_write = cd.is_desktop_available, cd.execute_desktop_action, cd.read_clipboard, cd.write_clipboard

    def avail():
        return True if FAKE_DESK["on"] else real_avail()

    def execute(session_id, workspace_dir, args, display_override=None):
        if not FAKE_DESK["on"] or session_id != "phone":
            return real_exec(session_id, workspace_dir, args, display_override=display_override)
        if args.get("action") == "type":
            text = args.get("text", "")
            FAKE_DESK["typed"].append(text)
            if any(ord(c) > 127 for c in text):
                FAKE_DESK["clip"] = text
                return {"status": "ok", "action": "type", "length": len(text), "method": "clipboard", "via": "fake"}
            return {"status": "ok", "action": "type", "length": len(text)}
        if args.get("action") == "key":
            FAKE_DESK["keys"].append([args.get("key"), int(args.get("repeat") or 1)])
            return {"status": "ok", "action": "key", "key": args.get("key"), "repeat": int(args.get("repeat") or 1)}
        return {"error": "fake desktop: unsupported"}

    def read(display):
        return (FAKE_DESK["clip"], None) if FAKE_DESK["on"] else real_read(display)

    def write(display, text):
        if not FAKE_DESK["on"]:
            return real_write(display, text)
        FAKE_DESK["clip"] = text
        FAKE_DESK["clip_sets"].append(text)
        return None

    cd.is_desktop_available, cd.execute_desktop_action, cd.read_clipboard, cd.write_clipboard = avail, execute, read, write


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
    sup.FakeModelHandler.scripts[FRONT_MODEL] = front_script
    sup.FakeModelHandler.scripts[BACK_MODEL] = back_script
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
                FAKE_DESK.update({"on": False, "clip": "", "typed": [], "keys": [], "clip_sets": []})
                body = json.dumps({"cleared_sessions": len(sids)}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if urlparse(self.path).path == "/_e2e/desktop":
                # ?on=1 / ?on=0 开关假桌面（同时清空记录）；?clip=文字 模拟在远端程序里复制了一段
                q = parse_qs(urlparse(self.path).query)
                if "on" in q:
                    FAKE_DESK.update({"on": q["on"][0] == "1", "clip": "", "typed": [], "keys": [], "clip_sets": []})
                if "clip" in q:
                    FAKE_DESK["clip"] = q["clip"][0]
                body = json.dumps(FAKE_DESK, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if urlparse(self.path).path == "/_e2e/reply":
                try:
                    out = set_reply((parse_qs(urlparse(self.path).query).get("mode") or [""])[0])
                    code = 200
                except Exception as e:
                    out, code = {"error": str(e)}, 500
                body = json.dumps(out, ensure_ascii=False).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if urlparse(self.path).path == "/_e2e/approval":
                try:
                    out = set_approval((parse_qs(urlparse(self.path).query).get("mode") or [""])[0])
                    code = 200
                except Exception as e:
                    out, code = {"error": str(e)}, 500
                body = json.dumps(out, ensure_ascii=False).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if urlparse(self.path).path == "/_e2e/defaults":
                import cloud_isolation
                out = {"defaults": {"bot_defaults": cloud_isolation.DEFAULTS["bot_defaults"]}}
                body = json.dumps(out, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if urlparse(self.path).path == "/_e2e/restart":
                try:
                    out, code = simulate_restart(), 200
                except Exception as e:
                    out, code = {"error": str(e)}, 500
                body = json.dumps(out, ensure_ascii=False).encode()
                self.send_response(code)
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
    install_fake_desktop()
    srv.SERVER_TOKEN = TOKEN
    srv.init_db()
    api = ThreadingHTTPServer(("127.0.0.1", API_PORT), srv.CloudAgentHandler)
    threading.Thread(target=api.serve_forever, daemon=True).start()

    import urllib.request

    def call(method, path, body):
        req = urllib.request.Request(f"http://127.0.0.1:{api.server_address[1]}{path}", method=method,
                                     data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read() or b"{}")

    call("PUT", "/v1/credentials/e2e", {"api_key": "sk-e2e-fake-000000000000", "base_url": model_base})
    call("PUT", f"/v1/bots/{BOT_ID}", {"name": BOT_NAME, "instructions": "端到端测试 Bot", "model": MODEL, "credential": "e2e"})
    # E2E 流程本身一律批准，避免老用例卡在审批卡；产品默认仍是 ask（/_e2e/defaults 可读到）
    call("PUT", "/v1/resources", {"bot_defaults": {"approval_mode": "auto"},
                                  "bot_overrides": {BOT_ID: {"approval_mode": "auto"}}})
    set_reply("verbose")
    print(f"E2E 云端就绪：API 127.0.0.1:{api.server_address[1]}，假模型 {model_base}，本地假模型 127.0.0.1:{LOCAL_MODEL_PORT}/v1，探针 127.0.0.1:18799", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
