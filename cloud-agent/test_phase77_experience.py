"""Real HTTP front/worker/reviewer integration; synthetic fixtures, no live keys."""
import json
import os
import sqlite3
import time
import unittest
from unittest.mock import patch

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

    def test_real_usage_is_idempotent_and_cost_budget_uses_configured_prices(self):
        exp.configure(self.db, "chat", {"version": 1, "input_price_per_million": 1, "output_price_per_million": 2,
                                       "task_token_budget": 2000, "task_cost_budget": 1})
        worker = {"worker_id": "w", "front_session": "chat"}
        first = exp.record_usage(self.db, worker, "call-one", 1000, 100)
        self.assertEqual(first["tokens"], 1100)
        self.assertAlmostEqual(first["cost"], .0012)
        self.assertFalse(first["needs_approval"])
        again = exp.record_usage(self.db, worker, "call-one", 9999, 9999)
        self.assertEqual(again, first)
        over = exp.record_usage(self.db, worker, "call-two", 1000, 100)
        self.assertTrue(over["needs_approval"])


class ExperienceHTTPTests(CloudServerTestCase):
    reply_default = None

    def test_restart_restores_recorded_tool_results_before_the_next_user_without_replaying_writes(self):
        import cloud_workers
        sid = self.new_session()
        db = self.srv.get_db_connection()
        try:
            worker = cloud_workers.create(db, None, sid, "恢复真实写入结果")
            task, now = "task-history-repair", time.time()
            db.execute("INSERT INTO tasks(task_id,session_id,status,model,created_at) VALUES (?,?,?,?,?)",
                       (task, worker["worker_session"], "paused", "fake", now))
            db.commit()
            actual = self.srv.tool_file_write(task, worker["worker_session"], {"path": "resume-proof.txt", "content": "只写一次"})
            self.assertNotIn("error", actual)
            db.execute("INSERT INTO task_events(task_id,event_type,payload,timestamp) VALUES (?,?,?,?)",
                       (task, "tool_result", json.dumps({"id": "write", "result": actual}), now + 1))
            calls = json.dumps([{"id": "write", "function": {"name": "file_write"}},
                                {"id": "read", "function": {"name": "file_read"}}])
            rows = [("assistant", None, calls, None, None, now),
                    ("user", "继续核验已有文件", None, None, None, now + 2),
                    ("tool", "已存在的读结果", None, "read", None, now + 1)]
            repaired = cloud_workers.restore_tool_rows(db, worker["worker_session"], rows)
            self.assertEqual([r[0] for r in repaired], ["assistant", "tool", "tool", "user"])
            self.assertEqual(json.loads(repaired[1][1]), actual)
            self.assertEqual(repaired[2][1], "已存在的读结果")
            path = os.path.join(self.srv.get_session_workspace(worker["worker_session"]), "resume-proof.txt")
            with open(path) as f:
                self.assertEqual(f.read(), "只写一次")
            # Virtual repair leaves the persistent transcript and provenance unchanged.
            self.assertEqual(db.execute("SELECT COUNT(*) FROM messages WHERE session_id=?", (worker["worker_session"],)).fetchone()[0], 0)
        finally:
            db.close()

    def test_restart_unknown_tool_outcome_stays_unknown_and_ignores_foreign_or_old_results(self):
        import cloud_workers
        sid, other = self.new_session(), self.new_session()
        db = self.srv.get_db_connection()
        try:
            now = time.time()
            for tid, session, stamp in [("own-old", sid, now - 10), ("foreign", other, now + 1)]:
                db.execute("INSERT INTO tasks(task_id,session_id,status,model,created_at) VALUES (?,?,?,?,?)", (tid, session, "completed", "fake", stamp))
                db.execute("INSERT INTO task_events(task_id,event_type,payload,timestamp) VALUES (?,?,?,?)",
                    (tid, "tool_result", json.dumps({"id": "pending", "result": {"status": "success"}}), stamp))
            rows = [("assistant", None, json.dumps([{"id": "pending"}]), None, None, now)]
            repaired = cloud_workers.restore_tool_rows(db, sid, rows)
            result = json.loads(repaired[1][1])
            self.assertEqual(result["status"], "unknown")
            self.assertTrue(result["needs_state_check"])
        finally:
            db.close()

    def test_restart_background_started_receipt_does_not_prove_the_process_finished(self):
        import cloud_workers
        sid = self.new_session()
        db = self.srv.get_db_connection()
        try:
            worker = cloud_workers.create(db, None, sid, "后台启动回执")
            contract = {"workstream": "bg-recovery", "goal": "核验后台完成", "context": "编造数据",
                        "success_criteria": ["实际完成"], "report_back": "完成依据"}
            orders.attach(db, worker["worker_id"], sid, contract)
            task, now = "task-bg-recovery", time.time()
            db.execute("INSERT INTO tasks(task_id,session_id,status,model,created_at) VALUES (?,?,?,?,?)",
                       (task, worker["worker_session"], "running", "fake", now))
            for kind, payload in [("tool_call", {"id": "bg", "tool": "shell_execute"}),
                                   ("tool_result", {"id": "bg", "result": {"status": "started", "job_id": "job-demo"}})]:
                db.execute("INSERT INTO task_events(task_id,event_type,payload,timestamp) VALUES (?,?,?,?)", (task, kind, json.dumps(payload), now))
            cloud_workers.set_status(db, worker["worker_id"], "running", task_id=task)
            cloud_workers.recover(db)
            cp = cloud_workers.load_checkpoint(cloud_workers.get(db, worker["worker_id"]))
            self.assertFalse(cp["safe_resume"])
            self.assertEqual(cp["uncertain_background_jobs"], ["job-demo"])
        finally:
            db.close()

    def test_stop_reaps_detached_child_jobs_after_parent_finishes_without_touching_other_workers(self):
        import cloud_workers
        import cloud_experience_runtime
        for stop_all in (False, True):
            with self.subTest(stop_all=stop_all):
                sid, other_sid, child_sid = self.new_session(), self.new_session(), self.new_session()
                db = self.srv.get_db_connection()
                try:
                    worker = cloud_workers.create(db, None, sid, "真实后台进程演示")
                    other = cloud_workers.create(db, None, other_sid, "其他对话")
                    cloud_workers.set_status(db, worker["worker_id"], "completed", result="主调用已结束")
                    db.commit()
                finally:
                    db.close()
                tid = "synthetic-child-" + worker["worker_id"]
                with self.srv.active_tasks_lock:
                    self.srv.active_tasks[tid] = {"parent": "already-finished-parent", "owner_worker_id": worker["worker_id"]}
                jobs = []
                try:
                    # Actual detached processes, including a child whose parent
                    # has already left the active-task registry.
                    with patch.object(self.srv, "on_background_done", lambda *_: None):
                        job = self.srv.tool_shell_execute(tid, child_sid,
                            {"command": "trap '' TERM; sleep 60", "background": True})
                        jobs.append(job["job_id"])
                        unrelated = self.srv.BG_JOBS.start("synthetic", other["worker_session"], "sleep 60",
                            self.srv.GLOBAL_WORKSPACE, dict(os.environ), {},
                            os.path.join(self.srv.GLOBAL_WORKSPACE, ".bg-test"), lambda *_: None,
                            owner_worker_id=other["worker_id"])
                        jobs.append(unrelated["job_id"])
                    self.assertEqual(self.srv.BG_JOBS.get(job["job_id"])["owner_worker_id"], worker["worker_id"])
                    if stop_all:
                        stopped = cloud_experience_runtime.stop_all(self.srv, sid)
                        self.assertIn(worker["worker_id"], [w["id"] for w in stopped])
                    else:
                        self.srv.worker_stop(worker["worker_id"])
                    self.wait_until(lambda: self.srv.BG_JOBS.get(job["job_id"])["status"] == "finished", timeout=5)
                    self.assertNotEqual(self.srv.BG_JOBS.get(job["job_id"])["exit_code"], 0)
                    self.assertEqual(self.srv.BG_JOBS.get(unrelated["job_id"])["status"], "running")
                    self.assertTrue(self.srv.is_task_cancelled(tid))
                finally:
                    for jid in jobs:
                        self.srv.BG_JOBS.stop(jid, force=True)
                        self.wait_until(lambda: self.srv.BG_JOBS.get(jid)["status"] == "finished", timeout=5)
                    with self.srv.active_tasks_lock:
                        self.srv.active_tasks.pop(tid, None)

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

    def test_07_ledger_requires_authentication(self):
        sid = self.new_session()
        self.assertEqual(self.request("GET", f"/v1/sessions/{sid}/experience", token="")[0], 401)

    def test_08_actual_budget_overrun_pauses_before_executing_the_next_tool(self):
        sid = self.new_session()
        contract = {"workstream": "budget-demo", "goal": "生成一个演示文件", "context": "假数据",
                    "success_criteria": ["实际生成"], "report_back": "文件"}
        FakeModelHandler.scripts["experience-front"] = lambda data: ({"role": "assistant", "content": "已派发"}
            if tool_turns(data) else tool_call("dispatch", "dispatch_workorder", contract))
        def worker(data):
            reply = tool_call("write", "file_write", {"path": "must-not-be-written.txt", "content": "unsafe over budget"})
            reply["_usage"] = {"prompt_tokens": 9000, "completion_tokens": 100}
            return reply
        FakeModelHandler.scripts["experience-back"] = worker
        status, task = self.submit(sid, "生成演示文件", "base", client_nonce="budget", **self.body(experience={"version": 1, "task_token_budget": 7000}))
        self.assertEqual(status, 202)
        self.wait_status(task["task_id"], {"completed"})
        def paused():
            _, tray = self.request("GET", f"/v1/workers?session_id={sid}")
            return tray["workers"][0] if tray.get("workers") and tray["workers"][0]["status"] == "paused" else None
        worker = self.wait_until(paused)
        self.assertEqual(worker["stop_reason"], "budget")
        self.assertTrue(worker["budget"]["needs_approval"])
        from pathlib import Path
        self.assertFalse((Path(self.srv.get_session_workspace(worker["worker_session"])) / "must-not-be-written.txt").exists())
        # An LLM cannot approve its own overrun. The phone must update policy.
        self.assertEqual(self.request("POST", "/v1/workers/" + worker["worker_id"] + "/resume", {})[0], 409)
        def within_budget(data):
            msgs = data["messages"]
            last_user = max(i for i, m in enumerate(msgs) if m["role"] == "user")
            if any(m["role"] == "tool" for m in msgs[last_user:]):
                return {"role": "assistant", "content": "文件已生成", "_usage": {"prompt_tokens": 5, "completion_tokens": 5}}
            reply = tool_call("allowed-write", "file_write", {"path": "approved-budget.txt", "content": "synthetic verified"})
            reply["_usage"] = {"prompt_tokens": 5, "completion_tokens": 5}
            return reply
        def reviewer(data):
            bundle = json.loads(data["messages"][-1]["content"])
            event = next(e for e in bundle["events"] if e["type"] == "tool_result")
            return {"role": "assistant", "content": json.dumps({"pass": True, "unmet": [], "evidence": [
                {"criterion": 0, "event_id": event["event_id"], "kind": "artifact"}]})}
        FakeModelHandler.scripts["experience-back"] = within_budget
        FakeModelHandler.scripts["experience-reviewer"] = reviewer
        body = self.body(experience={"version": 1, "task_token_budget": 20000})
        status, _ = self.request("POST", "/v1/workers/" + worker["worker_id"] + "/resume", body)
        self.assertEqual(status, 200)
        self.wait_until(lambda: self.request("GET", "/v1/workers/" + worker["worker_id"])[1]["worker"]["status"] == "completed")
        self.assertTrue((Path(self.srv.get_session_workspace(worker["worker_session"])) / "approved-budget.txt").exists())

    def test_09_restart_never_marks_unverified_execution_complete_or_replays_uncertain_calls(self):
        import cloud_workers
        sid = self.new_session()
        conn = self.srv.get_db_connection()
        try:
            exp.configure(conn, sid, {"version": 1})
            contract = {"workstream": "recover", "goal": "验证重启", "context": "编造数据",
                        "success_criteria": ["实际核验"], "report_back": "依据"}
            workers = []
            for n, finished in enumerate((True, False)):
                w = cloud_workers.create(conn, None, sid, "recover-" + str(n))
                orders.attach(conn, w["worker_id"], sid, dict(contract, workstream="recover-" + str(n)))
                tid = "task_recover_" + str(n)
                conn.execute("INSERT INTO tasks(task_id,session_id,status,model,created_at) VALUES (?,?,?,?,?)",
                             (tid, w["worker_session"], "completed" if finished else "running", "fake", time.time()))
                conn.execute("INSERT INTO task_events(task_id,event_type,payload,timestamp) VALUES (?,?,?,?)",
                             (tid,"tool_call",json.dumps({"id":"call","tool":"file_write"}),time.time()))
                if finished:
                    conn.execute("INSERT INTO task_events(task_id,event_type,payload,timestamp) VALUES (?,?,?,?)",
                                 (tid,"tool_result",json.dumps({"id":"call","result":{"status":"success"}}),time.time()))
                cloud_workers.set_status(conn,w["worker_id"],"running",task_id=tid)
                workers.append(w)
            cloud_workers.recover(conn)
            for index, w in enumerate(workers):
                recovered = cloud_workers.get(conn,w["worker_id"])
                self.assertEqual(recovered["status"],"paused")
                self.assertEqual(cloud_workers.load_checkpoint(recovered)["safe_resume"], index == 0)
                self.assertEqual(self.srv.worker_view(recovered)["auto_resume_ready"], index == 0)
        finally:
            conn.close()

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
