"""交班卡：把最近 N 小时各 Bot 的对话、没做完的任务、未收回的授权、待盯事项汇总成一张卡（不调模型，纯查库，数字可核对）。"""
import json
import time

import cloud_runmodel

MAX_HOURS = 48
EXCERPT = 80


def text_of(content):
    """消息内容可能是 message_parts JSON：只取文字"""
    c = content or ""
    if c.startswith("["):
        try:
            parts = json.loads(c)
            c = "\n".join(p.get("text", "") for p in parts if isinstance(p, dict) and p.get("type") == "text")
        except (ValueError, AttributeError):
            pass
    return c.strip()


def conclusion(content):
    """一句话结论优先，否则取第一行"""
    t = text_of(content)
    head, _ = cloud_runmodel.split_one_line(t)
    line = head or next((x.strip() for x in t.splitlines() if x.strip()), "")
    return line[:EXCERPT]


HANDOFF_UTTERANCES = ("交班", "交班卡", "开始交班", "/交班")


def is_utterance(text):
    t = (text or "").strip()
    if t in HANDOFF_UTTERANCES:
        return True
    # 「交班」单独成句，后面最多跟一个标点
    if t.startswith("交班") and t[2:].strip("。.!！？?，, ") == "":
        return True
    return False


def _table_exists(conn, name):
    r = conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone()
    return bool(r)


def collect_approvals(conn):
    """待批准的审批卡 + 尚未收回的长期授权（standing_grants）。"""
    pending, grants = [], []
    if _table_exists(conn, "approvals"):
        rows = conn.execute(
            "SELECT approval_id, tool, reason, status, created_at, task_id FROM approvals "
            "WHERE status = 'pending' ORDER BY created_at DESC LIMIT 40"
        ).fetchall()
        for r in rows:
            pending.append({"approval_id": r[0], "tool": r[1] or "", "reason": (r[2] or "")[:80],
                            "status": r[3], "created_at": r[4], "task_id": r[5]})
    if _table_exists(conn, "app_settings"):
        row = conn.execute("SELECT value FROM app_settings WHERE name = 'standing_grants'").fetchone()
        if row:
            try:
                items = json.loads(row[0]) or []
            except (ValueError, TypeError):
                items = []
            for g in items:
                if not isinstance(g, dict) or g.get("revoked_at"):
                    continue
                grants.append({
                    "grant_id": g.get("grant_id") or g.get("id") or "",
                    "bot_id": g.get("bot_id") or "",
                    "bot_name": g.get("bot_name") or "",
                    "tool": g.get("tool") or "",
                    "reason": (g.get("reason") or "")[:80],
                    "created_at": g.get("created_at") or 0,
                    "scope": g.get("scope") or "standing",
                })
    return pending, grants


def collect_watch(conn):
    """待盯事项：已开启的例行任务（尤其是监控类）以及还在跑的任务。"""
    items = []
    if _table_exists(conn, "routines"):
        cols = {r[1] for r in conn.execute("PRAGMA table_info(routines)").fetchall()}
        name_col = "name" if "name" in cols else None
        if name_col:
            q = "SELECT routine_id, name, prompt, enabled, last_status, persona_id FROM routines WHERE enabled = 1 LIMIT 40"
            if "persona_id" not in cols:
                q = "SELECT routine_id, name, prompt, enabled, last_status, NULL FROM routines WHERE enabled = 1 LIMIT 40"
            for r in conn.execute(q).fetchall():
                prompt = r[2] or ""
                title = r[1] or "例行任务"
                items.append({
                    "kind": "routine",
                    "id": r[0],
                    "title": title[:40],
                    "detail": (prompt.splitlines()[0] if prompt else "")[:80],
                    "last_status": r[4],
                    "bot_id": r[5],
                    "monitor": any(w in (title + prompt) for w in ("盯", "监控", "有变化", "monitor", "watch")),
                })
    if _table_exists(conn, "tasks"):
        rows = conn.execute(
            "SELECT task_id, session_id, status, created_at FROM tasks "
            "WHERE status IN ('running', 'queued', 'waiting_user') ORDER BY created_at DESC LIMIT 20"
        ).fetchall()
        for r in rows:
            items.append({"kind": "task", "id": r[0], "session_id": r[1], "title": "未完成任务",
                          "detail": r[2], "created_at": r[3]})
    return items


def build(conn, hours, bot_of, now=None, skip_session=None):
    """bot_of(session_id) -> {"bot_id","name"} 或 None（主 Bot）；skip_session(session_id) -> True 的（无痕）不进卡"""
    hours = max(1, min(MAX_HOURS, int(hours)))
    now = now or time.time()
    since = now - hours * 3600
    rows = conn.execute(
        "SELECT session_id, COUNT(*), MAX(timestamp) FROM messages WHERE timestamp >= ? AND role IN ('user','assistant') "
        "GROUP BY session_id ORDER BY MAX(timestamp) DESC", (since,)).fetchall()
    groups = {}
    for sid, n, last_ts in rows:
        if skip_session and skip_session(sid):
            continue
        bot = bot_of(sid) or {}
        key = bot.get("bot_id") or "main"
        g = groups.setdefault(key, {"bot_id": bot.get("bot_id"), "bot_name": bot.get("name") or "主 Bot",
                                    "sessions": 0, "messages": 0, "last_at": last_ts, "items": []})
        g["sessions"] += 1
        g["messages"] += n
        g["last_at"] = max(g["last_at"], last_ts)
        title = (conn.execute("SELECT title FROM sessions WHERE session_id = ?", (sid,)).fetchone() or [""])[0] or "对话"
        last = conn.execute("SELECT role, content FROM messages WHERE session_id = ? AND role IN ('user','assistant') "
                            "ORDER BY id DESC LIMIT 1", (sid,)).fetchone()
        task = conn.execute("SELECT status FROM tasks WHERE session_id = ? ORDER BY created_at DESC LIMIT 1", (sid,)).fetchone()
        status = task[0] if task else None
        if status in ("running", "queued"):
            state = "running"
        elif status == "waiting_user":
            state = "waiting_you"
        elif last and last[0] == "user":
            state = "unanswered"
        else:
            state = "done"
        g["items"].append({"session_id": sid, "title": title[:40], "state": state,
                           "conclusion": conclusion(last[1]) if last and last[0] == "assistant" else "",
                           "last_user": text_of(last[1])[:EXCERPT] if last and last[0] == "user" else ""})
    bots = sorted(groups.values(), key=lambda g: -g["last_at"])
    count = lambda s: sum(1 for g in bots for i in g["items"] if i["state"] == s)
    pending, grants = collect_approvals(conn)
    watch = collect_watch(conn)
    unfinished = count("running") + count("waiting_you") + count("unanswered")
    return {"hours": hours, "since": since, "generated_at": now, "bots": bots,
            "approvals": pending, "grants": grants, "watch": watch,
            "totals": {"sessions": sum(g["sessions"] for g in bots), "running": count("running"),
                       "waiting_you": count("waiting_you"), "unanswered": count("unanswered"),
                       "unfinished": unfinished, "approvals": len(pending), "grants": len(grants),
                       "watch": len(watch)}}
