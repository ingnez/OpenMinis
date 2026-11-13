#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""任务托盘：暂停 / 继续 / 重试；重启后在安全点保存进度并询问是否继续。新 Bot 默认先问我。"""

import json
import threading
import time
import unittest

import cloud_isolation
import cloud_workers
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns
from test_phase24_workers import last_user, fresh_tools, is_worker


class ProductDefaultAskTests(CloudServerTestCase):
    apply_approval_fixture = False

    def test_01_new_server_defaults_to_ask(self):
        self.assertEqual(cloud_isolation.DEFAULTS["bot_defaults"]["approval_mode"], "ask")
        merged = cloud_isolation.merged_with_defaults({})
        self.assertEqual(merged["bot_defaults"]["approval_mode"], "ask")
        self.assertEqual(cloud_isolation.bot_settings(merged, "newbie")["approval_mode"], "ask")
        code, body = self.request("GET", "/v1/resources")
        self.assertEqual(code, 200, body)
        self.assertEqual(body["settings"]["bot_defaults"]["approval_mode"], "ask")


class WorkerPauseResumeTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/credentials/wkp", {"api_key": "sk-inline-test-key-000000000000", "base_url": self.model_base})
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True,
                                              "model": "m-p1", "credential": "wkp"})
        self.gate = threading.Event()

    def tearDown(self):
        self.gate.set()

    def _front(self, worker_reply, title="慢任务"):
        def script(d):
            from test_phase24_workers import is_worker, last_user, fresh_tools
            if is_worker(d):
                return worker_reply(d)
            if "查一下" in last_user(d) and not fresh_tools(d):
                return tool_call("c0", "spawn_task", {"goal": "查一下 FAKE", "context": "假数据", "title": title})
            return {"role": "assistant", "content": "好，我在后台做。" if fresh_tools(d) else "在呢"}
        return script

    def _say(self, sid, text, model):
        tid = self.submit(sid, text, model)[1]["task_id"]
        self.wait_status(tid, {"completed"}, timeout=30)

    def _wait_worker(self, wid, statuses, timeout=30):
        deadline = time.time() + timeout
        w = {}
        while time.time() < deadline:
            w = self.request("GET", f"/v1/workers/{wid}")[1].get("worker") or {}
            if w.get("status") in statuses:
                return w
            time.sleep(0.1)
        self.fail(f"worker {wid} not {statuses}: {w}")

    def test_01_pause_resume_and_retry(self):
        started = threading.Event()

        def worker(d):
            if not tool_turns(d):
                started.set()
                return tool_call("s1", "shell_execute", {"command": "sleep 2; echo done-pause"})
            return {"role": "assistant", "content": "后台做完了"}

        FakeModelHandler.scripts["m-p1"] = self._front(worker)
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        self._say(sid, "查一下天气", "m-p1")
        self.assertTrue(started.wait(15), "后台还没开始干活")
        ws = self.request("GET", f"/v1/workers?session_id={sid}")[1]["workers"]
        self.assertTrue(ws)
        wid = ws[0]["worker_id"]
        self.assertTrue(ws[0].get("can_pause"))
        self.assertFalse(ws[0].get("can_resume"))
        code, body = self.request("POST", f"/v1/workers/{wid}/pause", {})
        self.assertEqual(code, 200, body)
        paused = self._wait_worker(wid, {"paused"})
        self.assertTrue(paused.get("can_resume"))
        self.assertFalse(paused.get("can_pause"))
        # 会话里仍可再开前台任务（paused 不占唯一进行中索引）
        FakeModelHandler.scripts["m-p1"] = lambda d: {"role": "assistant", "content": "前台还在"}
        st, res = self.submit(sid, "还在吗", "m-p1")
        self.assertIn(st, (200, 202), res)
        self.wait_status(res["task_id"], {"completed"})

        FakeModelHandler.scripts["m-p1"] = self._front(lambda d: {"role": "assistant", "content": "后台做完了"})
        code, body = self.request("POST", f"/v1/workers/{wid}/resume", {})
        self.assertEqual(code, 200, body)
        done = self._wait_worker(wid, {"completed"})
        self.assertIn("后台做完了", done.get("result") or "")

        # 失败任务可以重试
        conn = self.srv.get_db_connection()
        try:
            cloud_workers.set_status(conn, wid, "failed", result="上次失败（假）", finished_at=time.time())
        finally:
            conn.close()
        got = self.request("GET", f"/v1/workers/{wid}")[1]["worker"]
        self.assertTrue(got.get("can_retry"))
        code, body = self.request("POST", f"/v1/workers/{wid}/retry", {})
        self.assertEqual(code, 200, body)
        self._wait_worker(wid, {"completed", "running", "queued"})

    def test_02_saying_继续_without_card_does_not_resume(self):
        started = threading.Event()

        def worker(d):
            if not tool_turns(d):
                started.set()
                return tool_call("s1", "shell_execute", {"command": "sleep 2; echo stay-paused"})
            return {"role": "assistant", "content": "不该跑到这里"}
        FakeModelHandler.scripts["m-p1"] = self._front(worker)
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        self._say(sid, "查一下天气", "m-p1")
        self.assertTrue(started.wait(15))
        wid = self.request("GET", f"/v1/workers?session_id={sid}")[1]["workers"][0]["worker_id"]
        self.request("POST", f"/v1/workers/{wid}/pause", {})
        self._wait_worker(wid, {"paused"})
        FakeModelHandler.scripts["m-p1"] = lambda d: {"role": "assistant", "content": "你说继续我先记下"}
        st, res = self.submit(sid, "继续", "m-p1")
        self.assertIn(st, (200, 202), res)
        self.wait_status(res["task_id"], {"completed"})
        time.sleep(0.3)
        self.assertEqual(self.request("GET", f"/v1/workers/{wid}")[1]["worker"]["status"], "paused")

    def test_03_reject_resume_card_keeps_paused(self):
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "boss"})[1]["session_id"]
        conn = self.srv.get_db_connection()
        try:
            w = cloud_workers.create(conn, "boss", sid, "整理 FAKE", title="整理")
            conn.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES ('task_fakepause', ?, NULL, 'running', 'm', ?)",
                         (w["worker_session"], time.time()))
            conn.commit()
            cloud_workers.set_status(conn, w["worker_id"], "running", task_id="task_fakepause", started_at=time.time())
            cloud_workers.set_runtime(conn, w["worker_id"], "m-p1", {"credential": "wkp", "protocol": "chat"})
        finally:
            conn.close()
        self.srv.init_db()
        got = self.request("GET", f"/v1/workers/{w['worker_id']}")[1]["worker"]
        self.assertEqual(got["status"], "paused")
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        cards = [m for m in msgs if m["role"] == "assistant" and "要继续吗" in (m.get("content") or "")]
        self.assertEqual(len(cards), 1)
        FakeModelHandler.scripts["m-p1"] = lambda d: {"role": "assistant", "content": "好，先放着"}
        self.submit(sid, "先不用", "m-p1", choice_answer={"message_id": cards[0]["id"], "selected": ["2"]})
        time.sleep(0.3)
        self.assertEqual(self.request("GET", f"/v1/workers/{w['worker_id']}")[1]["worker"]["status"], "paused")


if __name__ == "__main__":
    unittest.main()
