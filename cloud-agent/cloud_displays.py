"""
每个 Bot（或同一 Bot 的额外并发槽）的独立虚拟屏幕：Xvfb :10+N + openbox + x11vnc，
并把 websockify token（bot-<key>: 127.0.0.1:<端口>）写进 token 目录，手机「电脑」页按 token 看对应屏幕。
按需启动，空闲超时关闭；数量上限来自资源设置。没有 Xvfb 时返回 None，调用方回退主屏 :99。
"""
import os
import re
import shutil
import subprocess
import threading
import time

TOKEN_DIR = os.environ.get("OPENMINIS_VNC_TOKENS", "/var/lib/openminis-cloud-agent/vnc-tokens")
AUTH_FILE = os.environ.get("XAUTHORITY", "/var/lib/openminis-cloud-agent/.Xauthority")
MAIN_DISPLAY = os.environ.get("DISPLAY", ":99") or ":99"


def token_proxy_enabled():
    """install-desktop.sh 新版把 websockify 改成 token 模式并写入 main 条目。"""
    return os.path.isfile(os.path.join(TOKEN_DIR, "main"))


def safe_token(key):
    return "bot-" + re.sub(r"[^a-z0-9_-]", "-", key.lower())[:48]


class DisplayManager:
    def __init__(self, settings_fn, index_fn, on_stop=None):
        self.settings_fn = settings_fn     # -> 资源设置
        self.index_fn = index_fn           # key -> 稳定编号（>=1）
        self.on_stop = on_stop             # key -> None（关闭该屏幕上的浏览器）
        self.lock = threading.Lock()
        self.displays = {}                 # key -> {display, vnc_port, procs, last_used, token}
        self.reaper = None

    @staticmethod
    def available():
        return bool(shutil.which("Xvfb") and shutil.which("x11vnc"))

    def _start_reaper(self):
        if self.reaper and self.reaper.is_alive():
            return
        self.reaper = threading.Thread(target=self._reap_loop, name="display-reaper", daemon=True)
        self.reaper.start()

    def _reap_loop(self):
        while True:
            time.sleep(30)
            idle = self.settings_fn().get("display_idle_min") or 0
            if not idle:
                continue
            now = time.time()
            with self.lock:
                stale = [k for k, d in self.displays.items() if now - d["last_used"] > idle * 60 and not d.get("pinned")]
            for k in stale:
                self.stop(k)

    def touch(self, key):
        with self.lock:
            if key in self.displays:
                self.displays[key]["last_used"] = time.time()

    def info(self, key):
        with self.lock:
            d = self.displays.get(key)
            return {k: v for k, v in d.items() if k != "procs"} if d else None

    def list(self):
        with self.lock:
            return [{"key": k, **{kk: vv for kk, vv in d.items() if kk != "procs"}} for k, d in self.displays.items()]

    def ensure(self, key):
        """返回屏幕信息；不可用或达到上限时返回 None（回退主屏）。"""
        if not self.available():
            return None
        s = self.settings_fn()
        with self.lock:
            d = self.displays.get(key)
            if d and all(p.poll() is None for p in d["procs"]):
                d["last_used"] = time.time()
                return {k: v for k, v in d.items() if k != "procs"}
            if d:
                self._kill(d)
                self.displays.pop(key, None)
            limit = s.get("max_displays") or 0
            if limit and len(self.displays) >= limit:
                return None
        n = 10 + self.index_fn(key)
        display = f":{n}"
        port = 5900 + n
        env = os.environ.copy()
        env["DISPLAY"] = display
        if os.path.exists(AUTH_FILE):
            env["XAUTHORITY"] = AUTH_FILE
        res = s.get("resolution") or "1280x800"
        procs = []
        try:
            xvfb = ["Xvfb", display, "-screen", "0", f"{res}x24", "-nolisten", "tcp", "-noreset"]
            if os.path.exists(AUTH_FILE):
                xvfb += ["-auth", AUTH_FILE]
            procs.append(subprocess.Popen(xvfb, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True))
            for _ in range(40):
                if os.path.exists(f"/tmp/.X11-unix/X{n}"):
                    break
                time.sleep(0.1)
            if shutil.which("openbox"):
                procs.append(subprocess.Popen(["openbox"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True))
            vnc = ["x11vnc", "-display", display, "-rfbport", str(port), "-listen", "127.0.0.1", "-nopw", "-forever", "-shared", "-quiet"]
            if os.path.exists(AUTH_FILE):
                vnc += ["-auth", AUTH_FILE]
            procs.append(subprocess.Popen(vnc, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True))
        except OSError:
            for p in procs:
                p.kill()
            return None
        token = safe_token(key)
        try:
            if os.path.isdir(TOKEN_DIR):
                with open(os.path.join(TOKEN_DIR, token), "w") as f:
                    f.write(f"{token}: 127.0.0.1:{port}\n")
        except OSError:
            pass
        entry = {"display": display, "vnc_port": port, "token": token, "resolution": res,
                 "started_at": time.time(), "last_used": time.time(), "procs": procs}
        with self.lock:
            self.displays[key] = entry
        self._start_reaper()
        return {k: v for k, v in entry.items() if k != "procs"}

    def _kill(self, d):
        for p in reversed(d["procs"]):
            try:
                p.terminate()
                p.wait(timeout=3)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass
        try:
            os.remove(os.path.join(TOKEN_DIR, d["token"]))
        except OSError:
            pass

    def stop(self, key):
        with self.lock:
            d = self.displays.pop(key, None)
        if not d:
            return False
        if self.on_stop:
            try:
                self.on_stop(key)
            except Exception:
                pass
        self._kill(d)
        return True

    def stop_all(self):
        for k in [d["key"] for d in self.list()]:
            self.stop(k)
