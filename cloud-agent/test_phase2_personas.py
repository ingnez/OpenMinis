#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 2：多人格（各自的指令与记忆范围；对话、例行任务、子代理继承）。"""

import json
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


class PersonaTests(CloudServerTestCase):
    def test_01_crud_and_validation(self):
        self.assertEqual(self.request("PUT", "/v1/personas/Bad%20Id", {"name": "x", "instructions": "y"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/personas/icu", {"name": "", "instructions": "y"})[0], 400)
        status, p = self.request("PUT", "/v1/personas/icu", {"name": "ICU 助手", "instructions": "你是重症医学助手。", "emoji": "🩺"})
        self.assertEqual((status, p["name"]), (201, "ICU 助手"))
        self.assertEqual(self.request("PUT", "/v1/personas/icu", {"name": "ICU 助手", "instructions": "你是重症医学助手，回答要引用指南。"})[0], 200)
        self.assertEqual([x["persona_id"] for x in self.request("GET", "/v1/personas")[1]["personas"]], ["icu"])
        self.assertEqual(self.request("POST", "/v1/sessions", {"title": "x", "persona_id": "ghost"})[0], 400)

    def test_02_persona_prompt_and_memory_isolation(self):
        self.request("PUT", "/v1/personas/coder", {"name": "代码助手", "instructions": "你只关心代码。"})
        self.request("PUT", "/v1/personas/doc", {"name": "医生助手", "instructions": "你只关心临床。"})
        self.request("POST", "/v1/memory", {"content": "共享：用户叫李", "category": "profile"})

        def writer(data):
            if not tool_turns(data):
                return tool_call("w1", "memory_write", {"content": "coder 私有：仓库在 ingnez/OpenMinis"})
            return {"role": "assistant", "content": "ok"}
        FakeModelHandler.scripts["m-p1"] = writer
        s1 = self.request("POST", "/v1/sessions", {"title": "c", "persona_id": "coder"})[1]["session_id"]
        t = self.submit(s1, "记一下", "m-p1")[1]
        self.wait_status(t["task_id"], ("completed",))
        system = FakeModelHandler.requests[-1]["messages"][0]["content"]
        self.assertTrue(system.startswith("[人格：代码助手]"))
        self.assertIn("你只关心代码。", system)

        def searcher(data):
            if data["messages"][-1]["role"] != "tool":
                return tool_call("s1", "memory_search", {"query": ""})
            return {"role": "assistant", "content": "done"}
        FakeModelHandler.scripts["m-p2"] = searcher
        s2 = self.request("POST", "/v1/sessions", {"title": "d", "persona_id": "doc"})[1]["session_id"]
        t = self.submit(s2, "查记忆", "m-p2")[1]
        self.wait_status(t["task_id"], ("completed",))
        out = json.loads(tool_turns(FakeModelHandler.requests[-1])[-1]["content"]); self.assertIn("results", out, out)
        seen = [r["content"] for r in out["results"]]
        self.assertIn("共享：用户叫李", seen)
        self.assertNotIn("coder 私有：仓库在 ingnez/OpenMinis", seen)
        t = self.submit(s1, "查记忆", "m-p2")[1]
        self.wait_status(t["task_id"], ("completed",))
        out = json.loads(tool_turns(FakeModelHandler.requests[-1])[-1]["content"]); self.assertIn("results", out, out)
        seen = [r["content"] for r in out["results"]]
        self.assertIn("coder 私有：仓库在 ingnez/OpenMinis", seen)
        # REST 可按人格过滤；不带 persona 时看到全部
        all_entries = self.request("GET", "/v1/memory?query=")[1]["entries"]
        self.assertEqual(len([e for e in all_entries if e["persona"] == "coder"]), 1)
        doc_view = self.request("GET", "/v1/memory?query=&persona=doc")[1]["entries"]
        self.assertFalse(any(e["persona"] == "coder" for e in doc_view))
        # 删除人格并清除其记忆
        res = self.request("DELETE", "/v1/personas/coder?purge_memory=1")[1]
        self.assertEqual(res["memory_purged"], 1)

    def test_03_routine_uses_persona(self):
        self.request("PUT", "/v1/personas/news", {"name": "简报员", "instructions": "你负责每日简报。"})
        self.request("PUT", "/v1/credentials/pc", {"api_key": "sk-persona-routine-00000000000", "base_url": self.model_base})
        FakeModelHandler.scripts["m-p3"] = lambda d: {"role": "assistant", "content": d["messages"][0]["content"][:20]}
        body = {"name": "简报", "prompt": "p", "model": "m-p3", "credential": "pc", "persona_id": "news",
                "schedule": {"kind": "interval", "seconds": 3600}}
        self.assertEqual(self.request("POST", "/v1/routines", dict(body, persona_id="ghost"))[0], 400)
        r = self.request("POST", "/v1/routines", body)[1]
        self.assertEqual(r["persona_id"], "news")
        self.request("POST", f"/v1/routines/{r['routine_id']}/run", {})
        runs = self.wait_until(lambda: [x for x in self.request("GET", f"/v1/routines/{r['routine_id']}/runs")[1]["runs"] if x["status"] == "completed"])
        self.assertTrue(runs[0]["result"].startswith("[人格：简报员]"))
        self.request("DELETE", "/v1/personas/news")
        self.assertIsNone(self.request("GET", f"/v1/routines/{r['routine_id']}")[1]["persona_id"])

    def test_04_consult_other_persona(self):
        self.request("PUT", "/v1/personas/main", {"name": "主助手", "instructions": "你是主助手。"})
        self.request("PUT", "/v1/personas/law", {"name": "法务", "instructions": "你是法务顾问。"})

        def model(data):
            system = data["messages"][0]["content"]
            if system.startswith("[人格：法务]"):
                return {"role": "assistant", "content": "法务意见：可以签"}
            if data["messages"][-1]["role"] != "tool":
                self.assertIn("law（法务）", system)
                self.assertNotIn("main（主助手）", system)
                return tool_call("c1", "subagent_task", {"task": "这份合同能签吗", "persona": "law"})
            return {"role": "assistant", "content": data["messages"][-1]["content"]}
        FakeModelHandler.scripts["m-p4"] = model
        sid = self.request("POST", "/v1/sessions", {"title": "m", "persona_id": "main"})[1]["session_id"]
        t = self.submit(sid, "问问法务", "m-p4")[1]
        self.wait_status(t["task_id"], ("completed",))
        out = json.loads(tool_turns(FakeModelHandler.requests[-1])[-1]["content"])
        self.assertEqual((out["persona"], out["result"]), ("law", "法务意见：可以签"))

        FakeModelHandler.scripts["m-p5"] = lambda d: (tool_call("c2", "subagent_task", {"task": "x", "persona": "ghost"})
                                                      if d["messages"][-1]["role"] != "tool" else {"role": "assistant", "content": "ok"})
        t = self.submit(sid, "问幽灵", "m-p5")[1]
        self.wait_status(t["task_id"], ("completed",))
        self.assertIn("人格不存在", tool_turns(FakeModelHandler.requests[-1])[-1]["content"])


if __name__ == "__main__":
    unittest.main()
