#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 64：群聊 G1–G11（折叠、输入中、不在时速览、收尾总结与分歧、只听、回复串、额度、与我相关、转任务）。"""

import unittest

import cloud_groups as cg
from test_phase1_support import CloudServerTestCase, FakeModelHandler


NAMES = {"chef": "厨师", "coder": "程序员", "doc": "医生"}


def _msgs(*rows):
    out = []
    for i, row in enumerate(rows, 1):
        sender, kind, content = row[0], row[1], row[2]
        extra = row[3] if len(row) > 3 else {}
        m = {"id": extra.get("id", i), "sender": sender, "kind": kind, "content": content,
             "reply_to": extra.get("reply_to"), "meta": extra.get("meta")}
        out.append(m)
    return out


class GroupUxLogicTests(unittest.TestCase):
    def test_g1_fold_hides_burst_after_two(self):
        msgs = _msgs(
            ("user", "text", "大家好"),
            ("chef", "text", "你好"),
            ("coder", "text", "我来了"),
            ("doc", "text", "我也在"),
            ("user", "text", "下一轮"),
        )
        sec = cg.fold_sections(msgs, keep=2)
        self.assertEqual(sec[0]["type"], "message")
        self.assertEqual(sec[1]["type"], "burst")
        self.assertEqual([m["sender"] for m in sec[1]["messages"]], ["chef", "coder"])
        self.assertEqual([m["sender"] for m in sec[1]["hidden"]], ["doc"])
        self.assertEqual(sec[2]["messages"][0]["content"], "下一轮")

    def test_g3_missed_digest(self):
        msgs = _msgs(
            ("user", "text", "早", {"id": 1}),
            ("chef", "text", "早上好", {"id": 2}),
            ("coder", "text", "已经写好了", {"id": 3}),
            ("chef", "reaction", "👍", {"id": 4}),
        )
        d = cg.missed_digest(msgs, last_read_id=1, names=NAMES)
        self.assertEqual(d["count"], 2)
        self.assertEqual(d["senders"], ["厨师", "程序员"])
        self.assertIn("已经写好了", d["preview"])
        empty = cg.missed_digest(msgs, last_read_id=4, names=NAMES)
        self.assertEqual(empty["count"], 0)

    def test_g4_wrap_summary_and_disagreements(self):
        msgs = _msgs(
            ("user", "text", "要不要加这项功能"),
            ("chef", "text", "我赞成，应该做"),
            ("coder", "text", "我不同意，现在不行"),
        )
        w = cg.compose_wrap(msgs, NAMES)
        self.assertIn("厨师", w["summary"])
        self.assertIn("程序员", w["summary"])
        self.assertTrue(w["disagreements"])
        self.assertIn("赞成", w["disagreements"][0])
        self.assertIn("反对", w["disagreements"][0])
        self.assertIn("分歧", w["content"])
        none = cg.compose_wrap(_msgs(("user", "text", "hi"), ("chef", "text", "好的收到")), NAMES)
        self.assertEqual(none["disagreements"], [])
        self.assertIn("没有明显分歧", none["content"])

    def test_g10_quota_hint(self):
        self.assertIsNone(cg.quota_hint({"turns": 1, "turns_max": 6, "tokens": 0, "tokens_max": 0, "hit": False}))
        self.assertIn("还剩 1 条", cg.quota_hint({"turns": 5, "turns_max": 6, "tokens": 0, "tokens_max": 0, "hit": False}))
        self.assertIn("已达上限 6", cg.quota_hint({"turns": 6, "turns_max": 6, "tokens": 0, "tokens_max": 0, "hit": True}))
        self.assertIn("token 额度已用完", cg.quota_hint({"turns": 1, "turns_max": 6, "tokens": 100, "tokens_max": 100, "hit": True}))
        self.assertIn("已用 80 / 100", cg.quota_hint({"turns": 1, "turns_max": 6, "tokens": 80, "tokens_max": 100, "hit": False}))

    def test_g11_relevant_to_user(self):
        hist = _msgs(("user", "text", "请看这个", {"id": 1}))
        mention = {"sender": "chef", "kind": "text", "content": "好", "meta": {"reason": "mention"}}
        reply = {"sender": "chef", "kind": "text", "content": "好", "reply_to": 1}
        chain = {"sender": "coder", "kind": "text", "content": "接话", "meta": {"reason": "chain"}}
        react = {"sender": "doc", "kind": "reaction", "content": "👍"}
        wrap = {"sender": "system", "kind": "wrap", "content": "总结：…"}
        quota = {"sender": "system", "kind": "system", "content": "本轮 Bot 发言已达上限 6 条", "meta": {"quota": "turns"}}
        self.assertTrue(cg.is_relevant_to_user(mention, hist, "relevant"))
        self.assertTrue(cg.is_relevant_to_user(reply, hist, "relevant"))
        self.assertFalse(cg.is_relevant_to_user(chain, hist, "relevant"))
        self.assertFalse(cg.is_relevant_to_user(react, hist, "relevant"))
        self.assertTrue(cg.is_relevant_to_user(wrap, hist, "relevant"))
        self.assertTrue(cg.is_relevant_to_user(quota, hist, "relevant"))
        self.assertTrue(cg.is_relevant_to_user(chain, hist, "all"))
        self.assertFalse(cg.is_relevant_to_user(react, hist, "all"))
        self.assertFalse(cg.is_relevant_to_user({"sender": "user", "kind": "text", "content": "我"}, hist, "all"))


class GroupUxServerTests(CloudServerTestCase):
    def _make(self, members=None):
        self.srv.GROUPS.sleep = lambda s: None
        self.request("PUT", "/v1/bots/gchef", {"name": "大厨", "instructions": "你会做菜", "description": "做菜"})
        self.request("PUT", "/v1/bots/gcode", {"name": "码农", "instructions": "你写代码"})
        st, g = self.request("POST", "/v1/groups", {"name": "讨论组", "members": members or ["gchef", "gcode"]})
        self.assertEqual(st, 201)
        return g["group_id"]

    def test_g4_g7_g9_g10_wrap_reply_spin_quota(self):
        gid = self._make()
        # 先写入两句对立观点（不走模型），再收尾
        self.request("POST", f"/v1/groups/{gid}/messages", {"content": "要不要加这项功能"})
        # 直接入库对立回复，避免假模型不确定性
        import cloud_agent_server as cas
        c = cas.get_db_connection()
        try:
            cg.add_message(c, gid, "gchef", "text", "我赞成，应该做")
            mid = cg.add_message(c, gid, "gcode", "text", "我不同意，现在不行")
        finally:
            c.close()
        st, wr = self.request("POST", f"/v1/groups/{gid}/wrap", {})
        self.assertEqual(st, 201, wr)
        self.assertTrue(wr.get("disagreements"))
        self.assertIn("总结", wr.get("content") or "")
        payload = self.request("GET", f"/v1/groups/{gid}")[1]
        self.assertIn("quota", payload)
        self.assertIn("turns", payload["quota"])
        kinds = [m["kind"] for m in payload["messages"]]
        self.assertIn("wrap", kinds)
        # G7 回复串
        st, r = self.request("POST", f"/v1/groups/{gid}/messages", {"content": "那折中一下", "reply_to": mid})
        self.assertEqual(st, 202, r)
        msgs = self.request("GET", f"/v1/groups/{gid}/messages?after=0&wait=0")[1]
        self.assertIn("quota", msgs)
        users = [m for m in msgs["messages"] if m["content"] == "那折中一下"]
        self.assertEqual(users[0]["reply_to"], mid)
        # G9 讨论转任务（贴回一条用户说明 + 启动任务）
        def script(messages, tools=None):
            return {"role": "assistant", "content": "菜单：番茄炒蛋"}
        FakeModelHandler.scripts["m-spin"] = script
        st, sp = self.request("POST", f"/v1/groups/{gid}/spin-task",
                              {"bot_id": "gchef", "goal": "列一个今晚菜单",
                               "model": "m-spin",
                               "provider": {"base_url": self.model_base, "api_key": "sk-inline-test-key-000000000000"}})
        self.assertEqual(st, 202, sp)
        self.assertEqual(sp["bot_id"], "gchef")

        def got_task():
            ms = self.request("GET", f"/v1/groups/{gid}/messages?after=0&wait=2")[1]["messages"]
            return ms if any(m["kind"] in ("task", "task_result") for m in ms) else None
        ms = self.wait_until(got_task, timeout=25, message="转任务没有贴回群里")
        self.assertTrue(any(m["kind"] == "task" for m in ms))

    def test_g3_g11_missed_and_notify_mode(self):
        gid = self._make()
        self.request("POST", f"/v1/groups/{gid}/messages", {"content": "第一句"})
        def settled():
            p = self.request("GET", f"/v1/groups/{gid}")[1]
            if p.get("typing"):
                return None
            return p
        payload = self.wait_until(settled, timeout=12, message="群聊这一轮没有结束")
        self.assertGreaterEqual(payload["missed"]["count"], 1)
        last = payload["messages"][-1]["id"]
        st, read = self.request("POST", f"/v1/groups/{gid}/read", {"last_id": last})
        self.assertEqual(st, 200, read)
        self.assertEqual(read["last_read_id"], last)
        self.assertEqual(read["missed"]["count"], 0)
        lst = self.request("GET", "/v1/groups")[1]["groups"][0]
        self.assertEqual(lst["missed_count"], 0)
        st, g = self.request("PUT", f"/v1/groups/{gid}", {"notify_mode": "all"})
        self.assertEqual(st, 200, g)
        self.assertEqual(g["notify_mode"], "all")
        self.assertEqual(self.request("PUT", f"/v1/groups/{gid}", {"notify_mode": "maybe"})[0], 400)
        # 默认新建是 relevant
        gid2 = self._make()
        self.assertEqual(self.request("GET", f"/v1/groups/{gid2}")[1]["notify_mode"], "relevant")

    def test_g10_turn_cap_posts_system_hint(self):
        from test_phase7_groups import FakeHooks, BOTS, GroupEngineTests
        fh = FakeHooks({b["persona_id"]: (lambda h: "@所有人 我再说一句") for b in BOTS}, {"group_max_bot_turns": 1})
        msgs, eng = GroupEngineTests()._run(fh, "@所有人 大家好")
        texts = [m for m in msgs if m["kind"] == "text"]
        syss = [m for m in msgs if m["kind"] == "system"]
        self.assertLessEqual(len(texts), 1)
        self.assertTrue(any("上限" in (m.get("content") or "") for m in syss), msgs)
        self.assertTrue(any((m.get("meta") or {}).get("quota") == "turns" for m in syss), msgs)


if __name__ == "__main__":
    unittest.main()
