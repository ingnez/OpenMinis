"""从旧版本服务器的数据库升级：旧库（2.0.0 / 2.4.0 的服务器真实生成，见 testdata/*.sql）
经当前 init_db 迁移后，主要接口不报错、旧数据还在、新接口可用。"""
import os
import sqlite3
import unittest

from test_phase1_support import CloudServerTestCase

HERE = os.path.dirname(os.path.abspath(__file__))


class _UpgradeBase(CloudServerTestCase):
    fixture = ""
    old_session = ""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        path = os.path.join(cls.tmp.name, "legacy.db")
        conn = sqlite3.connect(path)
        with open(os.path.join(HERE, "testdata", cls.fixture), encoding="utf-8") as f:
            conn.executescript(f.read())
        conn.close()
        cls.srv.DB_PATH = path
        cls.srv.init_db()
        cls.srv.init_db()   # 迁移要能重复执行（每次重启都会跑）

    def test_01_endpoints_after_upgrade(self):
        for path in ("/v1/sessions", f"/v1/sessions/{self.old_session}", "/v1/bots", "/v1/routines", "/v1/resources",
                     "/v1/search?q=%E5%8D%87%E7%BA%A7", "/v1/notifications?after=0&wait=0", "/v1/groups", "/v1/feed",
                     "/v1/usage", "/v1/audit"):
            st, body = self.request("GET", path)
            self.assertLess(st, 500, f"{path}: {body}")
        msgs = self.request("GET", f"/v1/sessions/{self.old_session}")[1].get("messages", [])
        self.assertIn("升级前的消息", [m.get("content") for m in msgs])

    def test_02_new_features_on_old_data(self):
        st, body = self.request("POST", f"/v1/sessions/{self.old_session}/transcript",
                                {"lines": [{"role": "user", "text": "升级后"}]})
        self.assertEqual((st, body.get("saved")), (200, 1))
        st, body = self.request("POST", "/v1/sessions", {"title": "无痕", "incognito": True})
        self.assertLess(st, 400, body)


class UpgradeFrom200(_UpgradeBase):
    fixture = "legacy_2.0.0.sql"
    old_session = "sess_d15be0ab9a4e"


class UpgradeFrom240(_UpgradeBase):
    fixture = "legacy_2.4.0.sql"
    old_session = "sess_d2aea712c4d2"

    def test_03_old_bot_still_there(self):
        st, body = self.request("GET", "/v1/bots/oldbot")
        self.assertEqual(st, 200, body)
        self.assertEqual(self.request("GET", "/v1/bots/oldbot/library")[0], 200)


del _UpgradeBase

if __name__ == "__main__":
    unittest.main()
