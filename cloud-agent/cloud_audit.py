"""
操作记录：Bot 改了哪些文件、记下了哪些记忆，都记一笔并保存撤销所需的旧内容，App 里可以一键撤销。
旧内容只保存不超过 512KB 的文本；更大的文件只记录、不能撤销。只保留最近 KEEP 条。
"""
import json
import os
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    bot_id TEXT,
    tool TEXT NOT NULL,
    target TEXT NOT NULL,
    summary TEXT NOT NULL,
    undo TEXT,
    undone INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_bot ON audit_log(bot_id, id);
"""
KEEP = 1000
MAX_SNAPSHOT = 512 * 1024


def ensure_schema(conn):
    conn.executescript(SCHEMA)
    conn.commit()


def file_snapshot(abs_path):
    """改文件之前调用：返回撤销信息（不存在 = 撤销时删掉；太大或不是文本 = None，不能撤销）。"""
    if not os.path.exists(abs_path):
        return {"kind": "file", "path": abs_path, "existed": False}
    try:
        if os.path.islink(abs_path) or not os.path.isfile(abs_path) or os.path.getsize(abs_path) > MAX_SNAPSHOT:
            return None
        with open(abs_path, "r", encoding="utf-8") as f:
            return {"kind": "file", "path": abs_path, "existed": True, "content": f.read()}
    except (OSError, UnicodeDecodeError):
        return None


def record(conn, tool, target, summary, undo=None, session_id=None, bot_id=None, now=None):
    c = conn.execute("INSERT INTO audit_log (session_id, bot_id, tool, target, summary, undo, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                     (session_id, bot_id or "", tool, str(target)[:300], str(summary)[:300],
                      json.dumps(undo, ensure_ascii=False) if undo else None, now or time.time()))
    conn.execute("DELETE FROM audit_log WHERE id <= ?", (c.lastrowid - KEEP,))
    conn.commit()
    return c.lastrowid


def _row(r):
    return {"id": r[0], "session_id": r[1], "bot_id": r[2], "tool": r[3], "target": r[4], "summary": r[5],
            "undoable": bool(r[6]) and not r[7], "undone": bool(r[7]), "created_at": r[8]}


def list_entries(conn, bot_id=None, limit=100):
    cols = "id, session_id, bot_id, tool, target, summary, undo, undone, created_at"
    if bot_id is not None:
        rows = conn.execute("SELECT " + cols + " FROM audit_log WHERE bot_id = ? ORDER BY id DESC LIMIT ?", (bot_id, limit)).fetchall()
    else:
        rows = conn.execute("SELECT " + cols + " FROM audit_log ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    return [_row(r) for r in rows]


def undo(conn, entry_id, delete_memory, other=None):
    """撤销一条记录。返回 (ok, 说明)。文件撤销前会核对路径没被换成链接。"""
    r = conn.execute("SELECT undo, undone FROM audit_log WHERE id = ?", (entry_id,)).fetchone()
    if not r:
        return False, "没有这条记录"
    if r[1]:
        return False, "已经撤销过了"
    if not r[0]:
        return False, "这条操作不能撤销"
    info = json.loads(r[0])
    if info.get("kind") == "file":
        path = info["path"]
        if os.path.islink(path):
            return False, "文件已被换成链接，不能撤销"
        if info.get("existed"):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(info.get("content", ""))
        elif os.path.isfile(path):
            os.remove(path)
    elif info.get("kind") == "memory":
        delete_memory(info["id"])
    elif other is not None and info.get("kind") == "bot":
        ok, msg = other(info)
        if not ok:
            return False, msg
    else:
        return False, "这条操作不能撤销"
    conn.execute("UPDATE audit_log SET undone = 1 WHERE id = ?", (entry_id,))
    conn.commit()
    return True, "已撤销"
