"""云电脑剪贴板 / 手机输入法中文：真 Xvfb + 真 xclip / xdotool + 一个真的 X 程序（Tk 输入框）收字。

以前的回归只读回剪贴板，没看字是否真的到了程序里。这里每一项都看 Tk 输入框里实际收到的文字：
- 服务进程没有 LANG（systemd 默认 = C locale）时，xdotool 逐字输入中文会报「Invalid multi-byte sequence」、
  什么都不输入却返回成功 —— 根因，X 工具一律换成 UTF-8 locale；
- 手机输入法中文（剪贴板 + Ctrl+V）、退路逐字输入、手机剪贴板 → 远端 Ctrl+V、远端程序复制中文 → 手机读回；
- 排在中文后面的退格走服务器 key + repeat。
没有 Xvfb / xclip / xdotool / tkinter 时跳过；CI 云电脑任务里设 OPENMINIS_REAL_X_TEST=1，缺了直接算失败。文字都是假数据。
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import cloud_desktop

REQUIRED = os.environ.get("OPENMINIS_REAL_X_TEST") == "1"
try:
    import tkinter  # noqa: F401
    HAVE_TK = True
except Exception:
    HAVE_TK = False
HAVE = HAVE_TK and all(shutil.which(t) for t in ("Xvfb", "xclip", "xdotool"))

# Tk 输入框：每 80 ms 把内容写到 out；cmd 文件出现时执行（清空 / 把一段文字放进剪贴板，模拟在远端程序里复制）
SINK = r'''
import os, sys, tkinter as tk
out, cmd = sys.argv[1], sys.argv[2]
r = tk.Tk(); r.title("om-cc-sink"); r.geometry("700x160+0+0")
e = tk.Text(r, width=70, height=4); e.pack()
def tick():
    try: e.focus_force()
    except Exception: pass
    with open(out + ".tmp", "w", encoding="utf-8") as f: f.write(e.get("1.0", "end-1c"))
    os.replace(out + ".tmp", out)
    if os.path.exists(cmd):
        with open(cmd, encoding="utf-8") as f: t = f.read()
        os.remove(cmd)
        if t == "\x00clear": e.delete("1.0", "end")
        else: r.clipboard_clear(); r.clipboard_append(t)
    r.after(80, tick)
r.after(200, tick); r.mainloop()
'''


def service_like_env(display):
    """模拟 systemd 服务：没有 LANG，LC_ALL=C"""
    env = {k: v for k, v in os.environ.items() if not k.startswith("LC_") and k != "LANG"}
    env.update({"DISPLAY": display, "LC_ALL": "C"})
    env.pop("XAUTHORITY", None)
    return env


class Utf8EnvUnit(unittest.TestCase):
    def test_c_locale_becomes_utf8(self):
        self.assertEqual(cloud_desktop.utf8_env({"LC_ALL": "C"})["LC_ALL"], "C.UTF-8")
        self.assertEqual(cloud_desktop.utf8_env({})["LC_ALL"], "C.UTF-8")
        self.assertEqual(cloud_desktop.utf8_env({"LANG": "POSIX"})["LC_ALL"], "C.UTF-8")

    def test_existing_utf8_kept(self):
        self.assertNotIn("LC_ALL", cloud_desktop.utf8_env({"LANG": "zh_CN.UTF-8"}))
        self.assertEqual(cloud_desktop.utf8_env({"LC_ALL": "en_US.utf8"})["LC_ALL"], "en_US.utf8")

    def test_x_env_is_utf8_without_lang(self):
        with mock.patch.dict(os.environ, {"LC_ALL": "C"}, clear=False):
            os.environ.pop("LANG", None)
            self.assertEqual(cloud_desktop._x_env(":99")["LC_ALL"], "C.UTF-8")

    def test_key_repeat_is_bounded(self):
        calls = []

        def fake_run(cmd, **k):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, b"", b"")
        with mock.patch.object(cloud_desktop.shutil, "which", lambda n: "/usr/bin/" + n), \
             mock.patch.object(cloud_desktop.subprocess, "run", fake_run):
            r = cloud_desktop.execute_desktop_action("t", tempfile.mkdtemp(), {"action": "key", "key": "BackSpace", "repeat": 999})
        self.assertEqual(r.get("repeat"), 50)
        self.assertEqual(calls[-1][:4], ["xdotool", "key", "--repeat", "50"])
        self.assertEqual(calls[-1][-2:], ["--", "BackSpace"])


@unittest.skipUnless(HAVE or REQUIRED, "需要 Xvfb + xclip + xdotool + tkinter（CI 云电脑任务里必跑）")
class ClipboardUtf8RealApp(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not HAVE:
            raise AssertionError("OPENMINIS_REAL_X_TEST=1 但缺 Xvfb / xclip / xdotool / tkinter")
        cls.display = ":%d" % (40 + os.getpid() % 20)
        cls.tmp = tempfile.mkdtemp(prefix="om-cc-")
        cls.out, cls.cmd = os.path.join(cls.tmp, "out"), os.path.join(cls.tmp, "cmd")
        cls.xvfb = subprocess.Popen(["Xvfb", cls.display, "-screen", "0", "1024x600x24", "-nolisten", "tcp"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.env = service_like_env(cls.display)
        for _ in range(50):
            if subprocess.run(["xdotool", "getmouselocation"], env=cls.env, capture_output=True).returncode == 0:
                break
            time.sleep(0.1)
        else:
            raise AssertionError("Xvfb 没起来")
        sink = os.path.join(cls.tmp, "sink.py")
        with open(sink, "w", encoding="utf-8") as f:
            f.write(SINK)
        cls.app = subprocess.Popen([sys.executable, sink, cls.out, cls.cmd], env=cls.env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if os.path.exists(cls.out):
                break
            time.sleep(0.1)
        else:
            raise AssertionError("Tk 输入框没起来")
        time.sleep(0.5)

    @classmethod
    def tearDownClass(cls):
        cls.app.terminate()
        cls.app.wait(timeout=5)
        cls.xvfb.terminate()
        cls.xvfb.wait(timeout=5)
        subprocess.run(["pkill", "-f", "xclip -selection clipboard -i"], capture_output=True)
        subprocess.run(["pkill", "-f", "xsel --clipboard --input"], capture_output=True)

    def setUp(self):
        self._command("\x00clear")
        self.assertTrue(self._wait(""), "输入框没清空")
        # 服务进程的环境：没有 LANG
        self._env = mock.patch.dict(os.environ, {"DISPLAY": self.display, "LC_ALL": "C"})
        self._env.start()
        os.environ.pop("LANG", None)
        os.environ.pop("XAUTHORITY", None)

    def tearDown(self):
        self._env.stop()

    def _command(self, text):
        with open(self.cmd + ".tmp", "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(self.cmd + ".tmp", self.cmd)
        for _ in range(50):
            if not os.path.exists(self.cmd):
                return
            time.sleep(0.05)

    def _entry(self):
        with open(self.out, encoding="utf-8") as f:
            return f.read()

    def _wait(self, want, timeout=4.0):
        """等到输入框是 want，并且 0.4 秒后还是它（粘贴是异步的，不能把中间状态当结果）"""
        end = time.time() + timeout
        while time.time() < end:
            if self._entry() == want:
                time.sleep(0.4)
                if self._entry() == want:
                    return True
            time.sleep(0.05)
        return False

    def _act(self, args):
        return cloud_desktop.execute_desktop_action("phone", self.tmp, args, display_override=self.display)

    def test_01_root_cause_xdotool_c_locale_drops_chinese(self):
        """先证明根因：C locale 下 xdotool 逐字输入中文，程序里什么都收不到"""
        subprocess.run(["xdotool", "type", "--delay", "12", "--file", "-"], input="中文".encode(), env=self.env,
                       capture_output=True, timeout=10)
        time.sleep(0.6)
        self.assertEqual(self._entry(), "", "C locale 下 xdotool 居然打出了中文：根因假设不成立")

    def test_02_phone_ime_chinese_arrives_in_app(self):
        text = "你好，云电脑：中文输入✓"
        res = self._act({"action": "type", "text": text})
        self.assertEqual(res.get("status"), "ok", res)
        self.assertTrue(self._wait(text), f"程序收到的是 {self._entry()!r}")

    def test_03_fallback_typing_chinese_without_clipboard_tools(self):
        """没有 xclip / xsel 时逐字输入：修好 locale 后中文照样到"""
        real = shutil.which
        with mock.patch.object(cloud_desktop.shutil, "which", lambda n: None if n in ("xclip", "xsel") else real(n)):
            res = self._act({"action": "type", "text": "逐字输入中文"})
        self.assertEqual(res.get("method"), "xdotool_type", res)
        self.assertTrue(self._wait("逐字输入中文"), f"程序收到的是 {self._entry()!r}")

    def test_04_mixed_order_and_backspace_repeat(self):
        """输入法顺序：中文、ASCII、退格依次走服务器，到程序里顺序不乱"""
        for a in ({"action": "type", "text": "中"}, {"action": "type", "text": "ab"}, {"action": "type", "text": "文c"}):
            self.assertEqual(self._act(a).get("status"), "ok", a)
        self.assertTrue(self._wait("中ab文c"), f"程序收到的是 {self._entry()!r}")
        self.assertEqual(self._act({"action": "key", "key": "BackSpace", "repeat": 2}).get("repeat"), 2)
        self.assertTrue(self._wait("中ab"), f"退格 2 次后程序里是 {self._entry()!r}")

    def test_04b_ascii_space_backspace_return_and_mixed_punctuation(self):
        """手机键盘 ASCII / 空格 / 退格 / 换行，以及混合「中a1？」都应原样出现在输入框"""
        self.assertEqual(self._act({"action": "type", "text": "abc 123"}).get("status"), "ok")
        self.assertTrue(self._wait("abc 123"), f"程序收到的是 {self._entry()!r}")
        self.assertEqual(self._act({"action": "key", "key": "BackSpace"}).get("status"), "ok")
        self.assertTrue(self._wait("abc 12"), f"退格后程序里是 {self._entry()!r}")
        self.assertEqual(self._act({"action": "key", "key": "Return"}).get("status"), "ok")
        self.assertTrue(self._wait("abc 12\n"), f"换行后程序里是 {self._entry()!r}")
        self.assertEqual(self._act({"action": "type", "text": "中a1？"}).get("status"), "ok")
        self.assertTrue(self._wait("abc 12\n中a1？"), f"混合标点后程序里是 {self._entry()!r}")

    def test_05_phone_clipboard_then_remote_ctrl_v(self):
        text = "手机剪贴板→云电脑：粘贴中文✓"
        self.assertIsNone(cloud_desktop.write_clipboard(self.display, text))
        self.assertEqual(self._act({"action": "key", "key": "ctrl+v"}).get("status"), "ok")
        self.assertTrue(self._wait(text), f"程序收到的是 {self._entry()!r}")

    def test_06_remote_app_copy_reaches_phone(self):
        text = "远端程序里复制的中文：剪贴板→手机✓"
        self._command(text)
        end, got = time.time() + 4, None
        while time.time() < end:
            got = cloud_desktop.read_clipboard(self.display)
            if got == (text, None):
                break
            time.sleep(0.1)
        self.assertEqual(got, (text, None))


if __name__ == "__main__":
    unittest.main()
