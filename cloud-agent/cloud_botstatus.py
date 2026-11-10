# -*- coding: utf-8 -*-
"""首页 Bot 状态：由服务器真实状态（任务、待答卡片、未读、例行任务、静音）推出一个主状态。
优先级：需要你（待审批 / 待回答）> 出错 > 工作中 > 未读 > 空闲。例行任务、静音是附加标记，不抢主状态。"""

import json

FAILED = ("failed", "limit_reached", "interrupted")


def derive(d):
    """d 是 bot_detail 的输出。返回 {state, unread, flags}。"""
    unread = int(d.get("unread_count") or 0) + (1 if (d.get("prefs") or {}).get("unread") and not d.get("unread_count") else 0)
    if int(d.get("waiting_approvals") or 0) > 0 or int(d.get("pending_cards") or 0) > 0:
        state = "needs_you"
    elif d.get("last_task_status") in FAILED:
        state = "error"
    elif int(d.get("running_tasks") or 0) > 0 or int(d.get("queued_tasks") or 0) > 0 or int(d.get("running_workers") or 0) > 0:
        state = "working"
    elif unread > 0:
        state = "unread"
    else:
        state = "idle"
    flags = []
    if int(d.get("routine_running") or 0) > 0:
        flags.append("routine_running")
    elif int(d.get("routines_enabled") or 0) > 0:
        flags.append("routine_scheduled")
    if d.get("notify") is False:
        flags.append("muted")
    return {"state": state, "unread": unread, "flags": flags}


def pending_cards(conn, bot_id):
    """最近的选项卡片里还没回答的个数（只看最近 20 张，旧卡片不算）。"""
    rows = conn.execute("SELECT m.meta FROM messages m JOIN sessions s ON s.session_id = m.session_id "
                        "WHERE s.persona_id = ? AND m.role = 'assistant' AND m.meta LIKE '%\"choice\"%' "
                        "ORDER BY m.id DESC LIMIT 20", (bot_id,)).fetchall()
    n = 0
    for (meta,) in rows:
        try:
            choice = (json.loads(meta) or {}).get("choice") or {}
        except (ValueError, TypeError):
            continue
        if choice and not choice.get("answer"):
            n += 1
    return n


def fill(conn, out, visible_sql):
    """往 bot_detail 的输出里补上状态需要的字段。visible_sql 是“可见会话”的 SQL 条件（用 s. 前缀）。"""
    pid = out["persona_id"]
    seen = float((out.get("prefs") or {}).get("seen_at") or 0)
    out["unread_count"] = conn.execute(
        "SELECT COUNT(*) FROM messages m JOIN sessions s ON s.session_id = m.session_id WHERE s.persona_id = ? AND " + visible_sql +
        " AND m.role = 'assistant' AND m.content IS NOT NULL AND m.content != '' AND m.timestamp > ?", (pid, seen + 0.5)).fetchone()[0]
    out["pending_cards"] = pending_cards(conn, pid)
    last = conn.execute("SELECT t.status FROM tasks t JOIN sessions s ON s.session_id = t.session_id WHERE s.persona_id = ? AND " + visible_sql +
                        " AND t.status NOT IN ('running', 'queued', 'waiting_user') ORDER BY t.created_at DESC LIMIT 1", (pid,)).fetchone()
    out["last_task_status"] = last[0] if last else None
    out["routine_running"] = conn.execute(
        "SELECT COUNT(*) FROM routine_runs r JOIN routines t ON t.routine_id = r.routine_id WHERE t.persona_id = ? AND r.status IN ('running', 'waiting_user')",
        (pid,)).fetchone()[0]
    out["status"] = derive(out)
    return out
