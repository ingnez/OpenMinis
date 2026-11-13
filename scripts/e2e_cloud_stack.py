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
LOCAL_FRONT_MODEL = "e2e-local-front-model"
LOCAL_BACK_MODEL = "e2e-local-back-model"
API_PORT = int(os.environ.get("OPENMINIS_E2E_PORT", "18765"))
# test30 临时把假 Bot 设成主 Bot：记下原来的主 Bot，/_e2e/reset 时还原
PREV_PRIMARY = []
E2E_PRIMARY_SET = []


def last_user_text(data):
    for m in reversed(data.get("messages", [])):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, list):
                return " ".join(p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text")
            return c or ""
    return ""


def user_texts(data):
    out = []
    for m in data.get("messages", []):
        if m.get("role") != "user":
            continue
        c = m.get("content")
        if isinstance(c, list):
            out.append(" ".join(p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text"))
        else:
            out.append(c or "")
    return out


def image_count(data):
    n = 0
    for m in data.get("messages", []):
        if m.get("role") == "user" and isinstance(m.get("content"), list):
            n += sum(1 for p in m["content"] if isinstance(p, dict) and p.get("type") == "image_url")
    return n


def delivery_pdf():
    parts = ["%PDF-1.4\n"]
    objects = (
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
        "<< /Length 0 >>\nstream\nendstream",
    )
    offsets = [0]
    for number, value in enumerate(objects, 1):
        offsets.append(sum(map(len, parts)))
        parts.append(f"{number} 0 obj\n{value}\nendobj\n")
    xref = sum(map(len, parts))
    parts.append(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n")
    parts.extend(f"{offset:010d} 00000 n \n" for offset in offsets[1:])
    parts.append(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n")
    return "".join(parts)


def script(data):
    from test_phase1_support import tool_call, tool_turns
    text = last_user_text(data)
    if "慢任务" in text and not tool_turns(data):
        return tool_call("c2", "shell_execute", {"command": "sleep 40; echo e2e-slow-done"})
    if "跑个命令" in text and not tool_turns(data):
        return tool_call("c1", "shell_execute", {"command": "echo e2e-shell-ok; sleep 2"})
    if "加粗" in text:
        return {"role": "assistant", "content": "> 这是**结论：**引用里的中文加粗，还有**「重点」**和**加粗的中文**。\n\n正文第二段。"}
    if "生成交付物" in text:
        if not _fresh_tools(data):
            import shlex
            cmd = "python3 -c " + shlex.quote(
                "from pathlib import Path; import zipfile;"
                f"Path('说明.pdf').write_bytes({delivery_pdf().encode()!r});"
                "Path('图.png').write_bytes(bytes.fromhex('89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de0000000c49444154789c63f8cfc0000000030001000518d84e0000000049454e44ae426082'));"
                "z=zipfile.ZipFile('课件.pptx','w');z.writestr('ppt/slides/slide1.xml','<s/>');z.close()"
            )
            return tool_call("d1", "shell_execute", {"command": cmd})
        return {"role": "assistant", "content": "课件做好了，说明见 https://example.com/guide"}
    n = image_count(data)
    if n:
        return {"role": "assistant", "content": f"收到 {n} 张图片"}
    return {"role": "assistant", "content": "收到：" + text[:30]}


def local_script(data):
    text = last_user_text(data)
    reply = "本地收到：" + text[:30]
    if "生成交付物" in text:
        if not _fresh_tools(data):
            args = {"path": "/var/minis/workspace/本地说明.pdf", "content": delivery_pdf()}
            if data.get("stream"):
                return _stream_then_tool("", "local-delivery", "file_write", args)
            from test_phase1_support import tool_call
            return tool_call("local-delivery", "file_write", args)
        content = "本地课件做好了，说明见 https://example.com/guide"
        return {"_chunks": [content]} if data.get("stream") else {"role": "assistant", "content": content}
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


def _stream_then_tool(text, call_id, name, args, reasoning=None):
    # 先流出一句回话，再在同一条回复里调工具（和真模型一样：文字在前，tool_calls 在后）
    chunks = []
    if reasoning:
        chunks.append({"reasoning_content": reasoning})
    chunks.append(text)
    chunks.append({"tool_calls": [{"index": 0, "id": call_id, "type": "function",
                                   "function": {"name": name, "arguments": json.dumps(args, ensure_ascii=False)}}]})
    return {"_chunks": chunks, "_delay": 0.02}



def _front_intent(text):
    """把用户插话理解成一句自然回应 + 结构化动作（steer/new/cancel/answer）。回应必须反映原话，不能是套话。"""
    # 每轮接在用户原话后面的后台任务摘要（「\n\n[这个对话的后台任务…」）不是用户说的，真模型也不会照抄进答复 / 转述
    t = (text or "").split("\n\n[")[0].strip() or "这个要求"
    short = t[:28]
    if any(k in t for k in ("停掉", "取消任务", "不要做了", "停下当前")):
        return f"你想停下当前任务，我现在就停。", "cancel", None
    if any(k in t for k in ("另外再", "同时再查", "再开一个", "新任务")):
        return f"你想再开一件：{short}，我另派一个后台去做。", "new", t
    if t.endswith("？") or t.endswith("?") or t.startswith("问一下"):
        return f"这个我直接说：{short}", "answer", None
    return f"你想{short}，我让后台现在就改。", "steer", "按用户补充调整：" + t


def _front_interject_response(text, wid, tool_id, stream=_stream_then_tool):
    line, action, instruction = _front_intent(text)
    if action == "steer" and wid:
        return stream(line, tool_id, "task_message", {"id": wid, "text": instruction or text})
    if action == "new":
        return stream(line, tool_id, "spawn_task", {"goal": instruction or text, "context": text, "title": "新任务"})
    if action == "cancel" and wid:
        return stream(line, tool_id, "task_stop", {"id": wid})
    return {"_chunks": [line], "_delay": 0.02}


def _front_memory_step(data, text):
    """「先翻记忆」：前台先带思考调一个步骤（标题「检索用户近期待办」），拿到结果再回话。秒回聊天流里两样都不该出现。"""
    fresh = _fresh_tools(data)
    if fresh and any(m.get("tool_call_id") == "fm1" for m in fresh):
        return {"_chunks": ["秒回：记忆里没有新事要提醒。"], "_delay": 0.02}
    if "先翻记忆" in text and not fresh:
        return _stream_then_tool("", "fm1", "memory_search", {"query": "近期待办", "tool_title": "检索用户近期待办"},
                                 reasoning="REASONING_SHOULD_BE_HIDDEN: check memory first.")
    return None


def front_script(data):
    """秒回前台：「查一下」→ 先回一句再派后台；后台在跑时「插话」→ 先回再转给后台；其余直接秒回。"""
    import re
    text = last_user_text(data)
    if "E2E引用卡布局" in text:
        return {"role": "assistant", "content": (
            "一句话：E2E结论正文：**今夜值班**，记得交班。\n\n这里是展开后的细节。\n\n"
            "依据：这是一段模拟出处。它有较长的标题、期刊名和出版信息，用来验证大字体下的分行。"
            "｜把握度：中（这里是较长的说明，需要正常换行。）")}
    step = _front_memory_step(data, text)
    if step:
        return step
    if _fresh_tools(data):
        return {"role": "assistant", "content": ""}
    blob = json.dumps(data, ensure_ascii=False)
    m = re.search(r"(wk_[a-f0-9]{10})「[^」]*」(进行中|排队中)", blob)
    if not m:
        m = re.search(r"(wk_[a-f0-9]{10}).{0,80}(进行中|排队中)", blob)
    wid = m.group(1) if m else None
    # 「查一下」始终派新活（两个胶囊的用例会在已有任务时再派一件）。其余有后台在跑的消息走意图分析。
    # 假模型也只处理这一轮，不能替应用把合批的输入伪装成逐条回复。
    if "查一下" not in text and wid:
        return _front_interject_response(text, wid, "f2")
    if "查一下" in text:
        title = "慢活" if "慢活" in text else "查资料"
        return _stream_then_tool("好，我让后台去查，做完告诉你。", "f1", "spawn_task",
                                {"goal": text, "context": "TASK_BRIEF_SHOULD_BE_HIDDEN\nFull English brief for the worker: compile a vasoactive-drugs slide deck.", "title": title},
                                reasoning="REASONING_SHOULD_BE_HIDDEN: I will delegate this job to a background worker.")
    return {"_chunks": ["秒回：", text[:20]], "_delay": 0.02}


def local_front_script(data):
    """本地秒回前台：和云端同一套话术；任务 id 从每轮刷新的任务摘要或 spawn_task 的 job_id 里取（本地是 UUID）。"""
    import re
    text = last_user_text(data)
    if _fresh_tools(data):
        return {"role": "assistant", "content": ""}
    blob = json.dumps(data, ensure_ascii=False)
    m = re.search(r"([0-9a-fA-F-]{8,})「[^」]*」(进行中|排队中)", blob)
    if not m:
        m = re.search(r"([0-9a-fA-F-]{8,}).{0,80}(进行中|排队中)", blob)
    if not m:
        m = re.search(r'"job_id"\s*:\s*"([0-9a-fA-F-]{8,})"', blob)
    wid = m.group(1) if m else None
    if "查一下" not in text and wid:
        return _front_interject_response(text, wid, "lf2")

    if "查一下" in text:
        title = "慢活" if "慢活" in text else "查资料"
        return _stream_then_tool("好，我让后台去查，做完告诉你。", "lf1", "spawn_task",
                                {"goal": text, "context": "TASK_BRIEF_SHOULD_BE_HIDDEN\nFull English brief for the worker: compile a vasoactive-drugs slide deck.", "title": title},
                                reasoning="REASONING_SHOULD_BE_HIDDEN: I will delegate this job to a background worker.")
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
    blob = " ".join(str(m.get("content")) for m in msgs if m.get("role") == "user")
    heard = "插话" in blob or "按用户补充调整：" in blob
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
            if w.get("status") in ("queued", "running", "waiting_user"):
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


REALTIME_PORT = 18796
# 假实时服务（OpenAI Realtime 协议，标准库手写 WebSocket）：App 发 input_audio_buffer.append，够 1 秒后回一段字幕 + 声音
REALTIME = {"connections": 0, "session_updates": 0, "appends": 0, "audio_bytes_in": 0, "replies": 0, "events": [],
            # echo 场景：模拟真机外放回声（服务端 VAD 持续「在说话」、把 Bot 自己的话转写成用户输入、上一句转写晚到）
            "scenario": "", "cancels": 0, "loud_appends_in_reply": 0, "echo_done": False, "opening_frames_loud": []}
REALTIME_ECHO_TEXT = "我听到了"
REALTIME_REPLY = "e2e-realtime-ok 我听到了"


def start_fake_realtime():
    import base64, hashlib, math, socketserver, struct

    send_lock = threading.Lock()   # echo 场景另起线程发事件，和主循环的 pong / session.updated 不能交错

    def send(sock, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        n = len(data)
        head = bytes([0x81]) + (bytes([n]) if n < 126 else (bytes([126]) + struct.pack(">H", n) if n < 65536 else bytes([127]) + struct.pack(">Q", n)))
        with send_lock:
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
            in_reply = False

            def echo_reply(sock):
                # 真机 09:26 的事件顺序：回复开始播 → 外放回声让 VAD 持续「在说话」→ 上一句的转写晚到 →
                # 回声被转写成 Bot 自己的话 → 1.5 秒后才 speech_stopped。手机不该取消回复、不该标「打断」、声音要全部播完。
                nonlocal in_reply
                send(sock, {"type": "input_audio_buffer.speech_started", "item_id": "u1"})
                send(sock, {"type": "input_audio_buffer.committed", "item_id": "u1"})
                send(sock, {"type": "response.created", "response": {"id": "r1"}})
                in_reply = True
                send(sock, {"type": "response.output_audio_transcript.delta", "response_id": "r1", "item_id": "a1", "delta": REALTIME_REPLY})
                long_tone = tone * 8   # 4 秒
                for n, i in enumerate(range(0, len(long_tone), 4800)):
                    send(sock, {"type": "response.output_audio.delta", "response_id": "r1", "item_id": "a1",
                                "content_index": 0, "delta": base64.b64encode(long_tone[i:i + 4800]).decode()})
                    if n == 3:
                        send(sock, {"type": "input_audio_buffer.speech_started", "item_id": "echo1"})
                    if n == 5:
                        send(sock, {"type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "（假）用户说话"})
                    if n == 7:
                        send(sock, {"type": "conversation.item.input_audio_transcription.completed", "item_id": "echo1",
                                    "transcript": REALTIME_ECHO_TEXT})
                    if n == 35:   # 回声让 VAD「说」了 1.6 秒，超过手机的插话确认时长
                        send(sock, {"type": "input_audio_buffer.speech_stopped", "item_id": "echo1"})
                    time.sleep(0.05)   # 比实时快一倍发：手机端始终有没播完的声音
                send(sock, {"type": "response.output_audio_transcript.done", "response_id": "r1", "item_id": "a1", "transcript": REALTIME_REPLY})
                time.sleep(2.5)   # 让手机按实时速度把剩下约 2 秒声音「播」完，期间的麦克风上行都算在回复里
                in_reply = False
                send(sock, {"type": "response.done", "response": {"id": "r1", "status": "completed"}})
                REALTIME["echo_done"] = True
            try:
                while True:
                    op, data = recv(self.rfile)
                    if op == 8:
                        return
                    if op == 9:
                        with send_lock:
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
                        if REALTIME["scenario"] == "call_island":
                            time.sleep(3)
                        send(sock, {"type": "session.updated", "session": ev.get("session", {})})
                    elif ty == "response.cancel":
                        REALTIME["cancels"] += 1
                    elif ty == "input_audio_buffer.append":
                        appends += 1
                        REALTIME["appends"] += 1
                        pcm = base64.b64decode(ev.get("audio", ""))
                        REALTIME["audio_bytes_in"] += len(pcm)
                        inspect_opening = REALTIME["scenario"] == "call_island" and appends <= 6
                        loud = (in_reply or inspect_opening) and any(
                            abs(v) > 1500 for (v,) in struct.iter_unpack("<h", pcm[:len(pcm) // 2 * 2])
                        )
                        if inspect_opening:
                            REALTIME["opening_frames_loud"].append(loud)
                        if in_reply and loud:
                            REALTIME["loud_appends_in_reply"] += 1
                        if REALTIME["scenario"] == "echo" and appends >= 30 and not replied:
                            replied = True
                            REALTIME["replies"] += 1
                            threading.Thread(target=echo_reply, args=(sock,), daemon=True).start()
                        elif REALTIME["scenario"] != "echo" and appends >= 10 and not replied:
                            replied = True
                            REALTIME["replies"] += 1
                            send(sock, {"type": "input_audio_buffer.speech_started", "item_id": "u1"})
                            send(sock, {"type": "input_audio_buffer.committed", "item_id": "u1"})
                            send(sock, {"type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "（假）用户说话"})
                            send(sock, {"type": "response.created", "response": {"id": "r1"}})
                            send(sock, {"type": "response.output_audio_transcript.delta", "response_id": "r1", "item_id": "a1", "delta": REALTIME_REPLY})
                            if REALTIME["scenario"] == "caption_only":
                                send(sock, {"type": "response.output_audio_transcript.done", "response_id": "r1", "item_id": "a1", "transcript": REALTIME_REPLY})
                                send(sock, {"type": "response.done", "response": {"id": "r1", "status": "completed"}})
                                continue
                            mid = False
                            for i in range(0, len(tone), 4800):
                                send(sock, {"type": "response.output_audio.delta", "response_id": "r1", "item_id": "a1",
                                            "content_index": 0, "delta": base64.b64encode(tone[i:i + 4800]).decode()})
                                # 播放中的短暂回声：不应把回复字幕换成「被打断」、也不该丢掉后面的音频
                                if not mid:
                                    mid = True
                                    send(sock, {"type": "input_audio_buffer.speech_started", "item_id": "echo1"})
                                    send(sock, {"type": "input_audio_buffer.speech_stopped", "item_id": "echo1"})
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
        # 插件市场 e2e：目录里多一个不访问网络的假 stdio MCP（E2E 回声）
        "OPENMINIS_E2E_FAKE_PLUGIN": os.path.abspath(os.path.join(HERE, "..", "cloud-agent", "test_fake_mcp_server.py")),
    })
    fake_plugin = os.environ["OPENMINIS_E2E_FAKE_PLUGIN"]
    if not os.path.isfile(fake_plugin):
        raise SystemExit("e2e 假插件脚本不存在: " + fake_plugin)
    os.makedirs(os.path.join(work, "data"), exist_ok=True)
    os.makedirs(os.path.join(work, "workspace"), exist_ok=True)

    import test_phase1_support as sup
    sup.FakeModelHandler.scripts[MODEL] = script
    sup.FakeModelHandler.scripts[LOCAL_MODEL] = local_script
    sup.FakeModelHandler.scripts[FRONT_MODEL] = front_script
    sup.FakeModelHandler.scripts[BACK_MODEL] = back_script
    sup.FakeModelHandler.scripts[LOCAL_FRONT_MODEL] = local_front_script
    sup.FakeModelHandler.scripts[LOCAL_BACK_MODEL] = back_script
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
                if PREV_PRIMARY:   # test30 把假 Bot 设成过主 Bot：还原
                    db.execute("UPDATE personas SET is_primary = 0 WHERE persona_id = ?", (BOT_ID,))
                    db.executemany("UPDATE personas SET is_primary = 1 WHERE persona_id = ?", [(p,) for p in PREV_PRIMARY])
                    PREV_PRIMARY.clear()
                elif E2E_PRIMARY_SET:
                    db.execute("UPDATE personas SET is_primary = 0 WHERE persona_id = ?", (BOT_ID,))
                E2E_PRIMARY_SET.clear()
                db.commit()
                db.close()
                # 卸掉上一个流程留下的 e2e 假插件，保证「插件目录安装」可重复跑
                try:
                    import urllib.request
                    req = urllib.request.Request(
                        f"http://127.0.0.1:{API_PORT}/v1/plugins/e2e-echo",
                        method="DELETE",
                        headers={"Authorization": f"Bearer {TOKEN}"},
                    )
                    urllib.request.urlopen(req, timeout=3).read()
                except Exception:
                    pass
                try:
                    _api("PUT", f"/v1/bots/{BOT_ID}/prefs", {"pinned": False, "hidden": False})   # test31 左滑置顶过
                except Exception:
                    pass
                FAKE_DESK.update({"on": False, "clip": "", "typed": [], "keys": [], "clip_sets": []})
                body = json.dumps({"cleared_sessions": len(sids)}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if urlparse(self.path).path == "/_e2e/swipe_history":
                import sqlite3
                with sqlite3.connect(os.environ["OPENMINIS_DB"]) as db:
                    sid = db.execute("SELECT session_id FROM sessions WHERE persona_id = ? ORDER BY created_at DESC LIMIT 1",
                                     (BOT_ID,)).fetchone()
                    if sid:
                        now = time.time()
                        rows = [
                            (sid[0], "user", "E2E先问两个问题", now - 180),
                            (sid[0], "assistant", "E2E左滑要引用第一条", now - 120),
                            (sid[0], "assistant", "E2E第二条需要独立定位", now - 60),
                        ]
                        db.executemany("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)", rows)
                self.send_response(200 if sid else 404)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"seeded": len(rows) if sid else 0}).encode())
                return
            if urlparse(self.path).path == "/_e2e/scroll_history":
                import sqlite3
                with sqlite3.connect(os.environ["OPENMINIS_DB"]) as db:
                    sid = db.execute("SELECT session_id FROM sessions WHERE persona_id = ? ORDER BY created_at DESC LIMIT 1",
                                     (BOT_ID,)).fetchone()
                    if sid:
                        rows = []
                        start = time.time() - 120
                        for i in range(1, 49):
                            rows.append((sid[0], "user", f"滚动测试问题 {i:02d}", start + i * 2))
                            text = f"滚动测试回复 {i:02d}\n\n**这是滚动回归的段落。**\n\n" + "正文用来覆盖聊天历史的排版与惯性滑动。" * 7
                            rows.append((sid[0], "assistant", text, start + i * 2 + 1))
                        db.executemany("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)", rows)
                self.send_response(200 if sid else 404)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"seeded": 48 if sid else 0}).encode())
                return
            if urlparse(self.path).path == "/_e2e/internal_prompt":
                # 往假 Bot 最近的对话里写两条内部提示（新数据带 internal 标记 / 老数据只有提示词原文）和一条 Bot 回复：
                # App 不能把内部提示画成用户气泡（R1：「…只回复 [SKIP]」出现在绿色气泡里）
                import sqlite3, time as _t
                db = sqlite3.connect(os.environ["OPENMINIS_DB"])
                row = db.execute("SELECT s.session_id FROM sessions s JOIN messages m ON m.session_id = s.session_id "
                                 "WHERE s.persona_id = ? ORDER BY m.id DESC LIMIT 1", (BOT_ID,)).fetchone()
                now = _t.time()
                if row:
                    sid = row[0]
                    db.execute("INSERT INTO messages (session_id, role, content, timestamp, meta) VALUES (?, 'user', ?, ?, ?)",
                               (sid, "[例行任务「主动消息」于 2026-01-01 09:00:00 +0800 触发（按计划）]\nE2E_INTERNAL_ROUTINE 先看看用户最近在忙什么。",
                                now, json.dumps({"internal": "routine"})))
                    db.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)",
                               (sid, "E2E_INTERNAL_LEGACY 现在是你主动联系用户的时间。如果没有值得打扰用户的事，只回复 [SKIP]。", now + 0.1))
                    db.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'assistant', ?, ?)",
                               (sid, "例行提醒：E2E 内部提示后的回复", now + 0.2))
                    db.commit()
                db.close()
                body = json.dumps({"session": row[0] if row else None}).encode()
                self.send_response(200 if row else 404)
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
            if urlparse(self.path).path == "/_e2e/primary":
                # 把假 Bot 设成主 Bot（测星标颜色）；/_e2e/reset 会改回来
                import sqlite3
                db = sqlite3.connect(os.environ["OPENMINIS_DB"])
                prev = [r[0] for r in db.execute("SELECT persona_id FROM personas WHERE is_primary = 1 AND persona_id != ?", (BOT_ID,))]
                if prev:
                    PREV_PRIMARY[:] = prev
                db.execute("UPDATE personas SET is_primary = 0")
                db.execute("UPDATE personas SET is_primary = 1 WHERE persona_id = ?", (BOT_ID,))
                db.commit()
                db.close()
                E2E_PRIMARY_SET.append(True)
                body = b'{"ok": true}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if urlparse(self.path).path == "/_e2e/feed":
                # 首页「今日」卡片：塞一条假 Bot 的「主动消息」结果，正文带 Markdown 加粗（测预览不露星号）
                import sqlite3
                now = time.time()
                db = sqlite3.connect(os.environ["OPENMINIS_DB"])
                db.execute("INSERT OR REPLACE INTO routines (routine_id, name, prompt, schedule, enabled, persona_id) "
                           "VALUES ('e2e-proactive', '主动消息', '假的', 'daily 09:00', 0, ?)", (BOT_ID,))
                db.execute("INSERT OR REPLACE INTO routine_runs (run_id, routine_id, session_id, trigger, status, result, started_at, finished_at) "
                           "VALUES ('e2e-proactive-run', 'e2e-proactive', '', 'schedule', 'completed', ?, ?, ?)",
                           ("昨晚值班辛苦，今天你是**E2E下夜班**，先补觉。\n\n顺手确认：表上你 **11/14–16 日（假数据）**", now - 5, now))
                db.commit()
                db.close()
                body = b'{"ok": true}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if urlparse(self.path).path == "/_e2e/realtime":
                sc = parse_qs(urlparse(self.path).query, keep_blank_values=True).get("scenario")
                if sc is not None:
                    REALTIME.update(scenario=sc[0], cancels=0, loud_appends_in_reply=0, echo_done=False, opening_frames_loud=[])
                body = json.dumps(REALTIME, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            want = (parse_qs(urlparse(self.path).query).get("model") or [MODEL])[0]
            # users：这条请求里所有用户消息（插话 / 转给后台的补充要求按顺序接在后面，只看最后一条会漏掉前面的）
            reqs = [{"model": r.get("model"), "images": image_count(r), "text": last_user_text(r)[:200],
                     "users": [u[:300] for u in user_texts(r)]}
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

    def call(method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Authorization": "Bearer " + TOKEN}
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(f"http://127.0.0.1:{api.server_address[1]}{path}", method=method,
                                     data=data, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read() or b"{}")

    call("PUT", "/v1/credentials/e2e", {"api_key": "sk-e2e-fake-000000000000", "base_url": model_base})
    call("PUT", f"/v1/bots/{BOT_ID}", {"name": BOT_NAME, "instructions": "端到端测试 Bot", "model": MODEL, "credential": "e2e"})
    set_reply("verbose")
    plugins = call("GET", "/v1/plugins")
    ids = [c["id"] for c in (plugins.get("catalog") or [])]
    print("插件目录 %d 项，首位 %s" % (len(ids), ids[:1]), flush=True)
    if ids[:1] != ["e2e-echo"]:
        raise SystemExit("GET /v1/plugins 没有把 e2e-echo 放在首位：" + ",".join(ids))
    print(f"E2E 云端就绪：API 127.0.0.1:{api.server_address[1]}，假模型 {model_base}，本地假模型 127.0.0.1:{LOCAL_MODEL_PORT}/v1，探针 127.0.0.1:18799", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
