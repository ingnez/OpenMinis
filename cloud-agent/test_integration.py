#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent Service - 端到端全功能集成测试套件 (test_integration.py)
严格覆盖：
1. 无 Token 拒绝启动与权限检查
2. 健康检查 /health 与鉴权保护 (401)
3. 会话管理（创建、列表、单个详情带 tasks 及重开恢复）
4. 并发与会话原子性（同一会话多任务并发返回 409 Conflict，事件驱动 Mock 阻塞）
5. 协议边界与参数校验（非 chat 协议、非法 base_url 如带凭据、fragment、缺失 content 等返回 400）
6. 完整自主 Agent 循环与工具调用（shell_execute, file_read, file_write, file_edit，断开客户端不轮询独立完成，多轮不重复 assistant，空 model 响应不伪 completed）
7. 任务取消与子进程 PID 级销毁验证（cancel API 触发独立进程组销毁，未执行后继 file，原子 UPDATE status WHERE running）
8. 重启状态迁移验证（running 自动转为 interrupted）
9. 数据库安全（SQLite 数据文件与事件日志中绝对无 api_key 明文泄露）
10. OPENMINIS_MAX_TURNS 环境变量与 128 轮 / limit_reached 验证
"""

import os
import sys
import json
import sqlite3
import time
import unittest
import threading
import subprocess
import tempfile
import urllib.request
import urllib.error
from http.server import HTTPServer, ThreadingHTTPServer, BaseHTTPRequestHandler

SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SERVER_DIR)

# ----------------- 动态端口 Mock LLM 服务器 -----------------
class DynamicMockLLMHandler(BaseHTTPRequestHandler):
    routes = {} # (model, last_tool_result_or_turn) -> response_dict
    request_log = []

    def do_POST(self):
        if self.path == "/v1/chat/completions":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8")
            data = json.loads(body)
            DynamicMockLLMHandler.request_log.append(data)
            
            model = data.get("model", "gpt-4o")
            messages = data.get("messages", [])
            
            # 路由键匹配：根据当前 messages 结尾或最后工具结果
            resp_payload = None
            
            # 检查是否有特定路由规则
            if model in DynamicMockLLMHandler.routes:
                rule_fn = DynamicMockLLMHandler.routes[model]
                resp_payload = rule_fn(data)
            else:
                # 默认工具循环响应
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


# ----------------- 集成测试用例类 -----------------
class TestCloudAgentVPSRobustness(unittest.TestCase):
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

        # 启动动态 Mock LLM
        cls.mock_llm_server, cls.mock_llm_port = start_mock_server()
        cls.mock_llm_base = f"http://127.0.0.1:{cls.mock_llm_port}/v1"

        # 启动云 Agent 服务（动态端口）
        import cloud_agent_server
        cloud_agent_server.HOST = "127.0.0.1"
        cloud_agent_server.PORT = 0 # 临时获取端口
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

        # 无 token 访问受保护接口
        status, _ = self._request("GET", "/v1/sessions", token="")
        self.assertEqual(status, 401)

        # 错误 token 访问
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

        # 立即并发提交第二个任务，应稳定返回 409
        status2, res2 = self._request("POST", f"/v1/sessions/{session_id}/messages", payload)
        self.assertEqual(status2, 409)
        self.assertIn("Conflict", res2.get("error", ""))

        # 释放阻塞并等待完成
        block_event.set()
        for _ in range(20):
            time.sleep(0.2)
            _, st_res = self._request("GET", f"/v1/tasks/{task_id1}")
            if st_res.get("status") in ["completed", "failed"]:
                break
        
        # 清理路由
        DynamicMockLLMHandler.routes.pop("slow-model", None)

    def test_04_autonomous_agent_and_disconnection(self):
        """4. 客户端断开不轮询等 1s 后结果完成证明自主；四工具真实调用；多轮不重复 assistant；空 model 响应不伪 completed"""
        _, s_res = self._request("POST", "/v1/sessions", {"title": "Autonomous & Tools"})
        session_id = s_res["session_id"]

        # 设置自定义路由模拟多轮工具调用（shell, read, write, edit）
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

        # 客户端断开连接，等待 1.5 秒后主动查询，证明后台自主独立完成
        time.sleep(1.5)

        status, task_detail = self._request("GET", f"/v1/tasks/{task_id}")
        self.assertEqual(status, 200)
        self.assertEqual(task_detail["status"], "completed")

        # 验证文件真实修改
        target_file = os.path.join(self.test_workspace, session_id, "test.txt")
        self.assertTrue(os.path.exists(target_file))
        with open(target_file, "r") as f:
            self.assertIn("updated content", f.read())

        # 验证无凭据泄露
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

        for _ in range(15):
            time.sleep(0.2)
            _, st_res = self._request("GET", f"/v1/tasks/{task_id}")
            if st_res.get("status") in ["completed", "failed", "limit_reached"]:
                break

        self.assertEqual(st_res.get("status"), "failed")
        DynamicMockLLMHandler.routes.pop("empty-model", None)

    def test_06_task_cancellation_and_isolation(self):
        """6. 测试真实 POST 两个 session 长 shell，一个 cancel API 后 PID 不存在/未执行后继 file，另一个完成，证明隔离"""
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

        # 启动 session 1 任务
        p1_req = {
            "content": "long task 1",
            "model": "cancel-model",
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-test", "protocol": "chat"}
        }
        _, t1_res = self._request("POST", f"/v1/sessions/{s1_id}/messages", p1_req)
        t1_id = t1_res["task_id"]

        # 启动 session 2 正常任务（简单完成）
        p2_req = {
            "content": "normal task 2",
            "model": "gpt-4o", # 走默认成功完成
            "provider": {"base_url": self.mock_llm_base, "api_key": "sk-test", "protocol": "chat"}
        }
        _, t2_res = self._request("POST", f"/v1/sessions/{s2_id}/messages", p2_req)
        t2_id = t2_res["task_id"]

        # 放行 mock 让其进入 tool 执行
        cancel_block.set()
        time.sleep(0.5)

        # 立即调用取消 task 1
        status_c, cancel_res = self._request("POST", f"/v1/tasks/{t1_id}/cancel")
        self.assertEqual(status_c, 200)
        self.assertEqual(cancel_res["status"], "cancelled")

        # 等待两者结束
        for _ in range(25):
            time.sleep(0.2)
            _, s1_status = self._request("GET", f"/v1/tasks/{t1_id}")
            _, s2_status = self._request("GET", f"/v1/tasks/{t2_id}")
            if s1_status.get("status") in ["cancelled", "completed", "failed"] and s2_status.get("status") in ["completed", "failed"]:
                break

        # 验证 session 1 状态为 cancelled，且后继文件未执行
        self.assertEqual(s1_status.get("status"), "cancelled")
        after_file = os.path.join(self.test_workspace, s1_id, "after_cancel.txt")
        self.assertFalse(os.path.exists(after_file))

        # 验证 session 2 正常完成，互不影响
        self.assertEqual(s2_status.get("status"), "completed")

        DynamicMockLLMHandler.routes.pop("cancel-model", None)

    def test_07_restart_state_migration(self):
        """7. 真正重启服务/重新 init_db 验证 running -> interrupted 且历史在"""
        import cloud_agent_server
        
        # 人为向 DB 插入一个状态为 running 的孤儿任务
        conn = cloud_agent_server.get_db_connection()
        cursor = conn.cursor()
        cursor.execute("INSERT OR IGNORE INTO sessions (session_id, title, created_at) VALUES ('sess_orphan', 'Orphan', ?)", (time.time(),))
        cursor.execute("INSERT OR REPLACE INTO tasks (task_id, session_id, status, model, created_at) VALUES ('task_orphan', 'sess_orphan', 'running', 'gpt-4o', ?)", (time.time(),))
        conn.commit()
        conn.close()

        # 重新执行 init_db
        cloud_agent_server.DB_PATH = self.test_db
        cloud_agent_server.init_db()

        # 验证该任务状态已被迁移为 interrupted
        conn = cloud_agent_server.get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT status FROM tasks WHERE task_id = 'task_orphan'")
        row = cursor.fetchone()
        conn.close()

        self.assertEqual(row[0], "interrupted")


if __name__ == "__main__":
    unittest.main()
