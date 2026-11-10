#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 6：Bot 之间的消息与委托（list_bots / send_to_bot / delegate_task、层数、频率、取消传递、结果回报）。"""

import threading
import time
import unittest

import cloud_delegation as deleg
import cloud_isolation as iso
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


class DelegationUnitTests(unittest.TestCase):
    def test_limiter_hop_and_marks(self):
        lim = deleg.PairLimiter(window=600)
        lim.check_and_add("a", "b", 2, now=0)
        lim.check_and_add("a", "b", 2, now=1)
        with self.assertRaises(deleg.LimitError):
            lim.check_and_add("a", "b", 2, now=2)
        lim.check_and_add("b", "a", 2, now=2)        # 反方向单独计数
        lim.check_and_add("a", "b", 2, now=700)      # 窗口过去后恢复
        lim.check_and_add("a", "b", 0, now=701)      # 0 = 不限
        deleg.check_hop(3, 3)
        with self.assertRaises(deleg.LimitError):
            deleg.check_hop(4, 3)
        with self.assertRaises(deleg.LimitError):
            deleg.check_hop(1, 0)
        t = deleg.incoming_text("研究员", "task", "查资料", "dlg_1", True)
        self.assertEqual(deleg.parse_mark(t), ("incoming", "研究员", "委托"))
        self.assertEqual(deleg.parse_mark(deleg.result_text("写手", "completed", "好了")), ("result", "写手", "已完成"))
        self.assertIsNone(deleg.parse_mark("普通消息"))

    def test_gate_priority_and_park(self):
        s = iso.merged_with_defaults({"max_tasks_total": 1})
        gate = iso.TaskGate(lambda: s)
        self.assertEqual(gate.acquire("t0", "bot:a", "a"), 0)
        order = []

        def run(tid, prio):
            gate.acquire(tid, "bot:" + tid, tid, priority=prio)
            order.append(tid)
            gate.release(tid)

        th1 = threading.Thread(target=run, args=("n1", "normal")); th1.start(); time.sleep(0.2)
        th2 = threading.Thread(target=run, args=("h1", "high")); th2.start(); time.sleep(0.2)
        self.assertEqual([q["task_id"] for q in gate.status()["queued"]], ["h1", "n1"])
        gate.park("t0")                               # 等别的 Bot 时让出名额
        th1.join(3); th2.join(3)
        self.assertEqual(order, ["h1", "n1"])
        gate.unpark("t0")
        self.assertIn("t0", [r["task_id"] for r in gate.status()["running"]])
        gate.release("t0")

    def test_settings_validation(self):
        cur = iso.merged_with_defaults({})
        self.assertEqual(iso.validate({"group_activity": "lively", "delegation_max_hops": 0}, cur)["delegation_max_hops"], 0)
        with self.assertRaises(iso.SettingsError):
            iso.validate({"group_activity": "loud"}, cur)
        with self.assertRaises(iso.SettingsError):
            iso.validate({"delegation_max_hops": 11}, cur)


def _messages(test, sid):
    return test.request("GET", f"/v1/sessions/{sid}")[1]["messages"]


class DelegationServerTests(CloudServerTestCase):
    def _bots(self, a, b):
        self.request("PUT", f"/v1/bots/{a}", {"name": a.upper(), "instructions": "你是" + a})
        self.request("PUT", f"/v1/bots/{b}", {"name": b.upper(), "instructions": "你是" + b, "description": "会算数"})
        return self.request("POST", "/v1/sessions", {"title": "d", "persona_id": a})[1]["session_id"]

    def _script(self, model, first_call, target_reply="答案是 2"):
        def script(d):
            last_user = [m for m in d["messages"] if m["role"] == "user"][-1]["content"]
            if isinstance(last_user, str) and last_user.startswith("【来自"):
                return {"role": "assistant", "content": target_reply}
            if d["messages"][-1]["role"] == "tool":
                return {"role": "assistant", "content": "汇总：" + d["messages"][-1]["content"][:300]}
            return first_call
        FakeModelHandler.scripts[model] = script

    def test_01_delegate_wait_returns_result(self):
        sid = self._bots("da", "db")
        self._script("m-d1", tool_call("c1", "delegate_task", {"bot_id": "db", "task": "1+1 等于几"}))
        t = self.submit(sid, "请让 DB 算一下", "m-d1")[1]
        self.wait_status(t["task_id"], ("completed",), timeout=20)
        final = _messages(self, sid)[-1]["content"]
        self.assertIn("答案是 2", final)
        ds = self.request("GET", f"/v1/delegations?session_id={sid}")[1]["delegations"]
        self.assertEqual((ds[0]["status"], ds[0]["reported"], ds[0]["to_name"], ds[0]["hop"]), ("completed", 1, "DB", 1))
        incoming = _messages(self, ds[0]["to_session"])[0]["content"]
        self.assertEqual(deleg.parse_mark(incoming), ("incoming", "DA", "委托"))
        # 结果只通过工具返回，不会再重复写一条到请求方会话
        self.assertFalse(any(isinstance(m["content"], str) and m["content"].startswith("【DB 的委托结果") for m in _messages(self, sid)))
        tools = [t["function"]["name"] for t in FakeModelHandler.requests[-1]["tools"]]
        self.assertIn("delegate_task", tools)

    def test_02_background_delegation_posts_back(self):
        sid = self._bots("ea", "eb")
        self._script("m-d2", tool_call("c1", "delegate_task", {"bot_id": "eb", "task": "慢慢算", "wait": False}))
        t = self.submit(sid, "交给 EB", "m-d2")[1]
        self.wait_status(t["task_id"], ("completed",), timeout=20)
        self.wait_until(lambda: any(isinstance(m["content"], str) and m["content"].startswith("【EB 的委托结果·已完成】")
                                    for m in _messages(self, sid)), timeout=20, message="结果没有发回请求方")

    def test_03_send_to_bot_and_limits(self):
        sid = self._bots("fa", "fb")
        self.request("PUT", "/v1/resources", {"delegation_pair_per_10min": 1})
        try:
            FakeModelHandler.scripts["m-d3"] = lambda d: (
                {"role": "assistant", "content": "收到"} if str([m for m in d["messages"] if m["role"] == "user"][-1]["content"]).startswith("【来自")
                else tool_call("c%d" % len(tool_turns(d)), "send_to_bot", {"bot_id": "fb", "message": "提醒一下"})
                if len(tool_turns(d)) < 2 else {"role": "assistant", "content": "done"})
            t = self.submit(sid, "通知 FB 两次", "m-d3")[1]
            self.wait_status(t["task_id"], ("completed",), timeout=20)
            sess_req = [r for r in FakeModelHandler.requests if r["model"] == "m-d3" and len(tool_turns(r)) == 2][-1]
            results = [m["content"] for m in tool_turns(sess_req)]
            self.assertIn('"sent"', results[0])
            self.assertIn("太频繁", results[1])
            self.request("PUT", "/v1/resources", {"delegation_max_hops": 0})
            self._script("m-d3b", tool_call("c1", "delegate_task", {"bot_id": "fb", "task": "x"}))
            t = self.submit(sid, "再委托", "m-d3b")[1]
            self.wait_status(t["task_id"], ("completed",), timeout=20)
            self.assertIn("已关闭", _messages(self, sid)[-1]["content"])
            # 委托给自己 / 不存在的 Bot
            self.assertRaises(ValueError, self.srv.start_delegation, "task_x", sid, "task", "fa", "x")
        finally:
            self.request("PUT", "/v1/resources", {"delegation_pair_per_10min": 10, "delegation_max_hops": 3})

    def test_04_cancel_propagates(self):
        sid = self._bots("ga", "gb")

        def script(d):
            last_user = [m for m in d["messages"] if m["role"] == "user"][-1]["content"]
            if isinstance(last_user, str) and last_user.startswith("【来自"):
                if d["messages"][-1]["role"] == "tool":
                    return {"role": "assistant", "content": "睡完了"}
                return tool_call("s1", "shell_execute", {"command": "sleep 20"})
            if d["messages"][-1]["role"] == "tool":
                return {"role": "assistant", "content": "end"}
            return tool_call("c1", "delegate_task", {"bot_id": "gb", "task": "睡一会"})
        FakeModelHandler.scripts["m-d4"] = script
        t = self.submit(sid, "go", "m-d4")[1]
        ds = self.wait_until(lambda: self.request("GET", f"/v1/delegations?session_id={sid}")[1]["delegations"], timeout=10)
        child = ds[0]["to_task"]
        time.sleep(1.0)
        self.assertEqual(self.request("POST", f"/v1/tasks/{t['task_id']}/cancel", {})[1]["status"], "cancelled")
        self.wait_status(child, ("cancelled",), timeout=15)


if __name__ == "__main__":
    unittest.main()
