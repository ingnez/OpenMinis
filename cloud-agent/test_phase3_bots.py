#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 3：多 Bot（人格升级为 Bot：简介、模型、技能白名单、主 Bot 分派、@提及、导出导入）。"""

import json
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


class BotTests(CloudServerTestCase):
    def test_01_persona_is_bot_and_validation(self):
        self.request("PUT", "/v1/personas/old", {"name": "旧人格", "instructions": "旧指令"})
        bots = self.request("GET", "/v1/bots")[1]["bots"]
        self.assertEqual([b["bot_id"] for b in bots], ["old"])
        self.assertEqual(bots[0]["plugins"], [])
        self.assertIsNone(bots[0]["skills"])
        self.assertEqual(self.request("PUT", "/v1/bots/x", {"name": "x", "instructions": "y", "model": "m"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/bots/x", {"name": "x", "instructions": "y", "credential": "nope", "model": "m"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/bots/x", {"name": "x", "instructions": "y", "skills": ["bad name"]})[0], 400)
        status, b = self.request("PUT", "/v1/bots/old", {"description": "老朋友"})
        self.assertEqual((status, b["description"], b["name"]), (200, "老朋友", "旧人格"))
        self.assertEqual(self.request("DELETE", "/v1/bots/old")[0], 200)
        self.assertEqual(self.request("GET", "/v1/bots/old")[0], 404)

    def test_02_bot_model_override_and_skills_allowlist(self):
        self.request("PUT", "/v1/credentials/botkey", {"api_key": "sk-bot-own-key-000000000000", "base_url": self.model_base})
        self.request("POST", "/v1/skills/sync", {"skills": [
            {"name": "alpha", "content": "---\ndescription: 技能A\n---\nA"},
            {"name": "beta", "content": "---\ndescription: 技能B\n---\nB"}]})
        self.request("PUT", "/v1/bots/coder", {"name": "代码", "instructions": "写代码", "model": "m-bot-own",
                                              "credential": "botkey", "skills": ["alpha"]})
        FakeModelHandler.scripts["m-bot-own"] = lambda d: (tool_call("k1", "skill_load", {"name": "beta"})
                                                           if d["messages"][-1]["role"] != "tool" else {"role": "assistant", "content": "ok"})
        sid = self.request("POST", "/v1/sessions", {"title": "c", "persona_id": "coder"})[1]["session_id"]
        t = self.submit(sid, "hi", "m-client-choice")[1]
        self.wait_status(t["task_id"], ("completed",))
        req = FakeModelHandler.requests[-1]
        self.assertEqual(req["model"], "m-bot-own")
        system = req["messages"][0]["content"]
        self.assertIn("alpha", system)
        self.assertNotIn("技能B", system)
        self.assertIn("技能不存在", tool_turns(req)[-1]["content"])
        self.assertEqual([s["session_id"] for s in self.request("GET", "/v1/sessions?bot=coder")[1]["sessions"]], [sid])

    def test_03_primary_routes_and_mentions(self):
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True})
        self.request("PUT", "/v1/bots/law", {"name": "法务", "instructions": "你是法务", "description": "合同审查"})
        self.request("PUT", "/v1/bots/doc", {"name": "医生", "instructions": "你是医生"})
        self.assertEqual(self.request("GET", "/v1/bots")[1]["primary"], "boss")
        # 设置新的主 Bot 会取消旧的
        self.request("PUT", "/v1/bots/doc", {"is_primary": True})
        self.assertEqual(self.request("GET", "/v1/bots")[1]["primary"], "doc")
        self.request("PUT", "/v1/bots/boss", {"is_primary": True})
        FakeModelHandler.scripts["m-boss"] = lambda d: {"role": "assistant", "content": "ok"}
        sid = self.request("POST", "/v1/sessions", {"title": "b", "persona_id": "boss"})[1]["session_id"]
        t = self.submit(sid, "请 @法务 看看这份合同，也问问 @doc", "m-boss")[1]
        self.wait_status(t["task_id"], ("completed",))
        system = FakeModelHandler.requests[-1]["messages"][0]["content"]
        self.assertIn("[主 Bot]", system)
        self.assertIn("law（法务：合同审查）", system)
        self.assertIn("[@提及] 用户在消息中 @ 了：law、doc", system)

    def test_04_export_import(self):
        self.request("PUT", "/v1/credentials/imp", {"api_key": "sk-import-key-0000000000000", "base_url": self.model_base})
        self.request("PUT", "/v1/bots/news", {"name": "简报", "emoji": "📰", "instructions": "做简报", "model": "m", "credential": "imp"})
        self.request("POST", "/v1/routines", {"name": "早报", "prompt": "p", "model": "m", "credential": "imp", "persona_id": "news",
                                             "schedule": {"kind": "cron", "expr": "0 8 * * *"}})
        FakeModelHandler.scripts["m-news"] = lambda d: (tool_call("w", "memory_write", {"content": "用户偏好科技新闻"})
                                                        if d["messages"][-1]["role"] != "tool" else {"role": "assistant", "content": "ok"})
        self.request("PUT", "/v1/bots/news", {"model": None, "credential": None})
        sid = self.request("POST", "/v1/sessions", {"title": "n", "persona_id": "news"})[1]["session_id"]
        self.wait_status(self.submit(sid, "记住", "m-news")[1]["task_id"], ("completed",))
        status, bundle = self.request("GET", "/v1/bots/news/export")
        self.assertEqual(status, 200)
        self.assertEqual(bundle["format"], "openminis-bot/1")
        self.assertNotIn("credential", bundle["bot"])
        self.assertNotIn("sk-import", json.dumps(bundle))
        self.assertEqual([r["name"] for r in bundle["routines"]], ["早报"])
        self.assertEqual([m["content"] for m in bundle["memory"]], ["用户偏好科技新闻"])
        # 无凭据导入：例行任务跳过
        status, res = self.request("POST", "/v1/bots/import", {"bundle": bundle})
        self.assertEqual((status, res["bot"]["bot_id"], res["memory_imported"]), (201, "news-2", 1))
        self.assertEqual(res["routines_skipped"], ["早报"])
        # 带凭据导入：例行任务创建但默认停用
        res = self.request("POST", "/v1/bots/import", {"bundle": bundle, "bot_id": "news-copy", "credential": "imp", "model": "m"})[1]
        self.assertEqual(len(res["routines_created"]), 1)
        rt = self.request("GET", "/v1/routines?bot=news-copy")[1]["routines"]
        self.assertEqual((len(rt), rt[0]["enabled"]), (1, False))
        self.assertEqual(self.request("POST", "/v1/bots/import", {"bundle": {"format": "x"}})[0], 400)


if __name__ == "__main__":
    unittest.main()
