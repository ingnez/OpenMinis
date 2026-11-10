"""浏览器会话快照（2.42.0）：保存 / 列表不带 cookie / 恢复把 cookie 和网页交回浏览器 / 删除（假 cookie）"""
import json
from test_phase1_support import CloudServerTestCase


class SnapshotTests(CloudServerTestCase):
    def setUp(self):
        self.calls = []
        self._orig = self.srv.cloud_browser.execute_browser_action

        def fake(key, ws, args, owner=None, display=None):
            self.calls.append((key, args))
            if args["action"] == "__snapshot__":
                return {"status": "ok", "cookies": [{"name": "sid", "value": "FAKE-COOKIE-VALUE", "domain": "example.com", "path": "/"}],
                        "tabs": ["https://example.com/inbox", "about:blank", "chrome://settings"]}
            if args["action"] == "__restore__":
                return {"status": "ok", "cookies": len(args["cookies"]), "opened": len(args["tabs"])}
            return {"error": "unexpected"}
        self.srv.cloud_browser.execute_browser_action = fake

    def tearDown(self):
        self.srv.cloud_browser.execute_browser_action = self._orig
        for m in self.request("GET", "/v1/browser/snapshots")[1]["snapshots"]:
            self.request("DELETE", f"/v1/browser/snapshots/{m['id']}")

    def test_save_list_restore_delete(self):
        st, meta = self.request("POST", "/v1/browser/snapshots", {"name": "邮箱登录"})
        self.assertEqual(st, 201, meta)
        self.assertEqual((meta["name"], meta["tabs"], meta["cookies"], meta["hosts"]), ("邮箱登录", 1, 1, ["example.com"]))
        st, lst = self.request("GET", "/v1/browser/snapshots")
        self.assertNotIn("FAKE-COOKIE-VALUE", json.dumps(lst))
        self.assertEqual([m["id"] for m in lst["snapshots"]], [meta["id"]])
        st, r = self.request("POST", f"/v1/browser/snapshots/{meta['id']}/restore", {})
        self.assertEqual((st, r["cookies"], r["opened"]), (200, 1, 1))
        restore = self.calls[-1][1]
        self.assertEqual(restore["tabs"], ["https://example.com/inbox"])
        self.assertEqual(restore["cookies"][0]["value"], "FAKE-COOKIE-VALUE")
        self.assertEqual(self.request("POST", "/v1/browser/snapshots/snap_0000000000/restore", {})[0], 404)
        self.assertEqual(self.request("DELETE", f"/v1/browser/snapshots/{meta['id']}")[0], 200)
        self.assertEqual(self.request("GET", "/v1/browser/snapshots")[1]["snapshots"], [])

    def test_browser_down(self):
        self.srv.cloud_browser.execute_browser_action = lambda *a, **k: {"error": "Playwright is not installed"}
        self.assertEqual(self.request("POST", "/v1/browser/snapshots", {})[0], 503)
