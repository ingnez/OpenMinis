"""连接与通知：/health 版本和桌面状态、App 在线时不发 Bark、通知流长轮询、桌面重启无权限时的回退。"""
import os
import re
import time
import unittest

import cloud_appfeed
from test_phase1_support import CloudServerTestCase, FakeModelHandler, NotifySinkHandler

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class FeedLogicTests(unittest.TestCase):
    def test_should_bark(self):
        f = cloud_appfeed.Feed(lambda: None)
        self.assertTrue(f.should_bark(True, None))               # 自动：配置了 Bark 就兜底
        self.assertFalse(f.should_bark(False, True))             # 没配 Bark 不发
        self.assertFalse(f.should_bark(True, False))             # 用户关掉兜底
        f.touch(foreground=False, local_notifications=True)
        self.assertFalse(f.should_bark(True, True))              # App 在线能发本地通知：不重复推
        self.assertTrue(f.should_bark(True, True, now=time.time() + cloud_appfeed.PRESENCE_TTL + 1))   # App 很久没报到
        f.touch(local_notifications=False)
        self.assertTrue(f.should_bark(True, None))               # App 没有通知权限：仍用 Bark


class LinkServerTests(CloudServerTestCase):
    def test_01_health_version_and_desktop(self):
        h = self.request("GET", "/health")[1]
        self.assertEqual(h["agent_version"], self.srv.AGENT_VERSION)
        self.assertIn("ok", h["desktop"])
        self.assertIn("diagnosis", h["desktop"])
        swift = open(os.path.join(ROOT, "src/ios/Views/Chat/AIChatView/Cloud/CloudLinkSupervisor.swift"), encoding="utf-8").read()
        m = re.search(r'bundledAgentVersion\s*=\s*"([0-9.]+)"', swift)
        self.assertTrue(m)
        self.assertEqual(m.group(1), self.srv.AGENT_VERSION)    # App 内置的服务器版本与服务器一致

    def test_02_feed_and_bark_dedup(self):
        code, r = self.request("PUT", "/v1/notify", {"provider": "ntfy", "url": f"{self.notify_base}/minis-topic"})
        self.assertEqual(code, 200, r)
        FakeModelHandler.scripts["m-n"] = lambda d: {"role": "assistant", "content": "做好了"}
        sid = self.new_session()
        start = self.request("GET", "/v1/notifications?after=0")[1]["last_id"]
        # App 在线且有本地通知权限：只进通知流，不发 Bark / webhook
        self.assertEqual(self.request("POST", "/v1/presence", {"foreground": True, "local_notifications": True})[0], 200)
        before = len(NotifySinkHandler.received)
        t = self.submit(sid, "hi", "m-n")[1]
        self.wait_status(t["task_id"], ("completed",))
        t0 = time.time()
        res = self.request("GET", f"/v1/notifications?after={start}&wait=5")[1]
        self.assertLess(time.time() - t0, 3)
        self.assertTrue(any(i["session_id"] == sid and "做好了" in i["body"] for i in res["items"]))
        time.sleep(0.5)
        self.assertEqual(len(NotifySinkHandler.received), before)
        # App 很久没报到：走推送兜底
        self.srv.APP_FEED.presence["last_seen"] = 0
        t = self.submit(sid, "again", "m-n")[1]
        self.wait_status(t["task_id"], ("completed",))
        self.wait_until(lambda: len(NotifySinkHandler.received) > before, message="App 不在线时应推送")
        # 用户关掉兜底
        self.request("PUT", "/v1/resources", {"bark_fallback": "off"})
        n = len(NotifySinkHandler.received)
        t = self.submit(sid, "third", "m-n")[1]
        self.wait_status(t["task_id"], ("completed",))
        time.sleep(0.5)
        self.assertEqual(len(NotifySinkHandler.received), n)
        self.request("PUT", "/v1/resources", {"bark_fallback": "auto"})
        self.assertEqual(self.request("PUT", "/v1/resources", {"bark_fallback": "maybe"})[0], 400)

    def test_03_longpoll_idle_and_bad_args(self):
        last = self.request("GET", "/v1/notifications?after=0")[1]["last_id"]
        t0 = time.time()
        res = self.request("GET", f"/v1/notifications?after={last}&wait=1")[1]
        self.assertGreaterEqual(time.time() - t0, 0.9)
        self.assertEqual(res["items"], [])
        self.assertEqual(self.request("GET", "/v1/notifications?after=x")[0], 400)

    def test_05_restart_via_request_file(self):
        import tempfile, threading
        with tempfile.TemporaryDirectory() as td:
            unit = os.path.join(td, "unit.path")
            open(unit, "w").close()
            req = os.path.join(td, "run", "desktop-restart.request")
            os.makedirs(os.path.dirname(req))
            old = (self.srv.RESTART_PATH_UNIT, self.srv.RESTART_REQUEST)
            self.srv.RESTART_PATH_UNIT, self.srv.RESTART_REQUEST = unit, req
            try:
                def root_side():          # 模拟 root 的 path 单元：看到请求文件就重启并删掉
                    for _ in range(40):
                        if os.path.exists(req):
                            os.remove(req)
                            return
                        time.sleep(0.05)
                threading.Thread(target=root_side, daemon=True).start()
                ok, why = self.srv.restart_desktop_services(wait_s=3)
                self.assertTrue(ok, why)
                ok, why = self.srv.restart_desktop_services(wait_s=0.5)   # 没人处理：超时
                self.assertEqual((ok, why), (False, "timeout"))
            finally:
                self.srv.RESTART_PATH_UNIT, self.srv.RESTART_REQUEST = old

    def test_04_desktop_restart_without_permission(self):
        code, res = self.request("POST", "/v1/desktop/restart", {})
        self.assertIn(code, (200, 409))
        if code == 409:
            self.assertIn("SSH", res["error"])


if __name__ == "__main__":
    unittest.main()


class EffortFallbackTests(CloudServerTestCase):
    def test_deepseek_styles_then_off(self):
        seen = []
        def script(d):
            seen.append({k: d.get(k) for k in ("reasoning_effort", "thinking", "enable_thinking")})
            if d.get("reasoning_effort") or d.get("thinking"):
                return {"_status": 400, "error": {"message": "unknown parameter: reasoning_effort / thinking"}}
            return {"role": "assistant", "content": "好"}
        FakeModelHandler.scripts["deepseek-v4-flash-0731"] = script
        sid = self.new_session()
        t = self.submit(sid, "hi", "deepseek-v4-flash-0731", reasoning_effort="high")[1]
        self.wait_status(t["task_id"], ("completed",))
        self.assertEqual(seen[0]["reasoning_effort"], "high")            # 先用 reasoning_effort
        self.assertEqual(seen[1]["thinking"], {"type": "enabled"})        # 被拒后换 thinking 写法
        self.assertEqual(seen[-1], {"reasoning_effort": None, "thinking": None, "enable_thinking": None})
        res = self.request("GET", "/v1/models/effort")[1]
        self.assertIn("deepseek-v4-flash-0731", res["unsupported"])
        n = len(seen)
        t = self.submit(sid, "again", "deepseek-v4-flash-0731", reasoning_effort="high")[1]
        self.wait_status(t["task_id"], ("completed",))
        self.assertEqual(len(seen), n + 1)                                # 记住了：直接不带参数
