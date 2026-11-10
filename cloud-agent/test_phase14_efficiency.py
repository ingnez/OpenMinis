"""提效回归：自动标题（截取首句 / 小模型）、非 Claude 提示缓存提示与命中统计、主模型失败切换备用、中转站体检、搜索短时缓存。"""
import json
import socket
import time
import unittest

import cloud_efficiency as eff
from test_phase1_support import CloudServerTestCase, FakeModelHandler


class EfficiencyUnitTests(unittest.TestCase):
    def test_heuristic_title(self):
        self.assertEqual(eff.heuristic_title("帮我查一下万古霉素怎么调整剂量？谢谢"), "查一下万古霉素怎么调整剂量")
        self.assertEqual(eff.heuristic_title('[{"type":"text","text":"总结这篇论文"}]'), "总结这篇论文")
        self.assertTrue(eff.heuristic_title("x" * 40).endswith("…"))
        self.assertTrue(eff.is_default_title("总管 · 2026年11月10日 16:20"))
        self.assertFalse(eff.is_default_title("我的科研计划"))

    def test_cache_hints(self):
        body = {"model": "qwen-max", "messages": [{"role": "system", "content": "稳定提示"}, {"role": "user", "content": "hi"}]}
        q = eff.with_cache_hints(body, stream=True)
        self.assertEqual(q["messages"][0]["content"][0]["cache_control"], {"type": "ephemeral"})
        self.assertEqual(q["stream_options"], {"include_usage": True})
        self.assertIsInstance(body["messages"][0]["content"], str, "不能改动原 body")
        o = eff.with_cache_hints(dict(body, model="gpt-6-sol"), cache_key="bot-1")
        self.assertEqual(o["prompt_cache_key"], "bot-1")
        self.assertIsInstance(o["messages"][0]["content"], str)
        d = eff.with_cache_hints(dict(body, model="deepseek-v4-flash"), cache_key="bot-1")
        self.assertNotIn("prompt_cache_key", d)
        self.assertEqual(eff.cached_tokens({"prompt_tokens_details": {"cached_tokens": 900}}), 900)
        self.assertEqual(eff.cached_tokens({"prompt_cache_hit_tokens": 512}), 512)
        self.assertEqual(eff.cached_tokens({}), 0)

    def test_failover_error_classes(self):
        class E(Exception):
            def __init__(self, code):
                self.code = code
        self.assertTrue(eff.is_failover_error(E(502)))
        self.assertTrue(eff.is_failover_error(E(429)))
        self.assertFalse(eff.is_failover_error(E(400)))
        self.assertTrue(eff.is_failover_error(ConnectionRefusedError("refused")))

    def test_ttl_cache(self):
        c = eff.TTLCache(ttl=10)
        c.put("a", 1)
        self.assertEqual(c.get("a"), 1)
        c.invalidate()
        self.assertIsNone(c.get("a"))


def _closed_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class EfficiencyServerTests(CloudServerTestCase):
    def _title(self, sid):
        return self.request("GET", f"/v1/sessions/{sid}")[1].get("title") or \
            next((x.get("title") for x in self.request("GET", "/v1/sessions")[1].get("sessions", []) if x.get("session_id") == sid), None)

    def test_01_auto_title_heuristic(self):
        self.request("PUT", "/v1/resources", {"fast_model": ""})
        sid = self.new_session(title="总管 · 2026年11月10日 16:20")
        t = self.submit(sid, "帮我整理一下明天的值班安排？", "m-plain")[1]
        self.assertEqual(self.wait_status(t["task_id"], ("completed", "failed"))["status"], "completed")
        self.wait_until(lambda: self._title(sid) == "整理一下明天的值班安排", message=f"标题没更新：{self._title(sid)}")

    def test_02_auto_title_fast_model_and_user_title_kept(self):
        FakeModelHandler.scripts["tiny-title"] = lambda d: {"role": "assistant", "content": "标题：值班排班整理。"}
        self.assertEqual(self.request("PUT", "/v1/resources", {"fast_model": "tiny-title"})[0], 200)
        try:
            sid = self.new_session(title="总管 · 2026年11月10日 16:21")
            t = self.submit(sid, "帮我排一下班", "m-plain")[1]
            self.wait_status(t["task_id"], ("completed", "failed"))
            self.wait_until(lambda: self._title(sid) == "值班排班整理", message=f"小模型标题没生效：{self._title(sid)}")
            sid2 = self.new_session(title="我自己起的名字")
            t2 = self.submit(sid2, "随便聊聊", "m-plain")[1]
            self.wait_status(t2["task_id"], ("completed", "failed"))
            time.sleep(0.5)
            self.assertEqual(self._title(sid2), "我自己起的名字")
        finally:
            self.request("PUT", "/v1/resources", {"fast_model": ""})

    def test_03_failover_to_backup(self):
        self.assertEqual(self.request("PUT", "/v1/credentials/backup", {"api_key": "sk-backup-000000000000000000", "base_url": self.model_base})[0] // 100, 2)
        FakeModelHandler.scripts["m-backup"] = lambda d: {"role": "assistant", "content": "备用模型回答"}
        self.assertEqual(self.request("PUT", "/v1/resources", {"failover": [{"credential": "backup", "model": "m-backup"}]})[0], 200)
        try:
            sid = self.new_session()
            dead = {"base_url": f"http://127.0.0.1:{_closed_port()}/v1", "api_key": "sk-dead-0000000000000000000"}
            t = self.submit(sid, "你好", "m-primary", provider=dead)[1]
            res = self.wait_status(t["task_id"], ("completed", "failed"), timeout=20)
            self.assertEqual(res["status"], "completed", res)
            msgs = [e["payload"].get("message", "") for e in res["events"] if e["type"] == "status"]
            self.assertTrue(any("已切换到备用" in m for m in msgs), msgs)
            texts = [m.get("content") for m in self.request("GET", f"/v1/sessions/{sid}")[1]["messages"] if m.get("role") == "assistant"]
            self.assertIn("备用模型回答", texts)
        finally:
            self.request("PUT", "/v1/resources", {"failover": []})
        self.assertEqual(self.request("PUT", "/v1/resources", {"failover": [{"credential": "bad name!", "model": "x"}]})[0], 400)

    def test_04_cache_hints_sent_and_dropped_when_rejected(self):
        seen = []
        def script(d):
            seen.append(d)
            if d.get("prompt_cache_key"):
                return {"_status": 400, "error": {"message": "Unrecognized request argument: prompt_cache_key"}}
            return {"role": "assistant", "content": "好"}
        FakeModelHandler.scripts["gpt-cache-test"] = script
        sid = self.new_session()
        t = self.submit(sid, "hi", "gpt-cache-test")[1]
        self.assertEqual(self.wait_status(t["task_id"], ("completed", "failed"))["status"], "completed")
        self.assertTrue(seen[0].get("prompt_cache_key"), "GPT 系应带 prompt_cache_key")
        self.assertFalse(seen[-1].get("prompt_cache_key"), "服务商拒绝后应去掉重试")

    def test_05_relay_check_honest_and_injected(self):
        def honest(d):
            msgs = d["messages"]
            last = msgs[-1]["content"]
            if msgs[0]["role"] == "system":
                return {"role": "assistant", "content": msgs[0]["content"].split("暗号是 ")[1].split("。")[0]}
            if "只回复这串字符" in last:
                return {"role": "assistant", "content": last.split("：")[-1]}
            return {"role": "assistant", "content": last.split("记住编号 ")[1].split("。")[0]}
        FakeModelHandler.scripts["honest-model"] = honest
        FakeModelHandler.scripts["lazy-model"] = lambda d: {"role": "assistant", "content": "你好！我是一个乐于助人的助手。"}
        prov = {"base_url": self.model_base, "api_key": "sk-inline-test-key-000000000000"}
        st, r = self.request("POST", "/v1/relays/check", {"provider": prov, "model": "honest-model", "needle_tokens": 200})
        self.assertEqual(st, 200, r)
        self.assertTrue(r["ok"], r)
        self.assertEqual({c["id"] for c in r["checks"]} >= {"echo", "system", "context"}, True)
        st, r = self.request("POST", "/v1/relays/check", {"provider": prov, "model": "lazy-model", "needle_tokens": 200})
        self.assertFalse(r["ok"])
        self.assertFalse(next(c for c in r["checks"] if c["id"] == "echo")["ok"])

    def test_06_search_cache(self):
        st, a = self.request("GET", "/v1/search?q=zzz-unlikely")
        self.assertEqual(st, 200)
        calls = []
        orig = self.srv.search_everything
        self.srv.search_everything = lambda q: calls.append(q) or []
        try:
            self.request("GET", "/v1/search?q=zzz-unlikely")
            self.assertEqual(calls, [], "15 秒内同一关键词应直接用缓存")
            self.srv.SEARCH_CACHE.invalidate()
            self.request("GET", "/v1/search?q=zzz-unlikely")
            self.assertEqual(calls, ["zzz-unlikely"])
        finally:
            self.srv.search_everything = orig


    def test_07_library_delete(self):
        import base64
        self.request("PUT", "/v1/bots/libdel", {"name": "删", "instructions": "x"})
        FakeModelHandler.scripts["m-libdel"] = lambda d: {"role": "assistant", "content": "见 https://example.com/keep 和 https://example.com/drop"}
        sid = self.request("POST", "/v1/sessions", {"title": "l", "persona_id": "libdel"})[1]["session_id"]
        t = self.submit(sid, "链接", "m-libdel")[1]
        self.wait_status(t["task_id"], ("completed",))
        up = self.request("POST", f"/v1/sessions/{sid}/upload", {"filename": "a.pdf", "data_base64": base64.b64encode(b"%PDF").decode()})[1]
        items = self.request("GET", "/v1/bots/libdel/library")[1]["items"]
        drop = next(i for i in items if i.get("url") == "https://example.com/drop")
        f = next(i for i in items if i.get("attachment_url") == up["attachment_url"])
        self.assertEqual(self.request("DELETE", f"/v1/bots/libdel/library/{drop['id']}")[0], 200)
        self.assertEqual(self.request("DELETE", f"/v1/bots/libdel/library/{f['id']}")[0], 200)
        left = self.request("GET", "/v1/bots/libdel/library")[1]["items"]
        self.assertEqual([i.get("url") for i in left if i["kind"] == "link"], ["https://example.com/keep"])
        self.assertFalse(any(i.get("attachment_url") for i in left), "上传的附件应被删除")
        self.assertTrue(any("drop" in (m.get("content") or "") for m in self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]),
                        "对话内容不能被改动")
        self.assertEqual(self.request("DELETE", "/v1/bots/libdel/library/nope")[0], 404)
        self.assertEqual(self.request("DELETE", "/v1/bots/ghost/library/x")[0], 404)


    def test_08_photo_avatar(self):
        import base64
        self.request("PUT", "/v1/bots/pic", {"name": "照片", "instructions": "x", "emoji": "av:e🧑‍⚕️c5"})
        self.assertEqual(self.request("GET", "/v1/bots/pic")[1].get("emoji"), "av:e🧑‍⚕️c5")
        self.assertEqual(self.request("GET", "/v1/bots/pic/avatar")[0], 404)
        jpg = b"\xff\xd8\xff\xe0" + b"0" * 100
        st, r = self.request("PUT", "/v1/bots/pic/avatar", {"data_base64": base64.b64encode(jpg).decode()})
        self.assertEqual(st, 200, r)
        got = self.request("GET", "/v1/bots/pic/avatar")[1]
        self.assertEqual(base64.b64decode(got["data_base64"]), jpg)
        self.assertEqual(got["hash"], r["hash"])
        self.assertEqual(self.request("PUT", "/v1/bots/pic/avatar", {"data_base64": base64.b64encode(b"GIF89a").decode()})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/bots/pic/avatar", {"data_base64": "!!"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/bots/ghost/avatar", {"data_base64": base64.b64encode(jpg).decode()})[0], 404)


if __name__ == "__main__":
    unittest.main()
