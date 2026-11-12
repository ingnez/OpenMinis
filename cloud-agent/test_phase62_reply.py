#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 62：回复方式「秒回」（前台快模型马上回话 + 后台 worker 干活）和「详细」（原来的实时步骤）。

全部假数据：假模型、假凭据。前台 / 后台用不同的模型名，看假模型收到的请求就知道谁在干活。"""

import json
import re
import threading
import time
import unittest

import cloud_reply
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call

FRONT, BACK, MAIN = "m-front", "m-back", "m-main"


def last_user(d):
    for m in reversed(d["messages"]):
        if m.get("role") == "user":
            c = m.get("content")
            return c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)
    return ""


def fresh_tools(d):
    msgs = d["messages"]
    last = max(i for i, m in enumerate(msgs) if m.get("role") == "user")
    return [m for m in msgs[last:] if m.get("role") == "tool"]


def tool_names(d):
    return {t["function"]["name"] for t in d.get("tools") or []}


def running_worker(d):
    m = re.search(r"(wk_[a-f0-9]{10})「[^」]*」进行中", json.dumps(d["messages"], ensure_ascii=False))
    return m.group(1) if m else None


def stream_then_tool(text, call_id, name, args):
    """先流出一句回话，再在同一条回复里调工具（和真模型一样：文字在前，tool_calls 在后）。"""
    return {"_chunks": [text, {"tool_calls": [{"index": 0, "id": call_id, "type": "function",
                                                "function": {"name": name, "arguments": json.dumps(args, ensure_ascii=False)}}]}],
            "_delay": 0.02}


class ReplySummarizerTests(unittest.TestCase):
    def test_tool_phrase(self):
        self.assertEqual(cloud_reply.tool_phrase("shell_execute", {"tool_title": "分析工作方案"}), "分析工作方案")
        self.assertEqual(cloud_reply.tool_phrase("browser_action", {"action": "navigate", "url": "https://example.com"}), "打开网页")
        self.assertEqual(cloud_reply.tool_phrase("shell_execute", {"command": "pip install requests"}), "安装依赖")
        self.assertEqual(cloud_reply.tool_phrase("shell_execute", {"command": "uname -a"}), "运行命令")
        self.assertEqual(cloud_reply.tool_phrase("file_read", {"path": "/x"}), "阅读文件")
        self.assertEqual(cloud_reply.tool_phrase("github__search", {}), "使用插件")
        self.assertEqual(cloud_reply.tool_phrase("desktop_action", {"action": "type"}), "在云电脑里输入")
        long = cloud_reply.tool_phrase("shell_execute", {"tool_title": "把这一大段非常非常长的标题压缩成状态行里放得下的一句话"})
        self.assertLessEqual(len(long), cloud_reply.PHRASE_MAX)
        self.assertTrue(long.endswith("…"))

    def test_status_phrase(self):
        self.assertEqual(cloud_reply.status_phrase("queued", []), "排队等待开始")
        self.assertEqual(cloud_reply.status_phrase("running", []), "分析工作方案")
        self.assertEqual(cloud_reply.status_phrase("running", [("browser_action", {"action": "navigate"}, False)]), "打开网页")
        self.assertEqual(cloud_reply.status_phrase("running", [("shell_execute", {}, True)]), "思考下一步")
        many = [("shell_execute", {}, True)] * 5
        self.assertEqual(cloud_reply.status_phrase("running", many), "整理结果")
        self.assertEqual(cloud_reply.status_phrase("running", [("ask_choice", {}, False)]), "等你决定")
        self.assertEqual(cloud_reply.status_phrase("completed", many), "已完成")
        self.assertEqual(cloud_reply.status_phrase("cancelled", []), "已停止")

    def test_eta_only_from_real_data(self):
        self.assertIsNone(cloud_reply.eta_seconds([], 3))
        self.assertIsNone(cloud_reply.eta_seconds([60, 80], 3))              # 样本不够：不猜
        self.assertEqual(cloud_reply.eta_seconds([60, 80, 100], 20), 60)      # 中位数 80 - 已用 20
        self.assertIsNone(cloud_reply.eta_seconds([60, 80, 100], 79))         # 只剩 1 秒：不显示
        self.assertIsNone(cloud_reply.eta_seconds([60, 80, 100], 200))        # 已经超时：不显示负数
        self.assertIsNone(cloud_reply.eta_seconds([0, -1, None, "x"], 1))


class ReplyModeTests(CloudServerTestCase):
    reply_default = None        # 按真实默认跑：没设置 = 秒回

    def setUp(self):
        self.gate = threading.Event()
        self.request("PUT", "/v1/bots/rb", {"name": "秒回测试", "instructions": "测试 Bot"})
        conn = self.srv.get_db_connection()          # 每个测试从「没设置过」开始（同一个类共用一个库）
        try:
            conn.execute("DELETE FROM bot_reply")
            conn.execute("DELETE FROM session_reply")
            conn.commit()
        finally:
            conn.close()

    def tearDown(self):
        self.gate.set()

    def _session(self, bot="rb"):
        return self.request("POST", "/v1/sessions", {"title": "t", "persona_id": bot})[1]["session_id"]

    def _say(self, sid, text, timeout=20):
        tid = self.submit(sid, text, MAIN)[1]["task_id"]
        return tid, self.wait_status(tid, {"completed", "failed"}, timeout=timeout)

    def _wait(self, fn, timeout=20, what="条件"):
        deadline = time.time() + timeout
        while time.time() < deadline:
            v = fn()
            if v:
                return v
            time.sleep(0.05)
        self.fail(f"等不到{what}")

    def _workers(self, sid):
        return self.request("GET", f"/v1/workers?session_id={sid}")[1]["workers"]

    def _worker(self, wid):
        return self.request("GET", f"/v1/workers/{wid}")[1]["worker"]

    def _install(self, worker_steps=2, step_sleep=0.4, slow=False):
        """前台：「查一下」→ 先流一句再 spawn_task；后台有任务时「插话」→ 先回再 task_message；其余直接秒回。
        后台：worker_steps 步带 tool_title 的命令，然后给结果（收到插话就在结果里注明）。"""
        def front(d):
            text = last_user(d).split("\n\n[", 1)[0].strip()
            if fresh_tools(d):
                return {"role": "assistant", "content": ""}
            wid = running_worker(d)
            if "查一下" not in text and wid:
                short = (text or "这个要求")[:28]
                line = f"你想{short}，我让后台现在就改。"
                return stream_then_tool(line, "f2", "task_message", {"id": wid, "text": "按用户补充调整：" + text})
            if "查一下" in text:
                return stream_then_tool("好，我让后台去查，做完告诉你。", "f1", "spawn_task",
                                        {"goal": text, "context": "假数据", "title": "查资料"})
            return {"_chunks": ["秒回：", text[:20]], "_delay": 0.02}

        def back(d):
            done = sum(1 for m in d["messages"] if m.get("role") == "tool")
            if slow and done == 0:
                self.gate.wait(30)
            if done < worker_steps:
                return tool_call(f"b{done}", "shell_execute", {"command": f"sleep {step_sleep}; echo step{done}",
                                                               "tool_title": ["分析工作方案", "查找资料", "整理结果"][done % 3]})
            heard = [m["content"] for m in d["messages"] if m.get("role") == "user" and "插话" in str(m.get("content"))]
            return {"role": "assistant", "content": "后台结论：42" + ("（已按插话调整）" if heard else "")}

        def main(d):
            return {"role": "assistant", "content": "主模型直接回答：" + last_user(d)[:20]}

        FakeModelHandler.scripts.update({FRONT: front, BACK: back, MAIN: main})
        self.request("PUT", "/v1/bots/rb/reply", {"front_model": FRONT, "back_model": BACK})

    def test_01_default_is_instant_and_settings_roundtrip(self):
        st, res = self.request("GET", "/v1/bots/rb/reply")
        self.assertEqual(st, 200)
        self.assertEqual(res["reply"], {"mode": "instant", "front_model": None, "back_model": None})
        sid = self._session()
        detail = self.request("GET", f"/v1/sessions/{sid}")[1]
        self.assertEqual(detail["reply"]["mode"], "instant")
        self.assertEqual(detail["reply"]["source"], "bot")
        st, res = self.request("PUT", "/v1/bots/rb/reply", {"mode": "verbose", "front_model": "fast-1", "back_model": "big-1"})
        self.assertEqual(res["reply"], {"mode": "verbose", "front_model": "fast-1", "back_model": "big-1"})
        st, res = self.request("PUT", "/v1/bots/rb/reply", {"front_model": ""})          # 清空 = 跟随默认，其他不变
        self.assertEqual(res["reply"], {"mode": "verbose", "front_model": None, "back_model": "big-1"})
        self.assertEqual(self.request("PUT", "/v1/bots/rb/reply", {"mode": "fast"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/bots/rb/reply", {"back_model": "bad model name"})[0], 400)
        self.assertEqual(self.request("GET", "/v1/bots/nobody/reply")[0], 404)

    def test_02_per_chat_override(self):
        sid = self._session()
        other = self._session()
        st, res = self.request("PUT", f"/v1/sessions/{sid}/reply", {"mode": "verbose"})
        self.assertEqual(st, 200)
        self.assertEqual((res["reply"]["mode"], res["reply"]["source"], res["reply"]["bot_mode"]), ("verbose", "chat", "instant"))
        self.assertEqual(self.request("GET", f"/v1/sessions/{other}/reply")[1]["reply"]["mode"], "instant")   # 别的对话不受影响
        self.request("PUT", "/v1/bots/rb/reply", {"mode": "verbose"})
        self.request("PUT", f"/v1/sessions/{sid}/reply", {"mode": "instant"})
        self.assertEqual(self.request("GET", f"/v1/sessions/{sid}")[1]["reply"]["mode"], "instant")
        res = self.request("PUT", f"/v1/sessions/{sid}/reply", {"mode": None})[1]["reply"]
        self.assertEqual((res["mode"], res["source"]), ("verbose", "bot"))
        self.assertEqual(self.request("PUT", f"/v1/sessions/{sid}/reply", {"mode": "x"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/sessions/sess_000000000000/reply", {"mode": "instant"})[0], 404)

    def test_03_instant_front_streams_fast_and_worker_does_the_work(self):
        self._install()
        sid = self._session()
        FakeModelHandler.requests.clear()
        tid, task = self._say(sid, "帮我查一下 FAKE 指标")
        self.assertEqual(task["status"], "completed")
        front_reqs = [r for r in FakeModelHandler.requests if r.get("model") == FRONT]
        self.assertTrue(front_reqs, "前台没用前台模型")
        self.assertFalse([r for r in FakeModelHandler.requests if r.get("model") == MAIN], "秒回前台不该用主模型")
        self.assertTrue(tool_names(front_reqs[0]) <= cloud_reply.FRONT_TOOLS, tool_names(front_reqs[0]))
        self.assertIn("spawn_task", tool_names(front_reqs[0]))
        self.assertNotIn("shell_execute", tool_names(front_reqs[0]))
        self.assertIn("[秒回 · 前台]", front_reqs[0]["messages"][0]["content"])
        # 首字时间：服务器记的 first_text_ms（从收到消息到流出第一个字）
        detail = self.request("GET", f"/v1/sessions/{sid}")[1]
        timing = next(t for t in detail["tasks"] if t["task_id"] == tid).get("timings") or {}
        self.assertIsNotNone(timing.get("first_text_ms"), timing)
        self.assertLess(timing["first_text_ms"], 1000, timing)
        self.assertIn("好，我让后台去查", json.dumps(detail["messages"], ensure_ascii=False))
        ev = self.request("GET", f"/v1/tasks/{tid}/events?after=0")[1]["events"]
        rm = [e for e in ev if e["type"] == "reply_mode"]
        self.assertEqual(rm[0]["payload"]["front_model"], FRONT)
        self.assertEqual(rm[0]["payload"]["back_model"], BACK)
        # 后台 worker 用后台模型，状态行短语来自 tool_title
        w = self._wait(lambda: (self._workers(sid) or [None])[0], what="后台任务")
        phrases = set()

        def finished():
            cur = self._worker(w["worker_id"])
            phrases.add(cur.get("status_phrase"))
            self.assertNotIn("eta_s", cur)          # 没有历史数据：不显示预计剩余
            return cur if cur["status"] == "completed" else None
        done = self._wait(finished, what="后台完成")
        self.assertTrue(phrases & {"分析工作方案", "查找资料", "思考下一步"}, phrases)
        self.assertEqual(done["result"], "后台结论：42")
        back_reqs = [r for r in FakeModelHandler.requests if r.get("model") == BACK]
        self.assertTrue(back_reqs and "[后台任务]" in back_reqs[0]["messages"][0]["content"])
        self.assertIn("shell_execute", tool_names(back_reqs[0]))
        # 结果作为一条 Bot 消息回到前台对话
        self._wait(lambda: any("后台结论：42" in (m.get("content") or "") for m in
                               self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]), what="结果回到前台")

    def test_04_interjection_answered_by_front_and_forwarded_to_worker(self):
        self._install(worker_steps=3, step_sleep=1.0, slow=True)
        sid = self._session()
        self._say(sid, "查一下要很久的事")
        w = self._wait(lambda: (self._workers(sid) or [None])[0], what="后台任务")
        self.assertEqual(w["status"], "running")
        t0 = time.time()
        tid, task = self._say(sid, "插话：结果用中文写")      # worker 还卡在第一步（gate 没放）
        self.assertEqual(task["status"], "completed")
        self.assertLess(time.time() - t0, 5, "后台在忙时前台没有马上回话")
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        blob = json.dumps(msgs, ensure_ascii=False)
        self.assertIn("你想", blob)
        self.assertIn("我让后台", blob)
        self.assertNotIn("收到插话，马上转给后台", blob)
        self.assertEqual(self._worker(w["worker_id"])["status"], "running")
        self.gate.set()
        done = self._wait(lambda: (lambda x: x if x["status"] == "completed" else None)(self._worker(w["worker_id"])),
                          timeout=30, what="后台完成")
        self.assertEqual(done["result"], "后台结论：42（已按插话调整）")

    def test_04b_burst_gets_separate_replies_while_worker_is_busy(self):
        self._install(worker_steps=1, slow=True)
        sid = self._session()
        self._say(sid, "查一下资料")
        worker = self._wait(lambda: (self._workers(sid) or [None])[0], what="后台任务")
        self.assertEqual(worker["status"], "running")

        steers = ["改成10页", "只要上海的", "先做大纲"]
        question, answer = "三乘以四是多少？", "三乘以四等于12。"
        burst = steers[:2] + [question, steers[2]]
        entered, release = threading.Event(), threading.Event()
        original_front = FakeModelHandler.scripts[FRONT]

        def front(request):
            current = last_user(request)
            if current.startswith(burst[0]) and not fresh_tools(request):
                entered.set()
                release.wait(10)
            if current.startswith(question):
                return {"_chunks": [answer], "_delay": 0.02}
            return original_front(request)

        FakeModelHandler.scripts[FRONT] = front
        tid = self.submit(sid, burst[0], MAIN)[1]["task_id"]
        try:
            self.assertTrue(entered.wait(5), "首条前台请求未开始")
            for index, text in enumerate(burst[1:], 1):
                code, _ = self.request("POST", f"/v1/tasks/{tid}/messages", {"content": text, "nonce": f"burst-{index}"})
                self.assertEqual(code, 202)
        finally:
            release.set()

        self.assertEqual(self.wait_status(tid, {"completed", "failed"}, timeout=10)["status"], "completed")
        self.assertEqual(self._worker(worker["worker_id"])["status"], "running", "前台答复不应等待后台完成")
        detail = self.request("GET", f"/v1/sessions/{sid}")[1]
        self.assertTrue(detail["ordered_reply_turns"])
        messages = detail["messages"]
        self.assertEqual([m.get("client_nonce") for m in messages if m["role"] == "user" and m["content"] in burst[1:]],
                         ["burst-1", "burst-2", "burst-3"])
        replies = [m["content"] for m in messages if m["role"] == "assistant" and m.get("front_task_id") == tid and m.get("content")]
        self.assertEqual(replies, [answer if text == question else f"你想{text}，我让后台现在就改。" for text in burst])
        events = self.request("GET", f"/v1/tasks/{tid}")[1]["events"]
        forwarded = [e["payload"]["arguments"]["text"] for e in events
                     if e["type"] == "tool_call" and e["payload"].get("tool") == "task_message"]
        self.assertEqual(forwarded, ["按用户补充调整：" + text for text in steers])

    def test_05_front_cannot_run_work_tools(self):
        def front(d):
            if fresh_tools(d):
                return {"role": "assistant", "content": "好的"}
            return tool_call("x1", "shell_execute", {"command": "echo front-should-not-run"}, content="我来跑")
        FakeModelHandler.scripts.update({FRONT: front})
        self.request("PUT", "/v1/bots/rb/reply", {"front_model": FRONT})
        sid = self._session()
        tid, _ = self._say(sid, "跑个命令")
        ev = self.request("GET", f"/v1/tasks/{tid}/events?after=0")[1]["events"]
        res = [e for e in ev if e["type"] == "tool_result"]
        self.assertTrue(res)
        dumped = json.dumps(res[0]["payload"], ensure_ascii=False)
        self.assertIn("spawn_task", dumped)
        self.assertNotIn("front-should-not-run", dumped.replace('"command": "echo front-should-not-run"', ""))

    def test_05b_instant_front_misused_tool_auto_spawns_worker(self):
        """快模型常直接调干活的工具：前台不执行，自动 spawn_task，后台拿到用户原要求并跑工具。"""
        self._install()
        def front(d):
            if fresh_tools(d):
                return {"role": "assistant", "content": "好，后台去做。"}
            return tool_call("x1", "shell_execute", {"command": "echo front-should-not-run"}, content="我来跑")
        FakeModelHandler.scripts.update({FRONT: front})
        # 另开一个 Bot，避免这个很快完成的后台任务污染 test_06 给 rb 准备的用时中位数
        self.request("PUT", "/v1/bots/rb2", {"name": "交接测试", "instructions": "测试 Bot"})
        self.request("PUT", "/v1/bots/rb2/reply", {"front_model": FRONT, "back_model": BACK})
        sid = self._session("rb2")
        tid, task = self._say(sid, "帮我处理一下自动交接")
        self.assertEqual(task["status"], "completed")
        ev = self.request("GET", f"/v1/tasks/{tid}/events?after=0")[1]["events"]
        res = [e for e in ev if e["type"] == "tool_result"]
        self.assertTrue(res)
        payload = res[0]["payload"]
        dumped = json.dumps(payload, ensure_ascii=False)
        self.assertIn("spawn_task", dumped)
        handed = payload.get("result") if isinstance(payload.get("result"), dict) else payload
        self.assertTrue((handed or {}).get("id"), payload)
        w = self._wait(lambda: (self._workers(sid) or [None])[0], what="自动派后台")
        self.assertIn("帮我处理一下自动交接", w.get("goal") or "")
        done = self._wait(lambda: (lambda x: x if x["status"] == "completed" else None)(self._worker(w["worker_id"])),
                          timeout=30, what="后台完成")
        self.assertEqual(done["result"], "后台结论：42")
        self._wait(lambda: any("后台结论：42" in (m.get("content") or "") for m in
                               self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]), what="结果回到前台")

    def test_05c_same_model_fans_out_without_taking_front_slot(self):
        self.addCleanup(self.srv.update_resource_settings, {"max_tasks_total": self.srv.resource_settings()["max_tasks_total"]})
        self.srv.update_resource_settings({"max_tasks_total": 3})
        self.request("PUT", "/v1/bots/rb/reply", {"front_model": MAIN, "back_model": MAIN})
        sid = self._session()
        front_entered, release_front = threading.Event(), threading.Event()
        first, second = threading.Event(), threading.Event()
        extra = "单独查第三件"

        def same_model(request):
            current = last_user(request).split("\n\n[", 1)[0]
            if "[后台任务]" in request["messages"][0]["content"]:
                if "查甲" in current:
                    first.set()
                if "查乙" in current:
                    second.set()
                self.gate.wait(20)
                return {"role": "assistant", "content": "后台结果"}
            if fresh_tools(request):
                return {"role": "assistant", "content": "已经交给后台。"}
            if current == "同时派两件":
                front_entered.set()
                release_front.wait(10)
                calls = [tool_call("dup", "shell_execute", {"command": "echo should-not-run"}),
                         tool_call("a", "spawn_task", {"goal": "查甲", "title": "查甲"}),
                         tool_call("b", "spawn_task", {"goal": "查乙", "title": "查乙"})]
                return {"role": "assistant", "content": None, "tool_calls": [c["tool_calls"][0] for c in calls]}
            if current == extra:
                return tool_call("next", "shell_execute", {"command": "echo hand-off-only"})
            return {"role": "assistant", "content": "前台直接回答：" + current}

        FakeModelHandler.scripts[MAIN] = same_model
        tid = self.submit(sid, "同时派两件", MAIN)[1]["task_id"]
        try:
            self.assertTrue(front_entered.wait(5))
            self.assertEqual(self.request("POST", f"/v1/tasks/{tid}/messages", {"content": extra, "nonce": "fan-out-3"})[0], 202)
        finally:
            release_front.set()
        self.assertTrue(first.wait(5) and second.wait(5), "同一个模型的两个后台任务没有并行运行")
        self.assertEqual(self.wait_status(tid, {"completed", "failed"}, timeout=8)["status"], "completed")
        self.assertCountEqual([w["title"] for w in self._workers(sid)], ["查甲", "查乙", extra])
        third = next(w for w in self._workers(sid) if w["title"] == extra)
        self._wait(lambda: self._worker(third["worker_id"])["status"] == "queued", what="第三个后台任务排队")
        _, chat = self._say(sid, "聊聊今天", timeout=5)
        self.assertEqual(chat["status"], "completed", "后台并发占满时前台没有立即取得名额")
        self.assertFalse(self.gate.is_set(), "前台不应该等待后台结束")
        self.gate.set()
        self._wait(lambda: all(w["status"] == "completed" for w in self._workers(sid)), what="三个后台任务完成")

    def test_05d_same_model_runs_independent_front_chats_concurrently(self):
        original = self.srv.resource_settings()
        self.addCleanup(self.srv.update_resource_settings, {
            "max_tasks_total": original["max_tasks_total"],
            "bot_defaults": {"max_tasks_per_bot": original["bot_defaults"]["max_tasks_per_bot"]},
        })
        self.srv.update_resource_settings({"max_tasks_total": 3, "bot_defaults": {"max_tasks_per_bot": 2}})
        self.request("PUT", "/v1/bots/rb/reply", {"front_model": MAIN, "back_model": MAIN})
        first, second = self._session(), self._session()
        entered = {text: threading.Event() for text in ("会话甲", "会话乙")}

        def same_model(request):
            current = last_user(request).split("\n\n[", 1)[0]
            entered[current].set()
            self.gate.wait(8)
            return {"role": "assistant", "content": "已回复：" + current}

        FakeModelHandler.scripts[MAIN] = same_model
        a = self.submit(first, "会话甲", MAIN)[1]["task_id"]
        b = self.submit(second, "会话乙", MAIN)[1]["task_id"]
        try:
            self.assertTrue(all(event.wait(5) for event in entered.values()))
        finally:
            self.gate.set()
        for sid, tid, current in ((first, a, "会话甲"), (second, b, "会话乙")):
            self.assertEqual(self.wait_status(tid, {"completed", "failed"}, timeout=5)["status"], "completed")
            messages = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
            self.assertEqual([m["content"] for m in messages], [current, "已回复：" + current])

    def test_06_stop_worker_and_eta_from_history(self):
        self._install(worker_steps=1, step_sleep=0.1)
        # 单独的 Bot：前面测试里很快完成的后台任务不要进这个用时中位数
        self.request("PUT", "/v1/bots/eta", {"name": "用时测试", "instructions": "测试 Bot"})
        self.request("PUT", "/v1/bots/eta/reply", {"front_model": FRONT, "back_model": BACK})
        sid = self._session("eta")
        # 三个完成的历史任务（真实用时 120 / 150 / 180 秒） → 新任务有预计剩余（中位数 150 - 已用）
        conn = self.srv.get_db_connection()
        try:
            now = time.time()
            for i, dur in enumerate((120, 150, 180)):
                conn.execute("INSERT INTO bot_workers (worker_id, bot_id, front_session, worker_session, title, goal, status, created_at, "
                             "started_at, finished_at, reported) VALUES (?, 'eta', ?, ?, 't', 'g', 'completed', ?, ?, ?, 1)",
                             (f"wk_00000000{i:02d}", sid, f"sess_hist0000000{i}", now - 900, now - 900, now - 900 + dur))
            conn.commit()
        finally:
            conn.close()

        def back(d):
            if not any(m.get("role") == "tool" for m in d["messages"]):
                self.gate.wait(30)
                return tool_call("s1", "shell_execute", {"command": "sleep 20"})
            return {"role": "assistant", "content": "不该走到这里"}
        FakeModelHandler.scripts[BACK] = back
        self._say(sid, "查一下慢的")
        w = self._wait(lambda: next((x for x in self._workers(sid) if x["status"] == "running"), None), what="后台开跑")
        cur = self._worker(w["worker_id"])
        self.assertIn("eta_s", cur)
        self.assertLessEqual(cur["eta_s"], 150)
        self.assertGreater(cur["eta_s"], 100)
        self.assertEqual(cur["status_phrase"], "分析工作方案")
        st, res = self.request("POST", f"/v1/workers/{w['worker_id']}/stop", {})
        self.assertEqual(st, 200)
        self.gate.set()
        self._wait(lambda: self._worker(w["worker_id"])["status"] == "cancelled", what="停止")

    def test_07_verbose_uses_main_model_with_all_tools(self):
        self._install()
        self.request("PUT", "/v1/bots/rb/reply", {"mode": "verbose"})
        sid = self._session()
        FakeModelHandler.requests.clear()
        tid, task = self._say(sid, "查一下")
        self.assertEqual(task["status"], "completed")
        self.assertEqual({r.get("model") for r in FakeModelHandler.requests}, {MAIN})
        req = FakeModelHandler.requests[0]
        self.assertNotIn("[秒回 · 前台]", req["messages"][0]["content"])
        ev = self.request("GET", f"/v1/tasks/{tid}/events?after=0")[1]["events"]
        self.assertFalse([e for e in ev if e["type"] == "reply_mode"])
        # 这个对话单独切回秒回
        self.request("PUT", f"/v1/sessions/{sid}/reply", {"mode": "instant"})
        FakeModelHandler.requests.clear()
        self._say(sid, "你好")
        self.assertEqual({r.get("model") for r in FakeModelHandler.requests}, {FRONT})

    def test_08_health_capability(self):
        h = self.request("GET", "/health")[1]
        self.assertTrue(h["capabilities"].get("reply_modes"))


if __name__ == "__main__":
    unittest.main()
