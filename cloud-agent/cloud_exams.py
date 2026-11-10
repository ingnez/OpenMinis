"""考试倒计时看板：用户登记考试（名称、日期、科目 / 备注），首页看板显示还有几天；
Bot 每一轮都会在本轮末尾看到最近 30 天内的考试（不改系统提示，前缀缓存不受影响），安排复习、出题时会参考。"""
import re
import time
import uuid
from datetime import date, datetime

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def ensure_schema(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS exams (id TEXT PRIMARY KEY, name TEXT NOT NULL, day TEXT NOT NULL, "
                 "notes TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL)")


def validate(body):
    name = (body.get("name") or "").strip() if isinstance(body.get("name"), str) else ""
    day = body.get("day") if isinstance(body.get("day"), str) else ""
    notes = body.get("notes", "") if isinstance(body.get("notes", ""), str) else None
    if not name or len(name) > 60:
        raise ValueError("name 必填，最多 60 字")
    if not DATE_RE.match(day):
        raise ValueError("day 是 YYYY-MM-DD")
    try:
        datetime.strptime(day, "%Y-%m-%d")
    except ValueError:
        raise ValueError("day 不是有效日期")
    if notes is None or len(notes) > 500:
        raise ValueError("notes 最多 500 字")
    return name, day, notes.strip()


def days_left(day, today=None):
    today = today or date.today()
    return (datetime.strptime(day, "%Y-%m-%d").date() - today).days


def add(conn, body):
    name, day, notes = validate(body)
    eid = "exam_" + uuid.uuid4().hex[:10]
    conn.execute("INSERT INTO exams (id, name, day, notes, created_at) VALUES (?, ?, ?, ?, ?)", (eid, name, day, notes, time.time()))
    conn.commit()
    return get(conn, eid)


def update(conn, eid, body):
    cur = get(conn, eid)
    if not cur:
        return None
    merged = {"name": cur["name"], "day": cur["day"], "notes": cur["notes"]}
    merged.update({k: v for k, v in body.items() if k in merged})
    name, day, notes = validate(merged)
    conn.execute("UPDATE exams SET name = ?, day = ?, notes = ? WHERE id = ?", (name, day, notes, eid))
    conn.commit()
    return get(conn, eid)


def delete(conn, eid):
    c = conn.execute("DELETE FROM exams WHERE id = ?", (eid,))
    conn.commit()
    return c.rowcount > 0


def _row(r, today=None):
    return {"id": r[0], "name": r[1], "day": r[2], "notes": r[3], "days_left": days_left(r[2], today)}


def get(conn, eid):
    r = conn.execute("SELECT id, name, day, notes FROM exams WHERE id = ?", (eid,)).fetchone()
    return _row(r) if r else None


def list_all(conn, include_past_days=3, today=None):
    rows = [_row(r, today) for r in conn.execute("SELECT id, name, day, notes FROM exams ORDER BY day ASC, name ASC")]
    return [r for r in rows if r["days_left"] >= -include_past_days]


def note(conn, within=30, today=None):
    """给模型的一行提示；没有近期考试返回空串"""
    soon = [r for r in list_all(conn, 0, today) if 0 <= r["days_left"] <= within]
    if not soon:
        return ""
    parts = [f"{r['name']}（{r['day']}，" + ("就是今天" if r["days_left"] == 0 else f"还有 {r['days_left']} 天") + "）" for r in soon[:5]]
    return "\n[考试倒计时] " + "；".join(parts) + "。安排复习、出题或排班建议时考虑这些日期。"
