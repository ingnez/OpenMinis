#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 31：Bot 之间的对话线程——按对保存（发送方 / 接收方 / 时间 / 优先级）、首页预览文字、用户对话里的折叠行、搜索。"""

import sqlite3
import time
import unittest

import cloud_botthreads as bt
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call

FAKE_KEY = "sk-fake-threads-000000000000"


class UnitTests(unittest.TestCase):
    def test_pair_preview_collapsed(self):
        self.assertEqual(bt.pair_key("b", "a"), bt.pair_key("a", "b"))
        self.assertEqual(bt.pair_key("", "x"), "_main|x")
        names = {"boss": "总管", "maker": "制造厂"}
        msg = {"sender": "boss", "recipient": "maker", "text": "把  图\n做好" + "长" * 200}
        self.assertTrue(bt.preview_text("boss", msg, names).startswith("➤ 已发消息给 制造厂：把 图 做好"))
        self.assertTrue(bt.preview_text("boss", msg, names).endswith("…"))
        self.assertTrue(bt.preview_text("maker", msg, names).startswith("← 来自 总管：把 图 做好"))
        self.assertEqual(bt.collapsed_label(2, "制造厂"), "与 制造厂 往来 2 条")
        self.assertEqual(bt.collapsed_label(1, "制造厂", True), "发消息给 ◯制造厂")
        self.assertEqual(bt.collapsed_label(1, "制造厂", False), "收到 ◯制造厂 的消息")

    def test_record_idempotent_and_backfill(self):
        conn = sqlite3.connect(":memory:")
        import cloud_delegation
        conn.execute(cloud_delegation.SCHEMA)
        conn.execute("INSERT INTO bot_delegations (delegation_id, kind, from_bot, to_bot, content, priority, status, result, created_at, finished_at) "
                     "VALUES ('d1', 'task', 'a', 'b', '做事', 'high', 'completed', '做完了', 1.0, 2.0)")
        bt.ensure_schema(conn)
        bt.ensure_schema(conn)                       # 再跑一次不重复
        msgs = bt.thread(conn, "b", "a")["messages"]
        self.assertEqual([(m["sender"], m["recipient"], m["kind"], m["priority"]) for m in msgs],
                         [("a", "b", "task", "high"), ("b", "a", "result", "high")])
        self.assertEqual(bt.record(conn, "a", "b", "做事", "task", "d1"), msgs[0]["id"])


class ThreadApiTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/credentials/th", {"api_key": FAKE_KEY, "base_url": self.model_base})
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "分派", "is_primary": True, "model": "t-boss", "credential": "th"})
        self.request("PUT", "/v1/bots/maker", {"name": "制造厂", "instructions": "做东西", "model": "t-maker", "credential": "th"})

    def test_01_delegation_persists_thread_preview_and_collapsed_row(self):
        def boss(d):
            if not any(m.get("role") == "tool" for m in d["messages"]):
                return tool_call("b1", "delegate_task", {"bot_id": "maker", "task": "做一张海报 @制造厂", "priority": "high", "wait": True,
                                                         "wait_seconds": 20})
            return {"role": "assistant", "content": "海报好了"}
        FakeModelHandler.scripts["t-boss"] = boss
        FakeModelHandler.scripts["t-maker"] = lambda d: {"role": "assistant", "content": "海报做好了，放在 poster.png"}
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        tid = self.submit(sid, "做张海报", "t-boss")[1]["task_id"]
        self.wait_status(tid, {"completed"}, timeout=30)
        # 线程：两条，按对保存，带发送方 / 接收方 / 优先级 / 跳转用的任务号
        th = self.wait_until(lambda: (lambda r: r if len(r["messages"]) == 2 else None)(self.request("GET", "/v1/bot-threads/maker/boss")[1]),
                             message="线程里应有发出和回复两条")
        m1, m2 = th["messages"]
        self.assertEqual((m1["sender"], m1["recipient"], m1["kind"], m1["priority"]), ("boss", "maker", "task", "high"))
        self.assertIn("做一张海报", m1["text"])
        self.assertEqual((m2["sender"], m2["recipient"], m2["kind"], m2["status"]), ("maker", "boss", "result", "completed"))
        self.assertTrue(m1["task_id"] and m1["session_id"])
        self.assertLessEqual(m1["ts"], m2["ts"])
        self.assertEqual(th["names"]["maker"], "制造厂")
        self.assertEqual(th["working"], [])
        # 续拉：after=最后一条 → 没有新消息
        self.assertEqual(self.request("GET", f"/v1/bot-threads/boss/maker?after={th['last_id']}")[1]["messages"], [])
        # 每个 Bot 的线程列表
        lst = self.request("GET", "/v1/bot-threads?bot_id=maker")[1]["threads"]
        self.assertEqual((lst[0]["peer"], lst[0]["count"], lst[0]["high_priority"]), ("boss", 2, 2))
        self.assertTrue(lst[0]["preview"].startswith("➤ 已发消息给 总管：海报做好了"))
        # 用户对话里的折叠行
        rows = self.request("GET", f"/v1/sessions/{sid}/bot-threads")[1]["threads"]
        self.assertEqual((rows[0]["peer"], rows[0]["count"], rows[0]["label"]), ("maker", 2, "与 制造厂 往来 2 条"))
        # 首页预览：制造厂最近的动静是回复总管
        bots = {b["bot_id"]: b for b in self.request("GET", "/v1/bots")[1]["bots"]}
        self.assertIn("thread_preview", bots["maker"])
        self.assertTrue(bots["maker"]["thread_preview"]["text"].startswith("➤ 已发消息给 总管："))
        self.assertTrue(bots["maker"]["thread_preview"]["outgoing"])
        # 全局搜索包含线程
        hits = self.request("GET", "/v1/search?q=poster.png")[1]["results"]
        self.assertTrue(any(h["type"] == "bot_thread" and h["bots"] == ["boss", "maker"] for h in hits))

    def test_02_message_shows_working_then_long_poll_returns(self):
        FakeModelHandler.scripts["t-maker"] = lambda d: {"_chunks": ["收", "到"], "_delay": 0.6}
        def boss(d):
            if not any(m.get("role") == "tool" for m in d["messages"]):
                return tool_call("s1", "send_to_bot", {"bot_id": "maker", "message": "明天开会"})
            return {"role": "assistant", "content": "通知了"}
        FakeModelHandler.scripts["t-boss"] = boss
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        self.submit(sid, "通知制造厂", "t-boss")
        th = self.wait_until(lambda: (lambda r: r if r["messages"] and r["working"] else None)(self.request("GET", "/v1/bot-threads/boss/maker?after=0")[1]),
                             message="对方处理时应显示正在工作")
        self.assertEqual(th["working"], ["maker"])
        t0 = time.time()
        done = self.request("GET", f"/v1/bot-threads/boss/maker?after={th['last_id']}&wait=10&working=maker")[1]
        self.assertLess(time.time() - t0, 9, "状态变了应立刻返回")
        self.assertEqual(done["working"], [])
        # 只是通知：没有回复消息
        self.assertEqual([m["kind"] for m in self.request("GET", "/v1/bot-threads/boss/maker")[1]["messages"]][-1], "message")


if __name__ == "__main__":
    unittest.main()
