# -*- coding: utf-8 -*-
"""风险操作的批准记录：绑定「任务 + 工具 + 参数哈希」。

「批准一次」只放行这一次完全相同的调用；「本任务内都批准」在同一任务里、
同一工具且参数哈希相同的后续调用可以直接放行，直到过期。
聊天原文（例如「同意」「批准」）不会产生或消耗这里的记录，必须走审批接口。
"""

import hashlib
import json
import time
import uuid

# 本任务内批准的有效期：从点下按钮起 30 分钟（过期后同样的操作要重新确认）
TASK_GRANT_TTL_S = 30 * 60
# 本班次：优先用值班结束时间；没有值班时默认 12 小时
SHIFT_FALLBACK_TTL_S = 12 * 3600
SCOPE_ONCE = "once"
SCOPE_TASK = "task"
SCOPE_SHIFT = "shift"
SCOPES = (SCOPE_ONCE, SCOPE_TASK, SCOPE_SHIFT)


def args_hash(args):
    """对工具参数做规范化后取 sha256。键排序，保证同一组参数得到同一哈希。"""
    if args is None:
        payload = "null"
    elif isinstance(args, (dict, list)):
        payload = json.dumps(args, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    else:
        payload = json.dumps(args, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def ensure_schema(conn):
    conn.execute(
        "CREATE TABLE IF NOT EXISTS approval_grants ("
        "grant_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, tool TEXT NOT NULL, "
        "args_hash TEXT NOT NULL, scope TEXT NOT NULL, used INTEGER NOT NULL DEFAULT 0, "
        "created_at REAL NOT NULL, expires_at REAL NOT NULL)"
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_approval_grants_task ON approval_grants(task_id, tool, args_hash)")
    cols = {row[1] for row in conn.execute("PRAGMA table_info(approval_grants)")}
    if "bot_id" not in cols:
        conn.execute("ALTER TABLE approval_grants ADD COLUMN bot_id TEXT")
    conn.commit()
    _ensure_approval_columns(conn)


def _ensure_approval_columns(conn):
    cols = {row[1] for row in conn.execute("PRAGMA table_info(approvals)")}
    if not cols:
        return
    if "args_hash" not in cols:
        conn.execute("ALTER TABLE approvals ADD COLUMN args_hash TEXT")
    if "scope" not in cols:
        conn.execute("ALTER TABLE approvals ADD COLUMN scope TEXT")
    conn.commit()


def shift_expires(now, duty_until=None):
    """本班次授权的到期时间：值班未结束就用 duty_until，否则从现在起 12 小时。"""
    now = time.time() if now is None else now
    try:
        until = float(duty_until) if duty_until else 0
    except (TypeError, ValueError):
        until = 0
    if until > now:
        return until
    return now + SHIFT_FALLBACK_TTL_S


def record(conn, task_id, tool, args, scope, now=None, bot_id=None, expires_at=None):
    """写入一条批准记录。scope 是 once / task / shift。"""
    if scope not in SCOPES:
        raise ValueError("scope 只能是 once、task 或 shift")
    now = time.time() if now is None else now
    gid = "grn_" + uuid.uuid4().hex[:12]
    if expires_at is not None:
        expires = float(expires_at)
    elif scope == SCOPE_SHIFT:
        expires = shift_expires(now)
    else:
        expires = now + TASK_GRANT_TTL_S
    h = args_hash(args)
    conn.execute(
        "INSERT INTO approval_grants (grant_id, task_id, tool, args_hash, scope, used, created_at, expires_at, bot_id) "
        "VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)",
        (gid, task_id, tool, h, scope, now, expires, bot_id),
    )
    conn.commit()
    return {"grant_id": gid, "task_id": task_id, "tool": tool, "args_hash": h, "scope": scope,
            "expires_at": expires, "bot_id": bot_id}


def find_match(conn, task_id, tool, args, now=None, bot_id=None):
    """找到仍有效的批准记录（不消耗）。本班次授权可跨同一 Bot 的其他任务。"""
    now = time.time() if now is None else now
    h = args_hash(args)
    row = conn.execute(
        "SELECT grant_id, scope, used, expires_at FROM approval_grants "
        "WHERE tool = ? AND args_hash = ? AND expires_at > ? AND ("
        "  (scope = ? AND task_id = ?) OR "
        "  (scope = ? AND task_id = ? AND used = 0) OR "
        "  (scope = ? AND (task_id = ? OR bot_id = ?))"
        ") ORDER BY created_at DESC LIMIT 1",
        (tool, h, now, SCOPE_TASK, task_id, SCOPE_ONCE, task_id, SCOPE_SHIFT, task_id, bot_id),
    ).fetchone()
    if not row:
        return None
    return {"grant_id": row[0], "scope": row[1], "used": bool(row[2]), "expires_at": row[3], "args_hash": h}


def consume(conn, task_id, tool, args, now=None, bot_id=None):
    """若有匹配的批准记录则消耗（once 标记已用）并返回该记录，否则 None。"""
    rec = find_match(conn, task_id, tool, args, now, bot_id=bot_id)
    if not rec:
        return None
    if rec["scope"] == SCOPE_ONCE:
        conn.execute("UPDATE approval_grants SET used = 1 WHERE grant_id = ? AND used = 0", (rec["grant_id"],))
        conn.commit()
    return rec


def parse_decision(raw):
    """把 HTTP / 界面传入的 decision 规范成 (status, scope_or_none)。

    approve / approve_once → 批准一次；approve_task → 本任务内都批准；
    approve_shift → 本班次都批准（到值班结束或 12 小时）；deny → 拒绝。
    其它值返回 (None, None)，由调用方报 400。
    """
    if raw in ("approve", "approve_once"):
        return "approved", SCOPE_ONCE
    if raw == "approve_task":
        return "approved", SCOPE_TASK
    if raw == "approve_shift":
        return "approved", SCOPE_SHIFT
    if raw == "deny":
        return "denied", None
    return None, None
