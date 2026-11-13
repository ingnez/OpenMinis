#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 4：Telegram 代理（http / socks5，加密保存）、自定义 API 地址与更明确的错误提示。"""

import json
import socket
import socketserver
import sqlite3
import struct
import sys
import threading
import unittest
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler

import cloud_telegram
from test_phase1_support import CloudServerTestCase, _serve
from test_phase2_telegram import FakeTelegram, TOKEN


def _pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class Socks5(socketserver.BaseRequestHandler):
    used = []
    auth = ("tg", "p@ss")

    def _read(self, n):
        buf = b""
        while len(buf) < n:
            buf += self.request.recv(n - len(buf))
        return buf

    def handle(self):
        s = self.request
        _, n = self._read(2)
        methods = self._read(n)
        if 2 not in methods:
            s.sendall(b"\x05\xff")
            return
        s.sendall(b"\x05\x02")
        _, ul = self._read(2)
        user = self._read(ul).decode()
        pl = self._read(1)[0]
        pwd = self._read(pl).decode()
        if (user, pwd) != self.auth:
            s.sendall(b"\x01\x01")
            return
        s.sendall(b"\x01\x00")
        _, cmd, _, atyp = self._read(4)
        if atyp == 1:
            host = socket.inet_ntoa(self._read(4))
        elif atyp == 3:
            host = self._read(self._read(1)[0]).decode()
        else:
            host = socket.inet_ntop(socket.AF_INET6, self._read(16))
        port = struct.unpack(">H", self._read(2))[0]
        Socks5.used.append((atyp, host, port))
        up = socket.create_connection(("127.0.0.1" if host == "localhost" else host, port))
        s.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", 0))
        t = threading.Thread(target=_pipe, args=(up, s), daemon=True)
        t.start()
        _pipe(s, up)
        t.join(5)


class HTTPProxy(BaseHTTPRequestHandler):
    used = []

    def do_POST(self):
        import urllib.request
        HTTPProxy.used.append(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(
                urllib.request.Request(self.path, data=body, headers={"Content-Type": "application/json"}, method="POST")) as r:
            data = r.read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        return


class TelegramProxyTests(CloudServerTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.srv.TELEGRAM_POLL_TIMEOUT = 1
        cls.tg_server, port = _serve(FakeTelegram)
        cls.tg_port = port
        cls.socks = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Socks5)
        cls.socks.daemon_threads = True
        threading.Thread(target=cls.socks.serve_forever, daemon=True).start()
        cls.request(cls, "PUT", "/v1/credentials/tgp", {"api_key": "sk-telegram-proxy-0000000000000", "base_url": cls.model_base})

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop_telegram()
        cls.socks.shutdown()
        cls.tg_server.shutdown()
        super().tearDownClass()

    def base(self, **kw):
        return dict({"bot_token": TOKEN, "credential": "tgp", "model": "m", "allowed_chat_ids": [1]}, **kw)

    def test_parse_proxy(self):
        self.assertIsNone(cloud_telegram.parse_proxy(""))
        self.assertEqual(cloud_telegram.parse_proxy("socks5://u:p@1.2.3.4:1080/"), "socks5://u:p@1.2.3.4:1080")
        for bad in ("ftp://x:1", "socks5://host", "http://h:1/path", "nonsense"):
            with self.assertRaises(cloud_telegram.TelegramConfigError):
                cloud_telegram.parse_proxy(bad)
        self.assertEqual(cloud_telegram.mask_proxy("socks5://u:secret@h:1080"), "socks5://***@h:1080")

    def test_errors_are_specific(self):
        status, res = self.request("PUT", "/v1/telegram", self.base(bot_token="  "))
        self.assertEqual(status, 400)
        self.assertIn("Token 为空", res["error"])
        # 连不上：提示代理
        closed = socket.socket()
        closed.bind(("127.0.0.1", 0))
        dead = closed.getsockname()[1]
        closed.close()
        status, res = self.request("PUT", "/v1/telegram", self.base(api_base=f"http://127.0.0.1:{dead}"))
        self.assertEqual((status, res["error_kind"]), (502, "network"), res)
        self.assertIn("代理", res["error"])
        self.assertNotIn(TOKEN.split(":")[1], json.dumps(res))
        # Token 被拒：401 → 400 unauthorized
        other = "987654321:AAsomeOtherTokenThatIsWrong_abcdefgh"
        status, res = self.request("PUT", "/v1/telegram", self.base(bot_token=other, api_base=f"http://127.0.0.1:{self.tg_port}"))
        self.assertEqual((status, res["error_kind"]), (400, "unauthorized"), res)

    def test_socks5_proxy_used_and_encrypted(self):
        proxy = f"socks5h://tg:p%40ss@127.0.0.1:{self.socks.server_address[1]}"
        status, res = self.request("PUT", "/v1/telegram", self.base(api_base=f"http://localhost:{self.tg_port}", proxy=proxy))
        self.assertEqual(status, 200, res)
        self.assertEqual(res["config"]["proxy"], f"socks5h://***@127.0.0.1:{self.socks.server_address[1]}")
        self.assertIn((3, "localhost", self.tg_port), Socks5.used)
        conn = sqlite3.connect(self.srv.DB_PATH)
        blob = bytes(conn.execute("SELECT ciphertext FROM secure_settings WHERE name = 'telegram'").fetchone()[0])
        conn.close()
        self.assertNotIn(b"p%40ss", blob)
        self.assertNotIn("p%40ss", json.dumps(self.request("GET", "/v1/telegram")[1]))
        # 未提交 proxy 字段时沿用；空字符串清除
        self.assertEqual(self.request("PUT", "/v1/telegram", self.base(api_base=f"http://localhost:{self.tg_port}"))[1]["config"]["has_proxy"], True)
        bad = self.request("PUT", "/v1/telegram", self.base(api_base=f"http://localhost:{self.tg_port}", proxy=proxy.replace("p%40ss", "wrong")))
        self.assertEqual((bad[0], bad[1]["error_kind"]), (502, "network"))
        self.assertIn("检查代理", bad[1]["error"])
        cleared = self.request("PUT", "/v1/telegram", self.base(api_base=f"http://127.0.0.1:{self.tg_port}", proxy=""))[1]
        self.assertFalse(cleared["config"]["has_proxy"])
        self.request("DELETE", "/v1/telegram")

    @unittest.skipUnless(sys.platform.startswith("linux"), "macOS 系统代理设置可能绕过本地地址")
    def test_http_proxy(self):
        proxy_server, pport = _serve(HTTPProxy)
        try:
            with patch("urllib.request.proxy_bypass", return_value=False):
                status, res = self.request("PUT", "/v1/telegram", self.base(
                    api_base=f"http://127.0.0.1:{self.tg_port}", proxy=f"http://127.0.0.1:{pport}"))
            self.assertEqual(status, 200, res)
            self.assertTrue(any("/getMe" in p for p in HTTPProxy.used))
        finally:
            self.request("DELETE", "/v1/telegram")
            proxy_server.shutdown()


if __name__ == "__main__":
    unittest.main()
