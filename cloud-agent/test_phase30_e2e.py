#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 30：端到端场景（假模型服务商，真实服务端 HTTP 接口）。

一组用户真实会走的路径，每条从手机发请求开始、到结果落库 / 事件流为止：
普通聊天、发图、长任务运行中另开对话、插话、/reset、后台回来续拉事件、重复提交 / 重复事件、
任务中途服务重启、多 Bot 分派、保管库填写、代理导入。

同时记录延迟（首个字、首个 token、总耗时）。这里的模型是本地假模型，数字只说明服务端本身的开销，
标记为 mock，不代表真实模型的速度。设 OPENMINIS_E2E_REPORT=路径 时把结果写成 JSON。
"""

import base64
import json
import os
import time
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns

FAKE_KEY = "sk-fake-e2e-0000000000000000"
PNG = b"\x89PNG\r\n\x1a\n" + b"FAKE-E2E-PNG" * 4
PNG_URL = "data:image/png;base64," + base64.b64encode(PNG).decode()
FAKE_UUID = "00000000-1111-4222-8333-444444444444"
FAKE_PBK = "FAKEpbkFAKEpbkFAKEpbkFAKEpbkFAKEpbkFAKEpbk0"
FAKE_PW = "FakeE2E-Pass-7x"
LATENCY = []


def say(text):
    return {"role": "assistant", "content": text}


class E2EScenarios(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/credentials/e2e", {"api_key": FAKE_KEY, "base_url": self.model_base})

    @classmethod
    def tearDownClass(cls):
        report = {"label": "mock（本地假模型，只反映服务端开销，不代表真实模型速度）", "runs": LATENCY}
        path = os.environ.get("OPENMINIS_E2E_REPORT")
        if path:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(report, f, ensure_ascii=False, indent=1)
        if LATENCY:
            print("\n[e2e mock 延迟] " + "; ".join(f"{r['scenario']}: " + (f"首字 {r['first_text_ms']}ms / " if r['first_text_ms'] is not None else "") + f"总 {r['total_ms']}ms" for r in LATENCY))
        super().tearDownClass()

    # —— 工具 ——
    def _events(self, tid, after=0):
        return self.request("GET", f"/v1/tasks/{tid}/events?after={after}")[1]["events"]

    def _run(self, sid, text, model, scenario=None, timeout=30, **extra):
        t0 = time.time()
        code, res = self.submit(sid, text, model, **extra)
        self.assertIn(code, (200, 201, 202), res)
        final = self.wait_status(res["task_id"], {"completed"}, timeout=timeout)
        if scenario:
            t = next((e["payload"] for e in final["events"] if e["type"] == "timings"), {})
            LATENCY.append({"scenario": scenario, "first_text_ms": t.get("first_text_ms"), "ttft_ms": t.get("ttft_ms"),
                            "total_ms": t.get("total_ms"), "client_total_ms": round((time.time() - t0) * 1000, 1), "source": "mock"})
        return res, final

    def _last_reply(self, sid):
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        return [m for m in msgs if m["role"] == "assistant"][-1]["content"]

    # —— 场景 ——
    def test_01_plain_chat(self):
        FakeModelHandler.scripts["e-chat"] = lambda d: {"_chunks": ["你好", "，我在"], "_delay": 0.02}
        sid = self.new_session()
        res, final = self._run(sid, "在吗", "e-chat", scenario="普通聊天（流式）")
        self.assertEqual(self._last_reply(sid), "你好，我在")
        types = [e["type"] for e in final["events"]]
        self.assertIn("timings", types)
        self.assertEqual(types.count("thought"), 1, "回复只发一次")

    def test_02_image_in(self):
        FakeModelHandler.scripts["e-eyes"] = lambda d: say("图里是一行字")
        sid = self.new_session()
        self._run(sid, "看图", "e-eyes", scenario="发图",
                  message_parts=[{"type": "text", "text": "看图"}, {"type": "image_url", "image_url": {"url": PNG_URL}}])
        req = [r for r in FakeModelHandler.requests if r.get("model") == "e-eyes"][-1]
        parts = [p for m in req["messages"] if m.get("role") == "user" and isinstance(m.get("content"), list) for p in m["content"]]
        self.assertTrue(any(p.get("type") == "image_url" and p["image_url"]["url"] == PNG_URL for p in parts))
        self.assertFalse(req.get("tools") and any(m.get("role") == "tool" for m in req["messages"]), "看图不该先跑工具")

    def test_03_long_tool_run_while_chatting(self):
        def slow(d):
            if not tool_turns(d):
                return tool_call("s1", "shell_execute", {"command": "sleep 3; echo fertig"})
            return say("长任务做完了")
        FakeModelHandler.scripts["e-slow"] = slow
        FakeModelHandler.scripts["e-quick"] = lambda d: say("马上回你")
        long_sid, chat_sid = self.new_session(), self.new_session()
        long_tid = self.submit(long_sid, "跑个长任务", "e-slow")[1]["task_id"]
        self.wait_until(lambda: any(e["type"] == "tool_call" for e in self._events(long_tid)), message="长任务没开始跑工具")
        t0 = time.time()
        self._run(chat_sid, "顺便问一句", "e-quick", scenario="长任务运行中另开对话")
        self.assertLess(time.time() - t0, 2.5, "另一个对话不该等长任务")
        self.assertEqual(self.request("GET", f"/v1/tasks/{long_tid}")[1]["status"], "running")
        self.wait_status(long_tid, {"completed"}, timeout=30)
        self.assertEqual(self._last_reply(long_sid), "长任务做完了")

    def test_04_steering(self):
        def script(d):
            users = [m for m in d["messages"] if m["role"] == "user"]
            if len(users) == 1:
                return {"_chunks": ["很", "长", "的", "回复"] * 10, "_delay": 0.12}
            return say("改成：" + users[-1]["content"])
        FakeModelHandler.scripts["e-steer"] = script
        sid = self.new_session()
        tid = self.submit(sid, "写长文", "e-steer")[1]["task_id"]
        self.wait_until(lambda: (self.request("GET", f"/v1/tasks/{tid}/events?after=0&live_after=-1")[1].get("live") or {}).get("text"),
                        message="没开始流式输出")
        self.assertEqual(self.request("POST", f"/v1/tasks/{tid}/messages", {"content": "一句话就行", "nonce": "e2e-steer"})[0], 202)
        t0 = time.time()
        self.wait_status(tid, {"completed"})
        self.assertLess(time.time() - t0, 4, "插话应打断长回复")
        self.assertEqual(self._last_reply(sid), "改成：一句话就行")

    def test_05_reset(self):
        FakeModelHandler.scripts["e-r"] = lambda d: say("记住了：端口 9090")
        sid = self.new_session()
        self._run(sid, "端口是 9090", "e-r")
        FakeModelHandler.scripts["e-snap"] = lambda d: say("标题：端口\n## 关键信息\n端口 9090")
        code, res = self.request("POST", f"/v1/sessions/{sid}/reset",
                                 {"model": "e-snap", "provider": {"base_url": self.model_base, "api_key": FAKE_KEY}})
        self.assertEqual(code, 200, res)
        FakeModelHandler.scripts["e-after"] = lambda d: say("重置后")
        self._run(sid, "继续", "e-after")
        req = [r for r in FakeModelHandler.requests if r.get("model") == "e-after"][-1]
        users = [m for m in req["messages"] if m["role"] == "user"]
        self.assertNotIn("端口是 9090", json.dumps(users, ensure_ascii=False), "重置后旧对话不再进上下文")

    def test_06_reconnect_after_background(self):
        FakeModelHandler.scripts["e-bg"] = lambda d: {"_chunks": ["一", "二", "三"], "_delay": 0.05}
        sid = self.new_session()
        res, final = self._run(sid, "后台跑", "e-bg")
        evs = final["events"]
        ids = [e["id"] for e in evs]
        self.assertEqual(ids, sorted(set(ids)), "事件编号唯一递增")
        # 手机切后台前看到了一半，回来从断点续拉：不重复、不缺
        mid = ids[len(ids) // 2]
        rest = self._events(res["task_id"], after=mid)
        self.assertEqual([e["id"] for e in rest], [i for i in ids if i > mid])
        # 通知流同样能从断点续上
        n = self.request("GET", "/v1/notifications?after=0")[1]
        self.assertIn("last_id", n)
        again = self.request("GET", f"/v1/notifications?after={n['last_id']}")[1]
        self.assertEqual(again.get("items", []), [])

    def test_07_duplicate_submit_and_events(self):
        FakeModelHandler.scripts["e-dup"] = lambda d: say("只回一次")
        sid = self.new_session()
        code1, a = self.submit(sid, "hi", "e-dup", client_nonce="e2e-nonce-1")
        code2, b = self.submit(sid, "hi", "e-dup", client_nonce="e2e-nonce-1")      # 网络重试
        self.assertEqual(a["task_id"], b["task_id"])
        self.assertTrue(b.get("idempotent_replayed"))
        self.wait_status(a["task_id"], {"completed"})
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        self.assertEqual([m["role"] for m in msgs].count("user"), 1)
        self.assertEqual([m["role"] for m in msgs].count("assistant"), 1)
        self.assertEqual(len([r for r in FakeModelHandler.requests if r.get("model") == "e-dup"]), 1)

    def test_08_server_restart_mid_task(self):
        srv = self.srv
        sid = self.new_session()
        conn = srv.get_db_connection()
        now = time.time()
        conn.execute("INSERT INTO tasks (task_id, session_id, status, model, created_at) VALUES ('task_e2e_mid', ?, 'running', 'e-x', ?)", (sid, now))
        conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', '做到一半', ?)", (sid, now))
        conn.commit()
        conn.close()
        srv.init_db()                       # 模拟服务重启：任务线程没了
        st = self.request("GET", "/v1/tasks/task_e2e_mid")[1]
        self.assertEqual(st["status"], "interrupted", "重启后不能一直显示运行中")
        # 状态里能看出出错，用户接着发消息照常能用
        FakeModelHandler.scripts["e-resume"] = lambda d: say("接着做")
        self._run(sid, "继续", "e-resume", scenario="重启后继续")
        self.assertEqual(self._last_reply(sid), "接着做")

    def test_09_multi_bot_routing(self):
        self.request("PUT", "/v1/bots/e-boss", {"name": "总管", "instructions": "分派", "is_primary": True, "model": "e-boss", "credential": "e2e"})
        self.request("PUT", "/v1/bots/e-coder", {"name": "码农", "instructions": "写代码", "model": "e-coder", "credential": "e2e"})

        def boss(d):
            if not any(m.get("role") == "tool" for m in d["messages"]):
                return tool_call("r1", "delegate_task", {"bot_id": "e-coder", "task": "写脚本", "wait": False})
            return say("已交给码农")
        FakeModelHandler.scripts["e-boss"] = boss
        FakeModelHandler.scripts["e-coder"] = lambda d: say("脚本写好了")
        code, res = self.request("POST", "/v1/handoff", {"goal": "写个脚本", "progress": "还没开始"})
        self.assertEqual(code, 200, res)
        self.assertEqual(res["bot_id"], "e-boss")
        self.wait_status(res["task_id"], {"completed"}, timeout=30)
        evs = self._events(res["task_id"])
        self.assertTrue(any(e["type"] == "delegation_started" and e["payload"]["to_bot"] == "e-coder" for e in evs))
        self.wait_until(lambda: [r for r in FakeModelHandler.requests if r.get("model") == "e-coder"], timeout=20,
                        message="码农没收到任务")
        bots = {b["bot_id"]: b for b in self.request("GET", "/v1/bots")[1]["bots"]}
        self.assertIn("status", bots["e-boss"])

    def test_10_vault_fill(self):
        import test_phase22_vault as v
        code, item = self.request("POST", "/v1/vault", {"kind": "login", "title": "E2E", "url": "https://login.example.com/",
                                                       "username": "fake.e2e@example.com", "password": FAKE_PW, "allow_bots": True})
        self.assertEqual(code, 201, item)
        iid = item["item"]["id"]
        browser = v.FakeBrowser()
        old = self.srv.cloud_browser.execute_browser_action
        self.srv.cloud_browser.execute_browser_action = browser
        try:
            def script(d):
                if not tool_turns(d):
                    return tool_call("v1", "vault_fill", {"id": iid})
                return say("填好了")
            FakeModelHandler.scripts["e-vault"] = script
            sid = self.new_session()
            self._run(sid, "帮我登录", "e-vault")
        finally:
            self.srv.cloud_browser.execute_browser_action = old
        fills = [c for c in browser.calls if c.get("action") == "__vault_fill__"]
        self.assertEqual(fills[0]["fields"]["password"], FAKE_PW)
        traffic = json.dumps(FakeModelHandler.requests, ensure_ascii=False) + json.dumps(self.request("GET", f"/v1/sessions/{sid}")[1], ensure_ascii=False)
        self.assertNotIn(FAKE_PW, traffic, "密码不进模型请求和对话记录")

    def test_11_proxy_import(self):
        link = (f"vless://{FAKE_UUID}@hk.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality"
                f"&sni=www.example.com&fp=chrome&pbk={FAKE_PBK}&sid=0123abcd&type=tcp#E2E-HK")
        code, body = self.request("POST", "/v1/proxy/import", {"text": link})
        self.assertEqual(code, 200, body)
        self.assertEqual(len(body["added"]), 1)
        dump = json.dumps(self.request("GET", "/v1/proxy")[1])
        self.assertNotIn(FAKE_UUID, dump)
        self.assertNotIn(FAKE_PBK, dump)
        self.assertEqual(self.request("POST", "/v1/proxy/import", {"text": link})[1]["added"], [], "重复导入不重复保存")
        for n in self.request("GET", "/v1/proxy")[1].get("nodes", []):
            self.request("DELETE", f"/v1/proxy/nodes/{n['id']}")

    def test_12_bot_rename_is_cheap_and_partial(self):
        long_instr = "很长的指令" * 400
        self.request("PUT", "/v1/bots/e-edit", {"name": "旧名", "instructions": long_instr, "description": "简介", "model": "e-m", "credential": "e2e"})
        times = []
        for i in range(5):
            t0 = time.time()
            code, bot = self.request("PUT", "/v1/bots/e-edit", {"name": f"新名{i}"})      # App 只发变了的字段
            times.append((time.time() - t0) * 1000)
            self.assertEqual(code, 200, bot)
        self.assertEqual(bot["name"], "新名4")
        self.assertEqual((bot["instructions"], bot["description"], bot["model"]), (long_instr, "简介", "e-m"), "没带的字段保持不变")
        times.sort()
        LATENCY.append({"scenario": "Bot 改名保存（服务端 PUT）", "first_text_ms": None, "ttft_ms": None,
                        "total_ms": round(times[len(times) // 2], 1), "client_total_ms": round(times[-1], 1), "source": "mock"})
        self.assertLess(times[len(times) // 2], 300, "改名保存应很快")


if __name__ == "__main__":
    unittest.main()
