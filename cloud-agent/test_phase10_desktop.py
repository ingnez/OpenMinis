"""桌面链路诊断：websockify 模式识别、VNC 握手探测、token 条目自动修复。"""
import os
import socket
import tempfile
import threading
import unittest

import cloud_displays
from test_phase1_support import CloudServerTestCase


def _fake_proc(root, pid, args):
    d = os.path.join(root, str(pid))
    os.makedirs(d)
    with open(os.path.join(d, "cmdline"), "wb") as f:
        f.write(b"\0".join(a.encode() for a in args) + b"\0")


class DesktopDiagnoseTests(unittest.TestCase):
    def test_websockify_mode(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertIsNone(cloud_displays.websockify_mode(root))
            _fake_proc(root, 10, ["/usr/bin/python3", "/usr/bin/websockify", "--web=/usr/share/novnc", "127.0.0.1:18766", "127.0.0.1:5901"])
            self.assertEqual(cloud_displays.websockify_mode(root), "fixed")
        with tempfile.TemporaryDirectory() as root:
            _fake_proc(root, 11, ["/usr/bin/websockify", "--web=/x", "127.0.0.1:18766", "--token-plugin", "TokenFile", "--token-source", "/t"])
            self.assertEqual(cloud_displays.websockify_mode(root), "token")

    def _rfb_server(self, banner=b"RFB 003.008\n"):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(4)
        def loop():
            while True:
                try:
                    c, _ = s.accept()
                except OSError:
                    return
                c.sendall(banner)
                c.close()
        threading.Thread(target=loop, daemon=True).start()
        return s, s.getsockname()[1]

    def _ws_server(self, vnc_port, token="main"):
        """最小 websockify：校验 token 路径，握手后把 VNC 的第一段数据包成二进制帧发回；token 不对返回 404。"""
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(4)
        def handle(c):
            try:
                req = b""
                while b"\r\n\r\n" not in req:
                    req += c.recv(4096)
                line = req.split(b"\r\n", 1)[0].decode()
                if token and f"token={token}" not in line:
                    c.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                    return
                c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: binary\r\n\r\n")
                v = socket.create_connection(("127.0.0.1", vnc_port), timeout=2)
                data = v.recv(64)
                v.close()
                c.sendall(bytes([0x82, len(data)]) + data)
            except OSError:
                pass
            finally:
                c.close()
        def loop():
            while True:
                try:
                    c, _ = s.accept()
                except OSError:
                    return
                threading.Thread(target=handle, args=(c,), daemon=True).start()
        threading.Thread(target=loop, daemon=True).start()
        return s, s.getsockname()[1]

    def test_ws_probe(self):
        vnc, vport = self._rfb_server()
        web, wport = self._ws_server(vport)
        plain, pport = self._rfb_server(b"HTTP/1.1 200 OK\r\n\r\n")
        try:
            self.assertEqual(cloud_displays.ws_probe(wport, "main"), (True, ""))
            ok, why = cloud_displays.ws_probe(wport, "bot-x")
            self.assertFalse(ok)
            self.assertIn("token", why)
            self.assertFalse(cloud_displays.ws_probe(pport, "main")[0])     # 不是 websocket 服务
            closed = socket.socket(); closed.bind(("127.0.0.1", 0)); cport = closed.getsockname()[1]; closed.close()
            self.assertEqual(cloud_displays.ws_probe(cport)[1], "websockify 端口连不上")
        finally:
            vnc.close(); web.close(); plain.close()

    def test_diagnose_chain(self):
        vnc, vport = self._rfb_server()
        web, wport = self._ws_server(vport)
        old_dir = cloud_displays.TOKEN_DIR
        orig_alive = cloud_displays.display_alive
        try:
            with tempfile.TemporaryDirectory() as td:
                cloud_displays.TOKEN_DIR = td
                cloud_displays.display_alive = lambda d: True
                h = cloud_displays.diagnose(":99", vport, "main", wport, mode="token")
                self.assertTrue(h["ok"], h)
                self.assertTrue(h.get("token_repaired"))           # 缺失的 main 条目被补上
                with open(os.path.join(td, "main")) as f:
                    self.assertEqual(f.read().strip(), f"main: 127.0.0.1:{vport}")
                h = cloud_displays.diagnose(":99", vport, "bot-x", wport, mode="token")
                self.assertEqual(h["diagnosis"], "ws_failed")       # 网页能开但画面通道不通
                self.assertIn("画面通道不通", h["message"])
                h = cloud_displays.diagnose(":99", vport, "main", wport, mode="fixed")
                self.assertEqual(h["diagnosis"], "proxy_old")       # 旧版固定目标只能连 5901
                closed = socket.socket(); closed.bind(("127.0.0.1", 0)); cport = closed.getsockname()[1]; closed.close()
                h = cloud_displays.diagnose(":99", cport, "main", wport, mode="token")
                self.assertEqual(h["diagnosis"], "vnc_down")
                self.assertIn("VNC 端口不通", h["message"])
                h = cloud_displays.diagnose(":99", vport, "main", cport, mode=None)
                self.assertEqual(h["diagnosis"], "proxy_down")
                cloud_displays.display_alive = lambda d: False
                self.assertEqual(cloud_displays.diagnose(":99", vport, "main", wport)["diagnosis"], "display_down")
        finally:
            cloud_displays.TOKEN_DIR = old_dir
            cloud_displays.display_alive = orig_alive
            vnc.close()
            web.close()


class DesktopHealthEndpointTests(CloudServerTestCase):
    def test_health_endpoint(self):
        code, h = self.request("GET", "/v1/desktop/health")
        self.assertEqual(code, 200)
        for k in ("ok", "diagnosis", "message", "token", "token_proxy", "own_display", "xvfb", "vnc", "websockify"):
            self.assertIn(k, h)
        self.assertEqual(h["token"], "main")
        self.assertEqual(self.request("GET", "/v1/desktop/health?bot_id=nobody")[0], 200)


if __name__ == "__main__":
    unittest.main()
