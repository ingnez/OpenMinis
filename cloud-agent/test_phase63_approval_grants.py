#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批准一次 / 本任务内都批准：绑定任务+工具+参数哈希；聊天里说「同意」不算批准。"""

import json
import os
import time
import unittest

import cloud_approval_grant
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


def two_risky(command, second=None, final="finished"):
    second = command if second is None else second

    def script(data):
        n = len(tool_turns(data))
        if n == 0:
            return tool_call("call_a", "shell_execute", {"command": command})
        if n == 1:
            return tool_call("call_b", "shell_execute", {"command": second})
        return {"role": "assistant", "content": final + ": " + tool_turns(data)[-1]["content"][:200]}
    return script


class GrantHashUnitTests(unittest.TestCase):
    def test_args_hash_is_canonical(self):
        a = cloud_approval_grant.args_hash({"b": 1, "a": 2})
        b = cloud_approval_grant.args_hash({"a": 2, "b": 1})
        c = cloud_approval_grant.args_hash({"a": 2, "b": 3})
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)
        self.assertEqual(len(a), 64)

    def test_parse_decision(self):
        self.assertEqual(cloud_approval_grant.parse_decision("approve"), ("approved", "once"))
        self.assertEqual(cloud_approval_grant.parse_decision("approve_once"), ("approved", "once"))
        self.assertEqual(cloud_approval_grant.parse_decision("approve_task"), ("approved", "task"))
        self.assertEqual(cloud_approval_grant.parse_decision("deny"), ("denied", None))
        self.assertEqual(cloud_approval_grant.parse_decision("同意"), (None, None))
        self.assertEqual(cloud_approval_grant.parse_decision("approve_always"), (None, None))


class ApprovalGrantFlowTests(CloudServerTestCase):
    approval_mode = "ask"

    def _pending(self, task_id):
        def find():
            evs = self.request("GET", f"/v1/tasks/{task_id}")[1]["events"]
            for ev in evs:
                if ev["type"] == "approval_required":
                    return ev["payload"]
            return None
        return self.wait_until(find, message="no approval_required event")

    def _pending_count(self, task_id):
        evs = self.request("GET", f"/v1/tasks/{task_id}")[1]["events"]
        return sum(1 for ev in evs if ev["type"] == "approval_required")

    def test_01_chat_同意_does_not_approve(self):
        FakeModelHandler.scripts["m-agree"] = two_risky("rm -rf /tmp/openminis-fake-grant-a")
        sid = self.new_session()
        tid = self.submit(sid, "clean", "m-agree")[1]["task_id"]
        appr = self._pending(tid)
        self.assertEqual(self.wait_status(tid, {"waiting_user"})["status"], "waiting_user")
        # 插话「同意」只进收件箱，不能当审批
        code, body = self.request("POST", f"/v1/tasks/{tid}/messages", {"content": "同意", "nonce": "n-agree-1"})
        self.assertIn(code, (200, 202), body)
        self.assertTrue(body.get("accepted"))
        time.sleep(0.4)
        self.assertEqual(self.request("GET", f"/v1/tasks/{tid}")[1]["status"], "waiting_user")
        listing = self.request("GET", f"/v1/tasks/{tid}/approvals")[1]["approvals"]
        self.assertEqual(listing[0]["status"], "pending")
        # 必须走审批接口
        self.assertEqual(self.request("POST", f"/v1/tasks/{tid}/approvals/{appr['approval_id']}",
                                      {"decision": "approve_once"})[0], 200)
        # 第二次同样的命令：一次批准已用完，还要再问
        appr2 = self.wait_until(lambda: self._pending_count(tid) >= 2 and
                                next(e["payload"] for e in self.request("GET", f"/v1/tasks/{tid}")[1]["events"]
                                     if e["type"] == "approval_required" and e["payload"]["approval_id"] != appr["approval_id"]),
                                message="second approval not requested")
        self.assertEqual(self.request("POST", f"/v1/tasks/{tid}/approvals/{appr2['approval_id']}",
                                      {"decision": "deny"})[0], 200)
        self.wait_status(tid, {"completed"})

    def test_02_approve_task_reuses_same_hash_only(self):
        FakeModelHandler.scripts["m-task"] = two_risky("rm -rf /tmp/openminis-fake-grant-same",
                                                       "rm -rf /tmp/openminis-fake-grant-other")
        sid = self.new_session()
        tid = self.submit(sid, "clean", "m-task")[1]["task_id"]
        appr = self._pending(tid)
        self.assertIn("args_hash", appr)
        self.assertEqual(self.request("POST", f"/v1/tasks/{tid}/approvals/{appr['approval_id']}",
                                      {"decision": "approve_task"})[0], 200)
        # 第二个命令参数不同：不能复用本任务批准，要再问
        appr2 = self.wait_until(lambda: self._pending_count(tid) >= 2 and
                                next((e["payload"] for e in self.request("GET", f"/v1/tasks/{tid}")[1]["events"]
                                      if e["type"] == "approval_required" and e["payload"]["approval_id"] != appr["approval_id"]), None),
                                message="different-args approval not requested")
        self.assertNotEqual(appr2["args_hash"], appr["args_hash"])
        self.assertEqual(self.request("POST", f"/v1/tasks/{tid}/approvals/{appr2['approval_id']}",
                                      {"decision": "approve_task"})[0], 200)
        final = self.wait_status(tid, {"completed"})
        grants = [e for e in final["events"] if e["type"] == "approval_grant"]
        self.assertEqual(len(grants), 0, "second call had a different hash, should not consume the first grant")

    def test_03_approve_task_skips_identical_followup(self):
        FakeModelHandler.scripts["m-same"] = two_risky("rm -rf /tmp/openminis-fake-grant-dup")
        sid = self.new_session()
        tid = self.submit(sid, "clean", "m-same")[1]["task_id"]
        appr = self._pending(tid)
        self.assertEqual(self.request("POST", f"/v1/tasks/{tid}/approvals/{appr['approval_id']}",
                                      {"decision": "approve_task"})[0], 200)
        final = self.wait_status(tid, {"completed"})
        evs = final["events"]
        self.assertEqual(sum(1 for e in evs if e["type"] == "approval_required"), 1)
        self.assertTrue(any(e["type"] == "approval_grant" and e["payload"].get("scope") == "task" for e in evs))
        results = [e for e in evs if e["type"] == "tool_result"]
        self.assertGreaterEqual(len(results), 2)


if __name__ == "__main__":
    unittest.main()
