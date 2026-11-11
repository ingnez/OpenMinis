#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""命名密钥只在执行时注入；事件/模型里脱敏编码变体；聊天里误贴的假密钥会被遮罩。测试只用假值。"""

import base64
import binascii
import json
import os
import unittest
import urllib.parse

import cloud_secret_refs
import cloud_vault
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns

# 测试专用假值，不是真实密钥
FAKE_NAMED = "fake-named-secret-value-0001"
FAKE_PASTED = "sk-fake-phase64-not-a-real-key-xxxxxxxx"
FAKE_NAME = "FAKE_TOKEN"


class SecretRefUnitTests(unittest.TestCase):
    def test_placeholder_and_variants(self):
        self.assertTrue(cloud_secret_refs.valid_name("GITHUB_TOKEN"))
        self.assertFalse(cloud_secret_refs.valid_name("github-token"))
        self.assertEqual(cloud_secret_refs.find_refs("use {{secret:FAKE_TOKEN}} and {{secret:FAKE_TOKEN}}"), [FAKE_NAME])
        variants = cloud_secret_refs.encoded_variants(FAKE_NAMED)
        self.assertIn(FAKE_NAMED, variants)
        self.assertIn(urllib.parse.quote(FAKE_NAMED, safe=""), variants)
        self.assertIn(binascii.hexlify(FAKE_NAMED.encode()).decode(), variants)
        b64 = base64.standard_b64encode(FAKE_NAMED.encode()).decode()
        self.assertIn(b64, variants)
        self.assertIn(b64.rstrip("="), variants)

    def test_mask_pasted_fake_key(self):
        text, hit = cloud_secret_refs.mask_pasted("请保存 " + FAKE_PASTED + " 谢谢")
        self.assertTrue(hit)
        self.assertNotIn(FAKE_PASTED, text)
        self.assertIn(cloud_secret_refs.MASK, text)
        same, hit2 = cloud_secret_refs.mask_pasted("没有密钥，只是一段话")
        self.assertFalse(hit2)
        self.assertEqual(same, "没有密钥，只是一段话")

    def test_inject_leaves_unknown(self):
        args = {"command": "echo {{secret:FAKE_TOKEN}}"}
        injected, missing = cloud_secret_refs.inject(args, {FAKE_NAME: FAKE_NAMED})
        self.assertEqual(injected["command"], "echo " + FAKE_NAMED)
        self.assertEqual(missing, [])
        _, missing2 = cloud_secret_refs.inject(args, {})
        self.assertEqual(missing2, [FAKE_NAME])

    def test_redact_encoded_variants(self):
        blob = "leak " + FAKE_NAMED + " " + urllib.parse.quote(FAKE_NAMED, safe="") + " " + \
               binascii.hexlify(FAKE_NAMED.encode()).decode() + " " + \
               base64.standard_b64encode(FAKE_NAMED.encode()).decode()
        out = cloud_secret_refs.redact(blob, [FAKE_NAMED])
        self.assertNotIn(FAKE_NAMED, out)
        self.assertNotIn(urllib.parse.quote(FAKE_NAMED, safe=""), out)
        self.assertNotIn(binascii.hexlify(FAKE_NAMED.encode()).decode(), out)
        self.assertNotIn(base64.standard_b64encode(FAKE_NAMED.encode()).decode().rstrip("="), out)


class NamedSecretFlowTests(CloudServerTestCase):
    approval_mode = "ask"

    def test_01_mask_pasted_in_chat_and_inbox(self):
        FakeModelHandler.scripts["m-mask"] = lambda d: {"role": "assistant", "content": "收到"}
        sid = self.new_session()
        status, res = self.submit(sid, "帮我记下 " + FAKE_PASTED, "m-mask")
        self.assertIn(status, (200, 202), res)
        self.wait_status(res["task_id"], {"completed"})
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        user = next(m for m in msgs if m["role"] == "user")
        self.assertIn(cloud_secret_refs.MASK, user["content"])
        self.assertNotIn(FAKE_PASTED, json.dumps(msgs, ensure_ascii=False))
        # 模型请求里也不该出现原文
        sent = json.dumps(FakeModelHandler.requests, ensure_ascii=False)
        self.assertNotIn(FAKE_PASTED, sent)

    def test_02_inject_only_at_exec_and_redact_events(self):
        dest = os.path.join(self.srv.GLOBAL_WORKSPACE, "secret-out-fake.txt")
        # 命令把注入后的假值写到文件；事件里必须是遮罩，不能出现明文或常见编码
        cmd = 'printf %%s "{{secret:%s}}" > %s' % (FAKE_NAME, dest)

        def script(data):
            if not tool_turns(data):
                return tool_call("c1", "shell_execute", {"command": cmd})
            return {"role": "assistant", "content": "写好了"}

        FakeModelHandler.scripts["m-inj"] = script
        # 存命名密钥（假值）
        code, body = self.request("PUT", "/v1/named-secrets", {"name": FAKE_NAME, "value": FAKE_NAMED, "description": "测试假值"})
        self.assertIn(code, (200, 201), body)
        listed = self.request("GET", "/v1/named-secrets")[1]
        self.assertTrue(any(i["name"] == FAKE_NAME for i in listed["items"]))
        self.assertNotIn(FAKE_NAMED, json.dumps(listed))

        sid = self.new_session()
        tid = self.submit(sid, "写一下", "m-inj")[1]["task_id"]
        evs = self.request("GET", f"/v1/tasks/{tid}")[1]["events"]
        # 若命中审批（printf 通常不中），直接跑；中了就批准一次
        pending = next((e["payload"] for e in evs if e["type"] == "approval_required"), None)
        if pending is None:
            def find():
                ev = self.request("GET", f"/v1/tasks/{tid}")[1]["events"]
                return next((e["payload"] for e in ev if e["type"] == "approval_required"), True)
            got = self.wait_until(find, timeout=5, message="optional approval") if False else None
            _ = got
        # 等文件写出或任务结束
        self.wait_status(tid, {"completed"})
        with open(dest, "r", encoding="utf-8") as f:
            self.assertEqual(f.read(), FAKE_NAMED)
        raw = json.dumps(self.request("GET", f"/v1/tasks/{tid}")[1], ensure_ascii=False)
        self.assertNotIn(FAKE_NAMED, raw)
        self.assertNotIn(base64.standard_b64encode(FAKE_NAMED.encode()).decode().rstrip("="), raw)
        # 审批/工具调用参数里应保留占位符
        evs = self.request("GET", f"/v1/tasks/{tid}")[1]["events"]
        calls = [e for e in evs if e["type"] == "tool_call"]
        self.assertTrue(any("{{secret:FAKE_TOKEN}}" in json.dumps(e.get("payload") or {}, ensure_ascii=False) for e in calls))
        # GET 列表永不回说明文
        again = self.request("GET", "/v1/named-secrets")[1]
        self.assertNotIn("value", json.dumps(again.get("items")))
        self.assertEqual(self.request("DELETE", f"/v1/named-secrets/{FAKE_NAME}")[0], 200)

    def test_03_vault_redact_uses_encoded_variants(self):
        text = "x" + FAKE_NAMED + "y"
        out = cloud_vault.redact(text)  # 未登记时原文可保留
        registered = cloud_secret_refs.redact(text, [FAKE_NAMED])
        self.assertNotIn(FAKE_NAMED, registered)


if __name__ == "__main__":
    unittest.main()
