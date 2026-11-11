"""备份文件的计数、预览将新增的条目、自校验（不含密钥）。"""
import re

FORMAT = "openminis-backup/1"
BOT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
GROUP_ID_RE = re.compile(r"^grp_[a-f0-9]{10}$")


class BackupError(ValueError):
    pass


def validate(backup):
    if not isinstance(backup, dict):
        raise BackupError("不是有效的备份文件")
    if backup.get("format") != FORMAT:
        raise BackupError("不是 OpenMinis 备份文件（openminis-backup/1）")
    for key in ("bots", "sessions", "memory"):
        if key in backup and not isinstance(backup.get(key), list):
            raise BackupError(f"{key} 必须是列表")
    return True


def counts(backup):
    validate(backup)
    sessions = backup.get("sessions") or []
    messages = 0
    for s in sessions:
        if isinstance(s, dict):
            messages += len(s.get("messages") or [])
    return {
        "bots": len(backup.get("bots") or []),
        "sessions": len(sessions),
        "messages": messages,
        "groups": len(backup.get("groups") or []),
        "memory": len(backup.get("memory") or []),
        "skills": len(backup.get("skills") or []),
    }


def preview(backup, existing):
    """existing: {bots, sessions, groups, memory_keys, skill_names} 为已在服务器上的 ID 集合。
    返回将新增的数量与跳过的数量（不写库）。"""
    validate(backup)
    existing = existing or {}
    bots = set(existing.get("bots") or [])
    sessions = set(existing.get("sessions") or [])
    groups = set(existing.get("groups") or [])
    memory_keys = set(existing.get("memory_keys") or [])
    skills = set(existing.get("skill_names") or [])
    out = {"bots": 0, "sessions": 0, "messages": 0, "groups": 0, "memory": 0, "skills": 0, "skipped": 0}
    for b in backup.get("bots") or []:
        bid = (b or {}).get("bot_id")
        if not isinstance(bid, str) or not BOT_ID_RE.match(bid) or bid in bots:
            out["skipped"] += 1
            continue
        out["bots"] += 1
    for s in backup.get("sessions") or []:
        sid = (s or {}).get("session_id")
        if not isinstance(sid, str) or not SESSION_ID_RE.match(sid) or sid in sessions:
            out["skipped"] += 1
            continue
        out["sessions"] += 1
        out["messages"] += len((s or {}).get("messages") or [])
    for g in backup.get("groups") or []:
        gid = (g or {}).get("group_id")
        if not isinstance(gid, str) or not GROUP_ID_RE.match(gid) or gid in groups:
            out["skipped"] += 1
            continue
        out["groups"] += 1
    for e in backup.get("memory") or []:
        key = (e or {}).get("content")
        if not key or key in memory_keys:
            out["skipped"] += 1
            continue
        out["memory"] += 1
    for sk in backup.get("skills") or []:
        name = (sk or {}).get("name")
        if not name or name in skills:
            out["skipped"] += 1
            continue
        out["skills"] += 1
    return out


def existing_from_db(conn):
    bots = {r[0] for r in conn.execute("SELECT persona_id FROM personas").fetchall()} if _table(conn, "personas") else set()
    if _table(conn, "bots"):
        bots |= {r[0] for r in conn.execute("SELECT bot_id FROM bots").fetchall() if r[0]}
    sessions = {r[0] for r in conn.execute("SELECT session_id FROM sessions").fetchall()} if _table(conn, "sessions") else set()
    groups = {r[0] for r in conn.execute("SELECT group_id FROM groups").fetchall()} if _table(conn, "groups") else set()
    memory_keys = set()
    if _table(conn, "memory"):
        cols = {r[1] for r in conn.execute("PRAGMA table_info(memory)").fetchall()}
        if "content" in cols:
            memory_keys = {r[0] for r in conn.execute("SELECT content FROM memory").fetchall()}
    skill_names = set()
    if _table(conn, "skills"):
        skill_names = {r[0] for r in conn.execute("SELECT name FROM skills").fetchall()}
    return {"bots": bots, "sessions": sessions, "groups": groups, "memory_keys": memory_keys, "skill_names": skill_names}


def _table(conn, name):
    return bool(conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone())
