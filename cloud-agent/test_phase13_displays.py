"""独立屏幕真机测试（需要 Xvfb / x11vnc / xauth，没有就跳过）：
Xauthority 里只有主屏 :99 的 cookie 时，独立屏幕也要能起来并让 x11vnc 监听；Agent 重启后沿用还在工作的屏幕。"""
import os
import shutil
import subprocess
import tempfile
import unittest

import cloud_displays

HAVE = all(shutil.which(b) for b in ("Xvfb", "x11vnc", "xauth"))


@unittest.skipUnless(HAVE, "需要 Xvfb / x11vnc / xauth")
class PerBotDisplayTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.auth = os.path.join(self.td.name, ".Xauthority")
        open(self.auth, "w").close()
        subprocess.run(["xauth", "-f", self.auth, "add", ":99", ".", os.urandom(16).hex()], check=True, capture_output=True)
        self.old = (cloud_displays.AUTH_FILE, cloud_displays.TOKEN_DIR)
        cloud_displays.AUTH_FILE = self.auth
        cloud_displays.TOKEN_DIR = os.path.join(self.td.name, "tokens")
        os.makedirs(cloud_displays.TOKEN_DIR)
        self.mgr = cloud_displays.DisplayManager(lambda: {"resolution": "800x600"}, lambda k: 47)

    def tearDown(self):
        self.mgr.stop_all()
        cloud_displays.clear_stale_display(57)
        cloud_displays.AUTH_FILE, cloud_displays.TOKEN_DIR = self.old
        self.td.cleanup()

    def test_display_starts_and_vnc_listens(self):
        info = self.mgr.ensure("bot-a")
        self.assertIsNotNone(info, self.mgr.last_error)
        self.assertEqual((info["display"], info["vnc_port"]), (":57", 5957))
        self.assertTrue(cloud_displays.port_open(5957, banner=b"RFB "))
        listed = subprocess.run(["xauth", "-f", self.auth, "list", ":57"], capture_output=True, text=True).stdout
        self.assertTrue(listed.strip(), "应为 :57 补上 cookie")
        with open(os.path.join(cloud_displays.TOKEN_DIR, info["token"])) as f:
            self.assertEqual(f.read().strip(), f"{info['token']}: 127.0.0.1:5957")
        # 模拟 Agent 重启：新的管理器沿用还在工作的屏幕
        mgr2 = cloud_displays.DisplayManager(lambda: {"resolution": "800x600"}, lambda k: 47)
        again = mgr2.ensure("bot-a")
        self.assertIsNotNone(again)
        self.assertTrue(cloud_displays.port_open(5957, banner=b"RFB "))
        h = cloud_displays.diagnose(":57", 5957, info["token"], 1, mode="token", probe=False)
        self.assertTrue(h["xvfb"] and h["vnc"], h)


if __name__ == "__main__":
    unittest.main()
