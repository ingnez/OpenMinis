#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 47：首页「正在思考 / 正在用工具 / 正在回复 / 正在委派」来自真实的任务实时状态。"""

import json
import time
import unittest

import cloud_activity as act
from test_phase1_support import CloudServerTestCase


class DescribeTests(unittest.TestCase):
    def test_phases(self):
        self.assertEqual(act.describe(None), {"phase": "thinking"})
        self.assertEqual(act.describe({"text": "", "reasoning": "嗯"}), {"phase": "thinking"})
        self.assertEqual(act.describe({"text": "x", "tool": {"name": "shell_execute"}}), {"phase": "tool", "tool": "shell_execute"})
        self.assertEqual(act.describe({"text": "第一行\n\n  第二  行 "}), {"phase": "replying", "preview": "第二 行"})
        self.assertEqual(act.describe({"text": "x"}, "写手"), {"phase": "delegating", "peer": "写手"})

    def test_preview_is_short_and_redacted(self):
        d = act.describe({"text": "a" * 100}, redact=lambda s: s)
        self.assertEqual(len(d["preview"]), act.PREVIEW_MAX)
        self.assertTrue(d["preview"].startswith("…"))
        d = act.describe({"text": "密码是 FAKE-SECRET-123"}, redact=lambda s: s.replace("FAKE-SECRET-123", "[已隐藏]"))
        self.assertEqual(d["preview"], "密码是 [已隐藏]")

    def test_pending_delegation(self):
        self.assertIsNone(act.pending_delegation([]))
        evs = [("delegation_started", {"delegation_id": "d1", "to_name": "写手"})]
        self.assertEqual(act.pending_delegation(evs), "写手")
        evs.append(("delegation_finished", {"delegation_id": "d1"}))
        self.assertIsNone(act.pending_delegation(evs))


class BotActivityTests(CloudServerTestCase):
    def test_01_activity_follows_live_state(self):
        self.request("PUT", "/v1/bots/helper", {"name": "助手", "instructions": "x"})
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "helper"})[1]["session_id"]
        bot = lambda: self.request("GET", "/v1/bots/helper")[1]
        self.assertIsNone(bot()["activity"])
        tid = "task_fakeactivity01"
        conn = self.srv.get_db_connection()
        conn.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, NULL, 'running', 'm', ?)",
                     (tid, sid, time.time()))
        conn.commit(); conn.close()
        try:
            self.assertEqual(bot()["activity"], {"phase": "thinking", "task_id": tid})
            self.srv.live_update(tid, "", tool={"id": "c1", "name": "web_search", "output": ""})
            self.assertEqual(bot()["activity"]["tool"], "web_search")
            self.srv.live_update(tid, "好的，我查到了\n明天北京晴", tool=None)
            a = bot()["activity"]
            self.assertEqual((a["phase"], a["preview"]), ("replying", "明天北京晴"))
            self.srv.log_event(tid, "delegation_started", {"delegation_id": "d1", "to_bot": "writer", "to_name": "写手"})
            self.assertEqual(bot()["activity"]["peer"], "写手")
            listed = [b for b in self.request("GET", "/v1/bots")[1]["bots"] if b.get("persona_id") == "helper"]
            self.assertEqual([b["activity"]["phase"] for b in listed], ["delegating"])
        finally:
            self.srv.live_clear(tid)
            conn = self.srv.get_db_connection()
            conn.execute("UPDATE tasks SET status = 'completed' WHERE task_id = ?", (tid,))
            conn.commit(); conn.close()
        self.assertIsNone(bot()["activity"])


if __name__ == "__main__":
    unittest.main()
