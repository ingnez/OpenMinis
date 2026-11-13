"""Paired-device metadata identifies current approvals without exporting commands."""
import json
import time

from test_phase1_support import CloudServerTestCase


class ApprovalMetadataTests(CloudServerTestCase):
    def test_metadata_excludes_commands_private_sessions_expired_and_other_bots(self):
        for bot in ("watch-test-a", "watch-test-b"):
            self.assertEqual(self.request("PUT", "/v1/bots/" + bot, {"name": bot, "instructions": "synthetic"})[0], 201)
        sid = self.request("POST", "/v1/sessions", {"title": "synthetic", "persona_id": "watch-test-a"})[1]["session_id"]
        private_sid = self.request("POST", "/v1/sessions", {"title": "private synthetic", "persona_id": "watch-test-a", "incognito": True})[1]["session_id"]
        expired_sid = self.request("POST", "/v1/sessions", {"title": "expired synthetic", "persona_id": "watch-test-a"})[1]["session_id"]
        conn = self.srv.get_db_connection()
        try:
            for n, session, age, expiry in ((0, sid, 3, 60), (1, private_sid, 4, 60), (2, expired_sid, 5, -1)):
                task = "task_metadata_" + str(n)
                conn.execute("INSERT INTO tasks(task_id,session_id,status,model,created_at) VALUES (?,?,'waiting_user','fake',?)", (task,session,time.time()-age))
                conn.execute("INSERT INTO approvals(approval_id,task_id,tool_call_id,tool,arguments,status,created_at,expires_at) "
                             "VALUES (?,?,?,'shell_execute',?,'pending',?,?)",
                             ("ap_metadata_"+str(n),task,"call",json.dumps({"command":"SYNTHETIC_PRIVATE_COMMAND"}),time.time()-age,time.time()+expiry))
            conn.commit()
        finally:
            conn.close()
        bots = self.request("GET", "/v1/bots")[1]["bots"]
        a = next(bot for bot in bots if bot["persona_id"] == "watch-test-a")
        b = next(bot for bot in bots if bot["persona_id"] == "watch-test-b")
        self.assertEqual(a["pending_approval"], {"id":"ap_metadata_0","task_id":"task_metadata_0","tool":"shell_execute"})
        self.assertNotIn("SYNTHETIC_PRIVATE_COMMAND", json.dumps(a["pending_approval"]))
        self.assertIsNone(b["pending_approval"])
        conn = self.srv.get_db_connection()
        try:
            conn.execute("UPDATE approvals SET status='denied' WHERE approval_id='ap_metadata_0'")
            conn.commit()
        finally:
            conn.close()
        a = next(bot for bot in self.request("GET", "/v1/bots")[1]["bots"] if bot["persona_id"] == "watch-test-a")
        self.assertIsNone(a["pending_approval"])
