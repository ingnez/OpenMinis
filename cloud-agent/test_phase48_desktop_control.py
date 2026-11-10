#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 48：云电脑接管 / 交还（Bot 暂停）、取回剪贴板、从保管库安全粘贴、全尺寸截图参数。全部假数据。"""

import json
import unittest

import cloud_desktop_control as dc
from test_phase1_support import CloudServerTestCase

FAKE_PW = "FAKE-desk-pw-000"


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class LeaseTests(unittest.TestCase):
    def test_lease_expires_and_release(self):
        c = Clock()
        ctl = dc.DesktopControl(clock=c)
        self.assertFalse(ctl.held(None))
        ctl.hold(None)
        self.assertTrue(ctl.held(":99"))     # None 视为主屏
        self.assertFalse(ctl.held(":11"))
        c.t += dc.LEASE_S - 1
        self.assertTrue(ctl.held(None))
        c.t += 2
        self.assertFalse(ctl.held(None))     # 手机 45 秒没续：自动失效，Bot 不会被卡死
        ctl.hold(":11")
        ctl.release(":11")
        self.assertFalse(ctl.held(":11"))

    def test_wait_free(self):
        c = Clock()
        ctl = dc.DesktopControl(clock=c)
        ctl.hold(None, lease=300)
        def sleep(_s):
            c.t += 10
        ok, waited = ctl.wait_free(None, max_wait=30, sleep=sleep)
        self.assertFalse(ok)
        self.assertGreaterEqual(waited, 30)
        ticks = []
        def sleep_then_release(_s):
            ticks.append(1)
            c.t += 1
            if len(ticks) == 3:
                ctl.release(None)
        self.assertTrue(ctl.wait_free(None, max_wait=30, sleep=sleep_then_release)[0])
        ctl.hold(None, lease=300)
        self.assertFalse(ctl.wait_free(None, cancelled=lambda: True, sleep=sleep)[0])


class DesktopControlServerTests(CloudServerTestCase):
    def setUp(self):
        self._orig = (self.srv.cloud_desktop.is_desktop_available, self.srv.cloud_desktop.read_clipboard,
                      self.srv._vault_type_desktop, self.srv.cloud_desktop_control.MAX_WAIT_S)
        self.typed = []
        self.srv.cloud_desktop.is_desktop_available = lambda: True
        self.srv.cloud_desktop.read_clipboard = lambda display: ("远端剪贴板 fake text", None)
        self.srv._vault_type_desktop = lambda sid, values, display=None: (self.typed.append((sid, values, display)) or
                                                                           {"status": "ok", "filled": [n for n, _ in values]})

    def tearDown(self):
        (self.srv.cloud_desktop.is_desktop_available, self.srv.cloud_desktop.read_clipboard,
         self.srv._vault_type_desktop, self.srv.cloud_desktop_control.MAX_WAIT_S) = self._orig
        self.srv.DESK_CONTROL.release(self.srv.cloud_displays.MAIN_DISPLAY)

    def test_01_hold_pauses_bot_tools(self):
        self.assertEqual(self.request("POST", "/v1/desktop/control", {"hold": "yes"})[0], 400)
        st, r = self.request("POST", "/v1/desktop/control", {"hold": True})
        self.assertEqual((st, r["held"], r["display"], r["lease_s"]), (200, True, self.srv.cloud_displays.MAIN_DISPLAY, dc.LEASE_S))
        sid = self.new_session()
        self.srv.cloud_desktop_control.MAX_WAIT_S = 0.2
        called = []
        orig = self.srv.cloud_desktop.execute_desktop_action
        self.srv.cloud_desktop.execute_desktop_action = lambda *a, **k: called.append(a) or {"status": "ok"}
        try:
            res = self.srv.tool_desktop_action("task_fakectl01", sid, {"action": "click", "x": 1, "y": 2})
            self.assertTrue(res.get("paused"), res)
            self.assertIn("接管", res["note"])
            self.assertEqual(called, [])
            self.assertEqual(self.request("POST", "/v1/desktop/control", {"hold": False})[1]["held"], False)
            self.assertEqual(self.srv.tool_desktop_action("task_fakectl01", sid, {"action": "click", "x": 1, "y": 2}), {"status": "ok"})
            self.assertEqual(len(called), 1)
        finally:
            self.srv.cloud_desktop.execute_desktop_action = orig

    def test_02_clipboard_get(self):
        st, r = self.request("POST", "/v1/desktop/input", {"action": "clipboard_get"})
        self.assertEqual((st, r["text"]), (200, "远端剪贴板 fake text"))
        self.assertEqual(self.request("POST", "/v1/desktop/input", {"action": "click"})[0], 400)

    def test_03_vault_paste_never_returns_secret(self):
        st, item = self.request("POST", "/v1/vault", {"kind": "login", "title": "假站点", "site": "https://login.example.com",
                                                     "username": "fake.user@example.com", "password": FAKE_PW})
        self.assertEqual(st, 201, item)
        iid = item["item"]["id"]
        st, r = self.request("POST", "/v1/desktop/input", {"action": "vault", "item_id": iid})
        self.assertEqual((st, r["status"], r["field"]), (200, "ok", "password"))
        self.assertNotIn(FAKE_PW, json.dumps(r, ensure_ascii=False))
        self.assertEqual(self.typed[-1], (None, [("password", FAKE_PW)], self.srv.cloud_displays.MAIN_DISPLAY))
        st, r = self.request("POST", "/v1/desktop/input", {"action": "vault", "item_id": iid, "field": "username"})
        self.assertEqual(self.typed[-1][1], [("username", "fake.user@example.com")])
        self.assertEqual(self.request("POST", "/v1/desktop/input", {"action": "vault", "item_id": iid, "field": "cvv"})[0], 400)
        self.assertEqual(self.request("POST", "/v1/desktop/input", {"action": "vault", "item_id": "nope"})[0], 404)
        self.assertEqual(self.request("POST", "/v1/desktop/input", {"action": "vault", "item_id": iid, "field": "totp"})[0], 400)
        uses = self.request("GET", f"/v1/vault/uses?item_id={iid}")[1]["items"]
        self.assertEqual([(u["action"], u["actor"]) for u in uses][:2], [("phone_desktop_paste", "phone")] * 2)

    def test_04_thumbnail_width(self):
        widths = []
        orig = self.srv.cloud_desktop.thumbnail
        self.srv.cloud_desktop.thumbnail = lambda display, width=480, max_age=2.5: (widths.append(width) or b"\xff\xd8fake", "image/jpeg")
        try:
            self.assertEqual(self.request("GET", "/v1/desktop/thumbnail?width=9999")[0], 200)
            self.assertEqual(self.request("GET", "/v1/desktop/thumbnail")[0], 200)
            self.assertEqual(self.request("GET", "/v1/desktop/thumbnail?width=abc")[0], 400)
        finally:
            self.srv.cloud_desktop.thumbnail = orig
        self.assertEqual(widths, [1920, 480])


if __name__ == "__main__":
    unittest.main()
