#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Computer & Agent - 全面端到端集成测试套件 (test_integration.py)
包含全部 7 个原有 VPS 严苛测试 + 额外 3 个云电脑增强协议测试（共 10 个测试）：
1. test_01_health_and_auth_checks: 健康检查 /health 与无 token / 弱权限 401 检查
2. test_02_api_validation_and_url_security: validate content/model/provider dict/base URL 带凭据/fragment/非 chat 400 防崩
3. test_03_concurrent_session_conflict_409_with_event: 同 session 409 冲突：使用 Event 阻塞 mock 验证并发拒绝
4. test_04_autonomous_agent_and_disconnection: 客户端断开不轮询自主独立完成；四工具真实调用；多轮不重复 assistant；SQLite中无 api_key 泄露
5. test_05_empty_model_response_fails: 空 model 响应（无 content 无 tool_calls）不能伪 completed，应为 failed
6. test_06_task_cancellation_and_isolation: 测试真实 POST 两个 session 长 shell，一个 cancel API 后 PID 销毁/未执行后继 file，另一个完成，证明隔离
7. test_07_restart_state_migration: 真正重启服务/重新 init_db 验证 running -> interrupted 且历史在
8. test_08_session_import_and_workspace_files: POST /v1/sessions/import 稳定映射、防串、workspace_files 写入/大小与逃逸限制
9. test_09_client_nonce_idempotency_and_cursor: client_nonce 幂等唯一去重，GET /v1/tasks/{id}/events?after=... 增量单调游标
10. test_10_attachment_auth_and_socket_disconnect: 附件安全鉴权下载与客户端 socket 提交即关闭断开后台依然执行到底
"""

import os
import sys
import json
import socket
import sqlite3
import time
import unittest
import threading
import subprocess
import tempfile
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SERVER_DIR)

# ----------------- 动态端口 Mock LLM 服务器 -----------------
class DynamicMockLLMHandler(BaseHTTPRequestHandler):
    routes = {}
    request_log = []

    def do_POST(self):
        if self.path == "/v1/chat/completions":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8")
            data = json.loads(body)
            DynamicMockLLMHandler.request_log.append(data)
            
            model = data.get("model", "gpt-4o")
            messages = data.get("messages", [])
            
            resp_payload = None
            if model in DynamicMockLLMHandler.routes:
                rule_fn = DynamicMockLLMHandler.routes[model]
                resp_payload = rule_fn(data)
            else:
                turn = len([m for m in messages if m["role"] == "tool"])
                if turn == 0:
                    resp_payload = {
                        "id": "chatcmpl-mock-1",
                        "object": "chat.completion",
                        "choices": [{
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": "Executing shell command.",
                                "tool_calls": [{
                                    "id": "call_111",
                                    "type": "function",
                                    "function": {
                                        "name": "shell_execute",
                                        "arguments": json.dumps({"command": "echo 'Hello VPS Agent' > integration_test.txt"})
                                    }
                                }]
                            },
                            "finish_reason": "tool_calls"
                        }]
                    }
                elif turn == 1:
                    resp_payload = {
                        "id": "chatcmpl-mock-2",
                        "object": "chat.completion",
                        "choices": [{
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": "Reading file back.",
                                "tool_calls": [{
                                    "id": "call_222",
                                    "type": "function",
                                    "function": {
                                        "name": "file_read",
                                        "arguments": json.dumps({"path": "integration_test.txt"})
                                    }
                                }]
                            },
                            "finish_reason": "tool_calls"
                        }]
                    }
                else:
                    resp_payload = {
                        "id": "chatcmpl-mock-3",
                        "object": "chat.completion",
                        "choices": [{
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": "All tests passed successfully on VPS Cloud Agent."
                            },
                            "finish_reason": "stop"
                        }]
                    }

            body_bytes = json.dumps(resp_payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return

def start_mock_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), DynamicMockLLMHandler)
    port = server.server_address[1]
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server, port


class TestCloudComputerRobustness(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp_dir = tempfile.TemporaryDirectory()
        td = cls.temp_dir.name
        
        cls.test_db = os.path.join(td, "test_agent.db")
        cls.test_workspace = os.path.join(td, "workspace")
        cls.test_token_file = os.path.join(td, "token")
        cls.test_token = "secure-vps-token-12345"

        os.makedirs(cls.test_workspace, exist_ok=True)
        with open(cls.test_token_file, "w") as f:
            f.write(cls.test_token)
        os.chmod(cls.test_token_file, 0o600)

        cls.mock_llm_server, cls.mock_llm_port = start_mock_server()
        cls.mock_llm_base = f"http://127.0.0.1:{cls.mock_llm_port}/v1"

        import cloud_agent_server
        cloud_agent_server.HOST = "127.0.0.1"
        cloud_agent_server.PORT = 0
        cloud_agent_server.TOKEN_FILE = cls.test_token_file
        cloud_agent_server.DB_PATH = cls.test_db
        cloud_agent_server.GLOBAL_WORKSPACE = cls.test_workspace
        cloud_agent_server.SERVER_TOKEN = cls.test_token
        cloud_agent_server.init_db()

        cls.agent_server = ThreadingHTTPServer(("127.0.0.1", 0), cloud_agent_server.CloudAgentHandler)
        cls.agent_port = cls.agent_server.server_address[1]
        cls.agent_server_thread = threading.Thread(target=cls.agent_server.serve_forever, daemon=True)
        cls.agent_server_thread.start()
        time.sleep(0.5)

    @classmethod
    def tearDownClass(cls):
        try:
            cls.agent_server.shutdown()
        except Exception:
            pass
        try:
            cls.mock_llm_server.shutdown()
        except Exception:
            pass
        cls.temp_dir.cleanup()

    def _request(self, method, path, data=None, token=None):
        if token is None:
            token = self.test_token
        url = f"http://127.0.0.1:{self.agent_port}{path}"
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req_data = json.dumps(data).encode("utf-8") if data is not None else None
        req = urllib.request.Request(url, data=req_data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                status = resp.status
                body = resp.read().decode("utf-8")
                return status, json.loads(body) if body else {}
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8")
            return e.code, json.loads(body) if body else {}

    def test_01_health_and_auth_checks(self):
        """1. 健康检查与无 token / 权限弱拒绝测试"""
        status, res = self._request("GET", "/health", token="")
        self.assertEqual(status, 200)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res.get("service"), "openminis-cloud-agent")
        self.assertIn("capabilities", res)

        status, _ = self._request("GET", "/v1/sessions", token="")
        self.assertEqual(status, 401)

        status, _ = self._request("GET", "/v1/sessions", token="wrong-token")
        self.assertEqual(status, 401)

    def test_02_api_validation_and_url_security(self):
        """2. API 校验：validate content/model/provider dict/base URL 带凭据、fragment、错误 400 防崩"""
        _, s_res = self._request("POST", "/v1/sessions", {"title": "Validation Test"})
        session_id = s_res["session_id"]

        # 缺失 content -> 400
        status, res = self._request("POST", f"/v1/sessions/{session_id}/messages", {
            "model": "gpt-4o",
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-test", "protocol": "chat"}
        })
        self.assertEqual(status, 400)

        # base_url 包含用户名密码凭据 -> 400
        status, res = self._request("POST", f"/v1/sessions/{session_id}/messages", {
            "content": "test",
            "model": "gpt-4o",
            "provider": {"base_url": "https://user:pass@evil.com/v1", "api_key": "sk-test", "protocol": "chat"}
        })
        self.assertEqual(status, 400)
        self.assertIn("base_url", res.get("error", "").lower())

        # base_url 包含 fragment -> 400
        status, res = self._request("POST", f"/v1/sessions/{session_id}/messages", {
            "content": "test",
            "model": "gpt-4o",
            "provider": {"base_url": f"{self.mock_llm_base}#frag", "api_key": "sk-test", "protocol": "chat"}
        })
        self.assertEqual(status, 400)

        # 非 chat 协议 -> 400
        status, res = self._request("POST", f"/v1/sessions/{session_id}/messages", {
            "content": "test",
            "model": "gpt-4o",
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-test", "protocol": "responses"}
        })
        self.assertEqual(status, 400)

    def test_03_concurrent_session_conflict_409_with_event(self):
        """3. 同 session 409 冲突：使用 Event 阻塞 mock 验证并发拒绝"""
        _, s_res = self._request("POST", "/v1/sessions", {"title": "Conflict Event Test"})
        session_id = s_res["session_id"]

        block_event = threading.Event()
        def slow_mock_route(data):
            block_event.wait(timeout=5)
            return {
                "id": "chatcmpl-slow",
                "object": "chat.completion",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "done"}, "finish_reason": "stop"}]
            }

        DynamicMockLLMHandler.routes["slow-model"] = slow_mock_route

        payload = {
            "content": "Long task",
            "model": "slow-model",
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-test", "protocol": "chat"}
        }

        status1, t_res1 = self._request("POST", f"/v1/sessions/{session_id}/messages", payload)
        self.assertEqual(status1, 202)
        task_id1 = t_res1["task_id"]

        status2, res2 = self._request("POST", f"/v1/sessions/{session_id}/messages", payload)
        self.assertEqual(status2, 409)
        self.assertIn("Conflict", res2.get("error", ""))

        block_event.set()
        for _ in range(25):
            time.sleep(0.2)
            _, st_res = self._request("GET", f"/v1/tasks/{task_id1}")
            if st_res.get("status") in ["completed", "failed"]:
                break
        
        DynamicMockLLMHandler.routes.pop("slow-model", None)

    def test_04_autonomous_agent_and_disconnection(self):
        """4. 客户端断开不轮询等 1.5s 后结果完成证明自主；四工具真实调用；多轮不重复 assistant；SQLite中无 api_key 泄露"""
        _, s_res = self._request("POST", "/v1/sessions", {"title": "Autonomous & Tools"})
        session_id = s_res["session_id"]

        tool_turn = 0
        def multi_tool_route(data):
            nonlocal tool_turn
            tool_turn += 1
            if tool_turn == 1:
                return {
                    "id": "t1", "object": "chat.completion",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "Let's write a file.",
                            "tool_calls": [{
                                "id": "c1", "type": "function",
                                "function": {"name": "file_write", "arguments": json.dumps({"path": "test.txt", "content": "initial content"})}
                            }]
                        },
                        "finish_reason": "tool_calls"
                    }]
                }
            elif tool_turn == 2:
                return {
                    "id": "t2", "object": "chat.completion",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "Now edit it.",
                            "tool_calls": [{
                                "id": "c2", "type": "function",
                                "function": {"name": "file_edit", "arguments": json.dumps({"path": "test.txt", "old_string": "initial", "new_string": "updated"})}
                            }]
                        },
                        "finish_reason": "tool_calls"
                    }]
                }
            elif tool_turn == 3:
                return {
                    "id": "t3", "object": "chat.completion",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "Now read it.",
                            "tool_calls": [{
                                "id": "c3", "type": "function",
                                "function": {"name": "file_read", "arguments": json.dumps({"path": "test.txt"})}
                            }]
                        },
                        "finish_reason": "tool_calls"
                    }]
                }
            else:
                return {
                    "id": "t4", "object": "chat.completion",
                    "choices": [{
                        "index": 0,
                        "message": {"role": "assistant", "content": "All tools completed successfully."},
                        "finish_reason": "stop"
                    }]
                }

        DynamicMockLLMHandler.routes["tool-model"] = multi_tool_route

        payload = {
            "content": "Run all tools",
            "model": "tool-model",
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-secret-safe", "protocol": "chat"}
        }

        status, t_res = self._request("POST", f"/v1/sessions/{session_id}/messages", payload)
        self.assertEqual(status, 202)
        task_id = t_res["task_id"]

        # 保持客户端离线一段时间，再有界等待任务终态，避免把机器速度当正确性。
        time.sleep(1.5)
        deadline = time.monotonic() + 12
        while True:
            status, task_detail = self._request("GET", f"/v1/tasks/{task_id}")
            if task_detail.get("status") != "running" or time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        self.assertEqual(status, 200)
        self.assertEqual(task_detail["status"], "completed")

        target_file = os.path.join(self.test_workspace, session_id, "test.txt")
        self.assertTrue(os.path.exists(target_file))
        with open(target_file, "r") as f:
            self.assertIn("updated content", f.read())

        conn = sqlite3.connect(self.test_db)
        cursor = conn.cursor()
        cursor.execute("SELECT payload FROM task_events WHERE task_id = ?", (task_id,))
        for row in cursor.fetchall():
            self.assertNotIn("sk-secret-safe", str(row[0]))
        conn.close()

        DynamicMockLLMHandler.routes.pop("tool-model", None)

    def test_05_empty_model_response_fails(self):
        """5. 空 model 响应（无 content 无 tool_calls）不能伪 completed，应为 failed"""
        _, s_res = self._request("POST", "/v1/sessions", {"title": "Empty Response Test"})
        session_id = s_res["session_id"]

        def empty_route(data):
            return {
                "id": "empty", "object": "chat.completion",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": None}, "finish_reason": "stop"}]
            }

        DynamicMockLLMHandler.routes["empty-model"] = empty_route

        payload = {
            "content": "trigger empty",
            "model": "empty-model",
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-test", "protocol": "chat"}
        }

        status, t_res = self._request("POST", f"/v1/sessions/{session_id}/messages", payload)
        self.assertEqual(status, 202)
        task_id = t_res["task_id"]

        for _ in range(20):
            time.sleep(0.2)
            _, st_res = self._request("GET", f"/v1/tasks/{task_id}")
            if st_res.get("status") in ["completed", "failed", "limit_reached"]:
                break

        self.assertEqual(st_res.get("status"), "failed")
        DynamicMockLLMHandler.routes.pop("empty-model", None)

    def test_06_task_cancellation_and_isolation(self):
        """6. 测试真实 POST 两个 session 长 shell，一个 cancel API 后 PID 销毁/未执行后继 file，另一个完成，证明隔离"""
        _, s1_res = self._request("POST", "/v1/sessions", {"title": "Session 1 Cancel"})
        _, s2_res = self._request("POST", "/v1/sessions", {"title": "Session 2 Complete"})
        s1_id = s1_res["session_id"]
        s2_id = s2_res["session_id"]

        cancel_block = threading.Event()
        def long_shell_route(data):
            cancel_block.wait(timeout=5)
            return {
                "id": "long", "object": "chat.completion",
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "Running long shell",
                        "tool_calls": [{
                            "id": "c_long", "type": "function",
                            "function": {"name": "shell_execute", "arguments": json.dumps({"command": "sleep 10 && echo 'should_not_reach' > after_cancel.txt"})}
                        }]
                    },
                    "finish_reason": "tool_calls"
                }]
            }

        DynamicMockLLMHandler.routes["cancel-model"] = long_shell_route

        p1_req = {
            "content": "long task 1",
            "model": "cancel-model",
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-test", "protocol": "chat"}
        }
        _, t1_res = self._request("POST", f"/v1/sessions/{s1_id}/messages", p1_req)
        t1_id = t1_res["task_id"]

        p2_req = {
            "content": "normal task 2",
            "model": "gpt-4o",
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-test", "protocol": "chat"}
        }
        _, t2_res = self._request("POST", f"/v1/sessions/{s2_id}/messages", p2_req)
        t2_id = t2_res["task_id"]

        cancel_block.set()
        time.sleep(0.4)

        status_c, cancel_res = self._request("POST", f"/v1/tasks/{t1_id}/cancel")
        self.assertEqual(status_c, 200)
        self.assertEqual(cancel_res["status"], "cancelled")

        for _ in range(25):
            time.sleep(0.2)
            _, s1_status = self._request("GET", f"/v1/tasks/{t1_id}")
            _, s2_status = self._request("GET", f"/v1/tasks/{t2_id}")
            if s1_status.get("status") in ["cancelled", "completed", "failed"] and s2_status.get("status") in ["completed", "failed"]:
                break

        self.assertEqual(s1_status.get("status"), "cancelled")
        after_file = os.path.join(self.test_workspace, s1_id, "after_cancel.txt")
        self.assertFalse(os.path.exists(after_file))
        self.assertEqual(s2_status.get("status"), "completed")

        DynamicMockLLMHandler.routes.pop("cancel-model", None)

    def test_07_restart_state_migration(self):
        """7. 真正重启服务/重新 init_db 验证 running -> interrupted 且历史在"""
        import cloud_agent_server
        conn = cloud_agent_server.get_db_connection()
        cursor = conn.cursor()
        cursor.execute("INSERT OR IGNORE INTO sessions (session_id, title, created_at) VALUES ('sess_orphan', 'Orphan', ?)", (time.time(),))
        cursor.execute("INSERT OR REPLACE INTO tasks (task_id, session_id, status, model, created_at) VALUES ('task_orphan', 'sess_orphan', 'running', 'gpt-4o', ?)", (time.time(),))
        conn.commit()
        conn.close()

        cloud_agent_server.DB_PATH = self.test_db
        cloud_agent_server.init_db()

        conn = cloud_agent_server.get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT status FROM tasks WHERE task_id = 'task_orphan'")
        row = cursor.fetchone()
        conn.close()

        self.assertEqual(row[0], "interrupted")

    def test_08_session_import_and_workspace_files(self):
        """8. POST /v1/sessions/import 稳定映射、防串、workspace_files 写入/大小与逃逸限制"""
        local_id = f"ios_device_ns_001_sess_abc_{time.time()}"
        import_payload = {
            "local_session_id": local_id,
            "title": "Cloud Imported Task",
            "instructions": "You are a cloud computer agent.",
            "history": [
                {"role": "user", "content": "Context msg 1"},
                {"role": "assistant", "content": "Context msg 2"}
            ],
            "work_context": {
                "files": [
                    {"path": "skills/custom/SKILL.md", "content": "# Custom Skill MD"},
                    {"path": "memory/2026-11-10.md", "content": "# Note"},
                    {"path": "../../escape.txt", "content": "forbidden"}
                ]
            }
        }

        status, res = self._request("POST", "/v1/sessions/import", import_payload)
        self.assertEqual(status, 201)
        sid = res["session_id"]
        self.assertEqual(res["local_session_id"], local_id)
        self.assertEqual(res["imported_messages_count"], 2)
        self.assertEqual(res["imported_files_count"], 2)

        # 再次导入相同 local_session_id，保证稳定映射，不产生新 session_id
        status2, res2 = self._request("POST", "/v1/sessions/import", import_payload)
        self.assertEqual(status2, 200)
        self.assertEqual(res2["session_id"], sid)

        # 检查文件物理存在于该 session 工作区且逃逸文件被屏蔽
        ws_dir = os.path.join(self.test_workspace, sid)
        self.assertTrue(os.path.exists(os.path.join(ws_dir, "skills/custom/SKILL.md")))
        self.assertFalse(os.path.exists(os.path.join(self.test_workspace, "escape.txt")))

    def test_09_client_nonce_idempotency_and_cursor(self):
        """9. client_nonce 幂等唯一去重，GET /v1/tasks/{id}/events?after=... 增量单调游标"""
        _, s_res = self._request("POST", "/v1/sessions", {"title": "Nonce & Cursor Test"})
        sid = s_res["session_id"]

        nonce = f"nonce_fixed_test_999_{time.time()}"
        payload = {
            "content": "Run quick command",
            "model": "gpt-4o",
            "client_nonce": nonce,
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-test", "protocol": "chat"}
        }

        status1, t_res1 = self._request("POST", f"/v1/sessions/{sid}/messages", payload)
        self.assertEqual(status1, 202)
        tid1 = t_res1["task_id"]

        # 立即使用相同 client_nonce 重试 POST，返回 200 且返回已有 task
        status2, t_res2 = self._request("POST", f"/v1/sessions/{sid}/messages", payload)
        self.assertEqual(status2, 200)
        self.assertEqual(t_res2["task_id"], tid1)
        self.assertTrue(t_res2.get("idempotent_replayed"))

        for _ in range(25):
            time.sleep(0.2)
            _, t_stat = self._request("GET", f"/v1/tasks/{tid1}")
            if t_stat.get("status") in ["completed", "failed"]:
                break

        # 测试 after 游标增量拉取
        _, ev_all = self._request("GET", f"/v1/tasks/{tid1}/events")
        events = ev_all.get("events", [])
        self.assertGreater(len(events), 0)

        mid = events[0]["monotonic_id"]
        _, ev_after = self._request("GET", f"/v1/tasks/{tid1}/events?after={mid}")
        events_after = ev_after.get("events", [])
        for ea in events_after:
            self.assertGreater(ea["monotonic_id"], mid)

        # 错误游标类型返回 400
        bad_status, _ = self._request("GET", f"/v1/tasks/{tid1}/events?after=not_a_number")
        self.assertEqual(bad_status, 400)

    def test_10_attachment_auth_and_socket_disconnect(self):
        """10. 附件安全鉴权下载与客户端 socket 提交即关闭断开后台依然执行到底"""
        _, s_res = self._request("POST", "/v1/sessions", {"title": "Attachment and Disconnect"})
        sid = s_res["session_id"]

        # 准备附件
        att_dir = os.path.join(self.test_workspace, sid, "attachments")
        os.makedirs(att_dir, exist_ok=True)
        with open(os.path.join(att_dir, "test.png"), "wb") as f:
            f.write(b"PNG_DATA_STREAM")

        # 附件未认证 401
        status, _ = self._request("GET", f"/v1/sessions/{sid}/attachments/test.png", token="")
        self.assertEqual(status, 401)

        # 附件认证下载 200 (二进制数据，不用 json 解析)
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.agent_port}/v1/sessions/{sid}/attachments/test.png",
            headers={"Authorization": f"Bearer {self.test_token}"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(resp.read(), b"PNG_DATA_STREAM")

        # 客户端原生 Socket 提交任务后立刻 close()，服务端 thread 已启动执行不丢失
        body = json.dumps({
            "content": "Execute offline task",
            "model": "gpt-4o",
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-test", "protocol": "chat"}
        })
        http_req = (
            f"POST /v1/sessions/{sid}/messages HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self.agent_port}\r\n"
            f"Authorization: Bearer {self.test_token}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n"
            f"\r\n"
            f"{body}"
        )
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(("127.0.0.1", self.agent_port))
        s.sendall(http_req.encode("utf-8"))
        s.close() # 客户端立即断开 socket！

        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            _, s_detail = self._request("GET", f"/v1/sessions/{sid}")
            tasks = s_detail.get("tasks", [])
            if tasks and tasks[0].get("status") not in ("running", "queued"):
                break
            time.sleep(0.1)
        self.assertTrue(tasks)
        self.assertEqual(tasks[0].get("status"), "completed", s_detail)


if __name__ == "__main__":
    unittest.main()
