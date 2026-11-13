"""查房待办箱：本班次要核对的事项（标题、可选床号）。不含真实姓名或住院号。"""
import time
import uuid

MAX_ITEMS = 80
MAX_TITLE = 80
MAX_DETAIL = 200
MAX_BED = 20


class WardTodoError(ValueError):
    pass


def ensure_schema(conn):
    conn.execute(
        "CREATE TABLE IF NOT EXISTS ward_todos ("
        "todo_id TEXT PRIMARY KEY, title TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '', "
        "bed TEXT NOT NULL DEFAULT '', done INTEGER NOT NULL DEFAULT 0, "
        "created_at REAL NOT NULL, done_at REAL, shift_started REAL)"
    )
    conn.commit()


def _clean(title, detail="", bed=""):
    title = (title or "").strip()
    if not title:
        raise WardTodoError("待办标题不能为空")
    return title[:MAX_TITLE], (detail or "").strip()[:MAX_DETAIL], (bed or "").strip()[:MAX_BED]


def add(conn, title, detail="", bed="", now=None, shift_started=None):
    now = time.time() if now is None else now
    title, detail, bed = _clean(title, detail, bed)
    tid = "todo_" + uuid.uuid4().hex[:12]
    conn.execute(
        "INSERT INTO ward_todos (todo_id, title, detail, bed, done, created_at, done_at, shift_started) "
        "VALUES (?, ?, ?, ?, 0, ?, NULL, ?)",
        (tid, title, detail, bed, now, shift_started),
    )
    return get(conn, tid)


def get(conn, todo_id):
    r = conn.execute(
        "SELECT todo_id, title, detail, bed, done, created_at, done_at, shift_started FROM ward_todos WHERE todo_id = ?",
        (todo_id,),
    ).fetchone()
    if not r:
        return None
    return {"todo_id": r[0], "title": r[1], "detail": r[2], "bed": r[3], "done": bool(r[4]),
            "created_at": r[5], "done_at": r[6], "shift_started": r[7]}


def list_items(conn, include_done=True, limit=MAX_ITEMS):
    q = "SELECT todo_id, title, detail, bed, done, created_at, done_at, shift_started FROM ward_todos"
    if not include_done:
        q += " WHERE done = 0"
    q += " ORDER BY done ASC, created_at DESC LIMIT ?"
    rows = conn.execute(q, (limit,)).fetchall()
    return [{"todo_id": r[0], "title": r[1], "detail": r[2], "bed": r[3], "done": bool(r[4]),
             "created_at": r[5], "done_at": r[6], "shift_started": r[7]} for r in rows]


def set_done(conn, todo_id, done=True, now=None):
    item = get(conn, todo_id)
    if not item:
        raise WardTodoError("没有这条待办")
    now = time.time() if now is None else now
    conn.execute("UPDATE ward_todos SET done = ?, done_at = ? WHERE todo_id = ?",
                 (1 if done else 0, now if done else None, todo_id))
    return get(conn, todo_id)


def delete(conn, todo_id):
    cur = conn.execute("DELETE FROM ward_todos WHERE todo_id = ?", (todo_id,))
    if cur.rowcount == 0:
        raise WardTodoError("没有这条待办")
    return {"deleted": todo_id}


def totals(items):
    open_n = sum(1 for i in items if not i["done"])
    return {"open": open_n, "done": len(items) - open_n, "all": len(items)}
