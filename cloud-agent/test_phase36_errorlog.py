from test_phase1_support import CloudServerTestCase, FakeModelHandler


class ErrorLogTests(CloudServerTestCase):
    def test_01_errors_are_listed_and_scrubbed(self):
        FakeModelHandler.scripts["m-broken"] = lambda d: {"_status": 401, "error": {"message": "invalid key sk-abcdefFAKE0000000000000000"}}
        sid = self.new_session()
        res = self.wait_status(self.submit(sid, "你好", "m-broken")[1]["task_id"], ("failed", "completed"), timeout=30)
        self.assertEqual(res["status"], "failed")
        self.srv.note_server_error("test", RuntimeError("boom Bearer abcdefghijklmnopqrstuvwxyz"))
        st, r = self.request("GET", "/v1/logs/errors")
        self.assertEqual(st, 200)
        kinds = {e["kind"] for e in r["errors"]}
        self.assertEqual(kinds, {"task", "server"})
        blob = str(r)
        self.assertNotIn("FAKE0000000000000000", blob)
        self.assertNotIn("abcdefghijklmnopqrstuvwxyz", blob)
        self.assertNotIn("你好", blob)      # 不带对话内容
        self.assertEqual(r["version"], self.srv.AGENT_VERSION)
