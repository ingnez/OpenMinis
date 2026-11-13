"""静默时段：用户设定上班时间（可跨午夜）。时段内只应答主动提问，完成类通知攒起来，到点后汇总推送。"""
import json
import time
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover
    ZoneInfo = None

MAX_BODY = 160
MAX_ITEMS = 40
HOLD_EVENTS = frozenset({
    "task_complete", "task_completed", "task_failed", "routine", "routine_complete",
    "relay_watch", "notify", "proactive", "worker_complete", "delegation_complete",
})
# 审批等需要立刻处理的不攒
PASS_EVENTS = frozenset({"approval_required", "duty_digest", "quiet_digest"})

DEFAULT = {
    "enabled": False,
    "start": "08:00",
    "end": "18:00",
    "weekdays": [1, 2, 3, 4, 5],  # 周一到周五，ISO: 周一=1
    "timezone": "Asia/Shanghai",
}


class QuietError(ValueError):
    pass


def parse_hhmm(value, field="时间"):
    if not isinstance(value, str) or len(value) > 5:
        raise QuietError(f"{field} 必须是 HH:MM")
    parts = value.split(":")
    if len(parts) != 2:
        raise QuietError(f"{field} 必须是 HH:MM")
    try:
        h, m = int(parts[0]), int(parts[1])
    except (TypeError, ValueError):
        raise QuietError(f"{field} 必须是 HH:MM")
    if not (0 <= h <= 23 and 0 <= m <= 59):
        raise QuietError(f"{field} 必须是 HH:MM")
    return f"{h:02d}:{m:02d}", h * 60 + m


def validate(patch, current=None):
    cfg = dict(DEFAULT)
    if isinstance(current, dict):
        cfg.update({k: current[k] for k in DEFAULT if k in current})
    if not isinstance(patch, dict):
        raise QuietError("请求必须是对象")
    if "enabled" in patch:
        if not isinstance(patch["enabled"], bool):
            raise QuietError("enabled 必须是布尔值")
        cfg["enabled"] = patch["enabled"]
    if "start" in patch:
        cfg["start"], _ = parse_hhmm(patch["start"], "start")
    if "end" in patch:
        cfg["end"], _ = parse_hhmm(patch["end"], "end")
    if "weekdays" in patch:
        days = patch["weekdays"]
        if not isinstance(days, list) or not days or any(not isinstance(d, int) or isinstance(d, bool) or d < 1 or d > 7 for d in days):
            raise QuietError("weekdays 必须是 1–7（周一到周日）的整数列表")
        cfg["weekdays"] = sorted(set(days))
    if "timezone" in patch:
        tz = patch["timezone"]
        if not isinstance(tz, str) or not tz or len(tz) > 64:
            raise QuietError("timezone 必须是 IANA 时区名")
        if ZoneInfo is not None:
            try:
                ZoneInfo(tz)
            except Exception:
                raise QuietError(f"未知时区：{tz}")
        cfg["timezone"] = tz
    # 再校验一遍起止，保证存盘格式统一
    cfg["start"], _ = parse_hhmm(cfg["start"], "start")
    cfg["end"], _ = parse_hhmm(cfg["end"], "end")
    return cfg


def _zone(name):
    if ZoneInfo is None:
        return timezone(timedelta(hours=8))
    try:
        return ZoneInfo(name or "Asia/Shanghai")
    except Exception:
        return timezone(timedelta(hours=8))


def local_now(cfg, now=None):
    ts = now if now is not None else time.time()
    return datetime.fromtimestamp(ts, tz=_zone((cfg or {}).get("timezone") or "Asia/Shanghai"))


def is_active(cfg, now=None):
    """当前是否处于静默（上班）时段。起止相同视为全天；start > end 视为跨午夜。"""
    if not cfg or not cfg.get("enabled"):
        return False
    dt = local_now(cfg, now)
    if int(dt.isoweekday()) not in set(cfg.get("weekdays") or DEFAULT["weekdays"]):
        return False
    _, start = parse_hhmm(cfg.get("start") or DEFAULT["start"])
    _, end = parse_hhmm(cfg.get("end") or DEFAULT["end"])
    cur = dt.hour * 60 + dt.minute
    if start == end:
        return True
    if start < end:
        return start <= cur < end
    return cur >= start or cur < end


def should_hold(cfg, event, now=None):
    if event in PASS_EVENTS:
        return False
    if not is_active(cfg, now):
        return False
    return event in HOLD_EVENTS or event is None


def window_bounds(cfg, now=None):
    """当前（或刚结束的）这一段静默窗的起止 UNIX 时间。跨午夜时开始在前一天。"""
    dt = local_now(cfg, now)
    _, start = parse_hhmm(cfg.get("start") or DEFAULT["start"])
    _, end = parse_hhmm(cfg.get("end") or DEFAULT["end"])
    day = dt.replace(hour=0, minute=0, second=0, microsecond=0)
    start_dt = day + timedelta(minutes=start)
    if start < end or start == end:
        end_dt = day + timedelta(minutes=end if start < end else 24 * 60)
        if dt < start_dt:
            start_dt -= timedelta(days=1)
            end_dt -= timedelta(days=1)
    else:
        # 20:00–08:00：若现在是凌晨，开始在昨天 20:00
        if dt.hour * 60 + dt.minute < end:
            start_dt -= timedelta(days=1)
        end_dt = start_dt + timedelta(minutes=(24 * 60 - start) + end)
    return start_dt.timestamp(), end_dt.timestamp()


def ensure_schema(conn):
    conn.execute(
        "CREATE TABLE IF NOT EXISTS quiet_held (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, "
        "kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', bot_id TEXT, session_id TEXT)"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS quiet_digests (id INTEGER PRIMARY KEY AUTOINCREMENT, started REAL NOT NULL, "
        "ended REAL NOT NULL, count INTEGER NOT NULL, text TEXT NOT NULL, items TEXT NOT NULL, created_at REAL NOT NULL)"
    )


def record(conn, kind, title, body, bot_id=None, session_id=None, now=None):
    conn.execute(
        "INSERT INTO quiet_held (ts, kind, title, body, bot_id, session_id) VALUES (?, ?, ?, ?, ?, ?)",
        (now if now is not None else time.time(), kind or "notify", (title or "")[:120],
         (body or "").strip()[:MAX_BODY], bot_id, session_id),
    )


def _hm(ts, cfg=None):
    dt = local_now(cfg or DEFAULT, ts)
    return dt.strftime("%H:%M")


def compose(started, ended, items, cfg=None):
    head = f"静默时段（{_hm(started, cfg)}–{_hm(ended, cfg)}）"
    if not items:
        return head + "没有攒下的通知。"
    lines = [head + f"一共 {len(items)} 条完成通知，下班后一起告诉你："]
    for i in items[:12]:
        body = (i.get("body") or "").replace("\n", " ")
        lines.append(f"· {_hm(i['ts'], cfg)} {i.get('title') or ''}" + (f"：{body[:60]}" if body else ""))
    if len(items) > 12:
        lines.append(f"…还有 {len(items) - 12} 条，打开 App 查看")
    return "\n".join(lines)


def finish(conn, started, ended, now=None, cfg=None):
    rows = conn.execute(
        "SELECT ts, kind, title, body, bot_id, session_id FROM quiet_held WHERE ts >= ? AND ts <= ? "
        "ORDER BY ts ASC LIMIT ?",
        (started - 1, ended + 1, MAX_ITEMS),
    ).fetchall()
    items = [{"ts": r[0], "kind": r[1], "title": r[2], "body": r[3], "bot_id": r[4], "session_id": r[5]} for r in rows]
    text = compose(started, ended, items, cfg=cfg)
    conn.execute("DELETE FROM quiet_held WHERE ts <= ?", (ended + 1,))
    cur = conn.execute(
        "INSERT INTO quiet_digests (started, ended, count, text, items, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        (started, ended, len(items), text, json.dumps(items, ensure_ascii=False), now if now is not None else time.time()),
    )
    conn.execute("DELETE FROM quiet_digests WHERE id NOT IN (SELECT id FROM quiet_digests ORDER BY id DESC LIMIT 10)")
    return {"id": cur.lastrowid, "started": started, "ended": ended, "count": len(items), "text": text, "items": items}


def latest(conn):
    r = conn.execute(
        "SELECT id, started, ended, count, text, items, created_at FROM quiet_digests ORDER BY id DESC LIMIT 1"
    ).fetchone()
    if not r:
        return None
    return {"id": r[0], "started": r[1], "ended": r[2], "count": r[3], "text": r[4],
            "items": json.loads(r[5]), "created_at": r[6]}


def transition(state, cfg, now):
    """state: {active, started, until}。返回 (新 state, 要汇总的 (started, ended) 或 None)。"""
    state = dict(state or {})
    now = now if now is not None else time.time()
    on = is_active(cfg, now)
    if on:
        started, until = window_bounds(cfg, now)
        if not state.get("active"):
            return {"active": True, "started": started, "until": until}, None
        state["until"] = until
        return state, None
    if state.get("active"):
        started = float(state.get("started") or now)
        until = float(state.get("until") or now)
        ended = max(started, min(now, until))
        return {"active": False, "started": started, "until": ended}, (started, ended)
    return {"active": False, "started": state.get("started"), "until": state.get("until")}, None
