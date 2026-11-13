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

import cloud_deliver

SOFT_CAP = 4
ID_RE = re.compile(r"^wk_[a-f0-9]{10}$")
ACTIVE = ("queued", "running")
OPEN = ("queued", "running", "paused")  # 托盘里仍要展示（暂停后可继续）
TERMINAL = ("completed", "failed", "cancelled", "interrupted", "limit_reached")
COLS = ("worker_id", "bot_id", "front_session", "worker_session", "task_id", "title", "goal", "context", "status",
        "result", "last_step", "reported", "created_at", "started_at", "finished_at",
        "stop_reason", "pause_requested", "checkpoint", "runtime")


class WorkerError(ValueError):
    pass


def ensure_schema(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS bot_workers (worker_id TEXT PRIMARY KEY, bot_id TEXT, front_session TEXT NOT NULL, "
                 "worker_session TEXT NOT NULL, task_id TEXT, title TEXT NOT NULL, goal TEXT NOT NULL, context TEXT, "
                 "status TEXT NOT NULL, result TEXT, last_step TEXT, reported INTEGER NOT NULL DEFAULT 0, "
                 "created_at REAL NOT NULL, started_at REAL, finished_at REAL, "
                 "stop_reason TEXT, pause_requested INTEGER NOT NULL DEFAULT 0, checkpoint TEXT, runtime TEXT)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_bot_workers_front ON bot_workers(front_session, created_at)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_bot_workers_session ON bot_workers(worker_session)")
    if "client_nonce" not in {row[1] for row in conn.execute("PRAGMA table_info(bot_workers)")}:
        conn.execute("ALTER TABLE bot_workers ADD COLUMN client_nonce TEXT")
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_bot_workers_nonce ON bot_workers(front_session, client_nonce) "
                 "WHERE client_nonce IS NOT NULL")
    cols = {row[1] for row in conn.execute("PRAGMA table_info(bot_workers)")}
    for name, decl in (
        ("stop_reason", "TEXT"),
        ("pause_requested", "INTEGER NOT NULL DEFAULT 0"),
        ("checkpoint", "TEXT"),
        ("runtime", "TEXT"),
    ):
        if name not in cols:
            conn.execute(f"ALTER TABLE bot_workers ADD COLUMN {name} {decl}")
    conn.commit()


def _row(r):
    if not r:
        return None
    d = dict(zip(COLS, r))
    d["reported"] = bool(d["reported"])
    d["pause_requested"] = bool(d.get("pause_requested"))
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


def create(conn, bot_id, front_session, goal, context=None, title=None, client_nonce=None):
    if not isinstance(goal, str) or not goal.strip():
        raise WorkerError("goal 不能为空")
    if context is not None and not isinstance(context, str):
        raise WorkerError("context 必须是字符串")
    wid = "wk_" + uuid.uuid4().hex[:10]
    sid = "sess_" + uuid.uuid4().hex[:12]
    title = (title if isinstance(title, str) and title.strip() else goal.strip().splitlines()[0])[:60]
    now = time.time()
    with conn:
        if client_nonce:
            conn.execute("BEGIN IMMEDIATE")
            existing = conn.execute("SELECT worker_id FROM bot_workers WHERE front_session = ? AND client_nonce = ?",
                                    (front_session, client_nonce)).fetchone()
            if existing:
                return get(conn, existing[0])
        conn.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, NULL, ?, '', ?, ?)",
                     (sid, "后台任务：" + title, now, bot_id))
        conn.execute("INSERT INTO bot_workers (worker_id, bot_id, front_session, worker_session, title, goal, context, status, created_at, client_nonce) "
                     "VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?)", (wid, bot_id, front_session, sid, title, goal.strip()[:20000],
                                                                     (context or "")[:20000] or None, now, client_nonce))
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
        if k in ("task_id", "result", "last_step", "started_at", "finished_at", "stop_reason", "pause_requested", "checkpoint", "runtime"):
            sets.append(f"{k} = ?")
            args.append(v)
    conn.execute(f"UPDATE bot_workers SET {', '.join(sets)} WHERE worker_id = ?", args + [worker_id])
    conn.commit()


def summary_note(workers, limit=6):
    """前台上下文里的任务摘要：每个任务一行，不带 worker 的完整过程。"""
    rows = [w for w in workers if w["status"] in OPEN or (time.time() - (w["finished_at"] or 0)) < 6 * 3600][:limit]
    if not rows:
        return ""
    label = {"queued": "排队中", "running": "进行中", "paused": "已暂停", "completed": "已完成", "failed": "失败", "cancelled": "已停止",
             "interrupted": "中断", "limit_reached": "达到步数上限"}
    lines = []
    for w in rows:
        line = f"- {w['worker_id']}「{w['title']}」{label.get(w['status'], w['status'])}"
        if w["status"] in OPEN and w.get("last_step"):
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


def post_result(conn, w, defer_while_front_active=False):
    """原子交付一条结果。None 表示前台还在回话，稍后再试。"""
    with conn:
        conn.execute("BEGIN IMMEDIATE")
        current = get(conn, w["worker_id"])
        if (not current or current["reported"] or current["status"] in OPEN
                or current["finished_at"] != w["finished_at"]):
            return False
        if defer_while_front_active and conn.execute(
                "SELECT 1 FROM tasks WHERE session_id = ? AND status IN ('queued', 'running', 'waiting_user')",
                (current["front_session"],)).fetchone():
            return None
        front = conn.execute("SELECT incognito FROM sessions WHERE session_id = ?",
                             (current["front_session"],)).fetchone()
        if not front:
            return False
        text = result_text(current)
        meta = {"worker_id": current["worker_id"], "worker_status": current["status"],
                "worker_title": current["title"]}
        if current["status"] == "completed":
            pending = {"page", "reminder_draft", "shortcut_draft"}
            rows = conn.execute(
                "SELECT meta FROM messages WHERE session_id = ? AND role = 'assistant' "
                "AND timestamp >= ? AND meta IS NOT NULL ORDER BY id DESC",
                (current["worker_session"], current["started_at"] or 0),
            )
            for (raw,) in rows:
                try:
                    row = json.loads(raw)
                except (ValueError, TypeError):
                    continue
                if isinstance(row, dict):
                    for key in pending.intersection(row):
                        meta[key] = row[key]
                        pending.remove(key)
                if not pending:
                    break
            try:
                source_items = [] if front[0] else cloud_deliver.items_from_session(
                    current["worker_session"], since=current["started_at"] or current["created_at"])
                items = cloud_deliver.copy_items_to_session(
                    current["worker_session"], current["front_session"], source_items, source="worker")
                if items:
                    meta["deliverables"] = items
            except (OSError, ValueError) as e:
                print(f"worker deliver propagate failed: {type(e).__name__}", flush=True)
        conn.execute("INSERT INTO messages (session_id, role, content, timestamp, meta) VALUES (?, 'assistant', ?, ?, ?)",
                     (current["front_session"], text, time.time(),
                      json.dumps(meta, ensure_ascii=False)))
        conn.execute("UPDATE bot_workers SET reported = 1 WHERE worker_id = ?", (current["worker_id"],))
        return True


def restore_tool_rows(conn, session_id, rows):
    """Repair a crash between recording a result event and saving its tool row.

    This only reconstructs model history; it never executes a tool or creates
    evidence. An unknown outcome stays explicitly unknown for manual recovery.
    """
    output, consumed = [], set()
    for index, row in enumerate(rows):
        if index in consumed:
            continue
        output.append(row)
        role, content, raw_calls, call_id, meta, stamp = row
        if role != "assistant" or not raw_calls:
            continue
        try:
            calls = json.loads(raw_calls)
        except (ValueError, TypeError):
            continue
        if not isinstance(calls, list):
            continue
        end = next((i for i in range(index + 1, len(rows)) if rows[i][0] == "assistant"), len(rows))
        upper = rows[end][5] if end < len(rows) else float("inf")
        stored = {rows[i][3]: i for i in range(index + 1, end) if rows[i][0] == "tool"}
        events = None
        for call in calls:
            if not isinstance(call, dict):
                continue
            cid = call.get("id")
            if not cid:
                continue
            if cid in stored:
                consumed.add(stored[cid])
                output.append(rows[stored[cid]])
                continue
            if events is None:
                events = {}
                for (raw,) in conn.execute("SELECT e.payload FROM task_events e JOIN tasks t ON t.task_id=e.task_id "
                        "WHERE t.session_id=? AND e.event_type='tool_result' AND e.timestamp>=? AND e.timestamp<=? ORDER BY e.id",
                        (session_id, stamp, upper)):
                    try:
                        event = json.loads(raw)
                        if event.get("id") and "result" in event:
                            events.setdefault(event["id"], event["result"])
                    except (ValueError, TypeError, AttributeError):
                        continue
            result = events.get(cid, {"status": "unknown", "needs_state_check": True,
                "error": "服务在记录工具结果前中断。先核对实际状态，不能直接重放可能有副作用的操作。"})
            text = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
            output.append(("tool", text, None, cid, None, stamp))
    return output


def recover(conn, post_prompt=None):
    """服务器重启：已经写出答案的算完成；其余进行中 / 排队的任务改成暂停并保存进度，
    通过 post_prompt(conn, worker) 在前台对话里问用户要不要继续（不要只靠用户在聊天里说「继续」）。
    同一任务不会因为重复调用而再发一张卡（checkpoint 里记了 asked）。
    """
    out = []
    for w in [_row(r) for r in conn.execute(
            f"SELECT {', '.join(COLS)} FROM bot_workers WHERE status IN ('queued', 'running')"
    ).fetchall()]:
        st = conn.execute("SELECT status FROM tasks WHERE task_id = ?", (w["task_id"],)).fetchone() if w["task_id"] else None
        strict = conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='worker_workorders'").fetchone()
        verified = None
        if strict:
            verified = conn.execute("SELECT verification FROM worker_workorders WHERE worker_id=?", (w["worker_id"],)).fetchone()
        if st and st[0] == "completed" and (not verified or verified[0] == "verified"):
            result = last_answer(conn, w["worker_session"], w["started_at"] or 0)
            set_status(conn, w["worker_id"], "completed", result=result, finished_at=time.time(),
                       stop_reason=None, pause_requested=0)
            w.update(status="completed", result=result)
            post_result(conn, w)
            out.append(w["worker_id"])
            continue
        if w["task_id"]:
            conn.execute(
                "UPDATE tasks SET status = 'paused' WHERE task_id = ? AND status IN ('running', 'queued', 'waiting_user')",
                (w["task_id"],),
            )
        cp = load_checkpoint(w) or {}
        cp.update({"reason": "restart", "task_id": w.get("task_id"), "saved_at": time.time()})
        if verified:
            calls, results, background = set(), set(), set()
            for kind, payload in conn.execute("SELECT event_type,payload FROM task_events WHERE task_id=? "
                                               "AND event_type IN ('tool_call','tool_result')", (w.get("task_id"),)):
                try:
                    event = json.loads(payload)
                    event_id = event.get("id")
                    result = event.get("result")
                    if kind == "tool_result" and isinstance(result, dict):
                        if result.get("status") == "started" and result.get("job_id"):
                            background.add(result["job_id"])
                        for job in result.get("jobs", []) if isinstance(result.get("jobs"), list) else []:
                            if isinstance(job, dict) and job.get("status") == "finished":
                                background.discard(job.get("job_id"))
                except (ValueError, AttributeError):
                    event_id = None
                if event_id:
                    (calls if kind == "tool_call" else results).add(event_id)
            cp["safe_resume"] = not bool(calls - results or background)
            cp["uncertain_calls"] = sorted(calls - results)
            cp["uncertain_background_jobs"] = sorted(background)
        set_status(conn, w["worker_id"], "paused", stop_reason="restart", pause_requested=0,
                   checkpoint=json.dumps(cp, ensure_ascii=False), finished_at=None)
        w = get(conn, w["worker_id"])
        if post_prompt and not cp.get("asked"):
            try:
                post_prompt(conn, w)
                cp["asked"] = True
                conn.execute("UPDATE bot_workers SET checkpoint = ? WHERE worker_id = ?",
                             (json.dumps(cp, ensure_ascii=False), w["worker_id"]))
                conn.commit()
            except Exception:
                pass
        out.append(w["worker_id"])
    # 已完成但在等前台回话的结果也会在重启后补交。
    pending = conn.execute(f"SELECT {', '.join(COLS)} FROM bot_workers WHERE reported = 0 "
                           "AND status NOT IN ('queued', 'running', 'paused') ORDER BY finished_at, created_at").fetchall()
    for row in pending:
        post_result(conn, _row(row))
    return out


def load_checkpoint(w):
    raw = (w or {}).get("checkpoint")
    if not raw:
        return None
    try:
        d = json.loads(raw)
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def save_checkpoint(conn, worker_id, data):
    conn.execute("UPDATE bot_workers SET checkpoint = ? WHERE worker_id = ?",
                 (json.dumps(data, ensure_ascii=False), worker_id))
    conn.commit()


def public_runtime(model, provider):
    """只保存恢复任务所需的非机密字段（模型名、凭据代号、协议），不要 API Key。"""
    provider = provider if isinstance(provider, dict) else {}
    out = {"model": model or ""}
    for k in ("credential", "protocol"):
        v = provider.get(k)
        if isinstance(v, str) and v:
            out[k] = v
    return out


def set_runtime(conn, worker_id, model, provider):
    conn.execute("UPDATE bot_workers SET runtime = ? WHERE worker_id = ?",
                 (json.dumps(public_runtime(model, provider), ensure_ascii=False), worker_id))
    conn.commit()


def request_pause(conn, worker_id):
    """排队中的任务立刻暂停；运行中的打上标记，等当前工具跑完（安全点）再停。"""
    w = get(conn, worker_id)
    if not w:
        return None
    if w["status"] == "queued":
        set_status(conn, worker_id, "paused", stop_reason="user", pause_requested=0)
        return get(conn, worker_id)
    if w["status"] == "running":
        set_status(conn, worker_id, "running", pause_requested=1, stop_reason=None)
        return get(conn, worker_id)
    return w


def park(conn, worker_id, reason, checkpoint=None):
    """在安全点把运行中的任务改成暂停，并保存检查点。"""
    w = get(conn, worker_id)
    if not w:
        return None
    data = checkpoint if isinstance(checkpoint, dict) else (load_checkpoint(w) or {})
    data.update({"reason": reason, "task_id": w.get("task_id"), "saved_at": time.time()})
    if w.get("task_id"):
        conn.execute(
            "UPDATE tasks SET status = 'paused' WHERE task_id = ? AND status IN ('running', 'waiting_user')",
            (w["task_id"],),
        )
    set_status(conn, worker_id, "paused", stop_reason=reason, pause_requested=0,
               checkpoint=json.dumps(data, ensure_ascii=False), finished_at=None)
    return get(conn, worker_id)


def can_retry(status):
    return status in ("failed", "cancelled", "interrupted", "limit_reached")
