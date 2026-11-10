"""交班卡：把最近 N 小时各 Bot 的对话、没做完的任务、等你回复的问题汇总成一张卡（不调模型，纯查库，数字可核对）。"""
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
    return {"hours": hours, "since": since, "generated_at": now, "bots": bots,
            "totals": {"sessions": sum(g["sessions"] for g in bots), "running": count("running"),
                       "waiting_you": count("waiting_you"), "unanswered": count("unanswered")}}
