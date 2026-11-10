#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 28：本地模式交接给 Bot——没指定 Bot 交给主 Bot 分派；@ 了 Bot 直接交给它；带上下文摘要和文件。"""

import base64
import os
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call

FAKE_KEY = "sk-fake-handoff-0000000000000"


def first_user(d):
    return next(m["content"] for m in d["messages"] if m.get("role") == "user")


class HandoffTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/credentials/ho", {"api_key": FAKE_KEY, "base_url": self.model_base})
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True,
                                              "model": "m-boss", "credential": "ho"})
        self.request("PUT", "/v1/bots/coder", {"name": "码农", "instructions": "写代码", "model": "m-coder", "credential": "ho"})

    def _handoff(self, **body):
        body.setdefault("goal", "把报表脚本跑完并生成图表")
        body.setdefault("progress", "已经清洗好数据 FAKE-PROGRESS")
        body.setdefault("remaining", "画图、写结论")
        return self.request("POST", "/v1/handoff", body)

    def test_01_without_target_goes_to_primary_which_delegates(self):
        def boss(d):
            if not any(m.get("role") == "tool" for m in d["messages"]):
                return tool_call("d1", "delegate_task", {"bot_id": "coder", "task": "接着画图", "wait": False})
            return {"role": "assistant", "content": "已交给码农"}
        FakeModelHandler.scripts["m-boss"] = boss
        FakeModelHandler.scripts["m-coder"] = lambda d: {"role": "assistant", "content": "画好了"}
        code, res = self._handoff()
        self.assertEqual(code, 200, res)
        self.assertEqual(res["bot_id"], "boss")
        self.assertTrue(res["routed"])
        self.wait_status(res["task_id"], {"completed"}, timeout=30)
        boss_req = [r for r in FakeModelHandler.requests if r.get("model") == "m-boss"][0]
        text = first_user(boss_req)
        self.assertIn("FAKE-PROGRESS", text)
        self.assertIn("主 Bot", text)
        events = self.request("GET", f"/v1/tasks/{res['task_id']}/events?after=0")[1]["events"]
        self.assertTrue(any(e["type"] == "delegation_started" and e["payload"]["to_bot"] == "coder" for e in events))

    def test_02_named_target_gets_it_directly_with_files(self):
        FakeModelHandler.scripts["m-coder"] = lambda d: {"role": "assistant", "content": "收到"}
        before = len([r for r in FakeModelHandler.requests if r.get("model") == "m-boss"])
        data = b"col1,col2\n1,2\n"
        code, res = self._handoff(target_bot="coder", summary="本地对话摘要：用户要月度报表",
                                  files=[{"filename": "data.csv", "data_base64": base64.b64encode(data).decode()}])
        self.assertEqual(code, 200, res)
        self.assertEqual(res["bot_id"], "coder")
        self.assertFalse(res["routed"])
        self.wait_status(res["task_id"], {"completed"}, timeout=30)
        self.assertEqual(len([r for r in FakeModelHandler.requests if r.get("model") == "m-boss"]), before, "主 Bot 不参与")
        text = first_user([r for r in FakeModelHandler.requests if r.get("model") == "m-coder"][-1])
        self.assertIn("本地对话摘要", text)
        self.assertIn(res["files"][0], text)
        target = os.path.join(self.srv.get_session_workspace(res["session_id"]), res["files"][0])
        with open(target, "rb") as f:
            self.assertEqual(f.read(), data)

    def test_03_secrets_redacted_and_validation(self):
        code, res = self.request("POST", "/v1/handoff", {"progress": "x"})
        self.assertEqual(code, 400)
        code, res = self.request("POST", "/v1/handoff", {"goal": "g", "target_bot": "nobody"})
        self.assertEqual(code, 400)
        FakeModelHandler.scripts["m-coder"] = lambda d: {"role": "assistant", "content": "ok"}
        code, res = self._handoff(target_bot="coder", outputs="token sk-fakeSECRET1234567890abcdefgh")
        self.assertEqual(code, 200, res)
        self.wait_status(res["task_id"], {"completed"}, timeout=30)
        text = first_user([r for r in FakeModelHandler.requests if r.get("model") == "m-coder"][-1])
        self.assertNotIn("sk-fakeSECRET1234567890abcdefgh", text)


if __name__ == "__main__":
    unittest.main()
