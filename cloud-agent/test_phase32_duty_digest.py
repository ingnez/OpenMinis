import time
import unittest

import cloud_duty
from test_phase1_support import CloudServerTestCase


class DutyTransitionTests(unittest.TestCase):
    def test_state_machine(self):
        s, w = cloud_duty.transition({}, 2000, 1000)
        self.assertEqual((s["active"], s["started"], w), (True, 1000, None))
        s, w = cloud_duty.transition(s, 3000, 1500)          # 延长值班
        self.assertEqual((s["until"], w), (3000, None))
        s2, w = cloud_duty.transition(s, 3000, 3600)         # 到点自然结束：下班时间是 duty_until
        self.assertEqual(w, (1000, 3000))
        s3, w = cloud_duty.transition(s, 0, 2000)            # 提前手动关
        self.assertEqual(w, (1000, 2000))
        self.assertEqual(cloud_duty.transition(s3, 0, 2100)[1], None)   # 只汇总一次

    def test_compose(self):
        t = time.mktime((2026, 11, 10, 8, 0, 0, 0, 0, -1))
        self.assertIn("没有错过什么", cloud_duty.compose(t - 3600, t, []))
        items = [{"ts": t - 60, "kind": "proactive", "title": "主动消息 · 总管", "body": "明天考试\n记得带证", "suppressed": True}]
        text = cloud_duty.compose(t - 3600, t, items)
        self.assertIn("07:00–08:00", text)
        self.assertIn("1 条主动消息当时没推送", text)
        self.assertIn("明天考试 记得带证", text)


class DutyDigestServerTests(CloudServerTestCase):
    def test_01_digest_on_end_of_duty(self):
        sent = []
        orig = self.srv.user_notify
        self.request("PUT", "/v1/resources", {"duty_until": time.time() + 3600})
        try:
            self.srv.on_routine_finished({"name": "主动消息 · 总管", "notify": True, "persona_id": ""},
                                         {"status": "completed", "result": "下周三交病例，key sk-test-FAKE0000000000000000", "session_id": None})
            self.srv.user_notify(None, "task_finished", "任务完成", "化验单整理好了")
            self.srv.user_notify = lambda *a, **k: sent.append(a)
        finally:
            self.request("PUT", "/v1/resources", {"duty_until": 0})
            self.srv.user_notify = orig
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0][1], "duty_digest")
        self.assertIn("一共 2 条", sent[0][3])
        self.assertIn("下周三交病例", sent[0][3])
        self.assertNotIn("FAKE0000000000000000", sent[0][3])   # 脱敏
        st, d = self.request("GET", "/v1/duty/digest")
        self.assertEqual(st, 200)
        self.assertEqual(d["digest"]["count"], 2)
        self.assertFalse(d["on_duty"])
        # 再次检查不会重复推
        self.assertIsNone(self.srv.duty_check())


if __name__ == "__main__":
    unittest.main()
