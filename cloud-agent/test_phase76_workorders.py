"""Experience-upgrade contracts and evidence gates, using synthetic data only."""
import json
import sqlite3
import unittest

import cloud_workorders as orders


class WorkOrderTests(unittest.TestCase):
    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.addCleanup(self.conn.close)
        self.conn.executescript("""
            CREATE TABLE bot_workers(worker_id TEXT PRIMARY KEY,front_session TEXT,task_id TEXT,status TEXT,created_at REAL);
            CREATE TABLE task_events(id INTEGER PRIMARY KEY,task_id TEXT,event_type TEXT,payload TEXT);
            INSERT INTO bot_workers VALUES('worker-a','chat-a','task-a','running',1);
            INSERT INTO bot_workers VALUES('worker-b','chat-b','task-b','running',2);
        """)
        orders.ensure_schema(self.conn)
        self.contract = {"workstream": "openminis-ui", "goal": "生成并验证演示文件", "context": "只使用编造数据",
                         "success_criteria": ["回归通过", "文件实际生成"], "report_back": "交回文件和测试结果"}

    def attach(self, worker="worker-a", chat="chat-a"):
        return orders.attach(self.conn, worker, chat, self.contract)

    def event(self, number, task, tool, result):
        self.conn.execute("INSERT INTO task_events VALUES(?,?,?,?)",
                          (number, task, "tool_result", json.dumps({"tool": tool, "result": result})))
        self.conn.commit()

    def evidence(self):
        self.event(1, "task-a", "shell_execute", {"exit_code": 0, "output": "2 tests passed"})
        self.event(2, "task-a", "deliver_file", {"status": "ok", "name": "demo.pdf"})
        orders.record_evidence(self.conn, "worker-a", 0, 1, "test")
        orders.record_evidence(self.conn, "worker-a", 1, 2, "artifact")

    def test_contract_requires_all_five_fields(self):
        for key in orders.FIELDS:
            with self.subTest(key=key), self.assertRaises(orders.WorkOrderError):
                orders.normalize({k: v for k, v in self.contract.items() if k != key})
        for criteria in ([], [""], "测试通过"):
            with self.subTest(criteria=criteria), self.assertRaises(orders.WorkOrderError):
                orders.normalize(dict(self.contract, success_criteria=criteria))

    def test_existing_clients_can_be_normalized_without_dropping_the_goal(self):
        order = orders.normalize({"goal": "生成演示文件"}, legacy=True)
        self.assertEqual(order["goal"], "生成演示文件")
        self.assertTrue(all(key in order for key in orders.FIELDS))

    def test_workstream_reuse_is_limited_to_the_owning_conversation(self):
        self.attach()
        self.assertEqual(orders.reusable_worker(self.conn, "chat-a", "openminis-ui"), "worker-a")
        self.assertIsNone(orders.reusable_worker(self.conn, "chat-b", "openminis-ui"))
        with self.assertRaises(orders.WorkOrderError):
            orders.attach(self.conn, "worker-a", "chat-b", self.contract)
        self.conn.execute("UPDATE bot_workers SET status='completed' WHERE worker_id='worker-a'")
        self.assertIsNone(orders.reusable_worker(self.conn, "chat-a", "openminis-ui"))

    def test_replayed_requests_do_not_duplicate_or_replace_the_original_message(self):
        a = orders.register_request(self.conn, "chat-a", "nonce-a", "第一条请求")
        b = orders.register_request(self.conn, "chat-a", "nonce-a", "重复 HTTP 请求")
        self.assertEqual(a, b)
        self.assertEqual(len(orders.list_requests(self.conn, "chat-a")), 1)
        self.assertEqual(orders.list_requests(self.conn, "chat-a")[0]["message"], "第一条请求")
        self.assertEqual(orders.list_requests(self.conn, "chat-b"), [])

    def test_cannot_complete_a_request_with_an_empty_reply_or_foreign_worker(self):
        request = orders.register_request(self.conn, "chat-a", "nonce-a", "请求")
        with self.assertRaises(orders.WorkOrderError):
            orders.answer_request(self.conn, request, "chat-a", "")
        with self.assertRaises(orders.WorkOrderError):
            orders.assign_request(self.conn, request, "chat-a", "worker-b")
        orders.answer_request(self.conn, request, "chat-a", "直接回答")
        self.assertEqual(orders.list_requests(self.conn, "chat-a")[0]["status"], "delivered")

    def test_worker_end_does_not_mean_verified_delivery(self):
        self.attach()
        request = orders.register_request(self.conn, "chat-a", "nonce-a", "请求")
        orders.assign_request(self.conn, request, "chat-a", "worker-a")
        self.conn.execute("UPDATE bot_workers SET status='completed' WHERE worker_id='worker-a'")
        self.assertEqual(orders.reconcile(self.conn, "chat-a")[0]["status"], "blocked")
        self.evidence()
        orders.review(self.conn, "worker-a", {"pass": True, "unmet": []})
        self.assertEqual(orders.reconcile(self.conn, "chat-a")[0]["status"], "delivered")

    def test_optimistic_model_review_cannot_replace_missing_evidence(self):
        self.attach()
        result = orders.review(self.conn, "worker-a", {"pass": True, "unmet": []})
        self.assertEqual(result["verification"], "rejected")
        self.assertEqual(result["review"]["missing_evidence"], [0, 1])
        with self.assertRaises(orders.WorkOrderError):
            orders.milestone(self.conn, "worker-a", "result", "做完了")

    def test_evidence_cannot_reference_another_task_or_a_failed_command(self):
        self.attach()
        self.event(1, "task-b", "shell_execute", {"exit_code": 0})
        self.event(2, "task-a", "shell_execute", {"exit_code": 1})
        self.event(3, "task-a", "shell_execute", {"exit_code": False})
        for number in (1, 2, 3):
            with self.subTest(event=number), self.assertRaises(orders.WorkOrderError):
                orders.record_evidence(self.conn, "worker-a", 0, number, "test")

    def test_rejected_review_and_revised_goal_require_new_verification(self):
        self.attach()
        self.evidence()
        rejected = orders.review(self.conn, "worker-a", {"pass": False, "unmet": ["尚有失败"]})
        self.assertEqual(rejected["verification"], "rejected")
        orders.review(self.conn, "worker-a", {"pass": True, "unmet": []})
        revised = self.attach()
        self.assertEqual(revised["revision"], 2)
        self.assertEqual(revised["verification"], "pending")
        self.assertEqual(revised["evidence"], [])

    def test_milestones_are_coarse_and_idempotent(self):
        self.attach()
        self.assertTrue(orders.milestone(self.conn, "worker-a", "blocked", "需要补充输入"))
        self.assertFalse(orders.milestone(self.conn, "worker-a", "blocked", "需要补充输入"))
        with self.assertRaises(orders.WorkOrderError):
            orders.milestone(self.conn, "worker-a", "command", "每一条命令")

    def test_stop_all_requires_an_unambiguous_user_command(self):
        for text in ("停", "全部停止！", "停止所有任务"):
            self.assertTrue(orders.stop_all_requested(text))
        for text in ("不要停", "停止以后怎么继续？", "文档里写着‘停’", "停止这个步骤再做下一步"):
            self.assertFalse(orders.stop_all_requested(text))

    def test_default_concurrency_is_two_and_never_exceeds_four(self):
        self.assertEqual(orders.concurrency({}), 2)
        self.assertEqual(orders.concurrency({"worker_concurrency": 4}), 4)
        for value in (0, 5, True, "2"):
            with self.subTest(value=value), self.assertRaises(orders.WorkOrderError):
                orders.concurrency({"worker_concurrency": value})


if __name__ == "__main__":
    unittest.main()
