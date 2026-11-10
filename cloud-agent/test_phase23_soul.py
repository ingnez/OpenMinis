#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 23：每个 Bot 的灵魂设定（风格 / 语气、回复语言、人格提示词、禁止事项）。"""

import unittest

import cloud_bots
import cloud_groups
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns

SOUL = {"style": "简短、幽默", "language": "English", "persona": "You are Captain Fake, a cheerful pirate.",
        "forbidden": "never mention pineapples"}


def system_of(req):
    return req["messages"][0]["content"]


class SoulTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True})
        self.request("PUT", "/v1/bots/pirate", {"name": "海盗", "instructions": "GENERIC-INSTRUCTIONS", "soul": SOUL})
        self.request("PUT", "/v1/bots/plain", {"name": "普通", "instructions": "你是普通助手", "soul": None})
        self.srv.ADMIN_BASE = f"http://127.0.0.1:{self.api_port}"

    def _chat(self, bot, model, sid=None, script=None, text="你好"):
        FakeModelHandler.scripts[model] = script or (lambda d: {"role": "assistant", "content": "ok"})
        sid = sid or self.request("POST", "/v1/sessions", {"title": "t", "persona_id": bot})[1]["session_id"]
        tid = self.submit(sid, text, model)[1]["task_id"]
        self.wait_status(tid, {"completed"}, timeout=30)
        return sid

    def test_01_stored_and_validated(self):
        bot = next(b for b in self.request("GET", "/v1/bots")[1]["bots"] if b["bot_id"] == "pirate")
        self.assertEqual(bot["soul"], SOUL)
        self.assertEqual(self.request("PUT", "/v1/bots/pirate", {"soul": {"mood": "x"}})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/bots/pirate", {"soul": {"language": "x" * 41}})[0], 400)

    def test_02_injected_for_that_bot_only_and_language_enforced(self):
        self._chat("pirate", "m-s1")
        sys_text = system_of(FakeModelHandler.requests[-1])
        self.assertTrue(sys_text.startswith("[灵魂设定：海盗]"))
        self.assertLess(sys_text.index("Captain Fake"), sys_text.index("GENERIC-INSTRUCTIONS"))
        self.assertIn("never mention pineapples", sys_text)
        self.assertIn("始终用「English」回复", sys_text)
        self.assertTrue(sys_text.rstrip().endswith("除非用户明确要求换语言。"))
        self._chat("plain", "m-s2")
        plain = system_of(FakeModelHandler.requests[-1])
        self.assertNotIn("灵魂设定", plain)
        self.assertNotIn("Captain Fake", plain)

    def test_03_survives_reset(self):
        sid = self._chat("pirate", "m-s3")
        self.assertEqual(self.request("POST", f"/v1/sessions/{sid}/reset", {})[0], 200)
        self._chat("pirate", "m-s3", sid=sid, text="接着聊")
        sys_text = system_of(FakeModelHandler.requests[-1])
        self.assertIn("/reset", sys_text)
        self.assertIn("Captain Fake", sys_text)
        self.assertIn("「English」", sys_text)

    def test_04_subtask_for_bot_carries_soul(self):
        def script(d):
            if "Captain Fake" in system_of(d):
                return {"role": "assistant", "content": "Arr"}
            if not tool_turns(d):
                return tool_call("c0", "subagent_task", {"task": "say hi", "persona": "pirate"})
            return {"role": "assistant", "content": "done"}
        self._chat("plain", "m-s4", script=script)
        sub = [r for r in FakeModelHandler.requests if "Captain Fake" in system_of(r)]
        self.assertTrue(sub, "子任务的系统提示里没有灵魂设定")
        self.assertIn("「English」", system_of(sub[-1]))

    def test_05_primary_edits_soul_with_undo(self):
        def script(d):
            if not tool_turns(d):
                return tool_call("c0", "update_bot", {"bot_id": "plain", "soul": {"language": "日本語", "style": "丁寧"}})
            return {"role": "assistant", "content": "改好了"}
        self._chat("boss", "m-s5", script=script, text="把普通 Bot 的灵魂设定改成说日语")
        bot = next(b for b in self.request("GET", "/v1/bots")[1]["bots"] if b["bot_id"] == "plain")
        self.assertEqual(bot["soul"], {"language": "日本語", "style": "丁寧"})
        upd = next(e for e in self.request("GET", "/v1/audit")[1]["items"] if e["tool"] == "update_bot")
        self.assertEqual(self.request("POST", f"/v1/audit/{upd['id']}/undo", {})[0], 200)
        bot = next(b for b in self.request("GET", "/v1/bots")[1]["bots"] if b["bot_id"] == "plain")
        self.assertIsNone(bot["soul"])


class SoulGroupTests(unittest.TestCase):
    def test_group_prompt_has_soul_and_language(self):
        bot = {"persona_id": "pirate", "name": "海盗", "instructions": "x", "soul": SOUL}
        msgs = cloud_groups.build_prompt(bot, cloud_bots.prompt(bot, []), {"name": "群"}, [], [bot], "mention")
        self.assertIn("Captain Fake", msgs[0]["content"])
        self.assertIn("用「English」回复", msgs[0]["content"])
        plain = {"persona_id": "p", "name": "p", "instructions": "x"}
        self.assertNotIn("灵魂设定", cloud_groups.build_prompt(plain, cloud_bots.prompt(plain, []), {"name": "群"}, [], [plain], "mention")[0]["content"])


if __name__ == "__main__":
    unittest.main()
