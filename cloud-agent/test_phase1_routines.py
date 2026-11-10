#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 1 / 3：云端例行任务（CRUD、cron/interval/once 调度、加密凭据运行、结果持久化）。"""

import time
import sqlite3
import unittest
from datetime import datetime

import cloud_cron
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns

SECRET = "sk-routine-secret-key-0987654321"


class RoutineTests(CloudServerTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.srv.MIN_INTERVAL_SECONDS = 1
        cls.srv.SCHEDULER_TICK = 0.2
        status, _ = cls.request(cls, "PUT", "/v1/credentials/rt", {"api_key": SECRET, "base_url": cls.model_base})
        assert status == 201

    def routine(self, **over):
        body = {"name": "日报", "prompt": "总结今天的日志", "model": "m-rt", "credential": "rt",
                "schedule": {"kind": "interval", "seconds": 3600}}
        body.update(over)
        return body

    def wait_run(self, rid, statuses=("completed",), timeout=15):
        def done():
            runs = self.request("GET", f"/v1/routines/{rid}/runs")[1]["runs"]
            return runs if runs and runs[0]["status"] in statuses else None
        return self.wait_until(done, timeout=timeout, message=f"routine {rid} did not finish")

    def test_01_crud_and_validation(self):
        self.assertEqual(self.request("POST", "/v1/routines", self.routine(schedule={"kind": "cron", "expr": "61 * * * *"}))[0], 400)
        self.assertEqual(self.request("POST", "/v1/routines", self.routine(schedule={"kind": "interval", "seconds": 0}))[0], 400)
        self.assertEqual(self.request("POST", "/v1/routines", self.routine(schedule={"kind": "cron", "expr": "0 8 * * *", "timezone": "Mars/Base"}))[0], 400)
        self.assertEqual(self.request("POST", "/v1/routines", {"name": "x"})[0], 400)
        status, r = self.request("POST", "/v1/routines", self.routine(schedule={"kind": "cron", "expr": "30 8 * * 1-5", "timezone": "Asia/Shanghai"}))
        self.assertEqual(status, 201, r)
        self.assertTrue(r["enabled"])
        local = datetime.fromtimestamp(r["next_run_at"], cloud_cron.get_zone("Asia/Shanghai"))
        self.assertEqual((local.hour, local.minute), (8, 30))
        self.assertLess(local.weekday(), 5)
        status, r2 = self.request("PUT", f"/v1/routines/{r['routine_id']}", {"enabled": False})
        self.assertEqual(status, 200)
        self.assertFalse(r2["enabled"])
        self.assertIsNone(r2["next_run_at"])
        self.assertIn(r["routine_id"], [x["routine_id"] for x in self.request("GET", "/v1/routines")[1]["routines"]])
        self.assertEqual(self.request("DELETE", f"/v1/routines/{r['routine_id']}")[0], 200)
        self.assertEqual(self.request("GET", f"/v1/routines/{r['routine_id']}")[0], 404)

    def test_02_manual_run_uses_encrypted_credential_and_persists_result(self):
        def script(data):
            if not tool_turns(data):
                return tool_call("c1", "shell_execute", {"command": "echo routine-ok"})
            return {"role": "assistant", "content": "日报完成：" + tool_turns(data)[-1]["content"]}
        FakeModelHandler.scripts["m-rt"] = script
        r = self.request("POST", "/v1/routines", self.routine())[1]
        status, run = self.request("POST", f"/v1/routines/{r['routine_id']}/run", {})
        self.assertEqual(status, 202, run)
        runs = self.wait_run(r["routine_id"])
        self.assertIn("routine-ok", runs[0]["result"])
        self.assertEqual(runs[0]["trigger"], "manual")
        self.assertIn("Bearer " + SECRET, FakeModelHandler.auth_headers)
        detail = self.request("GET", f"/v1/routines/{r['routine_id']}")[1]
        self.assertEqual(detail["last_status"], "completed")
        self.assertEqual(detail["run_count"], 1)
        prompt = [m for m in FakeModelHandler.requests[-1]["messages"] if m["role"] == "user"][0]["content"]
        self.assertIn("例行任务「日报」", prompt)

    def test_03_scheduler_fires_due_interval_and_once(self):
        FakeModelHandler.scripts["m-tick"] = lambda d: {"role": "assistant", "content": "tick"}
        r = self.request("POST", "/v1/routines", self.routine(model="m-tick", schedule={"kind": "interval", "seconds": 1}))[1]
        once = self.request("POST", "/v1/routines", self.routine(model="m-tick", name="一次", schedule={"kind": "once", "at": time.time() - 1}))[1]
        self.srv.scheduler_tick(now=time.time() + 2)
        self.wait_run(r["routine_id"])
        self.wait_run(once["routine_id"])
        once_after = self.request("GET", f"/v1/routines/{once['routine_id']}")[1]
        self.assertFalse(once_after["enabled"])
        self.assertIsNone(once_after["next_run_at"])
        # once 不会再次触发
        self.srv.scheduler_tick(now=time.time() + 10)
        time.sleep(0.5)
        self.assertEqual(len(self.request("GET", f"/v1/routines/{once['routine_id']}/runs")[1]["runs"]), 1)
        self.request("DELETE", f"/v1/routines/{r['routine_id']}")

    def test_04_background_thread_and_max_runs(self):
        FakeModelHandler.scripts["m-bg"] = lambda d: {"role": "assistant", "content": "bg"}
        r = self.request("POST", "/v1/routines", self.routine(model="m-bg", max_runs=2, schedule={"kind": "interval", "seconds": 1}))[1]
        self.srv.start_scheduler()
        try:
            self.wait_until(lambda: len([x for x in self.request("GET", f"/v1/routines/{r['routine_id']}/runs")[1]["runs"] if x["status"] == "completed"]) >= 2,
                            timeout=10, message="scheduler thread did not run twice")
        finally:
            self.srv.stop_scheduler()
        final = self.request("GET", f"/v1/routines/{r['routine_id']}")[1]
        self.assertFalse(final["enabled"])
        self.assertEqual(final["run_count"], 2)

    def test_05_missing_credential_fails_cleanly(self):
        r = self.request("POST", "/v1/routines", self.routine(credential="nope"))[1]
        status, run = self.request("POST", f"/v1/routines/{r['routine_id']}/run", {})
        self.assertEqual(run["status"], "failed")
        self.assertIn("凭据不可用", run["error"])
        self.assertEqual(self.request("GET", f"/v1/routines/{r['routine_id']}")[1]["last_status"], "failed")

    def test_06_overlapping_run_is_skipped(self):
        def slow(data):
            if not tool_turns(data):
                return tool_call("s1", "shell_execute", {"command": "sleep 1.5; echo slow"})
            return {"role": "assistant", "content": "slow done"}
        FakeModelHandler.scripts["m-slow"] = slow
        r = self.request("POST", "/v1/routines", self.routine(model="m-slow"))[1]
        self.assertEqual(self.request("POST", f"/v1/routines/{r['routine_id']}/run", {})[1]["status"], "running")
        self.assertEqual(self.request("POST", f"/v1/routines/{r['routine_id']}/run", {})[1]["status"], "skipped")
        self.wait_until(lambda: any(x["status"] == "completed" for x in self.request("GET", f"/v1/routines/{r['routine_id']}/runs")[1]["runs"]),
                        message="slow run did not complete")

    def test_07_restart_marks_running_runs_interrupted(self):
        conn = sqlite3.connect(self.srv.DB_PATH)
        conn.execute("INSERT INTO routine_runs (run_id, routine_id, status, started_at) VALUES ('run_fake', 'rtn_x', 'running', 0)")
        conn.commit()
        conn.close()
        self.srv.init_db()
        conn = sqlite3.connect(self.srv.DB_PATH)
        self.assertEqual(conn.execute("SELECT status FROM routine_runs WHERE run_id='run_fake'").fetchone()[0], "interrupted")
        conn.close()


class CronUnitTests(unittest.TestCase):
    def nxt(self, expr, after, tz="UTC"):
        z = cloud_cron.get_zone(tz)
        ts = cloud_cron.CronSpec(expr).next_after(after.replace(tzinfo=z).timestamp(), tz)
        return datetime.fromtimestamp(ts, z).replace(tzinfo=None)

    def test_fields(self):
        self.assertEqual(self.nxt("*/15 * * * *", datetime(2026, 1, 1, 10, 7)), datetime(2026, 1, 1, 10, 15))
        self.assertEqual(self.nxt("0 9 * * 1", datetime(2026, 11, 10, 9, 0)), datetime(2026, 11, 16, 9, 0))  # 周二→下周一
        self.assertEqual(self.nxt("0 0 1 * *", datetime(2026, 12, 15)), datetime(2027, 1, 1))
        self.assertEqual(self.nxt("0 12 * * 7", datetime(2026, 11, 10)), datetime(2026, 11, 15, 12, 0))  # 7 = 周日
        # 日与周同时受限取“或”：每月 13 日或每周五
        self.assertEqual(self.nxt("0 0 13 * 5", datetime(2026, 11, 10)), datetime(2026, 11, 13))
        self.assertEqual(self.nxt("0 0 13 * 5", datetime(2026, 11, 13, 1)), datetime(2026, 11, 20))

    def test_dst_gap_skipped(self):
        # 2026-03-08 美东 02:30 不存在
        self.assertEqual(self.nxt("30 2 * * *", datetime(2026, 3, 7, 12), "America/New_York"), datetime(2026, 3, 9, 2, 30))

    def test_invalid(self):
        for expr in ["* * * *", "60 * * * *", "* 24 * * *", "a * * * *", "5-1 * * * *", "*/0 * * * *"]:
            with self.assertRaises(cloud_cron.CronError, msg=expr):
                cloud_cron.CronSpec(expr)


if __name__ == "__main__":
    unittest.main()
