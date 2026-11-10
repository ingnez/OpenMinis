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
from urllib.parse import urlparse, parse_qs
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
        'sessions': {'local_session_id': 'TEXT', 'instructions': 'TEXT'},
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

    # Server restart: mark interrupted
    cursor.execute("UPDATE tasks SET status = 'interrupted' WHERE status IN ('running', 'queued', 'waiting_user')")
    cursor.execute("UPDATE approvals SET status = 'expired', decided_at = ? WHERE status = 'pending'", (time.time(),))
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
        return active_tasks.get(task_id, {}).get("cancelled", False)

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

def on_approval_required(task_id, session_id, approval):
    """审批挂起时的扩展钩子（推送通知等），异常不影响任务。"""
    return None

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
    }
]

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "Redirection prohibited", headers, fp)

def call_llm(url, headers, body):
    opener = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST")
    with opener.open(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))

def run_agent_task(task_id, session_id, initial_content, model, provider_config, instructions):
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

    messages = [{"role": "system", "content": instructions}] if instructions else []
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
                    "model": model, "messages": messages, "tools": TOOL_DEFINITIONS, "tool_choice": "auto", "stream": False
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
                    "approvals": True
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

        if path == "/v1/credentials":
            available, reason = cloud_secrets.status()
            self._send(200, {"available": available, "reason": reason, "credentials": list_credentials()})
            return

        if path == "/v1/sessions":
            conn = get_db_connection()
            c = conn.cursor()
            c.execute("SELECT session_id, local_session_id, title, created_at FROM sessions ORDER BY created_at DESC")
            sessions = [{"session_id": r[0], "local_session_id": r[1], "title": r[2], "created_at": r[3]} for r in c.fetchall()]
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
        if not self._authorized():
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

        if path == "/v1/sessions":
            title = req_json.get("title", "Cloud Session")
            sid = "sess_" + uuid.uuid4().hex[:12]
            created_at = time.time()
            conn = get_db_connection()
            c = conn.cursor()
            c.execute("INSERT INTO sessions (session_id, title, created_at) VALUES (?, ?, ?)", (sid, title, created_at))
            conn.commit()
            conn.close()
            self._send(201, {"session_id": sid, "title": title, "created_at": created_at})
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
                c.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at) VALUES (?, ?, ?, ?, ?)",
                          (sid, local_session_id, title, instructions, created_at))
                
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

            self._send(200 if existing else 201, {
                "session_id": sid,
                "local_session_id": local_session_id,
                "title": title,
                "status": "ready",
                "imported_messages_count": len(history) if isinstance(history, list) else 0,
                "imported_files_count": imported_files_count,
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

            provider, p_status, p_err = resolve_provider(req_json.get("provider", {}))
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
    print(f"OpenMinis Cloud Computer & Agent running on {HOST}:{PORT}")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
