"""Real HTTP front/worker/reviewer integration; synthetic fixtures, no live keys."""
import json
import sqlite3
import time
import unittest

import cloud_experience as exp
import cloud_workorders as orders
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


class ExperiencePolicyTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        exp.ensure_schema(self.db)
        self.db.execute("CREATE TABLE usage_daily(day,bot_id,model,prompt_tokens,completion_tokens,calls)")

    def test_settings_never_persist_arbitrary_or_secret_fields(self):
        cfg = exp.configure(self.db, "chat", {"version": 1, "api_key": "synthetic-do-not-store", "worker_concurrency": 2})
        self.assertNotIn("api_key", cfg)
        self.assertNotIn("synthetic-do-not-store", self.db.execute("SELECT settings FROM experience_sessions").fetchone()[0])
        for bad in (True, -1, float("nan"), "10"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                exp.configure(self.db, "chat", {"version": 1, "task_token_budget": bad})

    def test_roles_keep_independent_endpoint_key_even_with_identical_model_ids(self):
        roles = exp.profiles({role: {"model": "same-name", "provider": {"base_url": "https://" + role + ".example/v1",
                              "api_key": role + "-synthetic"}} for role in ("front", "back")}, "default", {})
        self.assertNotEqual(exp.route(roles["front"]), exp.route(roles["back"]))
        self.assertEqual(roles["reviewer"], roles["front"])
        with self.assertRaises(ValueError):
            exp.profiles({"front": {"model": "m", "provider": {"base_url": "https://key@bad.example/v1", "api_key": "fake"}}}, "m", {})

    def test_budget_unknown_price_is_not_reported_as_free(self):
        exp.configure(self.db, "chat", {"version": 1, "task_cost_budget": 1})
        budget = exp.estimate_budget(self.db, "chat", "goal", "context")
        self.assertIsNone(budget["estimated_cost"])
        self.assertTrue(budget["needs_approval"])
        exp.configure(self.db, "chat", {"version": 1, "task_token_budget": 100})
        self.assertTrue(exp.estimate_budget(self.db, "chat", "goal", "context")["needs_approval"])

    def test_memory_is_scoped_relevant_short_and_actionable(self):
        exp.learn_correction(self.db, "a", "以后先测试再说完成")
        exp.learn_correction(self.db, "a", "你是真的垃圾")
        exp.remember(self.db, "a", "project", "OpenMinis 编译用 Mac-58")
        exp.remember(self.db, "a", "project", "别的项目要紫色")
        note = exp.memory_note(self.db, "a", "OpenMinis 编译")
        self.assertIn("先测试", note)
        self.assertIn("Mac-58", note)
        self.assertNotIn("垃圾", note)
        self.assertNotIn("紫色", note)
        self.assertEqual(exp.memory_note(self.db, "b", "OpenMinis"), "")
        with self.assertRaises(ValueError):
            exp.remember(self.db, "a", "preference", "api_key=sk-synthetic")


class ExperienceHTTPTests(CloudServerTestCase):
    reply_default = None

    def body(self, **extra):
        provider = {"base_url": self.model_base, "api_key": "fake-front-phone-only", "protocol": "chat"}
        data = {"experience": {"version": 1}, "execution_profiles": {
            "front": {"model": "experience-front", "provider": provider},
            "back": {"model": "experience-back", "provider": dict(provider, api_key="fake-back-phone-only")},
            "reviewer": {"model": "experience-reviewer", "provider": dict(provider, api_key="fake-review-phone-only")}}}
        data.update(extra)
        return data

    def test_01_twenty_quick_messages_settle_ledger_without_spawning_workers(self):
        sid = self.new_session("synthetic front benchmark")
        FakeModelHandler.scripts["experience-front"] = lambda data: {"role": "assistant", "content": "短答"}
        for n in range(20):
            status, result = self.submit(sid, "演示简单问题 " + str(n), "base", client_nonce="simple-" + str(n), **self.body())
            self.assertEqual(status, 202)
            self.wait_status(result["task_id"], {"completed"})
        _, ledger = self.request("GET", f"/v1/sessions/{sid}/experience")
        self.assertEqual(len(ledger["requests"]), 20)
        self.assertTrue(all(row["status"] == "delivered" for row in ledger["requests"]))
        _, tray = self.request("GET", f"/v1/workers?session_id={sid}")
        self.assertEqual(tray["workers"], [])
        db = self.srv.get_db_connection()
        try:
            raw = "\n".join(str(r) for r in db.execute("SELECT * FROM experience_sessions"))
            self.assertNotIn("fake-front-phone-only", raw)
        finally:
            db.close()

    def test_02_same_model_name_fallback_changes_provider_and_next_turn_restores_front(self):
        sid = self.new_session()
        seen = []
        def respond(data):
            key = FakeModelHandler.auth_headers[-1]
            seen.append(key)
            if key == "Bearer fake-front-phone-only":
                return {"_status": 500, "error": {"message": "synthetic front unavailable"}}
            return {"role": "assistant", "content": "后台回退回答"}
        FakeModelHandler.scripts["same-id"] = respond
        body = self.body()
        for profile in body["execution_profiles"].values():
            profile["model"] = "same-id"
        status, result = self.submit(sid, "问题", "base", **body)
        self.assertEqual(status, 202)
        self.wait_status(result["task_id"], {"completed"})
        self.assertIn("Bearer fake-front-phone-only", seen)
        self.assertIn("Bearer fake-back-phone-only", seen)

    def test_03_unverified_worker_output_is_a_draft_and_cannot_deliver(self):
        sid = self.new_session()
        contract = {"workstream": "test-proof", "goal": "生成并验证演示文件", "context": "仅编造数据",
                    "success_criteria": ["实际生成文件"], "report_back": "文件与验证依据"}
        FakeModelHandler.scripts["experience-front"] = lambda data: ({"role": "assistant", "content": "已派发，等待验证"}
            if tool_turns(data) else tool_call("dispatch", "dispatch_workorder", contract, "我理解你要生成文件，标准是文件实际生成。"))
        FakeModelHandler.scripts["experience-back"] = lambda data: {"role": "assistant", "content": "我完成了，全部通过"}
        FakeModelHandler.scripts["experience-reviewer"] = lambda data: {"role": "assistant", "content": '{"pass":true,"unmet":[],"evidence":[]}'}
        status, result = self.submit(sid, "生成并验证文件", "base", client_nonce="draft", **self.body())
        self.assertEqual(status, 202)
        self.wait_status(result["task_id"], {"completed"})
        def done():
            _, data = self.request("GET", f"/v1/workers?session_id={sid}")
            return data["workers"][0] if data.get("workers") and data["workers"][0]["status"] == "failed" else None
        worker = self.wait_until(done)
        self.assertEqual(worker["workorder"]["verification"], "rejected")
        self.assertIn("待验证草稿", worker["result"])
        _, ledger = self.request("GET", f"/v1/sessions/{sid}/experience")
        self.assertEqual(ledger["requests"][0]["status"], "blocked")

    def test_04_stop_works_without_model_credentials_and_is_idempotent(self):
        sid = self.new_session()
        self.assertEqual(self.request("POST", f"/v1/sessions/{sid}/experience", {"version": 1})[0], 200)
        db = self.srv.get_db_connection()
        try:
            import cloud_workers
            worker = cloud_workers.create(db, None, sid, "排队的演示任务")
        finally:
            db.close()
        body = {"content": "停", "client_nonce": "stop-nonce"}
        status, a = self.request("POST", f"/v1/sessions/{sid}/messages", body)
        self.assertEqual(status, 202)
        status, b = self.request("POST", f"/v1/sessions/{sid}/messages", body)
        self.assertEqual(status, 200)
        self.assertEqual(a["task_id"], b["task_id"])
        _, stopped = self.request("GET", "/v1/workers/" + worker["worker_id"])
        self.assertEqual(stopped["worker"]["status"], "cancelled")

    def test_05_verified_worker_uses_background_credentials_and_delivers_evidence(self):
        sid = self.new_session()
        contract = {"workstream": "verified-demo", "goal": "实际运行断言验证算术", "context": "仅编造数据",
                    "success_criteria": ["用 Python 断言验证 12 加 30 等于 42"], "report_back": "实际退出码和输出"}
        FakeModelHandler.scripts["experience-front"] = lambda data: ({"role": "assistant", "content": "已派发，等待验证"}
            if tool_turns(data) else tool_call("dispatch", "dispatch_workorder", contract, "目标是运行断言，标准是实际通过。"))
        def worker(data):
            if not tool_turns(data):
                return tool_call("verify", "shell_execute", {"command": "python3 -c 'assert 12 + 30 == 42; print(\"arithmetic assertion passed\")'"})
            return {"role": "assistant", "content": "Python 断言通过，实际输出 arithmetic assertion passed。"}
        FakeModelHandler.scripts["experience-back"] = worker
        def review(data):
            bundle = json.loads(data["messages"][-1]["content"])
            result = next(e for e in bundle["events"] if e["type"] == "tool_result")
            self.assertEqual(result["payload"]["result"]["exit_code"], 0)
            return {"role": "assistant", "content": json.dumps({"pass": True, "unmet": [], "evidence": [
                {"criterion": 0, "event_id": result["event_id"], "kind": "test", "summary": "Python 断言实际通过"}]})}
        FakeModelHandler.scripts["experience-reviewer"] = review
        status, task = self.submit(sid, "验证算术", "base", client_nonce="verified", **self.body())
        self.assertEqual(status, 202)
        self.wait_status(task["task_id"], {"completed"})
        def verified():
            _, tray = self.request("GET", f"/v1/workers?session_id={sid}")
            return tray["workers"][0] if tray.get("workers") and tray["workers"][0]["status"] == "completed" else None
        result = self.wait_until(verified)
        self.assertEqual(result["workorder"]["verification"], "verified")
        self.assertEqual(len(result["workorder"]["evidence"]), 1)
        _, ledger = self.request("GET", f"/v1/sessions/{sid}/experience")
        self.assertEqual(ledger["requests"][0]["status"], "delivered")

        self.assertIn("Bearer fake-back-phone-only", FakeModelHandler.auth_headers)
        self.assertIn("Bearer fake-review-phone-only", FakeModelHandler.auth_headers)

    def test_06_simulator_fixture_really_generates_and_verifies_its_delivery(self):
        import importlib.util
        from pathlib import Path
        spec = importlib.util.spec_from_file_location("experience_e2e_fixture", Path(__file__).resolve().parents[1] / "scripts/e2e_cloud_stack.py")
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        FakeModelHandler.scripts["experience-front"] = fixture.front_script
        FakeModelHandler.scripts["experience-back"] = fixture.back_script
        FakeModelHandler.scripts["experience-reviewer"] = fixture.experience_review_script
        sid = self.new_session()
        status, task = self.submit(sid, "体验生成文件", "base", client_nonce="simulator-fixture", **self.body())
        self.assertEqual(status, 202)
        self.wait_status(task["task_id"], {"completed"})
        def verified():
            _, tray = self.request("GET", f"/v1/workers?session_id={sid}")
            return tray["workers"][0] if tray.get("workers") and tray["workers"][0]["status"] == "completed" else None
        worker = self.wait_until(verified)
        self.assertEqual(worker["workorder"]["verification"], "verified")
        path = Path(self.srv.get_session_workspace(worker["worker_session"])) / "体验结果.txt"
        self.assertEqual(path.read_text(), "experience verified synthetic data")
        _, ledger = self.request("GET", f"/v1/sessions/{sid}/experience")
        self.assertEqual(ledger["requests"][0]["status"], "delivered")

        # A follow-up in the same workstream reuses the completed worker, but
        # must generate fresh evidence instead of accepting the old test run.
        original_task = worker["task_id"]
        status, task = self.submit(sid, "体验生成文件：重新生成", "base", client_nonce="simulator-followup", **self.body())
        self.assertEqual(status, 202)
        self.wait_status(task["task_id"], {"completed"})
        def revised():
            value = self.request("GET", "/v1/workers/" + worker["worker_id"])[1]["worker"]
            return value if value["status"] == "completed" and value["task_id"] != original_task else None
        newer = self.wait_until(revised)
        self.assertGreater(newer["workorder"]["revision"], worker["workorder"]["revision"])
        self.assertEqual(newer["workorder"]["verification"], "verified")
        all_workers = self.request("GET", f"/v1/workers?session_id={sid}")[1]["workers"]
        self.assertEqual(len(all_workers), 1)


if __name__ == "__main__":
    unittest.main()
