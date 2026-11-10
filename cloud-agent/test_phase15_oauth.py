#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 15：远程 MCP 插件 OAuth 登录（发现 → 动态注册 → PKCE → 换令牌 → 过期自动刷新），令牌不外泄。"""

import base64
import hashlib
import json
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler

from test_phase1_support import CloudServerTestCase, _serve
from test_phase3_plugins import FakeHttpMCP


class FakeOAuth(FakeHttpMCP):
    required_auth = "Bearer tok2"   # 只认刷新后的令牌：证明过期令牌会先刷新
    base = ""
    challenge = {}
    seen = []

    def _json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        b = FakeOAuth.base
        if self.path == "/.well-known/oauth-protected-resource/mcp":
            return self._json({"resource": b + "/mcp", "authorization_servers": [b], "scopes_supported": ["read"]})
        if self.path == "/.well-known/oauth-authorization-server":
            return self._json({"issuer": b, "authorization_endpoint": b + "/authorize", "token_endpoint": b + "/token",
                               "registration_endpoint": b + "/register"})
        self._json({}, 404)

    def do_POST(self):
        if self.path == "/mcp":
            return FakeHttpMCP.do_POST(self)
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.path == "/register":
            body = json.loads(raw)
            FakeOAuth.seen.append(("register", body["redirect_uris"]))
            return self._json({"client_id": "cid-1"}, 201)
        form = dict(urllib.parse.parse_qsl(raw))
        FakeOAuth.seen.append(("token", form["grant_type"]))
        if form["grant_type"] == "authorization_code":
            want = FakeOAuth.challenge.get("v")
            got = base64.urlsafe_b64encode(hashlib.sha256(form["code_verifier"].encode()).digest()).rstrip(b"=").decode()
            if form["code"] != "c1" or got != want or form["client_id"] != "cid-1":
                return self._json({"error": "invalid_grant"}, 400)
            return self._json({"access_token": "tok1", "refresh_token": "r1", "expires_in": 1, "token_type": "Bearer"})
        if form["grant_type"] == "refresh_token" and form["refresh_token"] == "r1":
            return self._json({"access_token": "tok2", "expires_in": 3600, "token_type": "Bearer"})
        self._json({"error": "invalid_grant"}, 400)


class OAuthTests(CloudServerTestCase):
    def test_01_full_flow(self):
        server, port = _serve(FakeOAuth)
        FakeOAuth.base = f"http://127.0.0.1:{port}"
        try:
            m = {"id": "oauthy", "kind": "mcp", "name": "OAuthy", "mcp": {"transport": "http", "url": FakeOAuth.base + "/mcp"}}
            self.request("POST", "/v1/plugins/install", {"manifest": m})
            p = self.request("GET", "/v1/plugins/oauthy")[1]
            self.assertEqual(p["oauth"], {"available": True, "connected": False, "connected_at": None})
            self.assertEqual(self.request("POST", "/v1/plugins/oauthy/oauth/start", {"redirect_uri": "javascript:alert(1)"})[0], 400)

            st, r = self.request("POST", "/v1/plugins/oauthy/oauth/start", {"redirect_uri": "openminis://oauth"})
            self.assertEqual(st, 200, r)
            q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(r["authorize_url"]).query))
            self.assertEqual((q["client_id"], q["code_challenge_method"], q["redirect_uri"], q["scope"]), ("cid-1", "S256", "openminis://oauth", "read"))
            self.assertEqual(q["resource"], FakeOAuth.base + "/mcp")
            FakeOAuth.challenge["v"] = q["code_challenge"]

            self.assertEqual(self.request("POST", "/v1/plugins/oauthy/oauth/finish", {"code": "c1", "state": "nope"})[0], 400)
            st, r = self.request("POST", "/v1/plugins/oauthy/oauth/finish", {"code": "c1", "state": q["state"]})
            self.assertEqual(st, 200, r)
            self.assertTrue(r["plugin"]["oauth"]["connected"])
            self.assertEqual(r["plugin"]["status"], "ready")
            # 同一个 state 不能用第二次
            self.assertEqual(self.request("POST", "/v1/plugins/oauthy/oauth/finish", {"code": "c1", "state": q["state"]})[0], 400)

            st, r = self.request("GET", "/v1/plugins/oauthy/tools")
            self.assertEqual(st, 200, r)
            self.assertEqual([t["name"] for t in r["tools"]], ["search"])
            self.assertIn(("token", "refresh_token"), FakeOAuth.seen)

            dump = json.dumps(self.request("GET", "/v1/plugins")[1])
            for secret in ("tok1", "tok2", "r1"):
                self.assertNotIn(secret, dump)

            # 第二次连接复用已注册的客户端
            n = sum(1 for s in FakeOAuth.seen if s[0] == "register")
            self.request("POST", "/v1/plugins/oauthy/oauth/start", {"redirect_uri": "openminis://oauth"})
            self.assertEqual(sum(1 for s in FakeOAuth.seen if s[0] == "register"), n)

            r = self.request("POST", "/v1/plugins/oauthy/oauth/disconnect", {})[1]
            self.assertFalse(r["plugin"]["oauth"]["connected"])
            self.request("DELETE", "/v1/plugins/oauthy")
        finally:
            server.shutdown()

    def test_02_stdio_plugin_has_no_oauth(self):
        import sys, os
        here = os.path.dirname(os.path.abspath(__file__))
        m = {"id": "local1", "kind": "mcp", "name": "L", "mcp": {"transport": "stdio", "command": sys.executable, "args": [os.path.join(here, "test_fake_mcp_server.py")]}}
        self.request("POST", "/v1/plugins/install", {"manifest": m, "acknowledge_command": True})
        st, r = self.request("POST", "/v1/plugins/local1/oauth/start", {})
        self.assertEqual(st, 400)
        self.request("DELETE", "/v1/plugins/local1")


if __name__ == "__main__":
    unittest.main()
