#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 41：群聊辩论与投票（/辩论、/投票）。"""
import unittest

import cloud_debate as cd
import cloud_groups as cg
from test_phase7_groups import FakeHooks


class DebateLogicTests(unittest.TestCase):
    def test_parse_command(self):
        self.assertEqual(cd.parse_command("/辩论 远程办公比坐班好"), ("debate", "远程办公比坐班好", []))
        self.assertEqual(cd.parse_command("/投票 午饭吃啥 | 面 ｜ 饭 | 饺子"), ("vote", "午饭吃啥", ["面", "饭", "饺子"]))
        self.assertIsNone(cd.parse_command("/投票 只有一个 | 选项"))
        self.assertIsNone(cd.parse_command("今天辩论吗"))

    def test_choice_and_tally(self):
        opts = ["面", "饭", "饺子"]
        self.assertEqual(cd.parse_choice("选 2\n米饭顶饱", opts), 1)
        self.assertEqual(cd.parse_choice("我觉得饺子最好", opts), 2)
        self.assertIsNone(cd.parse_choice("都行", opts))
        self.assertIsNone(cd.parse_choice("选 9", opts))
        r = cd.tally([("a", 1), ("b", 1), ("c", 0), ("d", None)], opts)
        self.assertTrue(r.startswith("投票结果：「饭」胜出"))
        self.assertIn("饭：2 票", r)
        self.assertIn("弃权 / 没看懂：d", r)
        self.assertIn("平票", cd.tally([("a", 0), ("b", 1)], opts))
        self.assertIn("没有有效票", cd.tally([("a", None)], opts))


class DebateEngineTests(unittest.TestCase):
    def _run(self, fh, text, members=("chef", "coder", "doc")):
        eng = cg.GroupEngine(fh.hooks())
        conn = fh.hooks()["db"]()
        g = cg.create_group(conn, {"name": "辩论群", "members": list(members)})
        mid = cg.add_message(conn, g["group_id"], "user", "text", text)
        eng.on_user_message(g["group_id"], mid, text, None).join(10)
        return cg.messages_after(conn, g["group_id"], mid)

    def test_vote_flow(self):
        fh = FakeHooks({"chef": lambda h: "选 2\n饭顶饱", "coder": lambda h: "选 2\n同意", "doc": lambda h: "选 1\n面清淡"})
        msgs = self._run(fh, "/投票 午饭吃啥 | 面 | 饭")
        self.assertEqual(fh.calls, ["chef", "coder", "doc"])
        self.assertEqual(msgs[-1]["kind"], "system")
        self.assertIn("「饭」胜出", msgs[-1]["content"])
        self.assertEqual(len([m for m in msgs if m["kind"] == "text"]), 3)

    def test_debate_flow_no_self_vote(self):
        def reply(name, vote):
            def f(prompt):
                if "投票" in prompt:
                    return vote
                if "反驳" in prompt:
                    return f"{name}反驳"
                return f"{name}的观点"
            return f
        # 厨师投自己（不算），程序员投厨师，医生投程序员
        fh = FakeHooks({"chef": reply("厨师", "选 1\n我最对"), "coder": reply("程序员", "选 1\n厨师说得好"),
                        "doc": reply("医生", "选 2\n程序员有理")})
        msgs = self._run(fh, "/辩论 早饭要不要吃")
        texts = [m["content"] for m in msgs if m["kind"] == "text"]
        self.assertEqual(texts[:3], ["厨师的观点", "程序员的观点", "医生的观点"])
        self.assertEqual(texts[3:6], ["厨师反驳", "程序员反驳", "医生反驳"])
        result = msgs[-1]["content"]
        self.assertIn("平票", result)
        self.assertIn("弃权 / 没看懂：厨师", result)
        self.assertEqual(len(fh.calls), 9)

    def test_debate_needs_two(self):
        fh = FakeHooks({"chef": lambda h: "x"})
        msgs = self._run(fh, "/辩论 题目题目", members=("chef",))
        self.assertIn("至少要 2 个", msgs[-1]["content"])
        self.assertEqual(fh.calls, [])


if __name__ == "__main__":
    unittest.main()
