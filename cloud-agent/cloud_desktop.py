#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Desktop Automation Helper (cloud_desktop.py)
Provides X11 desktop control using xdotool, xclip and scrot on DISPLAY=:99.
Thread-safe, self-contained, with graceful error handling when X11 tools are unavailable.
"""

import os
import sys
import time
import uuid
import shutil
import threading
import subprocess
import tempfile

desktop_lock = threading.Lock()

def is_desktop_available():
    display = os.environ.get("DISPLAY", ":99")
    if not display:
        return False

    has_xdotool = shutil.which("xdotool") is not None
    has_scrot = shutil.which("scrot") is not None or shutil.which("import") is not None
    if not (has_xdotool and has_scrot):
        return False

    # Check if X display is alive via xdpyinfo
    if shutil.which("xdpyinfo"):
        env = os.environ.copy()
        if "XAUTHORITY" not in env and os.path.exists("/var/lib/openminis-cloud-agent/.Xauthority"):
            env["XAUTHORITY"] = "/var/lib/openminis-cloud-agent/.Xauthority"
        try:
            res = subprocess.run(
                ["xdpyinfo", "-display", display],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2
            )
            if res.returncode != 0:
                return False
        except Exception:
            return False

    return True

def execute_desktop_action(session_id, workspace_dir, args, display_override=None):
    """
    Executes a desktop action (screenshot, click, type, key, mouse_move).
    Only allowed on DISPLAY user, thread-safe.
    """
    if not isinstance(args, dict):
        return {"error": "Invalid arguments: expected object"}

    action = args.get("action", "")
    display = display_override or os.environ.get("DISPLAY", ":99")

    # Verify X11 tools & auth
    env = os.environ.copy()
    env["DISPLAY"] = display
    if "XAUTHORITY" not in env and os.path.exists("/var/lib/openminis-cloud-agent/.Xauthority"):
        env["XAUTHORITY"] = "/var/lib/openminis-cloud-agent/.Xauthority"

    attachments_dir = os.path.join(workspace_dir, "attachments")
    os.makedirs(attachments_dir, exist_ok=True)

    with desktop_lock:
        if action == "screenshot":
            filename = f"desktop_{uuid.uuid4().hex[:8]}.png"
            filepath = os.path.join(attachments_dir, filename)
            
            # Try scrot first, then import (imagemagick)
            cmd = None
            if shutil.which("scrot"):
                cmd = ["scrot", filepath]
            elif shutil.which("import"):
                cmd = ["import", "-window", "root", filepath]
            
            if not cmd:
                return {
                    "error": "Desktop screenshot tool (scrot/import) is not installed on this VPS.",
                    "display": display
                }

            try:
                res = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                if res.returncode != 0:
                    return {"error": f"Screenshot command failed: {res.stderr.decode('utf-8', 'replace')}"}
                if not os.path.exists(filepath):
                    return {"error": "Screenshot file was not created"}
                return {
                    "status": "ok",
                    "action": "screenshot",
                    "file_path": os.path.relpath(filepath, workspace_dir),
                    "attachment_url": f"/v1/sessions/{session_id}/attachments/{filename}",
                    "width": 1280,
                    "height": 800
                }
            except Exception as e:
                return {"error": f"Screenshot error: {e}"}

        elif action in ("click", "mouse_move"):
            if not shutil.which("xdotool"):
                return {"error": "xdotool is not installed on this VPS."}
            x = int(args.get("x", 0))
            y = int(args.get("y", 0))
            button = int(args.get("button", 1))
            try:
                if action == "click":
                    cmd = ["xdotool", "mousemove", "--", str(x), str(y), "click", str(button)]
                else:
                    cmd = ["xdotool", "mousemove", "--", str(x), str(y)]
                res = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                if res.returncode != 0:
                    return {"error": f"xdotool failed: {res.stderr.decode('utf-8', 'replace')}"}
                return {"status": "ok", "action": action, "x": x, "y": y}
            except Exception as e:
                return {"error": f"Desktop {action} error: {e}"}

        elif action == "type":
            if not shutil.which("xdotool"):
                return {"error": "xdotool is not installed on this VPS."}
            text = args.get("text", "")
            if not isinstance(text, str):
                text = str(text)

            # Check if text contains non-ASCII characters (e.g. Chinese)
            has_non_ascii = any(ord(c) > 127 for c in text)
            if has_non_ascii:
                # Use xclip + xdotool key to paste unicode text cleanly
                if not shutil.which("xclip"):
                    return {"error": "xclip is required for non-ASCII/Unicode typing on this VPS."}
                try:
                    p = subprocess.Popen(
                        ["xclip", "-selection", "clipboard"],
                        env=env,
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE
                    )
                    stdout, stderr = p.communicate(input=text.encode("utf-8"), timeout=5)
                    if p.returncode != 0:
                        return {"error": f"xclip clipboard copy failed: {stderr.decode('utf-8', 'replace')}"}
                    # Paste using Ctrl+v
                    res = subprocess.run(
                        ["xdotool", "key", "--", "ctrl+v"],
                        env=env,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        timeout=5
                    )
                    if res.returncode != 0:
                        return {"error": f"xdotool paste failed: {res.stderr.decode('utf-8', 'replace')}"}
                    return {"status": "ok", "action": "type", "length": len(text), "method": "clipboard"}
                except Exception as e:
                    return {"error": f"Desktop unicode type error: {e}"}
            else:
                try:
                    # Pass -- to prevent option injection
                    cmd = ["xdotool", "type", "--delay", "12", "--", text]
                    res = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
                    if res.returncode != 0:
                        return {"error": f"xdotool type failed: {res.stderr.decode('utf-8', 'replace')}"}
                    return {"status": "ok", "action": "type", "length": len(text)}
                except Exception as e:
                    return {"error": f"Desktop type error: {e}"}

        elif action == "key":
            if not shutil.which("xdotool"):
                return {"error": "xdotool is not installed on this VPS."}
            key = args.get("key", "")
            if not key:
                return {"error": "Missing key parameter"}
            try:
                cmd = ["xdotool", "key", "--", str(key)]
                res = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                if res.returncode != 0:
                    return {"error": f"xdotool key failed: {res.stderr.decode('utf-8', 'replace')}"}
                return {"status": "ok", "action": "key", "key": key}
            except Exception as e:
                return {"error": f"Desktop key error: {e}"}

        else:
            return {"error": f"Unsupported desktop action: {action}"}


_THUMB_CACHE = {}
_THUMB_LOCK = threading.Lock()


def thumbnail(display, width=480, max_age=2.5):
    """桌面小预览（手机对话里“正在用电脑”时显示）：截屏后缩到 width 宽的 JPEG。
    返回 (bytes, mime)；截不了屏返回 (None, 原因)。同一屏幕 max_age 秒内复用上一张，避免多台手机一起轮询时反复截屏。"""
    now = time.time()
    with _THUMB_LOCK:
        hit = _THUMB_CACHE.get((display, width))
        if hit and now - hit[0] < max_age:
            return hit[1], hit[2]
    env = os.environ.copy()
    env["DISPLAY"] = display
    if "XAUTHORITY" not in env and os.path.exists("/var/lib/openminis-cloud-agent/.Xauthority"):
        env["XAUTHORITY"] = "/var/lib/openminis-cloud-agent/.Xauthority"
    with tempfile.TemporaryDirectory() as d:
        png = os.path.join(d, "s.png")
        if shutil.which("scrot"):
            cmd = ["scrot", "-o", png]
        elif shutil.which("import"):
            cmd = ["import", "-window", "root", png]
        else:
            return None, "没有截屏工具（scrot / import）"
        try:
            res = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8)
        except Exception as e:
            return None, f"截屏失败：{e}"
        if res.returncode != 0 or not os.path.exists(png):
            return None, "截屏失败：" + res.stderr.decode("utf-8", "replace")[:200]
        data, mime = None, "image/png"
        try:
            from PIL import Image
            import io
            im = Image.open(png).convert("RGB")
            if im.width > width:
                im = im.resize((width, max(1, im.height * width // im.width)))
            buf = io.BytesIO()
            im.save(buf, "JPEG", quality=70)
            data, mime = buf.getvalue(), "image/jpeg"
        except Exception:
            jpg = os.path.join(d, "s.jpg")
            if shutil.which("convert") and subprocess.run(["convert", png, "-resize", f"{width}x", "-quality", "70", jpg],
                                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8).returncode == 0:
                with open(jpg, "rb") as f:
                    data, mime = f.read(), "image/jpeg"
            else:
                with open(png, "rb") as f:
                    data = f.read()
    with _THUMB_LOCK:
        _THUMB_CACHE[(display, width)] = (time.time(), data, mime)
    return data, mime


CLIPBOARD_MAX = 10000


def _x_env(display):
    env = os.environ.copy()
    env["DISPLAY"] = display
    if "XAUTHORITY" not in env and os.path.exists("/var/lib/openminis-cloud-agent/.Xauthority"):
        env["XAUTHORITY"] = "/var/lib/openminis-cloud-agent/.Xauthority"
    return env


def write_clipboard(display, text):
    """手机 → 云电脑剪贴板。返回错误文字或 None。文字经 stdin 交给 xclip，不出现在进程参数里。"""
    if not shutil.which("xclip"):
        return "云电脑没有安装 xclip"
    try:
        r = subprocess.run(["xclip", "-selection", "clipboard", "-i"], input=text.encode("utf-8"), env=_x_env(display),
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5)
    except Exception as e:
        return f"写入剪贴板失败：{type(e).__name__}"
    return None if r.returncode == 0 else "写入剪贴板失败"


def read_clipboard(display):
    """读远端剪贴板文字（手机「取回剪贴板」）。返回 (文字, 错误)。"""
    if not shutil.which("xclip"):
        return None, "云电脑没有安装 xclip"
    try:
        r = subprocess.run(["xclip", "-o", "-selection", "clipboard"], env=_x_env(display), capture_output=True, timeout=5)
    except Exception as e:
        return None, f"读取剪贴板失败：{type(e).__name__}"
    if r.returncode != 0:
        return "", None  # 剪贴板为空时 xclip 返回非 0
    return r.stdout.decode("utf-8", "replace")[:CLIPBOARD_MAX], None
