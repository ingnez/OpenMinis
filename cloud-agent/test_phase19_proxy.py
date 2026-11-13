#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 19：云电脑代理（分享链接 / 订阅解析、sing-box 配置、加密保存、接口不泄露密钥、安装校验、真连测速）。

真 sing-box 的用例需要可执行文件：OPENMINIS_SINGBOX 指向它，或 PATH 里有 sing-box；没有时跳过。
"""

import base64
import hashlib
import io
import json
import os
import shutil
import socket
import subprocess
import tarfile
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cloud_proxy as cp
import cloud_secrets
from test_phase1_support import CloudServerTestCase

UUID = "a3482e88-686a-4a58-8126-99c9df64b7bf"
PBK = "Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw"
REALITY = (f"vless://{UUID}@hk.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality"
           f"&sni=www.microsoft.com&fp=chrome&pbk={PBK}&sid=6ba85179e30d4fc2&spx=%2Fsearch&type=tcp&headerType=none"
           "#%E9%A6%99%E6%B8%AF%20REALITY")


def singbox():
    p = os.environ.get("OPENMINIS_SINGBOX")
    return p if p and os.path.exists(p) else shutil.which("sing-box")


class ParseTests(unittest.TestCase):
    def test_shadowrocket_vless_reality(self):
        # 全是假的：uuid / 公钥 / short id / 地址都是测试用值
        fake_uuid = "00000000-1111-2222-3333-444444444444"
        info = base64.urlsafe_b64encode(f":{fake_uuid}@203.0.113.7:57635".encode()).decode().rstrip("=")
        link = (f"vless://{info}?remarks=%E6%B5%8B%E8%AF%95%E8%8A%82%E7%82%B9&tls=1&peer=www.example.com&udp=1&xtls=2"
                "&pbk=FAKEpublicKeyForTestsOnly0000000000000000000&sid=abcd12&fingerprint=chrome")
        n = cp.parse_link(link)
        ob = n["outbound"]
        self.assertEqual((n["name"], n["server"], n["port"]), ("测试节点", "203.0.113.7", 57635))
        self.assertEqual((ob["uuid"], ob["flow"]), (fake_uuid, "xtls-rprx-vision"))
        self.assertEqual(ob["tls"]["server_name"], "www.example.com")
        self.assertEqual(ob["tls"]["reality"], {"enabled": True, "public_key": "FAKEpublicKeyForTestsOnly0000000000000000000", "short_id": "abcd12"})
        self.assertEqual(ob["tls"]["utls"]["fingerprint"], "chrome")
        # method 写成 auto、走 websocket
        info2 = base64.urlsafe_b64encode(f"auto:{fake_uuid}@203.0.113.8:443".encode()).decode().rstrip("=")
        n2 = cp.parse_link(f"vless://{info2}?remarks=ws&tls=1&peer=a.example.com&obfs=websocket&path=/ray&obfsParam=a.example.com")
        self.assertEqual(n2["outbound"]["transport"], {"type": "ws", "path": "/ray", "headers": {"Host": "a.example.com"}})
        self.assertEqual(n2["outbound"]["tls"]["server_name"], "a.example.com")
        self.assertNotIn("reality", n2["outbound"]["tls"])
        info3 = base64.urlsafe_b64encode(f":{fake_uuid}@203.0.113.9:443".encode()).decode().rstrip("=")
        with self.assertRaises(cp.ProxyError) as e:
            cp.parse_link(f"vless://{info3}?tls=1&xtls=1")
        self.assertIn("xtls-rprx-direct", str(e.exception))

    def test_shadowrocket_vmess_trojan(self):
        fake = "99999999-8888-7777-6666-555555555555"
        info = base64.urlsafe_b64encode(f"auto:{fake}@198.51.100.2:8443".encode()).decode().rstrip("=")
        n = cp.parse_link(f"vmess://{info}?remarks=vm&obfs=websocket&path=/v&obfsParam=cdn.example.com&tls=1&peer=cdn.example.com&alterId=0")
        ob = n["outbound"]
        self.assertEqual((n["name"], ob["uuid"], ob["security"]), ("vm", fake, "auto"))
        self.assertEqual(ob["transport"]["type"], "ws")
        self.assertEqual(ob["tls"]["server_name"], "cdn.example.com")
        info_t = base64.urlsafe_b64encode(b"none:fake-password@198.51.100.3:443").decode().rstrip("=")
        t = cp.parse_link(f"trojan://{info_t}?remarks=tj&peer=t.example.com")
        self.assertEqual((t["name"], t["outbound"]["password"], t["outbound"]["tls"]["server_name"]), ("tj", "fake-password", "t.example.com"))
        # 标准 vmess 写法不受影响
        self.assertEqual(cp.parse_link(cp._shadowrocket(f"vmess://{info}?remarks=x"))["outbound"]["uuid"], fake)

    def test_vless_reality_params(self):
        n = cp.parse_link(REALITY)
        o = n["outbound"]
        self.assertEqual((n["name"], n["type"], n["server"], n["port"]), ("香港 REALITY", "vless", "hk.example.com", 443))
        self.assertEqual(o["uuid"], UUID)
        self.assertEqual(o["flow"], "xtls-rprx-vision")
        self.assertEqual(o["tls"]["server_name"], "www.microsoft.com")
        self.assertEqual(o["tls"]["utls"], {"enabled": True, "fingerprint": "chrome"})
        self.assertEqual(o["tls"]["reality"], {"enabled": True, "public_key": PBK, "short_id": "6ba85179e30d4fc2"})
        self.assertNotIn("transport", o)
        self.assertEqual(n["extra"], {"spx": "/search"})   # sing-box 不用 spiderX，如实保留

    def test_vless_reality_defaults_and_errors(self):
        n = cp.parse_link(f"vless://{UUID}@1.2.3.4:8443?security=reality&sni=a.com&pbk={PBK}#r")
        self.assertEqual(n["outbound"]["tls"]["utls"]["fingerprint"], "chrome")   # REALITY 必须有 uTLS
        self.assertEqual(n["outbound"]["tls"]["reality"]["short_id"], "")
        with self.assertRaisesRegex(cp.ProxyError, "pbk"):
            cp.parse_link(f"vless://{UUID}@1.2.3.4:443?security=reality&sni=a.com")
        with self.assertRaisesRegex(cp.ProxyError, "xhttp"):
            cp.parse_link(f"vless://{UUID}@1.2.3.4:443?security=tls&type=xhttp")
        with self.assertRaisesRegex(cp.ProxyError, "flow"):
            cp.parse_link(f"vless://{UUID}@1.2.3.4:443?security=tls&flow=xtls-rprx-direct")

    def test_vless_ws_grpc_ipv6(self):
        ws = cp.parse_link(f"vless://{UUID}@[2001:db8::1]:443?security=tls&sni=a.com&type=ws&host=a.com&path=%2Fws%3Fed%3D2048#ws")
        self.assertEqual(ws["server"], "2001:db8::1")
        self.assertEqual(ws["outbound"]["transport"], {"type": "ws", "path": "/ws?ed=2048", "headers": {"Host": "a.com"}})
        g = cp.parse_link(f"vless://{UUID}@a.com:443?security=tls&type=grpc&serviceName=svc#g")
        self.assertEqual(g["outbound"]["transport"], {"type": "grpc", "service_name": "svc"})

    def test_vmess(self):
        j = {"v": "2", "ps": "日本", "add": "jp.example.com", "port": "443", "id": UUID, "aid": "0", "scy": "auto",
             "net": "ws", "host": "jp.example.com", "path": "/v", "tls": "tls", "sni": "jp.example.com"}
        n = cp.parse_link("vmess://" + base64.b64encode(json.dumps(j).encode()).decode())
        self.assertEqual((n["name"], n["type"], n["port"]), ("日本", "vmess", 443))
        self.assertEqual(n["outbound"]["transport"]["path"], "/v")
        self.assertTrue(n["outbound"]["tls"]["enabled"])

    def test_trojan_ss_hy2(self):
        t = cp.parse_link("trojan://p%40ss@t.example.com:443?sni=t.example.com&allowInsecure=1#tj")
        self.assertEqual(t["outbound"]["password"], "p@ss")
        self.assertTrue(t["outbound"]["tls"]["insecure"])
        sip = base64.urlsafe_b64encode(b"2022-blake3-aes-128-gcm:a2V5a2V5a2V5a2V5a2V5aw==").decode().rstrip("=")
        s1 = cp.parse_link(f"ss://{sip}@s.example.com:8388#ss1")
        self.assertEqual((s1["outbound"]["method"], s1["port"]), ("2022-blake3-aes-128-gcm", 8388))
        legacy = base64.b64encode(b"aes-256-gcm:pw@1.2.3.4:8389").decode()
        s2 = cp.parse_link(f"ss://{legacy}#old")
        self.assertEqual((s2["server"], s2["outbound"]["password"]), ("1.2.3.4", "pw"))
        with self.assertRaisesRegex(cp.ProxyError, "plugin"):
            cp.parse_link(f"ss://{sip}@s.example.com:8388?plugin=obfs-local#p")
        h = cp.parse_link("hy2://secret@h.example.com:8443/?sni=h.example.com&obfs=salamander&obfs-password=ob&insecure=1#hy")
        self.assertEqual(h["outbound"]["password"], "secret")
        self.assertEqual(h["outbound"]["obfs"], {"type": "salamander", "password": "ob"})

    def test_subscription_base64_and_plain(self):
        body = base64.b64encode("\n".join([REALITY, "vless://bad", "trojan://pw@t.example.com:443#t"]).encode()).decode()
        nodes, skipped, why = cp.parse_subscription(body)
        self.assertEqual([n["type"] for n in nodes], ["vless", "trojan"])
        self.assertEqual(skipped, 1)
        self.assertTrue(why)
        with self.assertRaises(cp.ProxyError):
            cp.parse_subscription("proxies:\n  - name: x\n")
        with self.assertRaises(cp.ProxyError):
            cp.parse_link("socks5://1.2.3.4:1080")

    def test_config_rules_and_global(self):
        n = cp.parse_link(REALITY)
        rules = cp.build_config(n, "rules", 17000, ["example.org"])
        self.assertEqual(rules["inbounds"][0], {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 17000})
        self.assertEqual(rules["route"]["final"], "direct")
        doms = rules["route"]["rules"][-1]["domain_suffix"]
        for d in ("github.com", "githubusercontent.com", "ghcr.io", "pypi.org", "npmjs.org", "example.org"):
            self.assertIn(d, doms)
        self.assertEqual(cp.build_config(n, "global")["route"]["final"], "proxy")
        with self.assertRaises(cp.ProxyError):
            cp.build_config(n, "off")
        env = cp.proxy_env(17000)
        self.assertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:17000")
        self.assertEqual(env["ALL_PROXY"], "socks5h://127.0.0.1:17000")
        self.assertEqual((env["GIT_CONFIG_KEY_0"], env["GIT_CONFIG_VALUE_0"]), ("http.proxy", "http://127.0.0.1:17000"))

    @unittest.skipUnless(singbox(), "没有 sing-box 可执行文件")
    def test_configs_pass_singbox_check(self):
        links = [REALITY, "trojan://pw@t.example.com:443?type=ws&path=%2Ft#t",
                 "hy2://a@h.example.com:443?obfs=salamander&obfs-password=x#h",
                 "ss://" + base64.urlsafe_b64encode(b"aes-128-gcm:pw").decode() + "@s.example.com:1#s"]
        nodes = [cp.parse_link(l) for l in links]
        cfgs = [cp.build_config(n, m) for n in nodes for m in ("rules", "global")] + [cp.build_test_config(nodes, 30000)]
        with tempfile.TemporaryDirectory() as td:
            for cfg in cfgs:
                p = os.path.join(td, "c.json")
                with open(p, "w") as f:
                    json.dump(cfg, f)
                r = subprocess.run([singbox(), "check", "-c", p], capture_output=True, text=True, timeout=30)
                self.assertEqual(r.returncode, 0, r.stderr)


class InstallTests(unittest.TestCase):
    def _tarball(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tf:
            data = b"#!/bin/sh\necho 'sing-box version test'\n"
            info = tarfile.TarInfo("sing-box-x-linux-amd64/sing-box")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
            evil = tarfile.TarInfo("../../etc/evil")
            evil.size = 1
            tf.addfile(evil, io.BytesIO(b"x"))
        return buf.getvalue()

    def test_checksum_and_mirror_fallback(self):
        good = self._tarball()
        tried = []

        def fetch(url):
            tried.append(url)
            if url.startswith("https://github.com"):
                raise TimeoutError("slow")
            if url.startswith("https://ghfast.top/"):
                return b"tampered"
            return good
        old = dict(cp.SINGBOX_SHA256)
        cp.SINGBOX_SHA256[cp.arch()] = hashlib.sha256(good).hexdigest()
        try:
            with tempfile.TemporaryDirectory() as td:
                path = cp.install_singbox(os.path.join(td, "bin"), fetch=fetch)
                self.assertTrue(os.access(path, os.X_OK))
                self.assertEqual(sorted(os.listdir(os.path.join(td, "bin"))), ["sing-box"])
                self.assertEqual(len(tried), 3)   # github 超时 → 镜像 1 校验不一致 → 镜像 2
                with self.assertRaisesRegex(cp.ProxyError, "校验不一致"):
                    cp.install_singbox(os.path.join(td, "b2"), fetch=lambda u: b"tampered")
        finally:
            cp.SINGBOX_SHA256.clear()
            cp.SINGBOX_SHA256.update(old)

    def test_pinned_release(self):
        self.assertEqual(set(cp.SINGBOX_SHA256), {"amd64", "arm64"})
        self.assertTrue(cp.release_url("amd64").startswith("https://github.com/SagerNet/sing-box/releases/download/v"))


class ProxyApiTests(CloudServerTestCase):
    def setUp(self):
        self.mgr = self.srv.proxy_mgr()
        self._old_bin = os.environ.pop("OPENMINIS_SINGBOX", None)
        self.mgr.update({"mode": "off"}) if self.mgr.state()["nodes"] else None

    def tearDown(self):
        if self._old_bin:
            os.environ["OPENMINIS_SINGBOX"] = self._old_bin
        self.mgr.shutdown()
        for n in list(self.mgr.state()["nodes"]):
            self.mgr.delete(node_id=n["id"])

    def test_01_import_masks_and_encrypts(self):
        status, body = self.request("POST", "/v1/proxy/import", {"text": REALITY})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["added"][0]["security"], "REALITY")
        self.assertEqual(body["added"][0]["flow"], "xtls-rprx-vision")
        status, st = self.request("GET", "/v1/proxy")
        self.assertEqual(status, 200)
        dump = json.dumps(st)
        for secret in (UUID, PBK, "6ba85179e30d4fc2"):
            self.assertNotIn(secret, dump)
        with open(self.mgr.state_path, "rb") as f:
            raw = f.read()
        self.assertNotIn(UUID.encode(), raw)
        self.assertEqual(os.stat(self.mgr.state_path).st_mode & 0o777, 0o600)
        # 重新加载（新进程）还能解密
        fresh = cp.ProxyManager(self.mgr.dir, cloud_secrets.get_box)
        self.assertEqual(fresh.state()["nodes"][0]["outbound"]["uuid"], UUID)
        # 重复导入不重复保存
        self.assertEqual(self.request("POST", "/v1/proxy/import", {"text": REALITY})[1]["added"], [])

    def test_02_mode_without_binary_is_honest(self):
        self.request("POST", "/v1/proxy/import", {"text": REALITY})
        self.mgr.binary = lambda: None
        try:
            status, st = self.request("PUT", "/v1/proxy", {"mode": "rules"})
            self.assertEqual(status, 200)
            self.assertFalse(st["running"])
            self.assertIn("sing-box", st["error"])
            self.assertEqual(self.srv.proxy_env(), {})           # 代理没跑：不给终端设一个连不上的代理
            task_env = self.srv.task_env("nope")
            for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
                # A stopped sing-box must leave any host proxy unchanged. Avoid
                # including the complete task environment in assertion output.
                self.assertTrue(task_env.get(key) == os.environ.get(key),
                                f"{key} should retain its inherited value when sing-box is unavailable")
        finally:
            del self.mgr.binary
        self.assertEqual(self.request("PUT", "/v1/proxy", {"mode": "nope"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/proxy", {"selected": "000000"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/proxy", {"extra_domains": ["not a domain"]})[0], 400)
        self.assertEqual(self.request("POST", "/v1/proxy/import", {"text": "hello"})[0], 400)

    def test_03_delete_node(self):
        nid = self.request("POST", "/v1/proxy/import", {"text": REALITY})[1]["added"][0]["id"]
        status, st = self.request("DELETE", f"/v1/proxy/nodes/{nid}")
        self.assertEqual(status, 200)
        self.assertEqual(st["nodes"], [])
        self.assertIsNone(st["selected"])

    def test_04_subscription(self):
        body = base64.b64encode("\n".join([REALITY, "trojan://pw@t.example.com:443#t"]).encode()).decode()
        res = self.mgr.add_subscription("https://sub.example.com/api?token=SUBTOKEN123", fetch_sub=lambda u: body)
        self.assertEqual(len(res["added"]), 2)
        st = self.request("GET", "/v1/proxy")[1]
        self.assertEqual(st["subscriptions"][0]["host"], "sub.example.com")
        self.assertNotIn("SUBTOKEN123", json.dumps(st))
        self.assertEqual(self.request("DELETE", f"/v1/proxy/subscriptions/{res['subscription']}")[1]["nodes"], [])

    def test_05_install_runs_in_background(self):
        orig = cp.install_singbox

        def failing(*a, **k):
            raise cp.ProxyError("下载 sing-box 失败：github.com：TimeoutError")
        cp.install_singbox = failing
        try:
            status, st = self.request("POST", "/v1/proxy/install", {})
            self.assertEqual(status, 202)
            done = self.wait_until(lambda: (not self.mgr.installing) and self.mgr.install_error)
            self.assertIn("TimeoutError", done)
            self.assertIn("TimeoutError", self.request("GET", "/v1/proxy")[1]["install_error"])
        finally:
            cp.install_singbox = orig


class _Hello(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


@unittest.skipUnless(singbox(), "没有 sing-box 可执行文件")
class RealSingBoxTests(unittest.TestCase):
    """本机起一个 shadowsocks 服务端（同一个 sing-box），经节点真连一个本地 HTTP 服务，验证测速和运行。"""

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.web = ThreadingHTTPServer(("127.0.0.1", 0), _Hello)
        threading.Thread(target=self.web.serve_forever, daemon=True).start()
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.ss_port = s.getsockname()[1]
        cfg = {"log": {"level": "error"},
               "inbounds": [{"type": "shadowsocks", "listen": "127.0.0.1", "listen_port": self.ss_port,
                             "method": "aes-128-gcm", "password": "testpw"}],
               "outbounds": [{"type": "direct"}]}
        p = os.path.join(self.td.name, "server.json")
        with open(p, "w") as f:
            json.dump(cfg, f)
        self.server = subprocess.Popen([singbox(), "run", "-c", p], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertTrue(cp._wait_port(self.ss_port, 5))
        os.environ["OPENMINIS_MASTER_KEY"] = base64.b64encode(b"k" * 32).decode()
        cloud_secrets.reset()

    def tearDown(self):
        self.server.terminate()
        self.server.wait(5)
        self.web.shutdown()
        os.environ.pop("OPENMINIS_MASTER_KEY", None)
        cloud_secrets.reset()
        self.td.cleanup()

    def test_url_latency_and_run(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        m = cp.ProxyManager(os.path.join(self.td.name, "state"), cloud_secrets.get_box, port=port)
        link = "ss://" + base64.urlsafe_b64encode(b"aes-128-gcm:testpw").decode() + f"@127.0.0.1:{self.ss_port}#local"
        bad = "ss://" + base64.urlsafe_b64encode(b"aes-128-gcm:testpw").decode() + "@127.0.0.1:1#dead"
        m.import_text(link + "\n" + bad)
        res = {r["id"]: r for r in m.test(url=f"http://127.0.0.1:{self.web.server_address[1]}/", timeout=4)}
        good_id, dead_id = [n["id"] for n in m.state()["nodes"]]
        self.assertEqual(res[good_id]["method"], "url")
        self.assertIsInstance(res[good_id].get("ms"), int, res)
        self.assertIn("error", res[dead_id])
        try:
            st = m.update({"mode": "global", "selected": good_id})
            self.assertTrue(st["running"], st)
            self.assertEqual(m.env()["HTTPS_PROXY"], f"http://127.0.0.1:{port}")
            self.assertEqual(oct(os.stat(os.path.join(m.run_dir, "config.json")).st_mode & 0o777), "0o600")
            m.proc.kill()
            m.proc.wait(5)
            self.assertEqual(m.env(), {})          # 意外退出：立即不再给终端设代理
            m.watch(interval=0.2)
            self.assertTrue(cp._wait_port(port, 8))
            self.assertGreaterEqual(m.restarts, 1)
        finally:
            m.shutdown()
        self.assertFalse(os.path.exists(os.path.join(m.run_dir, "config.json")))


if __name__ == "__main__":
    unittest.main()
