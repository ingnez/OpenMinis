from datetime import date, timedelta

import cloud_exams
from test_phase1_support import CloudServerTestCase, FakeModelHandler


class ExamTests(CloudServerTestCase):
    def test_01_crud_and_note_in_turn(self):
        day = (date.today() + timedelta(days=12)).isoformat()
        self.assertEqual(self.request("POST", "/v1/exams", {"name": "", "day": day})[0], 400)
        self.assertEqual(self.request("POST", "/v1/exams", {"name": "主治", "day": "2026-02-30"})[0], 400)
        st, r = self.request("POST", "/v1/exams", {"name": "主治医师考试", "day": day, "notes": "重症医学"})
        self.assertEqual(st, 200, r)
        eid = r["exam"]["id"]
        self.assertEqual(r["exam"]["days_left"], 12)
        st, r = self.request("PUT", f"/v1/exams/{eid}", {"notes": "重症 + 内科"})
        self.assertEqual(r["exam"]["notes"], "重症 + 内科")
        self.assertEqual(len(self.request("GET", "/v1/exams")[1]["exams"]), 1)
        FakeModelHandler.scripts["m-exam"] = lambda d: {"role": "assistant", "content": "好"}
        sid = self.new_session()
        self.wait_status(self.submit(sid, "帮我排复习计划", "m-exam")[1]["task_id"], ("completed",))
        req = FakeModelHandler.requests[-1]
        self.assertIn("主治医师考试", req["messages"][-1]["content"])
        self.assertIn("还有 12 天", req["messages"][-1]["content"])
        self.assertNotIn("考试倒计时", req["messages"][0]["content"])   # 不进系统提示
        self.assertEqual(self.request("DELETE", f"/v1/exams/{eid}")[0], 200)
        self.assertEqual(self.request("GET", "/v1/exams")[1]["exams"], [])

    def test_02_note_window(self):
        t = date(2026, 11, 1)
        conn = self.srv.get_db_connection()
        try:
            conn.execute("DELETE FROM exams")
            for i, (n, d) in enumerate((("远", "2027-03-01"), ("近", "2026-11-05"), ("过", "2026-10-20"), ("今", "2026-11-01"))):
                conn.execute("INSERT INTO exams (id, name, day, notes, created_at) VALUES (?, ?, ?, '', 0)", (f"exam_000000000{i}", n, d))
            conn.commit()
            note = cloud_exams.note(conn, today=t)
            self.assertIn("今（2026-11-01，就是今天）", note)
            self.assertIn("近（2026-11-05，还有 4 天）", note)
            self.assertNotIn("远", note)
            self.assertNotIn("过", note)
            conn.execute("DELETE FROM exams")
            conn.commit()
        finally:
            conn.close()
