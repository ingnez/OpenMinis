"""浏览器会话快照：存下当前登录 cookie 和打开的网页，之后一键恢复（比如重启桌面、换 Bot 资料之后）。
cookie 只留在 VPS（文件权限 600），列表接口只给名字、网页数和时间，不把 cookie 发回手机，也不进模型上下文。
localStorage 不恢复（Playwright 只能在页面加载前注入，太容易出错），这点在说明里写明。"""
import json
import os
import re
import secrets
import time

MAX_SNAPSHOTS = 20
MAX_TABS = 6


def _dir(base):
    d = os.path.join(base, "browser-snapshots")
    os.makedirs(d, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def _valid_id(sid):
    return bool(re.match(r"^snap_[0-9a-f]{10}$", sid or ""))


def tabs_of(urls):
    return [u for u in (urls or []) if isinstance(u, str) and re.match(r"^https?://", u)][:MAX_TABS]


def save(base, name, profile, state):
    sid = "snap_" + secrets.token_hex(5)
    tabs = tabs_of(state.get("tabs"))
    cookies = state.get("cookies") or []
    meta = {"id": sid, "name": (name or "").strip()[:40] or time.strftime("快照 %m-%d %H:%M"),
            "profile": profile, "tabs": len(tabs), "hosts": sorted({re.sub(r"^https?://([^/]+).*", r"\1", u) for u in tabs})[:6],
            "cookies": len(cookies), "created_at": time.time()}
    path = os.path.join(_dir(base), sid + ".json")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"meta": meta, "cookies": cookies, "tabs": tabs}, f)
    for old in listing(base)[MAX_SNAPSHOTS:]:
        delete(base, old["id"])
    return meta


def listing(base):
    out = []
    d = _dir(base)
    for fn in os.listdir(d):
        if fn.endswith(".json"):
            try:
                with open(os.path.join(d, fn)) as f:
                    out.append(json.load(f)["meta"])
            except (OSError, ValueError, KeyError):
                continue
    out.sort(key=lambda m: -m.get("created_at", 0))
    return out


def load(base, sid):
    if not _valid_id(sid):
        return None
    try:
        with open(os.path.join(_dir(base), sid + ".json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def delete(base, sid):
    if not _valid_id(sid):
        return False
    try:
        os.remove(os.path.join(_dir(base), sid + ".json"))
        return True
    except OSError:
        return False
