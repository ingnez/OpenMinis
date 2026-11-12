#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 25：Grok Bot 式的对话行为——表情回应、选项卡、引用回复、页面卡片、例行任务工具、分层记忆、里程碑、安静唤醒。"""

import json
import threading
import time
import unittest

import cloud_runmodel
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns

FAKE_KEY = "sk-fake-runmodel-000000000000"


def system_of(req):
    return req["messages"][0]["content"]


def fresh_tools(req):
    msgs = req["messages"]
    last = max(i for i, m in enumerate(msgs) if m.get("role") == "user")
    return [m for m in msgs[last:] if m.get("role") == "tool"]


def last_user(req):
    return [m for m in req["messages"] if m.get("role") == "user"][-1]["content"]


class RunModelTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/credentials/rm", {"api_key": FAKE_KEY, "base_url": self.model_base})
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True})
        self.request("PUT", "/v1/bots/writer", {"name": "写手", "instructions": "你是写手", "model": None, "credential": None})

    def _sid(self, bot="writer"):
        return self.request("POST", "/v1/sessions", {"title": "t", "persona_id": bot})[1]["session_id"]

    def _say(self, sid, text, model, status=("completed",), **extra):
        code, res = self.submit(sid, text, model, **extra)
        self.assertIn(code, (200, 201, 202), res)
        self.wait_status(res["task_id"], set(status), timeout=30)
        return res

    def _msgs(self, sid):
        return self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]

    def _calls(self, model):
        return [r for r in FakeModelHandler.requests if r.get("model") == model]

    def test_01_bot_reacts_instead_of_reply_and_user_reacts(self):
        def script(d):
            if not fresh_tools(d):
                return tool_call("c0", "react", {"emoji": "👍"})
            return {"role": "assistant", "content": ""}
        FakeModelHandler.scripts["m-r1"] = script
        sid = self._sid()
        self._say(sid, "谢谢！", "m-r1")
        msgs = self._msgs(sid)
        user = [m for m in msgs if m["role"] == "user"][-1]
        self.assertEqual(user["reactions"], [{"actor": "bot", "emoji": "👍"}])
        self.assertFalse([m for m in msgs if m["role"] == "assistant" and (m.get("content") or "").strip() and not m.get("tool_calls")])
        # 用户可回应 Bot 的消息，也可回应自己的消息，后者保留 Bot 已加的表情。
        FakeModelHandler.scripts["m-r1b"] = lambda d: {"role": "assistant", "content": "好的"}
        self._say(sid, "再说一句", "m-r1b")
        bot_msg = [m for m in self._msgs(sid) if m["role"] == "assistant" and m.get("content") == "好的"][-1]
        code, res = self.request("POST", f"/v1/sessions/{sid}/messages/{bot_msg['id']}/reaction", {"emoji": "❤️"})
        self.assertEqual(code, 200, res)
        self.assertEqual(res["reactions"], [{"actor": "user", "emoji": "❤️"}])
        own_path = f"/v1/sessions/{sid}/messages/{user['id']}/reaction"
        code, own = self.request("POST", own_path, {"emoji": "❤️"})
        self.assertEqual(code, 200, own)
        self.assertEqual(own["reactions"], [{"actor": "bot", "emoji": "👍"}, {"actor": "user", "emoji": "❤️"}])
        self.assertEqual(self.request("POST", own_path, {"emoji": None})[1]["reactions"], [{"actor": "bot", "emoji": "👍"}])
        self.assertEqual(self.request("POST", f"/v1/sessions/{sid}/messages/{bot_msg['id']}/reaction", {"emoji": "hello"})[0], 400)
        self.assertEqual(self.request("POST", f"/v1/sessions/{sid}/messages/{bot_msg['id']}/reaction", {"emoji": ""})[1]["reactions"], [])

    def test_02_choice_card_ends_turn_and_answer_flows_back(self):
        def script(d):
            if "我选" in last_user(d) or "不选" in last_user(d):
                return {"role": "assistant", "content": "收到：" + last_user(d)}
            if not fresh_tools(d):
                return tool_call("c0", "ask_choice", {"question": "订哪家？", "options": [{"label": "A 店", "detail": "近"}, "B 店", "C 店"]})
            return {"role": "assistant", "content": "SHOULD-NOT-BE-ASKED"}
        FakeModelHandler.scripts["m-r2"] = script
        sid = self._sid()
        self._say(sid, "帮我订个餐厅", "m-r2")
        self.assertEqual(len(self._calls("m-r2")), 1)                 # 选项卡结束本轮，不再问模型
        card = [m for m in self._msgs(sid) if m.get("choice")][-1]
        self.assertEqual([o["label"] for o in card["choice"]["options"]], ["A 店", "B 店", "C 店"])
        self.assertTrue(card["choice"]["allow_custom"])
        self.assertIn("订哪家？", card["content"])
        self._say(sid, "B 店", "m-r2", choice_answer={"message_id": card["id"], "selected": ["2"]})
        msgs = self._msgs(sid)
        self.assertEqual([m for m in msgs if m["role"] == "user"][-1]["content"], "我选：B 店")
        self.assertEqual(msgs[-1]["content"], "收到：我选：B 店")
        self.assertEqual([m for m in msgs if m.get("choice")][-1]["choice"]["answer"]["selected"], ["2"])
        code, _ = self.submit(sid, "x", "m-r2", choice_answer={"message_id": card["id"], "selected": ["1"]})
        self.assertEqual(code, 400)       # 只能选一次
        self.assertEqual(cloud_runmodel.choice_answer_text(card["choice"], [], None, True), "（我先不选，跳过这个问题）")
        with self.assertRaises(cloud_runmodel.RunModelError):
            cloud_runmodel.validate_choice({"question": "q", "options": ["only one"]})

    def test_03_threaded_reply_quotes_for_model(self):
        FakeModelHandler.scripts["m-r3"] = lambda d: {"role": "assistant", "content": "第一版：FAKE-PLAN-ALPHA" if "计划" in last_user(d) else "改好了"}
        sid = self._sid()
        self._say(sid, "给个计划", "m-r3")
        target = [m for m in self._msgs(sid) if m["role"] == "assistant"][-1]
        self._say(sid, "这条改短一点", "m-r3", reply_to=target["id"])
        sent = self._calls("m-r3")[-1]["messages"]
        u = [m for m in sent if m["role"] == "user"][-1]["content"]
        self.assertTrue(u.startswith("> 回复（你之前说）：第一版：FAKE-PLAN-ALPHA"), u)
        mine = [m for m in self._msgs(sid) if m["role"] == "user"][-1]
        self.assertEqual(mine["content"], "这条改短一点")
        self.assertEqual(mine["reply_to"]["id"], target["id"])
        self.assertEqual(self.submit(sid, "x", "m-r3", reply_to=999999)[0], 400)

    def test_04_page_card_on_final_reply(self):
        def script(d):
            if not fresh_tools(d):
                return tool_call("c0", "page_write", {"title": "FAKE 周报", "html": "<h1>周报</h1>"})
            return {"role": "assistant", "content": "周报做好了，点开看。"}
        FakeModelHandler.scripts["m-r4"] = script
        sid = self._sid()
        self._say(sid, "做个周报页面", "m-r4")
        last = self._msgs(sid)[-1]
        self.assertEqual(last["content"], "周报做好了，点开看。")
        self.assertEqual(last["page"]["title"], "FAKE 周报")
        self.assertTrue(last["page"]["page_id"])

    def test_05_routine_tools_in_user_timezone(self):
        self.request("PUT", "/v1/settings", {"timezone": "Asia/Shanghai"})
        self.request("PUT", "/v1/bots/writer", {"name": "写手", "instructions": "你是写手", "model": "m-r5", "credential": "rm"})
        made = {}

        def script(d):
            t = last_user(d)
            if fresh_tools(d):
                made.update(json.loads(fresh_tools(d)[-1]["content"]))
                return {"role": "assistant", "content": "好了"}
            if "每天" in t:
                return tool_call("c0", "routine_create", {"name": "早报", "prompt": "汇总新闻", "schedule": {"kind": "cron", "expr": "0 9 * * *", "window_minutes": 20}})
            if "提醒" in t:
                return tool_call("c1", "routine_create", {"name": "喝水", "prompt": "提醒喝水", "schedule": {"kind": "once", "at": "2099-01-02T08:30"}})
            if "降价" in t:
                return tool_call("c2", "routine_create", {"name": "盯价格", "prompt": "看 FAKE 商品价格", "monitor": True, "schedule": {"kind": "interval", "seconds": 3600}})
            if "列出" in t:
                return tool_call("c3", "routine_list", {})
            return tool_call("c4", "routine_delete", {"id": made["id"]})
        FakeModelHandler.scripts["m-r5"] = script
        sid = self._sid()
        self._say(sid, "每天早上给我早报", "m-r5")
        daily = self.request("GET", f"/v1/routines/{made['id']}")[1]
        daily = daily.get("routine", daily)
        self.assertEqual(daily["schedule"], {"kind": "cron", "expr": "0 9 * * *", "timezone": "Asia/Shanghai", "window_minutes": 20})
        self.assertEqual(daily["persona_id"], "writer")
        from datetime import datetime
        from zoneinfo import ZoneInfo
        nxt = datetime.fromtimestamp(daily["next_run_at"], ZoneInfo("Asia/Shanghai"))
        self.assertEqual(nxt.hour, 9)
        self.assertLess(nxt.minute, 21)
        self._say(sid, "明早提醒我喝水", "m-r5")
        once = self.request("GET", f"/v1/routines/{made['id']}")[1]
        once = once.get("routine", once)
        self.assertEqual(once["schedule"]["at"], datetime(2099, 1, 2, 8, 30, tzinfo=ZoneInfo("Asia/Shanghai")).timestamp())
        self.assertEqual(once["max_runs"], 1)
        self._say(sid, "降价了告诉我", "m-r5")
        mon = self.request("GET", f"/v1/routines/{made['id']}")[1]
        mon = mon.get("routine", mon)
        self.assertIn("[SKIP]", mon["prompt"])
        self._say(sid, "列出例行任务", "m-r5")
        self.assertEqual(len(made["routines"]), 3)
        self._say(sid, "删掉", "m-r5")       # made 还是 routine_list 的结果，没有 id → 用上一次创建的
        self.assertTrue(self.srv.is_quiet_result("无变化。"))
        self.assertTrue(self.srv.is_quiet_result("[SKIP]"))
        self.assertFalse(self.srv.is_quiet_result("价格从 99 降到 79，没有变化的是库存"))

    def test_06_layered_memory_in_context(self):
        conn = self.srv.get_db_connection()
        try:
            import cloud_memory
            cloud_memory.write(conn, "用户叫 FAKE-NAME，住在上海", "profile", source="cloud", persona="")
            cloud_memory.write(conn, "写手：用户喜欢短句", "rules", source="cloud", persona="writer")
            cloud_memory.write(conn, "总管私事 FAKE-BOSS-ONLY", "profile", source="cloud", persona="boss")
            cloud_memory.write(conn, "2026-11-01 日记 FAKE-JOURNAL", "note", source="cloud", persona="writer")
        finally:
            conn.close()
        FakeModelHandler.scripts["m-r6"] = lambda d: {"role": "assistant", "content": "ok"}
        self._say(self._sid("writer"), "你好", "m-r6")
        sys_text = system_of(self._calls("m-r6")[-1])
        self.assertIn("FAKE-NAME", sys_text)           # 共用的用户档案
        self.assertIn("用户喜欢短句", sys_text)          # 自己的档案
        self.assertNotIn("FAKE-BOSS-ONLY", sys_text)   # 别的 Bot 的档案
        self.assertNotIn("FAKE-JOURNAL", sys_text)     # 日记不常驻，用 memory_search 查
        self.assertIn("[回复风格]", sys_text)
        self.assertIn("ask_choice", sys_text)

        def script(d):
            if not fresh_tools(d):
                return tool_call("c0", "memory_write", {"content": "用户养了一只猫 FAKE-CAT", "category": "profile", "scope": "shared"})
            return {"role": "assistant", "content": "记下了"}
        FakeModelHandler.scripts["m-r6b"] = script
        self._say(self._sid("writer"), "我养了只猫", "m-r6b")
        FakeModelHandler.scripts["m-r6c"] = lambda d: {"role": "assistant", "content": "ok"}
        self._say(self._sid("boss"), "你好", "m-r6c")
        self.assertIn("FAKE-CAT", system_of(self._calls("m-r6c")[-1]))   # 别的 Bot 也看得到共用档案

    def test_07_worker_milestones_capped(self):
        gate = threading.Event()

        def script(d):
            if "[后台任务]" in system_of(d):
                n = len(fresh_tools(d))
                if n < 4:
                    return tool_call(f"p{n}", "report_progress", {"text": f"阶段 {n + 1}"})
                return {"role": "assistant", "content": "全部完成"}
            if "调研" in last_user(d) and not fresh_tools(d):
                return tool_call("c0", "spawn_task", {"goal": "调研 FAKE", "title": "调研"})
            if fresh_tools(d) and "report_progress" in json.dumps(fresh_tools(d), ensure_ascii=False):
                return {"role": "assistant", "content": "x"}
            return {"role": "assistant", "content": "好，后台做"}
        FakeModelHandler.scripts["m-r7"] = script
        sid = self._sid("boss")
        self._say(sid, "帮我调研一下", "m-r7")
        deadline = time.time() + 20
        while time.time() < deadline and not [m for m in self._msgs(sid) if "后台任务完成" in (m.get("content") or "")]:
            time.sleep(0.1)
        miles = [m for m in self._msgs(sid) if m.get("milestone")]
        self.assertEqual([m["content"] for m in miles], ["⏳ 调研：阶段 1", "⏳ 调研：阶段 2", "⏳ 调研：阶段 3"])
        gate.set()

    def test_09_quick_ack_with_fast_model(self):
        self.srv.QUICK_ACK_DELAY = 0.3
        self.srv.update_resource_settings({"fast_model": "m-fast"})
        try:
            FakeModelHandler.scripts["m-fast"] = lambda d: {"role": "assistant", "content": "收到，马上去查"}

            def slow(d):
                if not fresh_tools(d):
                    time.sleep(1.5)
                    return tool_call("c0", "memory_search", {"query": "x"})
                return {"role": "assistant", "content": "查到了：42"}
            FakeModelHandler.scripts["m-slow"] = slow
            sid = self._sid()
            self._say(sid, "帮我查个数", "m-slow")
            fast = self._calls("m-fast")
            self.assertEqual(len(fast), 1)
            self.assertIn("不超过 20 个字", system_of(fast[0]))
            msgs = self._msgs(sid)
            ack = [m for m in msgs if m["role"] == "assistant" and m.get("tool_calls")][0]
            self.assertEqual(ack["content"], "收到，马上去查")       # 并进工具调用那条消息，顺序不乱
            self.assertEqual(msgs[-1]["content"], "查到了：42")
            # 主模型很快就说话：不调快速模型
            FakeModelHandler.scripts["m-quick"] = lambda d: {"role": "assistant", "content": "马上答"}
            self._say(sid, "你好", "m-quick")
            time.sleep(0.6)
            self.assertEqual(len(self._calls("m-fast")), 1)
        finally:
            self.srv.update_resource_settings({"fast_model": ""})
            self.srv.QUICK_ACK_DELAY = 1.5

    def test_08_beats_split(self):
        self.assertEqual(cloud_runmodel.split_beats("答案是 42。\n---\n顺便：记下了。"), ["答案是 42。", "顺便：记下了。"])
        self.assertIsNone(cloud_runmodel.split_beats("```\na\n---\nb\n```"))
        self.assertEqual(len(cloud_runmodel.split_beats("a\n---\nb\n---\nc\n---\nd")), 3)


if __name__ == "__main__":
    unittest.main()
