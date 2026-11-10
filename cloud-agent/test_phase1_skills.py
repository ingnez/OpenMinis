#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 1 / 5：技能按需加载（只注入名称+描述索引，skill_load 读取全文）。"""

import json
import sqlite3
import unittest
import urllib.parse

import cloud_skills
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns

BODY = "---\nname: pump\ndescription: 泵速换算 μg/kg/min 与 ml/h\n---\n# 泵速\n" + ("详细步骤。" * 2000) + "\nSECRET-BODY-MARKER"


class SkillUnitTests(unittest.TestCase):
    def test_sync_prune_and_index(self):
        conn = sqlite3.connect(":memory:")
        cloud_skills.ensure_schema(conn)
        r = cloud_skills.sync(conn, [{"name": "pump", "content": BODY}, {"name": "夜班作息", "content": "# 夜班\n\n排夜班睡眠计划"}])
        self.assertEqual((r["added"], r["total"]), (2, 2))
        r = cloud_skills.sync(conn, [{"name": "pump", "content": BODY}], prune=True)
        self.assertEqual((r["unchanged"], r["removed"], r["total"]), (1, 1, 1))
        idx = cloud_skills.index_text(conn)
        self.assertIn("- pump: 泵速换算", idx)
        self.assertNotIn("SECRET-BODY-MARKER", idx)
        for bad in ["../x", "a/b", " x", "", "."]:
            with self.assertRaises(ValueError):
                cloud_skills.sync(conn, [{"name": bad, "content": "x"}])
        with self.assertRaises(ValueError):
            cloud_skills.sync(conn, [{"name": "a", "content": "x"}, {"name": "a", "content": "y"}])
        self.assertEqual(cloud_skills.list_index(conn)[0]["name"], "pump")  # 失败的批次不落盘


class SkillServerTests(CloudServerTestCase):
    def test_01_sync_index_in_prompt_and_skill_load(self):
        status, r = self.request("POST", "/v1/skills/sync", {"skills": [{"name": "pump", "content": BODY}], "prune": True})
        self.assertEqual((status, r["added"]), (200, 1))

        def script(data):
            turns = tool_turns(data)
            if not turns:
                return tool_call("s1", "skill_load", {"name": "pump"})
            if len(turns) == 1:
                return tool_call("s2", "skill_load", {"name": "pu"})
            return {"role": "assistant", "content": "done"}
        FakeModelHandler.scripts["m-skill"] = script
        sid = self.new_session()
        status, res = self.submit(sid, "换算泵速", "m-skill")
        self.assertEqual(status, 202)
        self.assertEqual(self.wait_status(res["task_id"], ("completed", "failed"))["status"], "completed")
        first = FakeModelHandler.requests[-3]
        system = first["messages"][0]["content"]
        self.assertIn("- pump: 泵速换算", system)
        self.assertNotIn("SECRET-BODY-MARKER", json.dumps(first, ensure_ascii=False))  # 全文不进首轮上下文
        self.assertIn("skill_load", [t["function"]["name"] for t in first["tools"]])
        turns = tool_turns(FakeModelHandler.requests[-1])
        self.assertIn("SECRET-BODY-MARKER", json.loads(turns[0]["content"])["content"])
        miss = json.loads(turns[1]["content"])
        self.assertIn("技能不存在", miss["error"])
        self.assertEqual(miss["similar"], ["pump"])

    def test_02_import_files_also_index_and_rest(self):
        status, res = self.request("POST", "/v1/sessions/import", {
            "local_session_id": "phone-skills", "workspace_files": [
                {"path": "skills/夜班作息/SKILL.md", "content": "---\ndescription: 倒班作息\n---\n内容"}]})
        self.assertEqual(res["skills_indexed"], 1)
        names = [s["name"] for s in self.request("GET", "/v1/skills")[1]["skills"]]
        self.assertIn("夜班作息", names)
        q = urllib.parse.quote("夜班作息")
        status, skill = self.request("GET", f"/v1/skills/{q}")
        self.assertEqual((status, skill["description"]), (200, "倒班作息"))
        self.assertEqual(self.request("DELETE", f"/v1/skills/{q}")[0], 200)
        self.assertEqual(self.request("GET", f"/v1/skills/{q}")[0], 404)
        self.assertEqual(self.request("POST", "/v1/skills/sync", {"skills": "nope"})[0], 400)


if __name__ == "__main__":
    unittest.main()
