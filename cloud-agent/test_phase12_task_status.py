"""任务状态回归：已经给出回答的任务不能被标成 failed；DeepSeek 思考模式要把 reasoning_content 传回。"""
import json
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call


class TaskStatusTests(CloudServerTestCase):
    def _messages(self, sid):
        return self.request("GET", f"/v1/sessions/{sid}")[1].get("messages", [])

    def test_01_answer_then_followup_failure_is_completed(self):
        calls = []
        def script(d):
            calls.append(d)
            n = len(calls)
            if n == 1:
                return tool_call("m1", "memory_search", {"query": "能力"})
            if n == 2:   # 写出完整回答，同时顺手记一条记忆
                return tool_call("m2", "memory_write", {"content": "用户问过我能做什么", "category": "note"}, content="我可以帮你做很多事。")
            return {"_status": 500, "error": {"message": "upstream exploded"}}
        FakeModelHandler.scripts["m-ans"] = script
        sid = self.new_session()
        t = self.submit(sid, "你可以做什么事", "m-ans")[1]
        res = self.wait_status(t["task_id"], ("completed", "failed"))
        self.assertEqual(res["status"], "completed", res)
        self.assertTrue(any(m.get("role") == "assistant" and "很多事" in (m.get("content") or "") for m in self._messages(sid)))

    def test_02_empty_reply_after_answer_is_completed(self):
        calls = []
        def script(d):
            calls.append(d)
            if len(calls) == 1:
                return tool_call("w1", "memory_write", {"content": "x", "category": "note"}, content="好的，记下了。")
            return {"role": "assistant", "content": ""}
        FakeModelHandler.scripts["m-empty"] = script
        sid = self.new_session()
        t = self.submit(sid, "记一下", "m-empty")[1]
        self.assertEqual(self.wait_status(t["task_id"], ("completed", "failed"))["status"], "completed")

    def test_03_empty_reply_without_answer_fails_with_chinese_reason(self):
        FakeModelHandler.scripts["m-none"] = lambda d: {"role": "assistant", "content": ""}
        sid = self.new_session()
        t = self.submit(sid, "hi", "m-none")[1]
        res = self.wait_status(t["task_id"], ("completed", "failed"))
        self.assertEqual(res["status"], "failed")
        errs = [e for e in res.get("events", []) if e["type"] == "error"]
        self.assertIn("空回复", errs[-1]["payload"]["error"])

    def test_04_deepseek_reasoning_content_passed_back(self):
        calls = []
        def script(d):
            calls.append(d)
            if len(calls) == 1:
                return {"_chunks": [{"reasoning_content": "先查记忆"},
                                    {"tool_calls": [{"index": 0, "id": "s1", "type": "function",
                                                     "function": {"name": "memory_search", "arguments": json.dumps({"query": "x"})}}]}],
                        "_delay": 0}
            prev = [m for m in d["messages"] if m.get("role") == "assistant" and m.get("tool_calls")]
            if not prev or not prev[-1].get("reasoning_content"):
                return {"_status": 400, "error": {"message": "Missing `reasoning_content` field in the assistant message"}}
            return {"_chunks": ["查完了，", "这是答案"], "_delay": 0}
        FakeModelHandler.scripts["deepseek-v4.1-flash"] = script
        sid = self.new_session()
        t = self.submit(sid, "查一下", "deepseek-v4.1-flash")[1]
        res = self.wait_status(t["task_id"], ("completed", "failed"))
        self.assertEqual(res["status"], "completed", res)
        self.assertEqual(calls[1]["messages"][-2].get("reasoning_content"), "先查记忆")


if __name__ == "__main__":
    unittest.main()
