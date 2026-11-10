"""云电脑智能键盘（2.44.0）：/v1/desktop/focus 只给类型不给内容；浏览器没开时 available=false（假浏览器）"""
import json
from test_phase1_support import CloudServerTestCase


class DesktopFocusTests(CloudServerTestCase):
    def setUp(self):
        self._orig = (self.srv.cloud_browser.execute_browser_action, self.srv.cloud_browser.is_browser_available)
        self.srv.cloud_browser.is_browser_available = lambda: True

    def tearDown(self):
        self.srv.cloud_browser.execute_browser_action, self.srv.cloud_browser.is_browser_available = self._orig

    def test_password_field(self):
        seen = []
        def fake(key, ws, args, owner=None, display=None):
            seen.append((key, args["action"]))
            return {"status": "ok", "editable": True, "password": True, "kind": "password", "value": "FAKE-SHOULD-NOT-LEAK"}
        self.srv.cloud_browser.execute_browser_action = fake
        st, r = self.request("GET", "/v1/desktop/focus")
        self.assertEqual(st, 200)
        self.assertEqual((r["editable"], r["password"], r["kind"], r["available"]), (True, True, "password", True))
        self.assertNotIn("FAKE-SHOULD-NOT-LEAK", json.dumps(r))
        self.assertEqual(seen, [("shared", "__focus__")])

    def test_no_browser(self):
        self.srv.cloud_browser.execute_browser_action = lambda *a, **k: {"status": "none", "editable": False}
        st, r = self.request("GET", "/v1/desktop/focus")
        self.assertEqual((r["editable"], r["available"]), (False, False))
        self.srv.cloud_browser.is_browser_available = lambda: False
        self.assertFalse(self.request("GET", "/v1/desktop/focus")[1]["available"])

    def test_focus_js_reads_no_values(self):
        import cloud_browser
        self.assertNotIn(".value", cloud_browser.FOCUS_JS)
