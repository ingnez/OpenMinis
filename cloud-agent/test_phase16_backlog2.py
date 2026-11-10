#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第二批：主动消息（[SKIP] 不打扰）等。"""

import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler


class ProactiveTests(CloudServerTestCase):
    def test_01_quiet_result_does_not_notify(self):
        sent = []
        orig = self.srv.user_notify
        self.srv.user_notify = lambda *a, **k: sent.append(a)
        try:
            r = {"name": "主动消息", "notify": True, "persona_id": None}
            self.srv.on_routine_finished(r, {"status": "completed", "result": "[SKIP] 今天没什么要说的"})
            self.srv.on_routine_finished(r, {"status": "completed", "result": "  [静默]"})
            self.assertEqual(sent, [])
            self.srv.on_routine_finished(r, {"status": "completed", "result": "明天 8 点有会，记得带资料"})
            self.assertEqual(len(sent), 1)
            # 失败仍然通知
            self.srv.on_routine_finished(r, {"status": "failed", "error": "[SKIP]"})
            self.assertEqual(len(sent), 2)
        finally:
            self.srv.user_notify = orig



class AutoModelTests(CloudServerTestCase):
    def test_01_simple_question_uses_fast_model_and_falls_back(self):
        import cloud_efficiency as eff
        self.assertTrue(eff.is_simple_request("你好"))
        self.assertTrue(eff.is_simple_request("今天星期几？"))
        self.assertFalse(eff.is_simple_request("帮我查一下明天的航班"))
        self.assertFalse(eff.is_simple_request("写一个 Python 脚本"))
        self.assertFalse(eff.is_simple_request("看看 https://example.com"))
        self.assertFalse(eff.is_simple_request([{"type": "text", "text": "hi"}]))
        self.assertFalse(eff.is_simple_request("x" * 200))

        FakeModelHandler.scripts["m-fast"] = lambda d: {"role": "assistant", "content": "快速回答"}
        FakeModelHandler.scripts["m-main"] = lambda d: {"role": "assistant", "content": "主模型回答"}
        self.assertEqual(self.request("PUT", "/v1/resources", {"auto_model": True, "fast_model": "m-fast"})[0], 200)
        try:
            sid = self.new_session()
            res = self.wait_status(self.submit(sid, "你好", "m-main")[1]["task_id"], ("completed", "failed"))
            self.assertEqual(res["status"], "completed")
            texts = [m.get("content") for m in self.request("GET", f"/v1/sessions/{sid}")[1]["messages"] if m.get("role") == "assistant"]
            self.assertIn("快速回答", texts)
            res = self.wait_status(self.submit(sid, "帮我写一份值班计划", "m-main")[1]["task_id"], ("completed", "failed"))
            texts = [m.get("content") for m in self.request("GET", f"/v1/sessions/{sid}")[1]["messages"] if m.get("role") == "assistant"]
            self.assertEqual(texts[-1], "主模型回答")
            # 快速模型出错：同一任务换回主模型
            FakeModelHandler.scripts["m-fast"] = lambda d: {"_status": 404}
            res = self.wait_status(self.submit(sid, "在吗", "m-main")[1]["task_id"], ("completed", "failed"))
            self.assertEqual(res["status"], "completed", res)
            texts = [m.get("content") for m in self.request("GET", f"/v1/sessions/{sid}")[1]["messages"] if m.get("role") == "assistant"]
            self.assertEqual(texts[-1], "主模型回答")
        finally:
            self.request("PUT", "/v1/resources", {"auto_model": False, "fast_model": ""})



class DutyModeTests(CloudServerTestCase):
    def test_01_duty_note_and_quiet_proactive(self):
        import time
        FakeModelHandler.scripts["m-duty"] = lambda d: {"role": "assistant", "content": "ok"}
        self.assertEqual(self.request("PUT", "/v1/resources", {"duty_until": "x"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/resources", {"duty_until": time.time() + 3600})[0], 200)
        try:
            sid = self.new_session()
            self.wait_status(self.submit(sid, "去甲肾上腺素泵速", "m-duty")[1]["task_id"], ("completed",))
            req = FakeModelHandler.requests[-1]
            self.assertIn("值班模式", req["messages"][-1]["content"])
            self.assertNotIn("值班模式", req["messages"][0]["content"])
            sent = []
            orig = self.srv.user_notify
            self.srv.user_notify = lambda *a, **k: sent.append(a)
            try:
                self.srv.on_routine_finished({"name": "主动消息 · 总管", "notify": True}, {"status": "completed", "result": "明天有考试"})
                self.assertEqual(sent, [])
                self.srv.on_routine_finished({"name": "每日简报", "notify": True}, {"status": "completed", "result": "x"})
                self.assertEqual(len(sent), 1)
            finally:
                self.srv.user_notify = orig
        finally:
            self.request("PUT", "/v1/resources", {"duty_until": 0})
        sid = self.new_session()
        self.wait_status(self.submit(sid, "你好", "m-duty")[1]["task_id"], ("completed",))
        self.assertNotIn("值班模式", FakeModelHandler.requests[-1]["messages"][-1]["content"])



class FeedTests(CloudServerTestCase):
    def test_01_feed_lists_recent_non_quiet_results(self):
        import time, uuid
        conn = self.srv.get_db_connection()
        try:
            now = time.time()
            for rid, name in (("rtn_feed00000001", "主动消息 · 总管"), ("rtn_feed00000002", "每日简报")):
                conn.execute("INSERT INTO routines (routine_id, name, prompt, schedule, credential, model, enabled, run_count, notify, created_at, updated_at) "
                             "VALUES (?, ?, 'p', '{}', 'c', 'm', 1, 0, 1, ?, ?)", (rid, name, now, now))
            rows = [("rtn_feed00000001", "明早 8 点交班，记得带记录", now - 60), ("rtn_feed00000001", "[SKIP]", now - 30),
                    ("rtn_feed00000002", "今日要闻三条", now - 10), ("rtn_feed00000002", "很久以前", now - 3 * 86400)]
            for rid, res, at in rows:
                conn.execute("INSERT INTO routine_runs (run_id, routine_id, task_id, session_id, trigger, status, result, error, started_at, finished_at) "
                             "VALUES (?, ?, NULL, 'sess_x', 'schedule', 'completed', ?, NULL, ?, ?)", ("run_" + uuid.uuid4().hex[:12], rid, res, at, at))
            conn.commit()
        finally:
            conn.close()
        items = self.request("GET", "/v1/feed")[1]["items"]
        self.assertEqual([i["text"] for i in items], ["今日要闻三条", "明早 8 点交班，记得带记录"])
        self.assertTrue(items[1]["proactive"])



class IncognitoTests(CloudServerTestCase):
    def test_01_incognito_session_hidden_no_memory_and_deletable(self):
        sid = self.request("POST", "/v1/sessions", {"title": "无痕", "incognito": True})[1]["session_id"]
        normal = self.request("POST", "/v1/sessions", {"title": "普通"})[1]["session_id"]
        listed = [x["session_id"] for x in self.request("GET", "/v1/sessions")[1]["sessions"]]
        self.assertIn(normal, listed)
        self.assertNotIn(sid, listed)
        res = self.srv.tool_memory_write("t_x", sid, {"content": "不该被记住", "category": "note"})
        self.assertFalse(res["saved"])
        self.assertEqual(self.request("DELETE", "/v1/sessions/" + normal)[0], 400)
        self.assertEqual(self.request("DELETE", "/v1/sessions/" + sid)[0], 200)
        self.assertEqual(self.request("GET", "/v1/sessions/" + sid)[0], 404)

    def test_02_stale_incognito_purged(self):
        import time
        sid = self.request("POST", "/v1/sessions", {"title": "旧", "incognito": True})[1]["session_id"]
        conn = self.srv.get_db_connection()
        try:
            self.assertEqual(self.srv.purge_stale_incognito(conn, time.time() + 2 * 86400), 1)
            conn.commit()
            self.assertIsNone(conn.execute("SELECT 1 FROM sessions WHERE session_id = ?", (sid,)).fetchone())
        finally:
            conn.close()



class AuditTests(CloudServerTestCase):
    def test_01_file_write_edit_undo(self):
        import os
        sid = self.request("POST", "/v1/sessions", {"title": "审计"})[1]["session_id"]
        self.assertEqual(self.srv.tool_file_write("t_a", sid, {"path": "notes/a.txt", "content": "v1"})["status"], "success")
        self.srv.tool_file_edit("t_a", sid, {"path": "notes/a.txt", "old_string": "v1", "new_string": "v2"})
        target, _ = self.srv.safe_path_resolve(sid, "notes/a.txt")
        items = self.request("GET", "/v1/audit")[1]["items"]
        edit, create = items[0], items[1]
        self.assertEqual(edit["tool"], "file_edit")
        self.assertTrue(edit["undoable"])
        self.assertEqual(self.request("POST", f"/v1/audit/{edit['id']}/undo", {})[0], 200)
        with open(target, encoding="utf-8") as f:
            self.assertEqual(f.read(), "v1")
        self.assertEqual(self.request("POST", f"/v1/audit/{edit['id']}/undo", {})[0], 400)
        self.assertEqual(self.request("POST", f"/v1/audit/{create['id']}/undo", {})[0], 200)
        self.assertFalse(os.path.exists(target))

    def test_02_memory_write_undo(self):
        sid = self.request("POST", "/v1/sessions", {"title": "审计记忆"})[1]["session_id"]
        res = self.srv.tool_memory_write("t_m", sid, {"content": "用户喜欢黑咖啡 审计测试", "category": "profile"})
        self.assertTrue(res["saved"])
        item = self.request("GET", "/v1/audit")[1]["items"][0]
        self.assertEqual(item["tool"], "memory_write")
        self.assertEqual(self.request("POST", f"/v1/audit/{item['id']}/undo", {})[0], 200)
        conn = self.srv.get_db_connection()
        try:
            self.assertIsNone(conn.execute("SELECT 1 FROM memory_entries WHERE id = ?", (res["id"],)).fetchone())
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main()
