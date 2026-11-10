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

def execute_desktop_action(session_id, workspace_dir, args):
    """
    Executes a desktop action (screenshot, click, type, key, mouse_move).
    Only allowed on DISPLAY user, thread-safe.
    """
    if not isinstance(args, dict):
        return {"error": "Invalid arguments: expected object"}

    action = args.get("action", "")
    display = os.environ.get("DISPLAY", ":99")

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
