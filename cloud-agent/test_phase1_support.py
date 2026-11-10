#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 1 测试公共设施：临时目录中的真实服务端 + 可编排的假模型服务商。

假模型按 model 名路由到脚本函数；脚本接收请求体，返回 OpenAI Chat Completions 的
message 字典。每个测试类在独立临时目录中启动，数据库、主密钥、工作区互不影响。
"""

import os
import sys
import json
import time
import tempfile
import threading
import unittest
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)


class FakeModelHandler(BaseHTTPRequestHandler):
    scripts = {}
    requests = []
    auth_headers = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        data = json.loads(self.rfile.read(length).decode("utf-8"))
        FakeModelHandler.requests.append(data)
        FakeModelHandler.auth_headers.append(self.headers.get("Authorization", ""))
        if self.path == "/v1/images/generations":
            import base64
            png = b"\x89PNG\r\n\x1a\n" + data.get("prompt", "").encode("utf-8")
            body = json.dumps({"data": [{"b64_json": base64.b64encode(png).decode(), "revised_prompt": "rp"}]}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path != "/v1/chat/completions":
            self.send_response(404)
            self.end_headers()
            return
        script = FakeModelHandler.scripts.get(data.get("model"))
        message = script(data) if script else {"role": "assistant", "content": "ok"}
        if isinstance(message, dict) and message.get("_status"):
            # 模拟服务商报错（如不认识的参数）
            body = json.dumps({"error": message.get("error") or {"message": "bad request"}}).encode("utf-8")
            self.send_response(int(message["_status"]))
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if isinstance(message, dict) and message.get("_chunks") is not None:
            # 流式回复：按 _chunks 逐块发 SSE，每块间隔 _delay 秒
            chunks, delay = message["_chunks"], message.get("_delay", 0.05)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for piece in chunks:
                if delay:
                    time.sleep(delay)
                delta = piece if isinstance(piece, dict) else {"content": piece}     # dict = 原样的 delta（reasoning_content / tool_calls）
                try:
                    self.wfile.write(b"data: " + json.dumps({"choices": [{"index": 0, "delta": delta}]}).encode() + b"\n\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return          # 客户端中途不要了（插话中止）
            self.wfile.write(b"data: " + json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                                                     "usage": {"prompt_tokens": 11, "completion_tokens": len(chunks)}}).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
            return
        body = json.dumps({"id": "fake", "object": "chat.completion",
                           "choices": [{"index": 0, "message": message, "finish_reason": "stop"}]}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        return


def tool_call(call_id, name, args, content=None):
    return {"role": "assistant", "content": content,
            "tool_calls": [{"id": call_id, "type": "function",
                            "function": {"name": name, "arguments": json.dumps(args, ensure_ascii=False)}}]}


def tool_turns(data):
    return [m for m in data.get("messages", []) if m.get("role") == "tool"]


class NotifySinkHandler(BaseHTTPRequestHandler):
    """记录 Bark / ntfy 推送请求的本地接收端。"""
    received = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        NotifySinkHandler.received.append({"path": self.path, "headers": dict(self.headers), "body": body})
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        return


def _serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


class CloudServerTestCase(unittest.TestCase):
    token = "phase1-test-token"
    extra_env = {}
    approval_mode = None   # "ask" = 这一组测试要看审批卡（服务端默认「一律批准」）

    @classmethod
    def setUpClass(cls):
        cls._threads_before = set(threading.enumerate())
        cls.tmp = tempfile.TemporaryDirectory()
        td = cls.tmp.name
        os.environ["OPENMINIS_MASTER_KEY_FILE"] = os.path.join(td, "conf", "master.key")
        os.environ.pop("OPENMINIS_MASTER_KEY", None)
        for k, v in cls.extra_env.items():
            os.environ[k] = v
        import cloud_secrets
        cloud_secrets.reset()
        import cloud_agent_server as srv
        cls.srv = srv
        srv.DB_PATH = os.path.join(td, "agent.db")
        srv.SYSNAP_ETC = os.path.join(td, "etc")      # 系统快照只打包测试用的假 /etc
        os.makedirs(srv.SYSNAP_ETC, exist_ok=True)
        srv.GLOBAL_WORKSPACE = os.path.join(td, "workspace")
        os.makedirs(srv.GLOBAL_WORKSPACE, exist_ok=True)
        srv.SERVER_TOKEN = cls.token
        if hasattr(srv, "configure_paths"):
            srv.configure_paths(os.path.join(td, "data"))
        srv.init_db()
        if getattr(srv, "APP_FEED", None) is not None:      # 在线状态是模块级的，别串到下一个测试类
            srv.APP_FEED.presence.update(last_seen=0.0, foreground=False, local_notifications=False)
        FakeModelHandler.scripts = {}
        FakeModelHandler.requests = []
        FakeModelHandler.auth_headers = []
        NotifySinkHandler.received = []
        cls.model_server, port = _serve(FakeModelHandler)
        cls.model_base = f"http://127.0.0.1:{port}/v1"
        cls.notify_server, nport = _serve(NotifySinkHandler)
        cls.notify_base = f"http://127.0.0.1:{nport}"
        cls.api_server, cls.api_port = _serve(srv.CloudAgentHandler)
        if cls.approval_mode:
            srv.update_resource_settings({"bot_defaults": {"approval_mode": cls.approval_mode}})

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls.srv, "stop_scheduler"):
            cls.srv.stop_scheduler()
        for s in (cls.api_server, cls.model_server, cls.notify_server):
            try:
                s.shutdown()
            except Exception:
                pass
        cls._drain_background()
        for k in list(cls.extra_env.keys()) + ["OPENMINIS_MASTER_KEY_FILE"]:
            os.environ.pop(k, None)
        cls.tmp.cleanup()

    @classmethod
    def _drain_background(cls, timeout=20):
        """取消本类留下的任务，并等后台线程（委托、子代理、群聊…）退出后再删临时目录，
        否则它们会往已删除的数据库里写，报 unable to open database file，还会拖慢 / 干扰下一个测试类。"""
        srv = cls.srv
        try:
            import cloud_llm
            cloud_llm.POOL.close_all()
        except Exception:
            pass
        lock = getattr(srv, "active_tasks_lock", None)
        if lock is not None:
            with lock:
                tids = list(srv.active_tasks.keys())
            for tid in tids:
                try:
                    srv.set_task_cancelled(tid)
                except Exception:
                    pass
        deadline = time.time() + timeout
        while time.time() < deadline:
            alive = [t for t in threading.enumerate()
                     if t not in cls._threads_before and t is not threading.current_thread() and t.is_alive()
                     and t.name not in ("routine-scheduler", "watchdog")]
            if not alive:
                break
            time.sleep(0.05)
        if lock is not None:
            with lock:
                srv.active_tasks.clear()

    def request(self, method, path, data=None, token=None):
        token = self.token if token is None else token
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        body = json.dumps(data).encode("utf-8") if data is not None else None
        req = urllib.request.Request(f"http://127.0.0.1:{self.api_port}{path}", data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                raw = resp.read().decode("utf-8")
                return resp.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8")
            return e.code, (json.loads(raw) if raw else {})

    def new_session(self, title="t"):
        status, res = self.request("POST", "/v1/sessions", {"title": title})
        self.assertEqual(status, 201)
        return res["session_id"]

    def submit(self, sid, content, model, provider=None, **extra):
        body = {"content": content, "model": model,
                "provider": provider or {"base_url": self.model_base, "api_key": "sk-inline-test-key-000000000000"}}
        body.update(extra)
        return self.request("POST", f"/v1/sessions/{sid}/messages", body)

    def wait_status(self, task_id, statuses, timeout=15):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            status, res = self.request("GET", f"/v1/tasks/{task_id}")
            last = res
            if res.get("status") in statuses:
                return res
            time.sleep(0.1)
        self.fail(f"task {task_id} did not reach {statuses}; last={last}")

    def wait_until(self, predicate, timeout=15, message="condition not met"):
        deadline = time.time() + timeout
        while time.time() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.1)
        self.fail(message)
