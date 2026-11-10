#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 18：一轮对话只画一次（工具 id 唯一、过期草稿不重发）与「一律批准」默认值。"""

import json
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


class ToolIdTests(unittest.TestCase):
    def test_missing_and_duplicate_ids_are_replaced(self):
        import cloud_agent_server as srv
        seen = set()
        first = srv.normalize_tool_call_ids([{"id": "call_0"}, {"id": ""}, {}], seen)
        second = srv.normalize_tool_call_ids([{"id": "call_0"}], seen)
        ids = [tc["id"] for tc in first + second]
        self.assertEqual(ids[0], "call_0")
        self.assertEqual(len(set(ids)), 4)
        self.assertTrue(all(i.startswith("call_") for i in ids))
        self.assertIsNone(srv.normalize_tool_call_ids(None, seen))


class TurnStreamTests(CloudServerTestCase):
    def _events(self, tid, query=""):
        return self.request("GET", f"/v1/tasks/{tid}/events{query}")[1]

    def test_01_relay_reusing_call_ids_gets_unique_steps(self):
        def script(data):
            n = len(tool_turns(data))
            if n < 2:
                return tool_call("call_0", "shell_execute", {"command": f"echo step{n}"})
            return {"role": "assistant", "content": "done"}
        FakeModelHandler.scripts["m-dup"] = script
        sid = self.new_session()
        tid = self.submit(sid, "go", "m-dup")[1]["task_id"]
        final = self.wait_status(tid, {"completed"})
        calls = [e["payload"]["id"] for e in final["events"] if e["type"] == "tool_call"]
        results = [e["payload"].get("id") for e in final["events"] if e["type"] == "tool_result"]
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(set(calls)), 2, calls)
        self.assertEqual(results, calls)
        # 历史里的 tool 消息也对得上各自的调用
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        hist_ids = [tc["id"] for m in msgs for tc in (m.get("tool_calls") or [])]
        self.assertEqual(hist_ids, calls)

    def test_02_stale_live_draft_is_not_resent(self):
        FakeModelHandler.scripts["m-live"] = lambda data: {"role": "assistant", "content": "ok"}
        sid = self.new_session()
        tid = self.submit(sid, "hi", "m-live")[1]["task_id"]
        self.wait_status(tid, {"completed"})
        self.srv.live_update(tid, "6/6 全绿。导出了。")
        seq = self.srv.live_get(tid)["seq"]
        try:
            self.assertEqual(self._events(tid, "?after=0&live_after=-1")["live"]["text"], "6/6 全绿。导出了。")
            self.assertNotIn("live", self._events(tid, f"?after=0&live_after={seq}"))
        finally:
            self.srv.live_clear(tid)
        self.assertNotIn("live", self._events(tid, "?after=0&live_after=-1"))


def risky(command):
    def script(data):
        if not tool_turns(data):
            return tool_call("call_risky", "shell_execute", {"command": command})
        return {"role": "assistant", "content": "finished: " + tool_turns(data)[-1]["content"][:200]}
    return script


class ApprovalDefaultTests(CloudServerTestCase):
    def tearDown(self):
        self.srv.update_resource_settings({"bot_defaults": {"approval_mode": "auto"}})

    def test_01_default_is_auto_approve(self):
        self.assertEqual(self.request("GET", "/v1/resources")[1]["settings"]["bot_defaults"]["approval_mode"], "auto")
        FakeModelHandler.scripts["m-auto"] = risky("mkdir -p d && rm -rf d && echo removed")
        sid = self.new_session()
        tid = self.submit(sid, "clean", "m-auto")[1]["task_id"]
        final = self.wait_status(tid, {"completed"})
        types = [e["type"] for e in final["events"]]
        self.assertNotIn("approval_required", types)
        auto = [e["payload"] for e in final["events"] if e["type"] == "approval_auto"]
        self.assertEqual(auto[0]["rule_id"], "rm_recursive_force")
        self.assertIn("removed", json.dumps([e for e in final["events"] if e["type"] == "tool_result"]))

    def test_02_switch_back_to_ask(self):
        status, body = self.request("PUT", "/v1/resources", {"bot_defaults": {"approval_mode": "ask"}})
        self.assertEqual(status, 200, body)
        FakeModelHandler.scripts["m-ask"] = risky("mkdir -p d && rm -rf d && echo removed")
        sid = self.new_session()
        tid = self.submit(sid, "clean", "m-ask")[1]["task_id"]
        self.assertEqual(self.wait_status(tid, {"waiting_user"})["status"], "waiting_user")
        self.request("POST", f"/v1/tasks/{tid}/cancel")
        self.wait_status(tid, {"cancelled"})

    def test_03_validation(self):
        status, body = self.request("PUT", "/v1/resources", {"bot_defaults": {"approval_mode": "maybe"}})
        self.assertEqual(status, 400)
        self.assertIn("approval_mode", body["error"])


if __name__ == "__main__":
    unittest.main()
