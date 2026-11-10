"""任务录屏回放：Bot 用浏览器 / 桌面时，每张截图连同之前做过的动作说明存成一帧，手机上可以逐帧或自动播放。
- 只存截图（Bot 本来就拍的），不额外录视频，不占 CPU
- 动作说明不含输入的原文（可能是密码），只写「输入了 N 个字」；网址只留域名
- 每个任务最多 MAX_FRAMES 帧，只保留最近 MAX_TASKS 个任务的回放"""
import json
import os
import re
import shutil
import threading
import time
import urllib.parse

MAX_FRAMES = 80
MAX_TASKS = 20
MAX_BYTES = 2 * 1024 * 1024
_lock = threading.Lock()
_pending = {}       # task_id -> [动作说明…]（下一帧之前做的事）


def describe(tool, args):
    """把一次浏览器 / 桌面动作写成一句不泄露内容的说明"""
    a = args or {}
    act = a.get("action") or ""
    if act == "screenshot":
        return None
    if act in ("click", "mouse_move") and "x" in a:
        return f"{'点击' if act == 'click' else '移动鼠标到'} ({a.get('x')}, {a.get('y')})"
    if act == "click":
        sel = str(a.get("selector") or a.get("text") or "")[:40]
        return "点击 " + sel if sel else "点击"
    if act == "type":
        return f"输入了 {len(str(a.get('text') or ''))} 个字"
    if act == "key":
        return "按键 " + re.sub(r"[^A-Za-z0-9+_-]", "", str(a.get("key") or ""))[:24]
    if act == "navigate":
        host = urllib.parse.urlparse(str(a.get("url") or "")).hostname or ""
        return "打开 " + host if host else "打开网页"
    if act == "scroll":
        return "滚动页面"
    return (tool or "") + " " + act if act else tool


def _task_dir(root, task_id):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", task_id or ""):
        raise ValueError("bad task id")
    return os.path.join(root, task_id)


def note_action(task_id, tool, args):
    text = describe(tool, args)
    if text:
        with _lock:
            _pending.setdefault(task_id, []).append(text)


def add_frame(root, task_id, image_path, now=None):
    """截图存成一帧；返回帧号，超过上限 / 图太大 / 不存在时返回 None"""
    if not image_path or not os.path.isfile(image_path) or os.path.getsize(image_path) > MAX_BYTES:
        return None
    d = _task_dir(root, task_id)
    with _lock:
        steps = _pending.pop(task_id, [])
        os.makedirs(d, exist_ok=True)
        idx = _read_index(d)
        if len(idx) >= MAX_FRAMES:
            return None
        i = len(idx)
        ext = os.path.splitext(image_path)[1].lower() if os.path.splitext(image_path)[1].lower() in (".png", ".jpg", ".jpeg") else ".png"
        shutil.copyfile(image_path, os.path.join(d, f"{i:04d}{ext}"))
        idx.append({"i": i, "t": round(now if now is not None else time.time(), 2), "steps": steps[-8:], "file": f"{i:04d}{ext}"})
        with open(os.path.join(d, "index.json"), "w", encoding="utf-8") as f:
            json.dump(idx, f, ensure_ascii=False)
        if i == 0:
            _prune(root)
        return i


def _read_index(d):
    try:
        with open(os.path.join(d, "index.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def _prune(root):
    try:
        dirs = [os.path.join(root, x) for x in os.listdir(root) if os.path.isdir(os.path.join(root, x))]
    except OSError:
        return
    dirs.sort(key=os.path.getmtime, reverse=True)
    for old in dirs[MAX_TASKS:]:
        shutil.rmtree(old, ignore_errors=True)


def frames(root, task_id):
    return [{k: v for k, v in f.items() if k != "file"} for f in _read_index(_task_dir(root, task_id))]


def frame_bytes(root, task_id, i):
    for f in _read_index(_task_dir(root, task_id)):
        if f.get("i") == i:
            p = os.path.join(_task_dir(root, task_id), os.path.basename(f["file"]))
            with open(p, "rb") as fh:
                return fh.read(), ("image/jpeg" if p.endswith((".jpg", ".jpeg")) else "image/png")
    return None, None


def list_tasks(root):
    out = []
    try:
        names = os.listdir(root)
    except OSError:
        return []
    for n in names:
        d = os.path.join(root, n)
        idx = _read_index(d) if os.path.isdir(d) else []
        if idx:
            out.append({"task_id": n, "frames": len(idx), "started_at": idx[0]["t"], "ended_at": idx[-1]["t"]})
    out.sort(key=lambda x: -x["ended_at"])
    return out
