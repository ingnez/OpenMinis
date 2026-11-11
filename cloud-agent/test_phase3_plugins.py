#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 3：插件（MCP 连接器 + 技能包），按 Bot 授权，密钥加密，needs_auth，写操作审批，手机 MCP 导入。"""

import json
import os
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns, _serve

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE = os.path.join(HERE, "test_fake_mcp_server.py")


def stdio_manifest(pid="fake", secrets=None, confirm=None):
    m = {"id": pid, "kind": "mcp", "name": "Fake", "mcp": {"transport": "stdio", "command": sys.executable, "args": [FAKE]}}
    if secrets:
        m["secrets"] = secrets
    if confirm:
        m["confirm_pattern"] = confirm
    return m


class FakeHttpMCP(BaseHTTPRequestHandler):
    required_auth = "Bearer good"

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if self.headers.get("Authorization") != self.required_auth:
            self.send_response(401)
            self.end_headers()
            return
        if "id" not in body:
            self.send_response(202)
            self.end_headers()
            return
        m = body["method"]
        if m == "initialize":
            result = {"protocolVersion": "2025-03-26", "capabilities": {}, "serverInfo": {"name": "h", "version": "1"}}
        elif m == "tools/list":
            result = {"tools": [{"name": "search", "description": "Search", "inputSchema": {"type": "object", "properties": {"q": {"type": "string"}}}}]}
        else:
            result = {"content": [{"type": "text", "text": "hits for " + body["params"]["arguments"].get("q", "")}]}
        data = ("event: message\ndata: " + json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": result}) + "\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Mcp-Session-Id", "sess-1")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class PluginTests(CloudServerTestCase):
    approval_mode = "ask"
    def setUp(self):
        self.srv.PLUGINS.close_all()
        self.srv.PLUGINS.plugin_dir = os.path.join(self.tmp.name, "plugin-files")

    def test_01_catalog_and_skill_pack(self):
        status, res = self.request("GET", "/v1/plugins")
        self.assertEqual(status, 200)
        ids = [c["id"] for c in res["catalog"]]
        for pid in ("fetch", "github", "deepwiki", "skills-research"):
            self.assertIn(pid, ids)
        status, p = self.request("POST", "/v1/plugins/install", {"catalog_id": "skills-research"})
        self.assertEqual((status, p["status"]), (201, "ready"))
        names = [s["name"] for s in self.request("GET", "/v1/skills")[1]["skills"]]
        self.assertIn("web-research", names)
        status, p = self.request("POST", "/v1/plugins/install", {"catalog_id": "github"})
        self.assertEqual(p["status"], "needs_auth")
        self.assertEqual(p["secrets"], [{"name": "GITHUB_TOKEN", "label": "GitHub Personal Access Token", "set": False, "optional": False}])
        p = self.request("PUT", "/v1/plugins/github", {"secrets": {"GITHUB_TOKEN": "ghp_secretvalue123"}})[1]
        self.assertTrue(p["secrets"][0]["set"])
        self.assertNotIn("ghp_secretvalue123", json.dumps(self.request("GET", "/v1/plugins")[1]))
        self.assertEqual(self.request("PUT", "/v1/plugins/github", {"secrets": {"OTHER": "x"}})[0], 400)
        self.assertEqual(self.request("DELETE", "/v1/plugins/skills-research")[0], 200)
        names = [s["name"] for s in self.request("GET", "/v1/skills")[1]["skills"]]
        self.assertNotIn("web-research", names)
        self.request("DELETE", "/v1/plugins/github")

    def test_catalog_marks_installed_and_install_is_idempotent(self):
        status, res = self.request("GET", "/v1/plugins")
        self.assertEqual(status, 200)
        daily = next(c for c in res["catalog"] if c["id"] == "skills-daily")
        self.assertFalse(daily.get("installed"))
        status, p = self.request("POST", "/v1/plugins/install", {"catalog_id": "skills-daily"})
        self.assertEqual(status, 201)
        self.assertTrue(p.get("created"))
        self.assertFalse(p.get("already_installed"))
        self.assertEqual(p.get("message"), "安装成功")
        status, res = self.request("GET", "/v1/plugins")
        self.assertEqual(status, 200)
        daily = next(c for c in res["catalog"] if c["id"] == "skills-daily")
        self.assertTrue(daily.get("installed"), "安装后目录项应标记为已安装")
        self.assertEqual([x["plugin_id"] for x in res["installed"]].count("skills-daily"), 1)
        status, p2 = self.request("POST", "/v1/plugins/install", {"catalog_id": "skills-daily"})
        self.assertEqual(status, 200)
        self.assertFalse(p2.get("created"))
        self.assertTrue(p2.get("already_installed"))
        self.assertIn("已经安装", p2.get("message") or "")
        status, res = self.request("GET", "/v1/plugins")
        self.assertEqual([x["plugin_id"] for x in res["installed"]].count("skills-daily"), 1)
        self.assertTrue(next(c for c in res["catalog"] if c["id"] == "skills-daily").get("installed"))
        self.request("DELETE", "/v1/plugins/skills-daily")

    def test_02_manifest_requires_ack_and_validation(self):
        status, res = self.request("POST", "/v1/plugins/install", {"manifest": stdio_manifest()})
        self.assertEqual((status, res["error"]), (428, "confirm_command"))
        self.assertIn("test_fake_mcp_server.py", res["command"])
        bad = stdio_manifest()
        bad["mcp"]["command"] = "rm -rf /"
        self.assertEqual(self.request("POST", "/v1/plugins/install", {"manifest": bad, "acknowledge_command": True})[0], 400)
        http_bad = {"id": "h", "kind": "mcp", "name": "h", "mcp": {"transport": "http", "url": "http://example.com/mcp"}}
        self.assertEqual(self.request("POST", "/v1/plugins/install", {"manifest": http_bad})[0], 400)
        status, p = self.request("POST", "/v1/plugins/install", {"manifest": stdio_manifest(), "acknowledge_command": True})
        self.assertEqual((status, p["status"]), (201, "ready"))
        tools = self.request("GET", "/v1/plugins/fake/tools")[1]["tools"]
        self.assertEqual([t["name"] for t in tools], ["echo", "add", "create_note", "whoami"])
        self.request("DELETE", "/v1/plugins/fake")

    def test_03_agent_calls_plugin_with_bot_grants_and_secrets(self):
        self.request("POST", "/v1/plugins/install", {"manifest": stdio_manifest(secrets=[{"name": "FAKE_TOKEN", "target": "env"}]),
                                                     "acknowledge_command": True, "secrets": {"FAKE_TOKEN": "tok-123"}, "default_grant": False})
        self.request("PUT", "/v1/bots/tooluser", {"name": "工具人", "instructions": "用插件", "plugins": ["fake"]})
        self.request("PUT", "/v1/bots/plain", {"name": "普通", "instructions": "不用插件"})

        def model(d):
            names = [t["function"]["name"] for t in d.get("tools", [])]
            if d["messages"][-1]["role"] != "tool":
                if "mcp__fake__whoami" not in names:
                    return {"role": "assistant", "content": "no-plugin:" + ",".join(n for n in names if n.startswith("mcp__"))}
                return tool_call("p1", "mcp__fake__whoami", {})
            return {"role": "assistant", "content": d["messages"][-1]["content"]}
        FakeModelHandler.scripts["m-plug"] = model
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "tooluser"})[1]["session_id"]
        self.wait_status(self.submit(sid, "who", "m-plug")[1]["task_id"], ("completed",))
        out = json.loads(tool_turns(FakeModelHandler.requests[-1])[-1]["content"])
        self.assertEqual(out["content"], "token=tok-123")
        self.assertIn("[插件]", FakeModelHandler.requests[-1]["messages"][0]["content"])
        # 未授权的 Bot 与默认会话（default_grant=False）看不到插件工具
        for persona in ("plain", None):
            body = {"title": "p"}
            if persona:
                body["persona_id"] = persona
            s2 = self.request("POST", "/v1/sessions", body)[1]["session_id"]
            self.wait_status(self.submit(s2, "who", "m-plug")[1]["task_id"], ("completed",))
            self.assertNotIn("mcp__", json.dumps([t["function"]["name"] for t in FakeModelHandler.requests[-1]["tools"]]))
        self.request("DELETE", "/v1/plugins/fake")

    def test_04_confirm_pattern_requires_approval(self):
        self.request("POST", "/v1/plugins/install", {"manifest": stdio_manifest(confirm="^create_"), "acknowledge_command": True})

        def model(d):
            if d["messages"][-1]["role"] != "tool":
                return tool_call("c1", "mcp__fake__create_note", {"text": "hi"})
            return {"role": "assistant", "content": "done"}
        FakeModelHandler.scripts["m-confirm"] = model
        sid = self.request("POST", "/v1/sessions", {"title": "c"})[1]["session_id"]
        tid = self.submit(sid, "note", "m-confirm")[1]["task_id"]
        self.wait_status(tid, ("waiting_user",))
        approvals = self.request("GET", f"/v1/tasks/{tid}/approvals")[1]["approvals"]
        self.assertEqual(approvals[0]["rule_id"], "plugin_confirm")
        self.request("POST", f"/v1/tasks/{tid}/approvals/{approvals[0]['approval_id']}", {"decision": "approve"})
        self.wait_status(tid, ("completed",))
        self.assertEqual(json.loads(tool_turns(FakeModelHandler.requests[-1])[-1]["content"])["content"], "created:hi")
        self.request("DELETE", "/v1/plugins/fake")

    def test_05_http_plugin_needs_auth_then_works(self):
        server, port = _serve(FakeHttpMCP)
        try:
            m = {"id": "remote", "kind": "mcp", "name": "Remote", "mcp": {"transport": "http", "url": f"http://127.0.0.1:{port}/mcp"},
                 "secrets": [{"name": "TOKEN", "target": "header:Authorization", "format": "Bearer {value}"}]}
            self.request("POST", "/v1/plugins/install", {"manifest": m, "secrets": {"TOKEN": "bad"}})
            status, res = self.request("GET", "/v1/plugins/remote/tools")
            self.assertEqual((status, res["error"]), (409, "needs_auth"))
            self.assertEqual(self.request("GET", "/v1/plugins/remote")[1]["status"], "needs_auth")

            FakeModelHandler.scripts["m-http"] = lambda d: {"role": "assistant", "content": "ok"}
            sid = self.request("POST", "/v1/sessions", {"title": "h"})[1]["session_id"]
            self.wait_status(self.submit(sid, "q", "m-http")[1]["task_id"], ("completed",))
            self.assertIn("需要授权", FakeModelHandler.requests[-1]["messages"][0]["content"])

            self.request("PUT", "/v1/plugins/remote", {"secrets": {"TOKEN": "good"}})
            self.assertEqual(self.request("GET", "/v1/plugins/remote")[1]["status"], "ready")

            def model(d):
                if d["messages"][-1]["role"] != "tool":
                    return tool_call("h1", "mcp__remote__search", {"q": "mcp"})
                return {"role": "assistant", "content": "ok"}
            FakeModelHandler.scripts["m-http2"] = model
            self.wait_status(self.submit(sid, "q2", "m-http2")[1]["task_id"], ("completed",))
            self.assertEqual(json.loads(tool_turns(FakeModelHandler.requests[-1])[-1]["content"])["content"], "hits for mcp")
            self.request("DELETE", "/v1/plugins/remote")
        finally:
            server.shutdown()

    def test_06_import_phone_mcp(self):
        servers = [{"id": "My Fake", "command": sys.executable, "args": [FAKE], "env": {"FAKE_TOKEN": "phone-secret"}},
                   {"id": "web", "url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer xyz"}},
                   {"id": "bad", "url": "http://insecure.example.com"}]
        res = self.request("POST", "/v1/plugins/import-phone", {"servers": servers})[1]["results"]
        self.assertEqual(res[0]["plugin_id"], "phone-my-fake")
        self.assertEqual(res[1]["plugin_id"], "phone-web")
        self.assertIn("error", res[2])
        listing = json.dumps(self.request("GET", "/v1/plugins")[1])
        self.assertNotIn("phone-secret", listing)
        self.assertNotIn("xyz", listing)
        FakeModelHandler.scripts["m-phone"] = lambda d: (tool_call("w", "mcp__phone-my-fake__whoami", {})
                                                         if d["messages"][-1]["role"] != "tool" else {"role": "assistant", "content": "ok"})
        self.request("PUT", "/v1/plugins/phone-web", {"enabled": False})
        sid = self.request("POST", "/v1/sessions", {"title": "ph"})[1]["session_id"]
        self.wait_status(self.submit(sid, "q", "m-phone")[1]["task_id"], ("completed",))
        self.assertEqual(json.loads(tool_turns(FakeModelHandler.requests[-1])[-1]["content"])["content"], "token=phone-secret")
        for pid in ("phone-my-fake", "phone-web"):
            self.request("DELETE", f"/v1/plugins/{pid}")


class E2ECatalogTests(unittest.TestCase):
    def test_e2e_echo_is_first_in_catalog(self):
        import cloud_plugin_catalog
        key = "OPENMINIS_E2E_FAKE_PLUGIN"
        old = os.environ.get(key)
        os.environ[key] = FAKE
        try:
            ids = [c["id"] for c in cloud_plugin_catalog.entries()]
            self.assertEqual(ids[0], "e2e-echo", "假插件必须排在目录最前，否则控件树里看不到")
            self.assertIn("fetch", ids)
        finally:
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old


class E2ECatalogHTTPTests(CloudServerTestCase):
    """应用读的是 GET /v1/plugins，不只是 entries()；在同样的 HTTP 路径上复现 e2e 注入。"""

    def setUp(self):
        self.srv.PLUGINS.close_all()
        self.srv.PLUGINS.plugin_dir = os.path.join(self.tmp.name, "plugin-files")

    def test_e2e_echo_is_first_in_v1_plugins(self):
        key = "OPENMINIS_E2E_FAKE_PLUGIN"
        old = os.environ.get(key)
        os.environ[key] = FAKE
        try:
            status, res = self.request("GET", "/v1/plugins")
            self.assertEqual(status, 200)
            catalog = res["catalog"]
            ids = [c["id"] for c in catalog]
            self.assertEqual(ids[0], "e2e-echo", "GET /v1/plugins 必须把 e2e-echo 放在首位（应用只读这个接口）")
            self.assertEqual(catalog[0]["name"], "E2E 回声")
            self.assertFalse(catalog[0].get("installed"), "假插件默认不应标成已安装，否则目录区会被过滤掉")
            self.assertIn("fetch", ids)
        finally:
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old

    def test_v1_plugins_omits_e2e_echo_without_env(self):
        key = "OPENMINIS_E2E_FAKE_PLUGIN"
        old = os.environ.get(key)
        os.environ.pop(key, None)
        try:
            status, res = self.request("GET", "/v1/plugins")
            self.assertEqual(status, 200)
            ids = [c["id"] for c in res["catalog"]]
            self.assertNotIn("e2e-echo", ids)
            self.assertEqual(ids[0], "fetch")
        finally:
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old


if __name__ == "__main__":
    unittest.main()
