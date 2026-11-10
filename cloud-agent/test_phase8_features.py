#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 8：用量统计与每日上限、记忆编辑与主 Bot 共享记忆、Bot 写技能、全局搜索、备份导出导入、删除文件需审批。"""

import json
import urllib.parse
import unittest

import cloud_policy
import cloud_usage
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


class UsageUnitTests(unittest.TestCase):
    def test_cap_state_and_estimate(self):
        cs = cloud_usage.CapState()
        self.assertEqual(cs.check(50, 0, 80), (False, None))
        self.assertEqual(cs.check(85, 100, 80, day="d"), (False, "near"))
        self.assertEqual(cs.check(90, 100, 80, day="d"), (False, None))     # 每天只提醒一次
        self.assertEqual(cs.check(100, 100, 80, day="d"), (True, "cap"))
        self.assertEqual(cs.check(120, 100, 80, day="d"), (True, None))
        self.assertEqual(cloud_usage.usage_from_response({"usage": {"prompt_tokens": 7, "completion_tokens": 3}}), (7, 3))
        p, c = cloud_usage.usage_from_response({}, [{"content": "你好世界"}], "ok")
        self.assertGreater(p, 3)

    def test_policy_rm(self):
        pol = cloud_policy.DEFAULT_POLICY
        self.assertEqual(cloud_policy.evaluate("shell_execute", {"command": "rm notes.txt"}, pol)["id"], "rm_files")
        self.assertEqual(cloud_policy.evaluate("shell_execute", {"command": "python3 -c 'import os; os.remove(\"a\")'"}, pol)["id"], "python_delete")
        self.assertIsNone(cloud_policy.evaluate("shell_execute", {"command": "echo firmware"}, pol))


class FeatureServerTests(CloudServerTestCase):
    def test_01_usage_and_cap(self):
        FakeModelHandler.scripts["m-use"] = lambda d: {"role": "assistant", "content": "ok"}
        sid = self.new_session()
        t = self.submit(sid, "hi", "m-use")[1]
        self.wait_status(t["task_id"], ("completed",))
        u = self.request("GET", "/v1/usage")[1]
        self.assertGreater(u["today_total"], 0)
        self.assertIn("m-use", u["by_model"])
        self.request("PUT", "/v1/resources", {"daily_token_cap": 1})
        try:
            st, body = self.submit(sid, "again", "m-use")
            self.assertEqual((st, body.get("error_kind")), (429, "daily_cap"))
        finally:
            self.request("PUT", "/v1/resources", {"daily_token_cap": 0})

    def test_02_memory_edit_and_primary_shared(self):
        self.request("PUT", "/v1/bots/mprime", {"name": "主", "instructions": "x", "is_primary": True})
        self.request("PUT", "/v1/bots/mother", {"name": "副", "instructions": "x"})
        FakeModelHandler.scripts["m-mem"] = lambda d: (tool_call("w", "memory_write", {"content": "用户喜欢喝美式", "category": "profile"})
                                                       if d["messages"][-1]["role"] != "tool" else {"role": "assistant", "content": "记住了"})
        sid = self.request("POST", "/v1/sessions", {"title": "m", "persona_id": "mprime"})[1]["session_id"]
        self.wait_status(self.submit(sid, "记住", "m-mem")[1]["task_id"], ("completed",))
        mine = self.request("GET", "/v1/memory?bot=mother")[1]["entries"]
        entry = [e for e in mine if "美式" in e["content"]][0]
        self.assertEqual(entry["persona"], "")                      # 主 Bot 写的是共享记忆
        st, e2 = self.request("PUT", f"/v1/memory/{entry['id']}", {"content": "用户喜欢喝拿铁", "bot_id": "mother"})
        self.assertEqual((st, e2["content"], e2["persona"]), (200, "用户喜欢喝拿铁", "mother"))
        self.assertEqual(self.request("GET", "/v1/memory?bot=mprime&shared=0")[1]["entries"], [])
        self.assertEqual(self.request("PUT", "/v1/memory/999999", {"content": "x"})[0], 404)
        st, e3 = self.request("POST", "/v1/memory", {"content": "手动添加", "bot_id": "mother"})
        self.assertEqual((st, e3["persona"]), (201, "mother"))

    def test_03_skill_save_search_backup(self):
        self.request("PUT", "/v1/bots/sk", {"name": "技能王", "instructions": "x", "skills": []})
        FakeModelHandler.scripts["m-sk"] = lambda d: (tool_call("s", "skill_save", {"name": "weekly-report", "description": "写周报",
                                                                                    "content": "1. 收集\n2. 汇总"})
                                                      if d["messages"][-1]["role"] != "tool" else {"role": "assistant", "content": "存好了独角兽"})
        sid = self.request("POST", "/v1/sessions", {"title": "s", "persona_id": "sk"})[1]["session_id"]
        self.wait_status(self.submit(sid, "存技能", "m-sk")[1]["task_id"], ("completed",))
        self.assertIn('"added"', tool_turns(FakeModelHandler.requests[-1])[-1]["content"])
        self.assertIn("weekly-report", self.request("GET", "/v1/bots/sk")[1]["skills"])
        res = self.request("GET", "/v1/search?q=" + urllib.parse.quote("独角兽"))[1]["results"]
        self.assertEqual((res[0]["type"], res[0]["bot_name"]), ("bot", "技能王"))
        self.assertEqual(self.request("GET", "/v1/search?q=")[0], 400)
        backup = self.request("GET", "/v1/backup")[1]
        self.assertEqual(backup["format"], "openminis-backup/1")
        self.assertNotIn("sk-", json.dumps(backup, ensure_ascii=False).replace("sk\"", ""))
        self.assertTrue(any(s["name"] == "weekly-report" for s in backup["skills"]))
        # 导入到同一台：已有的全部跳过；改个 ID 的会话会被导入
        sess = [s for s in backup["sessions"] if s["session_id"] == sid][0]
        sess = dict(sess, session_id="sess_restored01")
        st, stats = self.request("POST", "/v1/backup/import", {"backup": dict(backup, sessions=[sess])})
        self.assertEqual((st, stats["sessions"], stats["bots"]), (200, 1, 0))
        self.assertEqual(self.request("POST", "/v1/backup/import", {"backup": {"format": "x"}})[0], 400)


if __name__ == "__main__":
    unittest.main()
