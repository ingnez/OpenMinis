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
import cloud_cron
import cloud_memory

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

    # 结构化记忆（FTS5 trigram，不可用时退化为 LIKE）
    conn.commit()
    cloud_memory.ensure_schema(conn)

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

def tool_memory_write(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    conn = get_db_connection()
    try:
        entry, created = cloud_memory.write(conn, args.get("content"), args.get("category"), source="cloud", session_id=session_id)
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
        results = cloud_memory.search(conn, args.get("query", ""), args.get("category") or None, args.get("limit", 10))
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
)

def server_tool_notes(session_id):
    """追加到 system 消息的服务端工具说明（客户端 instructions 不了解服务端新增工具）。"""
    return SERVER_TOOL_NOTES

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

    system_text = (instructions or "") + server_tool_notes(session_id)
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
                    elif fn_name == "memory_write": res = tool_memory_write(task_id, session_id, fn_args)
                    elif fn_name == "memory_search": res = tool_memory_search(task_id, session_id, fn_args)
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
            "max_runs", "run_count", "next_run_at", "last_run_at", "last_status", "notify", "created_at", "updated_at"]
    d = dict(zip(keys, r))
    try: d["schedule"] = json.loads(d["schedule"])
    except Exception: d["schedule"] = {}
    d["enabled"] = bool(d["enabled"])
    d["notify"] = bool(d["notify"])
    return d

ROUTINE_COLUMNS = "routine_id, name, prompt, schedule, credential, model, instructions, enabled, max_runs, run_count, next_run_at, last_run_at, last_status, notify, created_at, updated_at"

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
        conn.execute("INSERT INTO routines (" + ROUTINE_COLUMNS + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NULL, NULL, ?, ?, ?)",
                     (rid, fields["name"], fields["prompt"], json.dumps(schedule), fields["credential"], fields["model"],
                      fields.get("instructions"), 1 if enabled else 0, fields.get("max_runs"), next_run,
                      1 if fields.get("notify", True) else 0, now, now))
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
        conn.execute("UPDATE routines SET name = ?, prompt = ?, schedule = ?, credential = ?, model = ?, instructions = ?, enabled = ?, max_runs = ?, next_run_at = ?, notify = ?, updated_at = ? WHERE routine_id = ?",
                     (merged["name"], merged["prompt"], json.dumps(merged["schedule"]), merged["credential"], merged["model"],
                      merged.get("instructions"), 1 if merged["enabled"] else 0, merged.get("max_runs"), merged["next_run_at"],
                      1 if merged["notify"] else 0, now, routine_id))
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
    """例行任务结束的扩展钩子（推送通知等），异常不影响调度。"""
    return None

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
        c.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at) VALUES (?, NULL, ?, ?, ?)",
                  (sid, "例行任务：" + routine["name"], instructions, now))
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
                    "memory_search": True
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

        if path == "/v1/memory":
            def qp(name, default=None):
                v = query_params.get(name)
                return v[0] if v else default
            conn = get_db_connection()
            try:
                if qp("query") is not None or qp("category"):
                    entries = cloud_memory.search(conn, qp("query", ""), qp("category"), int(qp("limit", "20")), source=qp("source"))
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

        if path == "/v1/routines":
            self._send(200, {"routines": list_routines(), "server_time": time.time()})
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
            memory_indexed = 0
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
    print(f"OpenMinis Cloud Computer & Agent running on {HOST}:{PORT}")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
