#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 1 / 6：完成推送（Bark / ntfy），配置加密保存，任务完成 / 审批 / 例行任务触发。"""

import json
import sqlite3
import time
import unittest

import cloud_notify
from test_phase1_support import CloudServerTestCase, FakeModelHandler, NotifySinkHandler, tool_call, tool_turns


class NotifyUnitTests(unittest.TestCase):
    def test_validate(self):
        for bad in [{}, {"provider": "x", "url": "https://a/b"}, {"provider": "bark", "url": "ftp://a/b"},
                    {"provider": "bark", "url": "https://api.day.app/"}, {"provider": "ntfy", "url": "https://u:p@ntfy.sh/t"},
                    {"provider": "ntfy", "url": "https://ntfy.sh/t", "events": {"nope": True}}]:
            with self.assertRaises(cloud_notify.NotifyConfigError, msg=str(bad)):
                cloud_notify.validate(bad)
        cfg = cloud_notify.validate({"provider": "ntfy", "url": "https://ntfy.sh/a/topic/", "events": {"task_completed": False}})
        self.assertEqual(cfg["events"], {"task_completed": False, "approval_required": True, "routine_finished": True})
        req = cloud_notify.build_request(cfg, "标题", "正文")
        self.assertEqual(req.full_url, "https://ntfy.sh/a/")
        self.assertEqual(json.loads(req.data)["topic"], "topic")
        self.assertEqual(cloud_notify.masked(cfg)["url"], "https://ntfy.sh/…opic")

    def test_bark_url_normalization(self):
        key = "AbCdEfGhIjKlMnOpQrStUv"
        cases = {
            f"https://api.day.app/{key}/这里改成你自己的推送内容": f"https://api.day.app/{key}",
            f"https://api.day.app/{key}/推送标题/推送内容?group=example&ttl=600": f"https://api.day.app/{key}",
            f"  示例：https://api.day.app/{key}/title/body?icon=https://x.y/z.png  ": f"https://api.day.app/{key}",
            key: f"https://api.day.app/{key}",
            f"https://bark.example.com:8443/{key}/": f"https://bark.example.com:8443/{key}",
            f"http://10.0.0.2:8080/bark/{key}/hello": f"http://10.0.0.2:8080/bark/{key}",
        }
        for text, expected in cases.items():
            self.assertEqual(cloud_notify.validate({"provider": "bark", "url": text})["url"], expected, text)
        self.assertEqual(cloud_notify.validate({"provider": "bark", "url": f"https://api.day.app/{key}/t/b?group=example"})["group"], "example")
        for bad, hint in [("https://api.day.app/", "设备 Key"), (f"https://u:p@api.day.app/{key}", "账号密码"), ("", "请填写"), ("not a url", "Bark 地址无效")]:
            with self.assertRaises(cloud_notify.NotifyConfigError) as ctx:
                cloud_notify.validate({"provider": "bark", "url": bad})
            self.assertIn(hint, str(ctx.exception))
        self.assertEqual(cloud_notify.validate({"provider": "ntfy", "url": "https://ntfy.sh/topic?x=1"})["url"], "https://ntfy.sh/topic")


class NotifyServerTests(CloudServerTestCase):
    approval_mode = "ask"
    DEVICE_KEY = "barkDeviceKey9876"

    def received(self, n, timeout=10):
        return self.wait_until(lambda: NotifySinkHandler.received if len(NotifySinkHandler.received) >= n else None,
                               timeout=timeout, message=f"expected {n} pushes, got {NotifySinkHandler.received}")

    def setUp(self):
        NotifySinkHandler.received.clear()

    def test_01_config_encrypted_masked_and_test_push(self):
        self.assertFalse(self.request("GET", "/v1/notify")[1]["configured"])
        self.assertEqual(self.request("POST", "/v1/notify/test", {})[0], 404)
        status, res = self.request("PUT", "/v1/notify", {"config": {"provider": "bark", "url": f"{self.notify_base}/{self.DEVICE_KEY}"}})
        self.assertEqual(status, 200, res)
        self.assertNotIn(self.DEVICE_KEY, json.dumps(res))
        status, res = self.request("GET", "/v1/notify")
        self.assertTrue(res["configured"])
        self.assertNotIn(self.DEVICE_KEY, json.dumps(res))
        conn = sqlite3.connect(self.srv.DB_PATH)
        blob = bytes(conn.execute("SELECT ciphertext FROM secure_settings").fetchone()[0])
        conn.close()
        self.assertNotIn(self.DEVICE_KEY.encode(), blob)
        status, res = self.request("POST", "/v1/notify/test", {})
        self.assertEqual((status, res["ok"]), (200, True))
        push = NotifySinkHandler.received[-1]
        self.assertEqual(push["path"], "/" + self.DEVICE_KEY)
        self.assertEqual(json.loads(push["body"])["title"], "OpenMinis 云电脑")
        self.assertEqual(self.request("PUT", "/v1/notify", {"provider": "bark", "url": "nope"})[0], 400)

    def test_02_task_completion_push_ntfy(self):
        self.request("PUT", "/v1/notify", {"provider": "ntfy", "url": f"{self.notify_base}/minis-topic", "token": "tk_secret"})
        FakeModelHandler.scripts["m-done"] = lambda d: {"role": "assistant", "content": "报告已生成"}
        sid = self.new_session("周报")
        task = self.submit(sid, "写周报", "m-done")[1]
        self.wait_status(task["task_id"], ("completed",))
        push = self.received(1)[0]
        body = json.loads(push["body"])
        self.assertEqual(push["path"], "/")
        self.assertEqual(body["topic"], "minis-topic")
        self.assertIn("周报", body["title"])
        self.assertEqual(body["message"], "报告已生成")
        self.assertEqual(push["headers"].get("Authorization"), "Bearer tk_secret")

    def test_03_approval_and_routine_pushes_event_filter(self):
        self.request("PUT", "/v1/notify", {"provider": "bark", "url": f"{self.notify_base}/{self.DEVICE_KEY}",
                                           "events": {"task_completed": False}})
        # 审批推送
        def risky(data):
            if not tool_turns(data):
                return tool_call("r1", "shell_execute", {"command": "sudo reboot"})
            return {"role": "assistant", "content": "ok"}
        FakeModelHandler.scripts["m-risk"] = risky
        sid = self.new_session("危险")
        task = self.submit(sid, "重启", "m-risk")[1]
        self.wait_status(task["task_id"], ("waiting_user",))
        push = json.loads(self.received(1)[0]["body"])
        self.assertEqual(push["title"], "云电脑等待你的审批")
        self.assertIn("sudo", push["body"])
        self.request("POST", f"/v1/tasks/{task['task_id']}/cancel", {})
        self.wait_status(task["task_id"], ("cancelled",))
        # 例行任务推送；task_completed 已关闭，不应额外推送对话完成
        self.request("PUT", "/v1/credentials/nt", {"api_key": "sk-notify-routine-000000000", "base_url": self.model_base})
        FakeModelHandler.scripts["m-rt-n"] = lambda d: {"role": "assistant", "content": "例行结果"}
        r = self.request("POST", "/v1/routines", {"name": "晨报", "prompt": "p", "model": "m-rt-n", "credential": "nt",
                                                  "schedule": {"kind": "interval", "seconds": 3600}})[1]
        self.request("POST", f"/v1/routines/{r['routine_id']}/run", {})
        pushes = self.received(2)
        time.sleep(0.5)
        self.assertEqual(len(NotifySinkHandler.received), 2)
        body = json.loads(pushes[1]["body"])
        self.assertEqual(body["title"], "例行任务「晨报」完成")
        self.assertEqual(body["body"], "例行结果")

    def test_04_delete(self):
        self.request("PUT", "/v1/notify", {"provider": "bark", "url": f"{self.notify_base}/k"})
        self.assertEqual(self.request("DELETE", "/v1/notify")[1]["deleted"], True)
        self.assertFalse(self.request("GET", "/v1/notify")[1]["configured"])


if __name__ == "__main__":
    unittest.main()
