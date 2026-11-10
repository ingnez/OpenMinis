"""提速相关：流式输出、长轮询、按需工具、上下文精简、并行工具、超长输出落盘、快速模式、性能记录。"""
import json
import os
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cloud_llm
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


class _SSE(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    seen_ports = []

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        _SSE.seen_ports.append(self.client_address[1])
        chunks = [{"choices": [{"index": 0, "delta": {"content": "你"}}]},
                  {"choices": [{"index": 0, "delta": {"content": "好"}}]},
                  {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "c1", "function": {"name": "file_read", "arguments": "{\"pa"}}]}}]},
                  {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": "th\": \"a\"}"}}]}, "finish_reason": "tool_calls"}]},
                  {"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 3}}]
        body = b"".join(b"data: " + json.dumps(c).encode() + b"\n\n" for c in chunks) + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class LLMClientTests(unittest.TestCase):
    def test_stream_parse_and_keepalive(self):
        srv = ThreadingHTTPServer(("127.0.0.1", 0), _SSE)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{srv.server_address[1]}/v1/chat/completions"
            pool = cloud_llm.HTTPPool()
            seen = []
            out, timing = cloud_llm.chat_completion(url, {"Content-Type": "application/json"}, {"model": "m", "messages": []},
                                                    stream=True, on_text=seen.append, pool=pool)
            msg = out["choices"][0]["message"]
            self.assertEqual(msg["content"], "你好")
            self.assertEqual(msg["tool_calls"][0]["function"], {"name": "file_read", "arguments": "{\"path\": \"a\"}"})
            self.assertEqual(out["usage"]["completion_tokens"], 3)
            self.assertTrue(timing["streamed"])
            self.assertEqual(seen[-1], "你好")
            cloud_llm.chat_completion(url, {}, {"model": "m", "messages": []}, stream=True, pool=pool)
            self.assertEqual(pool.stats, {"new": 1, "reused": 1})        # 第二次复用同一个 TCP 连接
            self.assertEqual(len(set(_SSE.seen_ports)), 1)
        finally:
            srv.shutdown()

    def test_select_tools_lazy(self):
        defs = [{"type": "function", "function": {"name": n}} for n in ("file_read", "browser_action", "image_generate", "plugin_x")]
        tools, omitted = cloud_llm.select_tools(defs, [{"role": "system", "content": "s"}, {"role": "user", "content": "你好"}])
        names = [t["function"]["name"] for t in tools]
        self.assertEqual(omitted, ["browser_action", "image_generate"])
        self.assertIn("plugin_x", names)
        self.assertIn("request_tools", names)
        tools, omitted = cloud_llm.select_tools(defs, [{"role": "user", "content": "打开这个网页 https://a.b"}], extra={"image_generate"})
        self.assertEqual(omitted, [])
        tools, _ = cloud_llm.select_tools(defs, [{"role": "user", "content": "hi"}], always_all=True)
        self.assertEqual(len(tools), 4)

    def test_trim_keeps_pairs(self):
        msgs = [{"role": "system", "content": "sys"}]
        for i in range(30):
            msgs.append({"role": "user", "content": f"问题{i} " + "x" * 400})
            msgs.append({"role": "assistant", "content": None, "tool_calls": [{"id": f"c{i}", "function": {"name": "file_read", "arguments": "{}"}}]})
            msgs.append({"role": "tool", "tool_call_id": f"c{i}", "content": "y" * 3000})
            msgs.append({"role": "assistant", "content": "答"})
        out, note = cloud_llm.trim_messages(msgs, 4000)
        self.assertTrue(note)
        self.assertLess(cloud_llm.estimate_tokens(out), cloud_llm.estimate_tokens(msgs))
        self.assertEqual(out[1]["role"], "user")
        ids = {tc["id"] for m in out for tc in (m.get("tool_calls") or [])}
        self.assertEqual(ids, {m["tool_call_id"] for m in out if m.get("role") == "tool"})
        self.assertIn("精简", out[0]["content"])
        self.assertEqual(msgs[0]["content"], "sys")            # 原列表不被修改
        self.assertEqual(cloud_llm.trim_messages(msgs[:3], 4000)[1], None)


class SpeedServerTests(CloudServerTestCase):
    def test_01_stream_live_and_longpoll(self):
        FakeModelHandler.scripts["m-stream"] = lambda d: {"_chunks": ["第一句，", "第二句，", "第三句。"], "_delay": 0.4}
        sid = self.new_session()
        t = self.submit(sid, "讲个故事", "m-stream")[1]
        t0 = time.time()
        code, res = self.request("GET", f"/v1/tasks/{t['task_id']}/events?after=0&wait=10&live_after=-1")
        self.assertEqual(code, 200)
        # 不是等到整段完成才返回：拿到第一批事件或流式文字时就返回
        self.assertLess(time.time() - t0, 1.5)
        live_seen = None
        cursor = res["last_cursor"]
        live_after = -1
        deadline = time.time() + 8
        while time.time() < deadline:
            code, res = self.request("GET", f"/v1/tasks/{t['task_id']}/events?after={cursor}&wait=5&live_after={live_after}")
            cursor = res["last_cursor"]
            if res.get("live"):
                live_after = res["live"]["seq"]
                live_seen = live_seen or res["live"]["text"]
            if res["status"] == "completed":
                break
        self.assertTrue(live_seen and live_seen.startswith("第一句"))
        self.assertNotEqual(live_seen, "第一句，第二句，第三句。")
        done = self.wait_status(t["task_id"], ("completed",))
        self.assertEqual(FakeModelHandler.requests[-1]["stream"], True)
        ev = self.request("GET", f"/v1/tasks/{t['task_id']}/events?after=0")[1]["events"]
        timings = [e["payload"] for e in ev if e["type"] == "timings"]
        self.assertEqual(len(timings), 1)
        self.assertTrue(timings[0]["streamed"])
        self.assertLess(timings[0]["first_text_ms"], timings[0]["total_ms"])
        self.assertEqual(timings[0]["completion_tokens"], 3)
        perf = self.request("GET", "/v1/perf")[1]
        self.assertTrue(any(r["task_id"] == t["task_id"] for r in perf["recent"]))
        self.assertIn("first_text_ms", perf["median"])

    def test_02_longpoll_times_out_when_idle(self):
        FakeModelHandler.scripts["m-quick"] = lambda d: {"role": "assistant", "content": "好"}
        sid = self.new_session()
        t = self.submit(sid, "hi", "m-quick")[1]
        self.wait_status(t["task_id"], ("completed",))
        cur = self.request("GET", f"/v1/tasks/{t['task_id']}/events?after=0")[1]["last_cursor"]
        t0 = time.time()
        res = self.request("GET", f"/v1/tasks/{t['task_id']}/events?after={cur}&wait=3")[1]
        self.assertLess(time.time() - t0, 1.0)           # 已结束的任务不挂起
        self.assertEqual(res["events"], [])
        self.assertTrue(self.request("GET", "/health")[1]["capabilities"]["event_longpoll"])
        self.assertEqual(self.request("GET", f"/v1/tasks/{t['task_id']}/events?wait=x")[0], 400)

    def test_03_lazy_tools_and_request_tools(self):
        calls = {"n": 0}
        def script(d):
            calls["n"] += 1
            names = [t["function"]["name"] for t in d.get("tools", [])]
            if calls["n"] == 1:
                self.assertNotIn("browser_action", names)
                self.assertIn("request_tools", names)
                return tool_call("r1", "request_tools", {"names": ["image_generate"]})
            self.assertIn("image_generate", names)
            return {"role": "assistant", "content": "好了"}
        FakeModelHandler.scripts["m-lazy"] = script
        sid = self.new_session()
        t = self.submit(sid, "随便聊聊", "m-lazy")[1]
        self.wait_status(t["task_id"], ("completed",))
        self.assertEqual(calls["n"], 2)
        self.request("PUT", "/v1/resources", {"lazy_tools": False})
        try:
            FakeModelHandler.scripts["m-all"] = lambda d: {"role": "assistant", "content": str(len(d["tools"]))}
            t = self.submit(sid, "再聊", "m-all")[1]
            self.wait_status(t["task_id"], ("completed",))
            self.assertNotIn("request_tools", [x["function"]["name"] for x in FakeModelHandler.requests[-1]["tools"]])
        finally:
            self.request("PUT", "/v1/resources", {"lazy_tools": True})

    def test_04_parallel_readonly_tools_and_spill(self):
        sid = self.new_session()
        ws = self.srv.get_session_workspace(sid)
        with open(os.path.join(ws, "a.txt"), "w") as f:
            f.write("A")
        with open(os.path.join(ws, "b.txt"), "w") as f:
            f.write("B")
        def script(d):
            if not tool_turns(d):
                m = tool_call("p1", "file_read", {"path": "a.txt"})
                m["tool_calls"].append({"id": "p2", "type": "function", "function": {"name": "file_read", "arguments": json.dumps({"path": "b.txt"})}})
                return m
            if len(tool_turns(d)) == 2:
                return tool_call("s1", "shell_execute", {"command": "python3 -c \"print('z'*40000)\""})
            return {"role": "assistant", "content": "完成"}
        FakeModelHandler.scripts["m-par"] = script
        t = self.submit(sid, "读两个文件", "m-par")[1]
        self.wait_status(t["task_id"], ("completed",), timeout=30)
        ev = self.request("GET", f"/v1/tasks/{t['task_id']}/events?after=0")[1]["events"]
        self.assertTrue(any(e["type"] == "status" and "并行" in e["payload"].get("message", "") for e in ev))
        last = FakeModelHandler.requests[-1]["messages"]
        tools = [m for m in last if m["role"] == "tool"]
        self.assertEqual([m["tool_call_id"] for m in tools[:2]], ["p1", "p2"])     # 结果按原顺序
        self.assertIn("A", tools[0]["content"])
        self.assertEqual(self.request("PUT", "/v1/resources", {"context_trim_tokens": 100})[0], 400)
        self.assertLess(len(tools[2]["content"]), 12000)
        self.assertIn(".outputs/", tools[2]["content"])
        self.assertTrue(os.path.exists(os.path.join(ws, ".outputs", "s1.txt")))

    def test_05_fast_mode_and_warm(self):
        code, b = self.request("PUT", "/v1/bots/quick", {"name": "快", "instructions": "x", "fast_mode": True, "reasoning_effort": "high"})
        self.assertIn(code, (200, 201), b)
        self.assertTrue(self.request("GET", "/v1/bots/quick")[1]["fast_mode"])
        self.assertEqual(self.request("PUT", "/v1/bots/quick", {"fast_mode": "yes"})[0], 400)
        FakeModelHandler.scripts["m-fast"] = lambda d: {"role": "assistant", "content": "短"}
        sid = self.request("POST", "/v1/sessions", {"title": "f", "persona_id": "quick"})[1]["session_id"]
        t = self.submit(sid, "hi", "m-fast")[1]
        self.wait_status(t["task_id"], ("completed",))
        req = FakeModelHandler.requests[-1]
        self.assertIn("[快速模式]", req["messages"][0]["content"])
        self.assertEqual(req.get("reasoning_effort"), "low")
        self.assertEqual(self.request("POST", f"/v1/sessions/{sid}/warm", {})[0], 202)

    def test_06_gzip_large_response(self):
        req = urllib.request.Request(f"http://127.0.0.1:{self.api_port}/v1/perf",
                                     headers={"Authorization": "Bearer " + self.token, "Accept-Encoding": "gzip"})
        with urllib.request.urlopen(req) as r:
            body = r.read()
            enc = r.headers.get("Content-Encoding")
        import gzip
        raw = gzip.decompress(body) if enc == "gzip" else body
        self.assertIn("recent", json.loads(raw))
        self.assertEqual(enc == "gzip", len(raw) > 4096)


if __name__ == "__main__":
    unittest.main()
