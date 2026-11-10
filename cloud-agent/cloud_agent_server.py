#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Computer & Agent Service (cloud_agent_server.py) v2.0
- Full model dialogue and tool history persistence (tool_calls, tool results)
- Monotonic event cursor (id monotone, GET /v1/tasks/{id}/events?after=...)
- Client nonce idempotency (POST /v1/sessions/{id}/messages)
- Stable session mapping via local_session_id (POST /v1/sessions/import)
- Transactional task and message creation before ACK
- Process-memory API keys (survives client disconnection)
- Distinct status states: queued, running, completed, waiting_user, failed, cancelled, limit_reached, interrupted
- Integrated Playwright Chromium browser tools with persistent per-workspace profile
- Integrated X11 desktop computer tools (scrot, xdotool)
- Workspace attachments endpoint with Bearer auth (/v1/sessions/{id}/attachments/{filename})
- Encrypted provider credential store (AES-256-GCM, /v1/credentials; names only are ever listed)
- Approval cards: risky tool calls pause the task in waiting_user until the user approves or denies
- Routines: cron / interval / once saved prompts run by a scheduler thread with stored encrypted credentials
- Structured memory: memory_write / memory_search over SQLite FTS5 (trigram), shared Markdown format with the phone
- Skills lazy-load: only a name + description index goes into the prompt; skill_load reads the full SKILL.md
- Push: Bark / ntfy notifications on task completion, approvals and routine runs (config stored encrypted)
- Pages library (page_write), cloud sub agents (subagent_task) and image generation (image_generate)
- Telegram channel: Bot API long polling, per-chat sessions, inline approve/deny buttons
- Personas: several bots with their own instructions and memory scope, usable from chat, routines and Telegram
"""

import os
import sys
import json
import sqlite3
import time
import uuid
import signal
import subprocess
import threading
import tempfile
import mimetypes
import urllib.request
import urllib.error
from urllib.parse import urlparse, parse_qs, unquote
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

# Import sub-modules
SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)

import re
import cloud_browser
import cloud_desktop
import cloud_secrets
import cloud_policy
import cloud_cron
import cloud_memory
import cloud_skills
import cloud_notify
import cloud_pages
import cloud_telegram
import cloud_bots
import cloud_plugins
import cloud_mcp

HOST = os.environ.get("OPENMINIS_HOST", "127.0.0.1")
PORT = int(os.environ.get("OPENMINIS_PORT", "18765"))
BASE_DIR = os.path.abspath(os.environ.get("OPENMINIS_BASE", SERVER_DIR))
DB_PATH = os.environ.get("OPENMINIS_DB", os.path.join(BASE_DIR, "data", "openminis_agent.db"))
GLOBAL_WORKSPACE = os.path.abspath(os.environ.get("OPENMINIS_WORKSPACE", os.path.join(BASE_DIR, "workspace")))
TOKEN_FILE = os.environ.get("OPENMINIS_TOKEN_FILE", "/etc/openminis/token")
MAX_TURNS = int(os.environ.get("OPENMINIS_MAX_TURNS", "128"))

def validate_and_load_token():
    token = os.environ.get("OPENMINIS_TOKEN")
    if token:
        return token.strip()
    if not os.path.exists(TOKEN_FILE):
        sys.stderr.write(f"[-] CRITICAL ERROR: Token file not found at {TOKEN_FILE} and OPENMINIS_TOKEN not set.\n")
        sys.exit(1)
    try:
        st = os.stat(TOKEN_FILE)
        if not (st.st_mode & 0o077) == 0:
            sys.stderr.write("[-] CRITICAL ERROR: Token file permissions must be 600.\n")
            sys.exit(1)
        with open(TOKEN_FILE, "r", encoding="utf-8") as f:
            t = f.read().strip()
            if not t:
                raise ValueError("Empty token")
            return t
    except Exception as e:
        sys.stderr.write(f"[-] CRITICAL ERROR: Token load failed: {e}\n")
        sys.exit(1)

SERVER_TOKEN = None

os.makedirs(os.path.dirname(os.path.abspath(DB_PATH)), exist_ok=True)
os.makedirs(GLOBAL_WORKSPACE, exist_ok=True)

def get_db_connection():
    conn = sqlite3.connect(DB_PATH, timeout=30.0)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA busy_timeout=30000;")
    return conn

def init_db():
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Sessions table with local_session_id mapping
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        local_session_id TEXT UNIQUE,
        title TEXT,
        instructions TEXT,
        created_at REAL
    )
    """)
    
    # Messages table storing role, content, tool_calls, tool_call_id
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT,
        role TEXT,
        content TEXT,
        tool_calls TEXT,
        tool_call_id TEXT,
        timestamp REAL
    )
    """)
    
    # Tasks table with client_nonce idempotency
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS tasks (
        task_id TEXT PRIMARY KEY,
        session_id TEXT,
        client_nonce TEXT UNIQUE,
        status TEXT,
        model TEXT,
        created_at REAL
    )
    """)

    # Task events table with monotonic autoincrement ID
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS task_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT,
        event_type TEXT,
        payload TEXT,
        timestamp REAL
    )
    """)

    # 兼容build9/10已有数据库；CREATE IF NOT EXISTS不会为旧表添加列。
    migrations = {
        'sessions': {'local_session_id': 'TEXT', 'instructions': 'TEXT', 'persona_id': 'TEXT'},
        'messages': {'tool_calls': 'TEXT', 'tool_call_id': 'TEXT'},
        'tasks': {'client_nonce': 'TEXT'},
    }
    for table, columns in migrations.items():
        existing_columns = {row[1] for row in cursor.execute('PRAGMA table_info(' + table + ')')}
        for column, kind in columns.items():
            if column not in existing_columns:
                cursor.execute('ALTER TABLE ' + table + ' ADD COLUMN ' + column + ' ' + kind)
    cursor.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_local ON sessions(local_session_id) WHERE local_session_id IS NOT NULL')
    cursor.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_nonce ON tasks(client_nonce) WHERE client_nonce IS NOT NULL')
    # 等待审批 (waiting_user) 的任务同样占用会话，同会话只允许一个活动任务
    cursor.execute("DROP INDEX IF EXISTS idx_tasks_session_running")
    cursor.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_session_active ON tasks(session_id) WHERE status IN ('running', 'waiting_user')")
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_tasks_session ON tasks(session_id, created_at)")
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_task_events_task ON task_events(task_id, id)")

    # 加密凭据：api_key 仅以 AES-GCM 密文落盘，AAD 绑定凭据名
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS credentials (
        name TEXT PRIMARY KEY,
        protocol TEXT,
        base_url TEXT,
        ciphertext BLOB NOT NULL,
        key_hint TEXT,
        created_at REAL,
        updated_at REAL
    )
    """)
    
    # 风险操作审批记录
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS approvals (
        approval_id TEXT PRIMARY KEY,
        task_id TEXT,
        tool_call_id TEXT,
        tool TEXT,
        arguments TEXT,
        rule_id TEXT,
        category TEXT,
        reason TEXT,
        status TEXT,
        note TEXT,
        created_at REAL,
        expires_at REAL,
        decided_at REAL
    )
    """)
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_approvals_task ON approvals(task_id, created_at)")

    # 云端例行任务与运行记录
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS routines (
        routine_id TEXT PRIMARY KEY,
        name TEXT,
        prompt TEXT,
        schedule TEXT,
        credential TEXT,
        model TEXT,
        instructions TEXT,
        enabled INTEGER,
        max_runs INTEGER,
        run_count INTEGER DEFAULT 0,
        next_run_at REAL,
        last_run_at REAL,
        last_status TEXT,
        notify INTEGER DEFAULT 1,
        created_at REAL,
        updated_at REAL
    )
    """)
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS routine_runs (
        run_id TEXT PRIMARY KEY,
        routine_id TEXT,
        task_id TEXT,
        session_id TEXT,
        trigger TEXT,
        status TEXT,
        result TEXT,
        error TEXT,
        started_at REAL,
        finished_at REAL
    )
    """)
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_routine_runs ON routine_runs(routine_id, started_at)")
    if "persona_id" not in {row[1] for row in cursor.execute("PRAGMA table_info(routines)")}:
        cursor.execute("ALTER TABLE routines ADD COLUMN persona_id TEXT")
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS personas (
        persona_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        instructions TEXT NOT NULL,
        emoji TEXT,
        created_at REAL,
        updated_at REAL
    )
    """)

    # 结构化记忆（FTS5 trigram，不可用时退化为 LIKE）
    conn.commit()
    cloud_memory.ensure_schema(conn)
    cloud_skills.ensure_schema(conn)
    cloud_bots.ensure_schema(conn)
    cloud_plugins.ensure_schema(conn)
    conn.execute("CREATE TABLE IF NOT EXISTS app_settings (name TEXT PRIMARY KEY, value TEXT)")
    try:
        row = conn.execute("SELECT value FROM app_settings WHERE name = 'timezone'").fetchone()
        cloud_memory.set_timezone(row[0] if row else None)
    except Exception as e:
        print(f"timezone setting ignored: {e}")
    cloud_notify.ensure_schema(conn)
    cloud_pages.ensure_schema(conn)
    cursor.execute("CREATE TABLE IF NOT EXISTS telegram_chats (chat_id INTEGER PRIMARY KEY, session_id TEXT, updated_at REAL)")
    cursor.execute("CREATE TABLE IF NOT EXISTS telegram_tasks (task_id TEXT PRIMARY KEY, chat_id INTEGER, created_at REAL)")
    cursor.execute("CREATE TABLE IF NOT EXISTS telegram_state (key TEXT PRIMARY KEY, value TEXT)")
    cursor.execute("CREATE TABLE IF NOT EXISTS telegram_bot_chats (channel TEXT NOT NULL, chat_id INTEGER NOT NULL, session_id TEXT, updated_at REAL, PRIMARY KEY (channel, chat_id))")
    if "channel" not in {row[1] for row in cursor.execute("PRAGMA table_info(telegram_tasks)")}:
        cursor.execute("ALTER TABLE telegram_tasks ADD COLUMN channel TEXT NOT NULL DEFAULT ''")

    # Server restart: mark interrupted
    cursor.execute("UPDATE tasks SET status = 'interrupted' WHERE status IN ('running', 'queued', 'waiting_user')")
    cursor.execute("UPDATE approvals SET status = 'expired', decided_at = ? WHERE status = 'pending'", (time.time(),))
    cursor.execute("UPDATE routine_runs SET status = 'interrupted', finished_at = ? WHERE status IN ('running', 'waiting_user')", (time.time(),))
    conn.commit()
    conn.close()

init_db()

active_tasks = {}
active_tasks_lock = threading.Lock()

def set_task_cancelled(task_id):
    with active_tasks_lock:
        if task_id in active_tasks:
            active_tasks[task_id]["cancelled"] = True
            proc = active_tasks[task_id].get("process")
            if proc and proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
        else:
            active_tasks[task_id] = {"process": None, "cancelled": True, "pid": None}

def is_task_cancelled(task_id):
    with active_tasks_lock:
        entry = active_tasks.get(task_id, {})
        if entry.get("cancelled", False):
            return True
        parent = entry.get("parent")
        # 子代理随父任务一起取消
        return bool(parent) and active_tasks.get(parent, {}).get("cancelled", False)

def get_session_workspace(session_id):
    ws = os.path.join(GLOBAL_WORKSPACE, session_id)
    os.makedirs(ws, exist_ok=True)
    return ws

def safe_path_resolve(session_id, user_path):
    ws = get_session_workspace(session_id)
    if not user_path:
        return None, "Missing path"
    try:
        joined = os.path.join(ws, user_path)
        real_target = os.path.realpath(joined)
        real_ws = os.path.realpath(ws)
        if os.path.commonpath([real_target, real_ws]) != real_ws:
            return None, "Access denied: path outside session workspace"
        return real_target, None
    except Exception as e:
        return None, str(e)

def validate_base_url(url_str):
    if not isinstance(url_str, str) or not url_str.strip():
        return False, "Invalid base_url: must be non-empty string"
    try:
        p = urlparse(url_str)
        if p.scheme not in ("http", "https") or not p.netloc:
            return False, "Invalid base_url: invalid scheme or host"
        if p.username or p.password or p.fragment:
            return False, "Invalid base_url: credentials or fragment not allowed"
        return True, ""
    except Exception as e:
        return False, f"Invalid base_url: {e}"

def sanitize_err(e):
    import re
    s = str(e)
    s = re.sub(r'sk-[a-zA-Z0-9\-_]{20,}', 'sk-***REDACTED***', s)
    s = re.sub(r'Bearer\s+[a-zA-Z0-9\-_.\s]+', 'Bearer ***REDACTED***', s)
    return s

CREDENTIAL_NAME_RE = re.compile(r'^[A-Za-z0-9_.:-]{1,64}$')

def credential_aad(name):
    return "credential:" + name

def credential_hint(api_key):
    # 只保留末 4 位便于用户辨认，短 Key 不显示任何字符
    return ("…" + api_key[-4:]) if len(api_key) >= 12 else "…"

def put_credential(name, api_key, base_url, protocol="chat"):
    box = cloud_secrets.get_box()
    blob = box.encrypt(api_key, credential_aad(name))
    now = time.time()
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("SELECT created_at FROM credentials WHERE name = ?", (name,))
        row = c.fetchone()
        if row:
            c.execute("UPDATE credentials SET protocol = ?, base_url = ?, ciphertext = ?, key_hint = ?, updated_at = ? WHERE name = ?",
                      (protocol, base_url, blob, credential_hint(api_key), now, name))
        else:
            c.execute("INSERT INTO credentials (name, protocol, base_url, ciphertext, key_hint, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                      (name, protocol, base_url, blob, credential_hint(api_key), now, now))
        conn.commit()
        return not bool(row)
    finally:
        conn.close()

def delete_credential(name):
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("DELETE FROM credentials WHERE name = ?", (name,))
        conn.commit()
        return c.rowcount > 0
    finally:
        conn.close()

def list_credentials():
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("SELECT name, protocol, base_url, key_hint, created_at, updated_at FROM credentials ORDER BY name ASC")
        return [{"name": r[0], "protocol": r[1], "base_url": r[2], "key_hint": r[3], "created_at": r[4], "updated_at": r[5]} for r in c.fetchall()]
    finally:
        conn.close()

def load_credential(name):
    """返回 {"protocol","base_url","api_key"}；不存在返回 None。解密失败抛 SecretDecryptError。"""
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("SELECT protocol, base_url, ciphertext FROM credentials WHERE name = ?", (name,))
        row = c.fetchone()
    finally:
        conn.close()
    if not row:
        return None
    api_key = cloud_secrets.get_box().decrypt(row[2], credential_aad(name))
    return {"protocol": row[0] or "chat", "base_url": row[1], "api_key": api_key}

def resolve_provider(provider):
    """把请求里的 provider 规范为 {"protocol","base_url","api_key"}。
    provider.credential 指向已加密保存的凭据；否则沿用请求内存中的 api_key。
    返回 (provider_config, http_status, error)。"""
    if not isinstance(provider, dict):
        return None, 400, "provider must be a dictionary"
    protocol = provider.get("protocol", "chat")
    if not isinstance(protocol, str) or protocol != "chat":
        return None, 400, "Unsupported provider protocol. Only 'chat' is supported."
    cred_name = provider.get("credential")
    if cred_name is not None:
        if not isinstance(cred_name, str) or not CREDENTIAL_NAME_RE.match(cred_name):
            return None, 400, "Invalid credential name"
        try:
            stored = load_credential(cred_name)
        except cloud_secrets.SecretStoreUnavailable as e:
            return None, 503, "Credential store unavailable: " + str(e)
        except cloud_secrets.SecretDecryptError as e:
            return None, 409, str(e)
        if not stored:
            return None, 404, "Credential not found: " + cred_name
        base_url = provider.get("base_url") or stored.get("base_url") or "https://api.openai.com/v1"
        ok, err = validate_base_url(base_url)
        if not ok:
            return None, 400, err
        return {"protocol": "chat", "base_url": base_url, "api_key": stored["api_key"], "credential": cred_name}, 200, None
    api_key = provider.get("api_key", "")
    if not isinstance(api_key, str):
        return None, 400, "api_key must be a string"
    base_url = provider.get("base_url", "https://api.openai.com/v1")
    ok, err = validate_base_url(base_url)
    if not ok:
        return None, 400, err
    return {"protocol": "chat", "base_url": base_url, "api_key": api_key}, 200, None

ACTIVE_TASK_STATUSES = ("running", "waiting_user")

def approval_policy_path():
    return os.environ.get("OPENMINIS_APPROVAL_POLICY_FILE",
                          os.path.join(os.path.dirname(os.path.abspath(DB_PATH)), "approval_policy.json"))

def current_approval_policy():
    return cloud_policy.load_policy(approval_policy_path())

# approval_id -> {"event": threading.Event, "decision": str|None, "note": str|None, "task_id": str}
pending_approvals = {}
pending_approvals_lock = threading.Lock()

def current_notify_config():
    """解密推送配置；未配置或加密存储不可用时返回 None。"""
    conn = get_db_connection()
    try:
        return cloud_notify.load(conn)
    except Exception as e:
        print(f"notify config unavailable: {type(e).__name__}")
        return None
    finally:
        conn.close()

def _session_title(session_id):
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT title FROM sessions WHERE session_id = ?", (session_id,)).fetchone()
        return (row[0] if row else None) or "云端会话"
    finally:
        conn.close()

def on_approval_required(task_id, session_id, approval):
    """审批挂起时推送提醒（Telegram 发起的任务另发带按钮的审批消息），异常不影响任务。"""
    try:
        telegram_notify_approval(task_id, approval)
    except Exception as e:
        print(f"telegram approval notify failed: {type(e).__name__}")
    cfg = current_notify_config()
    if not cfg:
        return None
    args = json.dumps(approval.get("arguments"), ensure_ascii=False)
    body = f"{approval.get('reason', '')}\n工具：{approval.get('tool')}  {args[:300]}\n会话：{_session_title(session_id)}"
    cloud_notify.notify_async(cfg, "approval_required", "云电脑等待你的审批", body)

def on_task_finished(task_id, session_id, final_status):
    """对话任务结束时推送（例行任务由 on_routine_finished 推送；用户主动取消不推送）。"""
    if final_status not in ("completed", "failed", "limit_reached"):
        return None
    conn = get_db_connection()
    try:
        if conn.execute("SELECT 1 FROM routine_runs WHERE task_id = ?", (task_id,)).fetchone():
            return None
        row = conn.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'assistant' AND content IS NOT NULL ORDER BY id DESC LIMIT 1", (session_id,)).fetchone()
    finally:
        conn.close()
    cfg = current_notify_config()
    if not cfg:
        return None
    label = {"completed": "已完成", "failed": "失败", "limit_reached": "达到轮数上限"}[final_status]
    body = ((row[0] if row else "") or "").strip()[:600] or "（无文字回复）"
    cloud_notify.notify_async(cfg, "task_completed", f"云电脑任务{label}：{_session_title(session_id)}"[:120], body)

def request_approval(task_id, session_id, tool_call_id, tool_name, args, rule, timeout_seconds):
    """挂起任务直到用户批准、拒绝、超时或取消。返回 approved / denied / expired / cancelled。"""
    approval_id = "appr_" + uuid.uuid4().hex[:12]
    now = time.time()
    expires_at = now + timeout_seconds
    waiter = {"event": threading.Event(), "decision": None, "note": None, "task_id": task_id}
    with pending_approvals_lock:
        pending_approvals[approval_id] = waiter
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("INSERT INTO approvals (approval_id, task_id, tool_call_id, tool, arguments, rule_id, category, reason, status, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
                  (approval_id, task_id, tool_call_id, tool_name, json.dumps(args, ensure_ascii=False), rule["id"], rule["category"], rule["reason"], now, expires_at))
        c.execute("UPDATE tasks SET status = 'waiting_user' WHERE task_id = ? AND status = 'running'", (task_id,))
        conn.commit()
    finally:
        conn.close()
    approval = {"approval_id": approval_id, "tool_call_id": tool_call_id, "tool": tool_name, "arguments": args,
                "rule_id": rule["id"], "category": rule["category"], "reason": rule["reason"], "expires_at": expires_at}
    log_event(task_id, "approval_required", approval)
    try:
        on_approval_required(task_id, session_id, approval)
    except Exception:
        pass

    decision = None
    while decision is None:
        if waiter["event"].wait(0.25):
            decision = waiter["decision"]
        elif is_task_cancelled(task_id):
            decision = "cancelled"
        elif time.time() >= expires_at:
            decision = "expired"
    with pending_approvals_lock:
        pending_approvals.pop(approval_id, None)
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("UPDATE approvals SET status = ?, note = ?, decided_at = ? WHERE approval_id = ? AND status = 'pending'",
                  (decision, waiter.get("note"), time.time(), approval_id))
        if decision != "cancelled":
            c.execute("UPDATE tasks SET status = 'running' WHERE task_id = ? AND status = 'waiting_user'", (task_id,))
        conn.commit()
    finally:
        conn.close()
    log_event(task_id, "approval_resolved", {"approval_id": approval_id, "tool_call_id": tool_call_id, "decision": decision})
    return decision

def resolve_approval(task_id, approval_id, decision, note=None):
    """返回 (http_status, body)。"""
    with pending_approvals_lock:
        waiter = pending_approvals.get(approval_id)
        if waiter and waiter["task_id"] == task_id and waiter["decision"] is None:
            waiter["decision"] = decision
            waiter["note"] = note
            waiter["event"].set()
            return 200, {"approval_id": approval_id, "task_id": task_id, "status": decision}
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("SELECT status FROM approvals WHERE approval_id = ? AND task_id = ?", (approval_id, task_id))
        row = c.fetchone()
    finally:
        conn.close()
    if not row:
        return 404, {"error": "Approval not found"}
    return 409, {"error": "Approval already resolved", "approval_id": approval_id, "status": row[0]}

def list_approvals(task_id):
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("SELECT approval_id, tool_call_id, tool, arguments, rule_id, category, reason, status, note, created_at, expires_at, decided_at FROM approvals WHERE task_id = ? ORDER BY created_at ASC", (task_id,))
        rows = c.fetchall()
    finally:
        conn.close()
    out = []
    for r in rows:
        try: args = json.loads(r[3])
        except Exception: args = {}
        out.append({"approval_id": r[0], "tool_call_id": r[1], "tool": r[2], "arguments": args, "rule_id": r[4],
                    "category": r[5], "reason": r[6], "status": r[7], "note": r[8], "created_at": r[9],
                    "expires_at": r[10], "decided_at": r[11]})
    return out

def log_event(task_id, etype, payload):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute(
        "INSERT INTO task_events (task_id, event_type, payload, timestamp) VALUES (?, ?, ?, ?)",
        (task_id, etype, json.dumps(payload, ensure_ascii=False), time.time())
    )
    conn.commit()
    conn.close()

def tool_shell_execute(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Task was cancelled"}
    cmd = args.get("command", "")
    timeout = int(args.get("timeout", 60))
    if not cmd:
        return {"error": "Missing command"}
    ws = get_session_workspace(session_id)
    try:
        with tempfile.TemporaryFile() as out_f, tempfile.TemporaryFile() as err_f:
            proc = subprocess.Popen(cmd, shell=True, stdout=out_f, stderr=err_f, cwd=ws, start_new_session=True)
            with active_tasks_lock:
                if task_id in active_tasks:
                    active_tasks[task_id]["process"] = proc
                    active_tasks[task_id]["pid"] = proc.pid
            start_t = time.time()
            while proc.poll() is None:
                if is_task_cancelled(task_id):
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except Exception:
                        proc.kill()
                    proc.wait()
                    return {"error": "Command terminated due to cancellation"}
                if time.time() - start_t > timeout:
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except Exception:
                        proc.kill()
                    proc.wait()
                    return {"error": f"Timeout after {timeout}s"}
                time.sleep(0.1)
            proc.wait()
            out_f.seek(0)
            err_f.seek(0)
            return {
                "exit_code": proc.returncode,
                "stdout": out_f.read(32768).decode("utf-8", "replace"),
                "stderr": err_f.read(32768).decode("utf-8", "replace")
            }
    except Exception as e:
        return {"error": str(e)}

def tool_file_read(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    target, err = safe_path_resolve(session_id, args.get("path", ""))
    if err:
        return {"error": err}
    if not os.path.exists(target) or not os.path.isfile(target):
        return {"error": "Not found"}
    try:
        if os.path.getsize(target) > 2 * 1024 * 1024:
            return {"error": "Too large (>2MB)"}
        with open(target, "r", encoding="utf-8") as f:
            return {"content": f.read()}
    except Exception as e:
        return {"error": str(e)}

def tool_file_write(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    target, err = safe_path_resolve(session_id, args.get("path", ""))
    if err:
        return {"error": err}
    try:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as f:
            f.write(args.get("content", ""))
        return {"status": "success", "path": args.get("path")}
    except Exception as e:
        return {"error": str(e)}

def tool_file_edit(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    target, err = safe_path_resolve(session_id, args.get("path", ""))
    if err:
        return {"error": err}
    if not os.path.exists(target):
        return {"error": "Not found"}
    try:
        with open(target, "r", encoding="utf-8") as f:
            content = f.read()
        old_s, new_s = args.get("old_string", ""), args.get("new_string", "")
        if old_s not in content:
            return {"error": "old_string not found"}
        with open(target, "w", encoding="utf-8") as f:
            f.write(content.replace(old_s, new_s, 1))
        return {"status": "success", "path": args.get("path")}
    except Exception as e:
        return {"error": str(e)}

def tool_browser_action(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    ws = get_session_workspace(session_id)
    return cloud_browser.execute_browser_action(session_id, ws, args)

def tool_desktop_action(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    ws = get_session_workspace(session_id)
    return cloud_desktop.execute_desktop_action(session_id, ws, args)

def tool_memory_write(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    conn = get_db_connection()
    try:
        entry, created = cloud_memory.write(conn, args.get("content"), args.get("category"), source="cloud", session_id=session_id,
                                            persona=session_persona_id(session_id) or "")
    except ValueError as e:
        return {"error": str(e)}
    finally:
        conn.close()
    return {"saved": created, "duplicate": not created, "id": entry["id"], "category": entry["category"], "entry_time": entry["entry_time"]}

def tool_memory_search(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    conn = get_db_connection()
    try:
        results = cloud_memory.search(conn, args.get("query", ""), args.get("category") or None, args.get("limit", 10),
                                      persona=session_persona_id(session_id) or "")
    except (ValueError, TypeError) as e:
        return {"error": str(e)}
    finally:
        conn.close()
    total = 0
    out = []
    for r in results:
        text = r["content"] if len(r["content"]) <= 4000 else r["content"][:4000] + "…"
        total += len(text)
        out.append({"id": r["id"], "category": r["category"], "entry_time": r["entry_time"], "source": r["source"], "content": text})
        if total > 30000:
            break
    return {"count": len(out), "results": out}

SERVER_TOOL_NOTES = (
    "\n\n[云端记忆] memory_search 按关键词检索用户的长期记忆（手机同步的 memory/ 日志与 GLOBAL.md，以及云端写入的条目），"
    "开始新话题或需要用户偏好、人物、项目背景时先检索；memory_write 保存值得长期记住的新事实，category 取 "
    "profile（用户本人）/ rules（偏好与约定）/ people（人物）/ workstreams（项目进展）/ note（其他）。不要写入密码、密钥等凭据。"
    "\n[页面库] 报告、表格、看板、可交互的小工具等适合长期查看的成果，用 page_write 保存为完整 HTML 页面（可内联 CSS/JS，不能依赖外部登录态），"
    "用户可在手机“云端页面库”中打开；更新同一页面时传回 page_id。"
    "\n[子代理] 可拆分、互不依赖的子任务可用 subagent_task 交给独立会话的子代理执行，它返回最终结论；子代理不能再派生子代理。"
    "\n[生成图片] 用户要图片时调用 image_generate，图片保存在工作区 attachments/。"
    "\n[发消息] send_message 可经 Telegram 或推送给用户发消息；每次都会先作为草稿请用户确认，被拒绝时不要重试同一内容。"
)

PLUGINS = cloud_plugins.Registry(lambda: get_db_connection(), os.path.join(BASE_DIR, "plugin-files"), cloud_skills)
import atexit
atexit.register(PLUGINS.close_all)

def plugin_tools_for_session(session_id, depth):
    """返回 (工具定义, 名称映射, 系统提示补充)。插件出错不影响任务本身。"""
    try:
        defs, mapping, unavailable = PLUGINS.tool_definitions(session_bot(session_id))
    except Exception as e:
        print(f"plugin tools failed: {e}")
        return [], {}, ""
    note = ""
    if mapping:
        note += "\n[插件] 名为 mcp__<插件>__<工具> 的函数来自用户安装的 MCP 插件，结果以插件真实返回为准。"
    if unavailable:
        note += "\n[插件不可用] " + "；".join(
            f"{p['name']}（{'需要授权：请用户在手机“插件”页填写密钥' if 'needs_auth' in err else err[:80]}）" for p, err in unavailable[:10])
    return defs, mapping, note

PERSONA_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")

def session_persona_id(session_id):
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT persona_id FROM sessions WHERE session_id = ?", (session_id,)).fetchone()
        return row[0] if row and row[0] else None
    finally:
        conn.close()

def get_persona(persona_id):
    if not persona_id:
        return None
    conn = get_db_connection()
    try:
        return cloud_bots.get(conn, persona_id)
    finally:
        conn.close()

def credential_exists(name):
    return bool(CREDENTIAL_NAME_RE.match(name)) and any(c["name"] == name for c in list_credentials())

def bot_detail(bot):
    conn = get_db_connection()
    try:
        pid = bot["persona_id"]
        out = dict(bot)
        out["session_count"] = conn.execute("SELECT COUNT(*) FROM sessions WHERE persona_id = ?", (pid,)).fetchone()[0]
        out["routine_count"] = conn.execute("SELECT COUNT(*) FROM routines WHERE persona_id = ?", (pid,)).fetchone()[0]
        out["memory_count"] = conn.execute("SELECT COUNT(*) FROM memory_entries WHERE persona = ?", (pid,)).fetchone()[0]
        out["telegram"] = conn.execute("SELECT 1 FROM secure_settings WHERE name = ?", (telegram_setting_name(pid),)).fetchone() is not None
        return out
    finally:
        conn.close()

def import_bot_bundle(req):
    bundle = req.get("bundle")
    if not isinstance(bundle, dict) or bundle.get("format") != cloud_bots.EXPORT_FORMAT or not isinstance(bundle.get("bot"), dict):
        raise cloud_bots.BotError("bundle must be an openminis-bot/1 export")
    base = req.get("bot_id") or bundle.get("bot_id") or "bot"
    if not isinstance(base, str) or not cloud_bots.BOT_ID_RE.match(base):
        raise cloud_bots.BotError("bot_id must match ^[a-z0-9][a-z0-9_-]{0,31}$")
    conn = get_db_connection()
    try:
        bot_id, n = base, 2
        while cloud_bots.get(conn, bot_id):
            bot_id = f"{base[:28]}-{n}"
            n += 1
        body = {k: v for k, v in bundle["bot"].items() if k in ("name", "emoji", "description", "instructions", "skills", "plugins")}
        if req.get("credential") and (req.get("model") or bundle["bot"].get("model")):
            body["credential"] = req["credential"]
            body["model"] = req.get("model") or bundle["bot"].get("model")
        bot, _ = cloud_bots.upsert(conn, bot_id, body, credential_exists)
        imported_memory = 0
        for m in (bundle.get("memory") or [])[:2000]:
            if isinstance(m, dict) and isinstance(m.get("content"), str) and m["content"].strip():
                try:
                    _, created = cloud_memory.write(conn, m["content"], m.get("category"), source="import", entry_time=m.get("entry_time"), commit=False, persona=bot_id)
                    imported_memory += 1 if created else 0
                except ValueError:
                    pass
        conn.commit()
    finally:
        conn.close()
    created_routines, skipped = [], []
    cred = req.get("credential")
    model = req.get("model") or bundle["bot"].get("model")
    for r in (bundle.get("routines") or [])[:50]:
        if not isinstance(r, dict):
            continue
        if not cred or not model:
            skipped.append(r.get("name"))
            continue
        try:
            fields = validate_routine_fields(dict(r, credential=cred, model=model, persona_id=bot_id, enabled=False))
            created_routines.append(create_routine(fields)["routine_id"])
        except ValueError:
            skipped.append(r.get("name"))
    return {"bot": bot, "memory_imported": imported_memory, "routines_created": created_routines,
            "routines_skipped": skipped, "note": "导入的例行任务默认停用，确认后再启用" if created_routines else None}

def primary_bot_id():
    conn = get_db_connection()
    try:
        p = cloud_bots.primary(conn)
    finally:
        conn.close()
    return p["persona_id"] if p else None

def list_personas():
    conn = get_db_connection()
    try:
        rows = conn.execute("SELECT persona_id FROM personas ORDER BY created_at ASC").fetchall()
    finally:
        conn.close()
    return [get_persona(r[0]) for r in rows]

def validate_persona_ref(value):
    """None / '' 表示默认人格；其余必须是已存在的 persona_id。"""
    if value in (None, ""):
        return None
    if not isinstance(value, str) or not PERSONA_ID_RE.match(value) or not get_persona(value):
        raise ValueError("persona_id does not exist")
    return value

def persona_prompt(session_id):
    p = get_persona(session_persona_id(session_id))
    if not p:
        return ""
    return cloud_bots.prompt(p, [b for b in list_personas() if b["persona_id"] != p["persona_id"]])

def mention_note(session_id, content):
    """用户消息里 @ 了其他 Bot 时，提示模型用 subagent_task(persona=...) 转交。"""
    if not isinstance(content, str) or "@" not in content:
        return ""
    own = session_persona_id(session_id)
    bots = [b for b in list_personas() if b["persona_id"] != own]
    ids = cloud_bots.mentions(content, bots)
    if not ids:
        return ""
    return "\n[@提及] 用户在消息中 @ 了：" + "、".join(ids) + "。请用 subagent_task 并传 persona 把相应部分交给这些 Bot，再把它们的答复整合给用户。"

def session_bot(session_id):
    return get_persona(session_persona_id(session_id))

def server_tool_notes(session_id):
    """追加到 system 消息的服务端工具说明（客户端 instructions 不了解服务端新增工具）与技能索引。"""
    conn = get_db_connection()
    bot = session_bot(session_id)
    try:
        skills_index = cloud_skills.index_text(conn, lambda n: cloud_bots.skill_allowed(bot, n))
    except Exception as e:
        print(f"skills index failed: {e}")
        skills_index = ""
    finally:
        conn.close()
    try:
        own = session_persona_id(session_id)
        others = [p for p in list_personas() if p["persona_id"] != own]
    except Exception:
        others = []
    personas_note = ""
    if others:
        personas_note = "\n[其他人格] 需要其他人格的专长或它们的私有记忆时，用 subagent_task 并传 persona 询问：" + "；".join(
            f"{p['persona_id']}（{p['name']}）" for p in others[:20])
    return SERVER_TOOL_NOTES + personas_note + skills_index

def tool_skill_load(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    name = args.get("name")
    conn = get_db_connection()
    try:
        bot = session_bot(session_id)
        skill = cloud_skills.load(conn, name) if isinstance(name, str) and cloud_bots.skill_allowed(bot, name) else None
        if not skill:
            names = [s["name"] for s in cloud_skills.list_index(conn) if cloud_bots.skill_allowed(bot, s["name"])]
            close = [n for n in names if isinstance(name, str) and name.lower() in n.lower()][:10]
            return {"error": f"技能不存在：{name}", "similar": close}
    finally:
        conn.close()
    return {"name": skill["name"], "description": skill["description"], "content": skill["content"]}

def tool_page_write(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    conn = get_db_connection()
    try:
        page = cloud_pages.write(conn, args.get("title"), args.get("html"), page_id=args.get("page_id") or None,
                                 session_id=session_id, task_id=task_id)
    except ValueError as e:
        return {"error": str(e)}
    except KeyError:
        return {"error": f"page_id 不存在：{args.get('page_id')}"}
    finally:
        conn.close()
    return {"status": "ok", "page_id": page["page_id"], "title": page["title"], "version": page["version"], "size": page["size"]}

SUBAGENT_MAX_PER_TASK = int(os.environ.get("OPENMINIS_SUBAGENT_MAX", "8"))
SUBAGENT_INSTRUCTIONS = (
    "你是 OpenMinis 云端子代理，在用户的 Linux 云电脑上独立完成父代理交给你的一个子任务。"
    "只做这个子任务，用工具核实结果，最后用简洁中文给出结论与关键依据（会原样返回给父代理）。不能再派生子代理。"
)

def tool_subagent_task(task_id, session_id, args, model, provider_config, depth):
    if depth >= 1:
        return {"error": "子代理不能再派生子代理"}
    prompt = args.get("task")
    if not isinstance(prompt, str) or not prompt.strip():
        return {"error": "task must be a non-empty string"}
    title = (args.get("title") or prompt.strip().splitlines()[0])[:60]
    target_persona = args.get("persona")
    if target_persona in (None, ""):
        target_persona = session_persona_id(session_id)
        title_prefix = "子代理："
    else:
        target = get_persona(target_persona) if isinstance(target_persona, str) else None
        if not target:
            return {"error": f"人格不存在：{target_persona}", "personas": [p["persona_id"] for p in list_personas()]}
        title_prefix = "询问" + target["name"] + "："
    with active_tasks_lock:
        parent_entry = active_tasks.get(task_id)
        if parent_entry is not None:
            used = parent_entry.get("subagents", 0)
            if used >= SUBAGENT_MAX_PER_TASK:
                return {"error": f"本任务子代理数量已达上限 {SUBAGENT_MAX_PER_TASK}"}
            parent_entry["subagents"] = used + 1
    sid = "sess_" + uuid.uuid4().hex[:12]
    tid = "task_" + uuid.uuid4().hex[:12]
    now = time.time()
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, NULL, ?, ?, ?, ?)",
                  (sid, title_prefix + title, SUBAGENT_INSTRUCTIONS, now, target_persona))
        c.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, NULL, 'running', ?, ?)",
                  (tid, sid, model, now))
        c.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)", (sid, prompt, now))
        conn.commit()
    finally:
        conn.close()
    with active_tasks_lock:
        active_tasks[tid] = {"process": None, "cancelled": False, "pid": None, "parent": task_id}
    log_event(task_id, "subagent_started", {"task_id": tid, "session_id": sid, "title": title})
    run_agent_task(tid, sid, prompt, model, provider_config, SUBAGENT_INSTRUCTIONS, depth=depth + 1)
    conn = get_db_connection()
    try:
        c = conn.cursor()
        status = (c.execute("SELECT status FROM tasks WHERE task_id = ?", (tid,)).fetchone() or ["failed"])[0]
        last = c.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'assistant' AND content IS NOT NULL ORDER BY id DESC LIMIT 1", (sid,)).fetchone()
    finally:
        conn.close()
    result = (last[0] if last else "") or ""
    log_event(task_id, "subagent_finished", {"task_id": tid, "session_id": sid, "status": status})
    out = {"status": status, "subagent_task_id": tid, "subagent_session_id": sid, "persona": target_persona, "result": result[:20000]}
    if status != "completed":
        out["error"] = f"子代理结束状态：{status}"
    return out

# 对外发消息：先以草稿形式挂起审批，用户确认后才发送（不受自定义策略影响）
ALWAYS_CONFIRM_TOOLS = {
    "send_message": {"id": "send_message_draft", "tool": "send_message", "field": "*", "pattern": ".",
                     "category": "outbound", "reason": "对外发送消息（草稿，确认后发送）"},
}

def tool_send_message(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    channel = args.get("channel")
    text = args.get("text")
    if not isinstance(text, str) or not text.strip():
        return {"error": "text must be a non-empty string"}
    if channel == "telegram":
        tg_channel = telegram_channel_for_task(task_id)
        if tg_channel is None:
            bot = session_bot(session_id)
            tg_channel = bot["persona_id"] if bot and telegram_config(bot["persona_id"]) else ""
        cfg = telegram_config(tg_channel)
        if not cfg:
            return {"error": "Telegram 渠道未配置"}
        chat_id = args.get("chat_id")
        allowed = cfg.get("allowed_chat_ids", [])
        if chat_id is None:
            chat_id = telegram_chat_for_task(task_id) or (allowed[0] if allowed else None)
        if not isinstance(chat_id, int) or chat_id not in allowed:
            return {"error": "chat_id 不在 Telegram 允许列表中"}
        try:
            cloud_telegram.send_text(cfg, chat_id, text)
        except cloud_telegram.TelegramAPIError as e:
            return {"error": "Telegram 发送失败：" + str(e)}
        return {"status": "sent", "channel": "telegram", "chat_id": chat_id}
    if channel == "push":
        cfg = current_notify_config()
        if not cfg:
            return {"error": "推送未配置"}
        ok, err = cloud_notify.send_now(cfg, (args.get("title") or "OpenMinis 云电脑")[:120], text, event="send_message")
        return {"status": "sent", "channel": "push"} if ok else {"error": "推送失败：" + str(err)}
    return {"error": "channel must be telegram or push"}

IMAGE_MODEL_DEFAULT = os.environ.get("OPENMINIS_IMAGE_MODEL", "gpt-image-1")
IMAGE_SIZES = ("1024x1024", "1024x1536", "1536x1024", "512x512", "auto")

def tool_image_generate(task_id, session_id, args, provider_config):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    prompt = args.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return {"error": "prompt must be a non-empty string"}
    size = args.get("size") or "1024x1024"
    if size not in IMAGE_SIZES:
        return {"error": "size must be one of " + ", ".join(IMAGE_SIZES)}
    model = args.get("model") or IMAGE_MODEL_DEFAULT
    url = f"{provider_config.get('base_url', 'https://api.openai.com/v1').rstrip('/')}/images/generations"
    try:
        resp = call_llm(url, {"Content-Type": "application/json", "Authorization": f"Bearer {provider_config.get('api_key', '')}"},
                        {"model": model, "prompt": prompt[:4000], "size": size, "n": 1})
        item = (resp.get("data") or [{}])[0]
        import base64
        if item.get("b64_json"):
            png = base64.b64decode(item["b64_json"])
        elif item.get("url", "").startswith(("https://", "http://")):
            opener = urllib.request.build_opener(NoRedirect)
            with opener.open(urllib.request.Request(item["url"]), timeout=60) as r:
                png = r.read(20 * 1024 * 1024 + 1)
            if len(png) > 20 * 1024 * 1024:
                return {"error": "生成的图片超过 20MB"}
        else:
            return {"error": "图片服务没有返回 b64_json 或 url"}
    except Exception as e:
        return {"error": "图片生成失败：" + sanitize_err(e)}
    ws = get_session_workspace(session_id)
    os.makedirs(os.path.join(ws, "attachments"), exist_ok=True)
    ext = "jpg" if png[:3] == b"\xff\xd8\xff" else ("webp" if png[8:12] == b"WEBP" else "png")
    filename = f"image_{uuid.uuid4().hex[:8]}.{ext}"
    with open(os.path.join(ws, "attachments", filename), "wb") as f:
        f.write(png)
    return {"status": "ok", "action": "image_generate", "file_path": f"attachments/{filename}",
            "attachment_url": f"/v1/sessions/{session_id}/attachments/{filename}", "bytes": len(png),
            "revised_prompt": item.get("revised_prompt")}

TOOL_DEFINITIONS = [
    {
        "type": "function",
        "function": {
            "name": "shell_execute",
            "description": "Execute shell command in isolated session workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string"},
                    "timeout": {"type": "integer"}
                },
                "required": ["command"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_read",
            "description": "Read file content from session workspace.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_write",
            "description": "Write text content to file in session workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"}
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_edit",
            "description": "Targeted edit in session workspace file via string replacement.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "old_string": {"type": "string"},
                    "new_string": {"type": "string"}
                },
                "required": ["path", "old_string", "new_string"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "browser_action",
            "description": "Control Playwright Chromium browser on persistent workspace profile.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["navigate", "get_text", "click", "type", "scroll", "screenshot", "tabs", "close_tab"]},
                    "url": {"type": "string"},
                    "selector": {"type": "string"},
                    "text": {"type": "string"},
                    "direction": {"type": "string", "enum": ["up", "down"]},
                    "amount": {"type": "integer"},
                    "full_page": {"type": "boolean"}
                },
                "required": ["action"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "desktop_action",
            "description": "Interact with VPS X11 desktop (DISPLAY=:99) using scrot / xdotool.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["screenshot", "click", "mouse_move", "type", "key"]},
                    "x": {"type": "integer"},
                    "y": {"type": "integer"},
                    "text": {"type": "string"},
                    "key": {"type": "string"},
                    "button": {"type": "integer"}
                },
                "required": ["action"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "memory_write",
            "description": "Save one long-term memory entry (shared with the user's phone). Keep it concise and self-contained; never store secrets.",
            "parameters": {
                "type": "object",
                "properties": {
                    "content": {"type": "string", "description": "Concise Markdown, ideally with a short '## Topic' heading."},
                    "category": {"type": "string", "enum": list(cloud_memory.CATEGORIES), "description": "profile / rules / people / workstreams / note (default note)."}
                },
                "required": ["content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "memory_search",
            "description": "Full-text search over the user's long-term memory (phone daily logs, GLOBAL.md and cloud entries). Space-separated keywords; Chinese substrings work. Empty query returns the most recent entries.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "category": {"type": "string", "enum": list(cloud_memory.CATEGORIES)},
                    "limit": {"type": "integer", "description": "1-50, default 10"}
                },
                "required": ["query"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "skill_load",
            "description": "Load the full SKILL.md of one skill from the index in the system prompt. Call it before following a skill.",
            "parameters": {
                "type": "object",
                "properties": {"name": {"type": "string", "description": "Exact skill name from the index."}},
                "required": ["name"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "page_write",
            "description": "Save a report / dashboard / small interactive tool as an HTML page in the user's Pages library (viewable on the phone). Pass page_id to update an existing page.",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "html": {"type": "string", "description": "Full HTML document or a body fragment; inline CSS/JS only, max 2MB."},
                    "page_id": {"type": "string", "description": "Existing page_id to update (optional)."}
                },
                "required": ["title", "html"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "subagent_task",
            "description": "Delegate one self-contained sub task to a sub agent with its own fresh session and the same tools; blocks until it finishes and returns its final answer.",
            "parameters": {
                "type": "object",
                "properties": {
                    "task": {"type": "string", "description": "Complete instructions; the sub agent cannot see this conversation."},
                    "title": {"type": "string", "description": "Short label."},
                    "persona": {"type": "string", "description": "Optional persona_id: run the sub agent as another persona (its instructions and private memory) to consult that bot. Defaults to the current persona."}
                },
                "required": ["task"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "image_generate",
            "description": "Generate an image with the provider's /images/generations endpoint and save it under attachments/.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prompt": {"type": "string"},
                    "size": {"type": "string", "enum": list(IMAGE_SIZES)},
                    "model": {"type": "string", "description": "Image model (default from OPENMINIS_IMAGE_MODEL or gpt-image-1)."}
                },
                "required": ["prompt"]
            }
        }
    }
]

TOOL_DEFINITIONS.append({
    "type": "function",
    "function": {
        "name": "send_message",
        "description": "Send a message to the user through Telegram or their push service. Every call is shown to the user as a draft and only sent after they approve it.",
        "parameters": {
            "type": "object",
            "properties": {
                "channel": {"type": "string", "enum": ["telegram", "push"]},
                "text": {"type": "string"},
                "title": {"type": "string", "description": "Push title (push only)."},
                "chat_id": {"type": "integer", "description": "Telegram chat id from the allow list (default: the chat this task came from, else the first allowed chat)."}
            },
            "required": ["channel", "text"]
        }
    }
})

def tools_for_depth(depth):
    if depth >= 1:
        return [t for t in TOOL_DEFINITIONS if t["function"]["name"] != "subagent_task"]
    return TOOL_DEFINITIONS

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "Redirection prohibited", headers, fp)

def call_llm(url, headers, body):
    opener = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST")
    with opener.open(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))

def run_agent_task(task_id, session_id, initial_content, model, provider_config, instructions, depth=0):
    api_key = provider_config.get("api_key", "")
    chat_url = f"{provider_config.get('base_url', 'https://api.openai.com/v1').rstrip('/')}/chat/completions"

    if is_task_cancelled(task_id):
        return

    conn = get_db_connection()
    c = conn.cursor()
    c.execute("SELECT status FROM tasks WHERE task_id = ?", (task_id,))
    r = c.fetchone()
    if not r or r[0] == 'cancelled':
        conn.close()
        return

    # Retrieve all session messages for LLM context
    c.execute("SELECT role, content, tool_calls, tool_call_id FROM messages WHERE session_id = ? ORDER BY id ASC", (session_id,))
    rows = c.fetchall()
    conn.close()

    plugin_defs, plugin_map, plugin_note = plugin_tools_for_session(session_id, depth)
    system_text = persona_prompt(session_id) + (instructions or "") + server_tool_notes(session_id) + plugin_note + mention_note(session_id, initial_content)
    messages = [{"role": "system", "content": system_text.lstrip()}]
    for r_role, r_content, r_tc, r_tcid in rows:
        m = {"role": r_role}
        if r_content is not None:
            decoded_content = r_content
            if r_role in ('user', 'assistant') and isinstance(r_content, str) and r_content.startswith('['):
                try:
                    candidate = json.loads(r_content)
                    if isinstance(candidate, list) and all(isinstance(part, dict) and part.get('type') in ('text', 'image_url') for part in candidate):
                        decoded_content = candidate
                except (ValueError, TypeError):
                    pass
            m["content"] = decoded_content
        if r_tc:
            try: m["tool_calls"] = json.loads(r_tc)
            except: pass
        if r_tcid:
            m["tool_call_id"] = r_tcid
        messages.append(m)

    log_event(task_id, "started", {"message": "Started"})
    final_status = "completed"

    try:
        for _ in range(MAX_TURNS):
            if is_task_cancelled(task_id):
                final_status = "cancelled"
                break
            try:
                resp = call_llm(chat_url, {"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"}, {
                    "model": model, "messages": messages, "tools": tools_for_depth(depth) + plugin_defs, "tool_choice": "auto", "stream": False
                })
            except Exception as e:
                log_event(task_id, "error", {"error": sanitize_err(e)})
                final_status = "failed"
                break

            choices = resp.get("choices", [])
            if not choices:
                log_event(task_id, "error", {"error": "Missing choices"})
                final_status = "failed"
                break

            msg = choices[0].get("message", {})
            content = msg.get("content")
            tool_calls = msg.get("tool_calls")

            if not content and not tool_calls:
                log_event(task_id, "error", {"error": "Empty model response"})
                final_status = "failed"
                break

            if content and not tool_calls:
                log_event(task_id, "thought", {"content": content})
                messages.append({"role": "assistant", "content": content})
                conn = get_db_connection()
                c = conn.cursor()
                c.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)", (session_id, "assistant", content, time.time()))
                conn.commit()
                conn.close()

            if tool_calls:
                ast_msg = {"role": "assistant"}
                if content:
                    ast_msg["content"] = content
                    log_event(task_id, "thought", {"content": content})
                else:
                    ast_msg["content"] = None
                ast_msg["tool_calls"] = tool_calls
                messages.append(ast_msg)

                conn = get_db_connection()
                c = conn.cursor()
                c.execute("INSERT INTO messages (session_id, role, content, tool_calls, timestamp) VALUES (?, ?, ?, ?, ?)", 
                          (session_id, "assistant", content, json.dumps(tool_calls, ensure_ascii=False), time.time()))
                conn.commit()
                conn.close()

                for tc in tool_calls:
                    if is_task_cancelled(task_id):
                        final_status = "cancelled"
                        break
                    tc_id = tc.get("id")
                    fn = tc.get("function", {})
                    fn_name = fn.get("name")
                    try: fn_args = json.loads(fn.get("arguments", "{}"))
                    except: fn_args = {}

                    log_event(task_id, "tool_call", {"id": tc_id, "tool": fn_name, "arguments": fn_args})
                    if is_task_cancelled(task_id):
                        final_status = "cancelled"
                        break

                    policy = current_approval_policy()
                    hit = cloud_policy.evaluate(fn_name, fn_args, policy)
                    if not hit and fn_name in ALWAYS_CONFIRM_TOOLS:
                        hit = ALWAYS_CONFIRM_TOOLS[fn_name]
                    if not hit and fn_name in plugin_map and PLUGINS.needs_confirm(*plugin_map[fn_name]):
                        hit = {"id": "plugin_confirm", "tool": fn_name, "field": "*", "pattern": ".", "category": "outbound",
                               "reason": f"插件 {plugin_map[fn_name][0]} 的写操作 {plugin_map[fn_name][1]}"}
                    decision = None
                    if hit:
                        decision = request_approval(task_id, session_id, tc_id, fn_name, fn_args, hit, policy.get("timeout_seconds", 1800))
                        if decision == "cancelled" or is_task_cancelled(task_id):
                            final_status = "cancelled"
                            break

                    if hit and decision != "approved":
                        label = {"denied": "用户拒绝", "expired": "审批超时未获批准"}.get(decision, decision)
                        res = {"error": f"{label}，未执行：{hit['reason']}", "approval": decision, "rule_id": hit["id"]}
                    elif fn_name == "shell_execute": res = tool_shell_execute(task_id, session_id, fn_args)
                    elif fn_name == "file_read": res = tool_file_read(task_id, session_id, fn_args)
                    elif fn_name == "file_write": res = tool_file_write(task_id, session_id, fn_args)
                    elif fn_name == "file_edit": res = tool_file_edit(task_id, session_id, fn_args)
                    elif fn_name == "browser_action": res = tool_browser_action(task_id, session_id, fn_args)
                    elif fn_name == "desktop_action": res = tool_desktop_action(task_id, session_id, fn_args)
                    elif fn_name == "memory_write": res = tool_memory_write(task_id, session_id, fn_args)
                    elif fn_name == "memory_search": res = tool_memory_search(task_id, session_id, fn_args)
                    elif fn_name == "skill_load": res = tool_skill_load(task_id, session_id, fn_args)
                    elif fn_name == "page_write": res = tool_page_write(task_id, session_id, fn_args)
                    elif fn_name == "subagent_task": res = tool_subagent_task(task_id, session_id, fn_args, model, provider_config, depth)
                    elif fn_name == "image_generate": res = tool_image_generate(task_id, session_id, fn_args, provider_config)
                    elif fn_name == "send_message": res = tool_send_message(task_id, session_id, fn_args)
                    elif fn_name in plugin_map:
                        res = PLUGINS.call(plugin_map[fn_name][0], plugin_map[fn_name][1], fn_args)
                        if isinstance(res, dict) and res.get("error") == "needs_auth":
                            log_event(task_id, "auth_required", {"plugin": res.get("plugin"), "message": res.get("message")})
                    else: res = {"error": f"Unknown tool {fn_name}"}

                    log_event(task_id, "tool_result", {"id": tc_id, "tool": fn_name, "result": res})
                    
                    # Tool result formatting: If screenshot produced, include attachment path and format
                    tool_content_str = json.dumps(res, ensure_ascii=False)
                    messages.append({"role": "tool", "tool_call_id": tc_id, "content": tool_content_str})

                    # If model is vision-capable (e.g. gpt-4o, claude-3, gemini-1.5, qwen-vl) and screenshot generated, inject vision user message
                    if isinstance(res, dict) and res.get("status") == "ok" and res.get("action") == "screenshot":
                        rel_file = res.get("file_path")
                        if rel_file:
                            ws = get_session_workspace(session_id)
                            abs_img = os.path.join(ws, rel_file)
                            if os.path.exists(abs_img) and os.path.getsize(abs_img) <= 2 * 1024 * 1024:
                                import base64
                                with open(abs_img, "rb") as im_f:
                                    img_b64 = base64.b64encode(im_f.read()).decode("utf-8")
                                # Append user vision observation for multimodal model comprehension
                                vision_user_msg = {
                                    "role": "user",
                                    "content": [
                                        {"type": "text", "text": f"[Browser/Desktop Screenshot Observation: {rel_file}]"},
                                        {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{img_b64}"}}
                                    ]
                                }
                                messages.append(vision_user_msg)

                    conn = get_db_connection()
                    c = conn.cursor()
                    c.execute("INSERT INTO messages (session_id, role, content, tool_call_id, timestamp) VALUES (?, ?, ?, ?, ?)",
                              (session_id, "tool", tool_content_str, tc_id, time.time()))
                    conn.commit()
                    conn.close()

                if final_status == "cancelled":
                    break
            else:
                break
        else:
            final_status = "limit_reached"
            log_event(task_id, "limit_reached", {"message": f"Reached {MAX_TURNS} turns"})
    except Exception as e:
        if is_task_cancelled(task_id):
            final_status = "cancelled"
        else:
            log_event(task_id, "error", {"error": sanitize_err(e)})
            final_status = "failed"
    finally:
        if is_task_cancelled(task_id):
            final_status = "cancelled"
        conn = get_db_connection()
        c = conn.cursor()
        c.execute("UPDATE tasks SET status = ? WHERE task_id = ? AND status IN ('running', 'waiting_user')", (final_status, task_id))
        conn.commit()
        conn.close()
        with active_tasks_lock:
            active_tasks.pop(task_id, None)
        try:
            if depth == 0:
                on_task_finished(task_id, session_id, final_status)
        except Exception as e:
            print(f"task notify failed: {type(e).__name__}")

# ======================= 云端例行任务 (Routines) =======================
ROUTINE_ID_RE = re.compile(r'^rtn_[a-f0-9]{12}$')
SCHEDULER_TICK = float(os.environ.get("OPENMINIS_SCHEDULER_TICK", "15"))
MIN_INTERVAL_SECONDS = int(os.environ.get("OPENMINIS_MIN_INTERVAL", "60"))
ROUTINE_DEFAULT_INSTRUCTIONS = (
    "你是 OpenMinis 云端 Agent，正在用户的 Linux 云电脑上执行一个无人值守的例行任务。"
    "用户此时可能不在线：不要等待对话回复，独立完成任务并以简洁中文给出最终结果摘要。"
    "风险操作会触发审批，用户批准前任务暂停；被拒绝或超时时换用安全做法或说明无法完成。"
    "只能调用本次实际提供的工具，所有结论以工具真实输出为准，不要声称未执行的操作已经完成。"
)
_scheduler_stop = threading.Event()
_scheduler_thread = None

def _routine_row_to_dict(r):
    keys = ["routine_id", "name", "prompt", "schedule", "credential", "model", "instructions", "enabled",
            "max_runs", "run_count", "next_run_at", "last_run_at", "last_status", "notify", "created_at", "updated_at", "persona_id"]
    d = dict(zip(keys, r))
    try: d["schedule"] = json.loads(d["schedule"])
    except Exception: d["schedule"] = {}
    d["enabled"] = bool(d["enabled"])
    d["notify"] = bool(d["notify"])
    return d

ROUTINE_COLUMNS = "routine_id, name, prompt, schedule, credential, model, instructions, enabled, max_runs, run_count, next_run_at, last_run_at, last_status, notify, created_at, updated_at, persona_id"

def validate_schedule(schedule):
    """返回规范化的 schedule dict，非法抛 ValueError。"""
    if not isinstance(schedule, dict):
        raise ValueError("schedule must be an object")
    kind = schedule.get("kind")
    if kind == "cron":
        expr = schedule.get("expr")
        tz = schedule.get("timezone") or "UTC"
        try:
            spec = cloud_cron.CronSpec(expr)
            cloud_cron.validate_timezone(tz)
        except cloud_cron.CronError as e:
            raise ValueError(str(e))
        if spec.next_after(time.time(), tz) is None:
            raise ValueError("cron expression never fires")
        return {"kind": "cron", "expr": spec.expr, "timezone": tz}
    if kind == "interval":
        seconds = schedule.get("seconds")
        if not isinstance(seconds, int) or isinstance(seconds, bool) or seconds < MIN_INTERVAL_SECONDS or seconds > 366 * 86400:
            raise ValueError(f"interval seconds must be an integer between {MIN_INTERVAL_SECONDS} and {366 * 86400}")
        return {"kind": "interval", "seconds": seconds}
    if kind == "once":
        at = schedule.get("at")
        if not isinstance(at, (int, float)) or isinstance(at, bool):
            raise ValueError("once.at must be a UNIX timestamp")
        return {"kind": "once", "at": float(at)}
    raise ValueError("schedule.kind must be cron, interval or once")

def compute_next_run(schedule, after_ts, first=False):
    kind = schedule["kind"]
    if kind == "cron":
        return cloud_cron.CronSpec(schedule["expr"]).next_after(after_ts, schedule.get("timezone", "UTC"))
    if kind == "interval":
        return after_ts + schedule["seconds"]
    if kind == "once":
        return schedule["at"] if first else None
    return None

def get_routine(routine_id):
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("SELECT " + ROUTINE_COLUMNS + " FROM routines WHERE routine_id = ?", (routine_id,))
        r = c.fetchone()
    finally:
        conn.close()
    return _routine_row_to_dict(r) if r else None

def list_routines():
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("SELECT " + ROUTINE_COLUMNS + " FROM routines ORDER BY created_at ASC")
        return [_routine_row_to_dict(r) for r in c.fetchall()]
    finally:
        conn.close()

def list_routine_runs(routine_id, limit=20):
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("SELECT run_id, task_id, session_id, trigger, status, result, error, started_at, finished_at FROM routine_runs WHERE routine_id = ? ORDER BY started_at DESC LIMIT ?",
                  (routine_id, limit))
        keys = ["run_id", "task_id", "session_id", "trigger", "status", "result", "error", "started_at", "finished_at"]
        return [dict(zip(keys, r)) for r in c.fetchall()]
    finally:
        conn.close()

def validate_routine_fields(req, existing=None):
    """返回待写入字段 dict；非法抛 ValueError。existing 为 None 时为新建（必填项校验）。"""
    out = {}
    def text(key, max_len, required):
        if key in req:
            v = req[key]
            if not isinstance(v, str) or not v.strip() or len(v) > max_len:
                raise ValueError(f"{key} must be a non-empty string (max {max_len})")
            out[key] = v.strip() if key != "prompt" else v
        elif required and existing is None:
            raise ValueError(f"{key} is required")
    text("name", 120, True)
    text("prompt", 20000, True)
    text("model", 200, True)
    text("credential", 64, True)
    if "credential" in out and not CREDENTIAL_NAME_RE.match(out["credential"]):
        raise ValueError("Invalid credential name")
    if "instructions" in req:
        v = req["instructions"]
        if v is not None and (not isinstance(v, str) or len(v) > 50000):
            raise ValueError("instructions must be a string (max 50000)")
        out["instructions"] = v
    if "schedule" in req:
        out["schedule"] = validate_schedule(req["schedule"])
    elif existing is None:
        raise ValueError("schedule is required")
    for key in ("enabled", "notify"):
        if key in req:
            if not isinstance(req[key], bool):
                raise ValueError(f"{key} must be a boolean")
            out[key] = req[key]
    if "persona_id" in req:
        out["persona_id"] = validate_persona_ref(req["persona_id"])
    if "max_runs" in req:
        v = req["max_runs"]
        if v is not None and (not isinstance(v, int) or isinstance(v, bool) or v < 1):
            raise ValueError("max_runs must be a positive integer or null")
        out["max_runs"] = v
    return out

def create_routine(fields):
    now = time.time()
    rid = "rtn_" + uuid.uuid4().hex[:12]
    schedule = fields["schedule"]
    enabled = fields.get("enabled", True)
    next_run = compute_next_run(schedule, now, first=True) if enabled else None
    conn = get_db_connection()
    try:
        conn.execute("INSERT INTO routines (" + ROUTINE_COLUMNS + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NULL, NULL, ?, ?, ?, ?)",
                     (rid, fields["name"], fields["prompt"], json.dumps(schedule), fields["credential"], fields["model"],
                      fields.get("instructions"), 1 if enabled else 0, fields.get("max_runs"), next_run,
                      1 if fields.get("notify", True) else 0, now, now, fields.get("persona_id")))
        conn.commit()
    finally:
        conn.close()
    return get_routine(rid)

def update_routine(routine_id, fields):
    current = get_routine(routine_id)
    if not current:
        return None
    merged = dict(current)
    merged.update(fields)
    now = time.time()
    if "schedule" in fields or "enabled" in fields:
        merged["next_run_at"] = compute_next_run(merged["schedule"], now, first=True) if merged["enabled"] else None
        if merged["schedule"]["kind"] == "once" and merged["enabled"] and merged["next_run_at"] is None:
            merged["enabled"] = False
    conn = get_db_connection()
    try:
        conn.execute("UPDATE routines SET name = ?, prompt = ?, schedule = ?, credential = ?, model = ?, instructions = ?, enabled = ?, max_runs = ?, next_run_at = ?, notify = ?, updated_at = ?, persona_id = ? WHERE routine_id = ?",
                     (merged["name"], merged["prompt"], json.dumps(merged["schedule"]), merged["credential"], merged["model"],
                      merged.get("instructions"), 1 if merged["enabled"] else 0, merged.get("max_runs"), merged["next_run_at"],
                      1 if merged["notify"] else 0, now, merged.get("persona_id"), routine_id))
        conn.commit()
    finally:
        conn.close()
    return get_routine(routine_id)

def delete_routine(routine_id):
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("DELETE FROM routines WHERE routine_id = ?", (routine_id,))
        deleted = c.rowcount > 0
        conn.commit()
        return deleted
    finally:
        conn.close()

def _finish_routine_run(run_id, routine_id, status, result=None, error=None):
    now = time.time()
    conn = get_db_connection()
    try:
        conn.execute("UPDATE routine_runs SET status = ?, result = ?, error = ?, finished_at = ? WHERE run_id = ?",
                     (status, result, error, now, run_id))
        conn.execute("UPDATE routines SET last_status = ? WHERE routine_id = ?", (status, routine_id))
        conn.commit()
    finally:
        conn.close()

def on_routine_finished(routine, run):
    """例行任务结束时推送，异常不影响调度。"""
    if not routine.get("notify", True) or run.get("status") == "skipped":
        return None
    cfg = current_notify_config()
    if not cfg:
        return None
    label = {"completed": "完成", "failed": "失败", "limit_reached": "达到轮数上限", "cancelled": "已取消",
             "interrupted": "中断"}.get(run.get("status"), run.get("status"))
    body = (run.get("result") or run.get("error") or "（无文字结果）").strip()[:600]
    cloud_notify.notify_async(cfg, "routine_finished", f"例行任务「{routine['name']}」{label}"[:120], body)

def launch_routine_run(routine, trigger="schedule"):
    """启动一次例行任务。返回 run dict（含 run_id / task_id / status）。"""
    run_id = "run_" + uuid.uuid4().hex[:12]
    now = time.time()
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("SELECT run_id FROM routine_runs WHERE routine_id = ? AND status IN ('running', 'waiting_user')", (routine["routine_id"],))
        active = c.fetchone()
        status = "skipped" if active else "running"
        c.execute("INSERT INTO routine_runs (run_id, routine_id, task_id, session_id, trigger, status, result, error, started_at, finished_at) VALUES (?, ?, NULL, NULL, ?, ?, NULL, ?, ?, ?)",
                  (run_id, routine["routine_id"], trigger, status, "上一次运行尚未结束，本次跳过" if active else None, now, now if active else None))
        c.execute("UPDATE routines SET last_run_at = ?, run_count = run_count + ? WHERE routine_id = ?", (now, 0 if active else 1, routine["routine_id"]))
        conn.commit()
    finally:
        conn.close()
    if active:
        return {"run_id": run_id, "status": "skipped", "task_id": None}

    provider, p_status, p_err = resolve_provider({"credential": routine["credential"]})
    if p_err:
        err = f"凭据不可用（{p_status}）：{p_err}"
        _finish_routine_run(run_id, routine["routine_id"], "failed", error=err)
        run = {"run_id": run_id, "status": "failed", "task_id": None, "error": err, "trigger": trigger}
        try: on_routine_finished(routine, run)
        except Exception: pass
        return run

    sid = "sess_" + uuid.uuid4().hex[:12]
    tid = "task_" + uuid.uuid4().hex[:12]
    instructions = routine.get("instructions") or ROUTINE_DEFAULT_INSTRUCTIONS
    fired = time.strftime("%Y-%m-%d %H:%M:%S %z", time.localtime(now))
    content = f"[例行任务「{routine['name']}」于 {fired} 触发（{'手动运行' if trigger == 'manual' else '按计划'}）]\n{routine['prompt']}"
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, NULL, ?, ?, ?, ?)",
                  (sid, "例行任务：" + routine["name"], instructions, now, routine.get("persona_id")))
        c.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, NULL, 'running', ?, ?)",
                  (tid, sid, routine["model"], now))
        c.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)", (sid, content, now))
        c.execute("UPDATE routine_runs SET task_id = ?, session_id = ? WHERE run_id = ?", (tid, sid, run_id))
        conn.commit()
    finally:
        conn.close()
    with active_tasks_lock:
        active_tasks[tid] = {"process": None, "cancelled": False, "pid": None}

    def worker():
        try:
            run_agent_task(tid, sid, content, routine["model"], provider, instructions)
        finally:
            conn2 = get_db_connection()
            try:
                c2 = conn2.cursor()
                c2.execute("SELECT status FROM tasks WHERE task_id = ?", (tid,))
                row = c2.fetchone()
                final = row[0] if row else "failed"
                c2.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'assistant' AND content IS NOT NULL ORDER BY id DESC LIMIT 1", (sid,))
                last = c2.fetchone()
                c2.execute("SELECT payload FROM task_events WHERE task_id = ? AND event_type = 'error' ORDER BY id DESC LIMIT 1", (tid,))
                err_row = c2.fetchone()
            finally:
                conn2.close()
            err = None
            if err_row:
                try: err = json.loads(err_row[0]).get("error")
                except Exception: err = err_row[0]
            result = last[0][:20000] if last else None
            _finish_routine_run(run_id, routine["routine_id"], final, result=result, error=err)
            try:
                on_routine_finished(routine, {"run_id": run_id, "task_id": tid, "session_id": sid, "status": final,
                                              "result": result, "error": err, "trigger": trigger})
            except Exception:
                pass

    threading.Thread(target=worker, daemon=True).start()
    return {"run_id": run_id, "status": "running", "task_id": tid, "session_id": sid}

def scheduler_tick(now=None):
    """认领到期的例行任务并启动；返回启动的 run 列表。"""
    now = time.time() if now is None else now
    claimed = []
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("BEGIN IMMEDIATE")
        c.execute("SELECT " + ROUTINE_COLUMNS + " FROM routines WHERE enabled = 1 AND next_run_at IS NOT NULL AND next_run_at <= ?", (now,))
        for row in c.fetchall():
            routine = _routine_row_to_dict(row)
            # 停机期间错过的多次触发只补跑一次，下一次从现在起算
            next_run = compute_next_run(routine["schedule"], now)
            enabled = 1
            if next_run is None:
                enabled = 0
            if routine.get("max_runs") is not None and routine["run_count"] + 1 >= routine["max_runs"]:
                enabled, next_run = 0, None
            c.execute("UPDATE routines SET next_run_at = ?, enabled = ? WHERE routine_id = ?", (next_run, enabled, routine["routine_id"]))
            claimed.append(routine)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    runs = []
    for routine in claimed:
        try:
            runs.append(launch_routine_run(routine, "schedule"))
        except Exception as e:
            sys.stderr.write(f"[routine] launch failed {routine['routine_id']}: {sanitize_err(e)}\n")
    return runs

def _scheduler_main():
    while not _scheduler_stop.wait(SCHEDULER_TICK):
        try:
            scheduler_tick()
        except Exception as e:
            sys.stderr.write(f"[routine] scheduler error: {sanitize_err(e)}\n")

def start_scheduler():
    global _scheduler_thread
    if _scheduler_thread and _scheduler_thread.is_alive():
        return
    _scheduler_stop.clear()
    _scheduler_thread = threading.Thread(target=_scheduler_main, name="routine-scheduler", daemon=True)
    _scheduler_thread.start()

def stop_scheduler():
    _scheduler_stop.set()
    t = _scheduler_thread
    if t:
        t.join(timeout=5)

# ======================= Telegram 渠道 =======================
TELEGRAM_POLL_TIMEOUT = int(os.environ.get("OPENMINIS_TELEGRAM_POLL_TIMEOUT", "25"))
TELEGRAM_DEFAULT_INSTRUCTIONS = (
    "你是 OpenMinis 云端 Agent，用户正通过 Telegram 与你对话，你运行在用户的 Linux 云电脑上。"
    "回复会以纯文本发到 Telegram：用简洁中文，少用 Markdown 表格；长结果可用 page_write 保存为页面后告诉用户标题。"
)
TELEGRAM_HELP = ("OpenMinis 云电脑已连接。直接发消息即可让云端 Agent 干活。\n"
                 "/new 开始新会话\n/stop 停止当前任务\n/status 查看当前任务状态")
_telegram_stop = threading.Event()
_telegram_threads = {}   # channel（"" = 共享渠道，否则为 bot_id）-> Thread
_telegram_statuses = {}  # channel -> 状态
_telegram_warned_chats = set()

def _tg_status(channel):
    return _telegram_statuses.setdefault(channel, {"running": False, "last_poll_at": None, "last_error": None, "handled": 0})

_telegram_status = _tg_status("")

def telegram_setting_name(channel=""):
    return cloud_telegram.SETTING_NAME + (":" + channel if channel else "")

def telegram_config(channel=""):
    conn = get_db_connection()
    try:
        cfg = cloud_notify.load_setting(conn, telegram_setting_name(channel))
    except Exception as e:
        _tg_status(channel)["last_error"] = "config: " + type(e).__name__
        return None
    finally:
        conn.close()
    if cfg is not None:
        cfg["_channel"] = channel
    return cfg

def telegram_bot_channels():
    conn = get_db_connection()
    try:
        rows = conn.execute("SELECT name FROM secure_settings WHERE name LIKE ?", (cloud_telegram.SETTING_NAME + ":%",)).fetchall()
    finally:
        conn.close()
    return [r[0].split(":", 1)[1] for r in rows]

def telegram_channel_for_task(task_id):
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT channel FROM telegram_tasks WHERE task_id = ?", (task_id,)).fetchone()
        return (row[0] or "") if row else None
    finally:
        conn.close()

def _telegram_state(key, value=None):
    conn = get_db_connection()
    try:
        if value is None:
            row = conn.execute("SELECT value FROM telegram_state WHERE key = ?", (key,)).fetchone()
            return row[0] if row else None
        conn.execute("INSERT INTO telegram_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, str(value)))
        conn.commit()
    finally:
        conn.close()

def telegram_session_for(cfg, chat_id, title_hint, new=False):
    channel = cfg.get("_channel") or ""
    conn = get_db_connection()
    try:
        c = conn.cursor()
        if channel:
            row = c.execute("SELECT session_id FROM telegram_bot_chats WHERE channel = ? AND chat_id = ?", (channel, chat_id)).fetchone()
        else:
            row = c.execute("SELECT session_id FROM telegram_chats WHERE chat_id = ?", (chat_id,)).fetchone()
        if row and not new:
            return row[0]
        sid = "sess_" + uuid.uuid4().hex[:12]
        now = time.time()
        persona = channel or cfg.get("persona_id") or primary_bot_id()
        c.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, NULL, ?, ?, ?, ?)",
                  (sid, ("Telegram：" + title_hint)[:80], cfg.get("instructions") or TELEGRAM_DEFAULT_INSTRUCTIONS, now, persona))
        if channel:
            c.execute("INSERT INTO telegram_bot_chats (channel, chat_id, session_id, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(channel, chat_id) DO UPDATE SET session_id = excluded.session_id, updated_at = excluded.updated_at",
                      (channel, chat_id, sid, now))
        else:
            c.execute("INSERT INTO telegram_chats (chat_id, session_id, updated_at) VALUES (?, ?, ?) ON CONFLICT(chat_id) DO UPDATE SET session_id = excluded.session_id, updated_at = excluded.updated_at",
                      (chat_id, sid, now))
        conn.commit()
        return sid
    finally:
        conn.close()

def _active_task_for_session(sid):
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT task_id, status FROM tasks WHERE session_id = ? AND status IN ('running', 'waiting_user') ORDER BY created_at DESC LIMIT 1", (sid,)).fetchone()
        return row
    finally:
        conn.close()

def telegram_chat_for_task(task_id):
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT chat_id FROM telegram_tasks WHERE task_id = ?", (task_id,)).fetchone()
        return row[0] if row else None
    finally:
        conn.close()

def _telegram_safe_send(cfg, chat_id, text, reply_markup=None):
    try:
        cloud_telegram.send_text(cfg, chat_id, text, reply_markup)
        return True
    except cloud_telegram.TelegramAPIError as e:
        _tg_status(cfg.get("_channel") or "")["last_error"] = str(e)
        return False

def telegram_start_task(cfg, chat_id, sid, text):
    provider, p_status, p_err = resolve_provider({"credential": cfg["credential"]})
    if p_err:
        _telegram_safe_send(cfg, chat_id, f"云端凭据不可用（{p_status}）：{p_err}")
        return None
    instructions = cfg.get("instructions") or TELEGRAM_DEFAULT_INSTRUCTIONS
    tid = "task_" + uuid.uuid4().hex[:12]
    now = time.time()
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)", (sid, text, now))
        c.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, NULL, 'running', ?, ?)",
                  (tid, sid, cfg["model"], now))
        c.execute("INSERT INTO telegram_tasks (task_id, chat_id, created_at, channel) VALUES (?, ?, ?, ?)", (tid, chat_id, now, cfg.get("_channel") or ""))
        conn.commit()
    finally:
        conn.close()
    with active_tasks_lock:
        active_tasks[tid] = {"process": None, "cancelled": False, "pid": None}
    try:
        cloud_telegram.call(cfg, "sendChatAction", {"chat_id": chat_id, "action": "typing"}, timeout=10)
    except cloud_telegram.TelegramAPIError:
        pass

    def worker():
        try:
            run_agent_task(tid, sid, text, cfg["model"], provider, instructions)
        finally:
            conn2 = get_db_connection()
            try:
                status = (conn2.execute("SELECT status FROM tasks WHERE task_id = ?", (tid,)).fetchone() or ["failed"])[0]
                last = conn2.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'assistant' AND content IS NOT NULL AND timestamp >= ? ORDER BY id DESC LIMIT 1",
                                     (sid, now)).fetchone()
                err = conn2.execute("SELECT payload FROM task_events WHERE task_id = ? AND event_type = 'error' ORDER BY id DESC LIMIT 1", (tid,)).fetchone()
            finally:
                conn2.close()
            if status == "completed":
                reply = (last[0] if last else "") or "（完成，无文字回复）"
            elif status == "cancelled":
                reply = "任务已停止。"
            else:
                detail = ""
                if err:
                    try: detail = json.loads(err[0]).get("error", "")
                    except Exception: detail = ""
                reply = f"任务结束（{status}）。{detail}".strip()
                if last and last[0]:
                    reply += "\n\n" + last[0]
            _telegram_safe_send(cfg, chat_id, reply)

    threading.Thread(target=worker, daemon=True, name="telegram-task").start()
    return tid

def telegram_handle_message(cfg, msg):
    chat = msg.get("chat") or {}
    chat_id = chat.get("id")
    if not isinstance(chat_id, int):
        return
    if chat_id not in cfg.get("allowed_chat_ids", []):
        if (cfg.get("_channel") or "", chat_id) not in _telegram_warned_chats:
            _telegram_warned_chats.add((cfg.get("_channel") or "", chat_id))
            _telegram_safe_send(cfg, chat_id, f"这个会话尚未授权。chat id：{chat_id}\n请在 OpenMinis 云电脑设置 → Telegram 中把它加入允许列表。")
        return
    text = (msg.get("text") or msg.get("caption") or "").strip()
    if not text:
        _telegram_safe_send(cfg, chat_id, "目前只支持文字消息。")
        return
    title_hint = chat.get("title") or chat.get("username") or chat.get("first_name") or str(chat_id)
    command = text.split()[0].split("@")[0].lower() if text.startswith("/") else None
    if command in ("/start", "/help"):
        _telegram_safe_send(cfg, chat_id, TELEGRAM_HELP)
        return
    sid = telegram_session_for(cfg, chat_id, title_hint, new=(command == "/new"))
    active = _active_task_for_session(sid)
    if command == "/new":
        _telegram_safe_send(cfg, chat_id, "已开始新会话。")
        return
    if command == "/stop":
        if active:
            with active_tasks_lock:
                if active[0] in active_tasks:
                    active_tasks[active[0]]["cancelled"] = True
            _telegram_safe_send(cfg, chat_id, "正在停止当前任务…")
        else:
            _telegram_safe_send(cfg, chat_id, "当前没有运行中的任务。")
        return
    if command == "/status":
        _telegram_safe_send(cfg, chat_id, f"当前任务：{active[1]}" if active else "当前没有运行中的任务。")
        return
    if active:
        _telegram_safe_send(cfg, chat_id, "上一个任务还在运行（" + ("等待审批" if active[1] == "waiting_user" else "运行中") + "），完成后再发，或发送 /stop 停止。")
        return
    telegram_start_task(cfg, chat_id, sid, text)

def telegram_handle_callback(cfg, cq):
    data = cq.get("data") or ""
    chat_id = ((cq.get("message") or {}).get("chat") or {}).get("id")
    answer = "无效操作"
    if chat_id in cfg.get("allowed_chat_ids", []) and re.match(r"^ap:(appr_[a-f0-9]{12}):(y|n)$", data):
        _, aid, yn = data.split(":")
        conn = get_db_connection()
        try:
            row = conn.execute("SELECT task_id FROM approvals WHERE approval_id = ?", (aid,)).fetchone()
        finally:
            conn.close()
        if row and telegram_chat_for_task(row[0]) == chat_id and telegram_channel_for_task(row[0]) == (cfg.get("_channel") or ""):
            code, body = resolve_approval(row[0], aid, "approved" if yn == "y" else "denied", "via Telegram")
            answer = ("已批准" if yn == "y" else "已拒绝") if code == 200 else "该审批已处理或已过期"
    try:
        cloud_telegram.call(cfg, "answerCallbackQuery", {"callback_query_id": cq.get("id"), "text": answer}, timeout=10)
    except cloud_telegram.TelegramAPIError:
        pass
    if answer in ("已批准", "已拒绝"):
        _telegram_safe_send(cfg, chat_id, answer + "。")

def telegram_notify_approval(task_id, approval):
    chat_id = telegram_chat_for_task(task_id)
    if chat_id is None:
        return False
    cfg = telegram_config(telegram_channel_for_task(task_id) or "")
    if not cfg:
        return False
    args = json.dumps(approval.get("arguments"), ensure_ascii=False)
    text = f"⚠️ 需要你的审批：{approval.get('reason')}\n工具：{approval.get('tool')}\n参数：{args[:800]}"
    markup = {"inline_keyboard": [[{"text": "批准", "callback_data": f"ap:{approval['approval_id']}:y"},
                                   {"text": "拒绝", "callback_data": f"ap:{approval['approval_id']}:n"}]]}
    return _telegram_safe_send(cfg, chat_id, text, markup)

def telegram_poll_once(cfg):
    channel = cfg.get("_channel") or ""
    key = "offset" + (":" + channel if channel else "")
    offset = int(_telegram_state(key) or 0)
    updates = cloud_telegram.call(cfg, "getUpdates", {"offset": offset, "timeout": TELEGRAM_POLL_TIMEOUT,
                                                      "allowed_updates": ["message", "callback_query"]},
                                  timeout=TELEGRAM_POLL_TIMEOUT + 15)
    st = _tg_status(channel)
    st["last_poll_at"] = time.time()
    for u in updates or []:
        uid = u.get("update_id")
        if isinstance(uid, int):
            _telegram_state(key, uid + 1)
        try:
            if "message" in u:
                telegram_handle_message(cfg, u["message"])
            elif "callback_query" in u:
                telegram_handle_callback(cfg, u["callback_query"])
            st["handled"] += 1
        except Exception as e:
            st["last_error"] = "handler: " + type(e).__name__
    return len(updates or [])

def _telegram_main(channel=""):
    st = _tg_status(channel)
    st["running"] = True
    try:
        while not _telegram_stop.is_set():
            cfg = telegram_config(channel)
            if not cfg or not cfg.get("enabled", True):
                if channel:
                    return  # Bot 专属渠道已删除：结束线程
                _telegram_stop.wait(5)
                continue
            try:
                telegram_poll_once(cfg)
                st["last_error"] = None
            except cloud_telegram.TelegramAPIError as e:
                st["last_error"] = str(e)
                _telegram_stop.wait(5)
            except Exception as e:
                st["last_error"] = type(e).__name__
                _telegram_stop.wait(5)
    finally:
        st["running"] = False

def telegram_running(channel=""):
    t = _telegram_threads.get(channel)
    return bool(t and t.is_alive())

def start_telegram(channel=None):
    """channel 为 None 时启动共享渠道与全部 Bot 专属渠道。"""
    channels = [""] + telegram_bot_channels() if channel is None else [channel]
    _telegram_stop.clear()
    for ch in channels:
        if telegram_running(ch):
            continue
        t = threading.Thread(target=_telegram_main, args=(ch,), name="telegram-poller" + (":" + ch if ch else ""), daemon=True)
        _telegram_threads[ch] = t
        t.start()

def stop_telegram():
    _telegram_stop.set()
    for t in list(_telegram_threads.values()):
        t.join(timeout=TELEGRAM_POLL_TIMEOUT + 20)

def telegram_save(channel, req_json):
    """保存共享或 Bot 专属 Telegram 配置，返回 (状态码, 响应体)。"""
    body = req_json.get("config", req_json)
    existing = telegram_config(channel)
    if isinstance(body, dict) and existing and not body.get("bot_token"):
        body = dict(body, bot_token=existing["bot_token"])  # 只改允许列表等字段时沿用已存 Token
    try:
        cfg = cloud_telegram.validate(body, lambda n: bool(CREDENTIAL_NAME_RE.match(n)) and any(c["name"] == n for c in list_credentials()))
        if channel:
            cfg["persona_id"] = channel
        else:
            try:
                cfg["persona_id"] = validate_persona_ref(body.get("persona_id"))
            except ValueError as e:
                raise cloud_telegram.TelegramConfigError(str(e))
        for other in [""] + telegram_bot_channels():
            if other == channel:
                continue
            oc = telegram_config(other)
            if oc and oc.get("bot_token") == cfg["bot_token"]:
                raise cloud_telegram.TelegramConfigError("这个 Bot Token 已被另一个渠道使用（同一 Token 不能同时长轮询）")
        me = cloud_telegram.call(cfg, "getMe", timeout=15)
        cfg["bot_username"] = (me or {}).get("username")
    except cloud_telegram.TelegramConfigError as e:
        return 400, {"error": str(e)}
    except cloud_telegram.TelegramAPIError as e:
        return 502, {"error": "Telegram 校验失败：" + str(e)}
    conn = get_db_connection()
    try:
        cloud_notify.save_setting(conn, telegram_setting_name(channel), cfg)
    except cloud_secrets.SecretStoreUnavailable as e:
        return 503, {"error": f"Encrypted store unavailable: {e}"}
    finally:
        conn.close()
    _telegram_warned_chats.clear()
    start_telegram(channel)
    return 200, {"configured": True, "config": cloud_telegram.masked(cfg)}

def telegram_delete(channel):
    conn = get_db_connection()
    try:
        existed = cloud_notify.delete_setting(conn, telegram_setting_name(channel))
        if channel:
            conn.execute("DELETE FROM telegram_state WHERE key = ?", ("offset:" + channel,))
            conn.execute("DELETE FROM telegram_bot_chats WHERE channel = ?", (channel,))
        else:
            conn.execute("DELETE FROM telegram_state WHERE key = 'offset'")
        conn.commit()
    finally:
        conn.close()
    return {"configured": False, "deleted": existed}

def telegram_view(channel):
    cfg = telegram_config(channel)
    if cfg:
        cfg = {k: v for k, v in cfg.items() if k != "_channel"}
    return {"configured": cfg is not None, "config": cloud_telegram.masked(cfg), "channel": channel or "shared",
            "status": dict(_tg_status(channel), running=telegram_running(channel))}

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed_url = urlparse(self.path)
        path = parsed_url.path
        query_params = parse_qs(parsed_url.query)

        if path == "/health":
            self._send(200, {
                "status": "ok",
                "service": "openminis-cloud-agent",
                "mode": "cloud-computer",
                "version": "2.0.0",
                "capabilities": {
                    "shell": True,
                    "files": True,
                    "browser": cloud_browser.is_browser_available(),
                    "desktop": cloud_desktop.is_desktop_available(),
                    "display": os.environ.get("DISPLAY", ":99"),
                    "vnc_port": 5901,
                    "novnc_port": 18766,
                    "credential_store": cloud_secrets.status()[0],
                    "approvals": True,
                    "routines": True,
                    "memory_search": True,
                    "skills_lazy_load": True,
                    "notify": True,
                    "pages": True,
                    "subagents": True,
                    "image_generate": True,
                    "telegram": True,
                    "personas": True,
                    "bots": True,
                    "plugins": True
                },
                "timestamp": time.time()
            })
            return

        # Attachment download endpoint with path security & Bearer auth
        if "/attachments/" in path:
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer ") or auth[7:].strip() != SERVER_TOKEN:
                self._send(401, {"error": "Unauthorized"})
                return
            
            parts = path.split("/")
            # Expected format: /v1/sessions/{sid}/attachments/{filename} or similar
            try:
                s_idx = parts.index("sessions")
                sid = parts[s_idx + 1]
                filename = parts[-1]
            except (ValueError, IndexError):
                self._send(400, {"error": "Invalid attachment path"})
                return

            target, err = safe_path_resolve(sid, os.path.join("attachments", filename))
            if err or not os.path.exists(target) or not os.path.isfile(target):
                self._send(404, {"error": "Attachment not found"})
                return

            try:
                content_type, _ = mimetypes.guess_type(target)
                content_type = content_type or "application/octet-stream"
                with open(target, "rb") as f:
                    file_bytes = f.read()
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(file_bytes)))
                self.end_headers()
                self.wfile.write(file_bytes)
                return
            except Exception as e:
                self._send(500, {"error": str(e)})
                return

        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:].strip() != SERVER_TOKEN:
            self._send(401, {"error": "Unauthorized"})
            return

        if path == "/v1/personas":
            self._send(200, {"personas": list_personas()})
            return

        if path == "/v1/settings":
            conn = get_db_connection()
            try:
                rows = dict(conn.execute("SELECT name, value FROM app_settings").fetchall())
            finally:
                conn.close()
            self._send(200, {"timezone": rows.get("timezone"), "server_time": time.time(),
                             "server_local_time": time.strftime("%Y-%m-%d %H:%M:%S")})
            return

        if path == "/v1/plugins":
            installed = PLUGINS.list()
            ids = {p["plugin_id"] for p in installed}
            cat = [dict(c, installed=c["id"] in ids) for c in cloud_plugins.catalog()]
            self._send(200, {"installed": installed, "catalog": cat})
            return

        if path.startswith("/v1/plugins/") and path.endswith("/tools"):
            pid = path[len("/v1/plugins/"):-len("/tools")]
            if not PLUGINS.get(pid):
                self._send(404, {"error": "Plugin not found"})
                return
            try:
                tools = PLUGINS.list_tools(pid, refresh=True)
            except cloud_mcp.MCPAuthRequired as e:
                self._send(409, {"error": "needs_auth", "message": str(e), "plugin": PLUGINS.get(pid)})
                return
            except (cloud_mcp.MCPError, cloud_plugins.PluginError) as e:
                self._send(502, {"error": str(e), "plugin": PLUGINS.get(pid)})
                return
            self._send(200, {"plugin_id": pid, "tools": [{"name": t["name"], "description": t.get("description", "")} for t in tools]})
            return

        if path.startswith("/v1/plugins/"):
            p = PLUGINS.get(path[len("/v1/plugins/"):])
            if p:
                self._send(200, p)
            else:
                self._send(404, {"error": "Plugin not found"})
            return

        if path == "/v1/bots":
            self._send(200, {"bots": [bot_detail(b) for b in list_personas()], "primary": primary_bot_id()})
            return

        if path.startswith("/v1/bots/") and path.endswith("/telegram"):
            bid = path[len("/v1/bots/"):-len("/telegram")]
            if not get_persona(bid):
                self._send(404, {"error": "Bot not found"})
                return
            self._send(200, telegram_view(bid))
            return

        if path.startswith("/v1/bots/") and path.endswith("/export"):
            bid = path[len("/v1/bots/"):-len("/export")]
            if not get_persona(bid):
                self._send(404, {"error": "Bot not found"})
                return
            routines = [r for r in list_routines() if r.get("persona_id") == bid]
            conn = get_db_connection()
            try:
                mem = [e for e in cloud_memory.list_entries(conn, limit=2000) if e.get("persona") == bid]
                bundle = cloud_bots.export_bundle(conn, bid, routines, mem)
            finally:
                conn.close()
            self._send(200, bundle)
            return

        if path.startswith("/v1/bots/"):
            b = get_persona(path[len("/v1/bots/"):])
            if b:
                self._send(200, bot_detail(b))
            else:
                self._send(404, {"error": "Bot not found"})
            return

        if path.startswith("/v1/personas/"):
            p = get_persona(path[len("/v1/personas/"):])
            if p:
                self._send(200, p)
            else:
                self._send(404, {"error": "Persona not found"})
            return

        if path == "/v1/telegram":
            self._send(200, telegram_view(""))
            return


        if path == "/v1/pages":
            conn = get_db_connection()
            try:
                self._send(200, {"pages": cloud_pages.list_pages(conn)})
            finally:
                conn.close()
            return

        if path.startswith("/v1/pages/"):
            rest = path[len("/v1/pages/"):]
            pid, _, fmt = rest.partition("/")
            conn = get_db_connection()
            try:
                page = cloud_pages.get(conn, pid) if cloud_pages.PAGE_ID_RE.match(pid) else None
            finally:
                conn.close()
            if not page or fmt not in ("", "html"):
                self._send(404, {"error": "Page not found"})
                return
            if fmt == "html":
                body = page["html"].encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Security-Policy", "sandbox allow-scripts; default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self._send(200, page)
            return

        if path == "/v1/notify":
            available, reason = cloud_secrets.status()
            conn = get_db_connection()
            try:
                cfg = cloud_notify.load(conn) if available else None
                err = None
            except Exception as e:
                cfg, err = None, type(e).__name__
            finally:
                conn.close()
            self._send(200, {"available": available, "reason": reason or err, "configured": cfg is not None,
                             "config": cloud_notify.masked(cfg), "last": cloud_notify.last_status()})
            return

        if path == "/v1/skills":
            conn = get_db_connection()
            try:
                self._send(200, {"skills": cloud_skills.list_index(conn)})
            finally:
                conn.close()
            return

        if path.startswith("/v1/skills/"):
            name = unquote(path[len("/v1/skills/"):])
            conn = get_db_connection()
            try:
                skill = cloud_skills.load(conn, name)
            finally:
                conn.close()
            if skill:
                self._send(200, skill)
            else:
                self._send(404, {"error": "Skill not found"})
            return

        if path == "/v1/memory":
            def qp(name, default=None):
                v = query_params.get(name)
                return v[0] if v else default
            conn = get_db_connection()
            try:
                if qp("query") is not None or qp("category") or qp("persona") is not None:
                    entries = cloud_memory.search(conn, qp("query", ""), qp("category"), int(qp("limit", "20")), source=qp("source"), persona=qp("persona"))
                else:
                    since = qp("since")
                    entries = cloud_memory.list_entries(conn, since=float(since) if since else None, source=qp("source"), limit=int(qp("limit", "200")))
                fts = cloud_memory.fts_enabled(conn)
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            finally:
                conn.close()
            self._send(200, {"entries": entries, "fts": fts, "server_time": time.time()})
            return

        if path == "/v1/credentials":
            available, reason = cloud_secrets.status()
            self._send(200, {"available": available, "reason": reason, "credentials": list_credentials()})
            return

        if path == "/v1/sessions":
            conn = get_db_connection()
            c = conn.cursor()
            bot_filter = (query_params.get("bot") or [None])[0]
            if bot_filter:
                c.execute("SELECT session_id, local_session_id, title, created_at, persona_id FROM sessions WHERE persona_id = ? ORDER BY created_at DESC", (bot_filter,))
            else:
                c.execute("SELECT session_id, local_session_id, title, created_at, persona_id FROM sessions ORDER BY created_at DESC")
            sessions = [{"session_id": r[0], "local_session_id": r[1], "title": r[2], "created_at": r[3], "persona_id": r[4]} for r in c.fetchall()]
            conn.close()
            self._send(200, {"sessions": sessions})
            return

        if path.startswith("/v1/sessions/") and not path.endswith("/events"):
            sid = path[len("/v1/sessions/"):]
            if "/" in sid:
                # Might be sub-resource
                pass
            else:
                conn = get_db_connection()
                c = conn.cursor()
                c.execute("SELECT session_id, local_session_id, title, instructions, created_at FROM sessions WHERE session_id = ?", (sid,))
                s = c.fetchone()
                if not s:
                    conn.close()
                    self._send(404, {"error": "Session not found"})
                    return
                c.execute("SELECT role, content, tool_calls, tool_call_id, timestamp FROM messages WHERE session_id = ? ORDER BY id ASC", (sid,))
                msgs = []
                for mr in c.fetchall():
                    m = {"role": mr[0], "content": mr[1], "timestamp": mr[4]}
                    if mr[2]:
                        try: m["tool_calls"] = json.loads(mr[2])
                        except: pass
                    if mr[3]:
                        m["tool_call_id"] = mr[3]
                    msgs.append(m)
                c.execute("SELECT task_id, status, model, created_at FROM tasks WHERE session_id = ? ORDER BY created_at DESC", (sid,))
                tasks = [{"task_id": tr[0], "status": tr[1], "model": tr[2], "created_at": tr[3]} for tr in c.fetchall()]
                conn.close()
                self._send(200, {"session_id": s[0], "local_session_id": s[1], "title": s[2], "instructions": s[3], "created_at": s[4], "messages": msgs, "tasks": tasks})
                return

        if path == "/v1/routines":
            bot_filter = (query_params.get("bot") or [None])[0]
            routines = [r for r in list_routines() if not bot_filter or r.get("persona_id") == bot_filter]
            self._send(200, {"routines": routines, "server_time": time.time()})
            return

        if path.startswith("/v1/routines/"):
            parts = path.split("/")
            rid = parts[3] if len(parts) >= 4 else ""
            routine = get_routine(rid) if ROUTINE_ID_RE.match(rid) else None
            if not routine:
                self._send(404, {"error": "Routine not found"})
                return
            if len(parts) == 4:
                routine["runs"] = list_routine_runs(rid)
                self._send(200, routine)
                return
            if len(parts) == 5 and parts[4] == "runs":
                self._send(200, {"routine_id": rid, "runs": list_routine_runs(rid, 100)})
                return
            self._send(404, {"error": "Not found"})
            return

        if path == "/v1/approval-policy":
            self._send(200, {"policy": current_approval_policy(), "default": cloud_policy.DEFAULT_POLICY,
                             "customized": os.path.exists(approval_policy_path())})
            return

        if path.startswith("/v1/tasks/") and path.endswith("/approvals"):
            parts = path.split("/")
            tid = parts[3] if len(parts) == 5 else ""
            conn = get_db_connection()
            c = conn.cursor()
            c.execute("SELECT status FROM tasks WHERE task_id = ?", (tid,))
            t = c.fetchone()
            conn.close()
            if not t:
                self._send(404, {"error": "Task not found"})
                return
            self._send(200, {"task_id": tid, "status": t[0], "approvals": list_approvals(tid)})
            return

        if path.startswith("/v1/tasks/") and path.endswith("/events"):
            # /v1/tasks/{id}/events?after=...
            parts = path.split("/")
            tid = parts[3] if len(parts) >= 4 else ""
            raw_after = query_params.get("after", ["0"])[0]
            try:
                after_cursor = int(raw_after)
            except ValueError:
                self._send(400, {"error": "Invalid after cursor: must be an integer"})
                return

            conn = get_db_connection()
            c = conn.cursor()
            c.execute("SELECT task_id, session_id, status, model, created_at FROM tasks WHERE task_id = ?", (tid,))
            t = c.fetchone()
            if not t:
                conn.close()
                self._send(404, {"error": "Task not found"})
                return
            
            c.execute("SELECT id, event_type, payload, timestamp FROM task_events WHERE task_id = ? AND id > ? ORDER BY id ASC", (tid, after_cursor))
            events = []
            max_id = after_cursor
            for er in c.fetchall():
                eid, etype, payload_str, etime = er
                max_id = max(max_id, eid)
                try: pl = json.loads(payload_str)
                except: pl = {"raw": payload_str}
                events.append({"monotonic_id": eid, "id": eid, "type": etype, "payload": pl, "timestamp": etime})
            conn.close()
            self._send(200, {
                "task_id": t[0],
                "session_id": t[1],
                "status": t[2],
                "model": t[3],
                "created_at": t[4],
                "last_cursor": max_id,
                "events": events
            })
            return

        if path.startswith("/v1/tasks/"):
            tid = path[len("/v1/tasks/"):]
            conn = get_db_connection()
            c = conn.cursor()
            c.execute("SELECT task_id, session_id, status, model, created_at FROM tasks WHERE task_id = ?", (tid,))
            t = c.fetchone()
            if not t:
                conn.close()
                self._send(404, {"error": "Task not found"})
                return
            c.execute("SELECT id, event_type, payload, timestamp FROM task_events WHERE task_id = ? ORDER BY id ASC", (tid,))
            events = []
            max_id = 0
            for er in c.fetchall():
                eid, etype, payload_str, etime = er
                max_id = max(max_id, eid)
                try: pl = json.loads(payload_str)
                except: pl = {"raw": payload_str}
                events.append({"monotonic_id": eid, "id": eid, "type": etype, "payload": pl, "timestamp": etime})
            conn.close()
            self._send(200, {
                "task_id": t[0],
                "session_id": t[1],
                "status": t[2],
                "model": t[3],
                "created_at": t[4],
                "last_cursor": max_id,
                "events": events
            })
            return

        self._send(404, {"error": "Not found"})

    def _authorized(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:].strip() != SERVER_TOKEN:
            self._send(401, {"error": "Unauthorized"})
            return False
        return True

    def _read_json_body(self):
        """返回 dict；出错时已发送错误响应并返回 None。"""
        raw_len = self.headers.get("Content-Length", 0)
        try:
            length = int(raw_len)
        except Exception:
            self._send(400, {"error": "Invalid Content-Length"})
            return None

        if length < 0 or length > 5 * 1024 * 1024:
            self._send(400 if length < 0 else 413, {"error": "Invalid body size or exceeds 5MB limit"})
            return None

        req_json = {}
        if length > 0:
            try:
                body_bytes = self.rfile.read(length)
                req_json = json.loads(body_bytes.decode("utf-8"))
            except Exception:
                self._send(400, {"error": "Invalid JSON body"})
                return None

        if not isinstance(req_json, dict):
            self._send(400, {"error": "Request body must be a JSON object"})
            return None
        return req_json

    def do_PUT(self):
        path = self.path.split("?")[0]
        if not self._authorized():
            return
        req_json = self._read_json_body()
        if req_json is None:
            return

        if path == "/v1/settings":
            tz = req_json.get("timezone")
            if tz is not None and (not isinstance(tz, str) or not re.match(r"^[A-Za-z0-9_+\-]+(/[A-Za-z0-9_+\-]+){0,2}$", tz)):
                self._send(400, {"error": "timezone must be an IANA name such as Asia/Shanghai"})
                return
            try:
                cloud_memory.set_timezone(tz)
            except Exception as e:
                self._send(400, {"error": f"unknown timezone: {tz}"})
                return
            conn = get_db_connection()
            try:
                if tz:
                    conn.execute("INSERT INTO app_settings (name, value) VALUES ('timezone', ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value", (tz,))
                else:
                    conn.execute("DELETE FROM app_settings WHERE name = 'timezone'")
                conn.commit()
            finally:
                conn.close()
            self._send(200, {"timezone": tz})
            return

        if path.startswith("/v1/bots/") and path.endswith("/telegram"):
            bid = path[len("/v1/bots/"):-len("/telegram")]
            if not get_persona(bid):
                self._send(404, {"error": "Bot not found"})
                return
            code, body = telegram_save(bid, req_json)
            self._send(code, body)
            return

        if path.startswith("/v1/plugins/"):
            try:
                p = PLUGINS.update(path[len("/v1/plugins/"):], req_json)
            except cloud_plugins.PluginError as e:
                self._send(400, {"error": str(e)})
                return
            if p:
                self._send(200, p)
            else:
                self._send(404, {"error": "Plugin not found"})
            return

        if path.startswith("/v1/bots/"):
            conn = get_db_connection()
            try:
                bot, created = cloud_bots.upsert(conn, path[len("/v1/bots/"):], req_json, credential_exists)
            except cloud_bots.BotError as e:
                self._send(400, {"error": str(e)})
                return
            finally:
                conn.close()
            self._send(201 if created else 200, bot)
            return

        if path.startswith("/v1/credentials/"):
            name = path[len("/v1/credentials/"):]
            if not CREDENTIAL_NAME_RE.match(name):
                self._send(400, {"error": "Invalid credential name"})
                return
            api_key = req_json.get("api_key")
            if not isinstance(api_key, str) or not api_key.strip() or len(api_key) > 8192:
                self._send(400, {"error": "api_key must be a non-empty string"})
                return
            base_url = req_json.get("base_url", "https://api.openai.com/v1")
            ok, err = validate_base_url(base_url)
            if not ok:
                self._send(400, {"error": err})
                return
            protocol = req_json.get("protocol", "chat")
            if protocol != "chat":
                self._send(400, {"error": "Unsupported provider protocol. Only 'chat' is supported."})
                return
            try:
                created = put_credential(name, api_key.strip(), base_url, protocol)
            except cloud_secrets.SecretStoreUnavailable as e:
                self._send(503, {"error": "Credential store unavailable: " + str(e)})
                return
            self._send(201 if created else 200, {"name": name, "base_url": base_url, "key_hint": credential_hint(api_key.strip()), "stored": True})
            return

        if path.startswith("/v1/personas/"):
            pid = path[len("/v1/personas/"):]
            name = req_json.get("name")
            instructions = req_json.get("instructions")
            emoji = req_json.get("emoji")
            if not PERSONA_ID_RE.match(pid):
                self._send(400, {"error": "persona_id must match ^[a-z0-9][a-z0-9_-]{0,31}$"})
                return
            if not isinstance(name, str) or not name.strip() or len(name) > 60:
                self._send(400, {"error": "name must be a non-empty string (max 60)"})
                return
            if not isinstance(instructions, str) or not instructions.strip() or len(instructions) > 20000:
                self._send(400, {"error": "instructions must be a non-empty string (max 20000)"})
                return
            if emoji is not None and (not isinstance(emoji, str) or len(emoji) > 8):
                self._send(400, {"error": "emoji must be a short string"})
                return
            existed = get_persona(pid) is not None
            now = time.time()
            conn = get_db_connection()
            try:
                conn.execute("INSERT INTO personas (persona_id, name, instructions, emoji, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?) "
                             "ON CONFLICT(persona_id) DO UPDATE SET name = excluded.name, instructions = excluded.instructions, emoji = excluded.emoji, updated_at = excluded.updated_at",
                             (pid, name.strip(), instructions, emoji, now, now))
                conn.commit()
            finally:
                conn.close()
            self._send(200 if existed else 201, get_persona(pid))
            return

        if path == "/v1/telegram":
            code, body = telegram_save("", req_json)
            self._send(code, body)
            return

        if path == "/v1/notify":
            conn = get_db_connection()
            try:
                cfg = cloud_notify.save(conn, req_json.get("config", req_json))
            except cloud_notify.NotifyConfigError as e:
                self._send(400, {"error": str(e)})
                return
            except cloud_secrets.SecretStoreUnavailable as e:
                self._send(503, {"error": f"Encrypted store unavailable: {e}"})
                return
            finally:
                conn.close()
            self._send(200, {"configured": True, "config": cloud_notify.masked(cfg)})
            return

        if path.startswith("/v1/routines/"):
            rid = path[len("/v1/routines/"):]
            if not ROUTINE_ID_RE.match(rid) or not get_routine(rid):
                self._send(404, {"error": "Routine not found"})
                return
            try:
                fields = validate_routine_fields(req_json, existing=get_routine(rid))
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            self._send(200, update_routine(rid, fields))
            return

        if path == "/v1/approval-policy":
            try:
                saved = cloud_policy.save_policy(approval_policy_path(), req_json.get("policy", req_json))
            except cloud_policy.PolicyError as e:
                self._send(400, {"error": str(e)})
                return
            self._send(200, {"policy": saved, "customized": True})
            return

        self._send(404, {"error": "Not found"})

    def do_DELETE(self):
        path = self.path.split("?")[0]
        query_params = parse_qs(urlparse(self.path).query)
        if not self._authorized():
            return
        if path.startswith("/v1/bots/") and path.endswith("/telegram"):
            self._send(200, telegram_delete(path[len("/v1/bots/"):-len("/telegram")]))
            return
        if path.startswith("/v1/bots/"):
            path = "/v1/personas/" + path[len("/v1/bots/"):]
        if path.startswith("/v1/plugins/"):
            if PLUGINS.uninstall(path[len("/v1/plugins/"):]):
                self._send(200, {"deleted": True})
            else:
                self._send(404, {"error": "Plugin not found"})
            return

        if path.startswith("/v1/credentials/"):
            name = path[len("/v1/credentials/"):]
            if not CREDENTIAL_NAME_RE.match(name):
                self._send(400, {"error": "Invalid credential name"})
                return
            if delete_credential(name):
                self._send(200, {"name": name, "deleted": True})
            else:
                self._send(404, {"error": "Credential not found"})
            return

        if path.startswith("/v1/personas/"):
            pid = path[len("/v1/personas/"):]
            conn = get_db_connection()
            try:
                cur = conn.execute("DELETE FROM personas WHERE persona_id = ?", (pid,))
                deleted = cur.rowcount > 0
                purged = 0
                if deleted:
                    conn.execute("UPDATE routines SET persona_id = NULL WHERE persona_id = ?", (pid,))
                    cloud_notify.delete_setting(conn, telegram_setting_name(pid))
                    conn.execute("DELETE FROM telegram_bot_chats WHERE channel = ?", (pid,))
                    if (query_params.get("purge_memory") or ["0"])[0] == "1":
                        purged = conn.execute("DELETE FROM memory_entries WHERE persona = ?", (pid,)).rowcount
                conn.commit()
            finally:
                conn.close()
            if deleted:
                self._send(200, {"persona_id": pid, "deleted": True, "memory_purged": purged})
            else:
                self._send(404, {"error": "Persona not found"})
            return

        if path == "/v1/telegram":
            self._send(200, telegram_delete(""))
            return

        if path.startswith("/v1/pages/"):
            pid = path[len("/v1/pages/"):]
            conn = get_db_connection()
            try:
                ok = bool(cloud_pages.PAGE_ID_RE.match(pid)) and cloud_pages.delete(conn, pid)
            finally:
                conn.close()
            if ok:
                self._send(200, {"page_id": pid, "deleted": True})
            else:
                self._send(404, {"error": "Page not found"})
            return

        if path == "/v1/notify":
            conn = get_db_connection()
            try:
                existed = cloud_notify.delete(conn)
            finally:
                conn.close()
            self._send(200, {"configured": False, "deleted": existed})
            return

        if path.startswith("/v1/skills/"):
            name = unquote(path[len("/v1/skills/"):])
            conn = get_db_connection()
            try:
                ok = cloud_skills.delete(conn, name)
            finally:
                conn.close()
            if ok:
                self._send(200, {"name": name, "deleted": True})
            else:
                self._send(404, {"error": "Skill not found"})
            return

        if path.startswith("/v1/memory/"):
            raw = path[len("/v1/memory/"):]
            conn = get_db_connection()
            try:
                ok = raw.isdigit() and cloud_memory.delete(conn, int(raw))
            finally:
                conn.close()
            if ok:
                self._send(200, {"id": int(raw), "deleted": True})
            else:
                self._send(404, {"error": "Memory entry not found"})
            return

        if path.startswith("/v1/routines/"):
            rid = path[len("/v1/routines/"):]
            if ROUTINE_ID_RE.match(rid) and delete_routine(rid):
                self._send(200, {"routine_id": rid, "deleted": True})
            else:
                self._send(404, {"error": "Routine not found"})
            return

        if path == "/v1/approval-policy":
            cloud_policy.reset_policy(approval_policy_path())
            self._send(200, {"policy": current_approval_policy(), "customized": False})
            return

        self._send(404, {"error": "Not found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        if not self._authorized():
            return
        req_json = self._read_json_body()
        if req_json is None:
            return

        if path == "/v1/plugins/install":
            try:
                if req_json.get("catalog_id"):
                    manifest, source = cloud_plugins.catalog_entry(req_json["catalog_id"]), "catalog"
                    if not manifest:
                        raise cloud_plugins.PluginError("unknown catalog_id")
                elif req_json.get("url"):
                    manifest, source = cloud_plugins.fetch_manifest(req_json["url"]), "url"
                elif isinstance(req_json.get("manifest"), dict):
                    manifest, source = req_json["manifest"], "manifest"
                else:
                    raise cloud_plugins.PluginError("one of catalog_id, url or manifest is required")
                checked = cloud_plugins.validate_manifest(manifest)
                if source != "catalog" and checked["kind"] == "mcp" and checked["mcp"]["transport"] == "stdio" and req_json.get("acknowledge_command") is not True:
                    # 非内置清单会在 VPS 上运行命令：先返回预览，需用户确认后带 acknowledge_command 重试
                    self._send(428, {"error": "confirm_command", "preview": checked,
                                     "command": " ".join([checked["mcp"]["command"]] + checked["mcp"]["args"])})
                    return
                p, created = PLUGINS.install(manifest, source, req_json.get("secrets"), req_json.get("default_grant", True) is not False)
            except cloud_plugins.PluginError as e:
                self._send(400, {"error": str(e)})
                return
            self._send(201 if created else 200, p)
            return

        if path == "/v1/plugins/import-phone":
            servers = req_json.get("servers")
            if not isinstance(servers, list) or len(servers) > 50:
                self._send(400, {"error": "servers must be a list (max 50)"})
                return
            results = []
            for s in servers:
                try:
                    manifest, values = cloud_plugins.phone_manifest(s)
                    p, _ = PLUGINS.install(manifest, "phone", values, default_grant=True)
                    results.append({"id": s.get("id"), "plugin_id": p["plugin_id"], "status": p["status"]})
                except cloud_plugins.PluginError as e:
                    results.append({"id": s.get("id") if isinstance(s, dict) else None, "error": str(e)})
            self._send(200, {"results": results})
            return

        if path == "/v1/bots/import":
            try:
                res = import_bot_bundle(req_json)
            except (cloud_bots.BotError, ValueError) as e:
                self._send(400, {"error": str(e)})
                return
            self._send(201, res)
            return

        if path == "/v1/sessions":
            title = req_json.get("title", "Cloud Session")
            try:
                persona_id = validate_persona_ref(req_json.get("persona_id"))
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            sid = "sess_" + uuid.uuid4().hex[:12]
            created_at = time.time()
            conn = get_db_connection()
            c = conn.cursor()
            c.execute("INSERT INTO sessions (session_id, title, created_at, persona_id) VALUES (?, ?, ?, ?)", (sid, title, created_at, persona_id))
            conn.commit()
            conn.close()
            self._send(201, {"session_id": sid, "title": title, "created_at": created_at, "persona_id": persona_id})
            return

        if path == "/v1/sessions/import":
            local_session_id = req_json.get("local_session_id")
            if not isinstance(local_session_id, str) or not local_session_id.strip():
                self._send(400, {"error": "local_session_id must be a non-empty string"})
                return

            title = req_json.get("title", "Imported Session")
            instructions = req_json.get("instructions", "You are OpenMinis Cloud Agent.")
            history = req_json.get("history", [])
            # Support both workspace_files, files and work_context
            workspace_files = req_json.get("workspace_files") or req_json.get("files") or []
            if isinstance(req_json.get("work_context"), dict):
                wc_files = req_json["work_context"].get("files", [])
                if isinstance(wc_files, list):
                    workspace_files.extend(wc_files)
                if not req_json.get("instructions") and req_json["work_context"].get("instructions"):
                    instructions = req_json["work_context"]["instructions"]

            conn = get_db_connection()
            c = conn.cursor()
            c.execute("SELECT session_id, created_at FROM sessions WHERE local_session_id = ?", (local_session_id,))
            existing = c.fetchone()
            
            if existing:
                sid = existing[0]
                created_at = existing[1]
                # Update instructions/title if provided
                c.execute("UPDATE sessions SET title = ?, instructions = ? WHERE session_id = ?", (title, instructions, sid))
                conn.commit()
            else:
                sid = "sess_" + uuid.uuid4().hex[:12]
                created_at = time.time()
                # 手机导入的会话归属指定 Bot，未指定时归主 Bot（没有主 Bot 则为默认）
                import_persona = req_json.get("persona_id") if isinstance(req_json.get("persona_id"), str) and get_persona(req_json.get("persona_id")) else primary_bot_id()
                c.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, ?, ?, ?, ?, ?)",
                          (sid, local_session_id, title, instructions, created_at, import_persona))
                
                # Insert history messages if any
                if isinstance(history, list):
                    for hm in history:
                        if isinstance(hm, dict):
                            role = hm.get("role", "user")
                            content = hm.get("content", "")
                            if isinstance(content, list):
                                content = json.dumps(content, ensure_ascii=False)
                            if not isinstance(content, (str, type(None))):
                                continue
                            tc = json.dumps(hm.get("tool_calls")) if hm.get("tool_calls") else None
                            tcid = hm.get("tool_call_id")
                            c.execute("INSERT INTO messages (session_id, role, content, tool_calls, tool_call_id, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
                                      (sid, role, content, tc, tcid, time.time()))
                conn.commit()
            conn.close()

            # Process workspace_files (skills, memory, etc. with size & path safety check)
            imported_files_count = 0
            memory_indexed = 0
            skills_indexed = 0
            if isinstance(workspace_files, list):
                ws = get_session_workspace(sid)
                for wf in workspace_files:
                    if not isinstance(wf, dict): continue
                    fpath = wf.get("path", "")
                    fcontent = wf.get("content", "")
                    if not fpath or not isinstance(fcontent, str): continue
                    if len(fcontent.encode("utf-8")) > 2 * 1024 * 1024: continue # >2MB skip
                    
                    # Security validation against path traversal and symlinks
                    target, err = safe_path_resolve(sid, fpath)
                    if err or not target: continue
                    if os.path.islink(target): continue # reject symlinks
                    
                    try:
                        os.makedirs(os.path.dirname(target), exist_ok=True)
                        with open(target, "w", encoding="utf-8") as f:
                            f.write(fcontent)
                        imported_files_count += 1
                    except Exception:
                        pass
                    # 手机记忆文件同时写入全局记忆索引（同一来源文件整体替换）
                    norm = fpath.lstrip("/").replace("\\", "/")
                    skill_parts = norm.split("/")
                    if len(skill_parts) == 3 and skill_parts[0] == "skills" and skill_parts[2] == "SKILL.md":
                        sconn = get_db_connection()
                        try:
                            cloud_skills.upsert(sconn, skill_parts[1], fcontent, source="phone")
                            skills_indexed += 1
                        except Exception as e:
                            print(f"skill import failed for {norm}: {e}")
                        finally:
                            sconn.close()
                    if norm.startswith("memory/") and norm.endswith(".md"):
                        mconn = get_db_connection()
                        try:
                            memory_indexed += cloud_memory.import_file(mconn, norm, fcontent, source="phone")
                        except Exception as e:
                            print(f"memory import failed for {norm}: {e}")
                        finally:
                            mconn.close()

            self._send(200 if existing else 201, {
                "session_id": sid,
                "local_session_id": local_session_id,
                "title": title,
                "status": "ready",
                "imported_messages_count": len(history) if isinstance(history, list) else 0,
                "imported_files_count": imported_files_count,
                "memory_entries_indexed": memory_indexed,
                "skills_indexed": skills_indexed,
                "created_at": created_at
            })
            return

        if path.startswith("/v1/sessions/") and path.endswith("/messages"):
            parts = path.split("/")
            sid = parts[3] if len(parts) >= 4 else ""
            
            content = req_json.get("content")
            if not isinstance(content, str) or not content.strip():
                self._send(400, {"error": "content must be a non-empty string"})
                return

            message_parts = req_json.get("message_parts")
            db_user_content = content
            if message_parts is not None:
                if not isinstance(message_parts, list):
                    self._send(400, {"error": "message_parts must be a list"})
                    return
                # Validate parts format and size
                total_parts_bytes = 0
                for p in message_parts:
                    if not isinstance(p, dict) or "type" not in p:
                        self._send(400, {"error": "Each message part must be a dict with 'type'"})
                        return
                    ptype = p.get("type")
                    if ptype == "text":
                        t = p.get("text", "")
                        if not isinstance(t, str):
                            self._send(400, {"error": "Part type text requires string 'text'"})
                            return
                        total_parts_bytes += len(t.encode("utf-8"))
                    elif ptype == "image_url":
                        iu = p.get("image_url", {})
                        if not isinstance(iu, dict) or "url" not in iu or not isinstance(iu.get("url"), str):
                            self._send(400, {"error": "Part type image_url requires dict with 'url' string"})
                            return
                        url_val = iu.get("url", "")
                        if not url_val.strip():
                            self._send(400, {"error": "Part image_url url cannot be empty"})
                            return
                        total_parts_bytes += len(url_val.encode("utf-8"))
                    else:
                        self._send(400, {"error": f"Unsupported message part type: {ptype}"})
                        return
                if total_parts_bytes > 2 * 1024 * 1024:
                    self._send(400, {"error": "message_parts size exceeds 2MB limit"})
                    return
                db_user_content = json.dumps(message_parts, ensure_ascii=False)

            model = req_json.get("model", "gpt-4o")
            client_nonce = req_json.get("client_nonce")
            provider_req = req_json.get("provider", {})
            bot = session_bot(sid)
            if bot and bot.get("model") and bot.get("credential"):
                # Bot 自带模型选择：覆盖客户端当前模型
                model = bot["model"]
                provider_req = {"protocol": "chat", "credential": bot["credential"]}

            provider, p_status, p_err = resolve_provider(provider_req)
            if p_err:
                self._send(p_status, {"error": p_err})
                return

            conn = get_db_connection()
            c = conn.cursor()
            try:
                c.execute("BEGIN IMMEDIATE")
                c.execute("SELECT session_id, instructions FROM sessions WHERE session_id = ?", (sid,))
                s_row = c.fetchone()
                if not s_row:
                    conn.rollback()
                    conn.close()
                    self._send(404, {"error": "Session not found"})
                    return
                
                instructions = req_json.get("instructions") or s_row[1] or "You are OpenMinis Cloud Agent."

                # Check client_nonce idempotency
                if client_nonce:
                    c.execute("SELECT task_id, status FROM tasks WHERE client_nonce = ? AND session_id = ?", (client_nonce, sid))
                    existing_task = c.fetchone()
                    if existing_task:
                        conn.rollback()
                        conn.close()
                        self._send(200, {"task_id": existing_task[0], "session_id": sid, "status": existing_task[1], "idempotent_replayed": True})
                        return

                c.execute("SELECT task_id FROM tasks WHERE session_id = ? AND status IN ('running', 'waiting_user')", (sid,))
                running = c.fetchone()
                if running:
                    conn.rollback()
                    conn.close()
                    self._send(409, {"error": "Conflict: Session has a running task", "running_task_id": running[0]})
                    return

                tid = "task_" + uuid.uuid4().hex[:12]
                created_at = time.time()
                c.execute(
                    "INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, ?, 'running', ?, ?)",
                    (tid, sid, client_nonce, model, created_at)
                )
                c.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)", (sid, db_user_content, created_at))
                conn.commit()
            except sqlite3.IntegrityError:
                conn.rollback()
                conn.close()
                self._send(409, {"error": "Conflict: Session already has a running task or nonce collision"})
                return
            except Exception as e:
                conn.rollback()
                conn.close()
                self._send(500, {"error": str(e)})
                return
            finally:
                try:
                    conn.close()
                except Exception:
                    pass

            with active_tasks_lock:
                active_tasks[tid] = {"process": None, "cancelled": False, "pid": None}
            
            # Start background thread BEFORE sending HTTP 202 to guarantee execution survives client disconnect
            task_thread = threading.Thread(
                target=run_agent_task,
                args=(tid, sid, content, model, provider, instructions),
                daemon=True
            )
            task_thread.start()
            
            try:
                self._send(202, {"task_id": tid, "session_id": sid, "status": "running"})
            except Exception:
                # BrokenPipeError / Client disconnected immediately after sending - task is already running!
                pass
            return

        if path == "/v1/notify/test":
            cfg = current_notify_config()
            if not cfg:
                self._send(404, {"error": "Notification not configured"})
                return
            ok, err = cloud_notify.send_now(cfg, "OpenMinis 云电脑", "推送测试：收到这条说明配置正确。", event="test")
            self._send(200 if ok else 502, {"ok": ok, "error": err})
            return

        if path == "/v1/skills/sync":
            conn = get_db_connection()
            try:
                counts = cloud_skills.sync(conn, req_json.get("skills"), prune=bool(req_json.get("prune")))
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            finally:
                conn.close()
            self._send(200, counts)
            return

        if path == "/v1/memory":
            conn = get_db_connection()
            try:
                entry, created = cloud_memory.write(conn, req_json.get("content"), req_json.get("category"), source=req_json.get("source") if req_json.get("source") in ("phone", "cloud") else "phone")
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            finally:
                conn.close()
            self._send(201 if created else 200, dict(entry, created=created))
            return

        if path == "/v1/routines":
            try:
                fields = validate_routine_fields(req_json)
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            self._send(201, create_routine(fields))
            return

        if path.startswith("/v1/routines/") and path.endswith("/run"):
            parts = path.split("/")
            rid = parts[3] if len(parts) == 5 else ""
            routine = get_routine(rid) if ROUTINE_ID_RE.match(rid) else None
            if not routine:
                self._send(404, {"error": "Routine not found"})
                return
            run = launch_routine_run(routine, "manual")
            self._send(202 if run["status"] == "running" else 200, run)
            return

        if path.startswith("/v1/tasks/") and "/approvals/" in path:
            parts = path.split("/")
            if len(parts) != 6 or parts[4] != "approvals":
                self._send(404, {"error": "Not found"})
                return
            tid, aid = parts[3], parts[5]
            decision = req_json.get("decision")
            if decision not in ("approve", "deny"):
                self._send(400, {"error": "decision must be 'approve' or 'deny'"})
                return
            note = req_json.get("note")
            if note is not None and (not isinstance(note, str) or len(note) > 1000):
                self._send(400, {"error": "note must be a string (max 1000)"})
                return
            code, body = resolve_approval(tid, aid, "approved" if decision == "approve" else "denied", note)
            self._send(code, body)
            return

        if path.startswith("/v1/tasks/") and path.endswith("/cancel"):
            parts = path.split("/")
            tid = parts[3] if len(parts) >= 4 else ""
            conn = get_db_connection()
            c = conn.cursor()
            c.execute("SELECT status FROM tasks WHERE task_id = ?", (tid,))
            r = c.fetchone()
            if not r:
                conn.close()
                self._send(404, {"error": "Task not found"})
                return
            if r[0] in ["completed", "failed", "cancelled", "limit_reached", "interrupted"]:
                conn.close()
                self._send(200, {"task_id": tid, "status": r[0]})
                return
            set_task_cancelled(tid)
            c.execute("UPDATE tasks SET status = 'cancelled' WHERE task_id = ? AND status IN ('running', 'waiting_user')", (tid,))
            conn.commit()
            conn.close()
            log_event(tid, "cancelled", {"message": "Cancelled via API"})
            self._send(200, {"task_id": tid, "status": "cancelled"})
            return

        self._send(404, {"error": "Not found"})

    def log_message(self, format, *args):
        pass

CloudAgentHandler = Handler

def run_server():
    global SERVER_TOKEN
    if not SERVER_TOKEN:
        SERVER_TOKEN = validate_and_load_token()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    start_scheduler()
    start_telegram()
    print(f"OpenMinis Cloud Computer & Agent running on {HOST}:{PORT}")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
