#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 20：思考过程转发与保存、工具标题与耗时、运行中命令的实时输出、插话（不排队）、/reset 快照。"""

import json
import time
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, NotifySinkHandler, tool_call, tool_turns


class SteerTests(CloudServerTestCase):
    def _events(self, tid, q="?after=0"):
        return self.request("GET", f"/v1/tasks/{tid}/events{q}")[1]

    def _types(self, tid):
        return [e["type"] for e in self._events(tid)["events"]]

    def test_01_reasoning_streamed_logged_and_stored(self):
        FakeModelHandler.scripts["m-think"] = lambda d: {"_chunks": [{"reasoning_content": "先想想"}, {"reasoning_content": "再想想"},
                                                                     "答案", "是 42"], "_delay": 0.25}
        sid = self.new_session()
        tid = self.submit(sid, "问题", "m-think")[1]["task_id"]
        live = self.wait_until(lambda: (self._events(tid, "?after=0&live_after=-1").get("live") or {}).get("reasoning"),
                               message="no live reasoning")
        self.assertTrue(live.startswith("先想想"))
        final = self.wait_status(tid, {"completed"})
        types = [e["type"] for e in final["events"]]
        self.assertLess(types.index("reasoning"), types.index("thought"))
        ev = next(e for e in final["events"] if e["type"] == "reasoning")["payload"]
        self.assertEqual((ev["content"], ev["chars"]), ("先想想再想想", 6))
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        self.assertEqual(msgs[-1]["reasoning"], "先想想再想想")
        self.assertEqual(msgs[-1]["content"], "答案是 42")
        # 下一轮请求不把以前的思考过程塞回上下文
        FakeModelHandler.scripts["m-plain"] = lambda d: {"role": "assistant", "content": "ok"}
        tid2 = self.submit(sid, "再问", "m-plain")[1]["task_id"]
        self.wait_status(tid2, {"completed"})
        self.assertNotIn("先想想", json.dumps(FakeModelHandler.requests[-1]["messages"], ensure_ascii=False))

    def test_02_tool_title_duration_and_live_output(self):
        def script(d):
            if not tool_turns(d):
                return tool_call("c1", "shell_execute", {"command": "for i in 1 2 3 4; do echo line$i; sleep 0.4; done",
                                                         "tool_title": "逐行打印四行"})
            return {"role": "assistant", "content": "done"}
        FakeModelHandler.scripts["m-tool"] = script
        sid = self.new_session()
        tid = self.submit(sid, "跑一下", "m-tool")[1]["task_id"]
        live = self.wait_until(lambda: ((self._events(tid, "?after=0&live_after=-1").get("live") or {}).get("tool") or {}).get("output"),
                               message="no live tool output")
        self.assertIn("line1", live)
        final = self.wait_status(tid, {"completed"})
        call = next(e for e in final["events"] if e["type"] == "tool_call")["payload"]
        self.assertEqual(call["arguments"]["tool_title"], "逐行打印四行")
        res = next(e for e in final["events"] if e["type"] == "tool_result")["payload"]
        self.assertGreaterEqual(res["duration_ms"], 1000)
        self.assertIn("line4", res["result"]["stdout"])
        props = next(t for t in FakeModelHandler.requests[-1]["tools"] if t["function"]["name"] == "shell_execute")["function"]["parameters"]["properties"]
        self.assertIn("tool_title", props)
        tool_row = next(m for m in self.request("GET", f"/v1/sessions/{sid}")[1]["messages"] if m["role"] == "tool")
        self.assertGreaterEqual(tool_row["duration_ms"], 1000)

    def test_03_inject_aborts_stream_and_is_seen_next(self):
        def script(d):
            users = [m for m in d["messages"] if m["role"] == "user"]
            if len(users) == 1:
                return {"_chunks": ["写", "一篇", "很长", "的", "文章"] * 8, "_delay": 0.15}
            return {"role": "assistant", "content": "改成：" + users[-1]["content"]}
        FakeModelHandler.scripts["m-steer"] = script
        sid = self.new_session()
        tid = self.submit(sid, "写文章", "m-steer")[1]["task_id"]
        self.wait_until(lambda: (self._events(tid, "?after=0&live_after=-1").get("live") or {}).get("text"), message="no stream")
        status, body = self.request("POST", f"/v1/tasks/{tid}/messages", {"content": "别写了，只要一句话", "nonce": "n-1"})
        self.assertEqual(status, 202, body)
        self.assertTrue(self.request("POST", f"/v1/tasks/{tid}/messages", {"content": "别写了，只要一句话", "nonce": "n-1"})[1]["duplicate"])
        started = time.time()
        final = self.wait_status(tid, {"completed"})
        self.assertLess(time.time() - started, 4)          # 没等长回复写完（40 块 × 0.15s）
        thoughts = [e["payload"]["content"] for e in final["events"] if e["type"] == "thought"]
        self.assertEqual(thoughts, ["改成：别写了，只要一句话"])
        types = [e["type"] for e in final["events"]]
        self.assertLess(types.index("user_message"), types.index("user_message_applied"))
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        injected = [m for m in msgs if m.get("injected")]
        self.assertEqual([m["content"] for m in injected], ["别写了，只要一句话"])
        self.assertEqual(sum(1 for m in msgs if m["role"] == "user"), 2)   # 同一个 nonce 只进一次
        status, body = self.request("POST", f"/v1/tasks/{tid}/messages", {"content": "晚了", "nonce": "n-2"})
        self.assertEqual(status, 409)

    def test_04_inject_during_tool_lands_after_result(self):
        def script(d):
            if not tool_turns(d):
                return tool_call("c1", "shell_execute", {"command": "sleep 1; echo slow"})
            last_user = [m for m in d["messages"] if m["role"] == "user"][-1]["content"]
            return {"role": "assistant", "content": "看到：" + last_user}
        FakeModelHandler.scripts["m-gap"] = script
        sid = self.new_session()
        tid = self.submit(sid, "跑", "m-gap")[1]["task_id"]
        self.wait_until(lambda: "tool_call" in self._types(tid), message="no tool call")
        self.assertEqual(self.request("POST", f"/v1/tasks/{tid}/messages", {"content": "顺便看看磁盘"})[0], 202)
        final = self.wait_status(tid, {"completed"})
        self.assertEqual([e["payload"]["content"] for e in final["events"] if e["type"] == "thought"], ["看到：顺便看看磁盘"])
        roles = [m["role"] for m in FakeModelHandler.requests[-1]["messages"]]
        self.assertEqual(roles[-2:], ["tool", "user"])     # 工具结果之后、下一次请求之前
        self.assertEqual(self.request("POST", "/v1/tasks/nope/messages", {"content": "x"})[0], 404)
        self.assertEqual(self.request("POST", f"/v1/tasks/{tid}/messages", {"content": ""})[0], 400)

    def test_05_reset_saves_snapshot_and_trims_context(self):
        FakeModelHandler.scripts["m-chat"] = lambda d: {"role": "assistant", "content": "好的，部署到 /srv/app，端口 8080"}
        sid = self.new_session()
        tid = self.submit(sid, "帮我把应用部署到 /srv/app", "m-chat")[1]["task_id"]
        self.wait_status(tid, {"completed"})
        FakeModelHandler.scripts["m-snap"] = lambda d: {"role": "assistant",
                                                        "content": "标题：部署应用\n## 目标\n部署到 /srv/app\n## 关键信息\n端口 8080"}
        status, res = self.request("POST", f"/v1/sessions/{sid}/reset",
                                   {"model": "m-snap", "provider": {"base_url": self.model_base, "api_key": "sk-inline-test-key-000000000000"}})
        self.assertEqual(status, 200, res)
        snap = res["snapshot"]
        self.assertEqual((snap["title"], snap["source"]), ("部署应用", "model"))
        self.assertIn("/srv/app", snap["summary"])
        self.assertEqual(res["note"], "已保存对话快照并重置上下文")
        snap_req = FakeModelHandler.requests[-1]
        self.assertIn("帮我把应用部署到 /srv/app", snap_req["messages"][-1]["content"])
        # 历史里有分隔标记（手机显示「已保存对话快照并重置上下文」，可点开快照）
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        self.assertEqual(msgs[-1]["role"], "context_reset")
        self.assertEqual(msgs[-1]["snapshot_id"], snap["snapshot_id"])
        self.assertEqual(self.request("GET", f"/v1/snapshots/{snap['snapshot_id']}")[1]["title"], "部署应用")
        self.assertEqual(len(self.request("GET", "/v1/bots/_default/snapshots")[1]["snapshots"]), 1)
        # 下一轮只带新消息和一句指向快照的话，不带旧对话、不带快照全文
        def recall(d):
            if not tool_turns(d):
                return tool_call("r1", "recall_snapshot", {"snapshot_id": snap["snapshot_id"]})
            return {"role": "assistant", "content": "端口是 8080"}
        FakeModelHandler.scripts["m-after"] = recall
        tid = self.submit(sid, "之前说的端口是多少", "m-after")[1]["task_id"]
        final = self.wait_status(tid, {"completed"})
        first_req = [r for r in FakeModelHandler.requests if r.get("model") == "m-after"][0]
        dump = json.dumps(first_req["messages"], ensure_ascii=False)
        self.assertNotIn("帮我把应用部署到", dump)
        self.assertNotIn("端口 8080", dump)
        self.assertIn(snap["snapshot_id"], first_req["messages"][0]["content"])
        self.assertEqual([m["role"] for m in first_req["messages"]], ["system", "user"])
        result = next(e for e in final["events"] if e["type"] == "tool_result")["payload"]["result"]
        self.assertIn("端口 8080", result["summary"])

    def test_06_reset_without_model_is_honest_and_stops_task(self):
        FakeModelHandler.scripts["m-slow"] = lambda d: (tool_call("c", "shell_execute", {"command": "sleep 5"})
                                                        if not tool_turns(d) else {"role": "assistant", "content": "x"})
        sid = self.new_session()
        tid = self.submit(sid, "记录一下：服务器在杭州", "m-slow")[1]["task_id"]
        self.wait_until(lambda: "tool_call" in self._types(tid), message="no tool call")
        status, res = self.request("POST", f"/v1/sessions/{sid}/reset", {})
        self.assertEqual(status, 200)
        self.assertEqual(res["cancelled_tasks"], [tid])
        self.assertEqual(res["snapshot"]["source"], "heuristic")
        self.assertIn("服务器在杭州", res["snapshot"]["summary"])
        self.wait_status(tid, {"cancelled"})
        empty = self.new_session()
        status, res = self.request("POST", f"/v1/sessions/{empty}/reset", {})
        self.assertEqual((status, res["snapshot"], res["note"]), (200, None, "已重置上下文"))


class NotifyRoutingTests(CloudServerTestCase):
    """App 进程活着（前台或后台）→ 只进 App 通知流；不在了 → 外部推送，并标记已推送，App 回来不再弹。"""

    def setUp(self):
        NotifySinkHandler.received.clear()
        self.request("PUT", "/v1/notify", {"provider": "ntfy", "url": f"{self.notify_base}/topic"})
        FakeModelHandler.scripts["m-n"] = lambda d: {"role": "assistant", "content": "做完了"}

    def _run(self):
        sid = self.new_session()
        tid = self.submit(sid, "干活", "m-n")[1]["task_id"]
        self.wait_status(tid, {"completed"})
        time.sleep(0.5)
        return sid

    def _feed(self):
        return self.request("GET", "/v1/notifications?after=0")[1]["items"]

    def test_alive_in_background_uses_app_feed_only(self):
        self.request("POST", "/v1/presence", {"foreground": False, "local_notifications": True})
        sid = self._run()
        self.assertEqual(NotifySinkHandler.received, [])
        item = [i for i in self._feed() if i["session_id"] == sid][-1]
        self.assertFalse(item["external"])

    def test_dead_app_gets_external_push_once(self):
        self.srv.APP_FEED.presence.update(last_seen=time.time() - 200, local_notifications=True)
        sid = self._run()
        self.wait_until(lambda: NotifySinkHandler.received, message="no external push")
        # 现在 App 回来取通知流：这条标记为已推送，App 不再弹系统通知
        item = [i for i in self._feed() if i["session_id"] == sid][-1]
        self.assertTrue(item["external"])
        self.assertEqual(len(NotifySinkHandler.received), 1)

    def test_presence_ttl(self):
        feed = self.srv.APP_FEED
        feed.touch(local_notifications=True, now=1000)
        self.assertTrue(feed.app_online(now=1080))
        self.assertFalse(feed.app_online(now=1100))


if __name__ == "__main__":
    unittest.main()
