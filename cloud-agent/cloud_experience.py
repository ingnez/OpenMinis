"""Phone-owned model profiles and persistent, non-secret experience settings."""
import json
import math
import re
import time
from urllib.parse import urlsplit

import cloud_usage
import cloud_workorders

NOTE = """
[前台工单协议 v1]
先直接回答或用一句话对齐目标和验收标准，然后调用 dispatch_workorder。
工单五个字段必须完整；同一件事用相同 workstream，修改和纠错复用已有任务。
简单问题直接回答，不派后台任务。进度只汇报结果、决定、卡住、改计划。
未验证的内容必须称为草稿或待测试；只有后台验证通过才可说完成。
用户叫停时立即停止全部相关任务。不要把推理过程、命令和重复确认刷进聊天。
"""
DISPATCH_TOOL = {"type": "function", "function": {
    "name": "dispatch_workorder", "description": "创建或复用同一工作流的后台任务。先简短说明目标和完成标准。",
    "parameters": {"type": "object", "properties": {
        "workstream": {"type": "string"}, "goal": {"type": "string"}, "context": {"type": "string"},
        "success_criteria": {"type": "array", "items": {"type": "string"}, "minItems": 1},
        "report_back": {"type": "string"}}, "required": list(cloud_workorders.FIELDS), "additionalProperties": False}}}
EVIDENCE_TOOL = {"type": "function", "function": {
    "name": "record_evidence", "description": "将实际工具结果绑定到验收标准（从 0 开始）。不能用自称完成替代验证。",
    "parameters": {"type": "object", "properties": {
        "criterion": {"type": "integer"}, "event_id": {"type": "integer"},
        "kind": {"type": "string", "enum": ["test", "artifact", "source"]}, "summary": {"type": "string"}},
        "required": ["criterion", "event_id", "kind"]}}}


def ensure_schema(conn):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS experience_sessions (
            session_id TEXT PRIMARY KEY, settings TEXT NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS experience_checkpoints (
            worker_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, task_id TEXT,
            last_event INTEGER, state TEXT NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS experience_lessons (
            session_id TEXT NOT NULL, layer TEXT NOT NULL, content TEXT NOT NULL,
            updated_at REAL NOT NULL, UNIQUE(session_id,layer,content));
    """)


def settings(conn, sid):
    row = conn.execute("SELECT settings FROM experience_sessions WHERE session_id=?", (sid,)).fetchone()
    return json.loads(row[0]) if row else None


def configure(conn, sid, value):
    if not isinstance(value, dict) or value.get("version") != 1:
        raise ValueError("体验协议版本必须为 1")
    clean = {"version": 1, "worker_concurrency": cloud_workorders.concurrency(value)}
    # Explicit allowlist: provider keys, addresses and arbitrary client fields
    # never enter persistent session settings.
    for key in ("task_token_budget", "daily_token_budget"):
        n = value.get(key, 0)
        if type(n) is not int or not 0 <= n <= 100000000:
            raise ValueError(key + " 必须是非负整数")
        clean[key] = n
    for key in ("input_price_per_million", "output_price_per_million", "task_cost_budget"):
        n = value.get(key)
        if n is not None and (type(n) not in (int, float) or not math.isfinite(n) or n < 0):
            raise ValueError(key + " 必须是非负金额")
        clean[key] = n
    conn.execute("INSERT INTO experience_sessions VALUES (?,?,?) ON CONFLICT(session_id) DO UPDATE SET "
                 "settings=excluded.settings,updated_at=excluded.updated_at", (sid, json.dumps(clean), time.time()))
    conn.commit()
    return clean


def profiles(value, fallback_model, fallback_provider):
    if not isinstance(value, dict):
        raise ValueError("前后台模型配置必须是对象")
    out = {}
    for role in ("front", "back", "reviewer"):
        raw = value.get(role)
        if raw is None:
            out[role] = dict(out["front"]) if role == "reviewer" else {
                "model": fallback_model, "provider": dict(fallback_provider)}
            continue
        if not isinstance(raw, dict) or not isinstance(raw.get("model"), str) or not raw["model"].strip():
            raise ValueError(role + " 缺少模型名")
        provider = raw.get("provider")
        if not isinstance(provider, dict) or provider.get("protocol", "chat") not in ("chat", "openai"):
            raise ValueError(role + " 需要 OpenAI 兼容 Chat Completions 接口")
        base, key = provider.get("base_url"), provider.get("api_key")
        if not isinstance(base, str) or not isinstance(key, str) or not key:
            raise ValueError(role + " 缺少服务地址或手机钥匙串凭据")
        url = urlsplit(base)
        if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ValueError(role + " 的服务地址无效")
        out[role] = {"model": raw["model"].strip()[:128], "provider": {
            "base_url": base.rstrip("/"), "api_key": key, "protocol": "chat"}}
    return out


def route(profile):
    return {"url": profile["provider"]["base_url"].rstrip("/") + "/chat/completions",
            "key": profile["provider"].get("api_key", ""), "model": profile["model"]}


def front_tools(tools):
    allowed = {"task_status", "task_message", "task_stop", "task_resume", "react", "ask_choice", "routine_create", "routine_list"}
    return [t for t in tools if t.get("function", {}).get("name") in allowed] + [DISPATCH_TOOL]


def estimate_budget(conn, sid, goal, context, output_tokens=4096):
    cfg = settings(conn, sid) or {}
    prompt = cloud_usage.estimate(goal) + cloud_usage.estimate(context) + 2000
    total = prompt + output_tokens
    p, c = cfg.get("input_price_per_million"), cfg.get("output_price_per_million")
    cost = (prompt * p + output_tokens * c) / 1000000 if p is not None and c is not None else None
    day = cloud_usage.total_for_day(conn)
    reasons = []
    if cfg.get("task_token_budget") and total > cfg["task_token_budget"]:
        reasons.append("本任务预计 token 超过预算")
    if cfg.get("daily_token_budget") and day + total > cfg["daily_token_budget"]:
        reasons.append("今天预计 token 超过预算")
    if cfg.get("task_cost_budget") and (cost is None or cost > cfg["task_cost_budget"]):
        reasons.append("费用未知，需要确认" if cost is None else "本任务预计费用超过预算")
    return {"estimated_tokens": total, "estimated_cost": cost, "today_tokens": day,
            "needs_approval": bool(reasons), "reasons": reasons}


def remember(conn, sid, layer, content):
    if layer not in ("preference", "project", "daily") or not isinstance(content, str) or not content.strip():
        raise ValueError("记忆需要明确的层级和内容")
    # Never infer a lesson from abuse or save credential-like values.
    if re.search(r"(?:sk-|Bearer\s|api[_ -]?key\s*[:=]|password\s*[:=])", content, re.I):
        raise ValueError("记忆不能包含凭据")
    conn.execute("INSERT INTO experience_lessons VALUES (?,?,?,?) ON CONFLICT(session_id,layer,content) "
                 "DO UPDATE SET updated_at=excluded.updated_at", (sid, layer, content.strip()[:1000], time.time()))
    conn.commit()


def learn_correction(conn, sid, text):
    # Only explicit, actionable corrections. Do not turn sentiment into rules.
    if isinstance(text, str):
        match = re.search(r"(?:以后|下次|记住|不要再|必须先)([^。！？\n]{3,160})", text)
        if match:
            remember(conn, sid, "preference", match[0])


def memory_note(conn, sid, query):
    rows = conn.execute("SELECT layer,content FROM experience_lessons WHERE session_id=? "
                        "AND (layer!='daily' OR updated_at>?) ORDER BY updated_at DESC LIMIT 80",
                        (sid, time.time() - 86400)).fetchall()
    terms = set(re.findall(r"[a-zA-Z0-9_]{3,}|[\u4e00-\u9fff]{2}", query or ""))
    ranked = sorted(rows, key=lambda row: (sum(term in row[1] for term in terms), row[0] == "preference"), reverse=True)
    relevant = [row for row in ranked if row[0] == "preference" or any(term in row[1] for term in terms)][:6]
    return "\n[相关记忆]\n" + "\n".join(layer + ": " + text for layer, text in relevant) if relevant else ""


def checkpoint(conn, worker_id, state):
    order = cloud_workorders.get(conn, worker_id)
    if not order:
        return
    row = conn.execute("SELECT task_id FROM bot_workers WHERE worker_id=?", (worker_id,)).fetchone()
    task = row[0] if row else None
    last = conn.execute("SELECT MAX(id) FROM task_events WHERE task_id=?", (task,)).fetchone()[0]
    conn.execute("INSERT INTO experience_checkpoints VALUES (?,?,?,?,?,?) ON CONFLICT(worker_id) DO UPDATE SET "
                 "revision=excluded.revision,task_id=excluded.task_id,last_event=excluded.last_event,state=excluded.state,"
                 "updated_at=excluded.updated_at", (worker_id, order["revision"], task, last, state, time.time()))
    conn.commit()
