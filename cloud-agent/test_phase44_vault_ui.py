#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 44：保管库新界面要的服务端字段。全部假数据。
- App 列表的提示：卡片有效期、联系信息默认地址、密码弱 / 重复（只给 App，不进模型）
- 安全备注（note）：Bot 看不到内容、不能填写
- 每项可限定哪些 Bot 能用
"""
import json
import unittest
from urllib.parse import quote

import cloud_vault
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns

WEAK = "abc123"
STRONG = "Fake-Strong-9xQ2#pw"


class VaultUITests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True})
        self.request("PUT", "/v1/bots/shopper", {"name": "购物", "instructions": "你帮我买东西"})
        for it in self.request("GET", "/v1/vault")[1]["items"]:
            self.request("DELETE", f"/v1/vault/{it['id']}")

    def _add(self, body):
        st, r = self.request("POST", "/v1/vault", body)
        self.assertEqual(st, 201, r)
        return r["item"]

    def test_01_hints_for_app_only(self):
        a = self._add({"kind": "login", "site": "github.com", "username": "fake1", "password": WEAK})
        b = self._add({"kind": "login", "site": "github.com", "username": "fake2", "password": WEAK})
        c = self._add({"kind": "login", "site": "example.com", "username": "fake3", "password": STRONG})
        self._add({"kind": "card", "name": "FAKE HOLDER", "number": "4111111111111111", "expiry": "3/27", "cvv": "123"})
        self._add({"kind": "contact", "name": "假名字", "addresses": [{"line1": "示例路 9 号", "city": "示例市", "default": True}]})
        items = {i.get("username") or i["kind"]: i for i in self.request("GET", "/v1/vault")[1]["items"]}
        self.assertTrue(items["fake1"]["pw_weak"] and items["fake1"]["pw_reused"])
        self.assertTrue(items["fake2"]["pw_reused"])
        self.assertFalse(items["fake3"]["pw_weak"] or items["fake3"]["pw_reused"])
        self.assertEqual(items["card"]["expiry_hint"], "03/27")
        self.assertEqual(items["contact"]["address_hint"], "示例路 9 号 示例市")
        listing = json.dumps(self.request("GET", "/v1/vault")[1], ensure_ascii=False)
        for s in (WEAK + '"', STRONG, "4111111111111111", '"123"'):
            self.assertNotIn(s, listing)
        # 搜索覆盖提示字段（不覆盖机密）
        self.assertEqual(len(self.request("GET", "/v1/vault?q=" + quote("示例路"))[1]["items"]), 1)
        self.assertEqual(len(self.request("GET", "/v1/vault?q=" + quote(STRONG))[1]["items"]), 0)
        # 模型那边看不到提示
        out = cloud_vault.for_model(items["contact"])
        self.assertNotIn("address_hint", out)
        self.assertNotIn("expiry_hint", cloud_vault.for_model(items["card"]))
        self.assertNotIn("pw_weak", cloud_vault.for_model(items["fake1"]))
        for x in (a, b, c):
            self.assertNotIn("pw_weak", x)   # 单项接口不算提示

    def test_02_secure_note(self):
        n = self._add({"kind": "note", "title": "门禁", "body": "假的门禁密码 FakeGate-7788"})
        self.assertEqual(n["kind"], "note")
        listing = json.dumps(self.request("GET", "/v1/vault")[1], ensure_ascii=False)
        self.assertNotIn("FakeGate-7788", listing)
        rev = self.request("POST", f"/v1/vault/{n['id']}/reveal", {})[1]
        self.assertEqual(rev["secret"]["body"], "假的门禁密码 FakeGate-7788")
        self.assertFalse(cloud_vault.for_model(n)["allowed"])
        self.assertEqual(cloud_vault.fill_fields("note", n, {"body": "x"}), {})
        # 备注内容会被防泄漏替换
        cloud_vault._invalidate()
        self.assertNotIn("FakeGate-7788", cloud_vault.redact("备注是：假的门禁密码 FakeGate-7788。"))

    def test_03_allowed_bots(self):
        it = self._add({"kind": "login", "site": "shop.example.com", "username": "buyer", "password": STRONG,
                        "allowed_bots": ["shopper"]})
        self.assertEqual(it["allowed_bots"], ["shopper"])
        self.assertTrue(cloud_vault.bot_allowed(it, "shopper"))
        self.assertFalse(cloud_vault.bot_allowed(it, "boss"))
        self.assertEqual(self.request("POST", "/v1/vault", {"kind": "login", "site": "x.com", "password": "p",
                                                           "allowed_bots": ["bad id!"]})[0], 400)
        # 总管 Bot 调 vault_fill 被拒，并记一条失败使用记录
        model = "vault-allow-model"
        steps = [lambda d: ("vault_fill", {"id": it["id"]})]
        def script(d):
            n = len(tool_turns(d))
            return tool_call(f"c{n}", *steps[n](d)) if n < len(steps) else {"role": "assistant", "content": "好"}
        FakeModelHandler.scripts[model] = script
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        tid = self.submit(sid, "登录商店", model)[1]["task_id"]
        final = self.wait_status(tid, {"completed"}, timeout=30)
        results = [e["payload"]["result"] for e in final["events"] if e["type"] == "tool_result"]
        self.assertTrue(any("只允许指定的 Bot" in json.dumps(r, ensure_ascii=False) for r in results), results)
        uses = self.request("GET", f"/v1/vault/uses?item_id={it['id']}")[1]["items"]
        self.assertTrue(uses and not uses[0]["ok"])
        # 改回所有 Bot
        upd = self.request("PUT", f"/v1/vault/{it['id']}", {"allowed_bots": []})[1]["item"]
        self.assertIsNone(upd.get("allowed_bots"))

    def test_weak_rule(self):
        self.assertTrue(cloud_vault.password_weak("short1A!"))
        self.assertTrue(cloud_vault.password_weak("alllowercaseletters"))
        self.assertFalse(cloud_vault.password_weak(STRONG))


if __name__ == "__main__":
    unittest.main()
