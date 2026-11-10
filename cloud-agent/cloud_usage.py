"""用量统计：按天 × Bot × 模型记录 token；每日上限与接近上限提醒。"""
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS usage_daily (
    day TEXT NOT NULL,
    bot_id TEXT NOT NULL,
    model TEXT NOT NULL,
    prompt_tokens INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    calls INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, bot_id, model)
)
"""


def ensure_schema(conn):
    conn.execute(SCHEMA)
    conn.commit()


def today(ts=None):
    return time.strftime("%Y-%m-%d", time.localtime(ts if ts is not None else time.time()))


def estimate(text):
    if not text:
        return 0
    s = text if isinstance(text, str) else str(text)
    cjk = sum(1 for ch in s if "\u4e00" <= ch <= "\u9fff")
    return cjk + (len(s) - cjk) // 4 + 1


def record(conn, bot_id, model, prompt_tokens, completion_tokens, ts=None):
    conn.execute("INSERT INTO usage_daily (day, bot_id, model, prompt_tokens, completion_tokens, calls) VALUES (?, ?, ?, ?, ?, 1) "
                 "ON CONFLICT(day, bot_id, model) DO UPDATE SET prompt_tokens = prompt_tokens + excluded.prompt_tokens, "
                 "completion_tokens = completion_tokens + excluded.completion_tokens, calls = calls + 1",
                 (today(ts), bot_id or "", model or "", int(prompt_tokens or 0), int(completion_tokens or 0)))
    conn.commit()


def usage_from_response(resp, request_messages=None, reply_text=None):
    """优先用服务商返回的 usage；没有时按字数估算。"""
    u = (resp or {}).get("usage") or {}
    p = u.get("prompt_tokens") or u.get("input_tokens")
    c = u.get("completion_tokens") or u.get("output_tokens")
    if p is None and c is None:
        p = sum(estimate(m.get("content")) for m in (request_messages or []))
        c = estimate(reply_text)
    return int(p or 0), int(c or 0)


def total_for_day(conn, day=None):
    r = conn.execute("SELECT COALESCE(SUM(prompt_tokens + completion_tokens), 0) FROM usage_daily WHERE day = ?", (day or today(),)).fetchone()
    return int(r[0] or 0)


def summary(conn, days=14):
    since = today(time.time() - (max(1, days) - 1) * 86400)
    rows = conn.execute("SELECT day, bot_id, model, prompt_tokens, completion_tokens, calls FROM usage_daily WHERE day >= ? "
                        "ORDER BY day ASC, bot_id ASC, model ASC", (since,)).fetchall()
    items = [{"day": r[0], "bot_id": r[1], "model": r[2], "prompt_tokens": r[3], "completion_tokens": r[4],
              "total_tokens": r[3] + r[4], "calls": r[5]} for r in rows]
    by_day, by_bot, by_model = {}, {}, {}
    for it in items:
        by_day[it["day"]] = by_day.get(it["day"], 0) + it["total_tokens"]
        by_bot[it["bot_id"]] = by_bot.get(it["bot_id"], 0) + it["total_tokens"]
        by_model[it["model"]] = by_model.get(it["model"], 0) + it["total_tokens"]
    return {"items": items, "by_day": by_day, "by_bot": by_bot, "by_model": by_model, "today": today(),
            "today_total": total_for_day(conn)}


class CapState:
    """每天只提醒一次：接近上限（alert_percent）与达到上限各一次。"""

    def __init__(self):
        self.sent = set()

    def check(self, used, cap, alert_percent, day=None):
        """返回 (blocked, alert_kind or None)。cap=0 不限。"""
        if not cap:
            return False, None
        day = day or today()
        kind = None
        if used >= cap:
            if (day, "cap") not in self.sent:
                self.sent.add((day, "cap"))
                kind = "cap"
            return True, kind
        if alert_percent and used >= cap * alert_percent / 100 and (day, "near") not in self.sent:
            self.sent.add((day, "near"))
            kind = "near"
        return False, kind
