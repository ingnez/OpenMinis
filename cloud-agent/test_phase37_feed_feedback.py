import time

from test_phase1_support import CloudServerTestCase


class FeedFeedbackTests(CloudServerTestCase):
    def test_01_like_and_comment_become_bot_rule_memory(self):
        self.request("PUT", "/v1/bots/fbbot", {"name": "简报", "instructions": "x"})
        conn = self.srv.get_db_connection()
        try:
            now = time.time()
            conn.execute("INSERT INTO routines (routine_id, name, prompt, schedule, credential, model, enabled, run_count, notify, created_at, updated_at, persona_id) "
                         "VALUES ('rtn_fb000000001', '每日简报', 'p', '{}', 'c', 'm', 1, 0, 1, ?, ?, 'fbbot')", (now, now))
            conn.execute("INSERT INTO routine_runs (run_id, routine_id, task_id, session_id, trigger, status, result, error, started_at, finished_at) "
                         "VALUES ('run_fb0000000001', 'rtn_fb000000001', NULL, 'sess_x', 'schedule', 'completed', '今日要闻三条：A、B、C', NULL, ?, ?)", (now, now))
            conn.commit()
        finally:
            conn.close()
        self.assertEqual(self.request("POST", "/v1/feed/run_fb0000000001/feedback", {"liked": 2})[0], 400)
        self.assertEqual(self.request("POST", "/v1/feed/run_nope00000000/feedback", {"liked": 1})[0], 404)
        st, r = self.request("POST", "/v1/feed/run_fb0000000001/feedback", {"liked": 1, "comment": "医学新闻多一点"})
        self.assertEqual(st, 200, r)
        item = next(i for i in self.request("GET", "/v1/feed")[1]["items"] if i["run_id"] == "run_fb0000000001")
        self.assertEqual((item["liked"], item["comment"]), (1, "医学新闻多一点"))

        def mems():
            conn = self.srv.get_db_connection()
            try:
                return [r[0] for r in conn.execute("SELECT content FROM memory_entries WHERE persona = 'fbbot' AND source = 'feedback'")]
            finally:
                conn.close()
        m = mems()
        self.assertEqual(len(m), 1)
        self.assertIn("👍", m[0])
        self.assertIn("医学新闻多一点", m[0])
        self.request("POST", "/v1/feed/run_fb0000000001/feedback", {"liked": -1, "comment": ""})
        m = mems()
        self.assertEqual(len(m), 1)          # 替换，不累积
        self.assertIn("👎", m[0])
        self.request("POST", "/v1/feed/run_fb0000000001/feedback", {"liked": 0, "comment": ""})
        self.assertEqual(mems(), [])         # 取消反馈就删掉
