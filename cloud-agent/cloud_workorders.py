"""Structured work orders, request reconciliation and evidence-backed delivery.

Provider credentials never belong in this module or its persistent records.
Model output can propose evidence references; only recorded tool events can
establish that the referenced operation actually succeeded.
"""
import hashlib
import json
import re
import time
import uuid

FIELDS = ("workstream", "goal", "context", "success_criteria", "report_back")
OPEN_WORKERS = ("queued", "running", "paused", "verifying")
MILESTONE_KINDS = ("result", "decision", "blocked", "plan_changed")
_STREAM = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$")


class WorkOrderError(ValueError):
    pass


def normalize(value, legacy=False):
    if not isinstance(value, dict):
        raise WorkOrderError("工单必须是 JSON 对象")
    order = {key: value.get(key) for key in FIELDS}
    if legacy:
        goal = value.get("goal")
        order.update(workstream=value.get("workstream") or "task-" + uuid.uuid4().hex[:12],
                     context=value.get("context") or "",
                     success_criteria=value.get("success_criteria") or ["返回与目标相符的结果及验证依据"],
                     report_back=value.get("report_back") or "结果、交付物和验证依据")
        order["goal"] = goal
    missing = [key for key in FIELDS if order[key] is None]
    if missing:
        raise WorkOrderError("工单缺少字段：" + "、".join(missing))
    for key, limit in (("goal", 20000), ("context", 20000), ("report_back", 2000)):
        text = order[key]
        if not isinstance(text, str) or len(text) > limit or (key != "context" and not text.strip()):
            raise WorkOrderError(key + " 必须是长度有效的文字")
        order[key] = text.strip()
    if not isinstance(order["workstream"], str) or not _STREAM.fullmatch(order["workstream"]):
        raise WorkOrderError("workstream 必须是稳定的工作流代号")
    criteria = order["success_criteria"]
    if not isinstance(criteria, list) or not 1 <= len(criteria) <= 20:
        raise WorkOrderError("success_criteria 必须包含 1–20 条验收标准")
    if any(not isinstance(item, str) or not item.strip() or len(item) > 2000 for item in criteria):
        raise WorkOrderError("验收标准必须是非空文字")
    order["success_criteria"] = list(dict.fromkeys(item.strip() for item in criteria))
    return order


def ensure_schema(conn):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS worker_workorders (
            worker_id TEXT PRIMARY KEY, front_session TEXT NOT NULL,
            workstream TEXT NOT NULL, contract TEXT NOT NULL,
            revision INTEGER NOT NULL DEFAULT 1, verification TEXT NOT NULL DEFAULT 'pending',
            review TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_workorders_stream
            ON worker_workorders(front_session, workstream);
        CREATE TABLE IF NOT EXISTS workorder_evidence (
            worker_id TEXT NOT NULL, revision INTEGER NOT NULL,
            criterion INTEGER NOT NULL, event_id INTEGER NOT NULL,
            kind TEXT NOT NULL, summary TEXT NOT NULL,
            PRIMARY KEY(worker_id, revision, criterion, event_id)
        );
        CREATE TABLE IF NOT EXISTS request_ledger (
            request_id TEXT PRIMARY KEY, front_session TEXT NOT NULL,
            client_nonce TEXT NOT NULL, user_message TEXT NOT NULL,
            worker_id TEXT, status TEXT NOT NULL DEFAULT 'queued', reply TEXT,
            created_at REAL NOT NULL, updated_at REAL NOT NULL,
            UNIQUE(front_session, client_nonce)
        );
        CREATE TABLE IF NOT EXISTS workorder_milestones (
            worker_id TEXT NOT NULL, kind TEXT NOT NULL,
            fingerprint TEXT NOT NULL, message TEXT NOT NULL, created_at REAL NOT NULL,
            PRIMARY KEY(worker_id, kind, fingerprint)
        );
    """)


def get(conn, worker_id):
    row = conn.execute("SELECT contract, revision, verification, review FROM worker_workorders WHERE worker_id = ?",
                       (worker_id,)).fetchone()
    if row is None:
        return None
    order = json.loads(row[0])
    order.update(revision=row[1], verification=row[2], review=json.loads(row[3]) if row[3] else None)
    order["evidence"] = [dict(zip(("criterion", "event_id", "kind", "summary"), item)) for item in conn.execute(
        "SELECT criterion, event_id, kind, summary FROM workorder_evidence WHERE worker_id = ? AND revision = ?",
        (worker_id, row[1])).fetchall()]
    return order


def attach(conn, worker_id, front_session, contract):
    order = normalize(contract)
    worker = conn.execute("SELECT front_session FROM bot_workers WHERE worker_id = ?", (worker_id,)).fetchone()
    if not worker or worker[0] != front_session:
        raise WorkOrderError("该任务不属于当前对话")
    now = time.time()
    conn.execute("INSERT INTO worker_workorders(worker_id, front_session, workstream, contract, revision, created_at, updated_at) "
                 "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(worker_id) DO UPDATE SET "
                 "workstream=excluded.workstream, contract=excluded.contract, revision=worker_workorders.revision+1, "
                 "verification='pending', review=NULL, updated_at=excluded.updated_at",
                 (worker_id, front_session, order["workstream"], json.dumps(order, ensure_ascii=False), 1, now, now))
    conn.commit()
    return get(conn, worker_id)


def reusable_worker(conn, front_session, workstream):
    row = conn.execute("SELECT w.worker_id FROM bot_workers w JOIN worker_workorders o ON o.worker_id=w.worker_id "
                       "WHERE o.front_session=? AND o.workstream=? AND w.status IN ('queued','running','paused','verifying') "
                       "ORDER BY w.created_at LIMIT 1", (front_session, workstream)).fetchone()
    return row[0] if row else None


def register_request(conn, front_session, client_nonce, user_message):
    nonce = client_nonce if isinstance(client_nonce, str) and client_nonce else uuid.uuid4().hex
    request_id = "req_" + hashlib.sha256((front_session + "\0" + nonce).encode()).hexdigest()[:24]
    now = time.time()
    conn.execute("INSERT OR IGNORE INTO request_ledger(request_id,front_session,client_nonce,user_message,created_at,updated_at) "
                 "VALUES (?,?,?,?,?,?)", (request_id, front_session, nonce, user_message, now, now))
    conn.commit()
    return request_id


def assign_request(conn, request_id, front_session, worker_id):
    row = conn.execute("SELECT front_session FROM bot_workers WHERE worker_id=?", (worker_id,)).fetchone()
    if not row or row[0] != front_session:
        raise WorkOrderError("不能把请求转给另一个对话的任务")
    conn.execute("UPDATE request_ledger SET worker_id=?,status='in_progress',updated_at=? "
                 "WHERE request_id=? AND front_session=?", (worker_id, time.time(), request_id, front_session))
    conn.commit()


def answer_request(conn, request_id, front_session, reply):
    if not isinstance(reply, str) or not reply.strip():
        raise WorkOrderError("不能把空回复标为已交付")
    conn.execute("UPDATE request_ledger SET status='delivered',reply=?,updated_at=? "
                 "WHERE request_id=? AND front_session=? AND worker_id IS NULL",
                 (reply, time.time(), request_id, front_session))
    conn.commit()


def reconcile(conn, front_session):
    rows = conn.execute("SELECT r.request_id,w.status,o.verification FROM request_ledger r "
                        "JOIN bot_workers w ON w.worker_id=r.worker_id "
                        "LEFT JOIN worker_workorders o ON o.worker_id=w.worker_id WHERE r.front_session=?",
                        (front_session,)).fetchall()
    for request_id, worker_status, verification in rows:
        if worker_status == "completed":
            status = "delivered" if verification == "verified" else "blocked"
        elif worker_status == "cancelled":
            status = "stopped"
        elif worker_status in ("failed", "interrupted", "limit_reached", "paused"):
            status = "blocked"
        else:
            status = "queued" if worker_status == "queued" else "in_progress"
        conn.execute("UPDATE request_ledger SET status=?,updated_at=? WHERE request_id=?",
                     (status, time.time(), request_id))
    conn.commit()
    return list_requests(conn, front_session)


def list_requests(conn, front_session, limit=100):
    columns = ("id", "nonce", "message", "worker_id", "status", "reply", "created_at", "updated_at")
    return [dict(zip(columns, row)) for row in conn.execute(
        "SELECT request_id,client_nonce,user_message,worker_id,status,reply,created_at,updated_at "
        "FROM request_ledger WHERE front_session=? ORDER BY created_at DESC LIMIT ?",
        (front_session, max(1, min(int(limit), 200)))).fetchall()]


def record_evidence(conn, worker_id, criterion, event_id, kind, summary=""):
    order = get(conn, worker_id)
    if not order or isinstance(criterion, bool) or not isinstance(criterion, int) or not 0 <= criterion < len(order["success_criteria"]):
        raise WorkOrderError("验证依据没有对应的验收标准")
    if kind not in ("test", "artifact", "source"):
        raise WorkOrderError("验证依据类型不支持")
    row = conn.execute("SELECT e.event_type,e.payload FROM task_events e JOIN bot_workers w ON w.task_id=e.task_id "
                       "WHERE w.worker_id=? AND e.id=?", (worker_id, event_id)).fetchone()
    if not row or row[0] != "tool_result":
        raise WorkOrderError("验证依据必须引用本任务真实的工具结果")
    payload = json.loads(row[1])
    result = payload.get("result")
    if not isinstance(result, dict) or result.get("error") or result.get("success") is False:
        raise WorkOrderError("失败的工具结果不能算通过依据")
    tool = payload.get("tool") or payload.get("name")
    if kind == "test" and (tool != "shell_execute" or type(result.get("exit_code")) is not int or result["exit_code"] != 0):
        raise WorkOrderError("测试依据必须有成功退出码")
    if kind == "artifact" and (tool not in ("deliver_file", "file_write", "file_read")
                               or not (result.get("status") == "ok" or result.get("success") is True)):
        raise WorkOrderError("交付物依据必须先由文件工具核验")
    nested = result.get("result") if isinstance(result.get("result"), dict) else {}
    if kind == "source" and (tool not in ("browser_action", "web_fetch", "fetch_url")
                             or not (result.get("url") or result.get("href") or nested.get("url"))):
        raise WorkOrderError("来源依据必须包含实际读取的链接")
    conn.execute("INSERT OR REPLACE INTO workorder_evidence(worker_id,revision,criterion,event_id,kind,summary) "
                 "VALUES (?,?,?,?,?,?)", (worker_id, order["revision"], criterion, event_id, kind, str(summary)[:2000]))
    conn.commit()
    return get(conn, worker_id)


def review(conn, worker_id, decision):
    order = get(conn, worker_id)
    if not order:
        raise WorkOrderError("没有可核验的工单")
    covered = {item["criterion"] for item in order["evidence"]}
    missing = sorted(set(range(len(order["success_criteria"]))) - covered)
    valid = isinstance(decision, dict) and type(decision.get("pass")) is bool and isinstance(decision.get("unmet"), list)
    verified = valid and decision["pass"] and not decision["unmet"] and not missing
    result = {"pass": bool(verified), "unmet": decision.get("unmet", []) if valid else ["审核结果格式不完整"],
              "missing_evidence": missing}
    conn.execute("UPDATE worker_workorders SET verification=?,review=?,updated_at=? WHERE worker_id=?",
                 ("verified" if verified else "rejected", json.dumps(result, ensure_ascii=False), time.time(), worker_id))
    conn.commit()
    return get(conn, worker_id)


def milestone(conn, worker_id, kind, message):
    if kind not in MILESTONE_KINDS or not isinstance(message, str) or not message.strip():
        raise WorkOrderError("只在结果、决定、卡住、改计划时汇报")
    order = get(conn, worker_id)
    if kind == "result" and (not order or order["verification"] != "verified"):
        raise WorkOrderError("未经验证不能发布完成汇报")
    text = message.strip()[:2000]
    fingerprint = hashlib.sha256(text.encode()).hexdigest()
    cursor = conn.execute("INSERT OR IGNORE INTO workorder_milestones(worker_id,kind,fingerprint,message,created_at) "
                          "VALUES (?,?,?,?,?)", (worker_id, kind, fingerprint, text, time.time()))
    conn.commit()
    return cursor.rowcount == 1


def concurrency(settings):
    value = (settings or {}).get("worker_concurrency", 2)
    if type(value) is not int or not 1 <= value <= 4:
        raise WorkOrderError("同时进行的后台任务只能设置为 1–4 个")
    return value


def stop_all_requested(text):
    return isinstance(text, str) and text.strip().strip("。！!？?，,") in (
        "停", "停止", "停下", "停一下", "全部停止", "全部停下", "都停", "停止所有任务", "停掉全部任务")
