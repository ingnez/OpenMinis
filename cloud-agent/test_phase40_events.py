import time
from email.message import EmailMessage

import cloud_events
from test_phase1_support import CloudServerTestCase, FakeModelHandler


def _routine(srv, rid):
    conn = srv.get_db_connection()
    try:
        now = time.time()
        conn.execute("INSERT INTO routines (routine_id, name, prompt, schedule, credential, model, enabled, run_count, notify, created_at, updated_at) "
                     "VALUES (?, '处理事件', '看看发生了什么', '{\"kind\": \"interval\", \"seconds\": 999999}', 'evcred', 'm-ev', 0, 0, 0, ?, ?)", (rid, now, now))
        conn.commit()
    finally:
        conn.close()


class EventTriggerTests(CloudServerTestCase):
    def test_01_github_first_poll_baseline_then_fire(self):
        self.request("PUT", "/v1/credentials/evcred", {"api_key": "sk-ev-fake-0000000000000000", "base_url": self.model_base})
        _routine(self.srv, "rtn_ev0000000001")
        seen = []
        FakeModelHandler.scripts["m-ev"] = lambda d: seen.append(d["messages"][-1]["content"]) or {"role": "assistant", "content": "收到"}
        self.assertEqual(self.request("POST", "/v1/event-triggers", {"kind": "github", "config": {"repo": "bad"}, "routine_id": "rtn_ev0000000001"})[0], 400)
        self.assertEqual(self.request("POST", "/v1/event-triggers", {"kind": "github", "config": {"repo": "a/b"}, "routine_id": "rtn_nope"})[0], 400)
        st, r = self.request("POST", "/v1/event-triggers", {"kind": "github", "config": {"repo": "octo/demo", "events": ["issues"], "token": "ghp_FAKEFAKEFAKEFAKEFAKE1234"},
                                                          "routine_id": "rtn_ev0000000001"})
        self.assertEqual(st, 200, r)
        tid = r["trigger"]["id"]
        self.assertNotIn("ghp_", str(r))
        feed = [[{"id": "100", "type": "IssuesEvent", "actor": {"login": "x"}, "payload": {"action": "opened", "issue": {"number": 1, "title": "旧的"}}}]]
        headers_seen = []

        def fake(url, headers):
            headers_seen.append(headers)
            return feed[0]
        orig = self.srv.EVENT_FETCHERS["github"]
        self.srv.EVENT_FETCHERS["github"] = fake
        try:
            self.assertEqual(self.srv.events_check(wait=True)[tid], [])        # 第一次只记位置
            feed[0] = [{"id": "102", "type": "IssuesEvent", "actor": {"login": "y"}, "payload": {"action": "opened", "issue": {"number": 7, "title": "登录崩溃"}}},
                       {"id": "101", "type": "WatchEvent", "payload": {}}] + feed[0]
            self.assertEqual(self.srv.events_check(wait=True), {})             # 没到 5 分钟
            got = self.srv.events_check(now=time.time() + 400, wait=True)[tid]
        finally:
            self.srv.EVENT_FETCHERS["github"] = orig
        self.assertEqual(len(got), 1)
        self.assertIn("Issue #7 opened：登录崩溃", got[0])
        self.assertEqual(headers_seen[0]["Authorization"], "Bearer ghp_FAKEFAKEFAKEFAKEFAKE1234")
        self.wait_until(lambda: any("登录崩溃" in c for c in seen), message=str(seen))
        t = self.request("GET", "/v1/event-triggers")[1]["triggers"][0]
        self.assertEqual((t["fired_count"], t["cursor"]), (1, "102"))
        self.assertEqual(self.request("DELETE", f"/v1/event-triggers/{tid}")[0], 200)

    def test_02_email_filter_and_telegram_keyword(self):
        _routine(self.srv, "rtn_ev0000000002")
        trig = {"config": {"host": "imap.example.com", "user": "u", "from": "hospital", "subject": ""}, "cursor": ""}

        def mail(frm, subj, body):
            m = EmailMessage()
            m["From"], m["Subject"] = frm, subj
            m.set_content(body)
            return m.as_bytes()
        msgs = [(5, mail("a@x.com", "广告", "买买买"))]
        self.assertEqual(cloud_events.poll_email(trig, "pw", fetch=lambda c, p, s: msgs), ([], "5"))
        trig["cursor"] = "5"
        msgs = [(6, mail("a@x.com", "广告", "买")), (7, mail("排班 <duty@hospital.org>", "下周排班", "周三夜班"))]
        items, cur = cloud_events.poll_email(trig, "pw", fetch=lambda c, p, s: msgs)
        self.assertEqual(cur, "7")
        self.assertEqual(len(items), 1)
        self.assertIn("下周排班", items[0])
        conn = self.srv.get_db_connection()
        try:
            cloud_events.create(conn, "telegram", {"keywords": ["急会诊"]}, "rtn_ev0000000002")
        finally:
            conn.close()
        launched = []
        orig = self.srv.launch_routine_run
        self.srv.launch_routine_run = lambda r, trig, context=None: launched.append((trig, context)) or {"run_id": "x"}
        try:
            self.assertEqual(self.srv.events_on_telegram("普通消息"), 0)
            self.assertEqual(self.srv.events_on_telegram("3 床急会诊"), 1)
        finally:
            self.srv.launch_routine_run = orig
        self.assertEqual(launched[0][0], "event:telegram")
        self.assertIn("3 床急会诊", launched[0][1])
