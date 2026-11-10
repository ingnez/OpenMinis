#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 4：每个 Bot 可有自己的 Telegram Bot；共享渠道由主 Bot 接待。"""

import json
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler

from test_phase1_support import CloudServerTestCase, FakeModelHandler, _serve

SHARED = "111111111:AAsharedTokenForTests_abcdefghijklmn"
LAW = "222222222:AAlawBotTokenForTests_abcdefghijklmno"
OWNER = 777


class MultiTelegram(BaseHTTPRequestHandler):
    names = {SHARED: "shared_bot", LAW: "law_bot"}
    updates = {SHARED: [], LAW: []}
    sent = []
    lock = threading.Lock()

    def do_POST(self):
        params = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode() or "{}")
        token = next((t for t in self.names if self.path.startswith(f"/bot{t}/")), None)
        if not token:
            return self._reply(401, {"ok": False, "description": "Unauthorized"})
        method = self.path[len(f"/bot{token}/"):]
        if method == "getMe":
            return self._reply(200, {"ok": True, "result": {"id": 1, "username": self.names[token]}})
        if method == "getUpdates":
            deadline = time.time() + min(params.get("timeout", 0), 1)
            while True:
                with self.lock:
                    pending = [u for u in self.updates[token] if u["update_id"] >= params.get("offset", 0)]
                if pending or time.time() >= deadline:
                    break
                time.sleep(0.05)
            return self._reply(200, {"ok": True, "result": pending})
        if method == "sendMessage":
            with self.lock:
                MultiTelegram.sent.append(dict(params, via=self.names[token]))
        return self._reply(200, {"ok": True, "result": True})

    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        return


class BotTelegramTests(CloudServerTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.srv.TELEGRAM_POLL_TIMEOUT = 1
        cls.tg, port = _serve(MultiTelegram)
        cls.tg_base = f"http://127.0.0.1:{port}"
        cls.request(cls, "PUT", "/v1/credentials/tgk", {"api_key": "sk-multi-telegram-000000000000", "base_url": cls.model_base})

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop_telegram()
        cls.tg.shutdown()
        super().tearDownClass()

    def push(self, token, text, uid):
        with MultiTelegram.lock:
            MultiTelegram.updates[token].append({"update_id": uid, "message": {"message_id": uid, "chat": {"id": OWNER, "type": "private"}, "text": text}})

    def reply(self, via, contains):
        return self.wait_until(lambda: next((m for m in MultiTelegram.sent if m["via"] == via and contains in m["text"]), None),
                               timeout=15, message=f"no reply via {via} containing {contains!r}: {MultiTelegram.sent}")

    def test_01_per_bot_channel_and_primary_fallback(self):
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True})
        self.request("PUT", "/v1/bots/law", {"name": "法务", "instructions": "你是法务"})
        FakeModelHandler.scripts["m-mt"] = lambda d: {"role": "assistant", "content": "我是" + d["messages"][0]["content"].split("]")[0].split("：")[-1]}
        base = {"credential": "tgk", "model": "m-mt", "allowed_chat_ids": [OWNER], "api_base": self.tg_base}
        self.assertEqual(self.request("PUT", "/v1/bots/ghost/telegram", dict(base, bot_token=LAW))[0], 404)
        self.assertEqual(self.request("PUT", "/v1/telegram", dict(base, bot_token=SHARED))[0], 200)
        # 同一 Token 不能同时用于两个渠道
        self.assertEqual(self.request("PUT", "/v1/bots/law/telegram", dict(base, bot_token=SHARED))[0], 400)
        status, res = self.request("PUT", "/v1/bots/law/telegram", dict(base, bot_token=LAW))
        self.assertEqual((status, res["config"]["bot_username"]), (200, "law_bot"))
        view = self.request("GET", "/v1/bots/law/telegram")[1]
        self.assertTrue(view["configured"])
        self.assertNotIn(LAW.split(":")[1], json.dumps(view))

        self.push(SHARED, "你是谁", 1)
        self.push(LAW, "你是谁", 1)
        self.reply("shared_bot", "我是总管")
        self.reply("law_bot", "我是法务")
        sessions = self.request("GET", "/v1/sessions?bot=law")[1]["sessions"]
        self.assertEqual(len(sessions), 1)

        # 删除 Bot 专属渠道后该轮询线程退出，共享渠道不受影响
        self.assertTrue(self.request("DELETE", "/v1/bots/law/telegram")[1]["deleted"])
        self.wait_until(lambda: not self.srv.telegram_running("law"), timeout=10, message="law poller still running")
        self.assertTrue(self.srv.telegram_running(""))


if __name__ == "__main__":
    unittest.main()
