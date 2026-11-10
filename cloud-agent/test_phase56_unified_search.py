"""统一搜索（2.43.0）：页面、例行任务、保管库标题出现在搜索里；保管库结果不含密码 / 用户名（假数据）"""
import json
import cloud_pages
from test_phase1_support import CloudServerTestCase

FAKE_PW = "Fake-Pass-ZZ-0000"


class UnifiedSearchTests(CloudServerTestCase):
    def test_pages_routines_vault(self):
        self.request("PUT", "/v1/credentials/us", {"api_key": "sk-unified-search-0000000000", "base_url": self.model_base})
        st, r = self.request("POST", "/v1/routines", {"model": "m-x", "credential": "us", "enabled": False, "name": "查房提醒甲乙丙",
                                                       "prompt": "每天早上整理示例病区", "schedule": {"kind": "interval", "seconds": 3600}})
        self.assertIn(st, (200, 201), r)
        st, v = self.request("POST", "/v1/vault", {"kind": "login", "title": "示例系统甲乙丙", "site": "https://example.com",
                                                   "username": "fake.user@example.com", "password": FAKE_PW})
        self.assertEqual(st, 201, v)
        conn = self.srv.get_db_connection()
        try:
            cloud_pages.ensure_schema(conn)
            cloud_pages.write(conn, "甲乙丙交班页", "<p>示例内容</p>")
        finally:
            conn.close()
        st, res = self.request("GET", "/v1/search?q=%E7%94%B2%E4%B9%99%E4%B8%99")
        self.assertEqual(st, 200)
        kinds = {x["type"]: x for x in res["results"]}
        self.assertEqual(kinds["routine"]["title"], "查房提醒甲乙丙")
        self.assertEqual(kinds["page"]["title"], "甲乙丙交班页")
        self.assertEqual(kinds["vault"]["title"], "示例系统甲乙丙")
        self.assertEqual(kinds["vault"]["snippet"], "登录")
        blob = json.dumps(res, ensure_ascii=False)
        self.assertNotIn(FAKE_PW, blob)
        self.assertNotIn("fake.user@example.com", blob)
        # 只按标题搜保管库：搜用户名搜不到
        st, res2 = self.request("GET", "/v1/search?q=fake.user")
        self.assertFalse([x for x in res2["results"] if x["type"] == "vault"])
