#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""云端 Agent 延迟基准（本机、合成模型）。

用法：python3 bench_latency.py [--server-dir DIR] [--runs N] [--json out.json]
  --server-dir 指向要测的 cloud_agent_server.py 所在目录（可以是旧版本的 git worktree，用来对比改动前后）。

合成模型：首 token 延迟 TTFT_MS（默认 400ms），之后每 TOKEN_MS（默认 25ms）一个 token，回复 REPLY_TOKENS 个 token。
支持 stream=true（SSE）和 stream=false（等全部生成完再返回）。数字只反映服务端与 API 的开销 + 合成模型时间，不代表真实服务商。

指标：
  accept_ms           POST 消息到拿到 202 的时间
  first_text_api_ms   通过 API 第一次能读到助手文字的时间（50ms 轮询 / 支持时用长轮询）
  first_text_app_ms   按 App 的取数方式能看到第一段文字的时间（旧版 App 每 2 秒拉一次；新版用长轮询）
  total_ms            任务完成（status=completed）的时间
  request_tokens      发给模型的请求体估算 token（字节数/4，含工具定义）
  tool_defs           发给模型的工具定义个数
"""
import argparse
import json
import math
import os
import statistics
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TTFT_MS = int(os.environ.get("TTFT_MS", "400"))
TOKEN_MS = int(os.environ.get("TOKEN_MS", "25"))
REPLY_TOKENS = int(os.environ.get("REPLY_TOKENS", "60"))
APP_POLL_OLD_S = 2.0


class FakeModel(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    log = []
    scenario = "chat"

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n)
        data = json.loads(raw)
        FakeModel.log.append({"bytes": len(raw), "tools": len(data.get("tools") or []), "stream": bool(data.get("stream"))})
        msgs = data.get("messages", [])
        tool_turns = [m for m in msgs if m.get("role") == "tool"]
        if FakeModel.scenario == "tools" and len(tool_turns) < 2:
            name = "file_write" if not tool_turns else "file_read"
            args = {"path": "bench.txt", "content": "hello"} if name == "file_write" else {"path": "bench.txt"}
            msg = {"role": "assistant", "content": None, "tool_calls": [{"id": f"c{len(tool_turns)}", "type": "function",
                                                                       "function": {"name": name, "arguments": json.dumps(args)}}]}
            self._reply(data, msg, tokens=15)
            return
        words = ["测试"] * REPLY_TOKENS
        self._reply(data, {"role": "assistant", "content": "".join(words)}, tokens=REPLY_TOKENS)

    def _reply(self, data, msg, tokens):
        time.sleep(TTFT_MS / 1000)
        if data.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            def chunk(obj):
                b = ("data: " + json.dumps(obj, ensure_ascii=False) + "\n\n").encode()
                self.wfile.write(f"{len(b):x}\r\n".encode() + b + b"\r\n")
                self.wfile.flush()
            if msg.get("tool_calls"):
                tc = msg["tool_calls"][0]
                chunk({"choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [
                    {"index": 0, "id": tc["id"], "type": "function", "function": {"name": tc["function"]["name"], "arguments": ""}}]}}]})
                time.sleep(TOKEN_MS * tokens / 1000)
                chunk({"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": tc["function"]["arguments"]}}]}}]})
            else:
                text = msg["content"]
                per = max(1, len(text) // tokens)
                for i in range(0, len(text), per):
                    chunk({"choices": [{"index": 0, "delta": {"content": text[i:i + per]}}]})
                    time.sleep(TOKEN_MS / 1000)
            chunk({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 100, "completion_tokens": tokens}})
            b = b"data: [DONE]\n\n"
            self.wfile.write(f"{len(b):x}\r\n".encode() + b + b"\r\n0\r\n\r\n")
            self.wfile.flush()
            return
        time.sleep(TOKEN_MS * tokens / 1000)
        body = json.dumps({"id": "x", "object": "chat.completion", "choices": [{"index": 0, "message": msg, "finish_reason": "stop"}],
                           "usage": {"prompt_tokens": 100, "completion_tokens": tokens}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def serve(handler):
    s = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s, s.server_address[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server-dir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--json")
    ap.add_argument("--client", choices=["auto", "local", "bot", "both"], default="auto",
                    help="模拟哪种 App 取数方式：local=本地云电脑（每 1 秒拉一次事件，只看整段文字）；bot=多 Bot（长轮询 + 正在生成的文字）")
    a = ap.parse_args()
    sys.path.insert(0, a.server_dir)
    td = tempfile.mkdtemp()
    os.environ["OPENMINIS_MASTER_KEY_FILE"] = os.path.join(td, "master.key")
    import cloud_secrets
    cloud_secrets.reset()
    import cloud_agent_server as srv
    srv.DB_PATH = os.path.join(td, "agent.db")
    srv.GLOBAL_WORKSPACE = os.path.join(td, "ws")
    os.makedirs(srv.GLOBAL_WORKSPACE, exist_ok=True)
    srv.SERVER_TOKEN = "bench-token"
    if hasattr(srv, "configure_paths"):
        srv.configure_paths(os.path.join(td, "data"))
    srv.init_db()
    _m, mport = serve(FakeModel)
    _s, port = serve(srv.CloudAgentHandler)
    base = f"http://127.0.0.1:{port}"
    model_base = f"http://127.0.0.1:{mport}/v1"

    def req(method, path, body=None, timeout=30):
        r = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                                   headers={"Authorization": "Bearer bench-token", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    longpoll = False
    caps = req("GET", "/health")[1].get("capabilities", {})
    longpoll = bool(caps.get("event_longpoll"))

    def text_in(events):
        for e in events:
            p = e.get("payload") or {}
            if e.get("type") in ("delta", "thought") and (p.get("text") or p.get("content")):
                return True
        return False

    clients = {"auto": ["auto"], "local": ["local"], "bot": ["bot"], "both": ["local", "bot"]}[a.client]
    results = {}
    for client, scenario in [(c, sc) for c in clients for sc in ("chat", "tools")]:
        FakeModel.scenario = scenario
        rows = []
        for i in range(a.runs):
            sid = req("POST", "/v1/sessions", {"title": "b"})[1]["session_id"]
            FakeModel.log.clear()
            t0 = time.perf_counter()
            st, r = req("POST", f"/v1/sessions/{sid}/messages", {"content": "你好，请回复", "model": "bench-model",
                                                                  "provider": {"base_url": model_base, "api_key": "sk-bench-000000000000000000"}})
            assert st == 202, r
            accept = time.perf_counter() - t0
            tid = r["task_id"]
            first_text = None
            cursor = 0
            live_after = -1
            status = "running"
            while True:
                use_long = longpoll if client == "auto" else client == "bot"
                path = f"/v1/tasks/{tid}/events?after={cursor}" + (f"&wait=15&live_after={live_after}" if use_long else "")
                _st, ev = req("GET", path)
                now = time.perf_counter() - t0
                live = ev.get("live") or {}
                if live:
                    live_after = live.get("seq", live_after)
                if first_text is None and (text_in(ev.get("events", [])) or live.get("text")):
                    first_text = now
                cursor = ev.get("last_cursor", cursor)
                status = ev.get("status")
                if status not in ("queued", "running", "waiting_user"):
                    total = now
                    break
                if client == "local":
                    time.sleep(1.0)          # 与 CloudTaskPump 本地模式（wait=0）相同的 1 秒间隔
                elif not use_long:
                    time.sleep(0.05)
            if first_text is None:
                first_text = total
            if client in ("local", "bot"):
                app = first_text             # 已按该模式的真实取数方式测得
            else:
                app = first_text if longpoll else math.ceil(first_text / APP_POLL_OLD_S) * APP_POLL_OLD_S
            rows.append({"accept_ms": accept * 1000, "first_text_api_ms": first_text * 1000, "first_text_app_ms": app * 1000,
                         "total_ms": total * 1000, "request_tokens": sum(x["bytes"] for x in FakeModel.log) // 4,
                         "tool_defs": max((x["tools"] for x in FakeModel.log), default=0), "llm_calls": len(FakeModel.log),
                         "streamed": all(x["stream"] for x in FakeModel.log), "status": status})
        agg = {k: round(statistics.median([r[k] for r in rows]), 1) for k in ("accept_ms", "first_text_api_ms", "first_text_app_ms", "total_ms", "request_tokens", "tool_defs", "llm_calls")}
        agg["streamed"] = rows[0]["streamed"]
        agg["statuses"] = sorted({r["status"] for r in rows})
        results[scenario if client == "auto" else f"{client}/{scenario}"] = agg
    out = {"server_dir": a.server_dir, "runs": a.runs, "ttft_ms": TTFT_MS, "token_ms": TOKEN_MS, "reply_tokens": REPLY_TOKENS,
           "longpoll": longpoll, "results": results}
    print(json.dumps(out, ensure_ascii=False, indent=2))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
    sys.stdout.flush()
    os._exit(0)


if __name__ == "__main__":
    main()
