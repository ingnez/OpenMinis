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


if __name__ == "__main__":
    unittest.main()
