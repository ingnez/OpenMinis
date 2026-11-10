#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 22：保管库（登录 / 卡片 / 联系信息）。全部用假数据；核对机密不进模型请求、对话记录、事件、日志和通知。"""

import base64
import contextlib
import io
import json
import sqlite3
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns

FAKE_PW = "FakePass-9f3k2Lq"
FAKE_TOTP = "JBSWY3DPEHPK3PXP"
FAKE_CARD = "4111111111111111"
FAKE_CVV = "737"


class FakeBrowser:
    """替身：代替真实 Chromium，记录服务器交给浏览器的值，模拟页面地址。"""
    def __init__(self, url="https://login.example.com/signin", text=""):
        self.url, self.text, self.calls = url, text, []

    def __call__(self, key, ws, args, owner=None, display=None):
        self.calls.append(args)
        if args.get("action") == "__vault_fill__":
            if args.get("site_key") and args["site_key_fn"](self.url) != args["site_key"]:
                return {"error": "当前页面和保管库条目的网站不一致", "page_host": "evil.test"}
            return {"status": "ok", "filled": list(args["fields"]), "not_found": [], "page_host": "login.example.com"}
        if args.get("action") == "get_text":
            return {"status": "ok", "action": "get_text", "text": self.text}
        return {"status": "ok", "action": args.get("action")}


def ids_from(d):
    for m in tool_turns(d):
        try:
            res = json.loads(m["content"])
        except ValueError:
            continue
        if res.get("items"):
            return [i["id"] for i in res["items"]]
    return []


class VaultTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True})
        self.request("PUT", "/v1/bots/shopper", {"name": "购物", "instructions": "你帮我买东西"})
        for it in self.request("GET", "/v1/vault")[1]["items"]:
            self.request("DELETE", f"/v1/vault/{it['id']}")
        self._orig = self.srv.cloud_browser.execute_browser_action

    def tearDown(self):
        self.srv.cloud_browser.execute_browser_action = self._orig

    def _login(self, **extra):
        body = {"kind": "login", "site": "https://www.example.com/login", "username": "fake.user@example.com",
                "password": FAKE_PW, "totp": FAKE_TOTP, "notes": "假账号"}
        body.update(extra)
        st, res = self.request("POST", "/v1/vault", body)
        self.assertEqual(st, 201, res)
        return res["item"]

    def _run(self, bot, steps, model, prompt="去保管库调用 example.com 的账号登录"):
        def script(d):
            n = len(tool_turns(d))
            if n < len(steps):
                name, args = steps[n](d)
                return tool_call(f"c{n}", name, args)
            return {"role": "assistant", "content": "已登录"}
        FakeModelHandler.scripts[model] = script
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": bot})[1]["session_id"]
        tid = self.submit(sid, prompt, model)[1]["task_id"]
        final = self.wait_status(tid, {"completed"}, timeout=30)
        return sid, [e["payload"]["result"] for e in final["events"] if e["type"] == "tool_result"], final

    def _db_text(self):
        conn = sqlite3.connect(self.srv.DB_PATH)
        try:
            return "\n".join(conn.iterdump())
        finally:
            conn.close()

    def test_01_crud_masks_secrets(self):
        login = self._login()
        self.assertEqual(login["site"], "example.com")
        self.assertTrue(login["has_totp"])
        st, card = self.request("POST", "/v1/vault", {"kind": "card", "name": "FAKE HOLDER", "number": "4111 1111 1111 1111",
                                                     "expiry": "8/29", "cvv": FAKE_CVV})
        self.assertEqual(st, 201, card)
        self.assertEqual((card["item"]["last4"], card["item"]["brand"]), ("1111", "Visa"))
        st, contact = self.request("POST", "/v1/vault", {"kind": "contact", "name": "测试用户", "phone": "+86 100 0000 0000",
                                                        "email": "fake@example.com", "is_default": True,
                                                        "addresses": [{"label": "家", "line1": "测试路 1 号", "city": "上海"}]})
        self.assertEqual(st, 201, contact)
        listing = json.dumps(self.request("GET", "/v1/vault")[1], ensure_ascii=False)
        # 2.31.0 起 App 列表带默认地址提示（只给 App，不给模型，见 test_phase44），密码 / 卡号 / CVV 仍不出现
        for s in (FAKE_PW, FAKE_TOTP, FAKE_CARD, FAKE_CVV + '"'):
            self.assertNotIn(s, listing)
        self.assertEqual(len(self.request("GET", "/v1/vault?kind=card")[1]["items"]), 1)
        self.assertEqual(len(self.request("GET", "/v1/vault?q=login.example.com")[1]["items"]), 1)
        # 数据库里只有密文
        self.assertNotIn(FAKE_PW, self._db_text())
        self.assertNotIn(FAKE_CARD, self._db_text())
        # App 查看（Face ID 之后）：能拿到原值，并记一条使用记录
        st, rev = self.request("POST", f"/v1/vault/{card['item']['id']}/reveal", {})
        self.assertEqual((st, rev["secret"]["number"], rev["secret"]["expiry"]), (200, FAKE_CARD, "08/29"))
        # 修改时不带密码 = 保持不变
        self.request("PUT", f"/v1/vault/{login['id']}", {"username": "other.user", "allow_bots": False})
        rev = self.request("POST", f"/v1/vault/{login['id']}/reveal", {})[1]
        self.assertEqual((rev["item"]["username"], rev["item"]["allow_bots"], rev["secret"]["password"]), ("other.user", False, FAKE_PW))
        self.assertEqual(self.request("POST", "/v1/vault", {"kind": "card", "number": "12ab"})[0], 400)
        self.assertEqual(self.request("DELETE", f"/v1/vault/{login['id']}")[0], 200)
        self.assertEqual(self.request("GET", f"/v1/vault/{login['id']}")[0], 404)

    def test_02_bot_fills_without_seeing_secret(self):
        item = self._login()
        browser = FakeBrowser()
        self.srv.cloud_browser.execute_browser_action = browser
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            sid, res, final = self._run("shopper", [
                lambda d: ("vault_list", {"kind": "login", "query": "https://login.example.com/"}),
                lambda d: ("vault_fill", {"id": ids_from(d)[0]}),
                lambda d: ("vault_totp", {"id": ids_from(d)[0]}),
            ], "m-v2")
        self.assertEqual(res[0]["items"][0]["id"], item["id"])
        self.assertEqual(res[0]["items"][0]["username"], "fake.user@example.com")
        self.assertEqual(sorted(res[1]["filled"]), ["password", "username"])
        self.assertEqual(res[2]["filled"], ["totp"])
        fills = [c for c in browser.calls if c.get("action") == "__vault_fill__"]
        self.assertEqual(fills[0]["fields"]["password"], FAKE_PW)
        code = fills[1]["fields"]["totp"]
        self.assertRegex(code, r"^\d{6}$")
        self.assertEqual(fills[0]["site_key"], "example.com")
        tools = {t["function"]["name"] for t in FakeModelHandler.requests[0].get("tools") or []}
        self.assertTrue({"vault_list", "vault_fill"} <= tools)
        # 模型请求、对话记录、事件、服务器输出里都没有机密
        model_traffic = json.dumps(FakeModelHandler.requests, ensure_ascii=False)
        st, hist = self.request("GET", f"/v1/sessions/{sid}")
        self.assertEqual(st, 200)
        self.assertGreater(len(hist["messages"]), 3)
        history = json.dumps(hist, ensure_ascii=False)
        events = json.dumps(final, ensure_ascii=False)
        for blob in (model_traffic, history, events, self._db_text(), out.getvalue(), err.getvalue()):
            self.assertNotIn(FAKE_PW, blob)
            self.assertNotIn(FAKE_TOTP, blob)
            self.assertNotIn('"' + code + '"', blob)
        uses = self.request("GET", f"/v1/vault/uses?item_id={item['id']}")[1]["items"]
        self.assertEqual([(u["action"], u["actor"], u["ok"]) for u in uses],
                         [("vault_totp", "shopper", True), ("vault_fill", "shopper", True)])
        self.assertEqual(uses[0]["target"], "login.example.com")

    def test_03_leaks_are_redacted(self):
        self._login()
        self.request("POST", "/v1/vault", {"kind": "card", "number": FAKE_CARD, "expiry": "08/29", "cvv": FAKE_CVV})
        self.srv.cloud_browser.execute_browser_action = FakeBrowser(text=f"Your password: {FAKE_PW} card 4111 1111 1111 1111")
        FakeModelHandler.scripts["m-v3"] = lambda d: tool_call("c0", "browser_action", {"action": "get_text"}) if not tool_turns(d) \
            else {"role": "assistant", "content": f"卡号是 {FAKE_CARD}"}
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "shopper"})[1]["session_id"]
        tid = self.submit(sid, "看看页面", "m-v3")[1]["task_id"]
        final = self.wait_status(tid, {"completed"}, timeout=30)
        model_traffic = json.dumps(FakeModelHandler.requests, ensure_ascii=False)
        self.assertNotIn(FAKE_PW, model_traffic)
        self.assertNotIn("4111 1111 1111 1111", model_traffic)
        self.assertIn("[保管库已隐藏]", model_traffic)
        st, hist = self.request("GET", f"/v1/sessions/{sid}")
        self.assertEqual(st, 200)
        self.assertGreater(len(hist["messages"]), 3)
        history = json.dumps(hist, ensure_ascii=False)
        self.assertNotIn(FAKE_CARD, history)
        self.assertNotIn(FAKE_CARD, json.dumps(final, ensure_ascii=False))
        # 模型不能直接调内部填写动作
        res = self.srv.tool_browser_action("t", sid, {"action": "__vault_fill__", "fields": {}})
        self.assertIn("Unsupported", res["error"])

    def test_04_permission_and_domain_checks(self):
        item = self._login(allow_bots=False)
        self.srv.cloud_browser.execute_browser_action = FakeBrowser()
        _sid, res, _ = self._run("shopper", [lambda d: ("vault_fill", {"id": item["id"]})], "m-v4a")
        self.assertIn("允许 Bot 使用", res[0]["error"])
        self.request("PUT", f"/v1/vault/{item['id']}", {"allow_bots": True})
        self.srv.cloud_browser.execute_browser_action = FakeBrowser(url="https://example.com.evil.test/login")
        _sid, res, _ = self._run("shopper", [lambda d: ("vault_fill", {"id": item["id"]})], "m-v4b")
        self.assertIn("不一致", res[0]["error"])
        uses = self.request("GET", "/v1/vault/uses")[1]["items"]
        self.assertFalse(uses[0]["ok"])
        self.assertFalse(uses[1]["ok"])
        # 主 Bot 的 admin_api 也碰不到保管库接口
        self.assertIn("不能由 Bot 调用", self.srv._admin_api("POST", f"/v1/vault/{item['id']}/reveal", {})["error"])

    def test_05_csv_import(self):
        chrome = "name,url,username,password,note\nExample,https://accounts.example.org/,fake1,FakeImport-111,\n"
        st, res = self.request("POST", "/v1/vault/import", {"csv": chrome})
        self.assertEqual((st, res["imported"]), (200, 1))
        bitwarden = ("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n"
                     ",,login,Shop,,,,https://shop.example.net,fake2,FakeImport-222," + FAKE_TOTP + "\n"
                     ",,note,Secure note,hello,,,,,,\n")
        res = self.request("POST", "/v1/vault/import", {"csv": bitwarden})[1]
        self.assertEqual((res["imported"], res["skipped"]), (1, 1))
        sites = {i.get("site") for i in self.request("GET", "/v1/vault?kind=login")[1]["items"]}
        self.assertEqual(sites, {"accounts.example.org", "shop.example.net"})
        self.assertEqual(self.request("POST", "/v1/vault/import", {"csv": "a,b\n1,2\n"})[0], 400)


class VaultUnitTests(unittest.TestCase):
    def test_totp_rfc6238_and_site_key(self):
        import cloud_vault
        seed = base64.b32encode(b"12345678901234567890").decode()
        self.assertEqual(cloud_vault.totp_code(seed, at=59)[0], "287082")
        self.assertEqual(cloud_vault.totp_code("otpauth://totp/x?secret=" + seed, at=1111111109)[0], "081804")
        self.assertEqual(cloud_vault.site_key("https://a.b.example.co.uk/x"), "example.co.uk")
        self.assertEqual(cloud_vault.site_key("login.example.com"), "example.com")
        self.assertNotEqual(cloud_vault.site_key("example.com.evil.test"), "example.com")


if __name__ == "__main__":
    unittest.main()
