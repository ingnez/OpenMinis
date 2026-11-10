#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 2：Telegram 渠道（长轮询、允许列表、按会话续聊、/new /stop、审批按钮、配置加密）。"""

import json
import sqlite3
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler

import cloud_telegram
from test_phase1_support import CloudServerTestCase, FakeModelHandler, _serve, tool_call, tool_turns

TOKEN = "123456789:AAFakeTelegramTokenForTests_abcdefghij"
OWNER = 4242


class FakeTelegram(BaseHTTPRequestHandler):
    updates = []
    sent = []
    calls = []
    lock = threading.Lock()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        params = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        prefix = f"/bot{TOKEN}/"
        if not self.path.startswith(prefix):
            return self._reply(401, {"ok": False, "description": "Unauthorized"})
        method = self.path[len(prefix):]
        FakeTelegram.calls.append(method)
        if method == "getMe":
            return self._reply(200, {"ok": True, "result": {"id": 123456789, "username": "minis_test_bot"}})
        if method == "getUpdates":
            deadline = time.time() + min(params.get("timeout", 0), 1)
            while True:
                with FakeTelegram.lock:
                    pending = [u for u in FakeTelegram.updates if u["update_id"] >= params.get("offset", 0)]
                if pending or time.time() >= deadline:
                    break
                time.sleep(0.05)
            return self._reply(200, {"ok": True, "result": pending})
        if method == "sendMessage":
            FakeTelegram.sent.append(params)
        return self._reply(200, {"ok": True, "result": True})

    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        return


class TelegramTests(CloudServerTestCase):
    approval_mode = "ask"
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.srv.TELEGRAM_POLL_TIMEOUT = 1
        cls.tg_server, port = _serve(FakeTelegram)
        cls.tg_base = f"http://127.0.0.1:{port}"
        cls.next_id = 1
        cls.request(cls, "PUT", "/v1/credentials/tg", {"api_key": "sk-telegram-routine-0000000000", "base_url": cls.model_base})

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop_telegram()
        cls.tg_server.shutdown()
        super().tearDownClass()

    def push(self, chat_id, text=None, callback=None):
        u = {"update_id": TelegramTests.next_id}
        TelegramTests.next_id += 1
        if callback:
            u["callback_query"] = {"id": "cq1", "data": callback, "message": {"chat": {"id": chat_id}}}
        else:
            u["message"] = {"message_id": u["update_id"], "chat": {"id": chat_id, "type": "private", "first_name": "Li"}, "text": text}
        with FakeTelegram.lock:
            FakeTelegram.updates.append(u)

    def sent_to(self, chat_id, contains, timeout=15):
        return self.wait_until(lambda: next((m for m in FakeTelegram.sent if m["chat_id"] == chat_id and contains in m["text"]), None),
                               timeout=timeout, message=f"no message to {chat_id} containing {contains!r}: {FakeTelegram.sent}")

    def test_01_flow(self):
        # 校验：无凭据、坏 Token
        self.assertEqual(self.request("PUT", "/v1/telegram", {"bot_token": TOKEN, "credential": "nope", "model": "m", "api_base": self.tg_base})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/telegram", {"bot_token": "bad", "credential": "tg", "model": "m", "api_base": self.tg_base})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/telegram", {"bot_token": TOKEN, "credential": "tg", "model": "m", "api_base": self.tg_base, "persona_id": "ghost"})[0], 400)
        status, res = self.request("PUT", "/v1/telegram", {"bot_token": TOKEN, "credential": "tg", "model": "m-tg",
                                                          "allowed_chat_ids": [OWNER], "api_base": self.tg_base})
        self.assertEqual(status, 200, res)
        self.assertEqual(res["config"]["bot_username"], "minis_test_bot")
        self.assertNotIn(TOKEN.split(":")[1], json.dumps(self.request("GET", "/v1/telegram")[1]))
        conn = sqlite3.connect(self.srv.DB_PATH)
        blob = bytes(conn.execute("SELECT ciphertext FROM secure_settings WHERE name = 'telegram'").fetchone()[0])
        conn.close()
        self.assertNotIn(TOKEN.encode(), blob)

        # 未授权会话只提示一次 chat id
        self.push(999, "hi")
        self.push(999, "hi again")
        self.sent_to(999, "chat id：999")
        time.sleep(1.2)
        self.assertEqual(len([m for m in FakeTelegram.sent if m["chat_id"] == 999]), 1)

        # 正常对话：两轮共用同一会话，第二轮能看到第一轮历史
        def script(data):
            users = [m["content"] for m in data["messages"] if m["role"] == "user"]
            return {"role": "assistant", "content": f"第{len(users)}轮：{users[-1]}"}
        FakeModelHandler.scripts["m-tg"] = script
        self.push(OWNER, "你好")
        self.sent_to(OWNER, "第1轮：你好")
        self.push(OWNER, "继续")
        self.sent_to(OWNER, "第2轮：继续")
        self.assertIn("Telegram", FakeModelHandler.requests[-1]["messages"][0]["content"])
        self.push(OWNER, "/new")
        self.sent_to(OWNER, "已开始新会话")
        self.push(OWNER, "重新开始")
        self.sent_to(OWNER, "第1轮：重新开始")

        # 审批按钮
        def risky(data):
            if not tool_turns(data):
                return tool_call("r1", "shell_execute", {"command": "sudo echo approved-run"})
            return {"role": "assistant", "content": "结果：" + json.loads(tool_turns(data)[0]["content"]).get("stdout", json.dumps(tool_turns(data)[0]["content"]))}
        FakeModelHandler.scripts["m-tg"] = risky
        self.push(OWNER, "执行危险命令")
        card = self.sent_to(OWNER, "需要你的审批")
        buttons = card["reply_markup"]["inline_keyboard"][0]
        self.assertEqual([b["text"] for b in buttons], ["批准", "拒绝"])
        self.push(OWNER, "插队消息")
        self.sent_to(OWNER, "上一个任务还在运行")
        self.push(12345, callback=buttons[0]["callback_data"])   # 非本会话的按钮无效
        self.push(OWNER, callback=buttons[1]["callback_data"])
        self.sent_to(OWNER, "已拒绝")
        self.sent_to(OWNER, "结果：")
        self.assertIn("answerCallbackQuery", FakeTelegram.calls)

        # 删除配置后停止处理
        self.assertTrue(self.request("DELETE", "/v1/telegram")[1]["deleted"])
        self.assertFalse(self.request("GET", "/v1/telegram")[1]["configured"])

    def test_chunks(self):
        parts = cloud_telegram.chunks("a" * 9000)
        self.assertEqual([len(p) for p in parts], [4000, 4000, 1000])


if __name__ == "__main__":
    unittest.main()
