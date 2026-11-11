# -*- coding: utf-8 -*-
"""后台任务（worker）：把「干活」和「聊天」分开。

前台对话（Bot 的主对话）保持随时能回话；实质性的多步任务用 spawn_task 交给后台 worker。
worker 有自己的会话（独立上下文，不带无关闲聊），完成后把结果作为 Bot 的一条消息发回前台对话，
只发一次（reported 0 → 1 谁先改到谁发）。前台上下文里只放每个任务的简短摘要，不放 worker 的完整过程。
每个 Bot 同时最多 SOFT_CAP 个 worker 运行，超出的排队。
"""

import json
import time
import uuid
import re

SOFT_CAP = 4
ID_RE = re.compile(r"^wk_[a-f0-9]{10}$")
ACTIVE = ("queued", "running")
COLS = ("worker_id", "bot_id", "front_session", "worker_session", "task_id", "title", "goal", "context", "status",
        "result", "last_step", "reported", "created_at", "started_at", "finished_at")


class WorkerError(ValueError):
    pass


def ensure_schema(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS bot_workers (worker_id TEXT PRIMARY KEY, bot_id TEXT, front_session TEXT NOT NULL, "
                 "worker_session TEXT NOT NULL, task_id TEXT, title TEXT NOT NULL, goal TEXT NOT NULL, context TEXT, "
                 "status TEXT NOT NULL, result TEXT, last_step TEXT, reported INTEGER NOT NULL DEFAULT 0, "
                 "created_at REAL NOT NULL, started_at REAL, finished_at REAL)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_bot_workers_front ON bot_workers(front_session, created_at)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_bot_workers_session ON bot_workers(worker_session)")
    conn.commit()


def _row(r):
    if not r:
        return None
    d = dict(zip(COLS, r))
    d["reported"] = bool(d["reported"])
    end = d["finished_at"] or time.time()
    d["elapsed_s"] = round(end - (d["started_at"] or d["created_at"]), 1) if d["status"] != "queued" else 0
    return d


def get(conn, worker_id):
    if not isinstance(worker_id, str) or not ID_RE.match(worker_id):
        return None
    return _row(conn.execute(f"SELECT {', '.join(COLS)} FROM bot_workers WHERE worker_id = ?", (worker_id,)).fetchone())


def by_session(conn, worker_session):
    return _row(conn.execute(f"SELECT {', '.join(COLS)} FROM bot_workers WHERE worker_session = ?", (worker_session,)).fetchone())


def is_worker_session(conn, session_id):
    return conn.execute("SELECT 1 FROM bot_workers WHERE worker_session = ?", (session_id,)).fetchone() is not None


def list_for(conn, bot_id=None, front_session=None, limit=50):
    sql, args = f"SELECT {', '.join(COLS)} FROM bot_workers", []
    if front_session:
        sql += " WHERE front_session = ?"
        args.append(front_session)
    elif bot_id is not None:
        sql += " WHERE COALESCE(bot_id, '') = ?"
        args.append(bot_id)
    sql += " ORDER BY created_at DESC LIMIT ?"
    return [_row(r) for r in conn.execute(sql, args + [max(1, min(int(limit), 200))]).fetchall()]


def running_count(conn, bot_id):
    return conn.execute("SELECT COUNT(*) FROM bot_workers WHERE COALESCE(bot_id, '') = ? AND status = 'running'",
                        (bot_id or "",)).fetchone()[0]


def create(conn, bot_id, front_session, goal, context=None, title=None):
    if not isinstance(goal, str) or not goal.strip():
        raise WorkerError("goal 不能为空")
    if context is not None and not isinstance(context, str):
        raise WorkerError("context 必须是字符串")
    wid = "wk_" + uuid.uuid4().hex[:10]
    sid = "sess_" + uuid.uuid4().hex[:12]
    title = (title if isinstance(title, str) and title.strip() else goal.strip().splitlines()[0])[:60]
    now = time.time()
    conn.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, NULL, ?, '', ?, ?)",
                 (sid, "后台任务：" + title, now, bot_id))
    conn.execute("INSERT INTO bot_workers (worker_id, bot_id, front_session, worker_session, title, goal, context, status, created_at) "
                 "VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?)", (wid, bot_id, front_session, sid, title, goal.strip()[:20000],
                                                               (context or "")[:20000] or None, now))
    conn.commit()
    return get(conn, wid)


def worker_prompt(w):
    text = "【后台任务】" + w["goal"]
    if w.get("context"):
        text += "\n\n背景（前台对话里整理的，不是完整聊天）：\n" + w["context"]
    return text


def set_status(conn, worker_id, status, **extra):
    sets = ["status = ?"]
    args = [status]
    for k, v in extra.items():
        if k in ("task_id", "result", "last_step", "started_at", "finished_at"):
            sets.append(f"{k} = ?")
            args.append(v)
    conn.execute(f"UPDATE bot_workers SET {', '.join(sets)} WHERE worker_id = ?", args + [worker_id])
    conn.commit()


def claim_report(conn, worker_id):
    cur = conn.execute("UPDATE bot_workers SET reported = 1 WHERE worker_id = ? AND reported = 0", (worker_id,))
    conn.commit()
    return cur.rowcount == 1


def summary_note(workers, limit=6):
    """前台上下文里的任务摘要：每个任务一行，不带 worker 的完整过程。"""
    rows = [w for w in workers if w["status"] in ACTIVE or (time.time() - (w["finished_at"] or 0)) < 6 * 3600][:limit]
    if not rows:
        return ""
    label = {"queued": "排队中", "running": "进行中", "completed": "已完成", "failed": "失败", "cancelled": "已停止",
             "interrupted": "中断", "limit_reached": "达到步数上限"}
    lines = []
    for w in rows:
        line = f"- {w['worker_id']}「{w['title']}」{label.get(w['status'], w['status'])}"
        if w["status"] in ACTIVE and w.get("last_step"):
            line += f"，最近一步：{w['last_step'][:80]}"
        if w["status"] not in ACTIVE and w.get("result"):
            line += "，结果摘要：" + " ".join(w["result"].split())[:160]
        lines.append(line)
    return ("\n\n[这个对话的后台任务（只是摘要）。用户在补充 / 修改进行中的任务 → task_message；要停 → task_stop；"
            "中断或失败要继续 → task_resume；无关的闲聊和提问直接回答，不要动后台任务]\n" + "\n".join(lines))


def result_text(w):
    head = {"completed": "✅ 后台任务完成", "failed": "⚠️ 后台任务失败", "cancelled": "⏹ 后台任务已停止",
            "limit_reached": "⚠️ 后台任务达到步数上限", "interrupted": "⚠️ 后台任务中断"}.get(w["status"], "后台任务结束")
    body = (w.get("result") or "").strip()
    if w["status"] == "interrupted" and not body:
        body = "服务器重启，任务没有做完。需要的话说一声「继续」，我会接着做（task_resume）。"
    return f"{head}：「{w['title']}」\n\n{body}".strip()


def last_answer(conn, session_id, since=0):
    r = conn.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'assistant' AND content IS NOT NULL "
                     "AND TRIM(content) != '' AND timestamp >= ? ORDER BY id DESC LIMIT 1", (session_id, since)).fetchone()
    return (r[0] if r else "")[:20000]


def post_result(conn, w):
    """把结果作为 Bot 的一条消息写进前台对话（只写一次）。返回是否写了。"""
    if not claim_report(conn, w["worker_id"]):
        return False
    text = result_text(w)
    meta = {"worker_id": w["worker_id"], "worker_status": w["status"]}
    try:
        import cloud_deliver
        items = cloud_deliver.copy_items_to_session(
            w["worker_session"], w["front_session"], cloud_deliver.items_from_session(w["worker_session"]), source="worker")
        items = cloud_deliver.merge_items(items, [], cloud_deliver.extract_links(text))
        if items:
            meta["deliverables"] = items
    except Exception as e:
        print(f"worker deliver propagate failed: {type(e).__name__}", flush=True)
    conn.execute("INSERT INTO messages (session_id, role, content, timestamp, meta) VALUES (?, 'assistant', ?, ?, ?)",
                 (w["front_session"], text, time.time(), json.dumps(meta, ensure_ascii=False)))
    conn.commit()
    return True


def recover(conn):
    """服务器重启：进行中 / 排队的任务如实标记。任务其实已经写完答案的算完成，否则标记中断并告诉用户。"""
    out = []
    for w in [_row(r) for r in conn.execute(f"SELECT {', '.join(COLS)} FROM bot_workers WHERE status IN ('queued', 'running')").fetchall()]:
        st = conn.execute("SELECT status FROM tasks WHERE task_id = ?", (w["task_id"],)).fetchone() if w["task_id"] else None
        status = "completed" if st and st[0] == "completed" else "interrupted"
        result = last_answer(conn, w["worker_session"], w["started_at"] or 0) if status == "completed" else None
        set_status(conn, w["worker_id"], status, result=result, finished_at=time.time())
        w.update(status=status, result=result)
        post_result(conn, w)
        out.append(w["worker_id"])
    return out
