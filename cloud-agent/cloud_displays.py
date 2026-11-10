"""
每个 Bot（或同一 Bot 的额外并发槽）的独立虚拟屏幕：Xvfb :10+N + openbox + x11vnc，
并把 websockify token（bot-<key>: 127.0.0.1:<端口>）写进 token 目录，手机「电脑」页按 token 看对应屏幕。
按需启动，空闲超时关闭；数量上限来自资源设置。没有 Xvfb 时返回 None，调用方回退主屏 :99。
"""
import base64
import os
import re
import socket
import shutil
import subprocess
import threading
import time

TOKEN_DIR = os.environ.get("OPENMINIS_VNC_TOKENS", "/var/lib/openminis-cloud-agent/vnc-tokens")
AUTH_FILE = os.environ.get("XAUTHORITY", "/var/lib/openminis-cloud-agent/.Xauthority")
MAIN_DISPLAY = os.environ.get("DISPLAY", ":99") or ":99"


def websockify_mode(proc_root="/proc"):
    """看正在运行的 websockify 进程实际用的是哪种目标：token（按 token 文件找屏幕）、fixed（固定 127.0.0.1:5901）、None（没在运行）。
    安装脚本更新了 token 文件但服务没重启时，两者会不一致，所以以进程为准。"""
    try:
        pids = [p for p in os.listdir(proc_root) if p.isdigit()]
    except OSError:
        return None
    for pid in pids:
        try:
            with open(os.path.join(proc_root, pid, "cmdline"), "rb") as f:
                args = f.read().split(b"\0")
        except OSError:
            continue
        if not any(b"websockify" in a for a in args[:3]):
            continue
        return "token" if b"--token-plugin" in args or any(a.startswith(b"--token-plugin=") for a in args) else "fixed"
    return None


def token_proxy_enabled():
    """websockify 是 token 模式时为 True；查不到进程时按安装脚本写入的 main 条目判断。"""
    mode = websockify_mode()
    if mode is not None:
        return mode == "token"
    return os.path.isfile(os.path.join(TOKEN_DIR, "main"))


def port_open(port, host="127.0.0.1", timeout=1.0, banner=None):
    import socket
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            if banner is None:
                return True
            s.settimeout(timeout)
            return s.recv(12).startswith(banner)
    except OSError:
        return False


def display_alive(display):
    n = display.lstrip(":").split(".")[0]
    return os.path.exists(f"/tmp/.X11-unix/X{n}")


def ws_probe(web_port, token=None, timeout=3.0):
    """像浏览器里的 noVNC 一样连 websockify：WebSocket 握手（binary 子协议）后应收到 VNC 的 "RFB " 握手帧。
    返回 (ok, 原因)。这一步能发现 token 不对 / 目标端口不对 / websockify 卡死等「网页能打开但画面连不上」的问题。"""
    path = "/websockify" + (f"?token={token}" if token else "")
    try:
        sock = socket.create_connection(("127.0.0.1", web_port), timeout=timeout)
    except OSError:
        return False, "websockify 端口连不上"
    try:
        sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{web_port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n"
                      "Origin: http://127.0.0.1\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf and len(buf) < 8192:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        parts = status.split()
        if len(parts) < 2 or parts[1] != "101":
            code = parts[1] if len(parts) >= 2 else "?"
            return False, ("websockify 找不到这个屏幕（token 不对）" if code == "404" else f"websockify 拒绝了 websocket（HTTP {code}）")
        def need(n):
            nonlocal rest
            while len(rest) < n:
                chunk = sock.recv(4096)
                if not chunk:
                    raise OSError("closed")
                rest += chunk
            out, rest = rest[:n], rest[n:]
            return out
        b0, b1 = need(2)
        if b0 & 0x0F == 0x8:
            return False, "websockify 接受后立刻关闭（转发目标 VNC 连不上）"
        n = b1 & 0x7F
        if n == 126:
            n = int.from_bytes(need(2), "big")
        elif n == 127:
            n = int.from_bytes(need(8), "big")
        mask = need(4) if b1 & 0x80 else None
        payload = need(min(n, 12))
        if mask:
            payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        if b0 & 0x0F == 0x1:           # 旧版 base64 文本帧
            try:
                payload = base64.b64decode(payload + b"==")
            except Exception:
                pass
        return (True, "") if payload.startswith(b"RFB ") else (False, "收到的不是 VNC 握手")
    except (OSError, ValueError):
        return False, "websocket 没有响应（x11vnc 未就绪或转发目标不对）"
    finally:
        try:
            sock.close()
        except OSError:
            pass


def diagnose(display=None, vnc_port=5901, token="main", web_port=18766, mode="auto", probe=True):
    """桌面链路逐段检查：Xvfb → x11vnc（RFB 握手）→ websockify（端口与 token 目标）。返回给手机显示的中文诊断。"""
    display = display or MAIN_DISPLAY
    mode = websockify_mode() if mode == "auto" else mode
    checks = {
        "xvfb": display_alive(display),
        "vnc": port_open(vnc_port, banner=b"RFB "),
        "websockify": port_open(web_port),
        "websockify_mode": mode,
        "token_file": None,
    }
    if mode == "token":
        path = os.path.join(TOKEN_DIR, token)
        want = f"{token}: 127.0.0.1:{vnc_port}"
        try:
            with open(path) as f:
                checks["token_file"] = f.read().strip() == want
        except OSError:
            checks["token_file"] = False
        if not checks["token_file"] and os.path.isdir(TOKEN_DIR):
            # token 条目缺失或指向旧端口（例如主屏条目被旧版安装脚本删掉）：直接改正，websockify 每次连接都会重新读取
            try:
                with open(path, "w") as f:
                    f.write(want + "\n")
                checks["token_file"] = True
                checks["token_repaired"] = True
            except OSError:
                pass
    code, msg = "ok", "桌面服务正常"
    if not checks["xvfb"]:
        code, msg = "display_down", f"桌面服务未运行：虚拟屏幕 {display} 没有启动"
    elif not checks["vnc"]:
        code, msg = "vnc_down", f"VNC 端口不通：x11vnc 没有在 {vnc_port} 端口响应"
    elif not checks["websockify"]:
        code, msg = "proxy_down", "桌面网页代理（websockify / noVNC）没有运行"
    elif mode == "token" and checks["token_file"] is False:
        code, msg = "token_mismatch", f"屏幕 {token} 的转发目标不对或缺失，需要重启桌面"
    elif mode == "fixed" and vnc_port != 5901:
        code, msg = "proxy_old", "服务器的桌面代理是旧版（只能看主屏），请安装 / 更新桌面环境"
    elif probe:
        ok, why = ws_probe(web_port, token if mode == "token" else None)
        checks["stream"] = ok
        if not ok:
            code, msg = "ws_failed", f"画面通道不通：{why}"
    checks["ok"] = code == "ok"
    checks["diagnosis"] = code
    checks["message"] = msg
    return checks


def ensure_xauth(display, auth_file=None, run=subprocess.run):
    """给 :N 在 Xauthority 文件里补一条 cookie（沿用主屏 :99 的 cookie）。
    安装脚本只为 :99 写了 cookie：独立屏幕的 Xvfb 用同一个文件开启了访问控制，x11vnc / 浏览器却找不到 :N 的条目，
    会被拒绝连接，x11vnc 随即退出——手机上就是「VNC 端口不通：x11vnc 没有在 59xx 端口响应」。
    返回 True 表示可以安全地带 -auth 启动；False 表示应不带 -auth 启动（没有 xauth 工具或文件不可写）。"""
    auth_file = auth_file or AUTH_FILE
    xauth = shutil.which("xauth")
    if not xauth or not os.path.exists(auth_file):
        return False
    try:
        have = run([xauth, "-f", auth_file, "list", display], capture_output=True, text=True, timeout=5).stdout.strip()
        if have:
            return True
        main = run([xauth, "-f", auth_file, "list", MAIN_DISPLAY], capture_output=True, text=True, timeout=5).stdout.split()
        cookie = main[-1] if len(main) >= 3 else os.urandom(16).hex()
        r = run([xauth, "-f", auth_file, "add", display, ".", cookie], capture_output=True, text=True, timeout=5)
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def clear_stale_display(n):
    """上一个 Agent 进程留下的 Xvfb :N（锁文件指向的进程还活着但不归现在的进程管）：结束它，避免「server already active」。"""
    lock = f"/tmp/.X{n}-lock"
    try:
        with open(lock) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return
    try:
        os.kill(pid, 15)
        for _ in range(20):
            time.sleep(0.1)
            os.kill(pid, 0)
    except ProcessLookupError:
        pass
    except PermissionError:
        return
    for path in (lock, f"/tmp/.X11-unix/X{n}"):
        try:
            os.remove(path)
        except OSError:
            pass


def safe_token(key):
    return "bot-" + re.sub(r"[^a-z0-9_-]", "-", key.lower())[:48]


class _Adopted(Exception):
    """屏幕已由之前的进程启动并在工作：不用重新启动。"""


class DisplayManager:
    def __init__(self, settings_fn, index_fn, on_stop=None):
        self.settings_fn = settings_fn     # -> 资源设置
        self.index_fn = index_fn           # key -> 稳定编号（>=1）
        self.on_stop = on_stop             # key -> None（关闭该屏幕上的浏览器）
        self.lock = threading.Lock()
        self.displays = {}                 # key -> {display, vnc_port, procs, last_used, token}
        self.reaper = None
        self.last_error = None

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
            alive = all(p.poll() is None for p in d["procs"]) if d and d["procs"] else (d is not None and port_open(d["vnc_port"], banner=b"RFB "))
            if d and alive:
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
        use_auth = ensure_xauth(display)
        if use_auth:
            env["XAUTHORITY"] = AUTH_FILE
        res = s.get("resolution") or "1280x800"
        procs = []
        # 上一个 Agent 进程起的屏幕还在正常工作：直接沿用；残缺的（只剩 Xvfb 或锁文件）先清掉再重建
        adopt = port_open(port, banner=b"RFB ") and display_alive(display)
        if not adopt:
            clear_stale_display(n)
        try:
            if adopt:
                raise _Adopted()
            xvfb = ["Xvfb", display, "-screen", "0", f"{res}x24", "-nolisten", "tcp", "-noreset"]
            if use_auth:
                xvfb += ["-auth", AUTH_FILE]
            procs.append(subprocess.Popen(xvfb, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True))
            for _ in range(40):
                if os.path.exists(f"/tmp/.X11-unix/X{n}"):
                    break
                time.sleep(0.1)
            if shutil.which("openbox"):
                procs.append(subprocess.Popen(["openbox"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True))
            vnc = ["x11vnc", "-display", display, "-rfbport", str(port), "-listen", "127.0.0.1", "-nopw", "-forever", "-shared", "-quiet"]
            if use_auth:
                vnc += ["-auth", AUTH_FILE]
            procs.append(subprocess.Popen(vnc, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True))
            # 等 x11vnc 真正开始监听；没起来就清掉、回退主屏，而不是把一个打不开的屏幕交给手机
            for _ in range(50):
                if port_open(port, banner=b"RFB "):
                    break
                if procs[-1].poll() is not None:
                    break
                time.sleep(0.1)
            if not port_open(port, banner=b"RFB "):
                raise OSError("x11vnc did not start")
        except _Adopted:
            pass
        except OSError:
            for p in procs:
                try:
                    p.kill()
                except Exception:
                    pass
            self.last_error = f"独立屏幕 {display} 启动失败（x11vnc 没有在 {port} 端口监听），已回退主屏"
            return None
        token = safe_token(key)
        try:
            if os.path.isdir(TOKEN_DIR):
                with open(os.path.join(TOKEN_DIR, token), "w") as f:
                    f.write(f"{token}: 127.0.0.1:{port}\n")
        except OSError:
            pass
        self.last_error = None
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
