"""值班模式的「错过了什么」：值班期间不推送的主动消息、照常推送但用户顾不上看的通知，都先攒起来；
下班（duty_until 到点或用户提前关掉）时汇总成一条「下夜班了：值班期间错过了什么」，推一次、进 App 通知流，
App 里可以随时再看最近一份。只存标题和截短的正文（推送前已经脱敏），上锁 Bot 只记「已上锁的 Bot」。"""
import json
import time

MAX_BODY = 160
MAX_ITEMS = 40


def ensure_schema(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS duty_missed (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, "
                  "kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', bot_id TEXT, session_id TEXT, "
                  "suppressed INTEGER NOT NULL DEFAULT 0)")
    conn.execute("CREATE TABLE IF NOT EXISTS duty_digests (id INTEGER PRIMARY KEY AUTOINCREMENT, started REAL NOT NULL, "
                  "ended REAL NOT NULL, count INTEGER NOT NULL, text TEXT NOT NULL, items TEXT NOT NULL, created_at REAL NOT NULL)")


def record(conn, kind, title, body, bot_id=None, session_id=None, suppressed=False, now=None):
    conn.execute("INSERT INTO duty_missed (ts, kind, title, body, bot_id, session_id, suppressed) VALUES (?, ?, ?, ?, ?, ?, ?)",
                 (now or time.time(), kind, (title or "")[:120], (body or "").strip()[:MAX_BODY], bot_id, session_id, 1 if suppressed else 0))


def _hm(ts):
    return time.strftime("%H:%M", time.localtime(ts))


def compose(started, ended, items):
    """items：[{ts, kind, title, body, suppressed}]，按时间顺序"""
    head = f"值班期间（{_hm(started)}–{_hm(ended)}）"
    if not items:
        return head + "没有错过什么。"
    held = [i for i in items if i["suppressed"]]
    lines = [head + f"一共 {len(items)} 条" + (f"，其中 {len(held)} 条主动消息当时没推送" if held else "") + "："]
    for i in items[:12]:
        body = i["body"].replace("\n", " ")
        lines.append(f"· {_hm(i['ts'])} {i['title']}" + (f"：{body[:60]}" if body else ""))
    if len(items) > 12:
        lines.append(f"…还有 {len(items) - 12} 条，打开 App 查看")
    return "\n".join(lines)


def finish(conn, started, ended, now=None):
    """把 [started, ended] 之间攒下的条目汇总成一份并清掉；返回 digest dict"""
    rows = conn.execute("SELECT ts, kind, title, body, bot_id, session_id, suppressed FROM duty_missed WHERE ts >= ? AND ts <= ? "
                        "ORDER BY ts ASC LIMIT ?", (started - 1, ended + 1, MAX_ITEMS)).fetchall()
    items = [{"ts": r[0], "kind": r[1], "title": r[2], "body": r[3], "bot_id": r[4], "session_id": r[5], "suppressed": bool(r[6])} for r in rows]
    text = compose(started, ended, items)
    conn.execute("DELETE FROM duty_missed WHERE ts <= ?", (ended + 1,))
    cur = conn.execute("INSERT INTO duty_digests (started, ended, count, text, items, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                       (started, ended, len(items), text, json.dumps(items, ensure_ascii=False), now or time.time()))
    conn.execute("DELETE FROM duty_digests WHERE id NOT IN (SELECT id FROM duty_digests ORDER BY id DESC LIMIT 10)")
    return {"id": cur.lastrowid, "started": started, "ended": ended, "count": len(items), "text": text, "items": items}


def latest(conn):
    r = conn.execute("SELECT id, started, ended, count, text, items, created_at FROM duty_digests ORDER BY id DESC LIMIT 1").fetchone()
    if not r:
        return None
    return {"id": r[0], "started": r[1], "ended": r[2], "count": r[3], "text": r[4], "items": json.loads(r[5]), "created_at": r[6]}


def transition(state, duty_until, now):
    """值班状态机。state：{"active", "started", "until"}。返回 (新 state, 要汇总的 (started, ended) 或 None)"""
    state = dict(state or {})
    on = float(duty_until or 0) > now
    if on:
        if not state.get("active"):
            state = {"active": True, "started": now, "until": float(duty_until)}
        else:
            state["until"] = float(duty_until)
        return state, None
    if state.get("active"):
        started = float(state.get("started") or now)
        # 用户手动关掉（0）→ 现在下班；到点自然结束 → 下班时间是 duty_until
        ended = now if float(duty_until or 0) <= 0 else max(started, min(now, float(duty_until)))
        return {"active": False, "started": started, "until": ended}, (started, ended)
    return state, None
