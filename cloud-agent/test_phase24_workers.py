#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 24：前台聊天、后台干活（spawn_task / task_status / task_message / task_stop / task_resume）。"""

import json
import threading
import time
import unittest
from unittest import mock
from unittest.mock import patch

import cloud_workers
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


def system_of(req):
    return req["messages"][0]["content"]


def is_worker(req):
    return "[后台任务]" in system_of(req)


def last_user(req):
    return [m for m in req["messages"] if m.get("role") == "user"][-1]["content"]


def fresh_tools(req):
    """本轮（最后一条用户消息之后）的工具结果；历史里之前几轮的不算。"""
    msgs = req["messages"]
    last = max(i for i, m in enumerate(msgs) if m.get("role") == "user")
    return [m for m in msgs[last:] if m.get("role") == "tool"]


def tool_names(req):
    return {t["function"]["name"] for t in req.get("tools") or []}


class WorkerTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True})
        self.request("PUT", "/v1/bots/helper", {"name": "助手", "instructions": "你是助手"})
        self.request("PUT", "/v1/bots/boss/reply", {"mode": "verbose", "front_model": "", "back_model": ""})
        self.request("PUT", "/v1/bots/boss", {"model": None, "credential": None})
        self.gate = threading.Event()

    def tearDown(self):
        self.gate.set()

    def _front_script(self, worker_reply, spawn_args=None, extra=None):
        def script(d):
            if is_worker(d):
                return worker_reply(d)
            if extra:
                r = extra(d)
                if r:
                    return r
            if "查一下" in last_user(d) and not fresh_tools(d):
                return tool_call("c0", "spawn_task", spawn_args or {"goal": "查一下 FAKE 价格并写结论", "context": "用户在上海", "title": "查价格"})
            return {"role": "assistant", "content": "好，我在后台做，做完告诉你。" if fresh_tools(d) else "随便聊：今天天气不错"}
        return script

    def _say(self, sid, text, model):
        tid = self.submit(sid, text, model)[1]["task_id"]
        self.wait_status(tid, {"completed"}, timeout=30)

    def _wait_worker(self, wid, statuses, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            w = self.request("GET", f"/v1/workers/{wid}")[1].get("worker") or {}
            if w.get("status") in statuses:
                return w
            time.sleep(0.1)
        self.fail(f"worker {wid} not {statuses}: {w}")

    def _workers(self, sid):
        return self.request("GET", f"/v1/workers?session_id={sid}")[1]["workers"]

    def _results(self, sid):
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        return [m for m in msgs if m["role"] == "assistant" and "后台任务" in (m.get("content") or "")]

    def _wait_results(self, sid, n=1, timeout=20):
        deadline = time.time() + timeout
        while time.time() < deadline:
            r = self._results(sid)
            if len(r) >= n:
                return r
            time.sleep(0.1)
        self.fail("结果没有发回前台")

    def test_stream_failure_shows_worker_error_in_chat(self):
        FakeModelHandler.scripts["worker-stream-error"] = self._front_script(
            lambda _req: {"_chunks": [{"error": {"message": "后台模型服务暂不可用"}}], "_delay": 0})
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        self._say(sid, "查一下资料", "worker-stream-error")
        worker = self._workers(sid)[0]
        failed = self._wait_worker(worker["worker_id"], {"failed"}, timeout=10)
        self.assertIn("后台模型服务暂不可用", failed["result"])
        delivered = self._wait_results(sid, timeout=10)
        self.assertTrue(any("后台任务失败" in m["content"] and "后台模型服务暂不可用" in m["content"] for m in delivered))

    def test_worker_turn_limit_is_opt_in_and_outcomes_keep_task_metadata(self):
        def work(req):
            step = len(fresh_tools(req))
            if step < 5:
                return tool_call(f"step-{step}", "shell_execute", {"command": f"echo step-{step}"})
            return {"role": "assistant", "content": "五个步骤均已完成"}

        model = "worker-turns"
        FakeModelHandler.scripts[model] = self._front_script(work, {"goal": "检查文件", "title": "文件核对"})
        for limit, status in ((0, "completed"), (2, "limit_reached")):
            with self.subTest(limit=limit), mock.patch.object(self.srv, "MAX_TURNS", 2), \
                    mock.patch.object(self.srv, "WORKER_MAX_TURNS", limit):
                sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
                self._say(sid, "查一下资料", model)
                worker = self._workers(sid)[0]
                done = self._wait_worker(worker["worker_id"], {status}, timeout=10)
                self.assertIn("五个步骤" if not limit else "2 轮上限", done["result"])
                outcomes = self._wait_results(sid, timeout=10)
                row = next(m for m in outcomes if m.get("worker_id") == worker["worker_id"])
                self.assertEqual((row["worker_status"], row["worker_title"]), (status, "文件核对"))

    def test_voice_dispatch_executes_tools_and_replayed_receipt_keeps_one_worker(self):
        def executor(req):
            if not is_worker(req):
                return {"role": "assistant", "content": "错误：语音任务绕到前台"}
            if not fresh_tools(req):
                return tool_call("actual-voice-tool", "shell_execute", {"command": "echo voice-work-proof"})
            return {"role": "assistant", "content": "已核验语音任务的工具输出"}

        FakeModelHandler.scripts["voice-work"] = executor
        self.request("PUT", "/v1/bots/boss/reply", {"front_model": "unneeded-front", "back_model": "voice-work"})
        sid = self.request("POST", "/v1/sessions", {"title": "语音对话", "persona_id": "boss"})[1]["session_id"]
        body = {"goal": "用云电脑核验工具输出", "model": "unneeded-front",
                "provider": {"base_url": self.model_base, "api_key": "sk-inline-test-key-000000000000"},
                "client_nonce": "voice-execution-test"}
        first_status, first = self.request("POST", f"/v1/sessions/{sid}/voice-tasks", body)
        second_status, second = self.request("POST", f"/v1/sessions/{sid}/voice-tasks", body)
        self.assertEqual((first_status, second_status), (202, 202))
        wid = first["worker"]["worker_id"]
        self.assertEqual(second["worker"]["worker_id"], wid)
        worker = self._wait_worker(wid, {"completed"}, timeout=10)
        events = self.request("GET", f"/v1/tasks/{worker['task_id']}")[1]["events"]
        results = [e for e in events if e["type"] == "tool_result"]
        self.assertTrue(any("voice-work-proof" in json.dumps(e["payload"]) for e in results))
        self.assertEqual(len(self._workers(sid)), 1)
        self.assertIn("已核验语音任务的工具输出", self._wait_results(sid)[0]["content"])

    def test_01_spawn_ack_chat_isolated_and_result_posted_once(self):
        def worker(d):
            self.gate.wait(20)
            return {"role": "assistant", "content": "FAKE 价格是 42 元"}
        FakeModelHandler.scripts["m-w1"] = self._front_script(worker)
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        self._say(sid, "帮我查一下价格", "m-w1")
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        self.assertEqual(msgs[-1]["content"], "好，我在后台做，做完告诉你。")
        ws = self._workers(sid)
        self.assertEqual(len(ws), 1)
        w = ws[0]
        self.assertEqual(w["status"], "running")
        self.assertEqual(w["title"], "查价格")
        self.assertNotIn("context", w)
        before = self.request("GET", f"/v1/sessions/{w['worker_session']}")[1]["messages"]
        self.assertIn("用户在上海", before[0]["content"])
        self.assertNotIn("帮我查一下价格", json.dumps(before, ensure_ascii=False))   # worker 看不到前台聊天
        # 任务在跑的时候闲聊：前台直接回答，worker 历史不变；前台上下文里只有一行摘要
        self._say(sid, "随便聊两句", "m-w1")
        front_req = [r for r in FakeModelHandler.requests if not is_worker(r) and "随便聊两句" in json.dumps(r, ensure_ascii=False)][-1]
        self.assertIn("「查价格」进行中", json.dumps(front_req, ensure_ascii=False))
        self.assertIn("spawn_task", tool_names(front_req))
        self.assertEqual(self.request("GET", f"/v1/sessions/{w['worker_session']}")[1]["messages"], before)
        self.gate.set()
        done = self._wait_worker(w["worker_id"], {"completed"})
        self.assertEqual(done["result"], "FAKE 价格是 42 元")
        res = self._wait_results(sid)
        self.assertIn("FAKE 价格是 42 元", res[0]["content"])
        time.sleep(0.5)
        conn = self.srv.get_db_connection()
        try:
            self.assertFalse(cloud_workers.post_result(conn, cloud_workers.get(conn, w["worker_id"])))   # 台账：只发一次
        finally:
            conn.close()
        self.assertEqual(len(self._results(sid)), 1)
        # worker 会话不出现在 Bot 的对话列表里，也不能再派后台任务
        listed = [s["session_id"] for s in self.request("GET", "/v1/sessions?bot=boss")[1]["sessions"]]
        self.assertIn(sid, listed)
        self.assertNotIn(w["worker_session"], listed)
        wreq = [r for r in FakeModelHandler.requests if is_worker(r)][-1]
        self.assertFalse(tool_names(wreq) & self.srv.WORKER_FRONT_TOOLS)
        self.assertNotIn("[前台对话]", system_of(wreq))

    def test_worker_delivers_reminder_draft_to_front(self):
        def worker(request):
            if not fresh_tools(request):
                return tool_call("draft1", "reminder_draft", {"title": "复核构建", "due": "2026-11-14"})
            return {"role": "assistant", "content": "待办草稿已准备"}

        FakeModelHandler.scripts["worker-reminder"] = self._front_script(worker)
        sid = self.new_session()
        self._say(sid, "查一下并准备苹果提醒事项", "worker-reminder")
        result = self._wait_results(sid)[0]
        self.assertEqual(result["reminder_draft"], {"title": "复核构建", "notes": "", "due": "2026-11-14"})

    def test_worker_delivers_file_to_front(self):
        def worker(request):
            if not fresh_tools(request):
                return tool_call("worker_file", "file_write",
                                 {"path": "handoff.txt", "content": "deliverable content"})
            return {"role": "assistant", "content": "文件已准备"}

        FakeModelHandler.scripts["worker-file"] = self._front_script(worker)
        sid = self.new_session()
        self._say(sid, "查一下并生成交班文件", "worker-file")
        result = self._wait_results(sid)[0]
        matches = [item for item in result["deliverables"] if item["name"] == "handoff.txt"]
        self.assertEqual(len(matches), 1)
        self.assertTrue(matches[0]["url"].startswith(f"/v1/sessions/{sid}/deliveries/"))

    def test_01b_worker_waits_for_front_and_notifies_once(self):
        front_entered, front_release = threading.Event(), threading.Event()

        def worker(_):
            self.gate.wait(10)
            return {"role": "assistant", "content": "后台交付样例"}

        def extra(d):
            if last_user(d).startswith("前台还在回复"):
                front_entered.set()
                front_release.wait(10)
                return {"role": "assistant", "content": "前台这条先答完"}
            return None

        FakeModelHandler.scripts["m-roles"] = self._front_script(worker, extra=extra)
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        with patch.object(self.srv, "user_notify") as notify:
            self._say(sid, "查一下价格", "m-roles")
            w = self._workers(sid)[0]
            tid = self.submit(sid, "前台还在回复", "m-roles")[1]["task_id"]
            try:
                self.assertTrue(front_entered.wait(5))
                self.srv.on_background_done({
                    "session_id": w["worker_session"], "job_id": "command-test",
                    "exit_code": 0, "command": "echo test",
                }, "test")
                self.gate.set()
                self._wait_worker(w["worker_id"], {"completed"}, timeout=5)
                conn = self.srv.get_db_connection()
                try:
                    self.assertIsNone(cloud_workers.post_result(
                        conn, cloud_workers.get(conn, w["worker_id"]), defer_while_front_active=True
                    ))
                finally:
                    conn.close()
                self.assertEqual(self._results(sid), [])
            finally:
                front_release.set()
            self.wait_status(tid, {"completed"}, timeout=10)
            result = self._wait_results(sid)[0]["content"]
            deadline = time.monotonic() + 3
            result_notifications = []
            while time.monotonic() < deadline:
                result_notifications = [
                    c for c in notify.call_args_list
                    if c.kwargs.get("session_id") == sid and c.args[2].startswith("后台任务：")
                ]
                if result_notifications:
                    break
                time.sleep(0.03)
            self.assertEqual(len(result_notifications), 1)
            self.assertEqual(result_notifications[0].kwargs["session_id"], sid)
            self.assertFalse(any(c.kwargs.get("session_id") == w["worker_session"] for c in notify.call_args_list))

        messages = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        self.assertEqual([m["content"] for m in messages[-2:]], ["前台这条先答完", result])
        self.assertIn("后台交付样例", result)

    def test_02_task_message_reaches_worker(self):
        def worker(d):
            if "改成蓝色" in json.dumps(d["messages"], ensure_ascii=False):
                return {"role": "assistant", "content": "final: blue"}
            self.gate.wait(20)
            return {"role": "assistant", "content": "draft: red"}

        def extra(d):
            if "改成蓝色" in last_user(d) and not fresh_tools(d):
                wid = self._workers(self.sid)[0]["worker_id"]
                return tool_call("c1", "task_message", {"id": wid, "text": "改成蓝色"})
            return None
        FakeModelHandler.scripts["m-w2"] = self._front_script(worker, extra=extra)
        self.sid = sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        self._say(sid, "帮我查一下颜色", "m-w2")
        wid = self._workers(sid)[0]["worker_id"]
        self._say(sid, "对了，改成蓝色", "m-w2")
        tr = [m for m in self.request("GET", f"/v1/sessions/{sid}")[1]["messages"] if m["role"] == "tool"]
        self.assertIn('"delivered": "running"', tr[-1]["content"])
        self.gate.set()
        w = self._wait_worker(wid, {"completed"})
        self.assertEqual(w["result"], "final: blue")

    def test_03_stop(self):
        def worker(d):
            self.gate.wait(20)
            return {"role": "assistant", "content": "should not matter"}

        def extra(d):
            if "停" in last_user(d) and not fresh_tools(d):
                return tool_call("c1", "task_stop", {"id": self._workers(self.sid)[0]["worker_id"]})
            return None
        FakeModelHandler.scripts["m-w3"] = self._front_script(worker, extra=extra)
        self.sid = sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        self._say(sid, "帮我查一下天气", "m-w3")
        wid = self._workers(sid)[0]["worker_id"]
        self._say(sid, "算了，停下", "m-w3")
        self.gate.set()
        w = self._wait_worker(wid, {"cancelled"})
        self.assertIsNone(w["result"])
        self.assertIn("已停止", self._wait_results(sid)[0]["content"])
        # App 里的停止按钮：对已结束的任务也安全
        self.assertEqual(self.request("POST", f"/v1/workers/{wid}/stop", {})[1]["worker"]["status"], "cancelled")

    def test_04_restart_pauses_and_asks_to_resume(self):
        self.request("PUT", "/v1/credentials/wk4", {"api_key": "sk-inline-test-key-000000000000", "base_url": self.model_base})
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True,
                                              "model": "m-w4", "credential": "wk4"})
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        conn = self.srv.get_db_connection()
        try:
            w = cloud_workers.create(conn, "boss", sid, "整理 FAKE 报告", title="整理报告")
            conn.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES ('task_fakerestart', ?, NULL, 'running', 'm', ?)",
                         (w["worker_session"], time.time()))
            conn.commit()
            cloud_workers.set_status(conn, w["worker_id"], "running", task_id="task_fakerestart", started_at=time.time())
            cloud_workers.set_runtime(conn, w["worker_id"], "m-w4", {"credential": "wk4", "protocol": "chat"})
        finally:
            conn.close()
        self.srv.init_db()       # 模拟重启：应暂停并问要不要继续
        self.srv.init_db()       # 再重启一次也不会重复发选项卡
        got = self.request("GET", f"/v1/workers/{w['worker_id']}")[1]["worker"]
        self.assertEqual(got["status"], "paused")
        self.assertTrue(got.get("can_resume"))
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        cards = [m for m in msgs if m["role"] == "assistant" and "要继续吗" in (m.get("content") or "")]
        self.assertEqual(len(cards), 1)
        self.assertNotIn("中断", cards[0]["content"])

        def worker(d):
            return {"role": "assistant", "content": "报告整理好了"}
        FakeModelHandler.scripts["m-w4"] = self._front_script(worker)
        status, body = self.submit(sid, "继续", "m-w4", choice_answer={"message_id": cards[0]["id"], "selected": ["1"]})
        self.assertIn(status, (200, 202), body)
        done = self._wait_worker(w["worker_id"], {"completed"})
        self.assertEqual(done["result"], "报告整理好了")
        res = self._wait_results(sid, 1)
        self.assertTrue(any("报告整理好了" in (m.get("content") or "") for m in res))

    def test_05_soft_cap_queues(self):
        old = cloud_workers.SOFT_CAP
        cloud_workers.SOFT_CAP = 1
        try:
            def worker(d):
                self.gate.wait(20)
                return {"role": "assistant", "content": "done " + last_user(d)[:12]}
            FakeModelHandler.scripts["m-w5"] = self._front_script(worker)
            sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "helper"})[1]["session_id"]
            self._say(sid, "查一下 A", "m-w5")
            self._say(sid, "查一下 B", "m-w5")
            ws = sorted(self._workers(sid), key=lambda w: w["created_at"])
            self.assertEqual([w["status"] for w in ws], ["running", "queued"])
            bots = self.request("GET", "/v1/bots")[1]["bots"]
            self.assertEqual(next(b for b in bots if b["bot_id"] == "helper").get("running_workers"), 2)
            self.gate.set()
            for w in ws:
                self._wait_worker(w["worker_id"], {"completed"})
            self.assertEqual(len(self._wait_results(sid, 2)), 2)
        finally:
            cloud_workers.SOFT_CAP = old


if __name__ == "__main__":
    unittest.main()
