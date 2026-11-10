#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 26：每一步的预览数据——tool_result 事件带文字末尾，浏览器 / 桌面步骤再带一张小 JPEG。"""

import base64
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call

FAKE_KEY = "sk-fake-steppreview-0000000000"
FAKE_JPEG = b"\xff\xd8\xff\xe0FAKE-JPEG-THUMB\xff\xd9"


class StepPreviewTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/credentials/sp", {"api_key": FAKE_KEY, "base_url": self.model_base})
        self.request("PUT", "/v1/bots/stepper", {"name": "步骤", "instructions": "测试", "model": None, "credential": None})
        self._orig_thumb = self.srv.step_thumbnail
        self._orig_browser = self.srv.tool_browser_action
        self.srv.step_thumbnail = lambda sid, fn: FAKE_JPEG
        self.srv.tool_browser_action = lambda tid, sid, args: {"status": "ok", "title": "示例页", "url": "https://example.com"}

    def tearDown(self):
        self.srv.step_thumbnail = self._orig_thumb
        self.srv.tool_browser_action = self._orig_browser

    def _results(self, model, script):
        FakeModelHandler.scripts[model] = script
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "stepper"})[1]["session_id"]
        code, res = self.submit(sid, "开始", model)
        self.assertIn(code, (200, 201, 202), res)
        self.wait_status(res["task_id"], {"completed"}, timeout=30)
        events = self.request("GET", f"/v1/tasks/{res['task_id']}/events?after=0")[1]["events"]
        return {e["payload"]["tool"]: e["payload"] for e in events if e["type"] == "tool_result"}

    def test_01_shell_step_carries_stdout_tail_without_thumb(self):
        def script(d):
            if not any(m.get("role") == "tool" for m in d["messages"]):
                return tool_call("s1", "shell_execute", {"command": "printf 'line1\\nline2\\nTAIL-OK'"})
            return {"role": "assistant", "content": "好了"}
        res = self._results("m-sp1", script)
        preview = res["shell_execute"]["preview"]
        self.assertIn("TAIL-OK", preview["text"])
        self.assertNotIn("thumb", preview)

    def test_02_browser_step_carries_small_jpeg(self):
        def script(d):
            if not any(m.get("role") == "tool" for m in d["messages"]):
                return tool_call("b1", "browser_action", {"action": "navigate", "url": "https://example.com"})
            return {"role": "assistant", "content": "看完了"}
        res = self._results("m-sp2", script)
        preview = res["browser_action"]["preview"]
        self.assertEqual(base64.b64decode(preview["thumb"]), FAKE_JPEG)
        self.assertEqual(preview["thumb_mime"], "image/jpeg")
        self.assertIn("example.com", preview["text"])

    def test_03_text_tail_is_bounded_and_oversized_thumb_dropped(self):
        srv = self.srv
        long = "x" * 5000 + "END"
        self.assertTrue(srv.step_text_tail("shell_execute", {"stdout": long}).endswith("END"))
        self.assertLessEqual(len(srv.step_text_tail("shell_execute", {"stdout": long})), srv.STEP_TEXT_TAIL)
        srv.step_thumbnail = lambda sid, fn: b"\xff" * (srv.STEP_THUMB_MAX + 1)
        self.assertNotIn("thumb", srv.step_preview("s", "desktop_action", {"status": "ok"}))
        self.assertNotIn("thumb", srv.step_preview("s", "browser_action", {"error": "坏了"}))


if __name__ == "__main__":
    unittest.main()
