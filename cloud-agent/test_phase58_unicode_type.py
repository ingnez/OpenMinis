"""真机 bug 回归（2.44.0）：手机键盘在云电脑接管里打中文报
「Desktop unicode type error: Command ['xclip', '-selection', 'clipboard'] timed out after 5 seconds」。
原因：xclip fork 出常驻进程持有剪贴板，它继承了 PIPE 的 stdout/stderr，communicate() 一直等 EOF 到超时。

这里起一个真的 Xvfb + 真的 xclip：中文输入要很快完成、剪贴板读回一致、手机⇄云电脑剪贴板往返、
没有剪贴板工具时自动退回逐字输入。没有 Xvfb / xclip 时跳过；CI 云电脑任务里设 OPENMINIS_REAL_X_TEST=1，缺工具直接算失败。
文字都是假数据。
"""
import os
import shutil
import signal
import subprocess
import time
import unittest
from unittest import mock

import cloud_desktop

REQUIRED = os.environ.get("OPENMINIS_REAL_X_TEST") == "1"
HAVE = all(shutil.which(t) for t in ("Xvfb", "xclip", "xdotool"))
TEXT = "你好，云电脑：测试中文输入 ✓ emoji🙂"


@unittest.skipUnless(HAVE or REQUIRED, "需要 Xvfb + xclip + xdotool（CI 云电脑任务里必跑）")
class UnicodeTypeRealX(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not HAVE:
            raise AssertionError("OPENMINIS_REAL_X_TEST=1 但缺 Xvfb / xclip / xdotool")
        cls.display = ":%d" % (70 + os.getpid() % 20)
        cls.xvfb = subprocess.Popen(["Xvfb", cls.display, "-screen", "0", "800x600x24", "-nolisten", "tcp"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.env = os.environ.copy()
        cls.env["DISPLAY"] = cls.display
        cls.env.pop("XAUTHORITY", None)
        for _ in range(50):
            if subprocess.run(["xdotool", "getmouselocation"], env=cls.env, capture_output=True).returncode == 0:
                break
            time.sleep(0.1)
        else:
            raise AssertionError("Xvfb 没起来")

    @classmethod
    def tearDownClass(cls):
        cls.xvfb.terminate()
        cls.xvfb.wait(timeout=5)
        subprocess.run(["pkill", "-f", "xclip -selection clipboard -i"], capture_output=True)
        subprocess.run(["pkill", "-f", "xsel --clipboard --input"], capture_output=True)

    def _type(self, text):
        t0 = time.time()
        with mock.patch.dict(os.environ, {"DISPLAY": self.display}):
            os.environ.pop("XAUTHORITY", None)
            res = cloud_desktop.execute_desktop_action("t", "/tmp/om-unicode-test", {"action": "type", "text": text},
                                                       display_override=self.display)
        return res, time.time() - t0

    def test_01_old_pipe_pattern_hangs(self):
        """先证明根因：旧写法（stdout/stderr 用 PIPE + communicate）会等到超时"""
        p = subprocess.Popen(["xclip", "-selection", "clipboard"], env=self.env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        with self.assertRaises(subprocess.TimeoutExpired):
            p.communicate(input="旧写法".encode(), timeout=1.5)
        # 前台 xclip 早就退出了，管道是被 fork 出的常驻子进程占着：只杀 p 不够，要杀整个进程组
        self.assertIsNotNone(p.poll(), "前台 xclip 应该已经退出（是子进程占着管道）")
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate(timeout=5)

    def test_02_unicode_type_fast_and_clipboard_matches(self):
        res, dt = self._type(TEXT)
        self.assertEqual(res.get("status"), "ok", res)
        self.assertEqual(res.get("method"), "clipboard", res)
        self.assertLess(dt, 3.0, "中文输入应在 3 秒内完成（之前卡 5 秒后报错）")
        self.assertEqual(cloud_desktop._clip_read(self.env), TEXT)

    def test_03_repeated_typing_no_stale_paste(self):
        """连续几次：每次剪贴板都是这一次的文字（等新的常驻进程真正拿到选区再粘贴）"""
        for i in range(4):
            t = f"第{i}次输入"
            res, dt = self._type(t)
            self.assertEqual(res.get("status"), "ok", res)
            self.assertLess(dt, 3.0)
            self.assertEqual(cloud_desktop._clip_read(self.env), t)

    def test_04_phone_clipboard_roundtrip(self):
        t0 = time.time()
        self.assertIsNone(cloud_desktop.write_clipboard(self.display, "手机剪贴板→云电脑"))
        self.assertLess(time.time() - t0, 3.0)
        self.assertEqual(cloud_desktop.read_clipboard(self.display), ("手机剪贴板→云电脑", None))

    def test_05_fallback_when_no_clipboard_tool(self):
        real = shutil.which
        with mock.patch.object(cloud_desktop.shutil, "which", lambda n: None if n in ("xclip", "xsel") else real(n)):
            res, dt = self._type("没有剪贴板工具")
        self.assertEqual(res.get("status"), "ok", res)
        self.assertEqual(res.get("method"), "xdotool_type")
        self.assertIn("逐字", res.get("fallback", ""))

    def test_06_xsel_used_when_xclip_missing(self):
        if not shutil.which("xsel"):
            self.skipTest("没有 xsel")
        real = shutil.which
        with mock.patch.object(cloud_desktop.shutil, "which", lambda n: None if n == "xclip" else real(n)):
            res, dt = self._type("改用 xsel")
        self.assertEqual(res.get("via"), "xsel", res)
        self.assertLess(dt, 3.0)


class UnicodeTypeFriendlyError(unittest.TestCase):
    def test_all_paths_fail_gives_chinese_error(self):
        """全都失败时给中文说明，不带内部命令名"""
        def fake_run(*a, **k):
            return subprocess.CompletedProcess(a[0], 1)
        with mock.patch.object(cloud_desktop.shutil, "which", lambda n: "/usr/bin/" + n if n == "xdotool" else None), \
             mock.patch.object(cloud_desktop.subprocess, "run", fake_run):
            res = cloud_desktop.type_unicode({}, "中文")
        self.assertIn("没能把文字输入到云电脑", res["error"])
        self.assertNotIn("xclip", res["error"])
        self.assertTrue(res.get("friendly"))

    def test_server_version(self):
        import cloud_agent_server
        self.assertGreaterEqual(tuple(map(int, cloud_agent_server.AGENT_VERSION.split("."))), (2, 45, 0))


if __name__ == "__main__":
    unittest.main()
