"""工作台：一屏看所有 Bot 正在跑 / 等你的任务（纯查库）。不估「还要多久」——没有可靠依据，只给已用时间和步数。"""
import json
import time

RECENT_S = 24 * 3600


def items(conn, bot_of, title_of, now=None):
    now = now or time.time()
    rows = conn.execute("SELECT task_id, session_id, status, created_at FROM tasks WHERE status IN ('running','waiting_user') "
                        "AND created_at >= ? ORDER BY created_at ASC", (now - RECENT_S,)).fetchall()
    out = []
    for tid, sid, status, created in rows:
        bot = bot_of(sid) or {}
        steps = conn.execute("SELECT COUNT(*) FROM task_events WHERE task_id = ? AND event_type = 'tool_call'", (tid,)).fetchone()[0]
        last = conn.execute("SELECT payload FROM task_events WHERE task_id = ? AND event_type = 'tool_call' ORDER BY id DESC LIMIT 1",
                            (tid,)).fetchone()
        tool = ""
        if last:
            try:
                tool = (json.loads(last[0] or "{}") or {}).get("tool") or ""
            except (ValueError, AttributeError):
                tool = ""
        out.append({"task_id": tid, "session_id": sid, "status": status, "bot_id": bot.get("bot_id"),
                    "bot_name": bot.get("name") or "主 Bot", "title": (title_of(sid) or "对话")[:40],
                    "started_at": created, "elapsed_s": max(0, int(now - (created or now))), "steps": steps, "last_tool": tool})
    return out
