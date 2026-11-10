#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 2：send_message 草稿审批——每次对外发送都先挂起为审批，批准后才发出。"""

import json
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, NotifySinkHandler, tool_call, tool_turns


class SendMessageDraftTests(CloudServerTestCase):
    def run_send(self, decision, policy_disabled=False):
        NotifySinkHandler.received.clear()
        if policy_disabled:
            self.request("PUT", "/v1/approval-policy", {"policy": {"enabled": False, "timeout_seconds": 60, "rules": []}})
        self.request("PUT", "/v1/notify", {"provider": "bark", "url": f"{self.notify_base}/key1", "events": {
            "task_completed": False, "approval_required": False, "routine_finished": False}})

        def script(data):
            if not tool_turns(data):
                return tool_call("d1", "send_message", {"channel": "push", "title": "提醒", "text": "明早 8 点交班"})
            return {"role": "assistant", "content": tool_turns(data)[0]["content"]}
        FakeModelHandler.scripts["m-send"] = script
        sid = self.new_session()
        task = self.submit(sid, "提醒我", "m-send")[1]
        self.wait_status(task["task_id"], ("waiting_user",))
        self.assertEqual(NotifySinkHandler.received, [])  # 草稿阶段未发送
        approvals = self.request("GET", f"/v1/tasks/{task['task_id']}/approvals")[1]["approvals"]
        self.assertEqual(approvals[0]["rule_id"], "send_message_draft")
        self.assertEqual(approvals[0]["arguments"]["text"], "明早 8 点交班")
        self.request("POST", f"/v1/tasks/{task['task_id']}/approvals/{approvals[0]['approval_id']}", {"decision": decision})
        self.wait_status(task["task_id"], ("completed",))
        return json.loads(tool_turns(FakeModelHandler.requests[-1])[0]["content"])

    def test_approve_sends(self):
        res = self.run_send("approve")
        self.assertEqual(res["status"], "sent")
        body = json.loads(self.wait_until(lambda: NotifySinkHandler.received)[0]["body"])
        self.assertEqual((body["title"], body["body"]), ("提醒", "明早 8 点交班"))

    def test_deny_does_not_send_even_with_policy_disabled(self):
        res = self.run_send("deny", policy_disabled=True)
        self.assertEqual(res["approval"], "denied")
        self.assertEqual(NotifySinkHandler.received, [])
        self.request("DELETE", "/v1/approval-policy")

    def test_validation(self):
        self.assertIn("channel", self.srv.tool_send_message("t", "s", {"channel": "sms", "text": "x"})["error"])
        self.assertIn("未配置", self.srv.tool_send_message("t", "s", {"channel": "telegram", "text": "x"})["error"])


if __name__ == "__main__":
    unittest.main()
