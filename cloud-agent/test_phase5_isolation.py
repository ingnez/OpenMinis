#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""多 Bot 隔离：资源设置校验与推荐、排队闸门、每 Bot 工作区 / 共享目录、后台命令、排队上限。"""
import os
import threading
import time
import unittest

import cloud_isolation as iso
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


class SettingsUnitTests(unittest.TestCase):
    def test_validate_merge_and_errors(self):
        base = iso.merged_with_defaults(None)
        s = iso.validate({"max_tasks_total": 0, "bot_defaults": {"memory_mb": 2048},
                          "bot_overrides": {"coder": {"max_tasks_per_bot": 3, "browser_profile": "per_bot"}}}, base)
        self.assertEqual(s["max_tasks_total"], 0)
        self.assertEqual(iso.bot_settings(s, "coder")["max_tasks_per_bot"], 3)
        self.assertEqual(iso.bot_settings(s, "coder")["memory_mb"], 2048)
        self.assertEqual(iso.bot_settings(s, "other")["max_tasks_per_bot"], 1)
        s2 = iso.validate({"bot_overrides": {"coder": {"max_tasks_per_bot": None}}}, s)
        self.assertNotIn("max_tasks_per_bot", s2["bot_overrides"]["coder"])
        self.assertNotIn("coder", iso.validate({"bot_overrides": {"coder": None}}, s)["bot_overrides"])
        for bad in ({"max_tasks_total": -1}, {"nope": 1}, {"resolution": "big"}, {"mirror": "custom"},
                    {"bot_defaults": {"memory_mb": 10}}, {"bot_overrides": {"Bad ID": {}}}, {"system_lock": "yes"},
                    {"mirror_pip": "ftp://x"}, {"port_base": 65000}):
            with self.assertRaises(iso.SettingsError, msg=str(bad)):
                iso.validate(bad, base)
        self.assertEqual(base["max_tasks_total"], 3)  # 校验失败不修改原设置

    def test_recommend_scales_with_specs(self):
        small = iso.recommend({"cpu_cores": 1, "memory_mb": 1024})
        big = iso.recommend({"cpu_cores": 32, "memory_mb": 128 * 1024})
        self.assertEqual(small["max_tasks_total"], 1)
        self.assertGreater(big["max_tasks_total"], 8)
        self.assertEqual(big["bot_defaults"]["max_tasks_per_bot"], 2)
        iso.validate(big, iso.merged_with_defaults(None))  # 推荐值必须能通过校验
        iso.validate(small, iso.merged_with_defaults(None))

    def test_ports_skip_reserved_and_system_op(self):
        s = iso.validate({"port_base": 18760, "port_range": 10}, iso.merged_with_defaults(None))
        self.assertNotIn(18765, iso.bot_port_range(s, 0))
        self.assertTrue(iso.is_system_op("cd x && sudo apt-get install -y jq"))
        self.assertTrue(iso.is_system_op("pip install requests"))
        self.assertFalse(iso.is_system_op("ls -la; echo apt"))

    def test_gate_fifo_lane_and_global_caps(self):
        settings = iso.validate({"max_tasks_total": 2, "bot_overrides": {"b": {"max_tasks_per_bot": 2}}},
                                iso.merged_with_defaults(None))
        gate = iso.TaskGate(lambda: settings)
        self.assertEqual(gate.acquire("a1", "bot:a", "a"), 0)
        started, positions = [], []

        def worker(tid, lane, bot):
            started.append((tid, gate.acquire(tid, lane, bot, on_queued=positions.append)))

        t = threading.Thread(target=worker, args=("a2", "bot:a", "a"))
        t.start()
        time.sleep(0.3)
        self.assertEqual(started, [])          # 同一 Bot 默认一次一个
        self.assertEqual(positions, [1])
        self.assertEqual(gate.acquire("b1", "bot:b", "b"), 0)
        t2 = threading.Thread(target=worker, args=("b2", "bot:b", "b"))
        t2.start()
        time.sleep(0.3)
        self.assertEqual(started, [])          # 全局上限 2 已满
        gate.release("b1")
        t2.join(2)
        self.assertEqual(started, [("b2", 0)])
        gate.release("a1")
        t.join(2)
        self.assertEqual(started[-1], ("a2", 0))
        settings["max_tasks_total"] = 0
        self.assertEqual(gate.acquire("b3", "bot:b", "b"), 1)   # b 允许 2 个并发，第二个用槽 1


class IsolationServerTests(CloudServerTestCase):
    def test_01_resources_api(self):
        code, res = self.request("GET", "/v1/resources")
        self.assertEqual(code, 200)
        self.assertGreaterEqual(res["specs"]["cpu_cores"], 1)
        self.assertIn("recommended", res)
        self.assertEqual(res["usage"]["running_tasks"], 0)
        self.assertEqual(self.request("PUT", "/v1/resources", {"max_tasks_total": "3"})[0], 400)
        code, res = self.request("PUT", "/v1/resources", {"max_tasks_total": 5, "bot_overrides": {"iso": {"queue_cap": 1}}})
        self.assertEqual(code, 200, res)
        self.assertEqual(self.request("GET", "/v1/resources")[1]["settings"]["max_tasks_total"], 5)

    def test_02_bot_workspace_shared_dir_and_queue(self):
        self.request("PUT", "/v1/bots/iso", {"name": "隔离", "instructions": "x"})
        gate = threading.Event()

        def slow(d):
            if d["messages"][-1]["role"] == "tool":
                return {"role": "assistant", "content": "done"}
            gate.wait(10)
            return tool_call("s1", "shell_execute", {"command": "pwd; echo hi > $OPENMINIS_SHARED/x.txt; echo $PORT"})
        FakeModelHandler.scripts["m-iso"] = slow
        s1 = self.request("POST", "/v1/sessions", {"title": "a", "persona_id": "iso"})[1]["session_id"]
        s2 = self.request("POST", "/v1/sessions", {"title": "b", "persona_id": "iso"})[1]["session_id"]
        t1 = self.submit(s1, "one", "m-iso")[1]
        time.sleep(0.3)
        t2 = self.submit(s2, "two", "m-iso")[1]
        self.wait_until(lambda: any(e["type"] == "queued" for e in
                                    self.request("GET", f"/v1/tasks/{t2['task_id']}/events?after=0")[1]["events"]),
                        message="second task of same bot should queue")
        s3 = self.request("POST", "/v1/sessions", {"title": "c", "persona_id": "iso"})[1]["session_id"]
        code, res = self.submit(s3, "three", "m-iso")
        self.assertEqual(code, 429, res)       # queue_cap = 1
        gate.set()
        self.wait_status(t1["task_id"], ("completed",))
        self.wait_status(t2["task_id"], ("completed",))
        out = tool_turns(FakeModelHandler.requests[-1])[-1]["content"]
        self.assertIn(os.path.join("bots", "iso", "workspace"), out)
        self.assertIn("20020", out)            # iso 是第一个分到端口段的 Bot：20000 + 1×20
        code, res = self.request("GET", "/v1/bots/iso")
        self.assertEqual(res["resources"]["queue_cap"], 1)

    def test_03_background_job_reports_back(self):
        FakeModelHandler.scripts["m-bg"] = lambda d: (tool_call("b1", "shell_execute", {"command": "sleep 0.5; echo built", "background": True})
                                                      if d["messages"][-1]["role"] != "tool" else {"role": "assistant", "content": "后台中"})
        sid = self.new_session()
        t = self.submit(sid, "build", "m-bg")[1]
        self.wait_status(t["task_id"], ("completed",))
        self.assertIn("job_", tool_turns(FakeModelHandler.requests[-1])[-1]["content"])
        self.wait_until(lambda: any("[后台命令完成]" in (m.get("content") or "") for m in
                                    self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]), message="bg result")

    def test_04_desktop_display_fallback(self):
        self.request("PUT", "/v1/bots/disp", {"name": "屏", "instructions": "x"})
        code, res = self.request("POST", "/v1/desktop/display", {"bot_id": "disp"})
        self.assertEqual(code, 200)
        self.assertEqual(res["token"], "main")
        self.assertEqual(self.request("POST", "/v1/desktop/display", {"bot_id": "ghost"})[0], 404)


if __name__ == "__main__":
    unittest.main()
