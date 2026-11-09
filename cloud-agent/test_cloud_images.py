#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_cloud_images.py
Tests for image / multimodal payload passing to cloud agent:
1. serverMock validates that incoming LLM requests contain image_url with non-empty base64 content.
2. Default pure-image prompt text is '请查看图片并处理任务'.
3. message_parts payload in POST /v1/sessions/{id}/messages correctly stored and reloaded as list of content parts.
4. Total image size validation (>2MB) returns 400.
"""

import os
import sys
import json
import time
import unittest
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)

import test_integration

class TestCloudImages(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # We start a dedicated mock LLM server to record and inspect exact payload
        cls.received_messages = []
        cls.lock = threading.Lock()

        class ImageMockLLMHandler(BaseHTTPRequestHandler):
            def do_POST(self):
                if self.path == "/v1/chat/completions":
                    clen = int(self.headers.get("Content-Length", 0))
                    body = json.loads(self.rfile.read(clen).decode("utf-8"))
                    with cls.lock:
                        cls.received_messages.append(body)
                    resp = {
                        "id": "chatcmpl-mock-img",
                        "object": "chat.completion",
                        "choices": [{
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": "已成功收到图片并处理完成。"
                            },
                            "finish_reason": "stop"
                        }]
                    }
                    data = json.dumps(resp).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, format, *args):
                pass

        cls.mock_llm = ThreadingHTTPServer(("127.0.0.1", 0), ImageMockLLMHandler)
        cls.mock_port = cls.mock_llm.server_address[1]
        cls.mock_thread = threading.Thread(target=cls.mock_llm.serve_forever, daemon=True)
        cls.mock_thread.start()

        # Import cloud_agent_server
        import cloud_agent_server
        import tempfile
        cls.temp_dir = tempfile.TemporaryDirectory()
        td = cls.temp_dir.name
        cls.token = "img-test-token"
        cls.token_file = os.path.join(td, "token")
        with open(cls.token_file, "w") as f:
            f.write(cls.token)
        os.chmod(cls.token_file, 0o600)

        cloud_agent_server.HOST = "127.0.0.1"
        cloud_agent_server.PORT = 0
        cloud_agent_server.TOKEN_FILE = cls.token_file
        cloud_agent_server.DB_PATH = os.path.join(td, "agent.db")
        cloud_agent_server.GLOBAL_WORKSPACE = os.path.join(td, "workspace")
        cloud_agent_server.SERVER_TOKEN = cls.token
        cloud_agent_server.init_db()

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), cloud_agent_server.CloudAgentHandler)
        cls.port = cls.server.server_address[1]
        cls.server_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.server_thread.start()
        time.sleep(0.3)

    @classmethod
    def tearDownClass(cls):
        try:
            cls.server.shutdown()
            cls.mock_llm.shutdown()
            cls.temp_dir.cleanup()
        except Exception:
            pass

    def _request(self, method, path, data=None):
        import urllib.request
        url = f"http://127.0.0.1:{self.port}{path}"
        headers = {"Authorization": f"Bearer {self.token}"}
        body_bytes = None
        if data is not None:
            headers["Content-Type"] = "application/json"
            body_bytes = json.dumps(data).encode("utf-8")
        req = urllib.request.Request(url, data=body_bytes, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                raw = resp.read()
                return resp.status, json.loads(raw.decode("utf-8")) if raw else {}
        except urllib.error.HTTPError as e:
            raw = e.read()
            return e.code, json.loads(raw.decode("utf-8")) if raw else {}

    def test_image_url_forwarded_and_not_empty(self):
        # 1. 创建会话
        status, sess = self._request("POST", "/v1/sessions", {"title": "Image Test"})
        self.assertEqual(status, 201)
        sid = sess["session_id"]

        # 2. 模拟包含图片的 message_parts 与纯图提示
        default_prompt = "请查看图片并处理任务"
        fake_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        image_parts = [
            {"type": "text", "text": default_prompt},
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{fake_base64}"}}
        ]

        payload = {
            "content": default_prompt,
            "message_parts": image_parts,
            "model": "gpt-4o",
            "provider": {
                "base_url": f"http://127.0.0.1:{self.mock_port}/v1",
                "api_key": "test-key",
                "protocol": "chat"
            }
        }

        with self.lock:
            self.received_messages.clear()

        status, res = self._request("POST", f"/v1/sessions/{sid}/messages", payload)
        self.assertEqual(status, 202)
        tid = res["task_id"]

        # 等待任务执行完成
        for _ in range(30):
            time.sleep(0.1)
            _, t_stat = self._request("GET", f"/v1/tasks/{tid}")
            if t_stat.get("status") in ["completed", "failed"]:
                break

        self.assertEqual(t_stat.get("status"), "completed")

        # 3. 验证 mock LLM 收到包含 image_url 且非空
        with self.lock:
            self.assertGreater(len(self.received_messages), 0, "LLM must have received at least one request")
            llm_req = self.received_messages[0]
            messages = llm_req.get("messages", [])
            user_msgs = [m for m in messages if m.get("role") == "user"]
            self.assertGreater(len(user_msgs), 0, "Must have a user message")
            user_content = user_msgs[-1].get("content")
            self.assertIsInstance(user_content, list, "User message content should be a list of parts")

            # 验证纯图默认提示文本
            text_part = next((p for p in user_content if p.get("type") == "text"), None)
            self.assertIsNotNone(text_part)
            self.assertEqual(text_part.get("text"), default_prompt)

            # 验证 image_url 非空
            img_part = next((p for p in user_content if p.get("type") == "image_url"), None)
            self.assertIsNotNone(img_part)
            url_val = img_part.get("image_url", {}).get("url", "")
            self.assertTrue(url_val.startswith("data:image/png;base64,"))
            self.assertIn(fake_base64, url_val)

    def test_image_oversize_rejected(self):
        status, sess = self._request("POST", "/v1/sessions", {"title": "Image Oversize"})
        self.assertEqual(status, 201)
        sid = sess["session_id"]

        huge_url = "data:image/png;base64," + ("A" * (2 * 1024 * 1024 + 100))
        oversized_parts = [
            {"type": "text", "text": "超限测试"},
            {"type": "image_url", "image_url": {"url": huge_url}}
        ]
        payload = {
            "content": "超限测试",
            "message_parts": oversized_parts,
            "model": "gpt-4o",
            "provider": {
                "base_url": f"http://127.0.0.1:{self.mock_port}/v1",
                "api_key": "test-key"
            }
        }
        status, res = self._request("POST", f"/v1/sessions/{sid}/messages", payload)
        self.assertEqual(status, 400)
        self.assertIn("exceeds 2MB limit", res.get("error", ""))

if __name__ == "__main__":
    unittest.main(verbosity=2)
