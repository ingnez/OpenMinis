"""撤回发送 /v1/tasks/<id>/retract（2.39.0）：时间窗口内删掉用户消息；超时 / 有更新的消息不能撤回（假数据）"""
import time
from test_phase1_support import CloudServerTestCase, FakeModelHandler


class RetractTests(CloudServerTestCase):
    def test_retract_deletes_message(self):
        FakeModelHandler.scripts["m-retract"] = lambda d: (time.sleep(1.5), {"role": "assistant", "content": "迟到的回复"})[1]
        sid = self.new_session("撤回")
        status, task = self.submit(sid, "发错了的消息（假）", "m-retract")
        self.assertIn(status, (200, 201, 202))
        st, res = self.request("POST", f"/v1/tasks/{task['task_id']}/retract", {})
        self.assertEqual(st, 200, res)
        self.assertEqual(res["status"], "retracted")
        self.assertGreaterEqual(res["deleted_messages"], 1)
        self.wait_status(task["task_id"], ["cancelled", "completed", "failed", "interrupted"])
        _, detail = self.request("GET", f"/v1/sessions/{sid}")
        contents = [m.get("content") for m in detail.get("messages", [])]
        self.assertNotIn("发错了的消息（假）", contents)

    def test_window_and_newer(self):
        sid = self.new_session("撤回2")
        _, t1 = self.submit(sid, "第一条（假）", "m-plain")
        self.wait_status(t1["task_id"], ["completed"])
        _, t2 = self.submit(sid, "第二条（假）", "m-plain")
        self.wait_status(t2["task_id"], ["completed"])
        st, _ = self.request("POST", f"/v1/tasks/{t1['task_id']}/retract", {})
        self.assertEqual(st, 409)       # 之后又发了消息
        old = self.srv.RETRACT_WINDOW_S
        self.srv.RETRACT_WINDOW_S = -1
        try:
            st, res = self.request("POST", f"/v1/tasks/{t2['task_id']}/retract", {})
            self.assertEqual(st, 409)   # 超时
        finally:
            self.srv.RETRACT_WINDOW_S = old
        st, _ = self.request("POST", "/v1/tasks/task_nope000000/retract", {})
        self.assertEqual(st, 404)
