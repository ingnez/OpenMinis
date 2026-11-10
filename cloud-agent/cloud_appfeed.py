"""
发给手机 App 的通知流：Bot 回复、任务完成、审批等都先记在这里，App 在线时长轮询取走，用系统本地通知显示。
App 最近在线且能发本地通知时不再走 Bark，避免同一件事收到两次；App 关闭后按设置决定要不要用 Bark 兜底。
"""
import json
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS app_notifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    session_id TEXT,
    bot_id TEXT,
    created_at REAL NOT NULL
);
"""
KEEP = 500
PRESENCE_TTL = 90           # 秒：App 进程这么久内报到过就算还活着（前台或后台都每 25 秒报到一次）


def ensure_schema(conn):
    conn.executescript(SCHEMA)
    cols = {r[1] for r in conn.execute("PRAGMA table_info(app_notifications)")}
    if "external" not in cols:
        # 1 = 已经通过 Bark / ntfy / Telegram 推送过：App 之后取到时只放进列表，不再弹系统通知（不重复）
        conn.execute("ALTER TABLE app_notifications ADD COLUMN external INTEGER NOT NULL DEFAULT 0")
    conn.commit()


class Feed:
    def __init__(self, db_fn):
        self.db_fn = db_fn
        self.cond = threading.Condition()
        self.presence = {"last_seen": 0.0, "foreground": False, "local_notifications": False}

    # ---------- 在线状态 ----------
    def touch(self, foreground=None, local_notifications=None, now=None):
        with self.cond:
            self.presence["last_seen"] = now or time.time()
            if foreground is not None:
                self.presence["foreground"] = bool(foreground)
            if local_notifications is not None:
                self.presence["local_notifications"] = bool(local_notifications)
            return dict(self.presence)

    def app_online(self, now=None):
        p = self.presence
        return (now or time.time()) - p["last_seen"] < PRESENCE_TTL and p["local_notifications"]

    def should_bark(self, bark_configured, bark_fallback, now=None):
        """bark_fallback: True / False / None（None = 已配置 Bark 就兜底）。App 在线时一律不发 Bark。"""
        if not bark_configured or self.app_online(now):
            return False
        return bark_configured if bark_fallback is None else bool(bark_fallback)

    # ---------- 通知流 ----------
    def add(self, kind, title, body, session_id=None, bot_id=None, external=False):
        conn = self.db_fn()
        try:
            cur = conn.execute("INSERT INTO app_notifications (kind, title, body, session_id, bot_id, created_at, external) VALUES (?, ?, ?, ?, ?, ?, ?)",
                               (kind, (title or "")[:120], (body or "")[:600], session_id, bot_id, time.time(), 1 if external else 0))
            nid = cur.lastrowid
            conn.execute("DELETE FROM app_notifications WHERE id <= ?", (nid - KEEP,))
            conn.commit()
        finally:
            conn.close()
        with self.cond:
            self.cond.notify_all()
        return nid

    def after(self, after_id, limit=50):
        conn = self.db_fn()
        try:
            rows = conn.execute("SELECT id, kind, title, body, session_id, bot_id, created_at, external FROM app_notifications WHERE id > ? ORDER BY id ASC LIMIT ?",
                                (after_id, limit)).fetchall()
            last = conn.execute("SELECT COALESCE(MAX(id), 0) FROM app_notifications").fetchone()[0]
        finally:
            conn.close()
        items = [{"id": r[0], "kind": r[1], "title": r[2], "body": r[3], "session_id": r[4], "bot_id": r[5], "created_at": r[6],
                  "external": bool(r[7])} for r in rows]
        return items, last

    def wait_after(self, after_id, wait_s):
        deadline = time.time() + max(0.0, min(25.0, wait_s))
        while True:
            items, last = self.after(after_id)
            remaining = deadline - time.time()
            if items or remaining <= 0:
                return items, last
            with self.cond:
                self.cond.wait(min(remaining, 5.0))
