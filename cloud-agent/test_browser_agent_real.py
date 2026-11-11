#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Computer & Browser Agent Real End-to-End Validation
- POST import session
- POST task message with raw TCP socket and immediate close
- Autonomous cloud model loop with browser_action (navigate, type, click, screenshot, get_text)
- Verify vision observation image_url injected for screenshot
- Poll GET /v1/sessions/{id} until completed
- Stop / Start browser context and verify localStorage persistence
"""

import os
import sys
import json
import time
import socket
import unittest
import urllib.request
import urllib.error
import threading
import sqlite3
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler, SimpleHTTPRequestHandler

EVIDENCE_PATH = os.environ.get("OPENMINIS_EVIDENCE_PATH", "/tmp/combined-browser-evidence.log")

def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(os.path.abspath(EVIDENCE_PATH)), exist_ok=True)
        with open(EVIDENCE_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

# Local Mock LLM
class MockLLMHandler(BaseHTTPRequestHandler):
    vision_image_received = False
    
    def do_POST(self):
        if self.path == "/v1/chat/completions":
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(length).decode("utf-8"))
            messages = data.get("messages", [])
            
            # Check if vision user observation was injected by server after screenshot
            for m in messages:
                content = m.get("content")
                if isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get("type") == "image_url":
                            url_val = part.get("image_url", {}).get("url", "")
                            if url_val.startswith("data:image/png;base64,"):
                                MockLLMHandler.vision_image_received = True

            tool_turns = len([m for m in messages if m.get("role") == "tool"])
            
            if tool_turns == 0:
                resp = {
                    "id": "mock-step-1", "object": "chat.completion",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "Step 1: Navigate to test page.",
                            "tool_calls": [{
                                "id": "call_nav", "type": "function",
                                "function": {
                                    "name": "browser_action",
                                    "arguments": json.dumps({"action": "navigate", "url": "http://127.0.0.1:18780/test_page.html"})
                                }
                            }]
                        },
                        "finish_reason": "tool_calls"
                    }]
                }
            elif tool_turns == 1:
                resp = {
                    "id": "mock-step-2", "object": "chat.completion",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "Step 2: Type verification text.",
                            "tool_calls": [{
                                "id": "call_type", "type": "function",
                                "function": {
                                    "name": "browser_action",
                                    "arguments": json.dumps({"action": "type", "selector": "#name", "text": "Client-Disconnected-Autonomous-Execution"})
                                }
                            }]
                        },
                        "finish_reason": "tool_calls"
                    }]
                }
            elif tool_turns == 2:
                resp = {
                    "id": "mock-step-3", "object": "chat.completion",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "Step 3: Click commit button.",
                            "tool_calls": [{
                                "id": "call_click", "type": "function",
                                "function": {
                                    "name": "browser_action",
                                    "arguments": json.dumps({"action": "click", "selector": "#go"})
                                }
                            }]
                        },
                        "finish_reason": "tool_calls"
                    }]
                }
            elif tool_turns == 3:
                resp = {
                    "id": "mock-step-4", "object": "chat.completion",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "Step 4: Take screenshot to verify visual state and feed vision observation.",
                            "tool_calls": [{
                                "id": "call_shot", "type": "function",
                                "function": {
                                    "name": "browser_action",
                                    "arguments": json.dumps({"action": "screenshot"})
                                }
                            }]
                        },
                        "finish_reason": "tool_calls"
                    }]
                }
            elif tool_turns == 4:
                resp = {
                    "id": "mock-step-5", "object": "chat.completion",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "Step 5: Get text from result paragraph.",
                            "tool_calls": [{
                                "id": "call_text", "type": "function",
                                "function": {
                                    "name": "browser_action",
                                    "arguments": json.dumps({"action": "get_text", "selector": "#result"})
                                }
                            }]
                        },
                        "finish_reason": "tool_calls"
                    }]
                }
            else:
                resp = {
                    "id": "mock-final", "object": "chat.completion",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "Autonomous browser loop finished with success."
                        },
                        "finish_reason": "stop"
                    }]
                }

            b = json.dumps(resp).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass

@unittest.skipUnless(os.environ.get('OPENMINIS_REAL_BROWSER_AGENT_TEST') == '1', '真实浏览器模型循环验证由显式运行')
class RealBrowserAgentTests(unittest.TestCase):
    def test_browser_model_loop_and_persistence(self):
        log("================================================================================")
        log("[START] 真实云电脑 Chromium 浏览器端到端模型循环验证")
        log("================================================================================")

        # 1. 启动静态网页 HTTP 服务器 (端口 18780)
        html_dir = "/tmp/browser_test_page"
        os.makedirs(html_dir, exist_ok=True)
        html_file = os.path.join(html_dir, "test_page.html")
        with open(html_file, "w", encoding="utf-8") as f:
            f.write("""<!DOCTYPE html>
<html>
<head><title>OpenMinis Real Browser Validation</title></head>
<body>
  <h1>Real Browser Validation Page</h1>
  <input id="name" type="text" />
  <button id="go" onclick="
    var v = document.getElementById('name').value;
    document.getElementById('result').innerText = 'Processed: ' + v;
    localStorage.setItem('openminis_saved_proof', v);
  ">Submit</button>
  <p id="result">Idle</p>
  <script>
    window.onload = function() {
      var s = localStorage.getItem('openminis_saved_proof');
      if (s) {
        document.getElementById('result').innerText = 'Restored: ' + s;
      }
    };
  </script>
</body>
</html>""")

        class PageHandler(SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=html_dir, **kwargs)
            def log_message(self, format, *args):
                pass

        page_server = ThreadingHTTPServer(("127.0.0.1", 18780), PageHandler)
        threading.Thread(target=page_server.serve_forever, daemon=True).start()
        log("✓ 静态测试网页服务已在 127.0.0.1:18780 启动")

        # 2. 启动 MockLLM (动态端口)
        mock_server = ThreadingHTTPServer(("127.0.0.1", 0), MockLLMHandler)
        mock_port = mock_server.server_address[1]
        threading.Thread(target=mock_server.serve_forever, daemon=True).start()
        mock_base_url = f"http://127.0.0.1:{mock_port}/v1"
        log(f"✓ MockLLM 服务已在 127.0.0.1:{mock_port} 启动")

        # 3. 读取本地 Token 并验证云电脑服务健康 (不输出 token 值)
        token_path = "/etc/openminis/token"
        self.assertTrue(os.path.exists(token_path), "/etc/openminis/token 必须存在")
        with open(token_path, "r", encoding="utf-8") as f:
            token = f.read().strip()
        self.assertTrue(len(token) > 0, "Token 不能为空")

        req = urllib.request.Request("http://127.0.0.1:18765/health")
        with urllib.request.urlopen(req, timeout=5) as resp:
            health = json.loads(resp.read().decode())
            log(f"✓ 云电脑服务健康检查通过: capabilities={health.get('capabilities')}")
            self.assertEqual(health.get("status"), "ok")
            self.assertTrue(health.get("capabilities", {}).get("browser"))

        # 4. POST 导入普通会话
        session_uid = f"session_real_browser_{int(time.time())}"
        import_body = json.dumps({
            "local_session_id": session_uid,
            "title": "Real Browser Session",
            "instructions": "You are OpenMinis Cloud Browser Agent.",
            "history": []
        }).encode("utf-8")
        req = urllib.request.Request(
            "http://127.0.0.1:18765/v1/sessions/import",
            data=import_body,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            sess_resp = json.loads(resp.read().decode())
            session_id = sess_resp["session_id"]
            log(f"✓ POST /v1/sessions/import 成功创建会话: {session_id}")

        # 2.50.0 默认「秒回」：前台没有 browser_action，截图不会发生，MockLLM 也收不到 image_url。
        # 本测试验证的是完整浏览器模型循环（含视觉回灌），所以这个会话改用「详细」。
        reply_body = json.dumps({"mode": "verbose"}).encode("utf-8")
        req = urllib.request.Request(
            f"http://127.0.0.1:18765/v1/sessions/{session_id}/reply",
            data=reply_body,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            method="PUT",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            reply = json.loads(resp.read().decode())
        self.assertEqual((reply.get("reply") or {}).get("mode"), "verbose", reply)
        log("✓ 本会话回复方式已设为详细，保留完整浏览器工具")

        # 5. POST 任务并通过 raw socket 发送后立即关闭连接（验证服务端脱机自主执行）
        task_payload = json.dumps({
            "content": "Execute autonomous browser model loop",
            "model": "gpt-4o",
            "client_nonce": f"nonce-{time.time()}",
            "provider": {
                "protocol": "chat",
                "base_url": mock_base_url,
                "api_key": "test-mock-key"
            }
        }).encode("utf-8")

        log("✓ 正在通过原生 TCP Socket 提交任务并立即断开客户端连接...")
        s = socket.create_connection(("127.0.0.1", 18765), timeout=5)
        raw_req = (
            f"POST /v1/sessions/{session_id}/messages HTTP/1.1\r\n"
            f"Host: 127.0.0.1:18765\r\n"
            f"Authorization: Bearer {token}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(task_payload)}\r\n"
            f"Connection: close\r\n\r\n"
        ).encode("utf-8") + task_payload
        s.sendall(raw_req)
        s.close()
        log("✓ 客户端 Socket 已立即断开，远端模型任务后台自主运行中...")

        # 6. 有界等待 (timeout 60s) 通过 GET /v1/sessions/{session_id} 验证任务状态 completed
        deadline = time.monotonic() + 60
        task_id = None
        completed = False
        final_status = None
        while time.monotonic() < deadline:
            time.sleep(1.0)
            try:
                req = urllib.request.Request(
                    f"http://127.0.0.1:18765/v1/sessions/{session_id}",
                    headers={"Authorization": f"Bearer {token}"}
                )
                with urllib.request.urlopen(req, timeout=5) as resp:
                    detail = json.loads(resp.read().decode())
                    tasks = detail.get("tasks", [])
                    if tasks:
                        latest = tasks[0]
                        task_id = latest["task_id"]
                        final_status = latest["status"]
                        log(f"  任务执行状态轮询: {final_status}")
                        if final_status in ["completed", "failed", "cancelled", "limit_reached"]:
                            if final_status == "completed":
                                completed = True
                            break
            except Exception as e:
                log(f"  轮询请求异常: {e}")

        self.assertTrue(completed, f"任务未在有界时限内完成 (最终状态: {final_status})")
        log(f"✓ 任务成功在客户端离线状态下自主完成: task_id={task_id}, status=completed")

        # 7. 验证视觉模型接收到了 screenshot image_url
        log(f"✓ 视觉自动回灌状态校验: MockLLM 接收到 image_url={MockLLMHandler.vision_image_received}")
        self.assertTrue(MockLLMHandler.vision_image_received, "MockLLM 必须接收到自动回灌的 base64 image_url")

        # 8. 检查 session 历史中的文字结果与截图附件
        req = urllib.request.Request(
            f"http://127.0.0.1:18765/v1/sessions/{session_id}",
            headers={"Authorization": f"Bearer {token}"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            detail = json.loads(resp.read().decode())
            messages = detail.get("messages", [])
            log(f"✓ 会话历史已完整记录 {len(messages)} 条消息")
            has_text_proof = any("Client-Disconnected-Autonomous-Execution" in str(m.get("content")) for m in messages)
            self.assertTrue(has_text_proof, "工具执行结果中必须包含已填入的 DOM 文本")
            has_screenshot = any("browser_" in str(m.get("content")) and ".png" in str(m.get("content")) for m in messages)
            self.assertTrue(has_screenshot, "工具执行结果中必须包含截图附件路径")

        # 9. 独立验证 browser 上下文 stop/start 后 localStorage 保留（真实持久化测试）
        log("================================================================================")
        log("[TEST] 验证浏览器上下文 stop/start 后 localStorage 真实持久化")
        log("================================================================================")
        
        sys.path.insert(0, "/opt/openminis-cloud-agent")
        import cloud_browser
        
        persist_session = f"persist_session_{int(time.time())}"
        persist_ws = f"/var/lib/openminis-cloud-agent/workspace/{persist_session}"
        os.makedirs(persist_ws, exist_ok=True)
        
        # 9.1 首次启动上下文，导航并写入 localStorage
        daemon = cloud_browser.get_daemon()
        log("✓ 打开独立持久会话页面并写入 localStorage...")
        res_nav1 = cloud_browser.execute_browser_action(
            persist_session,
            persist_ws,
            {"action": "navigate", "url": "http://127.0.0.1:18780/test_page.html"}
        )
        self.assertNotIn("error", res_nav1, str(res_nav1))
        
        res_type = cloud_browser.execute_browser_action(
            persist_session,
            persist_ws,
            {"action": "type", "selector": "#name", "text": "Storage-Survives-Process-Restart"}
        )
        self.assertNotIn("error", res_type, str(res_type))
        
        res_click = cloud_browser.execute_browser_action(
            persist_session,
            persist_ws,
            {"action": "click", "selector": "#go"}
        )
        self.assertNotIn("error", res_click, str(res_click))
        
        res_text1 = cloud_browser.execute_browser_action(
            persist_session,
            persist_ws,
            {"action": "get_text", "selector": "#result"}
        )
        self.assertIn("Processed: Storage-Survives-Process-Restart", res_text1.get("text", ""))
        log("✓ 已确认页面触发点击并执行 localStorage.setItem")

        # 9.2 完全关闭并停止浏览器 daemon（终止 Chromium 进程，刷盘释放句柄）
        log("✓ 正在执行 daemon.stop() 完全停止浏览器上下文进程并刷盘...")
        daemon.stop()
        time.sleep(1.5)
        self.assertFalse(daemon.running, "Daemon 必须已完全停止")

        # 9.3 再次启动浏览器 daemon 并导航至同一页面，验证 onload 从 localStorage 恢复
        log("✓ 正在重启浏览器 daemon 并加载同 session profile...")
        res_nav2 = cloud_browser.execute_browser_action(
            persist_session,
            persist_ws,
            {"action": "navigate", "url": "http://127.0.0.1:18780/test_page.html"}
        )
        self.assertNotIn("error", res_nav2, str(res_nav2))
        
        res_text2 = cloud_browser.execute_browser_action(
            persist_session,
            persist_ws,
            {"action": "get_text", "selector": "#result"}
        )
        log(f"✓ 重启后 onload 读回结果: {res_text2}")
        self.assertIn("Restored: Storage-Survives-Process-Restart", res_text2.get("text", ""))
        log("✓ [PASS] 成功证明: 浏览器完全停止后重启，localStorage 依然保留！属于真正磁盘持久化！")
        
        daemon.stop()
        log("================================================================================")
        log("[SUCCESS] 全流程真实云电脑与真实浏览器模型循环验收 100% 通过！")
        log("================================================================================")

if __name__ == "__main__":
    unittest.main(verbosity=2)
