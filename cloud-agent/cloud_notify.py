#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent — 完成推送（Bark / ntfy）。

配置（含 Bark 设备 Key、ntfy 访问令牌）经 cloud_secrets 以 AES-256-GCM 加密保存在 SQLite，
接口只回传脱敏后的地址。推送在后台线程发送，失败只记录状态，不影响任务。
"""

import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

import cloud_secrets

SETTING_NAME = "notify"
EVENTS = ("task_completed", "approval_required", "routine_finished")
DEFAULT_EVENTS = {"task_completed": True, "approval_required": True, "routine_finished": True}
TIMEOUT = 10

_last = {"at": None, "ok": None, "error": None, "event": None}
_last_lock = threading.Lock()


class NotifyConfigError(ValueError):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "Redirection prohibited", headers, fp)


def ensure_schema(conn):
    conn.execute("""
    CREATE TABLE IF NOT EXISTS secure_settings (
        name TEXT PRIMARY KEY,
        ciphertext BLOB NOT NULL,
        updated_at REAL NOT NULL
    )
    """)
    conn.commit()


def validate(cfg):
    if not isinstance(cfg, dict):
        raise NotifyConfigError("config must be an object")
    provider = cfg.get("provider")
    if provider not in ("bark", "ntfy"):
        raise NotifyConfigError("provider must be bark or ntfy")
    url = cfg.get("url")
    if not isinstance(url, str) or len(url) > 2048:
        raise NotifyConfigError("url is required")
    p = urllib.parse.urlparse(url.strip())
    if p.scheme not in ("http", "https") or not p.netloc or p.username or p.password:
        raise NotifyConfigError("url must be http(s) without embedded credentials")
    if not p.path.strip("/"):
        raise NotifyConfigError("url must include the Bark device key or the ntfy topic, e.g. https://api.day.app/<key> or https://ntfy.sh/<topic>")
    events = dict(DEFAULT_EVENTS)
    if "events" in cfg:
        if not isinstance(cfg["events"], dict):
            raise NotifyConfigError("events must be an object")
        for k, v in cfg["events"].items():
            if k not in EVENTS or not isinstance(v, bool):
                raise NotifyConfigError("unknown event or non-boolean value: " + str(k))
            events[k] = v
    token = cfg.get("token")
    if token is not None and (not isinstance(token, str) or len(token) > 512):
        raise NotifyConfigError("token must be a string")
    out = {"provider": provider, "url": url.strip().rstrip("/"), "events": events}
    if token:
        out["token"] = token
    group = cfg.get("group")
    if group is not None:
        if not isinstance(group, str) or len(group) > 64:
            raise NotifyConfigError("group must be a short string")
        out["group"] = group
    return out


def save_setting(conn, name, obj):
    """加密保存一份 JSON 配置（AAD = setting:<name>）。"""
    blob = cloud_secrets.get_box().encrypt(json.dumps(obj), "setting:" + name)
    conn.execute("INSERT INTO secure_settings (name, ciphertext, updated_at) VALUES (?, ?, ?) "
                 "ON CONFLICT(name) DO UPDATE SET ciphertext = excluded.ciphertext, updated_at = excluded.updated_at",
                 (name, blob, time.time()))
    conn.commit()


def load_setting(conn, name):
    """返回配置或 None。主密钥缺失 / 密文损坏时抛 cloud_secrets 的异常。"""
    row = conn.execute("SELECT ciphertext FROM secure_settings WHERE name = ?", (name,)).fetchone()
    if not row:
        return None
    return json.loads(cloud_secrets.get_box().decrypt(bytes(row[0]), "setting:" + name))


def delete_setting(conn, name):
    cur = conn.execute("DELETE FROM secure_settings WHERE name = ?", (name,))
    conn.commit()
    return cur.rowcount > 0


def save(conn, cfg):
    cfg = validate(cfg)
    save_setting(conn, SETTING_NAME, cfg)
    return cfg


def load(conn):
    return load_setting(conn, SETTING_NAME)


def delete(conn):
    return delete_setting(conn, SETTING_NAME)


def masked(cfg):
    if not cfg:
        return None
    p = urllib.parse.urlparse(cfg["url"])
    tail = p.path.rstrip("/")[-4:]
    return {"provider": cfg["provider"], "url": f"{p.scheme}://{p.netloc}/…{tail}", "events": cfg["events"],
            "has_token": bool(cfg.get("token")), "group": cfg.get("group")}


def last_status():
    with _last_lock:
        return dict(_last)


def build_request(cfg, title, body, click_url=None):
    """构造推送请求（不发送）。Bark: POST <server>/<key> JSON；ntfy: POST <server>/ JSON 发布（标题可含中文）。"""
    title = (title or "")[:120]
    body = (body or "")[:1500] or " "
    headers = {"Content-Type": "application/json; charset=utf-8", "User-Agent": "openminis-cloud-agent"}
    if cfg["provider"] == "bark":
        payload = {"title": title, "body": body, "group": cfg.get("group") or "OpenMinis"}
        if click_url:
            payload["url"] = click_url
        url = cfg["url"]
    else:
        p = urllib.parse.urlparse(cfg["url"])
        segments = [s for s in p.path.split("/") if s]
        topic = segments[-1]
        base_path = "/".join(segments[:-1])
        url = f"{p.scheme}://{p.netloc}/{base_path + '/' if base_path else ''}"
        payload = {"topic": topic, "title": title, "message": body, "tags": ["robot"]}
        if click_url:
            payload["click"] = click_url
        if cfg.get("token"):
            headers["Authorization"] = "Bearer " + cfg["token"]
    return urllib.request.Request(url, data=json.dumps(payload, ensure_ascii=False).encode("utf-8"), headers=headers, method="POST")


def send_now(cfg, title, body, event="test"):
    """同步发送，返回 (ok, error)。错误信息不含设备 Key / 令牌。"""
    try:
        req = build_request(cfg, title, body)
        opener = urllib.request.build_opener(_NoRedirect)
        with opener.open(req, timeout=TIMEOUT) as resp:
            ok, err = 200 <= resp.status < 300, None if 200 <= resp.status < 300 else f"HTTP {resp.status}"
    except urllib.error.HTTPError as e:
        ok, err = False, f"HTTP {e.code}"
    except Exception as e:
        ok, err = False, type(e).__name__
    with _last_lock:
        _last.update({"at": time.time(), "ok": ok, "error": err, "event": event})
    return ok, err


def notify_async(cfg, event, title, body):
    if not cfg or not cfg.get("events", {}).get(event, False):
        return False
    threading.Thread(target=send_now, args=(cfg, title, body, event), daemon=True).start()
    return True
