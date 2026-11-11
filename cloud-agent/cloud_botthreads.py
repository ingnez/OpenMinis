"""Bot 之间的对话线程（参照 Grok Bot）：每一对 Bot 一条只读线程。

每次 send_to_bot / delegate_task 记一条「发出」消息，委托结束时记一条「回复」消息，存在 bot_thread_messages，
带发送方、接收方、时间、优先级，以及对应的委托 / 任务 / 会话编号（App 里的卡片据此跳转）。
旧数据从 bot_delegations 补齐（幂等）。这里只做数据库读写和文字整理，不碰模型和网络。
"""
import json
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS bot_thread_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pair TEXT NOT NULL,
    sender TEXT NOT NULL,
    recipient TEXT NOT NULL,
    text TEXT NOT NULL,
    ts REAL NOT NULL,
    priority TEXT DEFAULT 'normal',
    kind TEXT,                -- message / task / result
    status TEXT,
    delegation_id TEXT,
    task_id TEXT,
    session_id TEXT,
    UNIQUE (delegation_id, kind)
)
"""
PREVIEW_CHARS = 80
MAIN = "_main"        # 没有 Bot 身份的会话（主助手）在线程里用这个编号


def ensure_schema(conn):
    conn.execute(SCHEMA)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_btm_pair ON bot_thread_messages(pair, id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_btm_sender ON bot_thread_messages(sender, id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_btm_recipient ON bot_thread_messages(recipient, id)")
    backfill(conn)
    conn.commit()


def norm(bot_id):
    return bot_id or MAIN


def pair_key(a, b):
    a, b = norm(a), norm(b)
    return "|".join(sorted((a, b)))


def record(conn, sender, recipient, text, kind, delegation_id=None, priority="normal", status=None,
           task_id=None, session_id=None, ts=None):
    """记一条线程消息；同一次委托的同一类消息只记一次。返回新 id（重复时返回已有 id）。"""
    sender, recipient = norm(sender), norm(recipient)
    text = (text or "").strip() or "（没有文字）"
    cur = conn.execute(
        "INSERT OR IGNORE INTO bot_thread_messages (pair, sender, recipient, text, ts, priority, kind, status, delegation_id, task_id, session_id) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (pair_key(sender, recipient), sender, recipient, text[:20000], ts or time.time(), priority or "normal", kind, status,
         delegation_id, task_id, session_id))
    if cur.rowcount:
        return cur.lastrowid
    row = conn.execute("SELECT id FROM bot_thread_messages WHERE delegation_id = ? AND kind = ?", (delegation_id, kind)).fetchone()
    return row[0] if row else None


def set_status(conn, delegation_id, status):
    conn.execute("UPDATE bot_thread_messages SET status = ? WHERE delegation_id = ? AND kind != 'result'", (status, delegation_id))


def backfill(conn):
    rows = conn.execute("SELECT delegation_id, kind, from_bot, to_bot, content, priority, status, result, created_at, finished_at, to_task, to_session "
                        "FROM bot_delegations d WHERE NOT EXISTS (SELECT 1 FROM bot_thread_messages m WHERE m.delegation_id = d.delegation_id)").fetchall()
    for did, kind, fb, tb, content, prio, status, result, created, finished, ttask, tsess in rows:
        record(conn, fb, tb, content, kind, did, prio, status, ttask, tsess, created)
        if status not in (None, "running") and result and kind == "task":
            record(conn, tb, fb, result, "result", did, prio, status, ttask, tsess, finished or created)


def _row(r):
    keys = ("id", "pair", "sender", "recipient", "text", "ts", "priority", "kind", "status", "delegation_id", "task_id", "session_id")
    return dict(zip(keys, r))


COLS = "id, pair, sender, recipient, text, ts, priority, kind, status, delegation_id, task_id, session_id"


def preview_text(viewer, msg, names):
    """首页列表的预览：自己发出的「➤ 已发消息给 X：…」，收到的「← 来自 X：…」。"""
    one = " ".join(str(msg["text"]).split())
    one = one[:PREVIEW_CHARS] + ("…" if len(one) > PREVIEW_CHARS else "")
    if msg["sender"] == norm(viewer):
        return f"➤ 已发消息给 {names.get(msg['recipient'], msg['recipient'])}：{one}"
    return f"← 来自 {names.get(msg['sender'], msg['sender'])}：{one}"


def latest_for(conn, bot_id):
    r = conn.execute(f"SELECT {COLS} FROM bot_thread_messages WHERE sender = ? OR recipient = ? ORDER BY id DESC LIMIT 1",
                     (norm(bot_id), norm(bot_id))).fetchone()
    return _row(r) if r else None


def threads(conn, bot_id=None, names=None, limit=100):
    """线程列表：每对 Bot 一条，带最后一条消息、条数、是否有人正在处理。bot_id 给定时只列它参与的。"""
    names = names or {}
    if bot_id:
        b = norm(bot_id)
        rows = conn.execute("SELECT pair, MAX(id), COUNT(*) FROM bot_thread_messages WHERE sender = ? OR recipient = ? GROUP BY pair "
                            "ORDER BY MAX(id) DESC LIMIT ?", (b, b, limit)).fetchall()
    else:
        rows = conn.execute("SELECT pair, MAX(id), COUNT(*) FROM bot_thread_messages GROUP BY pair ORDER BY MAX(id) DESC LIMIT ?", (limit,)).fetchall()
    out = []
    for pair, last_id, count in rows:
        last = _row(conn.execute(f"SELECT {COLS} FROM bot_thread_messages WHERE id = ?", (last_id,)).fetchone())
        a, b = pair.split("|", 1)
        working = [r[0] for r in conn.execute("SELECT DISTINCT recipient FROM bot_thread_messages WHERE pair = ? AND kind != 'result' AND status = 'running'",
                                              (pair,)).fetchall()]
        high = conn.execute("SELECT COUNT(*) FROM bot_thread_messages WHERE pair = ? AND priority = 'high'", (pair,)).fetchone()[0]
        item = {"pair": pair, "bots": [a, b], "names": {a: names.get(a, a), b: names.get(b, b)}, "count": count,
                "last": last, "last_at": last["ts"], "working": working, "high_priority": high}
        if bot_id:
            item["peer"] = b if a == norm(bot_id) else a
            item["preview"] = preview_text(bot_id, last, names)
        out.append(item)
    return out


def thread(conn, a, b, after=0, limit=300):
    pair = pair_key(a, b)
    rows = conn.execute(f"SELECT {COLS} FROM bot_thread_messages WHERE pair = ? AND id > ? ORDER BY id ASC LIMIT ?", (pair, after, limit)).fetchall()
    msgs = [_row(r) for r in rows]
    working = [r[0] for r in conn.execute("SELECT DISTINCT recipient FROM bot_thread_messages WHERE pair = ? AND kind != 'result' AND status = 'running'",
                                          (pair,)).fetchall()]
    last_id = conn.execute("SELECT MAX(id) FROM bot_thread_messages WHERE pair = ?", (pair,)).fetchone()[0] or 0
    return {"pair": pair, "messages": msgs, "working": working, "last_id": last_id}


def session_summary(conn, session_id, task_ids=None):
    """用户对话里的折叠行：这次对话发起的、以及这个对话作为接收方的 Bot 间消息，按对方 Bot 汇总。"""
    rows = conn.execute(
        "SELECT d.delegation_id, d.from_bot, d.to_bot, d.from_session, d.to_session "
        "FROM bot_delegations d WHERE d.from_session = ? OR d.to_session = ?",
        (session_id, session_id)).fetchall()
    peers = {}
    for did, fb, tb, fs, tsess in rows:
        incoming = (tsess == session_id) and (fs != session_id)
        me = norm(tb) if incoming else norm(fb)
        peer = norm(fb) if incoming else norm(tb)
        p = peers.setdefault(peer, {"peer": peer, "me": me, "count": 0, "delegations": [],
                                    "last_at": 0, "first_at": None, "outgoing": not incoming})
        n, first, last = conn.execute("SELECT COUNT(*), MIN(ts), MAX(ts) FROM bot_thread_messages WHERE delegation_id = ?", (did,)).fetchone()
        p["count"] += n or 0
        if last and last >= p["last_at"]:
            p["last_at"] = last
            last_row = conn.execute("SELECT sender FROM bot_thread_messages WHERE delegation_id = ? ORDER BY id DESC LIMIT 1", (did,)).fetchone()
            if last_row:
                p["outgoing"] = last_row[0] == p["me"]
        if first is not None:
            p["first_at"] = first if p["first_at"] is None else min(p["first_at"], first)
        p["delegations"].append(did)
    return sorted(peers.values(), key=lambda x: -x["last_at"])


def search(conn, like, limit=40):
    rows = conn.execute(f"SELECT {COLS} FROM bot_thread_messages WHERE text LIKE ? ESCAPE '\\' ORDER BY id DESC LIMIT ?", (like, limit)).fetchall()
    return [_row(r) for r in rows]


def collapsed_label(count, peer_name, outgoing=None):
    """一条时：发消息给 / 收到；连续多条折成「与 某Bot 往来 N 条」。"""
    if count <= 1:
        if outgoing is False:
            return f"收到 ◯{peer_name} 的消息"
        return f"发消息给 ◯{peer_name}"
    return f"与 {peer_name} 往来 {count} 条"
