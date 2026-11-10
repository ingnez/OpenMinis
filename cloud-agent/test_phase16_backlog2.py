#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第二批：主动消息（[SKIP] 不打扰）等。"""

import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler


class ProactiveTests(CloudServerTestCase):
    def test_01_quiet_result_does_not_notify(self):
        sent = []
        orig = self.srv.user_notify
        self.srv.user_notify = lambda *a, **k: sent.append(a)
        try:
            r = {"name": "主动消息", "notify": True, "persona_id": None}
            self.srv.on_routine_finished(r, {"status": "completed", "result": "[SKIP] 今天没什么要说的"})
            self.srv.on_routine_finished(r, {"status": "completed", "result": "  [静默]"})
            self.assertEqual(sent, [])
            self.srv.on_routine_finished(r, {"status": "completed", "result": "明天 8 点有会，记得带资料"})
            self.assertEqual(len(sent), 1)
            # 失败仍然通知
            self.srv.on_routine_finished(r, {"status": "failed", "error": "[SKIP]"})
            self.assertEqual(len(sent), 2)
        finally:
            self.srv.user_notify = orig



class AutoModelTests(CloudServerTestCase):
    def test_01_simple_question_uses_fast_model_and_falls_back(self):
        import cloud_efficiency as eff
        self.assertTrue(eff.is_simple_request("你好"))
        self.assertTrue(eff.is_simple_request("今天星期几？"))
        self.assertFalse(eff.is_simple_request("帮我查一下明天的航班"))
        self.assertFalse(eff.is_simple_request("写一个 Python 脚本"))
        self.assertFalse(eff.is_simple_request("看看 https://example.com"))
        self.assertFalse(eff.is_simple_request([{"type": "text", "text": "hi"}]))
        self.assertFalse(eff.is_simple_request("x" * 200))

        FakeModelHandler.scripts["m-fast"] = lambda d: {"role": "assistant", "content": "快速回答"}
        FakeModelHandler.scripts["m-main"] = lambda d: {"role": "assistant", "content": "主模型回答"}
        self.assertEqual(self.request("PUT", "/v1/resources", {"auto_model": True, "fast_model": "m-fast"})[0], 200)
        try:
            sid = self.new_session()
            res = self.wait_status(self.submit(sid, "你好", "m-main")[1]["task_id"], ("completed", "failed"))
            self.assertEqual(res["status"], "completed")
            texts = [m.get("content") for m in self.request("GET", f"/v1/sessions/{sid}")[1]["messages"] if m.get("role") == "assistant"]
            self.assertIn("快速回答", texts)
            res = self.wait_status(self.submit(sid, "帮我写一份值班计划", "m-main")[1]["task_id"], ("completed", "failed"))
            texts = [m.get("content") for m in self.request("GET", f"/v1/sessions/{sid}")[1]["messages"] if m.get("role") == "assistant"]
            self.assertEqual(texts[-1], "主模型回答")
            # 快速模型出错：同一任务换回主模型
            FakeModelHandler.scripts["m-fast"] = lambda d: {"_status": 404}
            res = self.wait_status(self.submit(sid, "在吗", "m-main")[1]["task_id"], ("completed", "failed"))
            self.assertEqual(res["status"], "completed", res)
            texts = [m.get("content") for m in self.request("GET", f"/v1/sessions/{sid}")[1]["messages"] if m.get("role") == "assistant"]
            self.assertEqual(texts[-1], "主模型回答")
        finally:
            self.request("PUT", "/v1/resources", {"auto_model": False, "fast_model": ""})



class DutyModeTests(CloudServerTestCase):
    def test_01_duty_note_and_quiet_proactive(self):
        import time
        FakeModelHandler.scripts["m-duty"] = lambda d: {"role": "assistant", "content": "ok"}
        self.assertEqual(self.request("PUT", "/v1/resources", {"duty_until": "x"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/resources", {"duty_until": time.time() + 3600})[0], 200)
        try:
            sid = self.new_session()
            self.wait_status(self.submit(sid, "去甲肾上腺素泵速", "m-duty")[1]["task_id"], ("completed",))
            req = FakeModelHandler.requests[-1]
            self.assertIn("值班模式", req["messages"][-1]["content"])
            self.assertNotIn("值班模式", req["messages"][0]["content"])
            sent = []
            orig = self.srv.user_notify
            self.srv.user_notify = lambda *a, **k: sent.append(a)
            try:
                self.srv.on_routine_finished({"name": "主动消息 · 总管", "notify": True}, {"status": "completed", "result": "明天有考试"})
                self.assertEqual(sent, [])
                self.srv.on_routine_finished({"name": "每日简报", "notify": True}, {"status": "completed", "result": "x"})
                self.assertEqual(len(sent), 1)
            finally:
                self.srv.user_notify = orig
        finally:
            self.request("PUT", "/v1/resources", {"duty_until": 0})
        sid = self.new_session()
        self.wait_status(self.submit(sid, "你好", "m-duty")[1]["task_id"], ("completed",))
        self.assertNotIn("值班模式", FakeModelHandler.requests[-1]["messages"][-1]["content"])



class FeedTests(CloudServerTestCase):
    def test_01_feed_lists_recent_non_quiet_results(self):
        import time, uuid
        conn = self.srv.get_db_connection()
        try:
            now = time.time()
            for rid, name in (("rtn_feed00000001", "主动消息 · 总管"), ("rtn_feed00000002", "每日简报")):
                conn.execute("INSERT INTO routines (routine_id, name, prompt, schedule, credential, model, enabled, run_count, notify, created_at, updated_at) "
                             "VALUES (?, ?, 'p', '{}', 'c', 'm', 1, 0, 1, ?, ?)", (rid, name, now, now))
            rows = [("rtn_feed00000001", "明早 8 点交班，记得带记录", now - 60), ("rtn_feed00000001", "[SKIP]", now - 30),
                    ("rtn_feed00000002", "今日要闻三条", now - 10), ("rtn_feed00000002", "很久以前", now - 3 * 86400)]
            for rid, res, at in rows:
                conn.execute("INSERT INTO routine_runs (run_id, routine_id, task_id, session_id, trigger, status, result, error, started_at, finished_at) "
                             "VALUES (?, ?, NULL, 'sess_x', 'schedule', 'completed', ?, NULL, ?, ?)", ("run_" + uuid.uuid4().hex[:12], rid, res, at, at))
            conn.commit()
        finally:
            conn.close()
        items = self.request("GET", "/v1/feed")[1]["items"]
        self.assertEqual([i["text"] for i in items], ["今日要闻三条", "明早 8 点交班，记得带记录"])
        self.assertTrue(items[1]["proactive"])



class IncognitoTests(CloudServerTestCase):
    def test_01_incognito_session_hidden_no_memory_and_deletable(self):
        sid = self.request("POST", "/v1/sessions", {"title": "无痕", "incognito": True})[1]["session_id"]
        normal = self.request("POST", "/v1/sessions", {"title": "普通"})[1]["session_id"]
        listed = [x["session_id"] for x in self.request("GET", "/v1/sessions")[1]["sessions"]]
        self.assertIn(normal, listed)
        self.assertNotIn(sid, listed)
        res = self.srv.tool_memory_write("t_x", sid, {"content": "不该被记住", "category": "note"})
        self.assertFalse(res["saved"])
        self.assertEqual(self.request("DELETE", "/v1/sessions/" + normal)[0], 400)
        self.assertEqual(self.request("DELETE", "/v1/sessions/" + sid)[0], 200)
        self.assertEqual(self.request("GET", "/v1/sessions/" + sid)[0], 404)

    def test_02_stale_incognito_purged(self):
        import time
        sid = self.request("POST", "/v1/sessions", {"title": "旧", "incognito": True})[1]["session_id"]
        conn = self.srv.get_db_connection()
        try:
            self.assertEqual(self.srv.purge_stale_incognito(conn, time.time() + 2 * 86400), 1)
            conn.commit()
            self.assertIsNone(conn.execute("SELECT 1 FROM sessions WHERE session_id = ?", (sid,)).fetchone())
        finally:
            conn.close()



class AuditTests(CloudServerTestCase):
    def test_01_file_write_edit_undo(self):
        import os
        sid = self.request("POST", "/v1/sessions", {"title": "审计"})[1]["session_id"]
        self.assertEqual(self.srv.tool_file_write("t_a", sid, {"path": "notes/a.txt", "content": "v1"})["status"], "success")
        self.srv.tool_file_edit("t_a", sid, {"path": "notes/a.txt", "old_string": "v1", "new_string": "v2"})
        target, _ = self.srv.safe_path_resolve(sid, "notes/a.txt")
        items = self.request("GET", "/v1/audit")[1]["items"]
        edit, create = items[0], items[1]
        self.assertEqual(edit["tool"], "file_edit")
        self.assertTrue(edit["undoable"])
        self.assertEqual(self.request("POST", f"/v1/audit/{edit['id']}/undo", {})[0], 200)
        with open(target, encoding="utf-8") as f:
            self.assertEqual(f.read(), "v1")
        self.assertEqual(self.request("POST", f"/v1/audit/{edit['id']}/undo", {})[0], 400)
        self.assertEqual(self.request("POST", f"/v1/audit/{create['id']}/undo", {})[0], 200)
        self.assertFalse(os.path.exists(target))

    def test_02_memory_write_undo(self):
        sid = self.request("POST", "/v1/sessions", {"title": "审计记忆"})[1]["session_id"]
        res = self.srv.tool_memory_write("t_m", sid, {"content": "用户喜欢黑咖啡 审计测试", "category": "profile"})
        self.assertTrue(res["saved"])
        item = self.request("GET", "/v1/audit")[1]["items"][0]
        self.assertEqual(item["tool"], "memory_write")
        self.assertEqual(self.request("POST", f"/v1/audit/{item['id']}/undo", {})[0], 200)
        conn = self.srv.get_db_connection()
        try:
            self.assertIsNone(conn.execute("SELECT 1 FROM memory_entries WHERE id = ?", (res["id"],)).fetchone())
        finally:
            conn.close()



class BotVersionTests(CloudServerTestCase):
    def test_01_edit_creates_version_and_restore(self):
        self.assertIn(self.request("PUT", "/v1/bots/verbot", {"name": "版本", "instructions": "v1 指令"})[0], (200, 201))
        self.request("PUT", "/v1/bots/verbot", {"instructions": "v1 指令"})   # 没变：不存版本
        self.assertEqual(self.request("GET", "/v1/bots/verbot/versions")[1]["versions"], [])
        self.request("PUT", "/v1/bots/verbot", {"instructions": "v2 指令", "fast_mode": True})
        versions = self.request("GET", "/v1/bots/verbot/versions")[1]["versions"]
        self.assertEqual(len(versions), 1)
        self.assertEqual(versions[0]["snapshot"]["instructions"], "v1 指令")
        code, bot = self.request("POST", f"/v1/bots/verbot/versions/{versions[0]['id']}/restore", {})
        self.assertEqual(code, 200)
        self.assertEqual(bot["instructions"], "v1 指令")
        self.assertFalse(bot["fast_mode"])
        # 恢复前的设置也存成了版本
        self.assertEqual(self.request("GET", "/v1/bots/verbot/versions")[1]["versions"][0]["snapshot"]["instructions"], "v2 指令")
        self.assertEqual(self.request("POST", "/v1/bots/verbot/versions/999999/restore", {})[0], 400)



class WorkflowTriggerTests(CloudServerTestCase):
    def test_01_after_schedule_chains_with_context_and_depth_limit(self):
        self.request("PUT", "/v1/credentials/wf", {"api_key": "sk-workflow-test-000000000000", "base_url": self.model_base})
        base = {"model": "m-wf", "credential": "wf", "enabled": True}
        up = self.request("POST", "/v1/routines", dict(base, name="抓取", prompt="抓数据", schedule={"kind": "interval", "seconds": 3600}))[1]
        code, down = self.request("POST", "/v1/routines", dict(base, name="总结", prompt="总结上一步",
                                                                 schedule={"kind": "after", "routine_id": up["routine_id"]}))
        self.assertEqual(code, 201, down)
        self.assertIsNone(down["next_run_at"])
        self.assertEqual(self.request("POST", "/v1/routines", dict(base, name="坏", prompt="x",
                                                                   schedule={"kind": "after", "routine_id": "rtn_000000000000"}))[0], 400)
        launched = []
        orig = self.srv.launch_routine_run
        self.srv.launch_routine_run = lambda r, trigger="schedule", context=None: launched.append((r["name"], trigger, context)) or {}
        try:
            self.srv.fire_followups(up, {"status": "completed", "result": "数据 42 条", "trigger": "schedule"})
            self.assertEqual(launched[0][0], "总结")
            self.assertEqual(launched[0][1], "after:1")
            self.assertIn("数据 42 条", launched[0][2])
            launched.clear()
            self.srv.fire_followups(up, {"status": "completed", "result": "[SKIP]", "trigger": "schedule"})
            self.srv.fire_followups(up, {"status": "failed", "error": "x", "trigger": "schedule"})
            self.srv.fire_followups(up, {"status": "completed", "result": "y", "trigger": "after:3"})
            self.assertEqual(launched, [])
        finally:
            self.srv.launch_routine_run = orig



class PrivateBotNotifyTests(CloudServerTestCase):
    def test_01_locked_bot_notifications_are_redacted(self):
        self.assertEqual(self.request("PUT", "/v1/resources", {"private_bots": ["secretbot"]})[0], 200)
        self.assertEqual(self.request("PUT", "/v1/resources", {"private_bots": ["Bad Id"]})[0], 400)
        added = []
        orig = self.srv.APP_FEED.add
        self.srv.APP_FEED.add = lambda kind, title, body, **k: added.append((title, body))
        try:
            self.srv.user_notify(None, "reply", "秘密 Bot 回复了", "化验结果：阳性", bot_id="secretbot")
            self.srv.user_notify(None, "reply", "总管回复了", "明天见", bot_id="other")
        finally:
            self.srv.APP_FEED.add = orig
            self.request("PUT", "/v1/resources", {"private_bots": []})
        self.assertEqual(added[0], ("OpenMinis", "有一条新消息（已上锁的 Bot）"))
        self.assertEqual(added[1], ("总管回复了", "明天见"))



class SharedLibraryTests(CloudServerTestCase):
    def test_01_share_link_to_other_bots(self):
        import time
        for b in ("liba", "libb"):
            self.request("PUT", f"/v1/bots/{b}", {"name": b, "instructions": "x"})
        sid = self.request("POST", "/v1/sessions", {"title": "资料", "persona_id": "liba"})[1]["session_id"]
        conn = self.srv.get_db_connection()
        try:
            conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'assistant', ?, ?)",
                         (sid, "指南见 https://example.org/guide 和 https://example.org/other", time.time()))
            conn.commit()
        finally:
            conn.close()
        items = self.request("GET", "/v1/bots/liba/library")[1]["items"]
        guide = next(i for i in items if i.get("url") == "https://example.org/guide")
        self.assertEqual(self.request("GET", "/v1/bots/libb/library")[1]["items"], [])
        self.assertEqual(self.request("POST", f"/v1/bots/liba/library/{guide['id']}/share", {"shared": True})[0], 200)
        self.assertEqual(self.request("POST", "/v1/bots/libb/library/nope/share", {})[0], 404)
        b_items = self.request("GET", "/v1/bots/libb/library")[1]["items"]
        self.assertEqual([i["url"] for i in b_items], ["https://example.org/guide"])
        self.assertEqual(b_items[0]["shared_from"], "liba")
        self.assertTrue(next(i for i in self.request("GET", "/v1/bots/liba/library")[1]["items"] if i["id"] == guide["id"])["shared"])
        # 在 B 里移除只影响 B
        self.assertEqual(self.request("DELETE", f"/v1/bots/libb/library/{guide['id']}")[0], 200)
        self.assertEqual(self.request("GET", "/v1/bots/libb/library")[1]["items"], [])
        self.assertTrue(any(i["id"] == guide["id"] for i in self.request("GET", "/v1/bots/liba/library")[1]["items"]))



class DesktopStreamTests(CloudServerTestCase):
    def _connect(self, token):
        import base64, os, socket
        sock = socket.create_connection(("127.0.0.1", self.api_port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((f"GET /v1/desktop/stream?fps=5 HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n\r\n").encode())
        return sock, key

    def test_01_streams_changed_frames_and_closes(self):
        import cloud_ws, os, struct
        frames = iter([b"\xff\xd8A", b"\xff\xd8A", b"\xff\xd8B"] + [b"\xff\xd8B"] * 100)
        orig = self.srv.desktop_frame
        self.srv.desktop_frame = lambda display, width: (next(frames), "image/jpeg")
        try:
            sock, key = self._connect(self.token)
            f = sock.makefile("rb")
            status = f.readline()
            self.assertIn(b"101", status)
            headers = {}
            while True:
                line = f.readline().strip()
                if not line:
                    break
                k, v = line.decode().split(":", 1)
                headers[k.lower()] = v.strip()
            self.assertEqual(headers["sec-websocket-accept"], cloud_ws.accept_key(key))
            got = []
            while len(got) < 2:
                h = f.read(2)
                n = h[1] & 0x7F
                got.append((h[0] & 0x0F, f.read(n)))
            # 相同的画面不重复发
            self.assertEqual(got, [(cloud_ws.OP_BINARY, b"\xff\xd8A"), (cloud_ws.OP_BINARY, b"\xff\xd8B")])
            mask = os.urandom(4)
            sock.sendall(bytes([0x88, 0x80 | 2]) + mask + bytes(b ^ mask[i] for i, b in enumerate(struct.pack("!H", 1000))))
            rest = f.read()   # 服务器回关闭帧后断开
            self.assertTrue(rest.endswith(bytes([0x88, 2, 0x03, 0xE8])) or rest == b"")
            sock.close()
        finally:
            self.srv.desktop_frame = orig

    def test_02_rejects_bad_token_and_plain_http(self):
        sock, _ = self._connect("wrong")
        self.assertIn(b"401", sock.makefile("rb").readline())
        sock.close()
        self.assertEqual(self.request("GET", "/v1/desktop/stream")[0], 400)



class IncognitoLeakTests(CloudServerTestCase):
    def test_01_incognito_not_in_library_search_or_bot_preview(self):
        import time
        self.request("PUT", "/v1/bots/incbot", {"name": "无痕测试", "instructions": "x"})
        sid = self.request("POST", "/v1/sessions", {"title": "无痕", "persona_id": "incbot", "incognito": True})[1]["session_id"]
        conn = self.srv.get_db_connection()
        try:
            conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)",
                         (sid, "私密链接 https://example.org/secret 关键字无痕暗号", time.time()))
            conn.commit()
        finally:
            conn.close()
        self.assertEqual(self.request("GET", "/v1/bots/incbot/library")[1]["items"], [])
        results = self.request("GET", "/v1/search?q=" + __import__("urllib.parse").parse.quote("无痕暗号"))[1].get("results", [])
        self.assertEqual(results, [])
        bot = self.request("GET", "/v1/bots/incbot")[1]
        self.assertNotEqual(bot.get("latest_session_id"), sid)
        self.assertIsNone(bot.get("last_message"))


if __name__ == "__main__":
    unittest.main()
