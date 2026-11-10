import cloud_efficiency as eff
from test_phase1_support import CloudServerTestCase, FakeModelHandler


class HardQuestionTests(CloudServerTestCase):
    def test_00_heuristic(self):
        self.assertTrue(eff.is_hard_request("请一步步推导这个感染性休克患者乳酸持续升高的病理生理机制"))
        self.assertTrue(eff.is_hard_request("帮我做鉴别诊断：发热、皮疹、血小板低，还有肝酶升高，可能是什么"))
        self.assertFalse(eff.is_hard_request("你好"))
        self.assertFalse(eff.is_hard_request("今天吃什么好呢，给点建议"))
        self.assertFalse(eff.is_hard_request([{"type": "text", "text": "证明一下"}]))
        self.assertFalse(eff.is_simple_request("请一步步推导这个机制") and eff.is_hard_request("请一步步推导这个机制"))

    def test_01_hard_question_uses_strong_model_and_high_effort(self):
        FakeModelHandler.scripts["m-strong"] = lambda d: {"role": "assistant", "content": "强模型回答"}
        FakeModelHandler.scripts["m-main2"] = lambda d: {"role": "assistant", "content": "主模型回答"}
        self.assertEqual(self.request("PUT", "/v1/resources", {"strong_model": "bad model!"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/resources", {"auto_model": True, "strong_model": "m-strong"})[0], 200)
        try:
            sid = self.new_session()
            q = "请一步步推导：为什么脓毒症早期乳酸会升高，机制和鉴别要点是什么"
            res = self.wait_status(self.submit(sid, q, "m-main2")[1]["task_id"], ("completed", "failed"))
            self.assertEqual(res["status"], "completed", res)
            req = FakeModelHandler.requests[-1]
            self.assertEqual(req["model"], "m-strong")
            self.assertEqual(req.get("reasoning_effort"), "high")
            # 普通问题照常用主模型、不加思考深度
            self.wait_status(self.submit(sid, "帮我写一份值班计划", "m-main2")[1]["task_id"], ("completed",))
            req = FakeModelHandler.requests[-1]
            self.assertEqual(req["model"], "m-main2")
            self.assertNotIn("reasoning_effort", req)
            # 强模型出错：回到主模型
            FakeModelHandler.scripts["m-strong"] = lambda d: {"_status": 404}
            res = self.wait_status(self.submit(sid, q, "m-main2")[1]["task_id"], ("completed", "failed"))
            self.assertEqual(res["status"], "completed", res)
            self.assertEqual(FakeModelHandler.requests[-1]["model"], "m-main2")
        finally:
            self.request("PUT", "/v1/resources", {"auto_model": False, "strong_model": ""})
