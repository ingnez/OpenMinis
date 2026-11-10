#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 29：首页 Bot 状态——由真实状态推出：需要你 > 出错 > 工作中 > 未读；例行任务、静音是附加标记。"""

import json
import time
import unittest

import cloud_botstatus
from test_phase1_support import CloudServerTestCase, FakeModelHandler

FAKE_KEY = "sk-fake-botstatus-00000000000"


class DeriveTests(unittest.TestCase):
    def test_priority(self):
        d = cloud_botstatus.derive
        self.assertEqual(d({})["state"], "idle")
        self.assertEqual(d({"unread_count": 3})["state"], "unread")
        self.assertEqual(d({"unread_count": 3})["unread"], 3)
        self.assertEqual(d({"unread_count": 3, "running_tasks": 1})["state"], "working")
        self.assertEqual(d({"running_workers": 1})["state"], "working")
        self.assertEqual(d({"running_tasks": 1, "last_task_status": "failed"})["state"], "error")
        self.assertEqual(d({"last_task_status": "failed", "waiting_approvals": 1})["state"], "needs_you")
        self.assertEqual(d({"pending_cards": 1, "running_tasks": 2, "unread_count": 5})["state"], "needs_you")
        self.assertEqual(d({"last_task_status": "completed"})["state"], "idle")
        self.assertEqual(d({"prefs": {"unread": True}})["unread"], 1, "手动标为未读")
        self.assertEqual(d({"routines_enabled": 2, "notify": False})["flags"], ["routine_scheduled", "muted"])
        self.assertEqual(d({"routines_enabled": 2, "routine_running": 1})["flags"], ["routine_running"])


class BotStatusApiTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/credentials/bs", {"api_key": FAKE_KEY, "base_url": self.model_base})
        self.bid = "st-" + self._testMethodName[5:12].replace("_", "-")
        self.request("PUT", f"/v1/bots/{self.bid}", {"name": "状态", "instructions": "测试", "model": None, "credential": None})

    def _bot(self):
        return next(b for b in self.request("GET", "/v1/bots")[1]["bots"] if b["persona_id"] == self.bid)

    def test_unread_cleared_by_seen_and_failed_task_is_error(self):
        FakeModelHandler.scripts["m-bs"] = lambda d: {"role": "assistant", "content": "回答"}
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": self.bid})[1]["session_id"]
        code, res = self.submit(sid, "你好", "m-bs")
        self.wait_status(res["task_id"], {"completed"})
        b = self._bot()
        self.assertEqual(b["status"]["state"], "unread")
        self.assertEqual(b["unread_count"], 1)
        self.request("PUT", f"/v1/bots/{self.bid}/prefs", {"seen_at": time.time() + 1})
        self.assertEqual(self._bot()["status"]["state"], "idle", "打开对话后清掉未读")
        FakeModelHandler.scripts["m-bs-bad"] = lambda d: {"_status": 500, "error": {"message": "boom"}}
        code, res = self.submit(sid, "再来", "m-bs-bad")
        self.wait_status(res["task_id"], {"failed"}, timeout=30)
        self.assertEqual(self._bot()["status"]["state"], "error")
        code, res = self.submit(sid, "好了吗", "m-bs")
        self.wait_status(res["task_id"], {"completed"})
        self.assertNotEqual(self._bot()["status"]["state"], "error", "后来成功了就不再显示出错")

    def test_pending_choice_card_needs_you(self):
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": self.bid})[1]["session_id"]
        conn = self.srv.get_db_connection()
        try:
            conn.execute("INSERT INTO messages (session_id, role, content, timestamp, meta) VALUES (?, 'assistant', '选一个', ?, ?)",
                         (sid, time.time(), json.dumps({"choice": {"question": "选哪个", "options": ["A", "B"]}})))
            conn.commit()
        finally:
            conn.close()
        b = self._bot()
        self.assertEqual(b["pending_cards"], 1)
        self.assertEqual(b["status"]["state"], "needs_you")


if __name__ == "__main__":
    unittest.main()
