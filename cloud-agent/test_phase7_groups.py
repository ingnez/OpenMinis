#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 7：群聊（成员、谁来回复、错开与输入状态、上限、表情、Bot 接话、@ 后在 Bot 工作区执行任务）。"""

import random
import sqlite3
import threading
import time
import unittest

import cloud_groups as cg
from test_phase1_support import CloudServerTestCase, FakeModelHandler


BOTS = [
    {"persona_id": "chef", "name": "厨师", "description": "做菜 菜谱 食材", "instructions": "你会做菜"},
    {"persona_id": "coder", "name": "程序员", "description": "写代码 Python 调试", "instructions": "你写代码"},
    {"persona_id": "doc", "name": "医生", "description": "健康 用药", "instructions": "你是医生"},
]


class GroupLogicTests(unittest.TestCase):
    def test_mentions_and_responders(self):
        self.assertEqual(cg.mentioned("@厨师 今晚吃啥", BOTS), ["chef"])
        self.assertEqual(cg.mentioned("@CODER 看看", BOTS), ["coder"])
        self.assertEqual(sorted(cg.mentioned("@所有人 早", BOTS)), ["chef", "coder", "doc"])
        rng = random.Random(1)
        picked = cg.choose_responders("@医生 头疼怎么办", BOTS, "quiet", rng)
        self.assertEqual(picked[0], ("doc", "mention"))
        # 没人被 @ 时至少一个回复，且相关度高的优先
        always = [cg.choose_responders("这道菜的食材怎么准备", BOTS, "quiet", random.Random(s))[0][0] for s in range(20)]
        self.assertGreater(always.count("chef"), 10)
        self.assertGreater(cg.relevance("Python 代码报错", BOTS[1]), cg.relevance("Python 代码报错", BOTS[0]))

    def test_parse_reply_and_budget(self):
        self.assertEqual(cg.parse_reply("[PASS]")["kind"], "pass")
        self.assertEqual(cg.parse_reply("[REACT:👍]"), {"kind": "react", "emoji": "👍"})
        r = cg.parse_reply("厨师：好的，我来查\n[TASK] 搜索三道家常菜做法")
        self.assertEqual(r["kind"], "text")
        self.assertIn("搜索三道", r["task"])
        self.assertEqual(cg.parse_reply("厨师：好的", "厨师")["content"], "好的")
        b = cg.TokenBudget()
        b.add("g", 900, now=0)
        self.assertEqual(b.remaining("g", 1000, now=10), 100)
        self.assertEqual(b.remaining("g", 1000, now=70), 1000)
        self.assertGreater(b.remaining("g", 0), 10 ** 8)

    def test_validate(self):
        exists = lambda b: b in ("chef", "coder")
        self.assertEqual(cg.validate_fields({"name": " 饭搭子 ", "members": ["chef", "chef", "coder"]}, exists),
                         {"name": "饭搭子", "members": ["chef", "coder"]})
        for bad in ({"name": "", "members": ["chef"]}, {"name": "x", "members": []}, {"name": "x", "members": ["ghost"]},
                    {"name": "x", "members": ["chef"], "activity": "loud"}):
            with self.assertRaises(cg.GroupError):
                cg.validate_fields(bad, exists)


class FakeHooks:
    def __init__(self, replies, settings=None):
        self.conn_path = ":memory:"
        self.db_conn = sqlite3.connect(":memory:", check_same_thread=False)
        self.lock = threading.Lock()
        cg.ensure_schema(self.db_conn)
        self.replies = replies           # bot_id -> callable(history_text) -> str
        self.settings = {"group_max_bot_turns": 6, "group_tokens_per_min": 0, "group_max_concurrent": 2, "group_activity": "normal"}
        self.settings.update(settings or {})
        self.tasks = []
        self.calls = []

    def hooks(self, seed=3):
        outer = self

        class C:
            def __getattr__(self, k):
                return getattr(outer.db_conn, k)

            def execute(self, *a):
                with outer.lock:
                    return outer.db_conn.execute(*a)

            def commit(self):
                with outer.lock:
                    outer.db_conn.commit()

            def close(self):
                pass

        def llm(bot, messages, fallback):
            self.calls.append(bot["persona_id"])
            return self.replies[bot["persona_id"]](messages[-1]["content"]), 10

        return {"db": lambda: C(), "settings": lambda: self.settings, "bot": lambda b: next((x for x in BOTS if x["persona_id"] == b), None),
                "persona_text": lambda b: "你是" + b["name"], "llm": llm,
                "start_task": lambda g, b, t, m: self.tasks.append((b["persona_id"], t)),
                "rng": random.Random(seed), "sleep": lambda s: None}


class GroupEngineTests(unittest.TestCase):
    def _run(self, fh, text, members=("chef", "coder", "doc"), activity=None):
        eng = cg.GroupEngine(fh.hooks())
        conn = fh.hooks()["db"]()
        g = cg.create_group(conn, {"name": "测试群", "members": list(members), "activity": activity})
        mid = cg.add_message(conn, g["group_id"], "user", "text", text)
        eng.on_user_message(g["group_id"], mid, text, None).join(10)
        return cg.messages_after(conn, g["group_id"], mid), eng

    def test_mention_reply_task_and_chain(self):
        fh = FakeHooks({"chef": lambda h: "好嘞，我去查\n[TASK] 查三道家常菜" if "@厨师" in h and "@程序员" not in h.split("厨师：")[-1] else "[PASS]",
                        "coder": lambda h: "我可以写个购物清单脚本" if "厨师：" in h else "[PASS]",
                        "doc": lambda h: "[PASS]"}, {"group_activity": "quiet"})
        msgs, _ = self._run(fh, "@厨师 今晚做什么菜", activity="lively")
        texts = [(m["sender"], m["kind"]) for m in msgs]
        self.assertEqual(texts[0], ("chef", "text"))
        self.assertEqual(fh.tasks, [("chef", "查三道家常菜")])
        self.assertNotIn("[TASK]", msgs[0]["content"])

    def test_turn_cap_and_reactions(self):
        fh = FakeHooks({b["persona_id"]: (lambda h: "@所有人 我再说一句") for b in BOTS}, {"group_max_bot_turns": 3})
        msgs, _ = self._run(fh, "@所有人 大家好")
        self.assertEqual(len([m for m in msgs if m["kind"] == "text"]), 3)
        fh2 = FakeHooks({"chef": lambda h: "[REACT:🎉]", "coder": lambda h: "[REACT:🎉]", "doc": lambda h: "[REACT:🎉]"})
        msgs2, _ = self._run(fh2, "@所有人 我升职了")
        self.assertEqual({(m["kind"], m["content"]) for m in msgs2}, {("reaction", "🎉")})
        self.assertTrue(all(m["reply_to"] for m in msgs2))

    def test_token_budget_stops_round(self):
        fh = FakeHooks({b["persona_id"]: (lambda h: "@所有人 继续") for b in BOTS}, {"group_tokens_per_min": 15, "group_max_bot_turns": 0})
        msgs, _ = self._run(fh, "@所有人 聊")
        self.assertLessEqual(len([m for m in msgs if m["kind"] == "text"]), 2)


class GroupServerTests(CloudServerTestCase):
    def test_group_api_and_flow(self):
        self.srv.GROUPS.sleep = lambda s: None
        self.srv.GROUPS.rng = random.Random(7)
        self.request("PUT", "/v1/bots/gchef", {"name": "大厨", "instructions": "你会做菜", "description": "做菜"})
        self.request("PUT", "/v1/bots/gcode", {"name": "码农", "instructions": "你写代码"})
        self.assertEqual(self.request("POST", "/v1/groups", {"name": "x", "members": ["nobody"]})[0], 400)
        st, g = self.request("POST", "/v1/groups", {"name": "饭搭子", "members": ["gchef", "gcode"]})
        self.assertEqual(st, 201)
        gid = g["group_id"]
        self.assertEqual([m["name"] for m in g["member_bots"]], ["大厨", "码农"])

        def script(d):
            system = d["messages"][0]["content"]
            if "【来自 群聊「饭搭子」·委托】" in str(d["messages"][-1].get("content")):
                return {"role": "assistant", "content": "菜单：番茄炒蛋"}
            if "[人格：大厨]" in system:
                return {"role": "assistant", "content": "收到\n[TASK] 列一个今晚的菜单"}
            return {"role": "assistant", "content": "[PASS]"}
        FakeModelHandler.scripts["m-group"] = script
        st, r = self.request("POST", f"/v1/groups/{gid}/messages", {"content": "@大厨 今晚吃什么", "model": "m-group",
                                                                  "provider": {"base_url": self.model_base, "api_key": "sk-inline-test-key-000000000000"}})
        self.assertEqual(st, 202)
        after = r["message_id"]

        def got_result():
            msgs = self.request("GET", f"/v1/groups/{gid}/messages?after={after}&wait=2")[1]["messages"]
            return msgs if any(m["kind"] == "task_result" for m in msgs) else None
        msgs = self.wait_until(got_result, timeout=25, message="任务结果没有贴回群里")
        kinds = [(m["sender"], m["kind"]) for m in msgs]
        self.assertIn(("gchef", "text"), kinds)
        self.assertIn(("gchef", "task"), kinds)
        res = [m for m in msgs if m["kind"] == "task_result"][0]
        self.assertEqual((res["content"], res["meta"]["status"]), ("菜单：番茄炒蛋", "completed"))
        # 群列表、改名、移除成员、删除
        lst = self.request("GET", "/v1/groups")[1]["groups"]
        self.assertEqual(lst[0]["group_id"], gid)
        self.assertEqual(self.request("PUT", f"/v1/groups/{gid}", {"members": ["gchef"], "activity": "quiet"})[1]["members"], ["gchef"])
        self.assertEqual(self.request("PUT", f"/v1/groups/{gid}", {"activity": "loud"})[0], 400)
        self.assertEqual(self.request("DELETE", f"/v1/groups/{gid}")[0], 200)
        self.assertEqual(self.request("GET", f"/v1/groups/{gid}")[0], 404)


if __name__ == "__main__":
    unittest.main()
