import time

from test_phase1_support import CloudServerTestCase, FakeModelHandler


class WeeklyReviewTests(CloudServerTestCase):
    def test_01_stats_filled_into_routine_prompt(self):
        self.request("PUT", "/v1/bots/wkbot", {"name": "周报", "instructions": "x"})
        FakeModelHandler.scripts["m-wk"] = lambda d: {"role": "assistant", "content": "回答一"}
        st, r = self.request("POST", "/v1/sessions", {"persona_id": "wkbot"})
        sid = r["session_id"]
        self.wait_status(self.submit(sid, "问题", "m-wk")[1]["task_id"], ("completed",))
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        mid = next(m["id"] for m in msgs if m.get("role") == "assistant")
        self.assertEqual(self.request("POST", f"/v1/sessions/{sid}/messages/{mid}/reaction", {"emoji": "👎"})[0], 200)
        text = self.srv.weekly_stats("wkbot")
        self.assertIn("任务 1 个：完成 1", text)
        self.assertIn("负面表情", text)
        self.assertIn("回答一", text)
        routine = {"routine_id": "rtn_wk0000000001", "name": "每周自我改进", "prompt": "复盘：\n{{weekly_stats}}\n写规则",
                   "credential": "nope", "model": "m-wk", "persona_id": "wkbot"}
        seen = {}
        orig = self.srv.resolve_provider
        self.srv.resolve_provider = lambda *_a, **_k: ({"base_url": self.model_base, "api_key": "sk-test-fake-0000000000000"}, 200, None)
        try:
            conn = self.srv.get_db_connection()
            try:
                now = time.time()
                conn.execute("INSERT INTO routines (routine_id, name, prompt, schedule, credential, model, enabled, run_count, notify, created_at, updated_at, persona_id) "
                             "VALUES ('rtn_wk0000000001', '每周自我改进', 'p', '{}', 'nope', 'm-wk', 1, 0, 0, ?, ?, 'wkbot')", (now, now))
                conn.commit()
            finally:
                conn.close()
            FakeModelHandler.scripts["m-wk"] = lambda d: seen.setdefault("c", d["messages"][-1]["content"]) and {"role": "assistant", "content": "ok"}
            run = self.srv.launch_routine_run(routine, "manual")
            self.wait_status(run["task_id"], ("completed", "failed"))
        finally:
            self.srv.resolve_provider = orig
        self.assertIn("负面表情", seen["c"])
        self.assertNotIn("{{weekly_stats}}", seen["c"])
