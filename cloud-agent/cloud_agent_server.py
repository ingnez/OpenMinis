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
import collections
import tempfile
import mimetypes
import urllib.request
import urllib.error
import urllib.parse
import hashlib
import hmac
import base64
_B64 = base64   # 处理函数里有局部 import base64，新代码用这个别名免得变成局部变量
import binascii
import shutil
from urllib.parse import urlparse, parse_qs, unquote
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

# Import sub-modules
SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)

import re
import cloud_browser
import cloud_delegation as deleg
import cloud_groups
import cloud_usage
import cloud_llm
import cloud_efficiency as eff
import cloud_appfeed
import cloud_audit
import cloud_proxy
import cloud_ws
import select
import gzip
from collections import deque
import cloud_desktop
import cloud_vision
import cloud_handoff
import cloud_activity
import cloud_desktop_control
import cloud_botstatus
import cloud_botthreads
import cloud_duty
import cloud_events
import cloud_exams
import cloud_sysnap
import cloud_livestats
import cloud_replay
import cloud_secrets
import cloud_policy
import cloud_cron
import cloud_memory
import cloud_skills
import cloud_notify
import cloud_pages
import cloud_telegram
import cloud_bots
import cloud_admin
import cloud_vault
import cloud_workers
import cloud_reply
import cloud_runmodel
import cloud_shift_card
import cloud_workbench
import cloud_desktop_files
import cloud_snapshots
import cloud_plugins
import cloud_oauth
import cloud_mcp
import cloud_deps
import cloud_isolation as iso
import cloud_displays

HOST = os.environ.get("OPENMINIS_HOST", "127.0.0.1")
PORT = int(os.environ.get("OPENMINIS_PORT", "18765"))
BASE_DIR = os.path.abspath(os.environ.get("OPENMINIS_BASE", SERVER_DIR))
DB_PATH = os.environ.get("OPENMINIS_DB", os.path.join(BASE_DIR, "data", "openminis_agent.db"))
SYSNAP_ETC = os.environ.get("OPENMINIS_SYSNAP_ETC", "/etc")
def replay_dir():
    return os.environ.get("OPENMINIS_REPLAY_DIR") or os.path.join(os.path.dirname(DB_PATH), "replays")

def sysnap_dir():
    return os.environ.get("OPENMINIS_SYSNAP_DIR") or os.path.join(os.path.dirname(DB_PATH), "system_snapshots")


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
ADMIN_BASE = None   # 主 Bot 的 admin_api 回调本机 API 用；run_server 里设好

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
        'sessions': {'local_session_id': 'TEXT', 'instructions': 'TEXT', 'persona_id': 'TEXT', 'incognito': 'INTEGER DEFAULT 0'},
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
    msg_cols = {row[1] for row in cursor.execute("PRAGMA table_info(messages)")}
    if "meta" not in msg_cols:
        # 每条消息的附加信息（JSON）：思考过程、工具耗时、插话标记
        cursor.execute("ALTER TABLE messages ADD COLUMN meta TEXT")
    routine_cols = {row[1] for row in cursor.execute("PRAGMA table_info(routines)")}
    if "persona_id" not in routine_cols:
        cursor.execute("ALTER TABLE routines ADD COLUMN persona_id TEXT")
    if "reasoning_effort" not in routine_cols:
        cursor.execute("ALTER TABLE routines ADD COLUMN reasoning_effort TEXT")
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS snapshots (
        snapshot_id TEXT PRIMARY KEY,
        persona_id TEXT,
        session_id TEXT,
        title TEXT,
        summary TEXT,
        source TEXT,
        created_at REAL
    )
    """)
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_snapshots_persona ON snapshots(persona_id, created_at)")
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
    cursor.execute(deleg.SCHEMA)
    conn.commit()
    cloud_groups.ensure_schema(conn)
    cloud_usage.ensure_schema(conn)
    cloud_memory.ensure_schema(conn)
    cloud_skills.ensure_schema(conn)
    cloud_bots.ensure_schema(conn)
    cloud_admin.ensure_schema(conn)
    cloud_vault.ensure_schema(conn)
    cloud_workers.ensure_schema(conn)
    cloud_reply.ensure_schema(conn)
    cloud_runmodel.ensure_schema(conn)
    cloud_vision.ensure_schema(conn)
    cloud_botthreads.ensure_schema(conn)
    cloud_duty.ensure_schema(conn)
    cloud_exams.ensure_schema(conn)
    cloud_events.ensure_schema(conn)
    conn.execute("CREATE TABLE IF NOT EXISTS feed_feedback (run_id TEXT PRIMARY KEY, liked INTEGER NOT NULL DEFAULT 0, "
                 "comment TEXT NOT NULL DEFAULT '', at REAL NOT NULL, memory_id INTEGER)")
    cloud_vault.set_loader(get_db_connection)
    cloud_plugins.ensure_schema(conn)
    conn.execute("CREATE TABLE IF NOT EXISTS app_settings (name TEXT PRIMARY KEY, value TEXT)")
    try:
        row = conn.execute("SELECT value FROM app_settings WHERE name = 'timezone'").fetchone()
        cloud_memory.set_timezone(row[0] if row else None)
    except Exception as e:
        print(f"timezone setting ignored: {e}")
    cloud_notify.ensure_schema(conn)
    cloud_appfeed.ensure_schema(conn)
    cloud_audit.ensure_schema(conn)
    cloud_pages.ensure_schema(conn)
    cursor.execute("CREATE TABLE IF NOT EXISTS telegram_chats (chat_id INTEGER PRIMARY KEY, session_id TEXT, updated_at REAL)")
    cursor.execute("CREATE TABLE IF NOT EXISTS telegram_tasks (task_id TEXT PRIMARY KEY, chat_id INTEGER, created_at REAL)")
    cursor.execute("CREATE TABLE IF NOT EXISTS telegram_state (key TEXT PRIMARY KEY, value TEXT)")
    cursor.execute("CREATE TABLE IF NOT EXISTS telegram_bot_chats (channel TEXT NOT NULL, chat_id INTEGER NOT NULL, session_id TEXT, updated_at REAL, PRIMARY KEY (channel, chat_id))")
    if "channel" not in {row[1] for row in cursor.execute("PRAGMA table_info(telegram_tasks)")}:
        cursor.execute("ALTER TABLE telegram_tasks ADD COLUMN channel TEXT NOT NULL DEFAULT ''")

    # Server restart: 进行中的任务标记为中断——但如果任务开始后已经写出了助手回答（回答完才被重启打断，
    # 例如回答后顺手记记忆时正好更新服务器），算作完成，免得手机上出现「中断」的误报
    cursor.execute("UPDATE tasks SET status = 'completed' WHERE status IN ('running', 'waiting_user') AND EXISTS ("
                   "SELECT 1 FROM messages m WHERE m.session_id = tasks.session_id AND m.role = 'assistant' "
                   "AND m.content IS NOT NULL AND TRIM(m.content) != '' AND m.timestamp >= tasks.created_at "
                   "AND m.id = (SELECT MAX(id) FROM messages WHERE session_id = tasks.session_id AND role IN ('user', 'assistant') "
                   "AND (content IS NOT NULL AND TRIM(content) != '')))")
    cursor.execute("UPDATE tasks SET status = 'interrupted' WHERE status IN ('running', 'queued', 'waiting_user')")
    cursor.execute("UPDATE approvals SET status = 'expired', decided_at = ? WHERE status = 'pending'", (time.time(),))
    cursor.execute("UPDATE routine_runs SET status = 'interrupted', finished_at = ? WHERE status IN ('running', 'waiting_user')", (time.time(),))
    conn.commit()
    cloud_workers.recover(conn)      # 后台任务：重启前没做完的如实标记中断，并在前台对话里说一声
    conn.close()

init_db()

active_tasks = {}
active_tasks_lock = threading.Lock()

def _kill_task_process(entry):
    proc = entry.get("process")
    if proc and proc.poll() is None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass

def set_task_cancelled(task_id):
    """取消任务，并立即把它的子代理 / 被委托任务（沿 parent 链）一起标记取消、杀掉正在跑的命令。
    不能只靠子任务回头查 parent：上游任务一结束就会从 active_tasks 里移除，链条就断了。"""
    with active_tasks_lock:
        if task_id in active_tasks:
            active_tasks[task_id]["cancelled"] = True
            _kill_task_process(active_tasks[task_id])
        else:
            active_tasks[task_id] = {"process": None, "cancelled": True, "pid": None}
        for tid, entry in list(active_tasks.items()):
            if tid == task_id or entry.get("cancelled"):
                continue
            cur, seen = entry.get("parent"), 0
            while cur and seen < 12:
                if cur == task_id:
                    entry["cancelled"] = True
                    _kill_task_process(entry)
                    break
                cur = active_tasks.get(cur, {}).get("parent")
                seen += 1

def is_task_cancelled(task_id):
    """子代理、被委托的 Bot 任务随上游任务一起取消（沿 parent 链向上最多 12 层）。"""
    with active_tasks_lock:
        seen = 0
        while task_id and seen < 12:
            entry = active_tasks.get(task_id, {})
            if entry.get("cancelled", False):
                return True
            task_id = entry.get("parent")
            seen += 1
        return False

SHARED_WORKSPACE = os.path.join(GLOBAL_WORKSPACE, "shared")
ACTIVE_SLOTS = {}   # session_id -> 同一 Bot 的并发槽（>0 时用独立子工作区 / 屏幕）

def get_session_workspace(session_id):
    """Bot 会话用 Bot 自己的工作区 workspace/bots/<id>/workspace（并发槽 k>0 用 bots/<id>/slots/<k>）；
    旧会话已有 workspace/<session_id> 目录时继续用，升级不丢文件。"""
    legacy = os.path.join(GLOBAL_WORKSPACE, session_id)
    ws = legacy
    if not os.path.isdir(legacy):
        try:
            pid = session_persona_id(session_id)
        except Exception:
            pid = None
        if pid and re.match(r"^[a-z0-9][a-z0-9_-]{0,31}$", pid):
            slot = ACTIVE_SLOTS.get(session_id, 0)
            ws = os.path.join(GLOBAL_WORKSPACE, "bots", pid, "workspace" if not slot else os.path.join("slots", str(slot)))
    os.makedirs(ws, exist_ok=True)
    return ws

def safe_path_resolve(session_id, user_path):
    ws = get_session_workspace(session_id)
    if not user_path:
        return None, "Missing path"
    if user_path == "@shared" or user_path.startswith("@shared/"):
        # 所有 Bot 共用的交换目录
        os.makedirs(SHARED_WORKSPACE, exist_ok=True)
        ws, user_path = SHARED_WORKSPACE, user_path[len("@shared"):].lstrip("/") or "."
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
    s = cloud_vault.redact(str(e))
    s = re.sub(r'sk-[a-zA-Z0-9\-_]{20,}', 'sk-***REDACTED***', s)
    s = re.sub(r'Bearer\s+[a-zA-Z0-9\-_.\s]+', 'Bearer ***REDACTED***', s)
    return s

_TOKEN_PATTERNS = [re.compile(p) for p in (r'sk-[A-Za-z0-9\-_]{16,}', r'gh[pousr]_[A-Za-z0-9]{20,}', r'xox[abprs]-[A-Za-z0-9\-]{10,}',
                                             r'AKIA[0-9A-Z]{16}', r'(?i)bearer\s+[A-Za-z0-9\-_.]{12,}', r'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}')]


SERVER_ERRORS = deque(maxlen=300)


def note_server_error(where, e):
    """服务器自己的异常（后台线程、调度器等）记一笔，给「导出错误日志」用；只存打码后的类型和消息"""
    try:
        SERVER_ERRORS.append({"at": time.time(), "where": where, "error": scrub_text(f"{type(e).__name__}: {e}")[:300]})
    except Exception:
        pass


def error_log(days=7, limit=300):
    """最近的错误：任务出错事件 + 服务器后台异常，按时间倒序；全部打码，不含对话内容"""
    since = time.time() - days * 86400
    conn = get_db_connection()
    try:
        rows = conn.execute("SELECT e.timestamp, e.task_id, e.payload, t.model, COALESCE(s.persona_id, '') FROM task_events e "
                            "LEFT JOIN tasks t ON t.task_id = e.task_id LEFT JOIN sessions s ON s.session_id = t.session_id "
                            "WHERE e.event_type = 'error' AND e.timestamp >= ? ORDER BY e.id DESC LIMIT ?", (since, limit)).fetchall()
    finally:
        conn.close()
    out = []
    for ts, tid, payload, model, bot in rows:
        try:
            err = (json.loads(payload or "{}") or {}).get("error") or ""
        except ValueError:
            err = ""
        out.append({"at": ts, "kind": "task", "task_id": tid, "bot_id": bot, "model": model or "", "error": scrub_text(str(err))[:400]})
    out += [dict(x, kind="server") for x in SERVER_ERRORS if x["at"] >= since]
    out.sort(key=lambda x: x["at"], reverse=True)
    return out[:limit]


def scrub_text(text):
    """保管库里的值 + 常见密钥形状都打码；用于要长期存下来或发出去的文字（值班汇总、错误日志）"""
    text = cloud_vault.redact(text or "")
    for p in _TOKEN_PATTERNS:
        text = p.sub("***", text)
    return text


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

APP_FEED = cloud_appfeed.Feed(lambda: get_db_connection())
RETRACT_WINDOW_S = 15        # 撤回发送：App 给 5 秒按钮，这里多留网络余量
AGENT_VERSION = "2.51.0"     # 与 iOS CloudLinkSupervisor.bundledAgentVersion 保持一致（测试会核对）
DESKTOP_UNITS = ("openminis-display", "openminis-vnc", "openminis-novnc")

_BRIEF_CACHE = {"at": 0.0, "value": None}

def _desktop_health_brief():
    """/health 里的桌面摘要：只做本机端口检查（不做 websocket 探测），并缓存 20 秒，保证 /health 永远秒回
    （自检定时器和 systemd 看门狗靠它判断 Agent 是否活着，慢了会误杀 Agent、打断正在跑的任务）。"""
    now = time.time()
    if _BRIEF_CACHE["value"] is not None and now - _BRIEF_CACHE["at"] < 20:
        return _BRIEF_CACHE["value"]
    if not desktop_installed():
        v = {"installed": False, "ok": False, "diagnosis": "not_installed", "message": "服务器还没有安装云电脑桌面环境"}
    else:
        h = cloud_displays.diagnose(probe=False)
        v = {"installed": True, "ok": h["ok"], "diagnosis": h["diagnosis"], "message": h["message"],
             "xvfb": h["xvfb"], "vnc": h["vnc"], "websockify": h["websockify"], "websockify_mode": h["websockify_mode"]}
    _BRIEF_CACHE.update(at=now, value=v)
    return v

def desktop_installed():
    return all(shutil.which(b) for b in ("Xvfb", "x11vnc", "websockify"))

RESTART_REQUEST = os.environ.get("OPENMINIS_RESTART_REQUEST", "/var/lib/openminis-cloud-agent/run/desktop-restart.request")
RESTART_PATH_UNIT = "/etc/systemd/system/openminis-desktop-restart.path"

def restart_desktop_services(wait_s=20):
    """Agent 以普通用户运行（NoNewPrivileges，不能 sudo）：写入重启请求文件，由安装脚本装的 root path 单元执行重启。
    没装这个单元（旧版安装）时返回原因，App 改用 SSH 重启。"""
    if not os.path.exists(RESTART_PATH_UNIT) or not os.path.isdir(os.path.dirname(RESTART_REQUEST)):
        return False, "no_restart_unit"
    try:
        with open(RESTART_REQUEST, "w") as f:
            f.write(str(time.time()))
    except OSError as e:
        return False, type(e).__name__
    deadline = time.time() + wait_s
    while time.time() < deadline:
        if not os.path.exists(RESTART_REQUEST):
            return True, None
        time.sleep(0.5)
    return False, "timeout"

def start_watchdog():
    """systemd WatchdogSec：每 15 秒自查一次 /health 能否应答，能才喂狗；HTTP 卡死时 systemd 会重启服务。"""
    sock_path = os.environ.get("NOTIFY_SOCKET")
    if not sock_path:
        return
    import socket
    addr = "\0" + sock_path[1:] if sock_path.startswith("@") else sock_path
    def notify(msg):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
                s.connect(addr)
                s.sendall(msg.encode())
        except OSError:
            pass
    def loop():
        notify("READY=1")
        while True:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/livez", timeout=8) as r:
                    if r.status == 200:
                        notify("WATCHDOG=1")
            except Exception:
                pass
            time.sleep(15)
    threading.Thread(target=loop, name="watchdog", daemon=True).start()

def user_notify(cfg, event, title, body, session_id=None, bot_id=None):
    """通知用户：先记进 App 通知流（App 在线时用系统本地通知显示），App 不在线且允许兜底时再发 Bark。"""
    title, body = cloud_vault.redact(title), cloud_vault.redact(body)
    try:
        bot_id = bot_id or (session_persona_id(session_id) if session_id else None)
        if bot_id and bot_id in (resource_settings().get("private_bots") or []):
            # 上锁的 Bot：通知里不带名字和内容
            title, body = "OpenMinis", "有一条新消息（已上锁的 Bot）"
    except Exception as e:
        print(f"notify privacy check failed: {type(e).__name__}", flush=True)
    _duty_record("notify", title, body, bot_id=bot_id, session_id=session_id)
    # 先决定走哪条路：App 进程还活着 → 只进 App 通知流（App 用系统本地通知显示）；
    # App 不在了 → 按设置走 Bark / ntfy / Telegram，并在通知流里标记已推送，App 回来后不再弹一次
    external = False
    if cfg:
        pref = resource_settings().get("bark_fallback", "auto")
        fallback = None if pref == "auto" else pref == "on"
        external = APP_FEED is None or APP_FEED.should_bark(True, fallback)
    try:
        if APP_FEED is not None:
            APP_FEED.add(event, title, body, session_id=session_id, external=external,
                         bot_id=bot_id or (session_persona_id(session_id) if session_id else None))
    except Exception as e:
        print(f"app feed add failed: {type(e).__name__}", flush=True)
    if not external:
        return False
    return cloud_notify.notify_async(cfg, event, title, body)

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

def muted_bots():
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT value FROM app_settings WHERE name = 'notify_muted_bots'").fetchone()
        return set(json.loads(row[0])) if row else set()
    except Exception:
        return set()
    finally:
        conn.close()

def set_bot_notify(bot_id, enabled):
    muted = muted_bots()
    if enabled:
        muted.discard(bot_id)
    else:
        muted.add(bot_id)
    conn = get_db_connection()
    try:
        conn.execute("INSERT INTO app_settings (name, value) VALUES ('notify_muted_bots', ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value",
                     (json.dumps(sorted(muted)),))
        conn.commit()
    finally:
        conn.close()

def _bot_muted(session_id=None, persona_id=None):
    """该会话（或例行任务）所属 Bot 关闭了推送时返回 True。"""
    pid = persona_id if persona_id is not None else (session_persona_id(session_id) if session_id else None)
    return bool(pid) and pid in muted_bots()

def library_shared():
    """共享给所有 Bot 的资料库条目：[{"id", "owner"}]。"""
    v = _settings_get("library_shared") or []
    return [x for x in v if isinstance(x, dict) and x.get("id") and x.get("owner")]


def library_set_shared(bot_id, item_id, shared):
    if not any(i["id"] == item_id for i in bot_library(bot_id, limit=100000, include_shared=False)):
        return False
    cur = [x for x in library_shared() if not (x["id"] == item_id and x["owner"] == bot_id)]
    if shared:
        cur.append({"id": item_id, "owner": bot_id})
    _settings_put("library_shared", cur[-2000:])
    return True


def bot_library(bot_id, limit=300, include_shared=True):
    """Bot 对话里出现过的图片、链接与生成的页面（资料库），加上其他 Bot 共享出来的条目（标 shared_from）。"""
    shared = library_shared()
    own = _bot_library_own(bot_id)
    mine = {x["id"] for x in shared if x["owner"] == bot_id}
    for i in own:
        if i["id"] in mine:
            i["shared"] = True
    if include_shared:
        have = {i["id"] for i in own}
        hidden = set(_settings_get(f"library_hidden:{bot_id}") or [])
        by_owner = {}
        for x in shared:
            if x["owner"] != bot_id and x["id"] not in have and x["id"] not in hidden:
                by_owner.setdefault(x["owner"], set()).add(x["id"])
        for owner, ids in by_owner.items():
            if not get_persona(owner):
                continue
            for i in _bot_library_own(owner):
                if i["id"] in ids:
                    i["shared_from"] = owner
                    own.append(i)
        own.sort(key=lambda i: i.get("at") or 0, reverse=True)
    return own[:limit]


def _bot_library_own(bot_id):
    conn = get_db_connection()
    try:
        sids = [r[0] for r in conn.execute("SELECT session_id FROM sessions WHERE persona_id = ? AND COALESCE(incognito, 0) = 0", (bot_id,)).fetchall()]
        if not sids:
            return []
        marks = ",".join("?" * len(sids))
        rows = conn.execute(f"SELECT id, session_id, role, content, timestamp FROM messages WHERE session_id IN ({marks}) "
                            f"AND role IN ('user', 'assistant') AND content IS NOT NULL ORDER BY id DESC LIMIT 2000", sids).fetchall()
        pages = conn.execute(f"SELECT page_id, title, summary, session_id, updated_at FROM pages WHERE session_id IN ({marks}) ORDER BY updated_at DESC LIMIT 200", sids).fetchall()
    finally:
        conn.close()
    items, seen_links = [], set()
    for mid, sid, role, content, ts in rows:
        text = content
        parts = None
        if content.startswith("["):
            try:
                parts = json.loads(content)
            except ValueError:
                parts = None
        if isinstance(parts, list):
            text = " ".join(p.get("text", "") for p in parts if isinstance(p, dict) and p.get("type") == "text")
            for idx, p in enumerate(parts):
                if isinstance(p, dict) and p.get("type") == "image_url":
                    items.append({"kind": "media", "id": f"m{mid}-{idx}", "message_id": mid, "part": idx, "session_id": sid,
                                  "role": role, "title": "图片", "at": ts})
        for url in re.findall(r"https?://[^\s<>\"'）)\]，。]+", text or ""):
            url = url.rstrip(".,;:!?")
            if url in seen_links:
                continue
            seen_links.add(url)
            host = urllib.parse.urlparse(url).hostname or url
            items.append({"kind": "link", "id": "l" + hashlib.sha256(url.encode()).hexdigest()[:16], "url": url,
                          "title": host, "session_id": sid, "role": role, "at": ts})
    for sid in sids:
        adir = os.path.join(get_session_workspace(sid), "attachments")
        if not os.path.isdir(adir):
            continue
        for name in os.listdir(adir):
            if not name.startswith("up_"):
                continue  # 只收手机上传的附件；Agent 截图不进资料库
            full = os.path.join(adir, name)
            ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
            items.append({"kind": "media" if ext in ("png", "jpg", "jpeg", "heic", "gif", "webp", "mov", "mp4") else "file",
                          "id": "a" + hashlib.sha256((sid + name).encode()).hexdigest()[:16], "title": name[12:] or name,
                          "attachment_url": f"/v1/sessions/{sid}/attachments/{name}", "bytes": os.path.getsize(full),
                          "session_id": sid, "at": os.path.getmtime(full)})
    for pid, title, summary, sid, ts in pages:
        items.append({"kind": "file", "id": "p" + pid, "page_id": pid, "title": title, "summary": summary or "", "session_id": sid, "at": ts})
    hidden = set(_settings_get(f"library_hidden:{bot_id}") or [])
    items = [i for i in items if i["id"] not in hidden]
    items.sort(key=lambda i: i.get("at") or 0, reverse=True)
    return items

def library_delete(bot_id, item_id):
    """从资料库删除一项：手机上传的附件直接删文件；对话里的图片、链接和页面只从资料库隐藏（对话内容不动）。"""
    item = next((i for i in bot_library(bot_id, limit=100000) if i["id"] == item_id), None)
    if not item:
        return False
    att = item.get("attachment_url") if not item.get("shared_from") else None   # 别的 Bot 共享来的：只在这里隐藏
    if att:
        m = re.match(r"^/v1/sessions/([A-Za-z0-9_-]{1,64})/attachments/(up_[A-Za-z0-9._-]{1,128})$", att)
        if m:
            target, err = safe_path_resolve(m.group(1), os.path.join("attachments", m.group(2)))
            if not err and os.path.isfile(target):
                os.remove(target)
                return True
    key = f"library_hidden:{bot_id}"
    hidden = list(_settings_get(key) or [])
    if item_id not in hidden:
        hidden.append(item_id)
        _settings_put(key, hidden[-5000:])
    return True

ATTACH_NAME_RE = re.compile(r"[^A-Za-z0-9._-]+")
AVATAR_MAX_BYTES = 400 * 1024
GROUP_NONCES = {}
GROUP_NONCE_LOCK = threading.Lock()

def avatar_path(bot_id):
    return os.path.join(os.path.dirname(os.path.abspath(DB_PATH)), "avatars", f"{bot_id}.jpg")

def avatar_save(bot_id, data):
    """Bot 照片头像（手机上已缩到 256px 的 JPEG / PNG），返回内容哈希（写进头像编码 av:p<哈希>c<颜色>）。"""
    if not data or len(data) > AVATAR_MAX_BYTES:
        raise ValueError("头像图片需小于 400 KB")
    if not (data[:3] == b"\xff\xd8\xff" or data[:8] == b"\x89PNG\r\n\x1a\n"):
        raise ValueError("头像只支持 JPEG 或 PNG")
    p = avatar_path(bot_id)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(data)
    return hashlib.sha256(data).hexdigest()[:10]

def save_upload(session_id, filename, data):
    """手机上传的附件存到会话工作区 attachments/，文件名去掉危险字符并加随机前缀。"""
    stem, ext = os.path.splitext(os.path.basename(filename or "file"))
    stem = ATTACH_NAME_RE.sub("_", stem).strip("._")[-60:] or "file"
    ext = ATTACH_NAME_RE.sub("", ext.lstrip("."))[:10].lower()
    base = stem + ("." + ext if ext else "")
    name = f"up_{uuid.uuid4().hex[:8]}_{base}"
    target, err = safe_path_resolve(session_id, os.path.join("attachments", name))
    if err:
        raise ValueError(err)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "wb") as f:
        f.write(data)
    return {"file_path": f"attachments/{name}", "filename": name, "bytes": len(data),
            "attachment_url": f"/v1/sessions/{session_id}/attachments/{name}"}

def library_media(bot_id, message_id, part):
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT m.content FROM messages m JOIN sessions s ON s.session_id = m.session_id WHERE m.id = ? AND s.persona_id = ?",
                           (message_id, bot_id)).fetchone()
    finally:
        conn.close()
    if not row:
        return None
    try:
        p = json.loads(row[0])[part]
        return p["image_url"]["url"] if isinstance(p.get("image_url"), dict) else p.get("image_url")
    except (ValueError, IndexError, KeyError, TypeError, AttributeError):
        return None

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
    if _bot_muted(session_id):
        return None
    args = json.dumps(approval.get("arguments"), ensure_ascii=False)
    body = f"{approval.get('reason', '')}\n工具：{approval.get('tool')}  {args[:300]}\n会话：{_session_title(session_id)}"
    user_notify(cfg, "approval_required", "云电脑等待你的审批", body, session_id=session_id)

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
    if _bot_muted(session_id):
        return None
    body = ((row[0] if row else "") or "").strip()
    head, _ = cloud_runmodel.split_one_line(body)
    body = (head or body)[:600] or "（无文字回复）"   # 有「一句话：」时锁屏只放那句结论
    bot = session_bot(session_id)
    if bot and final_status == "completed":
        title = bot.get("name") or "Bot"
    else:
        label = {"completed": "已完成", "failed": "失败", "limit_reached": "达到轮数上限"}[final_status]
        title = f"云电脑任务{label}：{_session_title(session_id)}"
    user_notify(cfg, "task_completed", title[:120], body, session_id=session_id)

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

EVENT_COND = threading.Condition()   # 新事件 / 流式文字更新时唤醒长轮询
LIVE = {}                            # task_id -> {"text", "seq"}：正在生成的文字，只在内存里
LIVE_SEQ = [0]

def log_event(task_id, etype, payload):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute(
        "INSERT INTO task_events (task_id, event_type, payload, timestamp) VALUES (?, ?, ?, ?)",
        (task_id, etype, cloud_vault.redact(json.dumps(payload, ensure_ascii=False)), time.time())
    )
    conn.commit()
    conn.close()
    with EVENT_COND:
        EVENT_COND.notify_all()

def normalize_tool_call_ids(tool_calls, seen):
    """有的中转站不给工具调用 id，或每轮都用同一个 id（如 call_0）。
    在写入历史、执行、记事件之前换成本任务内唯一的 id，手机端才能把结果对上、不把步骤画重或吞掉。"""
    if not isinstance(tool_calls, list):
        return tool_calls
    for tc in tool_calls:
        if not isinstance(tc, dict):
            continue
        tid = tc.get("id")
        if not isinstance(tid, str) or not tid or tid in seen:
            tid = "call_" + uuid.uuid4().hex[:16]
            tc["id"] = tid
        seen.add(tid)
    return tool_calls

def live_update(task_id, text=None, **fields):
    """正在生成的内容（只在内存）：text = 回答文字，reasoning = 思考过程，tool = 正在运行的工具 {id, name, output}。"""
    with EVENT_COND:
        LIVE_SEQ[0] += 1
        cur = dict(LIVE.get(task_id) or {"text": ""})
        if text is not None:
            cur["text"] = text
        cur.update(fields)
        cur["seq"] = LIVE_SEQ[0]
        LIVE[task_id] = cur
        EVENT_COND.notify_all()

def live_has_content(live):
    return bool(live and (live.get("text") or live.get("reasoning") or live.get("tool")))

# ---- 插话：任务进行中用户发来的新消息，不排队，下一步就交给模型
INBOX = {}            # task_id -> {"closed": bool, "items": [{content, nonce}], "nonces": set}
INBOX_LOCK = threading.Lock()

def inbox_push(task_id, content, nonce):
    """返回 (状态码, 结果)。同一个 nonce 只收一次。任务已经收尾（不再看新消息）时返回 409，手机改为发新消息。"""
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT status, session_id FROM tasks WHERE task_id = ?", (task_id,)).fetchone()
    finally:
        conn.close()
    if not row:
        return 404, {"error": "Task not found"}
    with INBOX_LOCK:
        box = INBOX.get(task_id)
        if box and nonce and nonce in box["nonces"]:
            return 200, {"task_id": task_id, "accepted": True, "duplicate": True}
        if row[0] not in ("running", "waiting_user", "queued") or (box and box["closed"]):
            return 409, {"error": "任务已经结束，请作为新消息发送", "status": row[0]}
        box = INBOX.setdefault(task_id, {"closed": False, "items": [], "nonces": set()})
        box["items"].append({"content": content, "nonce": nonce})
        if nonce:
            box["nonces"].add(nonce)
    log_event(task_id, "user_message", {"content": content, "nonce": nonce, "state": "pending"})
    return 202, {"task_id": task_id, "accepted": True}

def inbox_take(task_id):
    with INBOX_LOCK:
        box = INBOX.get(task_id)
        if not box or not box["items"]:
            return []
        items, box["items"] = box["items"], []
        return items

def inbox_pending(task_id):
    with INBOX_LOCK:
        box = INBOX.get(task_id)
        return bool(box and box["items"])

def inbox_close(task_id):
    """任务准备结束：还有没交给模型的插话就返回 True（继续跑），否则关门（之后的插话返回 409）。"""
    with INBOX_LOCK:
        box = INBOX.setdefault(task_id, {"closed": False, "items": [], "nonces": set()})
        if box["items"]:
            return True
        box["closed"] = True
        return False

def inbox_drop(task_id):
    with INBOX_LOCK:
        INBOX.pop(task_id, None)

def insert_message(session_id, role, content, tool_calls=None, tool_call_id=None, meta=None):
    content = cloud_vault.redact(content)
    if tool_calls:
        tool_calls = json.loads(cloud_vault.redact(json.dumps(tool_calls, ensure_ascii=False)))
    conn = get_db_connection()
    try:
        conn.execute("INSERT INTO messages (session_id, role, content, tool_calls, tool_call_id, timestamp, meta) VALUES (?, ?, ?, ?, ?, ?, ?)",
                     (session_id, role, content, json.dumps(tool_calls, ensure_ascii=False) if tool_calls else None, tool_call_id,
                      time.time(), json.dumps(meta, ensure_ascii=False) if meta else None))
        conn.commit()
    finally:
        conn.close()

def live_clear(task_id):
    with EVENT_COND:
        LIVE.pop(task_id, None)
        EVENT_COND.notify_all()

def live_get(task_id):
    with EVENT_COND:
        v = LIVE.get(task_id)
        return dict(v) if v else None

def _file_tail(f, size=1500):
    try:
        end = os.fstat(f.fileno()).st_size
        start = max(0, end - size)
        # pread 按位置读，不动文件指针；/proc/self/fd 只有 Linux 有，macOS 上实时输出会一直是空的
        return os.pread(f.fileno(), end - start, start).decode("utf-8", "replace")
    except OSError:
        return ""

def live_tool_output(task_id, out_f, err_f):
    """命令运行中：把输出尾部放进实时状态，手机上的小终端窗口跟着滚动。"""
    live = live_get(task_id) or {}
    tool = live.get("tool")
    if not tool:
        return
    text = (_file_tail(out_f) + _file_tail(err_f, 500)).strip()
    lines = text.splitlines()[-12:]
    out = "\n".join(lines)
    if out != tool.get("output"):
        live_update(task_id, tool=dict(tool, output=out))

def tool_shell_execute(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Task was cancelled"}
    cmd = args.get("command", "")
    timeout = int(args.get("timeout", 60))
    if not cmd:
        return {"error": "Missing command"}
    ws = get_session_workspace(session_id)
    bot_id = session_persona_id(session_id)
    limits = iso.bot_settings(resource_settings(), bot_id)
    env = task_env(session_id)
    if args.get("background"):
        lane = task_lane(session_id)
        cap = limits.get("bg_jobs_max") or 0
        if cap and BG_JOBS.running_count(lane) >= cap:
            return {"error": f"后台命令已达上限 {cap} 个，请等待或用 background_jobs 停止一个"}
        job = BG_JOBS.start(lane, session_id, cmd, ws, env, limits, os.path.join(ws, ".bg"), on_background_done)
        return {"status": "started", "job_id": job["job_id"], "log": os.path.relpath(job["log"], ws),
                "note": "命令在后台运行，完成后会写回对话并推送；可用 background_jobs 查看进度。"}
    argv, use_shell, preexec = iso.wrap_command(cmd, limits)
    system_op = resource_settings()["system_lock"] and iso.is_system_op(cmd)
    if iso.is_system_op(cmd) and resource_settings().get("system_snapshot", True):
        try:
            snap = cloud_sysnap.take(sysnap_dir(), scrub_text(cmd), etc_root=SYSNAP_ETC)
            log_event(task_id, "status", {"message": f"改系统之前已拍快照 {snap}，可在「系统快照」里对比和回滚"})
        except Exception as e:
            log_event(task_id, "status", {"message": f"系统快照没拍成（{type(e).__name__}），照常执行"})
    if system_op and not iso.SYSTEM_LOCK.acquire(blocking=False):
        log_event(task_id, "status", {"message": "等待其他 Bot 的系统级安装完成…"})
        if not iso.SYSTEM_LOCK.acquire(timeout=max(timeout, 600)):
            return {"error": "等待系统级操作锁超时（其他 Bot 正在安装软件或修改系统配置）"}
    try:
        with tempfile.TemporaryFile() as out_f, tempfile.TemporaryFile() as err_f:
            proc = subprocess.Popen(argv, shell=use_shell, stdout=out_f, stderr=err_f, cwd=ws, env=env,
                                    start_new_session=True, preexec_fn=preexec)
            with active_tasks_lock:
                if task_id in active_tasks:
                    active_tasks[task_id]["process"] = proc
                    active_tasks[task_id]["pid"] = proc.pid
            start_t = time.time()
            last_peek = 0.0
            while proc.poll() is None:
                if time.time() - last_peek > 0.5:
                    last_peek = time.time()
                    live_tool_output(task_id, out_f, err_f)
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
    finally:
        if system_op:
            iso.SYSTEM_LOCK.release()

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

def audit(session_id, tool, target, summary, undo=None):
    """记一笔操作记录；出错不影响工具本身。"""
    try:
        conn = get_db_connection()
        try:
            cloud_audit.record(conn, tool, target, summary, undo, session_id=session_id,
                               bot_id=session_persona_id(session_id) if session_id else None)
        finally:
            conn.close()
    except Exception as e:
        print(f"[audit] record failed: {type(e).__name__}", flush=True)


def tool_file_write(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    target, err = safe_path_resolve(session_id, args.get("path", ""))
    if err:
        return {"error": err}
    try:
        snap = cloud_audit.file_snapshot(target)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as f:
            f.write(args.get("content", ""))
        audit(session_id, "file_write", args.get("path"), ("改写 " if snap and snap.get("existed") else "新建 ") + str(args.get("path")), snap)
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
        snap = cloud_audit.file_snapshot(target)
        with open(target, "w", encoding="utf-8") as f:
            f.write(content.replace(old_s, new_s, 1))
        audit(session_id, "file_edit", args.get("path"), "修改 " + str(args.get("path")), snap)
        return {"status": "success", "path": args.get("path")}
    except Exception as e:
        return {"error": str(e)}

STEP_TEXT_TAIL = 1500
STEP_THUMB_MAX = 24000          # 缩略图字节上限（base64 前），超过就不带

def step_text_tail(fn_name, res):
    """步骤预览的文字：命令看 stdout / stderr 的末尾，其他工具看结果里的主要文字，最后退回结果 JSON。"""
    if isinstance(res, dict):
        parts = [str(res[k]) for k in ("stdout", "stderr") if res.get(k)]
        if not parts:
            for k in ("error", "text", "content", "message", "result", "summary", "title", "url", "path", "status"):
                if isinstance(res.get(k), (str, int, float)) and str(res.get(k)).strip():
                    parts.append(f"{k}: {res[k]}" if k in ("url", "path", "status", "title") else str(res[k]))
                    if k not in ("title", "url"):
                        break
        text = "\n".join(parts) if parts else json.dumps(res, ensure_ascii=False)
    else:
        text = str(res)
    return cloud_vault.redact(text[-STEP_TEXT_TAIL:])

def step_thumbnail(session_id, fn_name):
    """浏览器 / 桌面步骤结束时的小截图（JPEG 字节），截不了返回 None。测试里会替换。"""
    try:
        if fn_name == "browser_action":
            ws = get_session_workspace(session_id)
            key, owner, display = browser_route(session_id)
            r = cloud_browser.execute_browser_action(key, ws, {"action": "__thumb__", "width": 240}, owner=owner, display=display)
            return r.get("thumb") if isinstance(r, dict) else None
        if fn_name == "desktop_action":
            _k, _o, display = browser_route(session_id)
            data, _mime = cloud_desktop.thumbnail(display or os.environ.get("DISPLAY", ":99"), width=240, max_age=0.5)
            return data
    except Exception as e:
        print(f"step thumbnail failed: {type(e).__name__}", flush=True)
    return None

def step_preview(session_id, fn_name, res):
    """每一步的预览数据（随 tool_result 事件发给手机）：文字末尾；浏览器 / 桌面步骤再带一张小 JPEG。"""
    out = {"text": step_text_tail(fn_name, res)}
    if fn_name in ("browser_action", "desktop_action") and not (isinstance(res, dict) and res.get("error")):
        data = step_thumbnail(session_id, fn_name)
        if data and len(data) <= STEP_THUMB_MAX:
            out["thumb"] = base64.b64encode(data).decode()
            out["thumb_mime"] = "image/jpeg"
    return out

def snapshot_route(session_id):
    """快照对应的浏览器资料：给了会话就按那个 Bot 的路由，否则用共享资料"""
    if session_id and re.match(r"^[A-Za-z0-9_-]{1,64}$", session_id):
        key, owner, display = browser_route(session_id)
        return key, owner, display, get_session_workspace(session_id)
    return "shared", None, None, SHARED_WORKSPACE

def tool_browser_action(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    if str(args.get("action") or "").startswith("__"):
        return {"error": f"Unsupported browser action: {args.get('action')}"}
    ws = get_session_workspace(session_id)
    key, owner, display = browser_route(session_id)
    paused = wait_for_user_control(task_id, display)
    if paused:
        return paused
    return cloud_browser.execute_browser_action(key, ws, args, owner=owner, display=display)

# ---------- 多 Bot 隔离：资源设置、排队、屏幕、端口、后台命令 ----------
_resource_cache = {"value": None}
_resource_lock = threading.Lock()

def _settings_get(name):
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT value FROM app_settings WHERE name = ?", (name,)).fetchone()
        return json.loads(row[0]) if row else None
    except (ValueError, sqlite3.Error):
        return None
    finally:
        conn.close()

def _settings_put(name, value):
    conn = get_db_connection()
    try:
        conn.execute("INSERT INTO app_settings (name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value",
                     (name, json.dumps(value, ensure_ascii=False)))
        conn.commit()
    finally:
        conn.close()

def resource_settings():
    with _resource_lock:
        if _resource_cache["value"] is None:
            _resource_cache["value"] = iso.merged_with_defaults(_settings_get("resources"))
        return _resource_cache["value"]

def update_resource_settings(patch):
    with _resource_lock:
        current = _resource_cache["value"] or iso.merged_with_defaults(_settings_get("resources"))
        new = iso.validate(patch, current)
        _settings_put("resources", new)
        _resource_cache["value"] = new
    GATE.poke()
    return new

_index_lock = threading.Lock()

def slot_index(key):
    """Bot / 屏幕键的稳定编号（>=1），用于屏幕号 :10+N 与端口段。"""
    with _index_lock:
        idx = _settings_get("slot_index") or {}
        if key not in idx:
            used = set(idx.values())
            idx[key] = next(i for i in range(1, 10000) if i not in used)
            _settings_put("slot_index", idx)
        return idx[key]

def task_lane(session_id):
    pid = session_persona_id(session_id)
    if session_is_worker(session_id):
        return "worker:" + (pid or session_id)
    return ("bot:" + pid) if pid else ("session:" + session_id)

def display_key(session_id):
    pid = session_persona_id(session_id)
    if not pid:
        return None
    slot = ACTIVE_SLOTS.get(session_id, 0)
    return pid if not slot else f"{pid}:{slot}"

def browser_route(session_id):
    """(浏览器资料键, 标签页归属, DISPLAY)。共享模式：所有 Bot 共用 shared 资料（登录状态共享），
    浏览器开在主屏 :99，每个 Bot 记住自己的标签页；独立模式：Bot 自己的资料和独立屏幕。"""
    pid = session_persona_id(session_id)
    owner = pid or session_id
    if pid and iso.bot_settings(resource_settings(), pid)["browser_profile"] == "per_bot":
        info = DISPLAYS.ensure(display_key(session_id))
        if info:
            DISPLAYS.touch(display_key(session_id))
            return "bot-" + display_key(session_id).replace(":", "-"), owner, info["display"]
        return "bot-" + pid, owner, None
    return "shared", owner, None

def task_env(session_id):
    env = os.environ.copy()
    s = resource_settings()
    env.update(iso.mirror_env(s, os.path.join(os.path.dirname(GLOBAL_WORKSPACE), "cache")))
    env.update(proxy_env())   # 云电脑代理开着时：终端、git、pip、npm 走本机 sing-box（按规则分流）
    pid = session_persona_id(session_id)
    ports = iso.bot_port_range(s, slot_index("bot:" + pid) if pid else 0)
    env["OPENMINIS_SHARED"] = SHARED_WORKSPACE
    env["OPENMINIS_PORTS"] = f"{ports[0]}-{ports[-1]}" if ports else ""
    if ports:
        env["PORT"] = str(ports[0])
    _k, _o, display = browser_route(session_id) if pid else (None, None, None)
    if display:
        env["DISPLAY"] = display
    os.makedirs(SHARED_WORKSPACE, exist_ok=True)
    return env

def isolation_note(session_id):
    s = resource_settings()
    pid = session_persona_id(session_id)
    ports = iso.bot_port_range(s, slot_index("bot:" + pid) if pid else 0)
    return ("\n[工作区] 你的 Shell 当前目录是你自己的工作区；和其他 Bot 交换文件用环境变量 $OPENMINIS_SHARED 目录"
            "（文件工具里写作 @shared/文件名）。"
            + (f"开发服务器请只用端口 {ports[0]}–{ports[-1]}（$PORT 为第一个），不要占用 18765/18766。" if ports else "")
            + "耗时很久的命令（安装、编译、下载）用 shell_execute 的 background=true 在后台跑，完成后会通知你，别阻塞对话。")

def on_background_done(job, log_tail):
    sid = job["session_id"]
    text = (f"[后台命令完成] {job['job_id']} 退出码 {job['exit_code']}\n命令：{job['command'][:200]}\n"
            f"最后输出：\n{log_tail[-1500:]}")
    conn = get_db_connection()
    try:
        busy = conn.execute("SELECT 1 FROM tasks WHERE session_id = ? AND status IN ('running', 'waiting_user')", (sid,)).fetchone()
        if not busy:
            conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'assistant', ?, ?)",
                         (sid, text, time.time()))
            conn.commit()
    finally:
        conn.close()
    cfg = current_notify_config()
    if not _bot_muted(sid):
        user_notify(cfg, "task_completed", f"后台命令完成：{_session_title(sid)}"[:120], text[:600], session_id=sid)

def tool_background_jobs(task_id, session_id, args):
    action = (args or {}).get("action", "list")
    lane = task_lane(session_id)
    if action == "list":
        return {"jobs": [{k: v for k, v in j.items() if k not in ("pid", "lane")} for j in BG_JOBS.list(lane)]}
    job = BG_JOBS.get(str(args.get("job_id", "")))
    if not job or job["lane"] != lane:
        return {"error": "没有这个后台命令"}
    if action == "log":
        return {"job_id": job["job_id"], "status": job["status"], "exit_code": job["exit_code"], "log_tail": iso.tail(job["log"])}
    if action == "stop":
        return {"stopped": BG_JOBS.stop(job["job_id"])}
    return {"job_id": job["job_id"], "status": job["status"], "exit_code": job["exit_code"]}

def resource_usage():
    st = GATE.status()
    return {"running_tasks": len(st["running"]), "queued_tasks": len(st["queued"]),
            "running_bots": len({r["lane"] for r in st["running"]}), "displays_open": len(DISPLAYS.list()),
            "background_jobs": sum(1 for j in BG_JOBS.list() if j["status"] == "running"),
            "displays": DISPLAYS.list(), "queue": st["queued"]}

def _close_browser_for_display(key):
    try:
        cloud_browser.execute_browser_action("bot-" + key.replace(":", "-"), SHARED_WORKSPACE, {"action": "__close__"})
    except Exception:
        pass

GATE = iso.TaskGate(resource_settings)
LIVE_STATS = cloud_livestats.LiveStats()
DISPLAYS = cloud_displays.DisplayManager(resource_settings, slot_index, on_stop=_close_browser_for_display)
DESK_CONTROL = cloud_desktop_control.DesktopControl()
BG_JOBS = iso.BackgroundJobs()

_proxy_mgr = [None]
_proxy_lock = threading.Lock()

def proxy_mgr():
    """云电脑代理（sing-box）。状态和数据库放在同一个目录，节点整体用主密钥加密。"""
    d = os.path.dirname(os.path.abspath(DB_PATH))
    with _proxy_lock:
        m = _proxy_mgr[0]
        if m is None or m.dir != d:
            if m is not None:
                m.shutdown()
            port = int(os.environ.get("OPENMINIS_PROXY_PORT", cloud_proxy.DEFAULT_PORT))
            m = _proxy_mgr[0] = cloud_proxy.ProxyManager(d, cloud_secrets.get_box, port=port)
        return m

def proxy_env():
    try:
        return proxy_mgr().env()
    except Exception:
        return {}

def start_proxy():
    m = proxy_mgr()
    m.apply()
    m.watch()

cloud_browser.PROXY_SERVER_FN = lambda: proxy_mgr().browser_proxy()
cloud_deps.OPENER_FN = lambda: proxy_mgr().opener()

def tool_request_user_takeover(task_id, session_id, args):
    """需要用户亲自操作（登录、验证码、扫码、付款确认）时请求接管：记事件让手机显示「打开电脑」卡片，并推送提醒。"""
    reason = str((args or {}).get("reason") or "").strip()[:300] or "需要你在云电脑上完成一步操作"
    log_event(task_id, "takeover_request", {"reason": reason})
    cfg = current_notify_config()
    if cfg and not _bot_muted(session_id):
        cloud_notify.notify_async(cfg, "approval_required", "Bot 需要你帮忙"[:120],
                                  f"{reason}\n打开 App → 电脑 接管，完成后点「我完成了」。\n会话：{_session_title(session_id)}")
    return {"status": "requested", "reason": reason,
            "note": "已请求用户在手机「电脑」页接管。现在结束本轮，用一两句话告诉用户需要做什么；"
                    "用户完成后会发来“我完成了”，届时先截图确认结果再继续。不要索要或记录密码。"}

def _vault_type_desktop(session_id, values, display=None):
    """在桌面当前焦点处依次输入（栏位之间按 Tab）。值经 stdin 交给 xdotool，不出现在进程参数里。"""
    if not shutil.which("xdotool"):
        return {"error": "云电脑没有安装 xdotool，无法在桌面输入"}
    if display is None and session_id:
        _key, _owner, display = browser_route(session_id)
    env = cloud_desktop._x_env(display or os.environ.get("DISPLAY", ":99"))
    for i, (_name, value) in enumerate(values):
        if i:
            subprocess.run(["xdotool", "key", "Tab"], env=env, capture_output=True, timeout=10)
        r = subprocess.run(["xdotool", "type", "--delay", "20", "--file", "-"], input=str(value).encode("utf-8"),
                           env=env, capture_output=True, timeout=60)
        if r.returncode != 0:
            return {"error": "桌面输入失败"}
    return {"status": "ok", "filled": [n for n, _ in values]}

PHONE_VAULT_FIELDS = ("password", "username", "totp")

def phone_vault_type(body, display):
    """手机「电脑」页从保管库粘贴：服务器解密后直接在桌面焦点处输入，值不回到手机、不进对话和模型。
    返回 (状态码, 响应)。"""
    field = body.get("field") or "password"
    if field not in PHONE_VAULT_FIELDS:
        return 400, {"error": "field must be password, username or totp"}
    conn = get_db_connection()
    try:
        try:
            item, sec = cloud_vault.secret(conn, body.get("item_id"))
        except cloud_vault.VaultError as e:
            return 404, {"error": str(e)}
        except (cloud_secrets.SecretStoreUnavailable, cloud_secrets.SecretDecryptError) as e:
            return 503, {"error": "保管库无法解密：" + str(e)}
        if item["kind"] != "login":
            return 400, {"error": "只有登录项可以在云电脑里粘贴"}
        if field == "totp":
            value = cloud_vault.totp_code(sec["totp"])[0] if sec.get("totp") else None
        elif field == "username":
            value = item.get("username")
        else:
            value = sec.get("password")
        if not value:
            return 400, {"error": "这一项没有这个栏位"}
        res = _vault_type_desktop(None, [(field, value)], display=display or cloud_displays.MAIN_DISPLAY)
        value = None
        ok = res.get("status") == "ok"
        cloud_vault.record_use(conn, item, "phone", None, "phone_desktop_paste", "桌面", ok, None if ok else res.get("error"))
        return (200, {"status": "ok", "item": item["title"], "field": field}) if ok else (500, {"error": res.get("error")})
    finally:
        conn.close()

def tool_vault(task_id, session_id, name, args):
    """保管库工具：机密只在这里解密、直接填进云电脑，返回给模型的只有元数据和「填了哪些栏」。"""
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    actor = session_persona_id(session_id) or "default"
    conn = get_db_connection()
    try:
        if name == "vault_list":
            items = cloud_vault.list_items(conn, args.get("kind"), args.get("query"))
            out = [cloud_vault.for_model(i, actor) for i in items[:50]]
            note = "用 vault_fill(id) 把选中的一项填进当前网页；allowed=false 的项用户不允许 Bot 使用"
            return {"items": out, "count": len(items), "note": note if out else "保管库里没有匹配的项；请用户在 App 的「保管库」里添加"}
        try:
            item, sec = cloud_vault.secret(conn, args.get("id"))
        except cloud_vault.VaultError as e:
            return {"error": str(e) + "；先用 vault_list 查 id"}
        except (cloud_secrets.SecretStoreUnavailable, cloud_secrets.SecretDecryptError) as e:
            return {"error": "保管库无法解密：" + str(e)}
        if not item.get("allow_bots", True):
            cloud_vault.record_use(conn, item, actor, session_id, name, None, False, "用户不允许 Bot 使用这一项")
            return {"error": f"用户关掉了「{item['title']}」的「允许 Bot 使用」，不能使用；请用户在保管库里打开或亲自填写"}
        if not cloud_vault.bot_allowed(item, actor):
            cloud_vault.record_use(conn, item, actor, session_id, name, None, False, "这一项只允许指定的 Bot 使用")
            return {"error": f"「{item['title']}」只允许指定的 Bot 使用，你不在名单里；请用户在保管库里加上你或亲自填写"}
        if item["kind"] == "note":
            return {"error": "安全备注只能用户在 App 里查看，Bot 不能读取或填写"}
        target = args.get("target") or "browser"
        if name == "vault_totp":
            if item["kind"] != "login" or not sec.get("totp"):
                return {"error": "这一项没有保存两步验证（TOTP）密钥"}
            code, left = cloud_vault.totp_code(sec["totp"])
            fields = {"totp": code}
            selectors = {"totp": args["selector"]} if isinstance(args.get("selector"), str) and args.get("selector") else {}
        else:
            fields = cloud_vault.fill_fields(item["kind"], item, sec, args.get("address_index"))
            only = args.get("fields")
            if isinstance(only, list) and only:
                fields = {k: v for k, v in fields.items() if k in only}
            selectors = args.get("selectors") if isinstance(args.get("selectors"), dict) else {}
            left = None
        if not fields:
            return {"error": "这一项没有可以填写的内容"}
        if target == "desktop":
            res = _vault_type_desktop(session_id, list(fields.items()))
            where = "桌面"
        else:
            ws = get_session_workspace(session_id)
            key, owner, display = browser_route(session_id)
            want = cloud_vault.site_key(item["site"]) if item["kind"] == "login" and item.get("site") else None
            res = cloud_browser.execute_browser_action(key, ws, {"action": "__vault_fill__", "fields": fields, "selectors": selectors,
                                                                 "site_key": want, "site_key_fn": cloud_vault.site_key},
                                                       owner=owner, display=display)
            where = (res or {}).get("page_host") or "浏览器"
        fields = None
        ok = isinstance(res, dict) and res.get("status") == "ok"
        cloud_vault.record_use(conn, item, actor, session_id, name, where, ok, None if ok else (res or {}).get("error"))
        out = {"item": item["title"], "where": where}
        for k in ("status", "filled", "not_found", "error", "page_host"):
            if isinstance(res, dict) and k in res:
                out[k] = res[k]
        if ok:
            out["note"] = "已填好（值不会显示给你）。接着点登录 / 提交按钮" + ("；验证码约 %d 秒后过期" % left if left else "")
        return out
    finally:
        conn.close()

def wait_for_user_control(task_id, display):
    """手机接管这块屏幕时先等交还；等不到返回给模型的「已暂停」结果，否则 None。"""
    display = display or cloud_displays.MAIN_DISPLAY
    if not DESK_CONTROL.held(display):
        return None
    log_event(task_id, "user_control_wait", {"display": display})
    ok, _waited = DESK_CONTROL.wait_free(display, cancelled=lambda: is_task_cancelled(task_id))
    if ok:
        return None
    return {"error": "paused_by_user", "paused": True, "note": cloud_desktop_control.PAUSED_NOTE}

def tool_desktop_action(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    ws = get_session_workspace(session_id)
    _key, _owner, display = browser_route(session_id)
    paused = wait_for_user_control(task_id, display)
    if paused:
        return paused
    return cloud_desktop.execute_desktop_action(session_id, ws, args, display_override=display)

def tool_memory_write(task_id, session_id, args):
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    if session_incognito(session_id):
        return {"saved": False, "skipped": "无痕对话不写入长期记忆"}
    conn = get_db_connection()
    try:
        bot = session_bot(session_id)
        # 主 Bot 记下的、或 scope=shared 的内容所有 Bot 共享（用户档案）；其他 Bot 的记忆彼此隔离
        shared = args.get("scope") == "shared" or (bot and bot.get("is_primary") and args.get("scope") != "bot")
        persona = "" if shared else (session_persona_id(session_id) or "")
        entry, created = cloud_memory.write(conn, args.get("content"), args.get("category"), source="cloud", session_id=session_id,
                                            persona=persona)
    except ValueError as e:
        return {"error": str(e)}
    finally:
        conn.close()
    if created:
        audit(session_id, "memory_write", entry["id"], "记住：" + " ".join(str(entry.get("content", "")).split())[:80],
              {"kind": "memory", "id": entry["id"]})
    return {"saved": created, "duplicate": not created, "id": entry["id"], "category": entry["category"], "entry_time": entry["entry_time"]}

# ---------------- /reset：对话快照 ----------------
SNAPSHOT_PROMPT = (
    "把下面这段对话写成一份简洁的快照，供以后接着做时查阅。用对话的语言，Markdown，最多 400 字，分这几节（没有的节省略）：\n"
    "## 目标\n## 已做的决定\n## 当前进度\n## 待办\n## 关键信息（文件路径、ID、命令、地址、账号名等，原样保留；不要写密码和密钥）\n"
    "第一行单独写一个 15 字以内的标题，格式：标题：xxx")

def _context_rows(conn, session_id):
    """上一次 /reset 之后的消息（模型看到的上下文）。"""
    last = conn.execute("SELECT MAX(id) FROM messages WHERE session_id = ? AND role = 'context_reset'", (session_id,)).fetchone()[0] or 0
    return conn.execute("SELECT role, content, tool_calls FROM messages WHERE session_id = ? AND id > ? AND role IN ('user','assistant','tool') "
                        "ORDER BY id ASC", (session_id, last)).fetchall()

def snapshot_transcript(rows, limit=24000):
    parts = []
    for role, content, tcs in rows:
        text = content if isinstance(content, str) else ""
        if text.startswith("[") and role == "user":
            try:
                text = " ".join(p.get("text", "") for p in json.loads(text) if isinstance(p, dict))
            except ValueError:
                pass
        if role == "tool":
            parts.append("工具结果：" + text[:300])
            continue
        if tcs:
            try:
                names = [((tc.get("function") or {}).get("name") or "") + " " + ((tc.get("function") or {}).get("arguments") or "")[:200]
                         for tc in json.loads(tcs)]
                text = (text or "") + "\n[调用工具] " + "；".join(names)
            except ValueError:
                pass
        if text:
            parts.append(("用户：" if role == "user" else "助手：") + text[:3000])
    out = "\n".join(parts)
    return out if len(out) <= limit else out[:limit // 3] + "\n…（中间省略）…\n" + out[-limit * 2 // 3:]

def heuristic_snapshot(rows):
    """模型调不通时的兜底：如实列出最近几条用户消息和最后一段回答，不编内容。"""
    users = [c for r, c, _ in rows if r == "user" and isinstance(c, str) and c and not c.startswith("[")][-5:]
    answer = next((c for r, c, _ in reversed(rows) if r == "assistant" and c), "")
    title = eff.heuristic_title(users[0]) if users else "对话快照"
    body = "## 最近的要求\n" + "\n".join("- " + u[:200] for u in users) + ("\n## 最后的回答（节选）\n" + answer[:600] if answer else "")
    return title or "对话快照", body

def make_snapshot(session_id, provider_config, model):
    conn = get_db_connection()
    try:
        rows = _context_rows(conn, session_id)
    finally:
        conn.close()
    if not any(r == "user" for r, _c, _t in rows):
        return None
    transcript = snapshot_transcript(rows)
    title, summary, source = None, None, "model"
    use_model = resource_settings().get("fast_model") or model
    if provider_config and provider_config.get("api_key") and use_model:
        try:
            url = f"{provider_config.get('base_url', 'https://api.openai.com/v1').rstrip('/')}/chat/completions"
            resp, _t = cloud_llm.chat_completion(url, {"Content-Type": "application/json", "Authorization": f"Bearer {provider_config['api_key']}"},
                                                 {"model": use_model, "messages": [{"role": "system", "content": SNAPSHOT_PROMPT},
                                                                                   {"role": "user", "content": transcript}],
                                                  "max_tokens": 900, "temperature": 0.2}, stream=False, timeout=60)
            text = (((resp.get("choices") or [{}])[0].get("message") or {}).get("content") or "").strip()
            if text:
                first, _, rest = text.partition("\n")
                if first.strip().startswith(("标题：", "标题:", "Title:")):
                    title = first.split("：", 1)[-1].split(":", 1)[-1].strip().strip("#* ")[:40]
                    summary = rest.strip()
                else:
                    summary = text
        except Exception as e:
            print(f"snapshot via model failed: {type(e).__name__}", flush=True)
    if not summary:
        title, summary = heuristic_snapshot(rows)
        source = "heuristic"
    title = title or eff.heuristic_title(next((c for r, c, _ in rows if r == "user" and isinstance(c, str)), "")) or "对话快照"
    snap = {"snapshot_id": "snap_" + uuid.uuid4().hex[:12], "persona_id": session_persona_id(session_id) or "",
            "session_id": session_id, "title": title, "summary": summary[:20000], "source": source, "created_at": time.time()}
    conn = get_db_connection()
    try:
        conn.execute("INSERT INTO snapshots (snapshot_id, persona_id, session_id, title, summary, source, created_at) VALUES (?,?,?,?,?,?,?)",
                     tuple(snap[k] for k in ("snapshot_id", "persona_id", "session_id", "title", "summary", "source", "created_at")))
        conn.commit()
    finally:
        conn.close()
    return snap

def list_snapshots(persona_id, query=None, limit=20):
    conn = get_db_connection()
    try:
        rows = conn.execute("SELECT snapshot_id, title, summary, source, created_at, session_id FROM snapshots WHERE persona_id = ? "
                            "ORDER BY created_at DESC LIMIT 200", (persona_id or "",)).fetchall()
    finally:
        conn.close()
    out = []
    for r in rows:
        if query and not all(k.lower() in (r[1] + "\n" + r[2]).lower() for k in query.split()):
            continue
        out.append({"snapshot_id": r[0], "title": r[1], "summary": r[2], "source": r[3], "created_at": r[4], "session_id": r[5]})
        if len(out) >= limit:
            break
    return out

def get_snapshot(snapshot_id):
    conn = get_db_connection()
    try:
        r = conn.execute("SELECT snapshot_id, persona_id, title, summary, source, created_at, session_id FROM snapshots WHERE snapshot_id = ?",
                         (snapshot_id,)).fetchone()
    finally:
        conn.close()
    if not r:
        return None
    return {"snapshot_id": r[0], "persona_id": r[1], "title": r[2], "summary": r[3], "source": r[4], "created_at": r[5], "session_id": r[6]}

def tool_recall_snapshot(session_id, args):
    pid = session_persona_id(session_id) or ""
    sid = (args or {}).get("snapshot_id")
    if sid:
        snap = get_snapshot(str(sid))
        if not snap or snap["persona_id"] != pid:
            return {"error": "没有这个快照"}
        return {"snapshot_id": snap["snapshot_id"], "title": snap["title"], "created_at": snap["created_at"], "summary": snap["summary"]}
    items = list_snapshots(pid, (args or {}).get("query"), limit=10)
    return {"snapshots": [{"snapshot_id": i["snapshot_id"], "title": i["title"], "created_at": i["created_at"]} for i in items],
            "note": "用 snapshot_id 读取完整内容" if items else "还没有快照"}

def snapshot_pointer(session_id):
    """重置过的对话：系统提示里只放一句指向最近快照的话（不放全文，省 token）。"""
    conn = get_db_connection()
    try:
        r = conn.execute("SELECT meta FROM messages WHERE session_id = ? AND role = 'context_reset' ORDER BY id DESC LIMIT 1", (session_id,)).fetchone()
    finally:
        conn.close()
    if not r:
        return ""
    try:
        snap = get_snapshot((json.loads(r[0] or "{}")).get("snapshot_id") or "")
    except ValueError:
        snap = None
    if not snap:
        return "\n\n[这个对话刚用 /reset 清空了上下文。]"
    return (f"\n\n[这个对话刚用 /reset 清空了上下文。之前的进度存成了快照《{snap['title']}》（{snap['snapshot_id']}）。"
            "用户提到之前的事情时，调用 recall_snapshot 读取，不要凭印象回答。]")

def reset_session(session_id, provider_config, model):
    """/reset：先存快照，再清空上下文（插入一条分隔标记，之后只加载标记之后的消息）。运行中的任务会被停止。"""
    conn = get_db_connection()
    try:
        running = [r[0] for r in conn.execute("SELECT task_id FROM tasks WHERE session_id = ? AND status IN ('running','waiting_user')",
                                              (session_id,)).fetchall()]
        for tid in running:
            set_task_cancelled(tid)
            conn.execute("UPDATE tasks SET status = 'cancelled' WHERE task_id = ? AND status IN ('running','waiting_user')", (tid,))
        conn.commit()
    finally:
        conn.close()
    snap = make_snapshot(session_id, provider_config, model)
    note = "已保存对话快照并重置上下文" if snap else "已重置上下文"
    insert_message(session_id, "context_reset", note,
                   meta={"snapshot_id": snap["snapshot_id"], "title": snap["title"]} if snap else {})
    return {"session_id": session_id, "note": note, "snapshot": snap, "cancelled_tasks": running}

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

# 插件工作目录放在数据目录（服务用户可写）；安装目录归 root，2.46.0 之前放那里导致 stdio 插件 [Errno 13]
PLUGIN_DIR = os.path.abspath(os.environ.get("OPENMINIS_PLUGIN_DIR") or os.path.join(os.path.dirname(os.path.abspath(DB_PATH)), "plugin-files"))
PLUGINS = cloud_plugins.Registry(lambda: get_db_connection(), PLUGIN_DIR, cloud_skills,
                                 legacy_dir=os.path.join(BASE_DIR, "plugin-files"))
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

INCOGNITO_TTL = 24 * 3600


def session_incognito(session_id):
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT incognito FROM sessions WHERE session_id = ?", (session_id,)).fetchone()
        return bool(row and row[0])
    finally:
        conn.close()


def purge_session(conn, sid):
    """彻底删掉一条会话：消息、任务和任务事件一起删。"""
    tids = [r[0] for r in conn.execute("SELECT task_id FROM tasks WHERE session_id = ?", (sid,)).fetchall()]
    for tid in tids:
        conn.execute("DELETE FROM task_events WHERE task_id = ?", (tid,))
    conn.execute("DELETE FROM tasks WHERE session_id = ?", (sid,))
    conn.execute("DELETE FROM messages WHERE session_id = ?", (sid,))
    conn.execute("DELETE FROM sessions WHERE session_id = ?", (sid,))


def purge_stale_incognito(conn, now=None):
    """无痕对话最多留 24 小时（App 离开时会立刻删；这里兜底 App 被杀掉的情况）。正在跑的不删。"""
    cutoff = (now or time.time()) - INCOGNITO_TTL
    rows = conn.execute("SELECT s.session_id FROM sessions s WHERE s.incognito = 1 AND s.created_at < ? AND NOT EXISTS "
                        "(SELECT 1 FROM tasks t WHERE t.session_id = s.session_id AND t.status IN ('running', 'queued', 'waiting_user'))",
                        (cutoff,)).fetchall()
    for (sid,) in rows:
        purge_session(conn, sid)
    return len(rows)


def approval_mode_for(session_id):
    """这个对话所属 Bot 的风险操作处理方式：auto = 一律批准（默认），ask = 按规则先问我。"""
    try:
        return iso.bot_settings(resource_settings(), session_persona_id(session_id)).get("approval_mode") or "auto"
    except Exception:
        return "auto"


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

def bot_activity(conn, pid):
    """首页「正在思考 / 正在用工具 / 正在回复 / 正在委派」：取这个 Bot 最近开始的那个运行中任务的实时状态。没在跑返回 None。"""
    row = conn.execute("SELECT t.task_id FROM tasks t JOIN sessions s ON s.session_id = t.session_id "
                       "WHERE s.persona_id = ? AND t.status = 'running' AND COALESCE(s.incognito, 0) = 0 "
                       "ORDER BY t.created_at DESC LIMIT 1", (pid,)).fetchone()
    if not row:
        return None
    evs = []
    for etype, payload in conn.execute("SELECT event_type, payload FROM task_events WHERE task_id = ? AND event_type IN "
                                       "('delegation_started', 'delegation_finished') ORDER BY id", (row[0],)).fetchall():
        try:
            evs.append((etype, json.loads(payload)))
        except (TypeError, ValueError):
            pass
    out = cloud_activity.describe(live_get(row[0]), cloud_activity.pending_delegation(evs), cloud_vault.redact)
    out["task_id"] = row[0]
    return out

def bot_detail(bot):
    conn = get_db_connection()
    try:
        pid = bot["persona_id"]
        out = dict(bot)
        out["session_count"] = conn.execute("SELECT COUNT(*) FROM sessions WHERE persona_id = ?", (pid,)).fetchone()[0]
        out["routine_count"] = conn.execute("SELECT COUNT(*) FROM routines WHERE persona_id = ?", (pid,)).fetchone()[0]
        out["memory_count"] = conn.execute("SELECT COUNT(*) FROM memory_entries WHERE persona = ?", (pid,)).fetchone()[0]
        out["telegram"] = conn.execute("SELECT 1 FROM secure_settings WHERE name = ?", (telegram_setting_name(pid),)).fetchone() is not None
        # 首页 Bot 列表：最近会话、最后一条可见消息、运行中 / 待审批任务数
        latest = conn.execute("SELECT s.session_id, s.title FROM sessions s LEFT JOIN messages m ON m.session_id = s.session_id "
                              "WHERE s.persona_id = ? AND COALESCE(s.incognito, 0) = 0 AND s.session_id NOT IN (SELECT worker_session FROM bot_workers) GROUP BY s.session_id ORDER BY MAX(COALESCE(m.timestamp, s.created_at)) DESC LIMIT 1", (pid,)).fetchone()
        out["latest_session_id"] = latest[0] if latest else None
        out["running_workers"] = conn.execute("SELECT COUNT(*) FROM bot_workers WHERE COALESCE(bot_id, '') = ? AND status IN ('queued', 'running')",
                                              (pid or "",)).fetchone()[0]
        out["latest_session_title"] = latest[1] if latest else None
        last = conn.execute("SELECT m.role, m.content, m.timestamp, m.session_id FROM messages m JOIN sessions s ON s.session_id = m.session_id "
                            "WHERE s.persona_id = ? AND COALESCE(s.incognito, 0) = 0 AND s.session_id NOT IN (SELECT worker_session FROM bot_workers) AND m.role IN ('user', 'assistant') AND m.content IS NOT NULL AND m.content != '' "
                            "ORDER BY m.timestamp DESC, m.id DESC LIMIT 1", (pid,)).fetchone()
        out["last_message"] = {"role": last[0], "preview": CloudMessageText_plain(str(last[1]))[:120], "at": last[2], "session_id": last[3]} if last else None
        tmsg = cloud_botthreads.latest_for(conn, pid)
        if tmsg and (not last or tmsg["ts"] >= (last[2] or 0) - 0.5):
            # 最近的动静是和别的 Bot 说话：首页显示「➤ 已发消息给 X：…」/「← 来自 X：…」
            out["thread_preview"] = {"text": cloud_botthreads.preview_text(pid, tmsg, _thread_names()), "at": tmsg["ts"],
                                     "peer": tmsg["recipient"] if tmsg["sender"] == cloud_botthreads.norm(pid) else tmsg["sender"],
                                     "outgoing": tmsg["sender"] == cloud_botthreads.norm(pid), "priority": tmsg["priority"]}
        counts = dict(conn.execute("SELECT t.status, COUNT(*) FROM tasks t JOIN sessions s ON s.session_id = t.session_id "
                                   "WHERE s.persona_id = ? AND t.status IN ('running', 'queued', 'waiting_user') GROUP BY t.status", (pid,)).fetchall())
        out["notify"] = pid not in muted_bots()
        out["queued_tasks"] = sum(1 for q in GATE.status()["queued"] if q["lane"] == "bot:" + pid)
        out["resources"] = iso.bot_settings(resource_settings(), pid)
        out["resource_overrides"] = resource_settings()["bot_overrides"].get(pid, {})
        out["routines_enabled"] = conn.execute("SELECT COUNT(*) FROM routines WHERE persona_id = ? AND enabled = 1", (pid,)).fetchone()[0]
        out["prefs"] = cloud_admin.prefs(conn, pid)
        out["running_tasks"] = counts.get("running", 0) + counts.get("queued", 0)
        out["waiting_approvals"] = counts.get("waiting_user", 0)
        out["activity"] = bot_activity(conn, pid)
        # 首页状态：未读数、待回答卡片、最近一次任务是否出错、例行任务在跑 → status {state, unread, flags}
        cloud_botstatus.fill(conn, out, "COALESCE(s.incognito, 0) = 0 AND s.session_id NOT IN (SELECT worker_session FROM bot_workers)")
        # 存了密钥的 Bot：有自己的 API 凭据，或用过保管库里的条目 → App 默认给它上 Face ID 锁
        out["holds_secrets"] = bool(bot.get("credential")) or conn.execute(
            "SELECT 1 FROM vault_uses WHERE actor = ? AND ok = 1 LIMIT 1", (pid or "default",)).fetchone() is not None
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
    return ("\n[@提及] 用户在消息中 @ 了：" + "、".join(ids) + "。请用 delegate_task(bot_id=…) 把相应部分交给这些 Bot"
            "（它们在自己的工作区用自己的模型完成），再把它们的结果整合给用户；只想快速问一句可用 subagent_task 并传 persona。")

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
        personas_note += ("\n[Bot 协作] 需要别的 Bot 动手做事时用 delegate_task（在对方工作区执行，结果交回给你），只是通知用 send_to_bot；"
                          "收到以「【来自 …】」开头的消息说明是别的 Bot 交给你的，完成后最后一条回复写清结果。list_bots 查看所有 Bot。")
        if (session_bot(session_id) or {}).get("is_primary"):
            personas_note += ("\n[主 Bot 分派] 你是主 Bot：用户的请求明显属于某个 Bot 的专长（看 list_bots 的描述）时，用 delegate_task 交给它，"
                              "并告诉用户交给了谁；回复里提到别的 Bot 时写成 @名字，手机会显示成可点开它对话的标签。")
        personas_note += "\n[其他人格] 需要其他人格的专长或它们的私有记忆时，用 subagent_task 并传 persona 询问：" + "；".join(
            f"{p['persona_id']}（{p['name']}）" for p in others[:20])
    return SERVER_TOOL_NOTES + personas_note + isolation_note(session_id) + skills_index

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

def tool_skill_save(task_id, session_id, args):
    """Bot 把做成功的多步流程存成技能，之后用 skill_load 复用。"""
    if is_task_cancelled(task_id):
        return {"error": "Cancelled"}
    name, content = args.get("name"), args.get("content")
    desc = args.get("description")
    if isinstance(content, str) and desc and not content.lstrip().startswith("---"):
        content = f"---\ndescription: {' '.join(str(desc).split())[:300]}\n---\n" + content
    conn = get_db_connection()
    try:
        existing = cloud_skills.load(conn, name) if isinstance(name, str) else None
        if existing and existing.get("source") not in (None, "bot") and not args.get("overwrite"):
            return {"error": f"已有同名技能「{name}」（来自手机同步），换个名字或传 overwrite=true"}
        result = cloud_skills.upsert(conn, name, content, desc, source="bot")
        bot = session_bot(session_id)
        if bot and bot.get("skills") is not None and name not in bot["skills"]:
            conn.execute("UPDATE personas SET skills = ? WHERE persona_id = ?", (json.dumps(bot["skills"] + [name]), bot["persona_id"]))
            conn.commit()
    except ValueError as e:
        return {"error": str(e)}
    finally:
        conn.close()
    return {"status": result, "name": name, "note": "以后遇到同类任务先 skill_load 这个技能"}

def search_everything(q, limit=60):
    """在所有 Bot 对话与群聊里搜文字（不含工具输出）。"""
    like = "%" + q.replace("%", r"\%").replace("_", r"\_") + "%"
    conn = get_db_connection()
    try:
        rows = conn.execute(
            "SELECT m.session_id, m.role, m.content, m.timestamp, s.title, s.persona_id FROM messages m JOIN sessions s ON s.session_id = m.session_id "
            "WHERE m.role IN ('user', 'assistant') AND COALESCE(s.incognito, 0) = 0 AND m.content LIKE ? ESCAPE '\\' ORDER BY m.timestamp DESC LIMIT ?", (like, limit)).fetchall()
        grows = conn.execute(
            "SELECT gm.group_id, gm.id, gm.sender, gm.content, gm.timestamp, g.name FROM group_messages gm JOIN groups g ON g.group_id = gm.group_id "
            "WHERE gm.kind IN ('text', 'task', 'task_result') AND gm.content LIKE ? ESCAPE '\\' ORDER BY gm.timestamp DESC LIMIT ?", (like, limit)).fetchall()
        trows = cloud_botthreads.search(conn, like, limit)
        extra = search_extras(conn, like)
    finally:
        conn.close()

    def snippet(text):
        text = CloudMessageText_plain(text or "")
        i = text.lower().find(q.lower())
        start = max(0, i - 30)
        return ("…" if start else "") + text[start:start + 120].replace("\n", " ")

    names = {p["persona_id"]: p["name"] for p in list_personas()}
    items = [{"type": "bot", "session_id": r[0], "role": r[1], "snippet": snippet(r[2]), "timestamp": r[3], "title": r[4],
              "bot_id": r[5] or "", "bot_name": names.get(r[5], "主助手")} for r in rows]
    items += [{"type": "group", "group_id": r[0], "message_id": r[1], "sender": r[2], "snippet": snippet(r[3]), "timestamp": r[4],
               "group_name": r[5], "bot_name": "我" if r[2] == "user" else names.get(r[2], r[2])} for r in grows]
    tn = _thread_names()
    items += [{"type": "bot_thread", "message_id": r["id"], "bots": sorted([r["sender"], r["recipient"]]), "sender": r["sender"],
               "snippet": snippet(r["text"]), "timestamp": r["ts"], "bot_name": tn.get(r["sender"], r["sender"]),
               "title": f"{tn.get(r['sender'], r['sender'])} ↔ {tn.get(r['recipient'], r['recipient'])}"} for r in trows]
    items.sort(key=lambda x: -(x["timestamp"] or 0))
    # 页面 / 例行任务 / 保管库放在聊天记录前面：条目少、按名字找的时候最想要
    return (extra + items)[:limit]

def search_extras(conn, like):
    """统一搜索里的非聊天条目：页面（标题 / 摘要）、例行任务（名字 / 内容）、保管库（只搜标题，绝不碰密文）。"""
    out = []
    try:
        for r in conn.execute("SELECT p.page_id, p.title, p.summary, p.updated_at, s.persona_id FROM pages p LEFT JOIN sessions s ON s.session_id = p.session_id "
                              "WHERE COALESCE(s.incognito, 0) = 0 AND (p.title LIKE ? ESCAPE '\\' OR p.summary LIKE ? ESCAPE '\\') "
                              "ORDER BY p.updated_at DESC LIMIT 10", (like, like)).fetchall():
            out.append({"type": "page", "page_id": r[0], "title": r[1] or "页面", "snippet": (r[2] or "")[:120],
                        "timestamp": r[3], "bot_id": r[4] or ""})
    except sqlite3.Error:
        pass
    try:
        for r in conn.execute("SELECT routine_id, name, prompt, schedule, updated_at, persona_id FROM routines "
                              "WHERE name LIKE ? ESCAPE '\\' OR prompt LIKE ? ESCAPE '\\' ORDER BY updated_at DESC LIMIT 10", (like, like)).fetchall():
            out.append({"type": "routine", "routine_id": r[0], "title": r[1] or "例行任务", "snippet": f"{r[3] or ''} · {(r[2] or '')[:100]}",
                        "timestamp": r[4], "bot_id": r[5] or ""})
    except sqlite3.Error:
        pass
    try:
        for r in conn.execute("SELECT id, kind, title, updated_at FROM vault_items WHERE title LIKE ? ESCAPE '\\' ORDER BY updated_at DESC LIMIT 10",
                              (like,)).fetchall():
            out.append({"type": "vault", "item_id": r[0], "title": r[2], "snippet": {"login": "登录", "card": "银行卡", "contact": "联系信息"}.get(r[1], r[1]),
                        "timestamp": r[3]})
    except sqlite3.Error:
        pass
    return out

def _thread_names():
    names = {p["persona_id"]: p["name"] for p in list_personas()}
    names[cloud_botthreads.MAIN] = "主助手"
    return names

_ATT_LINE = re.compile(r"^\s*\[附件\] (.*?) → 工作区 (\S+)\s*$", re.M)

def CloudMessageText_plain(raw):
    """给人看的一行文字：message_parts 只取文字；「[附件] … → 工作区 …」行（给模型找文件用）换成 [图片] / [文件] 名字"""
    text, images = raw or "", 0
    if text.startswith("["):
        try:
            parts = json.loads(text)
            if isinstance(parts, list):
                images = sum(1 for p in parts if isinstance(p, dict) and p.get("type") == "image_url")
                text = " ".join(p.get("text", "") for p in parts if isinstance(p, dict) and p.get("type") == "text")
        except (ValueError, TypeError):
            pass
    marks = []
    for name, rel in _ATT_LINE.findall(text):
        ext = rel.rsplit(".", 1)[-1].lower() if "." in rel else ""
        marks.append("[图片]" if ext in cloud_vision.IMAGE_EXTS else f"[文件] {name}")
    if marks:
        text = _ATT_LINE.sub("", text).strip()
        if text == "请查看附件。":
            text = ""
        if images:   # 老版本 App：图片同时在 parts 里，别数两遍
            marks = [m for m in marks if m != "[图片]"]
    marks = ["[图片]"] * images + marks
    return " ".join(x for x in [" ".join(text.split())] + marks if x)

BACKUP_FORMAT = "openminis-backup/1"

def make_backup(include_messages=True):
    """导出 Bot、对话、群聊、例行任务、记忆、技能（Bot 写的）与资源设置；不含任何密钥或凭据内容。"""
    conn = get_db_connection()
    try:
        bots = [cloud_bots.export_bundle(conn, p["persona_id"], [], []) for p in list_personas()]
        sessions = []
        for r in conn.execute("SELECT session_id, title, instructions, created_at, persona_id FROM sessions ORDER BY created_at ASC").fetchall():
            s = {"session_id": r[0], "title": r[1], "instructions": r[2], "created_at": r[3], "persona_id": r[4]}
            if include_messages:
                s["messages"] = [{"role": m[0], "content": m[1], "tool_calls": m[2], "tool_call_id": m[3], "timestamp": m[4]} for m in conn.execute(
                    "SELECT role, content, tool_calls, tool_call_id, timestamp FROM messages WHERE session_id = ? ORDER BY id ASC", (r[0],)).fetchall()]
            sessions.append(s)
        groups = []
        for g in cloud_groups.list_groups(conn):
            g.pop("last_message", None)
            g["messages"] = cloud_groups.messages_after(conn, g["group_id"], 0, 100000) if include_messages else []
            groups.append(g)
        memory = cloud_memory.list_entries(conn, limit=1000)
        skills = [cloud_skills.load(conn, s["name"]) for s in cloud_skills.list_index(conn)]
        skills = [{"name": s["name"], "description": s["description"], "content": s["content"]} for s in skills if s and s.get("source") == "bot"]
    finally:
        conn.close()
    routines = [{k: v for k, v in r.items() if k not in ("credential",)} for r in list_routines()]
    return {"format": BACKUP_FORMAT, "created_at": time.time(), "bots": bots, "sessions": sessions, "groups": groups,
            "routines": routines, "memory": memory, "skills": skills, "settings": resource_settings()}

def restore_backup(backup, include_settings=False):
    """合并导入：已存在的 Bot / 会话 / 群聊保持不变（按 ID 跳过），记忆按内容去重。例行任务需要凭据，不自动导入。"""
    if not isinstance(backup, dict) or backup.get("format") != BACKUP_FORMAT:
        raise ValueError("不是 OpenMinis 备份文件（openminis-backup/1）")
    stats = {"bots": 0, "sessions": 0, "messages": 0, "groups": 0, "memory": 0, "skills": 0, "skipped": 0}
    conn = get_db_connection()
    try:
        for b in backup.get("bots") or []:
            bid = (b or {}).get("bot_id")
            if not isinstance(bid, str) or not cloud_bots.BOT_ID_RE.match(bid) or cloud_bots.get(conn, bid):
                stats["skipped"] += 1
                continue
            body = {k: v for k, v in (b.get("bot") or {}).items() if k in ("name", "emoji", "description", "instructions", "skills", "plugins")}
            try:
                cloud_bots.upsert(conn, bid, body, credential_exists)
                stats["bots"] += 1
            except cloud_bots.BotError:
                stats["skipped"] += 1
        for s in backup.get("sessions") or []:
            sid = (s or {}).get("session_id")
            if not isinstance(sid, str) or not re.match(r"^[A-Za-z0-9_-]{1,64}$", sid) or conn.execute("SELECT 1 FROM sessions WHERE session_id = ?", (sid,)).fetchone():
                stats["skipped"] += 1
                continue
            pid = s.get("persona_id") if s.get("persona_id") and cloud_bots.get(conn, s.get("persona_id")) else None
            conn.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, NULL, ?, ?, ?, ?)",
                         (sid, str(s.get("title") or "")[:200], str(s.get("instructions") or ""), float(s.get("created_at") or time.time()), pid))
            for m in s.get("messages") or []:
                if isinstance(m, dict) and m.get("role") in ("user", "assistant", "tool", "system"):
                    conn.execute("INSERT INTO messages (session_id, role, content, tool_calls, tool_call_id, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
                                 (sid, m["role"], m.get("content"), m.get("tool_calls"), m.get("tool_call_id"), float(m.get("timestamp") or 0)))
                    stats["messages"] += 1
            stats["sessions"] += 1
        conn.commit()
        for g in backup.get("groups") or []:
            gid = (g or {}).get("group_id")
            if not isinstance(gid, str) or not re.match(r"^grp_[a-f0-9]{10}$", gid) or cloud_groups.get_group(conn, gid):
                stats["skipped"] += 1
                continue
            members = [m for m in (g.get("members") or []) if cloud_bots.get(conn, m)]
            if not members:
                stats["skipped"] += 1
                continue
            conn.execute("INSERT INTO groups (group_id, name, members, activity, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                         (gid, str(g.get("name") or "群聊")[:40], json.dumps(members), g.get("activity"), g.get("created_at") or time.time(), g.get("updated_at") or time.time()))
            for m in g.get("messages") or []:
                conn.execute("INSERT INTO group_messages (group_id, sender, kind, content, reply_to, meta, timestamp) VALUES (?, ?, ?, ?, NULL, ?, ?)",
                             (gid, str(m.get("sender") or "user"), str(m.get("kind") or "text"), m.get("content"),
                              json.dumps(m.get("meta")) if m.get("meta") else None, m.get("timestamp") or 0))
            stats["groups"] += 1
        conn.commit()
        for e in backup.get("memory") or []:
            try:
                persona = e.get("persona") if e.get("persona") and cloud_bots.get(conn, e.get("persona")) else ""
                _, created = cloud_memory.write(conn, e.get("content"), e.get("category"), source="import", entry_time=e.get("entry_time"),
                                                commit=False, persona=persona)
                stats["memory"] += 1 if created else 0
            except (ValueError, AttributeError):
                stats["skipped"] += 1
        for sk in backup.get("skills") or []:
            try:
                if not cloud_skills.load(conn, sk.get("name")):
                    cloud_skills.upsert(conn, sk.get("name"), sk.get("content"), sk.get("description"), source="bot", commit=False)
                    stats["skills"] += 1
            except (ValueError, AttributeError):
                stats["skipped"] += 1
        conn.commit()
    finally:
        conn.close()
    if include_settings and isinstance(backup.get("settings"), dict):
        try:
            update_resource_settings({k: v for k, v in backup["settings"].items() if k != "bot_overrides"})
            stats["settings"] = True
        except iso.SettingsError as e:
            stats["settings_error"] = str(e)
    return stats

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
    TURN_FLAGS.setdefault(task_id, {}).setdefault("pages", []).append({"page_id": page["page_id"], "title": page["title"]})
    return {"status": "ok", "page_id": page["page_id"], "title": page["title"], "version": page["version"], "size": page["size"],
            "note": "页面已保存，聊天里会显示成页面卡片；回复只写一两句结论，不要把页面内容再贴一遍。"}

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

# ---------------- Bot 之间的消息与委托 ----------------
TASK_HOP = {}            # task_id -> 委托层数（用户直接发起的是 0）
TASK_PRIORITY = {}       # task_id -> "high" 时排到普通任务前面
DELEG_LIMITER = deleg.PairLimiter()
DELEG_THREADS = {}       # delegation_id -> worker 线程
DELEG_WAIT_DEFAULT = 600
DELEG_WAITING = set()    # 请求方正在同步等待结果的委托：worker 结束时不另行回报
DELEG_LOCK = threading.Lock()

def _bot_label(bot):
    return (bot or {}).get("name") or "主助手"

def tool_list_bots(task_id, session_id, args):
    own = session_persona_id(session_id)
    conn = get_db_connection()
    try:
        busy = {r[0] for r in conn.execute(
            "SELECT s.persona_id FROM tasks t JOIN sessions s ON s.session_id = t.session_id WHERE t.status IN ('running', 'waiting_user')")}
    finally:
        conn.close()
    bots = []
    for b in list_personas():
        if b["persona_id"] == own:
            continue
        bots.append({"bot_id": b["persona_id"], "name": b["name"], "description": (b.get("description") or "")[:200],
                     "model": b.get("model") or "", "busy": b["persona_id"] in busy})
    out = {"bots": bots, "you": own or ""}
    if is_admin_session(session_id):
        conn = get_db_connection()
        try:
            out["trash"] = cloud_admin.trash(conn)
        finally:
            conn.close()
    return out

ADMIN_API_BLOCKED = re.compile(r"^/v1/(credentials|notify|backup|auth|token|vault)(/|$)")

def _admin_api(method, path, body):
    """主 Bot 调本机 API（和 App 用的同一套）。密钥类接口不开放：模型不该经手原始密钥。"""
    method = (method or "GET").upper()
    if method not in ("GET", "POST", "PUT", "DELETE") or not isinstance(path, str) or not path.startswith("/v1/") or ".." in path:
        return {"error": "path 必须是 /v1/ 开头的接口，method 为 GET/POST/PUT/DELETE"}
    if ADMIN_API_BLOCKED.match(path.split("?")[0]):
        return {"error": "密钥、推送、备份类接口不能由 Bot 调用，请让用户在 App 设置里操作"}
    if method == "DELETE" and path.split("?")[0].rstrip("/") in (f"/v1/bots/{primary_bot_id()}", f"/v1/personas/{primary_bot_id()}"):
        return {"error": "主 Bot 不能删除自己"}
    if method == "DELETE" and re.match(r"^/v1/(bots|personas)/[^/]+$", path.split("?")[0]):
        return {"error": "删除 Bot 请用 delete_bot（进回收站，可恢复）"}
    base = ADMIN_BASE or f"http://127.0.0.1:{PORT}"
    data = json.dumps(body if isinstance(body, dict) else {}).encode() if method in ("POST", "PUT") else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Authorization": f"Bearer {SERVER_TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except Exception as e:
        return {"error": f"调用失败：{type(e).__name__}"}
    try:
        payload = json.loads(raw.decode("utf-8", "replace") or "{}")
    except ValueError:
        payload = {"text": raw.decode("utf-8", "replace")[:4000]}
    return {"status": status, "result": payload}

def tool_admin(task_id, session_id, name, args):
    """主 Bot 的管理工具。每次改动记审计日志并带撤销信息；改完推一条 bots_changed，App 首页马上刷新。"""
    actor = session_persona_id(session_id)
    if name == "admin_api":
        res = _admin_api(args.get("method"), args.get("path"), args.get("body"))
        if (args.get("method") or "GET").upper() != "GET":
            audit(session_id, "admin_api", f"{(args.get('method') or '').upper()} {args.get('path')}", f"状态 {res.get('status')}")
            if str(args.get("path") or "").startswith(("/v1/bots", "/v1/personas")):
                bots_changed()
        return res
    conn = get_db_connection()
    try:
        if name == "create_bot":
            body = dict(args)
            if body.get("model") and not body.get("credential"):
                own = session_bot(session_id) or {}
                if own.get("credential"):
                    body["credential"] = own["credential"]
            bot = cloud_admin.create(conn, body, credential_exists)
            undo, summary, target = {"kind": "bot", "op": "create", "bot_id": bot["bot_id"]}, f"新建 Bot「{bot['name']}」", bot["bot_id"]
            out = {"created": True, "bot": bot_detail(bot)}
        elif name == "update_bot":
            bid = args.get("bot_id")
            bot, before = cloud_admin.update(conn, bid, {k: v for k, v in args.items() if k != "bot_id"}, credential_exists)
            undo, summary, target = {"kind": "bot", "op": "update", "bot_id": bid, "before": before}, f"修改 Bot「{bot['name']}」", bid
            out = {"updated": True, "bot": bot_detail(bot)}
        elif name == "delete_bot":
            bid = args.get("bot_id")
            if bid == actor:
                raise cloud_admin.AdminError("主 Bot 不能删除自己")
            bot = cloud_admin.delete(conn, bid, actor)
            undo, summary, target = {"kind": "bot", "op": "delete", "bot_id": bid}, f"删除 Bot「{bot['name']}」（在回收站，可恢复）", bid
            out = {"deleted": True, "in_trash": True, "bot_id": bid}
        elif name == "restore_bot":
            bot = cloud_admin.restore(conn, args.get("bot_id"), credential_exists)
            undo, summary, target = {"kind": "bot", "op": "create", "bot_id": bot["bot_id"]}, f"从回收站恢复 Bot「{bot['name']}」", bot["bot_id"]
            out = {"restored": True, "bot": bot_detail(bot)}
        elif name == "set_primary_bot":
            bid = args.get("bot_id")
            prev = cloud_admin.set_primary(conn, bid)
            undo, summary, target = {"kind": "bot", "op": "set_primary", "bot_id": bid, "previous": prev}, f"把 {bid} 设为主 Bot", bid
            out = {"primary": bid, "previous": prev}
        else:
            return {"error": "未知的管理工具"}
    except (cloud_admin.AdminError, cloud_bots.BotError) as e:
        return {"error": str(e)}
    finally:
        conn.close()
    audit(session_id, name, target, summary, undo)
    bots_changed()
    return out

def bots_changed():
    """App 首页靠通知流里的 bots_changed 马上刷新 Bot 列表（不弹系统通知）。"""
    try:
        if APP_FEED is not None:
            APP_FEED.add("bots_changed", "", "", external=True)
    except Exception as e:
        print(f"bots_changed feed failed: {type(e).__name__}", flush=True)

def _delegation_row(did):
    conn = get_db_connection()
    try:
        conn.row_factory = sqlite3.Row
        r = conn.execute("SELECT * FROM bot_delegations WHERE delegation_id = ?", (did,)).fetchone()
        return dict(r) if r else None
    finally:
        conn.close()

def list_delegations(session_id=None, limit=50):
    conn = get_db_connection()
    try:
        conn.row_factory = sqlite3.Row
        if session_id:
            rows = conn.execute("SELECT * FROM bot_delegations WHERE from_session = ? OR to_session = ? ORDER BY created_at DESC LIMIT ?",
                                (session_id, session_id, limit)).fetchall()
        else:
            rows = conn.execute("SELECT * FROM bot_delegations ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()

def _post_when_idle(session_id, text, timeout=1800):
    """等会话空闲后把一条 assistant 消息写进去（不在别的任务的工具调用中间插消息）。"""
    deadline = time.time() + timeout
    while True:
        conn = get_db_connection()
        try:
            busy = conn.execute("SELECT 1 FROM tasks WHERE session_id = ? AND status IN ('running', 'waiting_user')", (session_id,)).fetchone()
            if not busy or time.time() > deadline:
                conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'assistant', ?, ?)",
                             (session_id, text, time.time()))
                conn.commit()
                return True
        finally:
            conn.close()
        time.sleep(1.0)

# ---------- 后台任务（worker）：前台聊天，后台干活 ----------
WORKER_RUNTIME = {}          # worker_id -> (model, provider)：排队的任务开跑时用；重启后丢失（中断的任务由前台 task_resume 带上新的）
WORKER_LOCK = threading.Lock()

def worker_view(w):
    """给前台 / App 看的任务状态：进行中的任务补上最近一步（取 worker 会话最后一个工具调用的标题）。"""
    if not w:
        return None
    w = dict(w)
    if w["status"] == "running" and w.get("task_id"):
        conn = get_db_connection()
        try:
            r = conn.execute("SELECT payload FROM task_events WHERE task_id = ? AND event_type = 'tool_call' ORDER BY id DESC LIMIT 1",
                             (w["task_id"],)).fetchone()
            steps = conn.execute("SELECT COUNT(*) FROM task_events WHERE task_id = ? AND event_type = 'tool_call'", (w["task_id"],)).fetchone()[0]
        finally:
            conn.close()
        try:
            d = json.loads(r[0]) if r else {}
            a = d.get("arguments") if isinstance(d.get("arguments"), dict) else {}
            w["last_step"] = a.get("title") or d.get("tool") or w.get("last_step")
        except Exception:
            pass
        w["steps"] = steps
    w.update(worker_status_extras(w))
    w.pop("context", None)
    return w

def worker_status_extras(w):
    """底部状态行用：这一刻在做什么（一句短语）、预计剩余（只在有真实历史数据时）、是否在等用户决定。"""
    conn = get_db_connection()
    try:
        steps = []
        if w.get("task_id"):
            rows = conn.execute("SELECT event_type, payload FROM task_events WHERE task_id = ? AND event_type IN ('tool_call', 'tool_result') "
                                "ORDER BY id DESC LIMIT 40", (w["task_id"],)).fetchall()
            done_ids = set()
            for et, pl in reversed(rows):
                try:
                    d = json.loads(pl)
                except (ValueError, TypeError):
                    continue
                if et == "tool_result":
                    done_ids.add(d.get("id"))
                else:
                    steps.append([d.get("tool"), d.get("arguments") if isinstance(d.get("arguments"), dict) else {}, d.get("id")])
            steps = [(t, a, i in done_ids) for t, a, i in steps]
        out = {"status_phrase": cloud_reply.status_phrase(w["status"], steps),
               "needs_decision": cloud_reply.decision_needed(conn, w.get("task_id")) if w["status"] == "running" else False}
        if out["needs_decision"]:
            out["status_phrase"] = "等你决定"
        if w["status"] == "running":
            eta = cloud_reply.eta_seconds(cloud_reply.recent_durations(conn, w.get("bot_id")), w.get("elapsed_s") or 0)
            if eta is not None:
                out["eta_s"] = eta
        return out
    except Exception as e:
        print(f"worker status extras failed: {type(e).__name__}", flush=True)
        return {}
    finally:
        conn.close()

def reply_plan(session_id, model):
    """这个对话这一轮的回复方式（秒回 / 详细）和前台、后台模型。"""
    conn = get_db_connection()
    try:
        return cloud_reply.resolve(conn, session_persona_id(session_id), session_id, model, resource_settings().get("fast_model") or None)
    finally:
        conn.close()

def session_reply_view(conn, sid, bot_id):
    plan = cloud_reply.resolve(conn, bot_id, sid, (get_persona(bot_id) or {}).get("model") if bot_id else None,
                               resource_settings().get("fast_model") or None)
    return {k: plan[k] for k in ("mode", "source", "bot_mode", "override", "front_model", "back_model")}

REPLY_BACK_MODEL = {}        # task_id -> 秒回前台这一轮派出去的后台任务用的模型
INSTANT_HANDED = set()       # 已经为这个前台任务自动 spawn_task 过（模型没照提示、直接调了干活的工具）
INSTANT_HANDOFF_LOCK = threading.Lock()


def instant_auto_handoff(task_id, session_id, fn_name, goal, model, provider_config):
    """秒回前台误调用了干活的工具：不在前台执行，把用户原要求自动 spawn_task 给后台（每个前台任务只派一次）。

    前台常用快模型，经常不理会「你没有这些工具、请用 spawn_task」。只回一句错误的话，后台不会启动，
    截图回灌、命令、文件这些活也就丢了。这里补上这一步。"""
    goal_text = (goal or "").strip()
    if not goal_text:
        return {"error": "秒回模式下前台不直接干活：先回用户一句，再用 spawn_task 把这件事交给后台。"}
    with INSTANT_HANDOFF_LOCK:
        already = task_id in INSTANT_HANDED
        if not already:
            INSTANT_HANDED.add(task_id)
    if already:
        return {"error": "秒回模式下前台不直接干活：这件事已经交给后台，请用 task_status 查看进度，或用 task_message 补充要求。"}
    res = tool_worker(task_id, session_id, "spawn_task",
                      {"goal": goal_text, "context": f"前台刚才调用了 {fn_name}，已改为交给后台继续完成。"},
                      model, provider_config)
    if not (isinstance(res, dict) and res.get("id")):
        with INSTANT_HANDOFF_LOCK:
            INSTANT_HANDED.discard(task_id)
        return res if isinstance(res, dict) else {"error": "秒回模式下前台不直接干活：请用 spawn_task 把这件事交给后台。"}
    res["note"] = "秒回前台不能直接调用 " + fn_name + "，已改为 spawn_task 交给后台。" + (res.get("note") or "")
    return res


def _worker_launch(wid):
    """名额够就开跑（同一 Bot 最多 SOFT_CAP 个），不够就留在队列里，等前面的任务结束再开。返回是否开跑。"""
    with WORKER_LOCK:
        conn = get_db_connection()
        try:
            w = cloud_workers.get(conn, wid)
            if not w or w["status"] != "queued" or cloud_workers.running_count(conn, w["bot_id"]) >= cloud_workers.SOFT_CAP:
                return False
            runtime = WORKER_RUNTIME.get(wid)
            if not runtime:
                return False
            model, provider, note = runtime
            tid = "task_" + uuid.uuid4().hex[:12]
            now = time.time()
            conn.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, NULL, 'running', ?, ?)",
                         (tid, w["worker_session"], model, now))
            has_user = conn.execute("SELECT 1 FROM messages WHERE session_id = ? AND role = 'user'", (w["worker_session"],)).fetchone()
            prompt = cloud_workers.worker_prompt(w) if not has_user else "继续完成这个任务（上次没做完）。" + ("\n补充：" + note if note else "")
            conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)", (w["worker_session"], prompt, now))
            conn.commit()
            cloud_workers.set_status(conn, wid, "running", task_id=tid, started_at=now, finished_at=None)
        finally:
            conn.close()
    with active_tasks_lock:
        active_tasks[tid] = {"process": None, "cancelled": False, "pid": None}
    threading.Thread(target=_worker_run, args=(wid, tid, w["worker_session"], prompt, model, provider), daemon=True).start()
    return True

def _worker_run(wid, tid, sid, prompt, model, provider):
    started = time.time()
    try:
        run_agent_task(tid, sid, prompt, model, provider, WORKER_INSTRUCTIONS)
    except Exception as e:
        print(f"worker {wid} crashed: {type(e).__name__}", flush=True)
    finally:
        _worker_finish(wid, tid, started)

def _worker_finish(wid, tid, started):
    conn = get_db_connection()
    try:
        st = (conn.execute("SELECT status FROM tasks WHERE task_id = ?", (tid,)).fetchone() or ["failed"])[0]
        status = st if st in ("completed", "failed", "cancelled", "limit_reached", "interrupted") else "failed"
        w = cloud_workers.get(conn, wid)
        if w and w["status"] == "running":
            result = cloud_workers.last_answer(conn, w["worker_session"], started) if status != "cancelled" else None
            cloud_workers.set_status(conn, wid, status, result=result, finished_at=time.time())
            w = cloud_workers.get(conn, wid)
            _worker_post(conn, w)
        bot_id = w["bot_id"] if w else None
        queued = [r[0] for r in conn.execute("SELECT worker_id FROM bot_workers WHERE COALESCE(bot_id, '') = ? AND status = 'queued' "
                                             "ORDER BY created_at", (bot_id or "",)).fetchall()]
    finally:
        conn.close()
    for q in queued:
        if not _worker_launch(q):
            break
    WORKER_RUNTIME.pop(wid, None)

def _worker_post(_conn, w):
    """结果作为 Bot 的消息发回前台（台账去重：只发一次），并走通知路由。前台正在回话时等它说完再写，不插在工具调用中间（另开线程等）。"""
    threading.Thread(target=_worker_post_wait, args=(w,), daemon=True).start()

def _worker_post_wait(w):
    deadline = time.time() + 600
    while True:
        conn = get_db_connection()
        try:
            busy = conn.execute("SELECT 1 FROM tasks WHERE session_id = ? AND status IN ('running', 'waiting_user')", (w["front_session"],)).fetchone()
            if not busy or time.time() > deadline:
                posted = cloud_workers.post_result(conn, w)
                break
        finally:
            conn.close()
        time.sleep(0.5)
    if posted:
        try:
            user_notify(current_notify_config(), "task_completed", f"后台任务：{w['title']}"[:120],
                        cloud_workers.result_text(w)[:600], session_id=w["front_session"])
        except Exception as e:
            print(f"worker notify failed: {type(e).__name__}", flush=True)

def worker_stop(wid):
    conn = get_db_connection()
    try:
        w = cloud_workers.get(conn, wid)
        if not w:
            return None
        if w["status"] == "queued":
            cloud_workers.set_status(conn, wid, "cancelled", finished_at=time.time())
            _worker_post(conn, cloud_workers.get(conn, wid))
        elif w["status"] == "running" and w.get("task_id"):
            set_task_cancelled(w["task_id"])
            conn.execute("UPDATE tasks SET status = 'cancelled' WHERE task_id = ? AND status IN ('running', 'waiting_user')", (w["task_id"],))
            conn.commit()
            log_event(w["task_id"], "cancelled", {"message": "后台任务已停止"})
        return cloud_workers.get(conn, wid)
    finally:
        conn.close()

def worker_message(wid, text):
    conn = get_db_connection()
    try:
        w = cloud_workers.get(conn, wid)
        if not w:
            return 404, {"error": "没有这个后台任务"}
        if not isinstance(text, str) or not text.strip():
            return 400, {"error": "text 不能为空"}
        if w["status"] == "queued":
            ctx = ((w.get("context") or "") + "\n用户补充：" + text.strip())[:20000]
            conn.execute("UPDATE bot_workers SET context = ? WHERE worker_id = ?", (ctx, wid))
            conn.commit()
            return 200, {"worker_id": wid, "delivered": "queued_context"}
    finally:
        conn.close()
    if w["status"] != "running" or not w.get("task_id"):
        return 409, {"error": f"任务已经{w['status']}，要继续请用 task_resume", "status": w["status"]}
    code, res = inbox_push(w["task_id"], text.strip(), "wkmsg_" + uuid.uuid4().hex[:10])
    if code >= 300:
        return code, res
    return 200, {"worker_id": wid, "delivered": "running"}

def user_tz():
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT value FROM app_settings WHERE name = 'timezone'").fetchone()
    except Exception:
        row = None
    finally:
        conn.close()
    return (row[0] if row and row[0] else None) or "UTC"

def _parse_at(at, tz):
    """once.at：UNIX 秒，或用户时区里的 ISO 时间（带时区偏移的按偏移）。"""
    if isinstance(at, (int, float)) and not isinstance(at, bool):
        return float(at)
    if not isinstance(at, str):
        raise ValueError("once.at 必须是时间")
    from datetime import datetime
    from zoneinfo import ZoneInfo
    try:
        dt = datetime.fromisoformat(at.strip().replace("Z", "+00:00"))
    except ValueError:
        raise ValueError("once.at 格式应为 2026-11-11T08:00")
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=ZoneInfo(tz))
    return dt.timestamp()

QUICK_ACK_DELAY = float(os.environ.get("OPENMINIS_QUICK_ACK_DELAY", "1.5"))
QUICK_ACK_PROMPT = ("你是 {name}。用户刚发来一条消息，你马上要去处理。先用一句不超过 20 个字的话回应（确认收到、说明马上去做），"
                    "不要回答具体内容，不要客套，不要用引号。{lang}")
TURN_LOCK = threading.Lock()

def _quick_ack(task_id, session_id, user_text, fast_model, chat_url, api_key, perf):
    time.sleep(QUICK_ACK_DELAY)
    if perf.get("first_text_ms") is not None or perf.get("tools") or is_task_cancelled(task_id):
        return
    bot = session_bot(session_id) or {}
    lang = (bot.get("soul") or {}).get("language") if isinstance(bot.get("soul"), dict) else None
    sys_text = QUICK_ACK_PROMPT.format(name=bot.get("name") or "助手", lang=f"用「{lang}」回复。" if lang else "用用户的语言回复。")
    text = user_text if isinstance(user_text, str) else json.dumps(user_text, ensure_ascii=False)
    try:
        resp, _t = cloud_llm.chat_completion(chat_url, {"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
                                             {"model": fast_model, "messages": [{"role": "system", "content": sys_text},
                                                                                {"role": "user", "content": text[:2000]}],
                                              "max_tokens": 60, "temperature": 0.3}, stream=False, timeout=6)
        ack = (((resp.get("choices") or [{}])[0].get("message") or {}).get("content") or "").strip().strip("\"「」")[:80]
    except Exception as e:
        print(f"quick ack failed: {type(e).__name__}", flush=True)
        return
    if not ack:
        return
    with TURN_LOCK:
        tf = TURN_FLAGS.setdefault(task_id, {})
        if tf.get("spoke") or perf.get("first_text_ms") is not None:
            return
        tf["ack"] = ack
    log_event(task_id, "thought", {"content": ack, "ack": True})
    perf["quick_ack_ms"] = round((time.time() - perf["created_at"]) * 1000, 1)

def _take_ack(task_id, content, tool_calls):
    """模型这一轮的输出写库前调用：还没给出的快速确认并进第一条工具调用消息（不打乱 tool_calls / tool 的顺序）；模型自己已经说话了就丢掉。"""
    with TURN_LOCK:
        tf = TURN_FLAGS.setdefault(task_id, {})
        tf["spoke"] = True
        ack = tf.pop("ack", None)
    if ack and not content and tool_calls:
        return ack
    return content

def _flush_ack(task_id, session_id):
    """任务结束时快速确认还没并进任何消息（比如出错了）：单独写一条。"""
    with TURN_LOCK:
        ack = (TURN_FLAGS.get(task_id) or {}).pop("ack", None)
    if ack:
        insert_message(session_id, "assistant", ack, meta={"ack": True})

def _turn_meta(task_id, meta):
    """最终回复上挂本轮写的页面（App 显示页面卡片）。"""
    pages = (TURN_FLAGS.get(task_id) or {}).pop("pages", None)
    if not pages:
        return meta
    meta = dict(meta or {})
    meta["page"] = pages[-1]
    return meta

def _post_turn_card(task_id, session_id):
    """把选项卡作为 Bot 的一条消息写进对话（内容是问题本身，模型下一轮也看得到问的是什么）。"""
    tf = TURN_FLAGS.get(task_id) or {}
    choice = tf.pop("choice", None)
    tf.pop("end", None)
    if not choice:
        return
    meta = _turn_meta(task_id, {"choice": choice})
    text = choice["question"] + "\n" + "\n".join(f"{o['id']}. {o['label']}" for o in choice["options"])
    insert_message(session_id, "assistant", text, meta=meta)

def tool_runmodel(task_id, session_id, name, args, model, provider_config, depth):
    args = args if isinstance(args, dict) else {}
    flags = TURN_FLAGS.setdefault(task_id, {})
    conn = get_db_connection()
    try:
        if name == "react":
            mid = args.get("message_id") or cloud_runmodel.last_user_message_id(conn, session_id)
            if not mid:
                return {"error": "没有可以回应的消息"}
            try:
                r = cloud_runmodel.set_reaction(conn, session_id, int(mid), "bot", args.get("emoji"))
            except (cloud_runmodel.RunModelError, ValueError) as e:
                return {"error": str(e)}
            flags["answered"] = True
            log_event(task_id, "reaction", {"message_id": int(mid), "emoji": args.get("emoji")})
            return {"reacted": True, "reactions": r, "note": "已回应。如果表情已经够了，本轮不用再写字。"}
        if name == "ask_choice":
            try:
                choice = cloud_runmodel.validate_choice(args)
            except cloud_runmodel.RunModelError as e:
                return {"error": str(e)}
            flags.update(answered=True, end=True, choice=choice)
            log_event(task_id, "choice", choice)
            return {"shown": True, "note": "选项卡已显示给用户，本轮到此结束，等用户点选。"}
        if name == "report_progress":
            w = cloud_workers.by_session(conn, session_id)
            if not w:
                return {"error": "只有后台任务能发里程碑；前台直接回复用户"}
            text = args.get("text")
            if not isinstance(text, str) or not text.strip():
                return {"error": "text 不能为空"}
            n = conn.execute("SELECT COUNT(*) FROM messages WHERE session_id = ? AND meta LIKE ?",
                             (w["front_session"], f'%"milestone": "{w["worker_id"]}"%')).fetchone()[0]
            cloud_workers.set_status(conn, w["worker_id"], w["status"], last_step=text.strip()[:200])
            if n >= cloud_runmodel.MILESTONE_MAX:
                return {"posted": False, "note": "里程碑已经发够了，专心做完，最后给结果"}
            conn.execute("INSERT INTO messages (session_id, role, content, timestamp, meta) VALUES (?, 'assistant', ?, ?, ?)",
                         (w["front_session"], f"⏳ {w['title']}：{text.strip()[:300]}", time.time(),
                          json.dumps({"milestone": w["worker_id"]}, ensure_ascii=False)))
            conn.commit()
            return {"posted": True}
    finally:
        conn.close()
    bot_id = session_persona_id(session_id)
    if name == "routine_list":
        return {"routines": [{"id": r["routine_id"], "name": r["name"], "schedule": r["schedule"], "enabled": r["enabled"],
                              "next_run_at": r.get("next_run_at"), "run_count": r.get("run_count")}
                             for r in list_routines() if (r.get("persona_id") or None) == (bot_id or None)]}
    if name == "routine_delete":
        r = get_routine(args.get("id")) if isinstance(args.get("id"), str) else None
        if not r or (r.get("persona_id") or None) != (bot_id or None):
            return {"error": "这个 Bot 没有这个例行任务"}
        if args.get("enabled") is False:
            update_routine(r["routine_id"], {"enabled": False})
            return {"id": r["routine_id"], "paused": True}
        conn = get_db_connection()
        try:
            conn.execute("DELETE FROM routines WHERE routine_id = ?", (r["routine_id"],))
            conn.commit()
        finally:
            conn.close()
        audit(session_id, "routine_delete", r["routine_id"], "删除例行任务：" + r["name"])
        return {"id": r["routine_id"], "deleted": True}
    if name == "routine_create":
        bot = get_persona(bot_id) if bot_id else None
        cred = (bot or {}).get("credential") or (provider_config or {}).get("credential")
        if not cred:
            return {"error": "需要已保存的模型凭据才能定时运行：请在 App 里给这个 Bot 选一个保存的服务商"}
        sch = args.get("schedule") if isinstance(args.get("schedule"), dict) else {}
        sch = dict(sch)
        tz = user_tz()
        try:
            if sch.get("kind") == "cron":
                sch.setdefault("timezone", tz)
            if sch.get("kind") == "once":
                sch["at"] = _parse_at(sch.get("at"), tz)
                if sch["at"] < time.time() - 60:
                    return {"error": "提醒时间已经过了"}
            prompt = args.get("prompt")
            if args.get("monitor") and isinstance(prompt, str):
                prompt += "\n\n（监控：和上次相比没有值得告诉用户的变化时，只回复 [SKIP]。）"
            fields = validate_routine_fields({"name": args.get("name"), "prompt": prompt, "schedule": sch,
                                              "model": (bot or {}).get("model") or model, "credential": cred,
                                              "persona_id": bot_id, "max_runs": args.get("max_runs") or (1 if sch.get("kind") == "once" else None)})
        except ValueError as e:
            return {"error": str(e)}
        r = create_routine(fields)
        audit(session_id, "routine_create", r["routine_id"], "新建例行任务：" + r["name"])
        return {"id": r["routine_id"], "name": r["name"], "schedule": r["schedule"], "next_run_at": r.get("next_run_at"),
                "timezone": tz, "note": "已创建。回复里用一句话告诉用户什么时候会运行。"}
    return {"error": "unknown tool"}

def tool_worker(task_id, session_id, name, args, model, provider_config):
    args = args if isinstance(args, dict) else {}
    if name == "spawn_task":
        conn = get_db_connection()
        try:
            try:
                w = cloud_workers.create(conn, session_persona_id(session_id), session_id, args.get("goal"), args.get("context"), args.get("title"))
            except cloud_workers.WorkerError as e:
                return {"error": str(e)}
        finally:
            conn.close()
        WORKER_RUNTIME[w["worker_id"]] = (model, provider_config, "")
        started = _worker_launch(w["worker_id"])
        log_event(task_id, "worker_spawned", {"worker_id": w["worker_id"], "title": w["title"], "status": "running" if started else "queued"})
        return {"id": w["worker_id"], "title": w["title"], "status": "running" if started else "queued",
                "note": "已在后台开始。现在只回用户一句简短确认，结果做完会自动发到这个对话。"}
    wid = args.get("id")
    conn = get_db_connection()
    try:
        if name == "task_status" and not wid:
            return {"tasks": [worker_view(w) for w in cloud_workers.list_for(conn, front_session=session_id, limit=10)]}
        w = cloud_workers.get(conn, wid)
    finally:
        conn.close()
    if not w or w["front_session"] != session_id:
        return {"error": "这个对话里没有这个后台任务"}
    if name == "task_status":
        return worker_view(w)
    if name == "task_message":
        code, res = worker_message(wid, args.get("text"))
        return res if code < 300 else {"error": res.get("error"), "status": res.get("status")}
    if name == "task_stop":
        return {"id": wid, "status": (worker_view(worker_stop(wid)) or {}).get("status")}
    if name == "task_resume":
        if w["status"] in cloud_workers.ACTIVE:
            return {"error": "任务还在进行，不需要继续", "status": w["status"]}
        conn = get_db_connection()
        try:
            note = args.get("note") if isinstance(args.get("note"), str) else ""
            conn.execute("UPDATE bot_workers SET status = 'queued', reported = 0, result = NULL, finished_at = NULL WHERE worker_id = ?", (wid,))
            conn.commit()
        finally:
            conn.close()
        WORKER_RUNTIME[wid] = (model, provider_config, note)
        started = _worker_launch(wid)
        return {"id": wid, "status": "running" if started else "queued"}
    return {"error": "unknown tool"}

def _handoff_session(bot_id, title):
    """交接进 Bot 那条连续对话（空闲时）；它正忙就另开一个会话，免得插进正在做的事。"""
    conn = get_db_connection()
    try:
        r = conn.execute("SELECT s.session_id FROM sessions s WHERE s.persona_id = ? AND s.title NOT LIKE '例行任务：%' "
                         "AND s.session_id NOT IN (SELECT worker_session FROM bot_workers) "
                         "AND s.session_id NOT IN (SELECT to_session FROM bot_delegations) ORDER BY s.created_at DESC LIMIT 1",
                         (bot_id,)).fetchone()
        sid = r[0] if r else None
        if sid and conn.execute("SELECT 1 FROM tasks WHERE session_id = ? AND status IN ('running', 'waiting_user')", (sid,)).fetchone():
            sid = None
        if not sid:
            sid = "sess_" + uuid.uuid4().hex[:12]
            conn.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, NULL, ?, '', ?, ?)",
                         (sid, title, time.time(), bot_id))
            conn.commit()
        return sid
    finally:
        conn.close()

def start_handoff(req):
    """本地模式交接：打包的上下文和文件交给指定 Bot；没指定就交给主 Bot 分派。返回会话 / 任务 / Bot。"""
    fields, files = cloud_handoff.clean(req)
    target_id = req.get("target_bot")
    routed = not target_id
    if routed:
        target_id = primary_bot_id()
        if not target_id:
            raise cloud_handoff.HandoffError("还没有主 Bot，请先在 Bot 模式里设置一个主 Bot")
    bot = get_persona(target_id)
    if not bot:
        raise cloud_handoff.HandoffError(f"没有这个 Bot：{target_id}")
    if bot.get("model") and bot.get("credential"):
        run_model = bot["model"]
        provider, _st, err = resolve_provider({"protocol": "chat", "credential": bot["credential"]})
    else:
        run_model = req.get("model") if isinstance(req.get("model"), str) and req.get("model") else None
        provider, _st, err = resolve_provider(req.get("provider") or {})
    if err or not provider or not run_model:
        raise cloud_handoff.HandoffError(f"{bot.get('name') or target_id} 没有可用的模型：{err or '请在 Bot 设置里选模型'}")
    sid = _handoff_session(target_id, "本地交接：" + (fields.get("goal") or fields.get("summary") or "")[:40])
    saved = []
    for f in files:
        try:
            data = base64.b64decode(f["data_base64"], validate=True)
        except (ValueError, TypeError):
            raise cloud_handoff.HandoffError(f"文件 {f['filename']} 不是合法的 base64")
        if len(data) > cloud_handoff.MAX_FILE_BYTES:
            raise cloud_handoff.HandoffError(f"文件 {f['filename']} 超过 20 MB")
        saved.append(save_upload(sid, f["filename"], data)["file_path"])
    content = cloud_handoff.compose(fields, saved, routed, redact=cloud_vault.redact)
    now = time.time()
    tid = "task_" + uuid.uuid4().hex[:12]
    conn = get_db_connection()
    try:
        conn.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, NULL, 'running', ?, ?)",
                     (tid, sid, run_model, now))
        conn.execute("INSERT INTO messages (session_id, role, content, timestamp, meta) VALUES (?, 'user', ?, ?, ?)",
                     (sid, content, now, json.dumps({"handoff": {"from": "local", "routed": routed}}, ensure_ascii=False)))
        conn.commit()
    finally:
        conn.close()
    with active_tasks_lock:
        active_tasks[tid] = {"process": None, "cancelled": False, "pid": None}
    log_event(tid, "status", {"message": "已从本地模式接手" + ("（主 Bot 分派）" if routed else "")})
    threading.Thread(target=run_agent_task, args=(tid, sid, content, run_model, provider, ""), daemon=True, name="handoff").start()
    return {"session_id": sid, "task_id": tid, "bot_id": target_id, "bot_name": bot.get("name") or target_id,
            "routed": routed, "files": saved}

def start_delegation(task_id, session_id, kind, target_id, body, priority="normal", report_back=True,
                     model=None, provider_config=None, waiting=False):
    """创建并启动一次 Bot 间消息 / 委托；返回 (delegation_id, worker 线程) 或抛 deleg.LimitError / ValueError。"""
    own = session_persona_id(session_id)
    if not isinstance(target_id, str) or not target_id:
        raise ValueError("bot_id 必须是字符串")
    if target_id == own:
        raise ValueError("不能委托给自己；需要分身处理请用 subagent_task")
    target = get_persona(target_id)
    if not target:
        raise ValueError(f"没有这个 Bot：{target_id}")
    if not isinstance(body, str) or not body.strip():
        raise ValueError("内容不能为空")
    if priority not in ("normal", "high"):
        raise ValueError("priority 只能是 normal 或 high")
    rs = resource_settings()
    hop = TASK_HOP.get(task_id, 0) + 1
    deleg.check_hop(hop, rs.get("delegation_max_hops", 3))
    DELEG_LIMITER.check_and_add(own or "", target_id, rs.get("delegation_pair_per_10min", 10))
    src = session_bot(session_id)
    did = "dlg_" + uuid.uuid4().hex[:12]
    content = deleg.incoming_text(_bot_label(src), kind, body[:20000], did, report_back)
    if target.get("model") and target.get("credential"):
        run_model = target["model"]
        provider, p_status, p_err = resolve_provider({"protocol": "chat", "credential": target["credential"]})
        if p_err:
            raise ValueError(f"{target['name']} 的模型凭据不可用：{p_err}")
    else:
        run_model, provider = model, provider_config
    if not provider:
        raise ValueError("没有可用的模型凭据")
    now = time.time()
    tid = "task_" + uuid.uuid4().hex[:12]
    conn = get_db_connection()
    try:
        c = conn.cursor()
        sid = None
        if kind == "message":
            # 普通消息进目标 Bot 最近的空闲会话，没有就新开
            r = c.execute("SELECT s.session_id FROM sessions s WHERE s.persona_id = ? AND NOT EXISTS (SELECT 1 FROM tasks t WHERE t.session_id = s.session_id "
                          "AND t.status IN ('running', 'waiting_user')) AND s.title NOT LIKE '例行任务：%' "
                          "AND s.session_id NOT IN (SELECT worker_session FROM bot_workers) ORDER BY s.created_at DESC LIMIT 1", (target_id,)).fetchone()
            sid = r[0] if r else None
        if not sid:
            sid = "sess_" + uuid.uuid4().hex[:12]
            title = f"来自 {_bot_label(src)}：" + body.strip().splitlines()[0][:40]
            c.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, NULL, ?, '', ?, ?)",
                      (sid, title, now, target_id))
        c.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, NULL, 'running', ?, ?)",
                  (tid, sid, run_model, now))
        c.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)", (sid, content, now))
        root = (c.execute("SELECT root_id FROM bot_delegations WHERE to_task = ?", (task_id,)).fetchone() or [did])[0]
        c.execute("INSERT INTO bot_delegations (delegation_id, kind, from_bot, to_bot, from_session, from_task, to_session, to_task, content, priority, "
                  "report_back, hop, root_id, status, result, reported, created_at, finished_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?, 'running', NULL, 0, ?, NULL)",
                  (did, kind, own or "", target_id, session_id, task_id, sid, tid, body[:20000], priority, 1 if report_back else 0, hop, root, now))
        cloud_botthreads.record(conn, own or "", target_id, cloud_vault.redact(body), kind, did, priority, "running", tid, sid, now)
        conn.commit()
    finally:
        conn.close()
    with active_tasks_lock:
        active_tasks[tid] = {"process": None, "cancelled": False, "pid": None, "parent": task_id}
    TASK_HOP[tid] = hop
    if priority == "high":
        TASK_PRIORITY[tid] = "high"
    log_event(task_id, "delegation_started", {"delegation_id": did, "kind": kind, "to_bot": target_id, "to_name": target["name"],
                                              "session_id": sid, "task_id": tid, "message": f"已交给 {target['name']}"})
    log_event(tid, "delegated_from", {"delegation_id": did, "from_bot": own or "", "from_name": _bot_label(src)})

    def worker():
        try:
            run_agent_task(tid, sid, content, run_model, provider, "")
        finally:
            TASK_HOP.pop(tid, None)
            TASK_PRIORITY.pop(tid, None)
            conn2 = get_db_connection()
            try:
                status = (conn2.execute("SELECT status FROM tasks WHERE task_id = ?", (tid,)).fetchone() or ["failed"])[0]
                last = conn2.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'assistant' AND content IS NOT NULL AND timestamp >= ? "
                                     "ORDER BY id DESC LIMIT 1", (sid, now)).fetchone()
                result = ((last[0] if last else "") or "")[:20000]
                conn2.execute("UPDATE bot_delegations SET status = ?, result = ?, finished_at = ? WHERE delegation_id = ?",
                              (status, result, time.time(), did))
                cloud_botthreads.set_status(conn2, did, status)
                if kind == "task":
                    cloud_botthreads.record(conn2, target_id, own or "", cloud_vault.redact(result or ""), "result", did, priority, status, tid, sid)
                conn2.commit()
            finally:
                conn2.close()
            log_event(task_id, "delegation_finished", {"delegation_id": did, "to_name": target["name"], "status": status})
            DELEG_THREADS.pop(did, None)
            with DELEG_LOCK:
                deferred = did in DELEG_WAITING
            if report_back and kind == "task" and not deferred:
                _report_delegation(did)

    th = threading.Thread(target=worker, daemon=True, name="bot-delegation")
    DELEG_THREADS[did] = th
    if waiting:
        with DELEG_LOCK:
            DELEG_WAITING.add(did)
    th.start()
    return did, th

def _claim_report(did):
    """回报只做一次：谁先把 reported 从 0 改成 1 谁负责交付结果。"""
    conn = get_db_connection()
    try:
        cur = conn.execute("UPDATE bot_delegations SET reported = 1 WHERE delegation_id = ? AND reported = 0", (did,))
        conn.commit()
        return cur.rowcount == 1
    finally:
        conn.close()

def _report_delegation(did):
    """结果交回请求方：请求方还在等（wait）时由工具直接返回；否则写进请求方会话并推送。只回报一次。"""
    if not _claim_report(did):
        return
    row = _delegation_row(did)
    target = get_persona(row["to_bot"]) or {}
    text = deleg.result_text(_bot_label(target), row["status"], row["result"])
    _post_when_idle(row["from_session"], text)
    cfg = current_notify_config()
    if not _bot_muted(row["from_session"]):
        user_notify(cfg, "task_completed", f"{_bot_label(target)} 完成了委托"[:120], (row["result"] or "")[:600], session_id=row["from_session"])

def tool_send_to_bot(task_id, session_id, args, model, provider_config):
    try:
        did, _ = start_delegation(task_id, session_id, "message", args.get("bot_id"), args.get("message"),
                                  args.get("priority") or "normal", report_back=False, model=model, provider_config=provider_config)
    except (deleg.LimitError, ValueError) as e:
        return {"error": str(e)}
    return {"status": "sent", "delegation_id": did, "note": "对方会在自己的对话里处理；需要结果请用 delegate_task"}

def tool_delegate_task(task_id, session_id, args, model, provider_config):
    report_back = args.get("report_back", True) is not False
    wait = args.get("wait", True) is not False
    try:
        wait_s = int(args.get("wait_seconds") or DELEG_WAIT_DEFAULT)
    except (TypeError, ValueError):
        wait_s = DELEG_WAIT_DEFAULT
    wait_s = max(5, min(wait_s, 1800))
    try:
        did, th = start_delegation(task_id, session_id, "task", args.get("bot_id"), args.get("task"),
                                   args.get("priority") or "normal", report_back=report_back, model=model,
                                   provider_config=provider_config, waiting=wait)
    except (deleg.LimitError, ValueError) as e:
        return {"error": str(e)}
    if not wait:
        return {"status": "running", "delegation_id": did, "note": "完成后结果会自动发回这个对话" if report_back else "已交出，不回报"}
    GATE.park(task_id)
    try:
        deadline = time.time() + wait_s
        while th.is_alive() and time.time() < deadline and not is_task_cancelled(task_id):
            th.join(timeout=0.5)
    finally:
        GATE.unpark(task_id)
        with DELEG_LOCK:
            DELEG_WAITING.discard(did)
    row = _delegation_row(did)
    if row["status"] == "running":
        return {"status": "running", "delegation_id": did,
                "note": f"等了 {wait_s} 秒还没完成，" + ("结果会自动发回这个对话" if report_back else "对方会继续做完")}
    if not _claim_report(did):
        return {"status": row["status"], "delegation_id": did, "note": "结果已经发到这个对话里"}
    out = {"status": row["status"], "delegation_id": did, "bot": row["to_bot"], "result": row["result"] or ""}
    if row["status"] != "completed":
        out["error"] = f"对方任务结束状态：{row['status']}"
    return out

# ---------------- 群聊 ----------------
GROUP_FALLBACK = {}      # group_id -> (model, provider)：成员 Bot 没选自己的模型时用用户当前的模型

def _bot_provider(bot, fallback):
    if bot.get("model") and bot.get("credential"):
        provider, _st, err = resolve_provider({"protocol": "chat", "credential": bot["credential"]})
        if err:
            raise RuntimeError(f"凭据不可用：{err}")
        return bot["model"], provider
    if fallback and fallback[1]:
        return fallback
    raise RuntimeError("没有可用的模型：请给这个 Bot 选一个模型，或在手机上选好默认模型")

USAGE_CAP = cloud_usage.CapState()
SEARCH_CACHE = eff.TTLCache(ttl=15.0)      # 首页搜索：同一关键词 15 秒内直接返回；任务结束 / 新消息时失效

def auto_title(session_id, provider_config, model):
    """第一轮回答后给对话起短标题：设置了 fast_model 就用同一服务商的小模型，否则截取用户首句；用户改过的标题不动。"""
    rs = resource_settings()
    if not rs.get("auto_title", True):
        return
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT title FROM sessions WHERE session_id = ?", (session_id,)).fetchone()
        if not row or not eff.is_default_title(row[0]):
            return
        users = conn.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'user' ORDER BY id LIMIT 3", (session_id,)).fetchall()
        answer = conn.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'assistant' AND content IS NOT NULL AND content != '' "
                              "ORDER BY id LIMIT 1", (session_id,)).fetchone()
    finally:
        conn.close()
    if not users or len(users) > 2:
        return
    first = users[0][0] or ""
    title = ""
    fast = rs.get("fast_model") or ""
    if fast and provider_config and provider_config.get("api_key"):
        try:
            url = f"{provider_config.get('base_url', 'https://api.openai.com/v1').rstrip('/')}/chat/completions"
            resp, _t = cloud_llm.chat_completion(url, {"Content-Type": "application/json", "Authorization": f"Bearer {provider_config['api_key']}"},
                                                 {"model": fast, "messages": eff.title_prompt(first, answer[0] if answer else ""),
                                                  "max_tokens": 30, "temperature": 0.3}, stream=False, timeout=20)
            title = eff.clean_model_title(((resp.get("choices") or [{}])[0].get("message") or {}).get("content"))
        except Exception as e:
            print(f"auto title via fast model failed: {type(e).__name__}", flush=True)
    title = title or eff.heuristic_title(first)
    if not title:
        return
    conn = get_db_connection()
    try:
        conn.execute("UPDATE sessions SET title = ? WHERE session_id = ?", (title[:80], session_id))
        conn.commit()
    finally:
        conn.close()

# ---------------- 提速：流式、连接复用、快速模式、性能记录 ----------------
PARALLEL_SAFE_TOOLS = {"file_read", "memory_search", "skill_load", "list_bots", "background_jobs", "request_tools"}
INCOGNITO_NOTE = "\n[无痕对话] 这次对话结束后会被删除：不要写入长期记忆，也不要把内容带到别的对话里。"
VISION_NOTE = ("\n\n[看图] 用户这次发的图片已经直接给你了（作为图片，或由看图模型读成的「图片内容」文字）：直接据此回答（排班表、截图等先逐字读出要用的内容）。"
               "不要用 OCR、安装工具、打开或在电脑上查看图片文件来识别；真的看不清就直接说哪里看不清。")
DUTY_NOTE = ("\n[值班模式] 用户正在值班（临床一线，随时被打断）：回答极简，先给结论、数字和要做的动作，"
             "用短句或要点，不寒暄、不铺垫；涉及剂量 / 换算时写明单位并提醒核对医嘱与说明书。")


def on_duty(rs=None):
    rs = rs or resource_settings()
    return float(rs.get("duty_until") or 0) > time.time()


_duty_lock = threading.Lock()


def _duty_record(kind, title, body, bot_id=None, session_id=None, suppressed=False):
    """值班中攒下要在下班时汇总的条目（标题和截短的正文，调用方已脱敏）；失败不影响通知本身"""
    if kind == "duty_digest" or not on_duty():
        return
    try:
        conn = get_db_connection()
        try:
            cloud_duty.record(conn, kind, scrub_text(title), scrub_text(body),
                              bot_id=bot_id, session_id=session_id, suppressed=suppressed)
            conn.commit()
        finally:
            conn.close()
    except Exception as e:
        print(f"duty record failed: {type(e).__name__}", flush=True)


_events_running = set()
_events_lock = threading.Lock()
EVENT_FETCHERS = {"github": cloud_events.http_json, "email": cloud_events.imap_fetch}


def _event_secret(tid):
    conn = get_db_connection()
    try:
        v = cloud_notify.load_setting(conn, "event:" + tid)
        return (v or {}).get("secret")
    finally:
        conn.close()


def event_fire(trig, summaries, source):
    """把事件交给绑定的例行任务：最多合并 5 条，打码截短后作为「上一步的结果」"""
    routine = get_routine(trig["routine_id"])
    if not routine or not summaries:
        return None
    ctx = scrub_text("\n\n".join(summaries[-5:]))[:4000]
    if len(summaries) > 5:
        ctx = f"（共 {len(summaries)} 条，只给最近 5 条）\n" + ctx
    return launch_routine_run(routine, "event:" + source, context=ctx)


def _event_poll(trig):
    conn = None
    try:
        secret = _event_secret(trig["id"])
        if trig["kind"] == "github":
            items, cursor = cloud_events.poll_github(trig, secret, fetch=EVENT_FETCHERS["github"])
        else:
            items, cursor = cloud_events.poll_email(trig, secret or "", fetch=EVENT_FETCHERS["email"])
        conn = get_db_connection()
        cloud_events.mark(conn, trig["id"], cursor=cursor, fired=1 if items else 0)
        conn.close()
        conn = None
        if items:
            event_fire(trig, items, trig["kind"])
        return items
    except Exception as e:
        conn = conn or get_db_connection()
        cloud_events.mark(conn, trig["id"], error=scrub_text(f"{type(e).__name__}: {e}"))
        note_server_error("event:" + trig["kind"], e)
        return None
    finally:
        if conn:
            conn.close()
        with _events_lock:
            _events_running.discard(trig["id"])


def events_check(now=None, wait=False):
    """调度器每轮调用：GitHub / 邮件触发器每 5 分钟轮询一次（后台线程，不卡调度器）"""
    now = time.time() if now is None else now
    conn = get_db_connection()
    try:
        due = [t for t in cloud_events.list_all(conn) if t["enabled"] and t["kind"] in ("github", "email")
               and now - t["last_poll"] >= cloud_events.POLL_SECONDS]
    finally:
        conn.close()
    results = {}
    for t in due:
        with _events_lock:
            if t["id"] in _events_running:
                continue
            _events_running.add(t["id"])
        if wait:
            results[t["id"]] = _event_poll(t)
        else:
            threading.Thread(target=_event_poll, args=(t,), name="event-poll", daemon=True).start()
    return results


def events_on_telegram(text):
    """Telegram 收到消息：包含关键词的触发对应例行任务（消息照常交给 Bot 处理）"""
    try:
        conn = get_db_connection()
        try:
            trigs = [t for t in cloud_events.list_all(conn) if t["enabled"] and t["kind"] == "telegram" and cloud_events.telegram_matches(t, text)]
            for t in trigs:
                cloud_events.mark(conn, t["id"], fired=1)
        finally:
            conn.close()
        for t in trigs:
            event_fire(t, [f"[Telegram 消息] {text[:800]}"], "telegram")
        return len(trigs)
    except Exception as e:
        note_server_error("event:telegram", e)
        return 0


_relay_watch_running = threading.Event()
RELAY_WATCH_NEEDLE = 3000


def relay_watch_config():
    return _settings_get("relay_watch") or {"credential": "", "model": "", "hours": 0, "last_run": 0, "history": []}


def _relay_watch_run(cfg, now):
    try:
        prov, _st, err = resolve_provider({"protocol": "chat", "credential": cfg["credential"]})
        if err:
            result = {"checks": [], "ok": False, "error": str(err)[:120]}
        else:
            url = f"{prov['base_url'].rstrip('/')}/chat/completions"
            headers = {"Content-Type": "application/json", "Authorization": f"Bearer {prov['api_key']}"}
            result = eff.relay_check(lambda body: cloud_llm.chat_completion(url, headers, body, stream=False, timeout=18),
                                     cfg["model"], RELAY_WATCH_NEEDLE)
        bad = [c["name"] for c in result.get("checks", []) if c.get("ok") is False]
        entry = {"at": now, "ok": bool(result.get("ok")), "failed": bad, "error": scrub_text(result.get("error") or "")}
        cur = relay_watch_config()
        prev = (cur.get("history") or [{}])[-1] if cur.get("history") else {}
        cur["history"] = (cur.get("history") or [])[-9:] + [entry]
        cur["last_run"] = now
        _settings_put("relay_watch", cur)
        # 只在变差时提醒（第一次就不合格也提醒）；一直不合格不重复刷屏
        if not entry["ok"] and (not prev or prev.get("ok") or set(prev.get("failed") or []) != set(bad)):
            why = "、".join(bad) or entry["error"] or "请求失败"
            user_notify(current_notify_config(), "relay_watch", f"中转站定期体检没通过：{cfg['model']}"[:120],
                        f"没通过的项目：{why}。可能掺水、换模型、注入提示词或截断上下文，打开「中转站体检」看详情。")
        return entry
    except Exception as e:
        print(f"relay watch failed: {type(e).__name__}", flush=True)
        return None
    finally:
        _relay_watch_running.clear()


def relay_watch_check(now=None, wait=False):
    """调度器每轮调用：到了间隔就在后台跑一次体检（只用一个小的长上下文探针，省 token）"""
    now = time.time() if now is None else now
    cfg = relay_watch_config()
    if not cfg.get("hours") or not cfg.get("credential") or not cfg.get("model"):
        return None
    if now - float(cfg.get("last_run") or 0) < float(cfg["hours"]) * 3600 or _relay_watch_running.is_set():
        return None
    _relay_watch_running.set()
    cfg["last_run"] = now           # 先占位，失败也不会每 15 秒重试
    _settings_put("relay_watch", cfg)
    if wait:
        return _relay_watch_run(cfg, now)
    threading.Thread(target=_relay_watch_run, args=(cfg, now), name="relay-watch", daemon=True).start()
    return "started"


def duty_check(now=None):
    """值班开始 / 结束检测：调度器每轮调用，改值班设置时也立即调用。下班时推一份「错过了什么」。"""
    now = time.time() if now is None else now
    with _duty_lock:
        state = _settings_get("duty_state") or {}
        new, window = cloud_duty.transition(state, resource_settings().get("duty_until"), now)
        if new != state:
            _settings_put("duty_state", new)
        if not window:
            return None
        conn = get_db_connection()
        try:
            digest = cloud_duty.finish(conn, window[0], window[1], now=now)
            conn.commit()
        finally:
            conn.close()
    user_notify(current_notify_config(), "duty_digest", "下班了：值班期间错过了什么", digest["text"])
    return digest


FAST_MODE_NOTE = "\n[快速模式] 用户希望快：直接给结论，回答尽量短；能一步完成就不要多步规划，非必要不调用工具。"
PERF = deque(maxlen=200)
_STREAM_UNSUPPORTED = set()
_CACHE_UNSUPPORTED = set()
SPILL_CHARS = 12000

def _bot_fast(session_id):
    b = session_bot(session_id)
    return bool(b and b.get("fast_mode"))

def _front_worker_note(session_id):
    """当前对话里后台任务的一行摘要。每轮现查：同一条前台任务里刚 spawn 的 worker、用户插话注入后，都要能看见。"""
    conn = get_db_connection()
    try:
        return cloud_workers.summary_note(cloud_workers.list_for(conn, front_session=session_id, limit=10))
    finally:
        conn.close()

def _append_note(msgs, note):
    """把本轮才有的提示接在最后一条用户消息后面（不改动稳定的系统提示）。"""
    out = list(msgs)
    for i in range(len(out) - 1, 0, -1):
        if out[i].get("role") == "user":
            m = dict(out[i])
            if isinstance(m.get("content"), str):
                m["content"] = m["content"] + "\n\n" + note.strip()
            elif isinstance(m.get("content"), list):
                m["content"] = m["content"] + [{"type": "text", "text": note.strip()}]
            out[i] = m
            return out
    return out

def _with_prompt_cache(body, url, cache_key=None, stream=False):
    """提示缓存：Claude / Qwen 给稳定的系统提示打 cache_control；GPT 系带 prompt_cache_key（同一 Bot 落到同一缓存）；
    DeepSeek / Gemini / GLM 等自动前缀缓存只要系统提示不变即可。流式时要求返回 usage 以统计缓存命中。
    服务商不认这些字段（400）时由 call_chat 去掉重试并记住。"""
    if (url, body.get("model")) in _CACHE_UNSUPPORTED or not resource_settings().get("prompt_cache", True):
        return body
    return eff.with_cache_hints(body, cache_key=cache_key, stream=stream)

def _err_text(e):
    """读出 HTTPError 的响应体（读完放回原位，别处还能再读），用来判断服务商拒绝的是哪个参数。"""
    try:
        fp = e.fp
        pos = fp.tell()
        text = fp.read().decode("utf-8", "replace")
        fp.seek(pos)
        return text.lower()
    except Exception:
        return ""

def call_chat(url, headers, body, effort, stream=True, on_text=None, cache_key=None, on_reasoning=None, should_abort=None):
    """主循环的模型调用：复用连接、流式；服务商不支持流式 / 思考参数 / 缓存标记时各降级一次并记住。返回 (resp, timing)。"""
    model = body.get("model")
    use_stream = bool(stream) and (url, model) not in _STREAM_UNSUPPORTED
    use_cache = True
    for _attempt in range(7):
        payload = apply_reasoning(body, model, effort, url)
        cached = _with_prompt_cache(payload, url, cache_key=cache_key, stream=use_stream) if use_cache else payload
        try:
            return cloud_llm.chat_completion(url, headers, cached, stream=use_stream, on_text=on_text,
                                             on_reasoning=on_reasoning, should_abort=should_abort)
        except urllib.error.HTTPError as e:
            if e.code not in (400, 422):
                raise
            blames_effort = payload is not body and any(k in _err_text(e) for k in ("reasoning", "thinking", "effort"))
            if cached is not payload and not blames_effort:
                use_cache = False
                _CACHE_UNSUPPORTED.add((url, model))
                continue
            if payload is not body:
                effort, _ = effort_rejected(url, model, effort)
                continue
            if (url, model) in _EFFORT_UNSUPPORTED and effort not in (None, "", "off") and not use_stream:
                _EFFORT_UNSUPPORTED.discard((url, model))   # 不带思考参数也失败：问题不在参数
                raise
            if use_stream:
                use_stream = False
                _STREAM_UNSUPPORTED.add((url, model))
                continue
            raise
    raise RuntimeError("model call failed after fallbacks")

def spill_tool_output(session_id, tc_id, text):
    """工具输出太长时：完整内容写进工作区文件，给模型头尾摘要 + 文件路径，避免撑爆上下文。"""
    if len(text) <= SPILL_CHARS:
        return text
    try:
        ws = get_session_workspace(session_id)
        d = os.path.join(ws, ".outputs")
        os.makedirs(d, exist_ok=True)
        name = re.sub(r"[^A-Za-z0-9_-]", "_", str(tc_id or uuid.uuid4().hex[:8]))[:40] + ".txt"
        with open(os.path.join(d, name), "w", encoding="utf-8") as f:
            f.write(text)
        rel = ".outputs/" + name
    except OSError:
        rel = None
    head, tail = text[:6000], text[-3000:]
    note = f"\n…[输出共 {len(text)} 字，中间省略；完整内容在 {rel}，需要时用 file_read 分段读取]…\n" if rel else f"\n…[输出共 {len(text)} 字，中间省略]…\n"
    return head + note + tail

def finish_perf(perf, status):
    calls = perf["llm_calls"]
    total_ms = round((time.time() - perf["created_at"]) * 1000, 1)
    rec = {"task_id": perf["task_id"], "session_id": perf["session_id"], "bot_id": perf["bot_id"], "model": perf.get("auto_model") or perf["model"],
           "status": status, "queued_ms": perf["queued_ms"],
           "ttft_ms": calls[0]["ttft_ms"] if calls else None,
           "first_text_ms": perf["first_text_ms"] if perf["first_text_ms"] is not None else total_ms,
           "total_ms": total_ms, "llm_calls": len(calls), "llm_ms": round(sum(c["total_ms"] for c in calls), 1),
           "streamed": all(c.get("streamed") for c in calls) if calls else False,
           "prompt_tokens": perf["prompt_tokens"], "completion_tokens": perf["completion_tokens"],
           "cached_tokens": perf.get("cached_tokens", 0), "failover": perf.get("failover"),
           "tool_defs": perf["tool_defs"], "trimmed": perf["trimmed"], "finished_at": time.time()}
    PERF.append(rec)
    log_event(perf["task_id"], "timings", rec)

def note_usage(bot_id, model, resp, request_messages=None):
    """记一次模型调用的 token，并在接近 / 达到每日上限时推送一次提醒。"""
    try:
        msg = (((resp or {}).get("choices") or [{}])[0].get("message") or {})
        p, c = cloud_usage.usage_from_response(resp, request_messages, msg.get("content"))
        conn = get_db_connection()
        try:
            cloud_usage.record(conn, bot_id or "", model, p, c)
            used = cloud_usage.total_for_day(conn)
        finally:
            conn.close()
        rs = resource_settings()
        _blocked, alert = USAGE_CAP.check(used, rs.get("daily_token_cap", 0), rs.get("usage_alert_percent", 80))
        cfg = current_notify_config()
        if alert and cfg:
            cap = rs.get("daily_token_cap", 0)
            title = "今日 token 用量已达上限" if alert == "cap" else "今日 token 用量接近上限"
            cloud_notify.notify_async(cfg, "task_completed", title, f"已用 {used} / {cap}（{used * 100 // max(cap, 1)}%）")
    except Exception as e:
        print(f"usage record failed: {e}", flush=True)

def usage_blocked():
    cap = resource_settings().get("daily_token_cap", 0)
    if not cap:
        return None
    conn = get_db_connection()
    try:
        used = cloud_usage.total_for_day(conn)
    finally:
        conn.close()
    return f"今天的 token 用量已达上限（{used} / {cap}），新任务暂停到明天；可在 云电脑资源设置 › 用量 调高上限" if used >= cap else None

def _group_llm(bot, messages, fallback):
    model, provider = _bot_provider(bot, fallback)
    url = f"{provider.get('base_url', 'https://api.openai.com/v1').rstrip('/')}/chat/completions"
    resp = call_llm_with_effort(url, {"Content-Type": "application/json", "Authorization": f"Bearer {provider.get('api_key', '')}"},
                                {"model": model, "messages": messages, "stream": False, "max_tokens": 600},
                                bot.get("reasoning_effort"))
    note_usage(bot["persona_id"], model, resp, messages)
    msg = ((resp.get("choices") or [{}])[0].get("message") or {})
    text = msg.get("content") or ""
    if isinstance(text, list):
        text = "".join(p.get("text", "") for p in text if isinstance(p, dict))
    return text, (resp.get("usage") or {}).get("total_tokens") or 0

def _group_start_task(group, bot, task, msg_id):
    """群里被 @ 的 Bot 需要真正动手：在它自己的工作区跑一个任务，结果贴回群里。"""
    model, provider = _bot_provider(bot, GROUP_FALLBACK.get(group["group_id"]))
    sid = "sess_" + uuid.uuid4().hex[:12]
    tid = "task_" + uuid.uuid4().hex[:12]
    now = time.time()
    did = "grp_task_" + uuid.uuid4().hex[:8]
    content = deleg.incoming_text(f"群聊「{group['name']}」", "task", task[:20000], did, True)
    conn = get_db_connection()
    try:
        conn.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, NULL, ?, '', ?, ?)",
                     (sid, f"群聊「{group['name']}」：" + task.strip().splitlines()[0][:40], now, bot["persona_id"]))
        conn.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, NULL, 'running', ?, ?)",
                     (tid, sid, model, now))
        conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)", (sid, content, now))
        conn.commit()
        task_msg = cloud_groups.add_message(conn, group["group_id"], bot["persona_id"], "task", task[:2000], reply_to=msg_id,
                                            meta={"task_id": tid, "session_id": sid, "status": "running"})
    finally:
        conn.close()
    with active_tasks_lock:
        active_tasks[tid] = {"process": None, "cancelled": False, "pid": None}
    TASK_HOP[tid] = 1
    GROUPS.notify()

    def worker():
        try:
            run_agent_task(tid, sid, content, model, provider, "")
        finally:
            TASK_HOP.pop(tid, None)
            c2 = get_db_connection()
            try:
                status = (c2.execute("SELECT status FROM tasks WHERE task_id = ?", (tid,)).fetchone() or ["failed"])[0]
                last = c2.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'assistant' AND content IS NOT NULL ORDER BY id DESC LIMIT 1",
                                  (sid,)).fetchone()
                result = ((last[0] if last else "") or "（没有文字结果）")[:6000]
                cloud_groups.add_message(c2, group["group_id"], bot["persona_id"], "task_result", result, reply_to=task_msg,
                                         meta={"task_id": tid, "session_id": sid, "status": status})
            finally:
                c2.close()
            GROUPS.notify()
            cfg = current_notify_config()
            if not _bot_muted(persona_id=bot["persona_id"]):
                user_notify(cfg, "task_completed", f"{bot.get('name')} 在「{group['name']}」完成了任务"[:120], result[:600],
                            bot_id=bot["persona_id"])

    threading.Thread(target=worker, daemon=True, name="group-task").start()
    return tid

GROUPS = cloud_groups.GroupEngine({
    "db": lambda: get_db_connection(),
    "settings": lambda: resource_settings(),
    "bot": lambda bid: get_persona(bid),
    "persona_text": lambda bot: cloud_bots.prompt(bot, []),
    "llm": lambda bot, messages, fallback: _group_llm(bot, messages, fallback),
    "start_task": lambda group, bot, task, msg_id: _group_start_task(group, bot, task, msg_id),
})

def group_payload(conn, g, after=0):
    members = []
    for bid in g["members"]:
        b = get_persona(bid)
        if b:
            members.append({"bot_id": bid, "name": b["name"], "emoji": b.get("emoji"), "model": b.get("model") or "",
                            "reasoning_effort": b.get("reasoning_effort") or ""})
    out = dict(g)
    out["member_bots"] = members
    out["typing"] = GROUPS.typing_list(g["group_id"])
    out["messages"] = cloud_groups.messages_after(conn, g["group_id"], after, 300) if after is not None else []
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
                    "timeout": {"type": "integer"},
                    "background": {"type": "boolean", "description": "Run detached for long installs/builds; you'll be notified on completion"}
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
            "name": "background_jobs",
            "description": "List, check, read the log tail of, or stop your background shell commands.",
            "parameters": {
                "type": "object",
                "properties": {"action": {"type": "string", "enum": ["list", "status", "log", "stop"]}, "job_id": {"type": "string"}},
                "required": ["action"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "request_user_takeover",
            "description": "Ask the user to take over the cloud desktop on their phone for a step only they can do (login, password, captcha, QR scan, payment confirmation). After calling, end your turn; the user replies '我完成了' when done.",
            "parameters": {
                "type": "object",
                "properties": {"reason": {"type": "string", "description": "What the user should do, in Chinese, one sentence"}},
                "required": ["reason"]
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
                    "category": {"type": "string", "enum": list(cloud_memory.CATEGORIES), "description": "profile / rules / people / workstreams / note (default note)."},
                    "scope": {"type": "string", "enum": ["bot", "shared"], "description": "bot (default): your own profile/journal; shared: the user profile all bots see."}
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

_BOT_FIELDS = {
    "name": {"type": "string", "description": "显示名称"},
    "description": {"type": "string", "description": "一句话简介"},
    "instructions": {"type": "string", "description": "系统提示词：这个 Bot 是谁、怎么做事"},
    "emoji": {"type": "string", "description": "头像 emoji"},
    "model": {"type": "string", "description": "模型名；留空跟随 App。需要凭据，不填则沿用你自己的凭据"},
    "credential": {"type": "string", "description": "已存的凭据名（不是密钥本身）"},
    "reasoning_effort": {"type": "string", "enum": ["off", "low", "medium", "high", "xhigh"]},
    "fast_mode": {"type": "boolean"},
    "skills": {"type": "array", "items": {"type": "string"}, "description": "技能白名单；不填 = 全部技能"},
    "plugins": {"type": "array", "items": {"type": "string"}, "description": "授权的插件 id"},
    "soul": {"type": "object", "description": "灵魂设定（整体替换；传 {} 清除）：style 风格/语气、language 回复语言、persona 人格提示词、forbidden 禁止事项",
             "properties": {"style": {"type": "string"}, "language": {"type": "string"}, "persona": {"type": "string"},
                            "forbidden": {"type": "string"}}}}

TOOL_DEFINITIONS.extend([
    {"type": "function", "function": {
        "name": "create_bot",
        "description": "Primary Bot only. Create a new Bot right away (shows up on the user's home screen immediately). Approval mode, browser isolation and other per-Bot resource settings: follow up with admin_api PUT /v1/resources.",
        "parameters": {"type": "object", "properties": dict(_BOT_FIELDS, bot_id={"type": "string", "description": "可选，小写字母数字和 - _"}),
                       "required": ["name"]}}},
    {"type": "function", "function": {
        "name": "update_bot",
        "description": "Primary Bot only. Change another Bot's (or your own) settings. Only the fields you pass change; the old settings stay undoable in the audit log.",
        "parameters": {"type": "object", "properties": dict(_BOT_FIELDS, bot_id={"type": "string"}), "required": ["bot_id"]}}},
    {"type": "function", "function": {
        "name": "delete_bot",
        "description": "Primary Bot only. Move a Bot to the trash (memory and chats kept, its routines paused); restore_bot brings it back. You cannot delete yourself.",
        "parameters": {"type": "object", "properties": {"bot_id": {"type": "string"}}, "required": ["bot_id"]}}},
    {"type": "function", "function": {
        "name": "restore_bot",
        "description": "Primary Bot only. Restore a Bot from the trash (list_bots shows the trash).",
        "parameters": {"type": "object", "properties": {"bot_id": {"type": "string"}}, "required": ["bot_id"]}}},
    {"type": "function", "function": {
        "name": "set_primary_bot",
        "description": "Primary Bot only. Make another Bot the primary Bot (it then gets these admin tools and you lose them).",
        "parameters": {"type": "object", "properties": {"bot_id": {"type": "string"}}, "required": ["bot_id"]}}},
    {"type": "function", "function": {
        "name": "admin_api",
        "description": "Primary Bot only. Call this cloud server's own HTTP API, the same one the app uses (see PROTOCOL): e.g. GET /v1/bots, GET/PUT /v1/resources (per-Bot approval & isolation), /v1/memory, /v1/skills, /v1/routines, /v1/plugins (install/remove), /v1/proxy, /v1/desktop/*, /v1/audit. Secret endpoints (credentials, push config, backup) are not available.",
        "parameters": {"type": "object", "properties": {
            "method": {"type": "string", "enum": ["GET", "POST", "PUT", "DELETE"]},
            "path": {"type": "string", "description": "以 /v1/ 开头，可带查询参数"},
            "body": {"type": "object"}}, "required": ["method", "path"]}}},
    {"type": "function", "function": {
        "name": "list_bots",
        "description": "List the user's other Bots (id, name, description, model, whether busy) so you can message or delegate to them.",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "send_to_bot",
        "description": "Send a one-way message to another Bot. It handles it in its own conversation (marked as from you); nothing comes back. Use delegate_task when you need a result.",
        "parameters": {"type": "object", "properties": {
            "bot_id": {"type": "string"},
            "message": {"type": "string"},
            "priority": {"type": "string", "enum": ["normal", "high"]}},
            "required": ["bot_id", "message"]}}},
    {"type": "function", "function": {
        "name": "delegate_task",
        "description": "Hand a self-contained task to another Bot. It runs in that Bot's own workspace, model and memory. By default waits for the result (up to wait_seconds) and returns it; if it takes longer, the result is posted back into this conversation when done.",
        "parameters": {"type": "object", "properties": {
            "bot_id": {"type": "string"},
            "task": {"type": "string", "description": "Complete instructions; the other Bot cannot see this conversation."},
            "report_back": {"type": "boolean", "description": "Send the result back to you (default true)."},
            "wait": {"type": "boolean", "description": "Block until done (default true). false = continue now, result arrives later."},
            "wait_seconds": {"type": "integer", "description": "Max seconds to wait (5-1800, default 600)."},
            "priority": {"type": "string", "enum": ["normal", "high"]}},
            "required": ["bot_id", "task"]}}},
])

TOOL_DEFINITIONS.append({"type": "function", "function": {
    "name": "skill_save",
    "description": "Save a multi-step workflow that just worked as a reusable skill (Markdown steps, commands, pitfalls). Later load it with skill_load instead of rediscovering.",
    "parameters": {"type": "object", "properties": {
        "name": {"type": "string", "description": "Short kebab-case name, e.g. weekly-report"},
        "description": {"type": "string", "description": "One line: when to use it"},
        "content": {"type": "string", "description": "Markdown: steps, exact commands, checks, pitfalls"},
        "overwrite": {"type": "boolean"}},
        "required": ["name", "description", "content"]}}})

TOOL_DEFINITIONS.extend([
    {"type": "function", "function": {
        "name": "vault_list",
        "description": "List items in the user's vault (保管库): saved logins, payment cards and contact info shared by all Bots. Returns only "
                       "non-secret metadata (id, site, username, card last4, labels) — never passwords or numbers. When the user says "
                       "'用保管库里的 X 账号登录' / asks you to log in, pay or fill a form, call this, then vault_fill, without asking the user for "
                       "the password. query can be a site/domain (matched by registrable domain) or words.",
        "parameters": {"type": "object", "properties": {
            "kind": {"type": "string", "enum": ["login", "card", "contact"]},
            "query": {"type": "string", "description": "Site, domain, URL or keyword (optional)."}}}}},
    {"type": "function", "function": {
        "name": "vault_fill",
        "description": "Fill a vault item into the page open in the cloud computer's browser (login: username + password; card: number, "
                       "expiry, CVV, name; contact: name, phone, email, address). The server fills it directly; you never see the values. "
                       "Logins are only filled when the page's domain matches the item's site. Open the page with browser_action first; "
                       "afterwards click the submit button yourself. target=desktop types into the focused field of the desktop instead.",
        "parameters": {"type": "object", "properties": {
            "id": {"type": "string", "description": "Item id from vault_list."},
            "target": {"type": "string", "enum": ["browser", "desktop"]},
            "fields": {"type": "array", "items": {"type": "string"}, "description": "Only these fields (optional), e.g. ['username'] on a username-first login page, ['password'] on the next step."},
            "selectors": {"type": "object", "description": "Optional CSS selector per field name when auto-detection misses, e.g. {\"password\": \"#pw\"}."},
            "address_index": {"type": "integer", "description": "Contact: which saved address (default = the default one)."}},
            "required": ["id"]}}},
    {"type": "function", "function": {
        "name": "vault_totp",
        "description": "Fill the current two-factor (TOTP) code of a vault login into the verification-code field of the open page. You never see the code.",
        "parameters": {"type": "object", "properties": {
            "id": {"type": "string"},
            "target": {"type": "string", "enum": ["browser", "desktop"]},
            "selector": {"type": "string", "description": "Optional CSS selector of the code field."}},
            "required": ["id"]}}},
])

VAULT_TOOLS = {"vault_list", "vault_fill", "vault_totp"}

TOOL_DEFINITIONS.extend([
    {"type": "function", "function": {
        "name": "spawn_task",
        "description": "Hand substantial work (multi-step, tool-heavy, takes more than a minute: research, coding, browsing, file work) to a "
                       "background worker so this conversation stays responsive. The worker gets its own clean context: put everything it needs "
                       "in goal + context (it cannot see this chat). After calling it, reply to the user with ONE short sentence; the result is "
                       "posted into this chat automatically when done. Do not use it for quick questions or chit-chat.",
        "parameters": {"type": "object", "properties": {
            "goal": {"type": "string", "description": "What to achieve and what the final deliverable is."},
            "context": {"type": "string", "description": "Relevant facts from the conversation: paths, links, preferences, constraints."},
            "title": {"type": "string", "description": "4-12 word title shown on the task card."}},
            "required": ["goal"]}}},
    {"type": "function", "function": {
        "name": "task_status",
        "description": "Status of this chat's background tasks (or one by id): status, elapsed time, latest step, result summary.",
        "parameters": {"type": "object", "properties": {"id": {"type": "string"}}}}},
    {"type": "function", "function": {
        "name": "task_message",
        "description": "Send the user's follow-up, correction or extra requirement into a running background task (it sees it at its next step).",
        "parameters": {"type": "object", "properties": {"id": {"type": "string"}, "text": {"type": "string"}}, "required": ["id", "text"]}}},
    {"type": "function", "function": {
        "name": "task_stop",
        "description": "Stop a background task when the user asks to stop / cancel it.",
        "parameters": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}}},
    {"type": "function", "function": {
        "name": "task_resume",
        "description": "Continue an interrupted, failed or stopped background task in its own context (optionally with an extra note).",
        "parameters": {"type": "object", "properties": {"id": {"type": "string"}, "note": {"type": "string"}}, "required": ["id"]}}},
])
WORKER_FRONT_TOOLS = {"spawn_task", "task_status", "task_message", "task_stop", "task_resume"}

_SCHEDULE_SCHEMA = {"type": "object", "description": "kind=cron {expr:'0 9 * * 1-5'}（按用户时区）｜once {at:'2026-11-11T08:00'（用户时区）或 UNIX 秒}｜interval {seconds}；"
                    "window_minutes 可选：在这之后的若干分钟内随机挑一个时间（不用卡准点）",
                    "properties": {"kind": {"type": "string", "enum": ["cron", "once", "interval"]}, "expr": {"type": "string"},
                                   "at": {"type": ["string", "number"]}, "seconds": {"type": "integer"},
                                   "window_minutes": {"type": "integer"}}, "required": ["kind"]}
TOOL_DEFINITIONS.extend([
    {"type": "function", "function": {
        "name": "react",
        "description": "Tapback-react to the user's latest message (or message_id) with one emoji, e.g. 👍 ❤️ 😂 🎉 🙏 👀. Use it INSTEAD of a text reply "
                       "when a reaction says it all (thanks, ok, acknowledgements); then end your turn without text.",
        "parameters": {"type": "object", "properties": {"emoji": {"type": "string"}, "message_id": {"type": "integer"}}, "required": ["emoji"]}}},
    {"type": "function", "function": {
        "name": "ask_choice",
        "description": "When you truly need the user to decide, show a tappable options card instead of asking in prose. Ends your turn; "
                       "the user's pick arrives as their next message (dismissing the card means they decline).",
        "parameters": {"type": "object", "properties": {
            "question": {"type": "string"},
            "options": {"type": "array", "items": {"type": "object", "properties": {"label": {"type": "string"}, "detail": {"type": "string"}},
                                                   "required": ["label"]}, "description": "2-8 options"},
            "multi": {"type": "boolean", "description": "Allow picking several."},
            "allow_custom": {"type": "boolean", "description": "Offer a free-text answer (default true)."}},
            "required": ["question", "options"]}}},
    {"type": "function", "function": {
        "name": "report_progress",
        "description": "Background tasks only: post a brief milestone into the user's chat (max 3 per task; e.g. 'found 12 candidates, comparing now'). "
                       "Not for step-by-step narration.",
        "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}},
    {"type": "function", "function": {
        "name": "routine_create",
        "description": "Create a routine for this bot: a scheduled prompt (daily digest, weekly check), a one-off reminder, or a monitor "
                       "('tell me when X'). The prompt runs later in a fresh chat; monitors should reply [SKIP] when nothing changed.",
        "parameters": {"type": "object", "properties": {
            "name": {"type": "string"}, "prompt": {"type": "string", "description": "What to do each run, self-contained."},
            "schedule": _SCHEDULE_SCHEMA, "monitor": {"type": "boolean", "description": "Only message the user when something changed."},
            "max_runs": {"type": "integer"}}, "required": ["name", "prompt", "schedule"]}}},
    {"type": "function", "function": {
        "name": "routine_list",
        "description": "List this bot's routines (id, name, schedule, next run, enabled).",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "routine_delete",
        "description": "Delete (or with enabled=false just pause) one of this bot's routines.",
        "parameters": {"type": "object", "properties": {"id": {"type": "string"}, "enabled": {"type": "boolean"}}, "required": ["id"]}}},
])
RUNMODEL_TOOLS = {"react", "ask_choice", "report_progress", "routine_create", "routine_list", "routine_delete"}
TURN_FLAGS = {}              # task_id -> {"answered", "end", "pages"}：表情 / 选项卡算回答；选项卡结束本轮；本轮写的页面挂在最终回复上
WORKER_INSTRUCTIONS = (
    "\n\n[后台任务] 你是这个 Bot 的后台工作者，独立完成下面的任务（看不到前台聊天）。用户发来的补充要求会作为新消息出现，照着调整。"
    "不要逐步汇报；做完后最后一条消息写清楚结果（结论在前，必要的链接 / 路径 / 数字），它会原样发给用户。")
FRONT_NOTE = (
    "\n\n[前台对话] 先回话：每条消息先马上给一句简短回应或直接答案；要调用工具时，在同一条回复的文字里先写这句回应再调工具。"
    "简单的问题和闲聊直接回答。需要多步操作、大量工具调用、耗时超过一分钟的事，用 spawn_task 交给后台任务，"
    "然后只回一句简短的确认（比如「好，我去查，做完告诉你」），不要在这里自己一步步做。后台正在做事时用户又发来消息：立刻理解他的意思，用一句自然的话点明他想做什么、你接下来会怎么做（例如「你想把课件改成 10 页，我让后台现在就改」），不要用固定套话；然后由你决定：用 task_message 把改写后的具体要求转给正在跑的后台，或 spawn_task 另派一件，或 task_stop 停下/换掉，或直接回答。")
DELEGATION_TOOLS = {"send_to_bot", "delegate_task"}
ADMIN_TOOLS = {"create_bot", "update_bot", "delete_bot", "restore_bot", "set_primary_bot", "admin_api"}

TOOL_DEFINITIONS.append({"type": "function", "function": {
    "name": "recall_snapshot",
    "description": "Read a conversation snapshot saved by /reset (goals, decisions, state, todos, key facts of an earlier conversation with this bot). Without snapshot_id: list recent snapshot titles. Call it when the user refers to earlier work.",
    "parameters": {"type": "object", "properties": {
        "snapshot_id": {"type": "string", "description": "Snapshot id from the list (optional)."},
        "query": {"type": "string", "description": "Keywords to filter titles / content (optional)."}}}}})

TOOL_TITLE_PARAM = {"type": "string", "description": "A concise 4-12 word summary of what this call does, shown to the user (same language as the user, e.g. '读取服务器连接信息'). Not passed to the tool."}
for _t in TOOL_DEFINITIONS:
    _props = _t["function"].setdefault("parameters", {"type": "object"}).setdefault("properties", {})
    _props.setdefault("tool_title", TOOL_TITLE_PARAM)

def session_tools(session_id, depth):
    """这个会话能用的工具：后台任务（worker）自己的会话和子任务里不能再派后台任务。"""
    tools = tools_for_depth(depth, is_admin_session(session_id, depth))
    if depth >= 1 or not session_is_front(session_id):
        tools = [t for t in tools if t["function"]["name"] not in WORKER_FRONT_TOOLS]
    return tools

def session_is_worker(session_id):
    conn = get_db_connection()
    try:
        return cloud_workers.is_worker_session(conn, session_id)
    finally:
        conn.close()

def session_is_front(session_id):
    """用户直接聊天的对话（App / Telegram）才分前台和后台；后台任务自己、别的 Bot 交来的委托、例行任务都不算。"""
    conn = get_db_connection()
    try:
        if cloud_workers.is_worker_session(conn, session_id):
            return False
        if conn.execute("SELECT 1 FROM bot_delegations WHERE to_session = ?", (session_id,)).fetchone():
            return False
        row = conn.execute("SELECT title FROM sessions WHERE session_id = ?", (session_id,)).fetchone()
        return not (row and (row[0] or "").startswith("例行任务："))
    finally:
        conn.close()

def tools_for_depth(depth, admin=False):
    """admin：主 Bot 的顶层任务才拿到管理工具（执行时会再查一次角色）。"""
    if depth >= 1:
        return [t for t in TOOL_DEFINITIONS if t["function"]["name"] not in DELEGATION_TOOLS | {"subagent_task"} | ADMIN_TOOLS]
    if admin:
        return TOOL_DEFINITIONS
    return [t for t in TOOL_DEFINITIONS if t["function"]["name"] not in ADMIN_TOOLS]

def is_admin_session(session_id, depth=0):
    """服务器侧的角色检查：只有当前主 Bot 的会话、且不是子任务，才能用管理工具。每次现查当前主 Bot 的 id，
    换主 Bot 后旧主 Bot 立刻失去权限（包括它正在跑的任务的下一步）。"""
    if depth or not session_id:
        return False
    pid = session_persona_id(session_id)
    return bool(pid) and pid == primary_bot_id()

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "Redirection prohibited", headers, fp)

TASK_EFFORT = {}          # task_id -> 本次任务的思考深度（例行任务覆盖、客户端指定）
_EFFORT_UNSUPPORTED = set()  # (base_url, model)：服务商拒绝思考参数后不再发送

_EFFORT_STYLE = {}            # (base_url, model) -> 当前使用的参数写法序号（上一种被拒后换下一种）
_BUDGET = {"low": 2048, "medium": 8192, "high": 24576, "xhigh": 48000}

def effort_styles(model):
    """各家思考参数写法，按优先级排列。所有模型都可以调；服务商拒绝一种就换下一种，全被拒才记为不支持。"""
    name = (model or "").lower()
    if "claude" in name or "sonnet" in name or "opus" in name:
        return ["claude_thinking", "reasoning_effort"]
    if "qwen" in name or "qwq" in name:
        return ["reasoning_effort", "qwen_enable_thinking"]
    if any(k in name for k in ("deepseek", "glm", "kimi", "doubao", "minimax")):
        return ["reasoning_effort", "thinking_enabled"]
    return ["reasoning_effort"]

def apply_reasoning(body, model, effort, chat_url):
    """把思考深度映射成服务商参数（Claude 用 thinking.budget_tokens，Qwen 用 enable_thinking，DeepSeek / GLM 等可用 thinking.type，
    其余用 reasoning_effort）。off 或已确认不支持时不发送。"""
    if not effort or effort == "off" or (chat_url, model) in _EFFORT_UNSUPPORTED:
        return body
    styles = effort_styles(model)
    style = styles[min(_EFFORT_STYLE.get((chat_url, model), 0), len(styles) - 1)]
    out = dict(body)
    budget = _BUDGET.get(effort, 8192)
    if style == "claude_thinking":
        out["thinking"] = {"type": "enabled", "budget_tokens": budget}
        out["max_tokens"] = max(int(out.get("max_tokens") or 0), budget + 4096)
    elif style == "qwen_enable_thinking":
        out["enable_thinking"] = True
        out["thinking_budget"] = budget
    elif style == "thinking_enabled":
        out["thinking"] = {"type": "enabled"}
    else:
        out["reasoning_effort"] = effort
    return out

def effort_rejected(url, model, effort):
    """服务商拒绝了当前写法：返回新的 effort（xhigh 先降到 high），换下一种写法，或标记为不支持。返回 (effort, changed)。"""
    if effort == "xhigh" and "claude" not in (model or "").lower():
        return "high", True
    styles = effort_styles(model)
    idx = _EFFORT_STYLE.get((url, model), 0)
    if idx + 1 < len(styles):
        _EFFORT_STYLE[(url, model)] = idx + 1
        return effort, True
    _EFFORT_UNSUPPORTED.add((url, model))
    return effort, True

def call_llm_with_effort(url, headers, body, effort):
    payload = apply_reasoning(body, body.get("model"), effort, url)
    if payload is body:
        return call_llm_pooled(url, headers, body)
    try:
        return call_llm_pooled(url, headers, payload)
    except urllib.error.HTTPError as e:
        if e.code not in (400, 422):
            raise
        # 思考参数被拒：依次降级（xhigh→high、换写法），都不行就不发送；不带参数也失败说明不是参数的问题，撤销标记
        model = body.get("model")
        for _ in range(4):
            effort, _changed = effort_rejected(url, model, effort)
            p = apply_reasoning(body, model, effort, url)
            try:
                return call_llm_pooled(url, headers, p)
            except urllib.error.HTTPError as e2:
                if e2.code not in (400, 422):
                    raise
                if p is body:
                    _EFFORT_UNSUPPORTED.discard((url, model))
                    raise
        return call_llm_pooled(url, headers, body)

def call_llm_pooled(url, headers, body):
    return cloud_llm.chat_completion(url, headers, body, stream=False)[0]

def call_llm(url, headers, body):
    opener = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST")
    with opener.open(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))

def run_agent_task(task_id, session_id, initial_content, model, provider_config, instructions, depth=0):
    """顶层任务先排队：同一 Bot 的并发数、全局并发数、同时运行的 Bot 数都来自资源设置；子代理在父任务的名额里运行。"""
    if depth > 0:
        return _run_agent_task_inner(task_id, session_id, initial_content, model, provider_config, instructions, depth)
    blocked = usage_blocked()
    if blocked:
        # 例行任务、Telegram、委托等后台入口也受每日上限约束
        log_event(task_id, "error", {"error": blocked})
        conn = get_db_connection()
        try:
            conn.execute("UPDATE tasks SET status = 'limit_reached' WHERE task_id = ? AND status IN ('running', 'waiting_user')", (task_id,))
            conn.commit()
        finally:
            conn.close()
        return None
    lane = task_lane(session_id)
    bot_id = session_persona_id(session_id)

    def queued(pos):
        log_event(task_id, "queued", {"position": pos, "message": f"排队中（第 {pos} 位）"})

    slot = GATE.acquire(task_id, lane, bot_id, cancelled=lambda: is_task_cancelled(task_id), on_queued=queued,
                        priority=TASK_PRIORITY.get(task_id, "normal"))
    if slot is None:
        # 排队时被取消（含上游委托方取消）：把状态落到数据库
        conn = get_db_connection()
        try:
            conn.execute("UPDATE tasks SET status = 'cancelled' WHERE task_id = ? AND status IN ('running', 'waiting_user')", (task_id,))
            conn.commit()
        finally:
            conn.close()
        log_event(task_id, "cancelled", {"message": "排队时已取消"})
        return None
    timer = None
    try:
        if slot:
            ACTIVE_SLOTS[session_id] = slot
        limit = iso.bot_settings(resource_settings(), bot_id).get("task_timeout_min") or 0
        if limit:
            def expire():
                log_event(task_id, "error", {"error": f"任务超过 {limit} 分钟上限，已停止"})
                set_task_cancelled(task_id)
            timer = threading.Timer(limit * 60, expire)
            timer.daemon = True
            timer.start()
        return _run_agent_task_inner(task_id, session_id, initial_content, model, provider_config, instructions, depth)
    finally:
        if timer:
            timer.cancel()
        ACTIVE_SLOTS.pop(session_id, None)
        if bot_id and slot:
            key = f"{bot_id}:{slot}"
            if DISPLAYS.info(key):
                DISPLAYS.stop(key)
        GATE.release(task_id)

def _run_agent_task_inner(task_id, session_id, initial_content, model, provider_config, instructions, depth=0):
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
    last_reset = c.execute("SELECT MAX(id) FROM messages WHERE session_id = ? AND role = 'context_reset'", (session_id,)).fetchone()[0] or 0
    c.execute("SELECT role, content, tool_calls, tool_call_id, meta FROM messages WHERE session_id = ? AND id > ? "
              "AND role != 'context_reset' ORDER BY id ASC", (session_id, last_reset))
    rows = c.fetchall()
    conn.close()

    plugin_defs, plugin_map, plugin_note = plugin_tools_for_session(session_id, depth)
    # 系统提示保持稳定（不放随消息变化的内容），服务商的前缀缓存才能命中；@提及提示放到本轮请求的末尾
    system_text = persona_prompt(session_id) + (instructions or "") + server_tool_notes(session_id) + plugin_note
    if last_reset:
        system_text += snapshot_pointer(session_id)
    if _bot_fast(session_id):
        system_text += FAST_MODE_NOTE
    front_session = depth == 0 and session_is_front(session_id)
    reply = reply_plan(session_id, model) if front_session else None
    instant = bool(reply and reply["mode"] == "instant")
    if instant:
        system_text += cloud_reply.FRONT_INSTANT_NOTE
    elif front_session:
        system_text += FRONT_NOTE
    system_text += cloud_runmodel.ATTACHMENT_NOTE
    if depth == 0:
        system_text += cloud_runmodel.REPLY_STYLE_NOTE + cloud_runmodel.MEMORY_NOTE
        if not session_incognito(session_id):
            _pc = get_db_connection()
            try:
                _pid = session_persona_id(session_id)
                system_text += cloud_runmodel.profile_block(_pc, _pid, (get_persona(_pid) or {}).get("name") if _pid else None)
            except Exception as e:
                print(f"profile block failed: {type(e).__name__}", flush=True)
            finally:
                _pc.close()
    system_text += cloud_bots.language_tail(get_persona(session_persona_id(session_id)))   # 灵魂设定的回复语言：结尾再强调一次
    dynamic_note = mention_note(session_id, initial_content)
    try:
        _ec = get_db_connection()
        try:
            _exam = cloud_exams.note(_ec)
        finally:
            _ec.close()
        if _exam:
            dynamic_note = (dynamic_note or "") + _exam
    except Exception as e:
        print(f"exam note failed: {type(e).__name__}", flush=True)
    # 后台任务摘要不在这里一次性拼进 dynamic_note：同一条前台任务里先 spawn 再被插话时，
    # 旧的 dynamic_note 还是空的，前台模型看不到进行中的 worker（43027845469 插话变成「秒回：插话」）。
    if on_duty():
        # 放在本轮末尾而不是系统提示里：系统提示不变，前缀缓存照样命中
        dynamic_note = (dynamic_note or "") + DUTY_NOTE
    if session_incognito(session_id):
        dynamic_note = (dynamic_note or "") + INCOGNITO_NOTE
    messages = [{"role": "system", "content": system_text.lstrip()}]
    for r_role, r_content, r_tc, r_tcid, r_meta in rows:
        m = {"role": r_role}
        if r_content is not None:
            decoded_content = cloud_runmodel.model_content(r_role, r_content, r_meta)
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

    _bot = session_bot(session_id)
    effort = TASK_EFFORT.pop(task_id, None) or (_bot or {}).get("reasoning_effort")
    if _bot_fast(session_id) and effort not in (None, "", "off"):
        effort = "low"
    log_event(task_id, "started", {"message": "Started", "model": model, "reasoning_effort": effort})
    final_status = "completed"
    seen_tool_ids = set()
    answered = False            # 本任务是否已经给用户写出过回答文字
    rs_perf = resource_settings()
    extra_tools = set()
    perf = {"task_id": task_id, "session_id": session_id, "bot_id": session_persona_id(session_id) or "", "model": model,
            "started_at": time.time(), "queued_ms": 0, "llm_calls": [], "first_text_ms": None, "tools": 0,
            "prompt_tokens": 0, "completion_tokens": 0, "cached_tokens": 0, "tool_defs": 0, "trimmed": False}
    try:
        created = get_db_connection().execute("SELECT created_at FROM tasks WHERE task_id = ?", (task_id,)).fetchone()
        perf["created_at"] = created[0] if created else perf["started_at"]
    except Exception:
        perf["created_at"] = perf["started_at"]
    perf["queued_ms"] = round((perf["started_at"] - perf["created_at"]) * 1000, 1)

    def on_text(text):
        if perf["first_text_ms"] is None:
            perf["first_text_ms"] = round((time.time() - perf["created_at"]) * 1000, 1)
        live_update(task_id, text)

    def on_reasoning(text):
        live_update(task_id, reasoning=text)

    # 主模型连续失败（5xx / 429 / 超时 / 断连）：先原地重试一次，再按资源设置里的 failover 依次换用备用服务商
    route = {"url": chat_url, "key": api_key, "model": model, "chain": list(rs_perf.get("failover") or [])}
    main_model = model
    if instant:
        # 秒回：前台用快模型马上回话；真正干活的后台任务用后台模型（没填就是主模型）
        REPLY_BACK_MODEL[task_id] = reply["back_model"]
        if reply["front_model"] and reply["front_model"] != model:
            route["model"] = model = reply["front_model"]
            perf["auto_model"] = model       # 前台模型出错时本轮回到主模型（同自动选模型的退路）
        perf["reply_mode"] = "instant"
        log_event(task_id, "reply_mode", {"mode": "instant", "source": reply["source"], "front_model": route["model"],
                                          "back_model": reply["back_model"]})
    # 自动选模型：简单的短问题用同一服务商的快速模型；快速模型出错就回到主模型
    if instant:
        pass
    elif depth == 0 and rs_perf.get("auto_model") and rs_perf.get("fast_model") and rs_perf["fast_model"] != model \
            and eff.is_simple_request(initial_content):
        route["model"] = model = rs_perf["fast_model"]
        perf["auto_model"] = model
        log_event(task_id, "status", {"message": f"简单问题，用快速模型 {model} 回答"})
    elif depth == 0 and rs_perf.get("auto_model") and eff.is_hard_request(initial_content):
        # 难题：换强模型（设了的话）并把思考深度调到 high；强模型出错同样回到主模型
        strong = rs_perf.get("strong_model") or ""
        if strong and strong != model:
            route["model"] = model = strong
            perf["auto_model"] = model
        if effort in (None, "", "low", "medium") and not _bot_fast(session_id) and not on_duty():
            effort = "high"
        perf["hard"] = True
        log_event(task_id, "status", {"message": "难题：" + (f"换用强模型 {model}，" if perf.get("auto_model") else "") + f"思考深度 {effort or '默认'}"})
    if front_session and not instant and rs_perf.get("quick_ack", True) and rs_perf.get("fast_model") and rs_perf["fast_model"] != route["model"]:
        # 先回话：主模型 1.5 秒还没出字，就用快速模型先回一句简短确认
        threading.Thread(target=_quick_ack, args=(task_id, session_id, initial_content, rs_perf["fast_model"], chat_url, api_key, perf),
                         daemon=True).start()

    loop_guard = cloud_runmodel.LoopGuard()
    vision = {"blocked": False}

    def route_vision(reason):
        """主模型不能看图：用看图模型把图片读成文字换进上下文。成功返回 True；没有可用的看图模型返回 False。"""
        base = cloud_vision.base_of(route["url"])
        vconn = get_db_connection()
        try:
            vm = (rs_perf.get("vision_model") or "").strip()
            if not vm:
                cloud_vision.probe(vconn, base, route["key"])
                cands = cloud_vision.vision_models(vconn, base, exclude=route["model"])
                vm = cands[0] if cands else ""
            if not vm or vm == route["model"] or cloud_vision.supports(vconn, base, vm) is False:
                return False
            hdrs = {"Content-Type": "application/json", "Authorization": f"Bearer {route['key']}"}

            def describe(url):
                resp, _t = call_chat(route["url"], hdrs, {"model": vm, "messages": [{"role": "user", "content": [
                    {"type": "text", "text": cloud_vision.DESCRIBE_PROMPT}, {"type": "image_url", "image_url": {"url": url}}]}]},
                    None, stream=False)
                text = (((resp.get("choices") or [{}])[0].get("message") or {}).get("content") or "").strip()
                if not text:
                    raise RuntimeError("看图模型没有返回内容")
                return text
            messages[:] = cloud_vision.replace_images(vconn, messages, vm, describe)
            perf["vision_model"] = vm
            log_event(task_id, "vision_route", {"model": vm, "reason": reason})
            return True
        except Exception as e:
            print(f"vision route failed: {type(e).__name__}", flush=True)
            return False
        finally:
            vconn.close()

    # 手机只给附件路径（2.47.0 起图片不再 base64 塞进 message_parts）：调用模型前读上传的文件补成图片内容
    def _resolve_att(rel, _sid=session_id):
        target, err = safe_path_resolve(_sid, rel)
        return None if err else target
    try:
        _added, _missing = cloud_vision.expand_attachment_images(messages, _resolve_att)
    except Exception as e:
        print(f"attachment images failed: {type(e).__name__}", flush=True)
        _added, _missing = 0, 0
    if _missing:
        log_event(task_id, "status", {"message": cloud_vision.missing_note(_missing)})
    _had_images = cloud_vision.has_images(messages)
    if cloud_vision.has_images(messages):
        _vc = get_db_connection()
        try:
            _base = cloud_vision.base_of(route["url"])
            if cloud_vision.supports(_vc, _base, route["model"]) is None:
                cloud_vision.probe(_vc, _base, route["key"])
            _cap = cloud_vision.supports(_vc, _base, route["model"])
        finally:
            _vc.close()
        if _cap is False and not route_vision("model_caps"):
            vision["blocked"] = True
    if _had_images:
        # 图片已直接给模型看，或已由看图模型读成文字：别去 OCR、装工具或打开文件识别（真机上 Bot 为一张排班表跑了很多轮 OCR）
        dynamic_note = (dynamic_note or "") + VISION_NOTE

    class VisionRetry(Exception):
        pass

    def call_with_failover(send_msgs, tools):
        nonlocal model
        retried = False
        while True:
            try:
                return call_chat(route["url"], {"Content-Type": "application/json", "Authorization": f"Bearer {route['key']}"}, {
                    "model": route["model"], "messages": send_msgs, "tools": tools, "tool_choice": "auto"
                }, effort, stream=rs_perf.get("stream", True), on_text=on_text, cache_key=perf["bot_id"] or session_id,
                   on_reasoning=on_reasoning, should_abort=lambda: inbox_pending(task_id) or is_task_cancelled(task_id))
            except cloud_llm.Aborted:
                raise
            except Exception as e:
                if is_task_cancelled(task_id):
                    raise
                if cloud_vision.has_images(send_msgs) and cloud_vision.is_unsupported_error(
                        _err_text(e) if isinstance(e, urllib.error.HTTPError) else str(e)):
                    # 服务商明确说这个模型不收图片：记下来（以后直接走看图模型），这次转给看图模型读图后重来
                    _vc = get_db_connection()
                    try:
                        cloud_vision.record(_vc, cloud_vision.base_of(route["url"]), route["model"], False, "error")
                    finally:
                        _vc.close()
                    if not route_vision("error"):
                        vision["blocked"] = True
                    raise VisionRetry()
                if perf.get("auto_model") and route["model"] == perf["auto_model"]:
                    # 快速模型不行（不存在 / 出错）：本任务直接换回主模型，不算失败
                    log_event(task_id, "status", {"message": f"快速模型不可用（{sanitize_err(e)[:60]}），改用 {main_model}"})
                    route["model"] = model = main_model
                    perf["auto_model_fallback"] = True
                    continue
                if not eff.is_failover_error(e):
                    raise
                if not retried:
                    retried = True
                    time.sleep(1.0)
                    continue
                if not route["chain"]:
                    raise
                nxt = route["chain"].pop(0)
                prov, _st, err = resolve_provider({"protocol": "chat", "credential": nxt["credential"]})
                if err:
                    log_event(task_id, "status", {"message": f"备用服务商 {nxt['credential']} 不可用：{err}"})
                    continue
                log_event(task_id, "status", {"message": f"主模型暂时不可用（{sanitize_err(e)[:80]}），已切换到备用：{nxt['model']}"})
                route.update(url=f"{prov['base_url'].rstrip('/')}/chat/completions", key=prov["api_key"], model=nxt["model"])
                model = nxt["model"]
                perf["failover"] = nxt["model"]
                retried = False

    try:
        def take_injected():
            for item in inbox_take(task_id):
                # 插话：作为一条用户消息放进上下文和历史（位置就是模型看到它的地方）
                messages.append({"role": "user", "content": item["content"]})
                if cloud_vision.image_lines(item["content"]):
                    # 运行中带图片插话：同样把上传的图片补成图片内容
                    try:
                        cloud_vision.expand_attachment_images(messages, _resolve_att, recent=1)
                    except Exception as e:
                        print(f"injected images failed: {type(e).__name__}", flush=True)
                insert_message(session_id, "user", item["content"], meta={"injected": True, "nonce": item["nonce"]})
                log_event(task_id, "user_message_applied", {"nonce": item["nonce"]})

        for _ in range(MAX_TURNS):
            if is_task_cancelled(task_id):
                final_status = "cancelled"
                break
            if vision["blocked"]:
                # 没有能看图的模型：立刻如实回复，不让主模型去装 OCR 之类的东西
                log_event(task_id, "thought", {"content": cloud_vision.NO_VISION_REPLY})
                messages.append({"role": "assistant", "content": cloud_vision.NO_VISION_REPLY})
                insert_message(session_id, "assistant", cloud_vision.NO_VISION_REPLY, meta={"vision": "unavailable"})
                answered = True
                break
            take_injected()
            try:
                send_msgs, trim_note = cloud_llm.trim_messages(messages, rs_perf.get("context_trim_tokens", 0))
                if trim_note and not perf["trimmed"]:
                    perf["trimmed"] = True
                    log_event(task_id, "status", {"message": "对话较长，已自动精简较早的内容"})
                if front_session:
                    # 每轮现查：刚派的后台任务、take_injected 插话，都能看到 worker 列表
                    _wnote = _front_worker_note(session_id)
                    if _wnote:
                        send_msgs = _append_note(send_msgs, _wnote)
                if dynamic_note:
                    send_msgs = _append_note(send_msgs, dynamic_note)
                if instant:
                    tools = cloud_reply.front_tools(session_tools(session_id, depth))   # 前台不拿干活的工具，全部交给后台
                else:
                    tools, _omitted = cloud_llm.select_tools(session_tools(session_id, depth) + plugin_defs, send_msgs, extra_tools,
                                                              always_all=not rs_perf.get("lazy_tools", True))
                perf["tool_defs"] = max(perf["tool_defs"], len(tools))
                live_update(task_id, "", reasoning="", tool=None)
                try:
                    resp, timing = call_with_failover(send_msgs, tools)
                except VisionRetry:
                    live_clear(task_id)
                    continue
                except cloud_llm.Aborted:
                    # 用户插话：丢掉这次还没说完的回复，带上新消息重新问
                    live_clear(task_id)
                    if is_task_cancelled(task_id):
                        final_status = "cancelled"
                        break
                    log_event(task_id, "status", {"message": "收到你的新消息，按新要求继续"})
                    continue
                # 这一轮的文字马上会作为 thought 事件写入：清掉流式草稿，免得手机把同一段话再画一遍
                live_clear(task_id)
                perf["llm_calls"].append(timing)
                u = resp.get("usage") or {}
                perf["prompt_tokens"] += int(u.get("prompt_tokens") or 0)
                perf["completion_tokens"] += int(u.get("completion_tokens") or 0)
                perf["cached_tokens"] += eff.cached_tokens(u)
            except Exception as e:
                err = sanitize_err(e)
                if answered:
                    # 已经给出过回答，后续步骤（如回答后顺手记忆）调用失败：保留回答，任务算完成，只记一条提醒
                    log_event(task_id, "status", {"message": "回答已给出；后续步骤调用模型失败，已跳过：" + str(err)[:200]})
                    final_status = "completed"
                else:
                    log_event(task_id, "error", {"error": err})
                    final_status = "failed"
                break

            note_usage(session_persona_id(session_id), model, resp, messages)
            choices = resp.get("choices", [])
            if not choices:
                log_event(task_id, "error", {"error": "Missing choices"})
                final_status = "failed"
                break

            msg = choices[0].get("message", {})
            content = msg.get("content")
            tool_calls = normalize_tool_call_ids(msg.get("tool_calls"), seen_tool_ids)
            reasoning_text = msg.get("reasoning_content") or (msg.get("reasoning") if isinstance(msg.get("reasoning"), str) else None)
            if reasoning_text:
                # 思考过程：先于这一轮的文字和工具写入，手机按顺序画「深度思考」气泡
                log_event(task_id, "reasoning", {"content": reasoning_text[:200000], "chars": len(reasoning_text)})
            row_meta = {"reasoning": reasoning_text[:200000]} if reasoning_text else None

            if not content and not tool_calls:
                if answered and not inbox_close(task_id):
                    break               # 工具做完后模型没再说话：前面的回答就是最终回答
                if answered:
                    continue            # 有插话：接着回答新消息
                log_event(task_id, "error", {"error": "模型返回了空回复（没有文字也没有工具调用）"})
                final_status = "failed"
                break
            content = _take_ack(task_id, content, tool_calls)   # 快速确认：并进第一条工具调用消息，已经有文字就不要了
            if content:
                answered = True

            if content and not tool_calls:
                log_event(task_id, "thought", {"content": content})
                messages.append({"role": "assistant", "content": content})
                row_meta = _turn_meta(task_id, row_meta)
                insert_message(session_id, "assistant", content, meta=row_meta)

            if tool_calls:
                ast_msg = {"role": "assistant"}
                if content:
                    ast_msg["content"] = content
                    log_event(task_id, "thought", {"content": content})
                else:
                    ast_msg["content"] = None
                ast_msg["tool_calls"] = tool_calls
                if msg.get("reasoning_content"):
                    ast_msg["reasoning_content"] = msg["reasoning_content"]
                messages.append(ast_msg)

                insert_message(session_id, "assistant", content, tool_calls=tool_calls, meta=row_meta)

                def exec_tool(tc):
                    if is_task_cancelled(task_id):
                        return None
                    tc_id = tc.get("id")
                    fn = tc.get("function", {})
                    fn_name = fn.get("name")
                    try: fn_args = json.loads(fn.get("arguments", "{}"))
                    except: fn_args = {}

                    log_event(task_id, "tool_call", {"id": tc_id, "tool": fn_name, "arguments": fn_args})
                    if is_task_cancelled(task_id):
                        return None
                    if isinstance(fn_args, dict) and fn_name not in plugin_map:
                        fn_args = {k: v for k, v in fn_args.items() if k != "tool_title"}   # 只给人看的标题，不传给工具
                    started_at = time.time()
                    live_update(task_id, tool={"id": tc_id, "name": fn_name, "output": ""})
                    blocked = loop_guard.check(fn_name, fn_args)
                    if blocked:
                        return (tc_id, fn_name, blocked, 0)
                    if instant:
                        front_err = cloud_reply.front_blocked(fn_name)
                        if front_err:
                            handed = instant_auto_handoff(
                                task_id, session_id, fn_name, initial_content,
                                REPLY_BACK_MODEL.get(task_id) or main_model, provider_config)
                            return (tc_id, fn_name, handed, 0)
                    if fn_name in ("browser_action", "desktop_action") and isinstance(fn_args, dict):
                        cloud_replay.note_action(task_id, fn_name, fn_args)     # 录屏回放：记下这一步做了什么（不含输入原文）

                    policy = current_approval_policy()
                    hit = cloud_policy.evaluate(fn_name, fn_args, policy)
                    if not hit and fn_name in ALWAYS_CONFIRM_TOOLS:
                        hit = ALWAYS_CONFIRM_TOOLS[fn_name]
                    if not hit and fn_name in plugin_map and PLUGINS.needs_confirm(*plugin_map[fn_name]):
                        hit = {"id": "plugin_confirm", "tool": fn_name, "field": "*", "pattern": ".", "category": "outbound",
                               "reason": f"插件 {plugin_map[fn_name][0]} 的写操作 {plugin_map[fn_name][1]}"}
                    decision = None
                    if hit and approval_mode_for(session_id) == "auto":
                        # 「一律批准」：不暂停，照常执行，事件里留一条记录（对话里能看到批准了什么）
                        log_event(task_id, "approval_auto", {"tool": fn_name, "rule_id": hit.get("id"), "reason": hit.get("reason"),
                                                             "category": hit.get("category")})
                        decision = "approved"
                    elif hit:
                        decision = request_approval(task_id, session_id, tc_id, fn_name, fn_args, hit, policy.get("timeout_seconds", 1800))
                        if decision == "cancelled" or is_task_cancelled(task_id):
                            return None

                    if hit and decision != "approved":
                        label = {"denied": "用户拒绝", "expired": "审批超时未获批准"}.get(decision, decision)
                        res = {"error": f"{label}，未执行：{hit['reason']}", "approval": decision, "rule_id": hit["id"]}
                    elif fn_name == "shell_execute": res = tool_shell_execute(task_id, session_id, fn_args)
                    elif fn_name == "file_read": res = tool_file_read(task_id, session_id, fn_args)
                    elif fn_name == "file_write": res = tool_file_write(task_id, session_id, fn_args)
                    elif fn_name == "file_edit": res = tool_file_edit(task_id, session_id, fn_args)
                    elif fn_name == "browser_action": res = tool_browser_action(task_id, session_id, fn_args)
                    elif fn_name == "desktop_action": res = tool_desktop_action(task_id, session_id, fn_args)
                    elif fn_name == "request_user_takeover": res = tool_request_user_takeover(task_id, session_id, fn_args)
                    elif fn_name == "background_jobs": res = tool_background_jobs(task_id, session_id, fn_args)
                    elif fn_name == "memory_write": res = tool_memory_write(task_id, session_id, fn_args)
                    elif fn_name == "memory_search": res = tool_memory_search(task_id, session_id, fn_args)
                    elif fn_name == "recall_snapshot": res = tool_recall_snapshot(session_id, fn_args)
                    elif fn_name == "skill_load": res = tool_skill_load(task_id, session_id, fn_args)
                    elif fn_name == "page_write": res = tool_page_write(task_id, session_id, fn_args)
                    elif fn_name == "subagent_task": res = tool_subagent_task(task_id, session_id, fn_args, model, provider_config, depth)
                    elif fn_name == "list_bots": res = tool_list_bots(task_id, session_id, fn_args)
                    elif fn_name in VAULT_TOOLS: res = tool_vault(task_id, session_id, fn_name, fn_args)
                    elif fn_name in RUNMODEL_TOOLS: res = tool_runmodel(task_id, session_id, fn_name, fn_args, model, provider_config, depth)
                    elif fn_name in WORKER_FRONT_TOOLS:
                        res = tool_worker(task_id, session_id, fn_name, fn_args, REPLY_BACK_MODEL.get(task_id) or main_model, provider_config) \
                            if depth == 0 and session_is_front(session_id) else {"error": "这里不能派后台任务，直接完成"}
                    elif fn_name in ADMIN_TOOLS:
                        res = tool_admin(task_id, session_id, fn_name, fn_args) if is_admin_session(session_id, depth) \
                            else {"error": "只有主 Bot 能管理 Bot 和系统设置；请让用户在主 Bot 里操作"}
                    elif fn_name == "request_tools":
                        known = {d["function"]["name"] for d in session_tools(session_id, depth)}
                        want = [n for n in (fn_args.get("names") or []) if n in known]
                        res = {"enabled": want, "note": "下一步可以使用这些工具"} if want else {"error": "没有这些工具", "available": sorted(known)}
                    elif fn_name == "skill_save": res = tool_skill_save(task_id, session_id, fn_args)
                    elif fn_name == "send_to_bot" and depth == 0: res = tool_send_to_bot(task_id, session_id, fn_args, model, provider_config)
                    elif fn_name == "delegate_task" and depth == 0: res = tool_delegate_task(task_id, session_id, fn_args, model, provider_config)
                    elif fn_name == "image_generate": res = tool_image_generate(task_id, session_id, fn_args, provider_config)
                    elif fn_name == "send_message": res = tool_send_message(task_id, session_id, fn_args)
                    elif fn_name in plugin_map:
                        res = PLUGINS.call(plugin_map[fn_name][0], plugin_map[fn_name][1], fn_args)
                        if isinstance(res, dict) and res.get("error") == "needs_auth":
                            log_event(task_id, "auth_required", {"plugin": res.get("plugin"), "message": res.get("message")})
                    else: res = {"error": f"Unknown tool {fn_name}"}
                    loop_guard.spend(fn_name, fn_args, int((time.time() - started_at) * 1000))
                    return (tc_id, fn_name, res, int((time.time() - started_at) * 1000))

                def post_tool(tc_id, fn_name, res, duration_ms=None):
                    if fn_name == "request_tools" and isinstance(res, dict) and res.get("enabled"):
                        extra_tools.update(res["enabled"])
                    live_update(task_id, tool=None)
                    log_event(task_id, "tool_result", {"id": tc_id, "tool": fn_name, "result": res, "duration_ms": duration_ms,
                                                       "preview": step_preview(session_id, fn_name, res)})
                    
                    # Tool result formatting: If screenshot produced, include attachment path and format
                    tool_content_str = spill_tool_output(session_id, tc_id, cloud_vault.redact(json.dumps(res, ensure_ascii=False)))
                    messages.append({"role": "tool", "tool_call_id": tc_id, "content": tool_content_str})

                    # If model is vision-capable (e.g. gpt-4o, claude-3, gemini-1.5, qwen-vl) and screenshot generated, inject vision user message
                    if isinstance(res, dict) and res.get("status") == "ok" and res.get("action") == "screenshot":
                        rel_file = res.get("file_path")
                        if rel_file:
                            try:
                                cloud_replay.add_frame(replay_dir(), task_id, os.path.join(get_session_workspace(session_id), rel_file))
                            except Exception as e:
                                note_server_error("replay", e)
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

                    insert_message(session_id, "tool", tool_content_str, tool_call_id=tc_id,
                                   meta={"duration_ms": duration_ms} if duration_ms is not None else None)

                parallel = (len(tool_calls) > 1 and resource_settings().get("parallel_tools", True)
                            and all(((tc.get("function") or {}).get("name")) in PARALLEL_SAFE_TOOLS for tc in tool_calls))
                if parallel:
                    # 互不依赖的只读工具一起执行，结果按原顺序写回
                    from concurrent.futures import ThreadPoolExecutor
                    with ThreadPoolExecutor(max_workers=min(4, len(tool_calls))) as ex:
                        outcomes = list(ex.map(exec_tool, tool_calls))
                    log_event(task_id, "status", {"message": f"并行执行了 {len(tool_calls)} 个工具"})
                    for outcome in outcomes:
                        if outcome is None:
                            final_status = "cancelled"
                            break
                        post_tool(*outcome)
                else:
                    for tc in tool_calls:
                        outcome = exec_tool(tc)
                        if outcome is None:
                            final_status = "cancelled"
                            break
                        post_tool(*outcome)

                if final_status == "cancelled":
                    break
                tf = TURN_FLAGS.get(task_id) or {}
                if tf.get("answered"):
                    answered = True
                if tf.get("end") and not inbox_close(task_id):
                    _post_turn_card(task_id, session_id)    # 选项卡：本轮到此结束，等用户点选
                    break
            elif inbox_close(task_id):
                continue                # 回答完了但用户刚插了话：接着处理新消息
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
        try:
            finish_perf(perf, final_status)
        except Exception as e:
            print(f"perf record failed: {e}", flush=True)
        live_clear(task_id)
        try:
            _flush_ack(task_id, session_id)
            if final_status != "cancelled":
                _post_turn_card(task_id, session_id)    # 选项卡还没写出去（模型之后又说了话）：补上
        except Exception as e:
            print(f"choice card post failed: {type(e).__name__}", flush=True)
        TURN_FLAGS.pop(task_id, None)
        REPLY_BACK_MODEL.pop(task_id, None)
        INSTANT_HANDED.discard(task_id)
        conn = get_db_connection()
        c = conn.cursor()
        c.execute("UPDATE tasks SET status = ? WHERE task_id = ? AND status IN ('running', 'waiting_user')", (final_status, task_id))
        conn.commit()
        conn.close()
        inbox_drop(task_id)     # 状态改完再拆：之后的插话按「任务已结束」返回 409
        with active_tasks_lock:
            active_tasks.pop(task_id, None)
        try:
            if depth == 0:
                on_task_finished(task_id, session_id, final_status)
        except Exception as e:
            print(f"task notify failed: {type(e).__name__}")
        SEARCH_CACHE.invalidate()
        if depth == 0 and final_status == "completed" and answered:
            threading.Thread(target=auto_title, args=(session_id, provider_config, model), daemon=True).start()

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
            "max_runs", "run_count", "next_run_at", "last_run_at", "last_status", "notify", "created_at", "updated_at", "persona_id",
            "reasoning_effort"]
    d = dict(zip(keys, r))
    try: d["schedule"] = json.loads(d["schedule"])
    except Exception: d["schedule"] = {}
    d["enabled"] = bool(d["enabled"])
    d["notify"] = bool(d["notify"])
    return d

ROUTINE_COLUMNS = "routine_id, name, prompt, schedule, credential, model, instructions, enabled, max_runs, run_count, next_run_at, last_run_at, last_status, notify, created_at, updated_at, persona_id, reasoning_effort"

def _validate_schedule_core(schedule):
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
    if kind == "after":
        # 工作流：另一个例行任务跑完后接着跑（拿到它的结果）
        rid = schedule.get("routine_id")
        if not isinstance(rid, str) or not re.match(r"^rtn_[a-f0-9]{12}$", rid):
            raise ValueError("after.routine_id must be a routine id")
        if not get_routine(rid):
            raise ValueError("after.routine_id 指向的例行任务不存在")
        on = schedule.get("on") or "completed"
        if on not in ("completed", "any"):
            raise ValueError("after.on must be completed or any")
        return {"kind": "after", "routine_id": rid, "on": on}
    raise ValueError("schedule.kind must be cron, interval, once or after")

def validate_schedule(schedule):
    out = _validate_schedule_core(schedule)
    w = schedule.get("window_minutes") if isinstance(schedule, dict) else None
    if w not in (None, 0):
        if not isinstance(w, int) or isinstance(w, bool) or not (0 < w <= 180) or out["kind"] == "after":
            raise ValueError("window_minutes must be an integer between 1 and 180 (not for after)")
        out["window_minutes"] = w
    return out

def compute_next_run(schedule, after_ts, first=False):
    """灵活时间窗：在准点之后 window_minutes 分钟内随机挑一个时间（不用每次都卡在 9:00 整）。"""
    t = _compute_next_run_exact(schedule, after_ts, first)
    w = schedule.get("window_minutes")
    if t is not None and w:
        import random
        t += random.uniform(0, w * 60)
    return t

def _compute_next_run_exact(schedule, after_ts, first=False):
    kind = schedule["kind"]
    if kind == "cron":
        return cloud_cron.CronSpec(schedule["expr"]).next_after(after_ts, schedule.get("timezone", "UTC"))
    if kind == "interval":
        return after_ts + schedule["seconds"]
    if kind == "once":
        return schedule["at"] if first else None
    return None     # after：不按时间，由上游任务结束时触发

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
    if "reasoning_effort" in req:
        v = req["reasoning_effort"]
        if v not in (None, "") and v not in cloud_bots.EFFORTS:
            raise ValueError("reasoning_effort must be one of off/low/medium/high/xhigh or null")
        out["reasoning_effort"] = v or None
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
        conn.execute("INSERT INTO routines (" + ROUTINE_COLUMNS + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NULL, NULL, ?, ?, ?, ?, ?)",
                     (rid, fields["name"], fields["prompt"], json.dumps(schedule), fields["credential"], fields["model"],
                      fields.get("instructions"), 1 if enabled else 0, fields.get("max_runs"), next_run,
                      1 if fields.get("notify", True) else 0, now, now, fields.get("persona_id"), fields.get("reasoning_effort")))
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
        conn.execute("UPDATE routines SET name = ?, prompt = ?, schedule = ?, credential = ?, model = ?, instructions = ?, enabled = ?, max_runs = ?, next_run_at = ?, notify = ?, updated_at = ?, persona_id = ?, reasoning_effort = ? WHERE routine_id = ?",
                     (merged["name"], merged["prompt"], json.dumps(merged["schedule"]), merged["credential"], merged["model"],
                      merged.get("instructions"), 1 if merged["enabled"] else 0, merged.get("max_runs"), merged["next_run_at"],
                      1 if merged["notify"] else 0, now, merged.get("persona_id"), merged.get("reasoning_effort"), routine_id))
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

PROACTIVE_SKIP_MARKERS = ("[SKIP]", "[静默]", "[无需打扰]")

QUIET_WHOLE = {"无变化", "没有变化", "暂无变化", "没有新变化", "一切照旧", "no change", "no changes", "(no change)", "（无变化）", "nothing new"}

def is_quiet_result(text):
    """后台唤醒（例行 / 监控）没有值得说的就不发消息：[SKIP] 标记，或整条回复只是「无变化」之类。"""
    t = (text or "").strip()
    if t.strip("。.!！ ").lower() in QUIET_WHOLE or t.lower() in QUIET_WHOLE:
        return True
    return any(t.startswith(m) or t.endswith(m) for m in PROACTIVE_SKIP_MARKERS)

DESKTOP_STREAM_MAX_SECONDS = 15 * 60


def desktop_frame(display, width):
    """推流用的一帧（测试里会替换）；0.2 秒内多个观看者共用同一张截屏。"""
    return cloud_desktop.thumbnail(display, width=width, max_age=0.2)


def token_ok(given):
    """常数时间比较服务 Token，避免按耗时猜出 Token。"""
    return bool(SERVER_TOKEN) and hmac.compare_digest(str(given).encode(), str(SERVER_TOKEN).encode())


def daily_feed(hours=24, limit=20):
    """「今日」：最近 hours 小时例行任务 / 主动消息的结果（Bot 说 [SKIP] 的不算），新的在前。"""
    since = time.time() - hours * 3600
    conn = get_db_connection()
    try:
        rows = conn.execute("SELECT r.run_id, r.session_id, r.result, r.finished_at, t.name, t.persona_id FROM routine_runs r "
                            "JOIN routines t ON t.routine_id = r.routine_id WHERE r.status = 'completed' AND r.finished_at >= ? "
                            "ORDER BY r.finished_at DESC LIMIT ?", (since, limit * 3)).fetchall()
    finally:
        conn.close()
    items = []
    for run_id, sid, result, at, name, bot in rows:
        if not result or is_quiet_result(result):
            continue
        items.append({"run_id": run_id, "session_id": sid, "title": name, "bot_id": bot or "",
                      "proactive": (name or "").startswith("主动消息"), "text": result.strip()[:600], "at": at,
                      "liked": 0, "comment": ""})
        if len(items) >= limit:
            break
    if items:
        conn = get_db_connection()
        try:
            fb = {r[0]: (r[1], r[2]) for r in conn.execute(
                "SELECT run_id, liked, comment FROM feed_feedback WHERE run_id IN (%s)" % ",".join("?" * len(items)), [i["run_id"] for i in items])}
        finally:
            conn.close()
        for i in items:
            if i["run_id"] in fb:
                i["liked"], i["comment"] = fb[i["run_id"]]
    return items


def feed_feedback(run_id, liked, comment):
    """「今日」动态的点赞 / 点踩 / 评论 → 变成这个 Bot 的一条规则记忆（下次做同类内容时参考）；改反馈会替换旧的那条"""
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT r.result, t.name, COALESCE(t.persona_id, '') FROM routine_runs r JOIN routines t ON t.routine_id = r.routine_id "
                           "WHERE r.run_id = ?", (run_id,)).fetchone()
        if not row:
            return None
        result, name, bot = row
        old = conn.execute("SELECT memory_id FROM feed_feedback WHERE run_id = ?", (run_id,)).fetchone()
        if old and old[0]:
            cloud_memory.delete(conn, old[0])
        memory_id = None
        comment = scrub_text((comment or "").strip())[:500]
        if liked or comment:
            verdict = {1: "👍 觉得有用，这类内容可以多给", -1: "👎 不想要这类内容，以后少发或换个方式"}.get(liked, "")
            excerpt = " ".join((result or "").split())[:80]
            text = f"用户对例行任务「{name}」的一次结果的反馈（{time.strftime('%Y-%m-%d')}）：" + "；".join(
                x for x in (verdict, f"评论：{comment}" if comment else "") if x) + f"。那次的内容开头：{excerpt}"
            entry, _ = cloud_memory.write(conn, text, category="rules", source="feedback", persona=bot, commit=False)
            memory_id = entry["id"]
        conn.execute("INSERT INTO feed_feedback (run_id, liked, comment, at, memory_id) VALUES (?, ?, ?, ?, ?) "
                     "ON CONFLICT(run_id) DO UPDATE SET liked = excluded.liked, comment = excluded.comment, at = excluded.at, memory_id = excluded.memory_id",
                     (run_id, liked, comment, time.time(), memory_id))
        conn.commit()
        return {"run_id": run_id, "liked": liked, "comment": comment, "memory_id": memory_id}
    finally:
        conn.close()


def on_routine_finished(routine, run):
    """例行任务结束时推送，异常不影响调度。"""
    if not routine.get("notify", True) or run.get("status") == "skipped" or _bot_muted(persona_id=routine.get("persona_id") or ""):
        return None
    if run.get("status") == "completed" and is_quiet_result(run.get("result")):
        return None     # 主动消息：Bot 觉得这次没什么值得说的，就不打扰
    if run.get("status") == "completed" and on_duty() and (routine.get("name") or "").startswith("主动消息"):
        # 值班中不推送主动消息（失败仍然通知），攒到下班汇总
        _duty_record("proactive", routine.get("name") or "主动消息", run.get("result") or "", bot_id=routine.get("persona_id"),
                     session_id=run.get("session_id"), suppressed=True)
        return None
    cfg = current_notify_config()
    label = {"completed": "完成", "failed": "失败", "limit_reached": "达到轮数上限", "cancelled": "已取消",
             "interrupted": "中断"}.get(run.get("status"), run.get("status"))
    body = (run.get("result") or run.get("error") or "（无文字结果）").strip()[:600]
    user_notify(cfg, "routine_finished", f"例行任务「{routine['name']}」{label}"[:120], body,
                session_id=run.get("session_id"), bot_id=routine.get("persona_id"))

CHAIN_MAX_DEPTH = 3


def chain_depth(trigger):
    m = re.match(r"^after:(\d+)$", str(trigger or ""))
    return int(m.group(1)) if m else 0


def routine_after_creates_cycle(routine_id, upstream_id):
    """工作流画布把 routine_id 接到 upstream_id 后面：顺着 upstream 往上找，碰到自己就是圈（2.32.1）"""
    cur, seen = upstream_id, set()
    while cur and cur not in seen:
        if cur == routine_id:
            return True
        seen.add(cur)
        r = get_routine(cur)
        sch = (r or {}).get("schedule") or {}
        cur = sch.get("routine_id") if sch.get("kind") == "after" else None
    return False


def fire_followups(routine, run):
    """上游例行任务结束后，启动 schedule.kind == after 且指向它的任务；最多连 3 层，防止循环。"""
    depth = chain_depth(run.get("trigger")) + 1
    if depth > CHAIN_MAX_DEPTH or run.get("status") == "skipped":
        return []
    if run.get("status") == "completed" and is_quiet_result(run.get("result")):
        return []
    started = []
    for r in list_routines():
        sch = r.get("schedule") or {}
        if not r.get("enabled") or sch.get("kind") != "after" or sch.get("routine_id") != routine["routine_id"]:
            continue
        if sch.get("on", "completed") == "completed" and run.get("status") != "completed":
            continue
        ctx = (run.get("result") or run.get("error") or "").strip()[:6000]
        started.append(launch_routine_run(r, trigger=f"after:{depth}",
                                          context=f"上一步「{routine['name']}」{'完成' if run.get('status') == 'completed' else '结束（' + str(run.get('status')) + '）'}，结果：\n{ctx}"))
    return started


WEEKLY_STATS_TOKEN = "{{weekly_stats}}"
NEGATIVE_EMOJI = ("👎", "😡", "😤", "🙄", "😒", "❌", "💩")


def weekly_stats(bot_id, days=7, now=None):
    """「每周自我改进」用的本周数据：任务数和失败、用户给的赞踩和评论、对回答点的负面表情（附那条回答开头）。不含其它对话内容。"""
    now = now or time.time()
    since = now - days * 86400
    bot = bot_id or ""
    conn = get_db_connection()
    try:
        st = dict(conn.execute("SELECT t.status, COUNT(*) FROM tasks t JOIN sessions s ON s.session_id = t.session_id "
                               "WHERE COALESCE(s.persona_id, '') = ? AND t.created_at >= ? GROUP BY t.status", (bot, since)).fetchall())
        fb = conn.execute("SELECT f.liked, f.comment, t.name FROM feed_feedback f JOIN routine_runs r ON r.run_id = f.run_id "
                          "JOIN routines t ON t.routine_id = r.routine_id WHERE COALESCE(t.persona_id, '') = ? AND f.at >= ?", (bot, since)).fetchall()
        neg = conn.execute("SELECT x.emoji, m.content FROM message_reactions x JOIN messages m ON m.id = x.message_id "
                           "JOIN sessions s ON s.session_id = x.session_id WHERE x.actor = 'user' AND COALESCE(s.persona_id, '') = ? "
                           "AND x.at >= ? AND m.role = 'assistant'", (bot, since)).fetchall()
        errs = conn.execute("SELECT e.payload FROM task_events e JOIN tasks t ON t.task_id = e.task_id JOIN sessions s ON s.session_id = t.session_id "
                            "WHERE e.event_type = 'error' AND COALESCE(s.persona_id, '') = ? AND e.timestamp >= ? ORDER BY e.id DESC LIMIT 5", (bot, since)).fetchall()
    finally:
        conn.close()
    total = sum(st.values())
    lines = [f"本周（{days} 天）任务 {total} 个：完成 {st.get('completed', 0)}，失败 {st.get('failed', 0)}，达到轮数上限 {st.get('limit_reached', 0)}，被取消 {st.get('cancelled', 0)}。"]
    likes = sum(1 for f in fb if f[0] == 1)
    dislikes = sum(1 for f in fb if f[0] == -1)
    if fb:
        lines.append(f"「今日」动态反馈：👍 {likes}，👎 {dislikes}。")
        lines += [f"· 「{n}」{'👍' if l == 1 else '👎' if l == -1 else ''} {c}".rstrip() for l, c, n in fb if c or l == -1][:8]
    bad = [(e, c) for e, c in neg if e in NEGATIVE_EMOJI]
    if bad:
        lines.append(f"用户对 {len(bad)} 条回答点了负面表情，那几条的开头：")
        lines += [f"· {e} {' '.join(str(c or '').split())[:80]}" for e, c in bad[:6]]
    for (payload,) in errs:
        try:
            lines.append("· 出错：" + scrub_text(str((json.loads(payload or "{}") or {}).get("error") or ""))[:120])
        except ValueError:
            pass
    if total == 0 and not fb and not bad:
        lines.append("本周没有足够的数据。")
    return scrub_text("\n".join(lines))


def launch_routine_run(routine, trigger="schedule", context=None):
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
    if routine.get("reasoning_effort"):
        TASK_EFFORT[tid] = routine["reasoning_effort"]
    instructions = routine.get("instructions") or ROUTINE_DEFAULT_INSTRUCTIONS
    fired = time.strftime("%Y-%m-%d %H:%M:%S %z", time.localtime(now))
    how = "手动运行" if trigger == "manual" else ("上一步完成后" if chain_depth(trigger) else "按计划")
    prompt = routine['prompt']
    if WEEKLY_STATS_TOKEN in prompt:
        try:
            prompt = prompt.replace(WEEKLY_STATS_TOKEN, weekly_stats(routine.get("persona_id") or ""))
        except Exception as e:
            prompt = prompt.replace(WEEKLY_STATS_TOKEN, f"（本周数据没取到：{type(e).__name__}）")
    content = f"[例行任务「{routine['name']}」于 {fired} 触发（{how}）]\n{prompt}"
    if context:
        content += "\n\n[工作流上一步的结果]\n" + context
    conn = get_db_connection()
    try:
        c = conn.cursor()
        c.execute("INSERT INTO sessions (session_id, local_session_id, title, instructions, created_at, persona_id) VALUES (?, NULL, ?, ?, ?, ?)",
                  (sid, "例行任务：" + routine["name"], instructions, now, routine.get("persona_id")))
        c.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, NULL, 'running', ?, ?)",
                  (tid, sid, routine["model"], now))
        # 例行任务 / 主动消息的提示词是发给模型的，不是用户说的：标 internal，App 不画成用户气泡
        c.execute("INSERT INTO messages (session_id, role, content, timestamp, meta) VALUES (?, 'user', ?, ?, ?)",
                  (sid, content, now, json.dumps({"internal": "routine"})))
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
            try:
                fire_followups(routine, {"status": final, "result": result, "error": err, "trigger": trigger})
            except Exception as e:
                print(f"[routine] follow-up failed: {type(e).__name__}", flush=True)

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
            note_server_error("routine_launch", e)
    return runs

def _scheduler_main():
    while not _scheduler_stop.wait(SCHEDULER_TICK):
        try:
            scheduler_tick()
        except Exception as e:
            sys.stderr.write(f"[routine] scheduler error: {sanitize_err(e)}\n")
            note_server_error("scheduler", e)
        try:
            duty_check()
        except Exception as e:
            sys.stderr.write(f"[duty] check error: {sanitize_err(e)}\n")
            note_server_error("duty", e)
        try:
            events_check()
        except Exception as e:
            sys.stderr.write(f"[events] check error: {sanitize_err(e)}\n")
            note_server_error("events", e)
        try:
            relay_watch_check()
        except Exception as e:
            sys.stderr.write(f"[relay] watch error: {sanitize_err(e)}\n")
            note_server_error("relay_watch", e)

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
    bot = get_persona(cfg.get("_channel")) if cfg.get("_channel") else None
    if bot and bot.get("model") and bot.get("credential"):
        # Bot 自己选了模型：它的 Telegram 渠道也跟着用（思考深度由 session 所属 Bot 决定）
        cfg = dict(cfg, model=bot["model"], credential=bot["credential"])
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
    if text:
        events_on_telegram(text)
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
    if isinstance(body, dict) and existing and "proxy" not in body and existing.get("proxy"):
        body = dict(body, proxy=existing["proxy"])  # 未提交 proxy 字段时沿用；提交空字符串表示清除
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
        if e.kind == "unauthorized":
            return 400, {"error": "Bot Token 无效（Telegram 返回 401 Unauthorized）：请在 @BotFather 重新复制完整 Token", "error_kind": "unauthorized"}
        if e.kind == "network":
            via = "代理" if cfg.get("proxy") else ("自定义 API 地址" if cfg.get("api_base") != "https://api.telegram.org" else "api.telegram.org")
            hint = ("请检查代理地址与端口是否可用" if cfg.get("proxy")
                    else "云电脑可能无法直连 Telegram（例如中国大陆的 VPS）：请在 Telegram 设置里填写代理（http / https / socks5）或自建 Bot API 地址后重试")
            return 502, {"error": f"云电脑连不上 Telegram（经 {via}：{e}）。{hint}", "error_kind": "network"}
        return 502, {"error": "Telegram 校验失败：" + str(e), "error_kind": "other"}
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

TRANSCRIPT_MAX_LINES = 400
TRANSCRIPT_MAX_CHARS = 8000


_transcript_nonces = collections.OrderedDict()
_transcript_lock = threading.Lock()


def session_append_transcript(sid, lines, nonce=None):
    """把实时语音通话的文字记录追加到会话（不触发 Agent 运行）。
    返回写入条数；会话不存在返回 None；格式不对抛 ValueError。"""
    if not isinstance(lines, list) or not lines:
        raise ValueError("lines must be a non-empty list")
    if len(lines) > TRANSCRIPT_MAX_LINES:
        raise ValueError(f"too many lines (max {TRANSCRIPT_MAX_LINES})")
    rows = []
    for item in lines:
        if not isinstance(item, dict):
            raise ValueError("each line must be an object")
        role = item.get("role")
        text = item.get("text")
        if role not in ("user", "assistant") or not isinstance(text, str):
            raise ValueError("line needs role user/assistant and string text")
        text = text.strip()[:TRANSCRIPT_MAX_CHARS]
        if not text:
            continue
        if item.get("interrupted") is True:
            text += "（被打断）"
        rows.append((role, text))
    key = (sid, nonce) if isinstance(nonce, str) and nonce else None
    if key:
        with _transcript_lock:
            if key in _transcript_nonces:
                return 0   # 重试：上一次已经写入
            _transcript_nonces[key] = True
            while len(_transcript_nonces) > 500:
                _transcript_nonces.popitem(last=False)
    ok = False
    conn = get_db_connection()
    try:
        if not conn.execute("SELECT 1 FROM sessions WHERE session_id = ?", (sid,)).fetchone():
            return None
        now = time.time()
        # 同一时刻写入的多条用递增的微小间隔保持顺序
        for i, (role, text) in enumerate(rows):
            conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
                         (sid, role, text, now + i * 0.001))
        conn.commit()
        ok = True
        return len(rows)
    finally:
        conn.close()
        if key and not ok:
            with _transcript_lock:
                _transcript_nonces.pop(key, None)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        gz = len(body) > 4096 and "gzip" in (self.headers.get("Accept-Encoding") or "")
        if gz:
            body = gzip.compress(body, 5)   # 大响应压缩，经 SSH 隧道传得更快
        self.send_response(code)
        if gz:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed_url = urlparse(self.path)
        path = parsed_url.path
        query_params = parse_qs(parsed_url.query)

        if path == "/livez":
            self._send(200, {"status": "ok", "agent_version": AGENT_VERSION})
            return

        if path == "/health":
            self._send(200, {
                "status": "ok",
                "service": "openminis-cloud-agent",
                "mode": "cloud-computer",
                "version": "2.0.0",
                "agent_version": AGENT_VERSION,
                "desktop": _desktop_health_brief(),
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
                    "delegation": True,
                    "group_chat": True,
                    "event_longpoll": True,
                    "streaming": True,
                    "perf": True,
                    "plugins": True,
                    "reply_modes": True
                },
                "timestamp": time.time()
            })
            return

        # Attachment download endpoint with path security & Bearer auth
        if "/attachments/" in path:
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer ") or not token_ok(auth[7:].strip()):
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
        if not auth.startswith("Bearer ") or not token_ok(auth[7:].strip()):
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
            try:
                pdir = {"path": PLUGINS.writable_plugin_dir(), "writable": True, "note": PLUGINS.dir_note}
            except cloud_plugins.PluginError as e:
                pdir = {"path": PLUGINS.plugin_dir, "writable": False, "note": str(e)}
            self._send(200, {"installed": installed, "catalog": cat, "plugin_dir": pdir})
            return

        if path == "/v1/plugins/deps":
            self._send(200, {"tools": cloud_deps.status()})
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

        if path == "/v1/vault" or path.startswith("/v1/vault/"):
            self._vault("GET", path, query_params, None)
            return
        if path == "/v1/workers" or path.startswith("/v1/workers/"):
            self._workers("GET", path, query_params, None)
            return
        if self._reply("GET", path, None):
            return
        if path == "/v1/bot_sections":
            conn = get_db_connection()
            try:
                self._send(200, {"sections": cloud_admin.sections(conn)})
            finally:
                conn.close()
            return
        if path == "/v1/bots/trash":
            conn = get_db_connection()
            try:
                self._send(200, {"trash": cloud_admin.trash(conn)})
            finally:
                conn.close()
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

        if path.startswith("/v1/bots/") and path.endswith("/library"):
            bid = path[len("/v1/bots/"):-len("/library")]
            if not get_persona(bid):
                self._send(404, {"error": "Bot not found"})
                return
            self._send(200, {"items": bot_library(bid)})
            return

        m_av = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31})/avatar$", path)
        if m_av:
            p = avatar_path(m_av.group(1))
            if not get_persona(m_av.group(1)) or not os.path.isfile(p):
                self._send(404, {"error": "没有照片头像"})
                return
            with open(p, "rb") as f:
                data = f.read()
            self._send(200, {"data_base64": base64.b64encode(data).decode(), "hash": hashlib.sha256(data).hexdigest()[:10]})
            return

        m_media = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31})/library/media/(\d+)/(\d+)$", path)
        if m_media:
            url = library_media(m_media.group(1), int(m_media.group(2)), int(m_media.group(3)))
            if not url:
                self._send(404, {"error": "Media not found"})
                return
            self._send(200, {"url": url})
            return

        if path == "/v1/workbench":
            # 工作台：所有 Bot 在跑 / 等你的任务（App 可逐个或批量 POST /v1/tasks/<id>/cancel）
            conn = get_db_connection()
            try:
                items = cloud_workbench.items(conn, lambda sid: session_bot(sid), _session_title)
            finally:
                conn.close()
            self._send(200, {"items": items, "running": sum(1 for i in items if i["status"] == "running"),
                             "waiting_you": sum(1 for i in items if i["status"] == "waiting_user")})
            return

        if path == "/v1/shift-card":
            # 交班卡：最近 N 小时（默认 12）各 Bot 的对话、在跑 / 等你 / 没回的事（纯查库，不调模型）
            try:
                hours = int((query_params.get("hours") or ["12"])[0])
            except ValueError:
                self._send(400, {"error": "hours 必须是整数"})
                return
            conn = get_db_connection()
            try:
                card = cloud_shift_card.build(conn, hours, lambda sid: session_bot(sid), skip_session=session_incognito)
            finally:
                conn.close()
            self._send(200, card)
            return

        if path == "/v1/notifications":
            # App 在线时长轮询：取走新的通知，用系统本地通知显示（同时算作 App 在线，服务器就不再发 Bark）
            try:
                after = int((query_params.get("after") or ["0"])[0])
                wait_s = float((query_params.get("wait") or ["0"])[0])
            except ValueError:
                self._send(400, {"error": "after / wait 必须是数字"})
                return
            APP_FEED.touch()
            items, last = APP_FEED.wait_after(after, wait_s)
            APP_FEED.touch()
            self._send(200, {"items": items, "last_id": last})
            return

        if path == "/v1/browser/snapshots":
            self._send(200, {"snapshots": cloud_snapshots.listing(os.path.dirname(DB_PATH))})
            return

        if path == "/v1/desktop/focus":
            # 智能键盘：主屏浏览器里当前焦点是不是输入框 / 密码框（只给类型，从不给内容）
            if not cloud_browser.is_browser_available():
                self._send(200, {"editable": False, "password": False, "kind": "", "available": False})
                return
            r = cloud_browser.execute_browser_action("shared", SHARED_WORKSPACE, {"action": "__focus__"})
            r = r if isinstance(r, dict) else {}
            self._send(200, {"editable": bool(r.get("editable")), "password": bool(r.get("password")),
                             "kind": str(r.get("kind") or "")[:20], "available": r.get("status") == "ok"})
            return

        if path == "/v1/desktop/files":
            # 云电脑「下载」文件夹里最近的文件（取回手机用）
            self._send(200, {"files": cloud_desktop_files.listing()})
            return

        if path.startswith("/v1/desktop/files/"):
            fid = path[len("/v1/desktop/files/"):]
            if not re.match(r"^[a-f0-9]{12}$", fid):
                self._send(400, {"error": "bad id"})
                return
            try:
                name, data = cloud_desktop_files.read(fid)
            except ValueError as e:
                self._send(413, {"error": str(e)})
                return
            if name is None:
                self._send(404, {"error": "文件不在了"})
                return
            self._send(200, {"name": name, "bytes": len(data), "data_base64": _B64.b64encode(data).decode()})
            return

        if path == "/v1/desktop/health":
            # 手机打开桌面页前先查链路；独立屏幕挂了会在这里自动重启
            bid = (query_params.get("bot_id") or [None])[0]
            display, port, token, own = cloud_displays.MAIN_DISPLAY, 5901, "main", False
            if bid and get_persona(bid) and iso.bot_settings(resource_settings(), bid)["browser_profile"] == "per_bot":
                info = DISPLAYS.ensure(bid)
                if info:
                    display, port, token, own = info["display"], info["vnc_port"], info["token"], True
            h = cloud_displays.diagnose(display, port, token)
            if bid and not own and DISPLAYS.last_error:
                h["display_error"] = DISPLAYS.last_error
            h.update({"display": display, "token": token, "own_display": own,
                      "token_proxy": h["websockify_mode"] == "token" if h["websockify_mode"] else cloud_displays.token_proxy_enabled(),
                      "tools": cloud_desktop.is_desktop_available(), "user_control": DESK_CONTROL.held(display)})
            self._send(200, h)
            return

        if path == "/v1/desktop/stream":
            self._desktop_stream(query_params)
            return

        if path == "/v1/desktop/thumbnail":
            # 对话里的电脑小预览：只看已经在跑的屏幕，不为预览专门启动独立屏幕
            bid = (query_params.get("bot_id") or [None])[0]
            display = cloud_displays.MAIN_DISPLAY
            if bid and get_persona(bid):
                info = DISPLAYS.info(bid)
                if info:
                    display = info["display"]
                    DISPLAYS.touch(bid)
            try:
                width = max(120, min(int((query_params.get("width") or ["480"])[0]), 1920))
            except ValueError:
                self._send(400, {"error": "width must be a number"})
                return
            data, mime = cloud_desktop.thumbnail(display, width=width)
            if data is None:
                self._send(503, {"error": mime})
                return
            self._send(200, {"data_base64": base64.b64encode(data).decode(), "mime": mime, "display": display, "at": time.time()})
            return

        if path == "/v1/desktop/status":
            conn = get_db_connection()
            try:
                running = conn.execute("SELECT COUNT(*) FROM tasks WHERE status IN ('running', 'queued')").fetchone()[0]
            finally:
                conn.close()
            self._send(200, {"available": cloud_desktop.is_desktop_available(), "busy": running > 0, "running_tasks": running,
                             "token_proxy": cloud_displays.token_proxy_enabled(), "displays": DISPLAYS.list()})
            return

        if path == "/v1/audit":
            bot = (query_params.get("bot") or [None])[0]
            conn = get_db_connection()
            try:
                items = cloud_audit.list_entries(conn, bot_id=bot)
            finally:
                conn.close()
            self._send(200, {"items": items})
            return

        if path == "/v1/feed":
            self._send(200, {"items": daily_feed()})
            return

        m_snap = re.match(r"^/v1/snapshots/(snap_[a-f0-9]{12})$", path)
        if m_snap:
            snap = get_snapshot(m_snap.group(1))
            self._send(200 if snap else 404, snap or {"error": "没有这个快照"})
            return
        m_snaps = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31}|_default)/snapshots$", path)
        if m_snaps:
            pid = "" if m_snaps.group(1) == "_default" else m_snaps.group(1)
            q = (parse_qs(urlparse(self.path).query).get("q") or [None])[0]
            self._send(200, {"snapshots": list_snapshots(pid, q, limit=50)})
            return
        if path == "/v1/proxy":
            try:
                self._send(200, proxy_mgr().status())
            except Exception as e:
                self._send(500, {"error": f"读取代理设置失败：{type(e).__name__}"})
            return
        if path == "/v1/event-triggers":
            conn = get_db_connection()
            try:
                self._send(200, {"triggers": cloud_events.list_all(conn)})
            finally:
                conn.close()
            return
        if path == "/v1/exams":
            conn = get_db_connection()
            try:
                self._send(200, {"exams": cloud_exams.list_all(conn)})
            finally:
                conn.close()
            return
        if path == "/v1/logs/errors":
            self._send(200, {"version": AGENT_VERSION, "errors": error_log()})
            return
        if path == "/v1/system-snapshots":
            self._send(200, {"snapshots": cloud_sysnap.list_all(sysnap_dir())})
            return
        m = re.match(r"^/v1/system-snapshots/([0-9-]{10,32})/plan$", path)
        if m:
            p = cloud_sysnap.plan(sysnap_dir(), m.group(1))
            self._send(200 if p else 404, {"plan": p} if p else {"error": "没有这个快照"})
            return
        if path == "/v1/relays/watch":
            cfg = relay_watch_config()
            self._send(200, {"watch": {k: cfg.get(k) for k in ("credential", "model", "hours", "last_run", "history")}})
            return
        if path == "/v1/duty/digest":
            conn = get_db_connection()
            try:
                self._send(200, {"digest": cloud_duty.latest(conn), "on_duty": on_duty()})
            finally:
                conn.close()
            return
        if path == "/v1/resources":
            specs = iso.server_specs(GLOBAL_WORKSPACE)
            self._send(200, {"settings": resource_settings(), "defaults": iso.DEFAULTS, "specs": specs,
                             "recommended": iso.recommend(specs), "usage": resource_usage(),
                             "per_bot_display": cloud_displays.DisplayManager.available()})
            return

        if path == "/v1/live-stats":
            self._send(200, LIVE_STATS.sample(GLOBAL_WORKSPACE, GATE.status()))
            return

        if path == "/v1/queue":
            self._send(200, GATE.status())
            return

        if path == "/v1/groups":
            conn = get_db_connection()
            try:
                groups = cloud_groups.list_groups(conn)
            finally:
                conn.close()
            for g in groups:
                g["typing"] = GROUPS.typing_list(g["group_id"])
            self._send(200, {"groups": groups})
            return

        m_grp = re.match(r"^/v1/groups/(grp_[a-f0-9]{10})(/messages)?$", path)
        if m_grp:
            gid = m_grp.group(1)
            conn = get_db_connection()
            try:
                g = cloud_groups.get_group(conn, gid)
                if not g:
                    self._send(404, {"error": "Group not found"})
                    return
                if not m_grp.group(2):
                    payload = group_payload(conn, g, 0)
                    self._send(200, payload)
                    return
            finally:
                conn.close()
            try:
                after = int((query_params.get("after") or ["0"])[0])
                wait = float((query_params.get("wait") or ["0"])[0])
            except ValueError:
                self._send(400, {"error": "after / wait 必须是数字"})
                return
            msgs, typing = GROUPS.wait_for(gid, after, wait) if wait > 0 else (None, GROUPS.typing_list(gid))
            if msgs is None:
                conn = get_db_connection()
                try:
                    msgs = cloud_groups.messages_after(conn, gid, after)
                finally:
                    conn.close()
            self._send(200, {"messages": msgs, "typing": typing})
            return

        if path == "/v1/search":
            q = ((query_params.get("q") or [""])[0]).strip()
            if not q or len(q) > 100:
                self._send(400, {"error": "q 必须是 1–100 个字符"})
                return
            hit = SEARCH_CACHE.get(q)
            if hit is None:
                hit = search_everything(q)
                SEARCH_CACHE.put(q, hit)
            self._send(200, {"results": hit})
            return

        if path == "/v1/models/effort":
            # 哪些模型的服务商不接受思考参数（自动去掉后记住的），手机在「模型与思考深度」里给出提示
            self._send(200, {"unsupported": sorted({m for _u, m in _EFFORT_UNSUPPORTED if m}),
                             "styles": {m: effort_styles(m)[min(i, len(effort_styles(m)) - 1)] for (_u, m), i in _EFFORT_STYLE.items() if m}})
            return

        if path == "/v1/perf":
            recs = list(PERF)[-50:]
            def med(key):
                vals = sorted(r[key] for r in recs if isinstance(r.get(key), (int, float)))
                return vals[len(vals) // 2] if vals else None
            self._send(200, {"recent": list(reversed(recs)),
                             "median": {k: med(k) for k in ("ttft_ms", "first_text_ms", "total_ms", "queued_ms", "prompt_tokens", "completion_tokens", "cached_tokens", "tool_defs")},
                             "pool": dict(cloud_llm.POOL.stats),
                             "settings": {k: resource_settings().get(k) for k in ("stream", "lazy_tools", "parallel_tools", "prompt_cache", "context_trim_tokens",
                                                                  "auto_title", "auto_model", "quick_ack", "fast_model", "vision_model", "strong_model", "failover", "duty_until")}})
            return

        if path == "/v1/usage":
            try:
                days = max(1, min(int((query_params.get("days") or ["14"])[0]), 90))
            except ValueError:
                days = 14
            conn = get_db_connection()
            try:
                s = cloud_usage.summary(conn, days)
            finally:
                conn.close()
            rs = resource_settings()
            s["daily_token_cap"] = rs.get("daily_token_cap", 0)
            s["usage_alert_percent"] = rs.get("usage_alert_percent", 80)
            s["bot_names"] = {p["persona_id"]: p["name"] for p in list_personas()}
            self._send(200, s)
            return

        if path == "/v1/backup":
            self._send(200, make_backup((query_params.get("messages") or ["1"])[0] != "0"))
            return

        if path == "/v1/bot-threads":
            bid = (query_params.get("bot_id") or [None])[0]
            conn = get_db_connection()
            try:
                self._send(200, {"threads": cloud_botthreads.threads(conn, bid, _thread_names())})
            finally:
                conn.close()
            return

        m_bt = re.match(r"^/v1/bot-threads/([a-z0-9_][a-z0-9_-]{0,31})/([a-z0-9_][a-z0-9_-]{0,31})$", path)
        if m_bt:
            # 只读线程；after + wait 长轮询（新消息 / 状态变化立刻返回）
            try:
                after = int((query_params.get("after") or ["0"])[0])
                wait_s = max(0.0, min(25.0, float((query_params.get("wait") or ["0"])[0])))
            except ValueError:
                self._send(400, {"error": "after / wait must be numbers"})
                return
            deadline = time.time() + wait_s
            seen_working = (query_params.get("working") or [None])[0]
            while True:
                conn = get_db_connection()
                try:
                    out = cloud_botthreads.thread(conn, m_bt.group(1), m_bt.group(2), after)
                finally:
                    conn.close()
                remaining = deadline - time.time()
                if out["messages"] or remaining <= 0 or (seen_working is not None and ",".join(out["working"]) != seen_working):
                    break
                with EVENT_COND:
                    EVENT_COND.wait(min(remaining, 5.0))
            out["names"] = _thread_names()
            self._send(200, out)
            return

        m_sbt = re.match(r"^/v1/sessions/([A-Za-z0-9_-]{1,64})/bot-threads$", path)
        if m_sbt:
            conn = get_db_connection()
            try:
                rows = cloud_botthreads.session_summary(conn, m_sbt.group(1))
            finally:
                conn.close()
            names = _thread_names()
            for r in rows:
                r["peer_name"] = names.get(r["peer"], r["peer"])
                r["label"] = cloud_botthreads.collapsed_label(r["count"], r["peer_name"])
            self._send(200, {"threads": rows})
            return

        if path == "/v1/delegations":
            sid = (query_params.get("session_id") or [None])[0]
            items = list_delegations(sid)
            for it in items:
                for k in ("from_bot", "to_bot"):
                    it[k.replace("bot", "name")] = _bot_label(get_persona(it[k])) if it[k] else "主助手"
            self._send(200, {"delegations": items})
            return

        m_ver = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31})/versions$", path)
        if m_ver:
            conn = get_db_connection()
            try:
                if not cloud_bots.get(conn, m_ver.group(1)):
                    self._send(404, {"error": "Bot not found"})
                    return
                self._send(200, {"versions": cloud_bots.versions(conn, m_ver.group(1))})
            finally:
                conn.close()
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
                    entries = cloud_memory.list_entries(conn, since=float(since) if since else None, source=qp("source"), limit=int(qp("limit", "200")),
                                                        persona=qp("bot"), include_shared=qp("shared", "1") != "0")
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
                c.execute("SELECT session_id, local_session_id, title, created_at, persona_id FROM sessions WHERE persona_id = ? AND COALESCE(incognito, 0) = 0 "
                          "AND session_id NOT IN (SELECT worker_session FROM bot_workers) ORDER BY created_at DESC", (bot_filter,))
            else:
                c.execute("SELECT session_id, local_session_id, title, created_at, persona_id FROM sessions WHERE COALESCE(incognito, 0) = 0 "
                          "AND session_id NOT IN (SELECT worker_session FROM bot_workers) ORDER BY created_at DESC")
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
                c.execute("SELECT session_id, local_session_id, title, instructions, created_at, COALESCE(incognito, 0) FROM sessions WHERE session_id = ?", (sid,))
                s = c.fetchone()
                if not s:
                    conn.close()
                    self._send(404, {"error": "Session not found"})
                    return
                # 分页（2.32.0）：带 limit 时只回最近 limit 条（before_id 之前），并告诉手机还有没有更早的；不带时照旧全回
                page_limit = page_before = None
                try:
                    if query_params.get("limit"):
                        page_limit = max(1, min(int(query_params["limit"][0]), 1000))
                    if query_params.get("before_id"):
                        page_before = int(query_params["before_id"][0])
                except ValueError:
                    conn.close()
                    self._send(400, {"error": "limit / before_id must be integers"})
                    return
                if page_limit:
                    c.execute("SELECT role, content, tool_calls, tool_call_id, timestamp, meta, id FROM messages WHERE session_id = ? AND id < ? "
                              "ORDER BY id DESC LIMIT ?", (sid, page_before if page_before is not None else 2 ** 62, page_limit + 1))
                    page_rows = c.fetchall()
                    has_more = len(page_rows) > page_limit
                    page_rows = list(reversed(page_rows[:page_limit]))
                else:
                    c.execute("SELECT role, content, tool_calls, tool_call_id, timestamp, meta, id FROM messages WHERE session_id = ? ORDER BY id ASC", (sid,))
                    page_rows = c.fetchall()
                    has_more = False
                reactions = cloud_runmodel.reactions_for(conn, sid)
                msgs = []
                for mr in page_rows:
                    m = {"id": mr[6], "role": mr[0], "content": mr[1], "timestamp": mr[4]}
                    if mr[6] in reactions:
                        m["reactions"] = reactions[mr[6]]
                    if mr[5]:
                        try:
                            meta = json.loads(mr[5])
                            for k in ("reasoning", "duration_ms", "injected", "snapshot_id", "title", "internal"):
                                if k in meta:
                                    m[k] = meta[k]
                            m.update(cloud_runmodel.public_meta(meta))
                        except ValueError:
                            pass
                    if mr[2]:
                        try: m["tool_calls"] = json.loads(mr[2])
                        except: pass
                    if mr[3]:
                        m["tool_call_id"] = mr[3]
                    msgs.append(m)
                c.execute("SELECT task_id, status, model, created_at FROM tasks WHERE session_id = ? ORDER BY created_at DESC", (sid,))
                tasks = [{"task_id": tr[0], "status": tr[1], "model": tr[2], "created_at": tr[3]} for tr in c.fetchall()]
                # 每个任务的耗时（首字、总时长、token），手机长按消息时显示
                timing_rows = c.execute("SELECT e.task_id, e.payload FROM task_events e JOIN tasks t ON t.task_id = e.task_id "
                                        "WHERE t.session_id = ? AND e.event_type = 'timings'", (sid,)).fetchall()
                tmap = {}
                for tid_, pl in timing_rows:
                    try:
                        p = json.loads(pl)
                        tmap[tid_] = {k: p.get(k) for k in ("first_text_ms", "ttft_ms", "total_ms", "queued_ms", "llm_calls", "prompt_tokens", "completion_tokens", "streamed")}
                    except ValueError:
                        pass
                for t_ in tasks:
                    if t_["task_id"] in tmap:
                        t_["timings"] = tmap[t_["task_id"]]
                try:
                    _rp = session_reply_view(conn, sid, session_persona_id(sid))
                except Exception as e:
                    print(f"reply view failed: {type(e).__name__}", flush=True)
                    _rp = None
                conn.close()
                self._send(200, {"session_id": s[0], "local_session_id": s[1], "title": s[2], "instructions": s[3], "created_at": s[4], "messages": msgs, "tasks": tasks,
                                 "incognito": bool(s[5]), "has_more": has_more, "reply": _rp})
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

        if path == "/v1/replays":
            self._send(200, {"replays": cloud_replay.list_tasks(replay_dir())})
            return

        m_rp = re.match(r"^/v1/tasks/([A-Za-z0-9_-]{1,64})/replay(?:/(\d{1,4}))?$", path)
        if m_rp:
            tid = m_rp.group(1)
            if m_rp.group(2) is None:
                self._send(200, {"task_id": tid, "frames": cloud_replay.frames(replay_dir(), tid)})
                return
            data, mime = cloud_replay.frame_bytes(replay_dir(), tid, int(m_rp.group(2)))
            if data is None:
                self._send(404, {"error": "Frame not found"})
                return
            self._send(200, {"mime": mime, "image_b64": base64.b64encode(data).decode("ascii")})
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

            try:
                wait_s = max(0.0, min(25.0, float(query_params.get("wait", ["0"])[0])))
                live_after = int(query_params.get("live_after", ["-1"])[0])
            except ValueError:
                self._send(400, {"error": "wait / live_after must be numbers"})
                return
            # 长轮询：没有新事件也没有新的流式文字时挂起，有更新立刻返回（比定时轮询省流量、首字更早）
            deadline = time.time() + wait_s
            while True:
                conn = get_db_connection()
                c = conn.cursor()
                c.execute("SELECT task_id, session_id, status, model, created_at FROM tasks WHERE task_id = ?", (tid,))
                t = c.fetchone()
                if not t:
                    conn.close()
                    self._send(404, {"error": "Task not found"})
                    return
                c.execute("SELECT id, event_type, payload, timestamp FROM task_events WHERE task_id = ? AND id > ? ORDER BY id ASC", (tid, after_cursor))
                rows_ev = c.fetchall()
                conn.close()
                live = live_get(tid)
                fresh_live = live_has_content(live) and live["seq"] > live_after
                remaining = deadline - time.time()
                if rows_ev or fresh_live or t[2] not in ("queued", "running") or remaining <= 0:
                    break
                with EVENT_COND:
                    EVENT_COND.wait(min(remaining, 5.0))
            events = []
            max_id = after_cursor
            for er in rows_ev:
                eid, etype, payload_str, etime = er
                max_id = max(max_id, eid)
                try: pl = json.loads(payload_str)
                except: pl = {"raw": payload_str}
                events.append({"monotonic_id": eid, "id": eid, "type": etype, "payload": pl, "timestamp": etime})
            out = {
                "task_id": t[0],
                "session_id": t[1],
                "status": t[2],
                "model": t[3],
                "created_at": t[4],
                "last_cursor": max_id,
                "events": events
            }
            # 只发比手机已有的更新的草稿；旧草稿反复下发会和已写入的文字叠在一起
            if live_has_content(live) and live["seq"] > live_after:
                out["live"] = live
            self._send(200, out)
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

    def _desktop_stream(self, query_params):
        """WebSocket：把云电脑画面按 1–5 帧/秒推给手机（画面没变就不发），最长 15 分钟，手机关掉预览就结束。"""
        key = self.headers.get("Sec-WebSocket-Key", "")
        if self.headers.get("Upgrade", "").lower() != "websocket" or not cloud_ws.valid_key(key):
            self._send(400, {"error": "需要 WebSocket 连接"})
            return
        bid = (query_params.get("bot_id") or [None])[0]
        display = cloud_displays.MAIN_DISPLAY
        if bid and get_persona(bid):
            info = DISPLAYS.info(bid)
            if info:
                display = info["display"]
        try:
            fps = min(5.0, max(1.0, float((query_params.get("fps") or ["3"])[0])))
        except ValueError:
            fps = 3.0
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", cloud_ws.accept_key(key))
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        sock = self.connection
        deadline = time.time() + DESKTOP_STREAM_MAX_SECONDS
        last_digest, last_send, misses = None, time.time(), 0
        try:
            while time.time() < deadline:
                started = time.time()
                readable, _, _ = select.select([sock], [], [], 0)
                if readable:
                    frame = cloud_ws.read_frame(self.rfile)
                    if frame is None or frame[0] == cloud_ws.OP_CLOSE:
                        break
                    if frame[0] == cloud_ws.OP_PING:
                        self.wfile.write(cloud_ws.encode_frame(cloud_ws.OP_PONG, frame[1]))
                if bid:
                    DISPLAYS.touch(bid)
                data, _mime = desktop_frame(display, 720)
                if data:
                    misses = 0
                    digest = hashlib.sha1(data).digest()
                    if digest != last_digest:
                        self.wfile.write(cloud_ws.encode_frame(cloud_ws.OP_BINARY, data))
                        self.wfile.flush()
                        last_digest, last_send = digest, time.time()
                else:
                    misses += 1   # 截屏偶尔失败：继续用上一帧；连续失败就慢下来
                if time.time() - last_send > 10:
                    self.wfile.write(cloud_ws.encode_frame(cloud_ws.OP_PING, b"k"))
                    self.wfile.flush()
                    last_send = time.time()
                interval = (1.0 / fps) * (4 if misses > 3 else 1)
                time.sleep(max(0.05, interval - (time.time() - started)))
            try:
                self.wfile.write(cloud_ws.encode_frame(cloud_ws.OP_CLOSE, (1000).to_bytes(2, "big")))
                self.wfile.flush()
            except OSError:
                pass
        except (OSError, ValueError):
            pass    # 手机断开：正常结束

    def _authorized(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or not token_ok(auth[7:].strip()):
            self._send(401, {"error": "Unauthorized"})
            return False
        return True

    def _reply(self, method, path, body):
        """回复方式：GET/PUT /v1/bots/<id|_default>/reply {mode, front_model, back_model}；
        GET/PUT /v1/sessions/<sid>/reply {mode: instant|verbose|null}（这个对话单独覆盖，null = 跟随 Bot）。返回是否处理了。"""
        m_b = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31}|_default)/reply$", path)
        m_s = re.match(r"^/v1/sessions/(sess_[a-f0-9]{12})/reply$", path)
        if not m_b and not m_s:
            return False
        conn = get_db_connection()
        try:
            if m_b:
                bot_id = None if m_b.group(1) == "_default" else m_b.group(1)
                if bot_id and not get_persona(bot_id):
                    self._send(404, {"error": "Bot not found"})
                    return True
                if method == "PUT":
                    cloud_reply.set_bot_settings(conn, bot_id, body)
                self._send(200, {"reply": cloud_reply.bot_settings(conn, bot_id), "fast_model": resource_settings().get("fast_model") or None})
                return True
            sid = m_s.group(1)
            row = conn.execute("SELECT persona_id FROM sessions WHERE session_id = ?", (sid,)).fetchone()
            if not row:
                self._send(404, {"error": "Session not found"})
                return True
            if method == "PUT":
                cloud_reply.set_session_override(conn, sid, (body or {}).get("mode"))
            self._send(200, {"reply": session_reply_view(conn, sid, row[0])})
            return True
        except cloud_reply.ReplyError as e:
            self._send(400, {"error": str(e)})
            return True
        finally:
            conn.close()

    def _workers(self, method, path, query, body):
        """后台任务：GET /v1/workers?session_id=|bot=、GET /v1/workers/<id>（含过程事件）、POST /v1/workers/<id>/stop|message。"""
        parts = path.strip("/").split("/")
        conn = get_db_connection()
        try:
            if method == "GET" and len(parts) == 2:
                sid = (query.get("session_id") or [None])[0]
                bot = (query.get("bot") or [None])[0]
                rows = cloud_workers.list_for(conn, bot_id=bot if sid is None else None, front_session=sid,
                                              limit=int((query.get("limit") or ["50"])[0] or 50))
                self._send(200, {"workers": [worker_view(w) for w in rows]})
                return
            w = cloud_workers.get(conn, parts[2]) if len(parts) >= 3 else None
        finally:
            conn.close()
        if not w:
            self._send(404, {"error": "没有这个后台任务"})
            return
        if method == "GET" and len(parts) == 3:
            self._send(200, {"worker": worker_view(w)})
            return
        if method == "POST" and len(parts) == 4 and parts[3] == "stop":
            self._send(200, {"worker": worker_view(worker_stop(w["worker_id"]))})
            return
        if method == "POST" and len(parts) == 4 and parts[3] == "message":
            code, res = worker_message(w["worker_id"], (body or {}).get("text"))
            self._send(code, res)
            return
        self._send(404, {"error": "Not found"})

    def _vault(self, method, path, query, body):
        """保管库接口（只给 App 用；admin_api 不能访问）。列表只有元数据；reveal 返回机密，App 先过 Face ID。"""
        conn = get_db_connection()
        try:
            item_m = re.match(r"^/v1/vault/(v_[a-f0-9]{10})(/reveal)?$", path)
            if method == "GET" and path == "/v1/vault":
                q = lambda k: (query.get(k) or [None])[0]
                ok, reason = cloud_secrets.status()
                self._send(200, {"items": cloud_vault.list_items(conn, q("kind"), q("q"), hints=ok), "available": ok,
                                 **({} if ok else {"reason": reason})})
            elif method == "GET" and path == "/v1/vault/uses":
                item_id = (query.get("item_id") or [None])[0]
                self._send(200, {"items": cloud_vault.uses(conn, item_id)})
            elif method == "POST" and path == "/v1/vault":
                self._send(201, {"item": cloud_vault.create(conn, body)})
            elif method == "POST" and path == "/v1/vault/import":
                self._send(200, cloud_vault.import_csv(conn, body.get("csv")))
            elif item_m and item_m.group(2):
                if method != "POST":
                    self._send(405, {"error": "Method not allowed"})
                    return
                item, sec = cloud_vault.secret(conn, item_m.group(1))
                cloud_vault.record_use(conn, item, "app", None, "app_reveal", "App", True)
                self._send(200, {"item": item, "secret": sec})
            elif item_m and method == "GET":
                self._send(200, {"item": cloud_vault.get(conn, item_m.group(1))})
            elif item_m and method == "PUT":
                self._send(200, {"item": cloud_vault.update(conn, item_m.group(1), body)})
            elif item_m and method == "DELETE":
                cloud_vault.delete(conn, item_m.group(1))
                self._send(200, {"deleted": True})
            else:
                self._send(404, {"error": "Not found"})
        except cloud_vault.VaultError as e:
            self._send(404 if "没有这一项" in str(e) else 400, {"error": str(e)})
        except cloud_secrets.SecretStoreUnavailable as e:
            self._send(503, {"error": "加密存储不可用：" + str(e)})
        except cloud_secrets.SecretDecryptError as e:
            self._send(500, {"error": str(e)})
        finally:
            conn.close()

    def _read_json_body(self):
        """返回 dict；出错时已发送错误响应并返回 None。"""
        raw_len = self.headers.get("Content-Length", 0)
        try:
            length = int(raw_len)
        except Exception:
            self._send(400, {"error": "Invalid Content-Length"})
            return None

        # 附件上传（base64）放宽到 36MB，其余接口仍限制 5MB
        _lp = urlparse(self.path).path
        limit = 36 * 1024 * 1024 if (re.match(r"^/v1/sessions/[A-Za-z0-9_-]{1,64}/upload$", _lp) or _lp == "/v1/handoff") else 5 * 1024 * 1024
        if length < 0 or length > limit:
            self._send(400 if length < 0 else 413, {"error": "Invalid body size or exceeds limit"})
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
        if self._reply("PUT", path, req_json):
            return

        m_ev = re.match(r"^/v1/event-triggers/(evt_[0-9a-f]{10})$", path)
        if m_ev:
            conn = get_db_connection()
            try:
                if not cloud_events.get(conn, m_ev.group(1)) or not isinstance(req_json.get("enabled"), bool):
                    self._send(404 if not cloud_events.get(conn, m_ev.group(1)) else 400, {"error": "需要 enabled: true/false"})
                    return
                cloud_events.set_enabled(conn, m_ev.group(1), req_json["enabled"])
                self._send(200, {"trigger": cloud_events.get(conn, m_ev.group(1))})
            finally:
                conn.close()
            return

        m_ex = re.match(r"^/v1/exams/(exam_[0-9a-f]{10})$", path)
        if m_ex:
            conn = get_db_connection()
            try:
                e = cloud_exams.update(conn, m_ex.group(1), req_json)
                self._send(200 if e else 404, {"exam": e} if e else {"error": "没有这场考试"})
            except ValueError as err:
                self._send(400, {"error": str(err)})
            finally:
                conn.close()
            return

        m_av = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31})/avatar$", path)
        if m_av:
            if not get_persona(m_av.group(1)):
                self._send(404, {"error": "Bot not found"})
                return
            try:
                data = base64.b64decode(req_json.get("data_base64") or "", validate=True)
                h = avatar_save(m_av.group(1), data)
            except (ValueError, TypeError, binascii.Error) as e:
                self._send(400, {"error": str(e) or "图片数据无效"})
                return
            self._send(200, {"hash": h})
            return

        if path.startswith("/v1/bots/") and path.endswith("/notify"):
            bid = path[len("/v1/bots/"):-len("/notify")]
            if not get_persona(bid):
                self._send(404, {"error": "Bot not found"})
                return
            if not isinstance(req_json.get("enabled"), bool):
                self._send(400, {"error": "enabled must be a boolean"})
                return
            set_bot_notify(bid, req_json["enabled"])
            self._send(200, {"bot_id": bid, "notify": req_json["enabled"]})
            return

        m_grp = re.match(r"^/v1/groups/(grp_[a-f0-9]{10})$", path)
        if m_grp:
            conn = get_db_connection()
            try:
                if not cloud_groups.get_group(conn, m_grp.group(1)):
                    self._send(404, {"error": "Group not found"})
                    return
                try:
                    fields = cloud_groups.validate_fields(req_json, lambda b: bool(get_persona(b)), partial=True)
                except cloud_groups.GroupError as e:
                    self._send(400, {"error": str(e)})
                    return
                g = cloud_groups.update_group(conn, m_grp.group(1), fields)
                self._send(200, group_payload(conn, g, None))
            finally:
                conn.close()
            return

        m_mem = re.match(r"^/v1/memory/(\d+)$", path)
        if m_mem:
            persona = req_json.get("bot_id")
            if persona and not get_persona(persona):
                self._send(400, {"error": "Bot 不存在"})
                return
            conn = get_db_connection()
            try:
                entry = cloud_memory.update(conn, int(m_mem.group(1)), req_json.get("content"), req_json.get("category"),
                                            None if "bot_id" not in req_json else (persona or ""))
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            finally:
                conn.close()
            self._send(200 if entry else 404, entry or {"error": "Memory entry not found"})
            return

        if path == "/v1/proxy":
            try:
                self._send(200, proxy_mgr().update(req_json))
            except cloud_proxy.ProxyError as e:
                self._send(400, {"error": str(e)})
            return
        if path == "/v1/relays/watch":
            cred, model, hours = req_json.get("credential", ""), req_json.get("model", ""), req_json.get("hours", 0)
            if not isinstance(hours, (int, float)) or hours not in (0, 6, 12, 24, 72, 168) \
                    or not isinstance(cred, str) or not re.match(r"^[A-Za-z0-9_.:-]{0,64}$", cred) \
                    or not isinstance(model, str) or not re.match(r"^[A-Za-z0-9._:/@+-]{0,120}$", model) or (hours and not (cred and model)):
                self._send(400, {"error": "hours 只能是 0 / 6 / 12 / 24 / 72 / 168；开启时需要 credential 和 model"})
                return
            cfg = relay_watch_config()
            changed = (cfg.get("credential"), cfg.get("model")) != (cred, model)
            cfg.update({"credential": cred, "model": model, "hours": hours})
            if changed:
                cfg["history"], cfg["last_run"] = [], 0
            _settings_put("relay_watch", cfg)
            self._send(200, {"watch": {k: cfg.get(k) for k in ("credential", "model", "hours", "last_run", "history")}})
            return

        if path == "/v1/resources":
            try:
                new = update_resource_settings(req_json)
            except iso.SettingsError as e:
                self._send(400, {"error": str(e)})
                return
            if "duty_until" in req_json:
                try:
                    duty_check()
                except Exception as e:
                    print(f"duty check failed: {type(e).__name__}", flush=True)
            self._send(200, {"settings": new, "usage": resource_usage()})
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

        if path.startswith("/v1/vault/"):
            self._vault("PUT", path, {}, req_json)
            return
        m_sec = re.match(r"^/v1/bot_sections/(sec_[a-f0-9]{10})$", path)
        if m_sec:
            conn = get_db_connection()
            try:
                sec = cloud_admin.update_section(conn, m_sec.group(1), req_json)
            except cloud_admin.AdminError as e:
                self._send(404 if "没有" in str(e) else 400, {"error": str(e)})
                return
            finally:
                conn.close()
            bots_changed()
            self._send(200, sec)
            return
        m_prefs = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31})/prefs$", path)
        if m_prefs:
            conn = get_db_connection()
            try:
                p = cloud_admin.set_prefs(conn, m_prefs.group(1), req_json)
            except cloud_admin.AdminError as e:
                self._send(404 if "没有这个" in str(e) else 400, {"error": str(e)})
                return
            finally:
                conn.close()
            bots_changed()
            self._send(200, {"bot_id": m_prefs.group(1), "prefs": p})
            return
        if path.startswith("/v1/bots/"):
            conn = get_db_connection()
            try:
                bid_put = path[len("/v1/bots/"):]
                if req_json.get("is_primary") is True and cloud_bots.BOT_ID_RE.match(bid_put or "") and cloud_bots.get(conn, bid_put) \
                        and not (cloud_bots.get(conn, bid_put) or {}).get("is_primary"):
                    prev = cloud_admin.set_primary(conn, bid_put)
                    cloud_audit.record(conn, "set_primary_bot", bid_put, f"把 {bid_put} 设为主 Bot（App）",
                                       {"kind": "bot", "op": "set_primary", "bot_id": bid_put, "previous": prev}, bot_id=bid_put)
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
                sch = fields.get("schedule") or {}
                if sch.get("kind") == "after" and routine_after_creates_cycle(rid, sch.get("routine_id")):
                    raise ValueError("这样连会绕成圈：上一步不能是它自己或它后面的任务")
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

    def _proxy_post(self, path, body):
        m = proxy_mgr()
        try:
            if path == "/v1/proxy/import":
                text = body.get("text")
                if not isinstance(text, str) or not text.strip() or len(text) > 2_000_000:
                    raise cloud_proxy.ProxyError("请粘贴分享链接或订阅地址")
                res = m.import_text(text)
                m.apply()
                self._send(200, dict(res, status=m.status()))
            elif path == "/v1/proxy/test":
                ids = body.get("ids")
                self._send(200, {"results": m.test(ids if isinstance(ids, list) else None), "status": m.status()})
            elif path == "/v1/proxy/refresh":
                self._send(200, {"results": m.refresh_subscriptions(), "status": m.status()})
            elif path == "/v1/proxy/install":
                m.install_async()
                self._send(202, m.status())
            elif path == "/v1/proxy/check":
                # 经代理访问 GitHub：如实给出耗时，不编数字
                op = m.opener()
                if not op:
                    raise cloud_proxy.ProxyError("代理没在运行")
                t0 = time.monotonic()
                with op.open(urllib.request.Request("https://github.com", method="HEAD"), timeout=15) as r:
                    code = r.status
                self._send(200, {"ok": True, "http": code, "ms": int((time.monotonic() - t0) * 1000)})
            else:
                self._send(404, {"error": "Not found"})
        except cloud_proxy.ProxyError as e:
            self._send(400, {"error": str(e)})
        except cloud_secrets.SecretStoreUnavailable as e:
            self._send(503, {"error": str(e)})
        except Exception as e:
            self._send(502, {"error": f"{type(e).__name__}：{cloud_proxy.scrub(str(e), cloud_proxy.secret_strings(m.state()))[:200]}"})

    def do_DELETE(self):
        path = self.path.split("?")[0]
        query_params = parse_qs(urlparse(self.path).query)
        if not self._authorized():
            return
        m_snap = re.match(r"^/v1/browser/snapshots/(snap_[0-9a-f]{10})$", path)
        if m_snap:
            ok = cloud_snapshots.delete(os.path.dirname(DB_PATH), m_snap.group(1))
            self._send(200 if ok else 404, {"deleted": ok})
            return
        m_ev = re.match(r"^/v1/event-triggers/(evt_[0-9a-f]{10})$", path)
        if m_ev:
            conn = get_db_connection()
            try:
                ok = cloud_events.delete(conn, m_ev.group(1))
                cloud_notify.delete_setting(conn, "event:" + m_ev.group(1))
            finally:
                conn.close()
            self._send(200 if ok else 404, {"deleted": ok})
            return
        m_ex = re.match(r"^/v1/exams/(exam_[0-9a-f]{10})$", path)
        if m_ex:
            conn = get_db_connection()
            try:
                ok = cloud_exams.delete(conn, m_ex.group(1))
            finally:
                conn.close()
            self._send(200 if ok else 404, {"deleted": ok})
            return
        m_px = re.match(r"^/v1/proxy/(nodes|subscriptions)/([0-9a-f]{6,64})$", path)
        if m_px:
            if m_px.group(1) == "nodes":
                proxy_mgr().delete(node_id=m_px.group(2))
            else:
                proxy_mgr().delete(sub_id=m_px.group(2))
            self._send(200, proxy_mgr().status())
            return
        if path.startswith("/v1/bots/") and path.endswith("/telegram"):
            self._send(200, telegram_delete(path[len("/v1/bots/"):-len("/telegram")]))
            return
        m_lib = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31})/library/([A-Za-z0-9_-]{1,64})$", path)
        if m_lib:
            if not get_persona(m_lib.group(1)):
                self._send(404, {"error": "Bot not found"})
                return
            ok = library_delete(m_lib.group(1), m_lib.group(2))
            self._send(200 if ok else 404, {"deleted": ok} if ok else {"error": "资料库里没有这一项"})
            return
        m_sess = re.match(r"^/v1/sessions/(sess_[a-f0-9]{12})$", path)
        if m_sess:
            # 只允许删无痕对话（普通对话的历史保留，避免误删）
            sid = m_sess.group(1)
            conn = get_db_connection()
            try:
                row = conn.execute("SELECT incognito FROM sessions WHERE session_id = ?", (sid,)).fetchone()
                if not row:
                    self._send(404, {"error": "Session not found"})
                    return
                if not row[0]:
                    self._send(400, {"error": "只能删除无痕对话"})
                    return
                active = conn.execute("SELECT task_id FROM tasks WHERE session_id = ? AND status IN ('running', 'queued', 'waiting_user')", (sid,)).fetchall()
                if active:
                    # 先停掉任务，App 稍后重试删除；App 没再来的话 24 小时后自动清掉
                    for (tid,) in active:
                        set_task_cancelled(tid)
                    self._send(409, {"error": "正在停止任务，稍后再删"})
                    return
                purge_session(conn, sid)
                conn.commit()
            finally:
                conn.close()
            self._send(200, {"deleted": True})
            return
        m_grp = re.match(r"^/v1/groups/(grp_[a-f0-9]{10})$", path)
        if m_grp:
            conn = get_db_connection()
            try:
                ok = cloud_groups.delete_group(conn, m_grp.group(1))
            finally:
                conn.close()
            self._send(200 if ok else 404, {"deleted": True} if ok else {"error": "Group not found"})
            return
        if path.startswith("/v1/vault/"):
            self._vault("DELETE", path, query_params, None)
            return
        m_sec_del = re.match(r"^/v1/bot_sections/(sec_[a-f0-9]{10})$", path)
        if m_sec_del:
            conn = get_db_connection()
            try:
                cloud_admin.delete_section(conn, m_sec_del.group(1))
            except cloud_admin.AdminError as e:
                self._send(404, {"error": str(e)})
                return
            finally:
                conn.close()
            bots_changed()
            self._send(200, {"deleted": True})
            return
        if path.startswith("/v1/bots/") and (query_params.get("soft") or ["0"])[0] == "1":
            # 首页长按「删除」：进回收站（保留记忆和会话），可在操作记录里撤销或 POST /v1/bots/<id>/restore
            bid = path[len("/v1/bots/"):]
            conn = get_db_connection()
            try:
                bot = cloud_admin.delete(conn, bid)
                cloud_audit.record(conn, "delete_bot", bid, f"删除 Bot「{bot['name']}」（在回收站，可恢复）",
                                   {"kind": "bot", "op": "delete", "bot_id": bid}, bot_id=bid)
            except cloud_admin.AdminError as e:
                self._send(404 if "没有这个" in str(e) else 400, {"error": str(e)})
                return
            finally:
                conn.close()
            bots_changed()
            self._send(200, {"bot_id": bid, "deleted": True, "in_trash": True})
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
        if path.startswith("/v1/proxy/"):
            self._proxy_post(path, req_json)
            return
        if path == "/v1/vault" or path.startswith("/v1/vault/"):
            self._vault("POST", path, {}, req_json)
            return
        if path.startswith("/v1/workers/"):
            self._workers("POST", path, {}, req_json)
            return
        if path == "/v1/handoff":
            try:
                self._send(200, start_handoff(req_json))
            except cloud_handoff.HandoffError as e:
                self._send(400, {"error": str(e)})
            return
        m_react = re.match(r"^/v1/sessions/(sess_[a-f0-9]{12})/messages/(\d{1,12})/reaction$", path)
        if m_react:
            # 用户给 Bot 的消息点表情（emoji 为空 = 取消）
            conn = get_db_connection()
            try:
                r = cloud_runmodel.set_reaction(conn, m_react.group(1), int(m_react.group(2)), "user", req_json.get("emoji"))
            except cloud_runmodel.RunModelError as e:
                self._send(400, {"error": str(e)})
                return
            finally:
                conn.close()
            self._send(200, {"message_id": int(m_react.group(2)), "reactions": r})
            return
        m_share = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31})/library/([A-Za-z0-9_-]{1,64})/share$", path)
        if m_share:
            on = req_json.get("shared", True)
            if not isinstance(on, bool):
                self._send(400, {"error": "shared must be a boolean"})
                return
            ok = library_set_shared(m_share.group(1), m_share.group(2), on)
            self._send(200 if ok else 404, {"shared": on} if ok else {"error": "资料库里没有这一项"})
            return
        m_restore = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31})/versions/(\d{1,12})/restore$", path)
        if m_restore:
            conn = get_db_connection()
            try:
                bot = cloud_bots.restore_version(conn, m_restore.group(1), int(m_restore.group(2)), credential_exists)
            except cloud_bots.BotError as e:
                self._send(400, {"error": str(e)})
                return
            finally:
                conn.close()
            self._send(200, bot)
            return
        m_undo = re.match(r"^/v1/audit/(\d{1,12})/undo$", path)
        if m_undo:
            conn = get_db_connection()
            try:
                def _del_memory(mid):
                    c2 = get_db_connection()
                    try:
                        cloud_memory.delete(c2, mid)
                    finally:
                        c2.close()
                ok, msg = cloud_audit.undo(conn, int(m_undo.group(1)), _del_memory,
                                           other=lambda info: cloud_admin.undo(conn, info, credential_exists))
                if ok:
                    bots_changed()
            except OSError as e:
                ok, msg = False, f"撤销失败：{type(e).__name__}"
            finally:
                conn.close()
            self._send(200 if ok else 400, {"undone": True, "message": msg} if ok else {"error": msg})
            return

        if path == "/v1/backup/import":
            try:
                stats = restore_backup(req_json.get("backup"), bool(req_json.get("include_settings")))
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            self._send(200, stats)
            return

        if path == "/v1/event-triggers":
            kind, rid = req_json.get("kind"), req_json.get("routine_id")
            try:
                cfg, secret = cloud_events.validate(kind, req_json.get("config") or {})
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            if not isinstance(rid, str) or not get_routine(rid):
                self._send(400, {"error": "routine_id 不存在（先建一个例行任务，触发时运行它）"})
                return
            conn = get_db_connection()
            try:
                tid = cloud_events.create(conn, kind, cfg, rid)
                if secret:
                    cloud_notify.save_setting(conn, "event:" + tid, {"secret": secret})
                self._send(200, {"trigger": cloud_events.get(conn, tid)})
            finally:
                conn.close()
            return

        if path == "/v1/exams":
            conn = get_db_connection()
            try:
                self._send(200, {"exam": cloud_exams.add(conn, req_json)})
            except ValueError as e:
                self._send(400, {"error": str(e)})
            finally:
                conn.close()
            return

        m = re.match(r"^/v1/feed/(run_[A-Za-z0-9_-]{4,40})/feedback$", path)
        if m:
            liked, comment = req_json.get("liked", 0), req_json.get("comment", "")
            if liked not in (-1, 0, 1) or not isinstance(comment, str) or len(comment) > 500:
                self._send(400, {"error": "liked 是 -1 / 0 / 1，comment 最多 500 字"})
                return
            r = feed_feedback(m.group(1), liked, comment)
            self._send(200 if r else 404, r or {"error": "没有这条动态"})
            return

        m = re.match(r"^/v1/system-snapshots/([0-9-]{10,32})/restore$", path)
        if m:
            if req_json.get("confirm") is not True:
                self._send(400, {"error": "回滚会卸载新装的软件、恢复 /etc，需要 confirm: true"})
                return
            with iso.SYSTEM_LOCK:
                r = cloud_sysnap.restore(sysnap_dir(), m.group(1))
            self._send(200 if r else 404, r or {"error": "没有这个快照"})
            return

        if path == "/v1/relays/check":
            # 中转站 / 服务商体检：原样复述、返回模型名、计费、系统提示是否生效、长上下文是否被截断（真实请求，不估计）
            prov, st, err = resolve_provider(req_json.get("provider") or {})
            model = req_json.get("model")
            if err or not isinstance(model, str) or not model:
                self._send(st if err else 400, {"error": err or "需要 model"})
                return
            needle = req_json.get("needle_tokens", 6000)
            needle = needle if isinstance(needle, int) and 0 <= needle <= 60000 else 6000
            url = f"{prov['base_url'].rstrip('/')}/chat/completions"
            headers = {"Content-Type": "application/json", "Authorization": f"Bearer {prov['api_key']}"}
            result = eff.relay_check(lambda body: cloud_llm.chat_completion(url, headers, body, stream=False, timeout=18), model, needle)
            result["model"] = model
            self._send(200, result)
            return

        if path == "/v1/presence":
            p = APP_FEED.touch(foreground=req_json.get("foreground"), local_notifications=req_json.get("local_notifications"))
            self._send(200, {"presence": p, "bark_fallback": resource_settings().get("bark_fallback", "auto")})
            return

        if path == "/v1/desktop/restart":
            ok, why = restart_desktop_services()
            if ok:
                time.sleep(2)
                self._send(200, {"restarted": True, "desktop": _desktop_health_brief()})
            else:
                self._send(409, {"error": "服务器上的 Agent 没有重启桌面的权限，请用 SSH 重启", "reason": why})
            return

        m_warm = re.match(r"^/v1/sessions/([A-Za-z0-9_-]{1,80})/warm$", path)
        if m_warm:
            # 打开对话 / 开始输入时调用：提前建好到模型服务商的连接、拉起浏览器，真正发送时少等一次握手
            def _warm():
                try:
                    cloud_llm.POOL.warm_known()
                except Exception:
                    pass
                try:
                    if req_json.get("browser") and cloud_browser.is_browser_available():
                        warm_browser_now()
                except Exception:
                    pass
            threading.Thread(target=_warm, name="warm", daemon=True).start()
            self._send(202, {"status": "warming"})
            return

        if path == "/v1/groups":
            try:
                fields = cloud_groups.validate_fields(req_json, lambda b: bool(get_persona(b)))
            except cloud_groups.GroupError as e:
                self._send(400, {"error": str(e)})
                return
            conn = get_db_connection()
            try:
                g = cloud_groups.create_group(conn, fields)
                self._send(201, group_payload(conn, g, None))
            finally:
                conn.close()
            return

        m_grp = re.match(r"^/v1/groups/(grp_[a-f0-9]{10})/messages$", path)
        if m_grp:
            gid = m_grp.group(1)
            content = req_json.get("content")
            if not isinstance(content, str) or not content.strip() or len(content) > 8000:
                self._send(400, {"error": "content 必须是 1–8000 字的文字"})
                return
            # 手机网络抖动时会静默重发：同一个 nonce 只算一条消息
            nonce = req_json.get("client_nonce")
            nonce_key = (gid, nonce) if isinstance(nonce, str) and 0 < len(nonce) <= 64 else None
            with GROUP_NONCE_LOCK:
                now = time.time()
                for k in [k for k, v in GROUP_NONCES.items() if now - v[1] > 600]:
                    GROUP_NONCES.pop(k, None)
                if nonce_key and nonce_key in GROUP_NONCES:
                    self._send(202, {"message_id": GROUP_NONCES[nonce_key][0], "duplicate": True})
                    return
            conn = get_db_connection()
            try:
                if not cloud_groups.get_group(conn, gid):
                    self._send(404, {"error": "Group not found"})
                    return
                provider_req = req_json.get("provider")
                if provider_req:
                    provider, _st, p_err = resolve_provider(provider_req)
                    if not p_err:
                        GROUP_FALLBACK[gid] = (req_json.get("model") or "gpt-4o", provider)
                mid = cloud_groups.add_message(conn, gid, "user", "text", content.strip())
                if nonce_key:
                    with GROUP_NONCE_LOCK:
                        GROUP_NONCES[nonce_key] = (mid, time.time())
            finally:
                conn.close()
            GROUPS.on_user_message(gid, mid, content.strip(), GROUP_FALLBACK.get(gid))
            GROUPS.notify()
            self._send(202, {"message_id": mid})
            return

        m_retry = re.match(r"^/v1/plugins/([a-z0-9][a-z0-9_-]{0,31})/retry$", path)
        if m_retry:
            pid = m_retry.group(1)
            p = PLUGINS.get(pid)
            if not p:
                self._send(404, {"error": "Plugin not found"})
                return
            try:
                if p["kind"] == "mcp":
                    tools = PLUGINS.list_tools(pid, refresh=True)
                    self._send(200, {"plugin": PLUGINS.get(pid), "tools": tools, "message": "已重新连接"})
                else:
                    self._send(200, {"plugin": p, "message": "技能包无需重新连接"})
            except cloud_mcp.MCPAuthRequired as e:
                self._send(409, {"error": "needs_auth", "message": str(e), "plugin": PLUGINS.get(pid)})
            except (cloud_mcp.MCPError, cloud_plugins.PluginError) as e:
                self._send(400, {"error": str(e), "plugin": PLUGINS.get(pid)})
            return

        m_oauth = re.match(r"^/v1/plugins/([a-z0-9][a-z0-9_-]{0,31})/oauth/(start|finish|disconnect)$", path)
        if m_oauth:
            pid, step = m_oauth.group(1), m_oauth.group(2)
            if not PLUGINS.get(pid):
                self._send(404, {"error": "Plugin not found"})
                return
            try:
                if step == "start":
                    self._send(200, {"authorize_url": PLUGINS.oauth_start(pid, req_json.get("redirect_uri") or "openminis://oauth")})
                elif step == "finish":
                    self._send(200, {"plugin": PLUGINS.oauth_finish(pid, req_json.get("code"), req_json.get("state"))})
                else:
                    self._send(200, {"plugin": PLUGINS.oauth_disconnect(pid)})
            except (cloud_plugins.PluginError, cloud_oauth.OAuthError) as e:
                self._send(400, {"error": str(e)})
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
            body = dict(p)
            body["created"] = created
            body["already_installed"] = not created
            body["message"] = "安装成功" if created else "这个插件已经安装过了"
            self._send(201 if created else 200, body)
            return

        m_up = re.match(r"^/v1/sessions/([A-Za-z0-9_-]{1,64})/upload$", path)
        if m_up:
            sid = m_up.group(1)
            conn = get_db_connection()
            try:
                found = conn.execute("SELECT 1 FROM sessions WHERE session_id = ?", (sid,)).fetchone()
            finally:
                conn.close()
            if not found:
                self._send(404, {"error": "Session not found"})
                return
            data_b64 = req_json.get("data_base64")
            if not isinstance(data_b64, str) or not data_b64:
                self._send(400, {"error": "data_base64 must be a non-empty string"})
                return
            try:
                import base64
                data = base64.b64decode(data_b64, validate=True)
            except Exception:
                self._send(400, {"error": "data_base64 is not valid base64"})
                return
            if len(data) > 25 * 1024 * 1024:
                self._send(413, {"error": "附件超过 25MB"})
                return
            try:
                self._send(200, save_upload(sid, str(req_json.get("filename") or "file"), data))
            except ValueError as e:
                self._send(400, {"error": str(e)})
            return

        if path == "/v1/desktop/display":
            # 手机「电脑」页：打开某个 Bot 的屏幕（独立模式按需启动），返回 noVNC token
            bid = req_json.get("bot_id")
            proxy = cloud_displays.token_proxy_enabled()
            if bid:
                if not isinstance(bid, str) or not get_persona(bid):
                    self._send(404, {"error": "Bot not found"})
                    return
                if iso.bot_settings(resource_settings(), bid)["browser_profile"] == "per_bot":
                    info = DISPLAYS.ensure(bid)
                    if info:
                        self._send(200, {"token_proxy": proxy, "token": info["token"], "display": info["display"],
                                         "own_display": True, "resolution": info["resolution"]})
                        return
            self._send(200, {"token_proxy": proxy, "token": "main", "display": cloud_displays.MAIN_DISPLAY, "own_display": False})
            return

        if path == "/v1/desktop/input":
            # 手机「电脑」页：把剪贴板文字或键盘输入发到云电脑桌面（与 Agent 共用 desktop_lock）
            action = req_json.get("action")
            if action == "type":
                text = req_json.get("text")
                if not isinstance(text, str) or not text or len(text) > 10000:
                    self._send(400, {"error": "text must be a non-empty string (max 10000)"})
                    return
                args = {"action": "type", "text": text}
            elif action == "key":
                key = req_json.get("key")
                if not isinstance(key, str) or not re.match(r"^[A-Za-z0-9_+]{1,40}$", key):
                    self._send(400, {"error": "key must be an xdotool key name such as Return or ctrl+v"})
                    return
                args = {"action": "key", "key": key}
                rep = req_json.get("repeat", 1)
                if not isinstance(rep, int) or isinstance(rep, bool) or not 1 <= rep <= 50:
                    self._send(400, {"error": "repeat must be an integer 1-50"})
                    return
                if rep > 1:
                    args["repeat"] = rep
            elif action in ("clipboard_get", "vault"):
                args = None
            elif action == "clipboard_set":
                text = req_json.get("text")
                if not isinstance(text, str) or len(text) > cloud_desktop.CLIPBOARD_MAX:
                    self._send(400, {"error": "text must be a string (max 10000)"})
                    return
                args = None
            else:
                self._send(400, {"error": "action must be type, key, clipboard_get, clipboard_set or vault"})
                return
            if not cloud_desktop.is_desktop_available():
                self._send(503, {"error": "云电脑桌面未运行：请先安装 / 更新云电脑桌面环境"})
                return
            display = None
            bid = req_json.get("bot_id")
            if isinstance(bid, str) and DISPLAYS.info(bid):
                display = DISPLAYS.info(bid)["display"]
                DISPLAYS.touch(bid)
            if action == "clipboard_get":
                # 云电脑 → 手机：读远端剪贴板文字（xclip）
                text, err = cloud_desktop.read_clipboard(display or cloud_displays.MAIN_DISPLAY)
                self._send(200 if err is None else 500, {"text": text} if err is None else {"error": err})
                return
            if action == "clipboard_set":
                # 手机 → 云电脑剪贴板（UTF-8，中文不乱码；RFB 自带的剪贴板只支持 Latin-1）
                err = cloud_desktop.write_clipboard(display or cloud_displays.MAIN_DISPLAY, req_json["text"])
                self._send(200 if err is None else 500, {"status": "ok"} if err is None else {"error": err})
                return
            if action == "vault":
                self._send(*phone_vault_type(req_json, display))
                return
            res = cloud_desktop.execute_desktop_action("phone", GLOBAL_WORKSPACE, args, display_override=display)
            self._send(200 if not res.get("error") else 500, res)
            return

        if path == "/v1/browser/snapshots":
            key, owner, display, ws = snapshot_route(req_json.get("session_id"))
            res = cloud_browser.execute_browser_action(key, ws, {"action": "__snapshot__"}, owner=owner, display=display)
            if not isinstance(res, dict) or res.get("error"):
                self._send(503, {"error": (res or {}).get("error") or "浏览器没开"})
                return
            self._send(201, cloud_snapshots.save(os.path.dirname(DB_PATH), req_json.get("name"), key, res))
            return

        m_snap = re.match(r"^/v1/browser/snapshots/(snap_[0-9a-f]{10})/restore$", path)
        if m_snap:
            snap = cloud_snapshots.load(os.path.dirname(DB_PATH), m_snap.group(1))
            if not snap:
                self._send(404, {"error": "快照不在了"})
                return
            key, owner, display, ws = snapshot_route(req_json.get("session_id"))
            res = cloud_browser.execute_browser_action(key, ws, {"action": "__restore__", "cookies": snap.get("cookies") or [],
                                                                 "tabs": snap.get("tabs") or []}, owner=owner, display=display)
            if not isinstance(res, dict) or res.get("error"):
                self._send(503, {"error": (res or {}).get("error") or "浏览器没开"})
                return
            self._send(200, {"restored": True, "cookies": res.get("cookies", 0), "opened": res.get("opened", 0)})
            return

        if path == "/v1/desktop/files":
            # 手机照片 / 文件 → 云电脑「下载」文件夹
            try:
                data = _B64.b64decode(req_json.get("data_base64") or "", validate=True)
                saved = cloud_desktop_files.save(req_json.get("filename") or "file", data)
            except (ValueError, TypeError) as e:
                self._send(400, {"error": str(e) or "data_base64 不是合法的 base64"})
                return
            self._send(201, saved)
            return

        if path == "/v1/desktop/control":
            # 手机「电脑」页：你来接管（Bot 的桌面 / 浏览器动作暂停）/ 交还给 Bot；接管是 45 秒租约，手机定时续
            hold = req_json.get("hold")
            if not isinstance(hold, bool):
                self._send(400, {"error": "hold must be true or false"})
                return
            display = cloud_displays.MAIN_DISPLAY
            bid = req_json.get("bot_id")
            if isinstance(bid, str) and DISPLAYS.info(bid):
                display = DISPLAYS.info(bid)["display"]
            if hold:
                DESK_CONTROL.hold(display)
            else:
                DESK_CONTROL.release(display)
            self._send(200, {"held": DESK_CONTROL.held(display), "display": display, "lease_s": cloud_desktop_control.LEASE_S})
            return

        if path == "/v1/plugins/deps/install":
            tool = cloud_deps.tool_for(req_json.get("tool") or "") or req_json.get("tool")
            if tool not in cloud_deps.TOOLS:
                self._send(400, {"error": "tool must be one of: node, npx, uv, uvx"})
                return
            info = cloud_deps.TOOLS[tool]
            if req_json.get("confirm") is not True:
                # 会从官方地址下载并在 VPS 上安装可执行文件：必须由用户确认后带 confirm 重试
                self._send(428, {"error": "confirm_install", "tool": tool, "label": info["label"], "source": info["source"],
                                 "install_dir": cloud_deps.bin_dir(),
                                 "message": f"将从 {info['source']} 下载 {info['label']}，校验 SHA-256 后安装到 {cloud_deps.bin_dir()}"})
                return
            job = cloud_deps.start_install(tool)
            self._send(202, {"job": job})
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

        if path == "/v1/bot_sections":
            conn = get_db_connection()
            try:
                sec = cloud_admin.create_section(conn, req_json.get("name"), req_json.get("bot_id"))
            except cloud_admin.AdminError as e:
                self._send(400, {"error": str(e)})
                return
            finally:
                conn.close()
            bots_changed()
            self._send(201, sec)
            return
        m_restore = re.match(r"^/v1/bots/([a-z0-9][a-z0-9_-]{0,31})/restore$", path)
        if m_restore:
            conn = get_db_connection()
            try:
                bot = cloud_admin.restore(conn, m_restore.group(1), credential_exists)
                cloud_audit.record(conn, "restore_bot", bot["bot_id"], f"从回收站恢复 Bot「{bot['name']}」",
                                   {"kind": "bot", "op": "create", "bot_id": bot["bot_id"]}, bot_id=bot["bot_id"])
            except cloud_admin.AdminError as e:
                self._send(404 if "没有" in str(e) else 400, {"error": str(e)})
                return
            finally:
                conn.close()
            bots_changed()
            self._send(200, {"restored": True, "bot": bot_detail(bot)})
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
            incognito = 1 if req_json.get("incognito") is True else 0
            sid = "sess_" + uuid.uuid4().hex[:12]
            created_at = time.time()
            conn = get_db_connection()
            c = conn.cursor()
            if incognito:
                purge_stale_incognito(conn, created_at)
            c.execute("INSERT INTO sessions (session_id, title, created_at, persona_id, incognito) VALUES (?, ?, ?, ?, ?)",
                      (sid, title, created_at, persona_id, incognito))
            conn.commit()
            conn.close()
            self._send(201, {"session_id": sid, "title": title, "created_at": created_at, "persona_id": persona_id, "incognito": bool(incognito)})
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

        if re.fullmatch(r"/v1/sessions/[A-Za-z0-9_-]{1,80}/transcript", path):
            sid = path.split("/")[3]
            try:
                n = session_append_transcript(sid, req_json.get("lines"), req_json.get("nonce"))
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            if n is None:
                self._send(404, {"error": "Session not found"})
                return
            self._send(200, {"ok": True, "saved": n})
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
            # 只带附件路径的图片（2.47.0 起手机都这样发）：数据库里存文字，调用模型时再读上传的文件补成图片

            model = req_json.get("model", "gpt-4o")
            client_effort = req_json.get("reasoning_effort")
            if client_effort not in (None, "") and client_effort not in cloud_bots.EFFORTS:
                self._send(400, {"error": "reasoning_effort must be one of off/low/medium/high/xhigh"})
                return
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
            blocked = usage_blocked()
            if blocked:
                self._send(429, {"error": blocked, "error_kind": "daily_cap"})
                return
            # 引用回复 / 选项卡的回答
            user_meta = {}
            rconn = get_db_connection()
            try:
                if req_json.get("reply_to") is not None:
                    user_meta["reply_to"] = cloud_runmodel.reply_ref(rconn, sid, req_json.get("reply_to"))
                ca = req_json.get("choice_answer")
                if ca is not None:
                    if not isinstance(ca, dict) or not isinstance(ca.get("message_id"), int):
                        raise cloud_runmodel.RunModelError("choice_answer 需要 message_id")
                    content = cloud_runmodel.mark_choice(rconn, sid, ca["message_id"], ca.get("selected") or [],
                                                         ca.get("custom") if isinstance(ca.get("custom"), str) else None, bool(ca.get("dismissed")))
                    db_user_content = content
                    user_meta["choice_answer"] = ca["message_id"]
            except cloud_runmodel.RunModelError as e:
                self._send(400, {"error": str(e)})
                return
            finally:
                rconn.close()

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

                try:
                    GATE.check_capacity(task_lane(sid), session_persona_id(sid))
                except iso.QueueFull as e:
                    conn.rollback()
                    conn.close()
                    self._send(429, {"error": str(e)})
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
                c.execute("INSERT INTO messages (session_id, role, content, timestamp, meta) VALUES (?, 'user', ?, ?, ?)",
                          (sid, db_user_content, created_at, json.dumps(user_meta, ensure_ascii=False) if user_meta else None))
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
            if client_effort and not (bot and bot.get("reasoning_effort")):
                TASK_EFFORT[tid] = client_effort

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
                # source：phone（手机技能同步，默认）/ macro（云电脑宏录制，手机技能同步的 prune 不会删到它）
                source = req_json.get("source") or "phone"
                if source not in ("phone", "macro"):
                    raise ValueError("source 只能是 phone 或 macro")
                counts = cloud_skills.sync(conn, req_json.get("skills"), prune=bool(req_json.get("prune")), source=source)
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            finally:
                conn.close()
            self._send(200, counts)
            return

        if path == "/v1/memory":
            persona = req_json.get("bot_id") or ""
            if persona and not get_persona(persona):
                self._send(400, {"error": "Bot 不存在"})
                return
            conn = get_db_connection()
            try:
                entry, created = cloud_memory.write(conn, req_json.get("content"), req_json.get("category"), source=req_json.get("source") if req_json.get("source") in ("phone", "cloud") else "phone",
                                                    persona=persona)
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

        m_inject = re.match(r"^/v1/tasks/([A-Za-z0-9_-]{1,64})/messages$", path)
        if m_inject:
            # 插话：任务进行中追加一条用户消息，下一步就交给模型（同一个 nonce 只收一次）
            content = req_json.get("content")
            nonce = req_json.get("nonce")
            if not isinstance(content, str) or not content.strip() or len(content) > 100000:
                self._send(400, {"error": "content must be a non-empty string"})
                return
            if nonce is not None and (not isinstance(nonce, str) or len(nonce) > 80):
                self._send(400, {"error": "nonce must be a short string"})
                return
            code, body = inbox_push(m_inject.group(1), content.strip(), nonce)
            self._send(code, body)
            return

        m_reset = re.match(r"^/v1/sessions/(sess_[a-f0-9]{12})/reset$", path)
        if m_reset:
            sid = m_reset.group(1)
            conn = get_db_connection()
            try:
                exists = conn.execute("SELECT 1 FROM sessions WHERE session_id = ?", (sid,)).fetchone()
            finally:
                conn.close()
            if not exists:
                self._send(404, {"error": "Session not found"})
                return
            model = req_json.get("model")
            provider_req = req_json.get("provider") or {}
            bot = session_bot(sid)
            if bot and bot.get("model") and bot.get("credential"):
                model, provider_req = bot["model"], {"protocol": "chat", "credential": bot["credential"]}
            provider = None
            if provider_req:
                provider, _st, p_err = resolve_provider(provider_req)
                if p_err:
                    provider = None     # 没有可用的模型：快照退回如实摘录，不影响重置
            self._send(200, reset_session(sid, provider, model))
            return

        if path.startswith("/v1/tasks/") and path.endswith("/retract"):
            # 撤回发送（App 发出后 5 秒内）：停掉任务，并删掉这条用户消息和它之后写进对话的内容
            parts = path.split("/")
            tid = parts[3] if len(parts) == 5 else ""
            conn = get_db_connection()
            try:
                row = conn.execute("SELECT session_id, created_at, status FROM tasks WHERE task_id = ?", (tid,)).fetchone()
                if not row:
                    self._send(404, {"error": "Task not found"})
                    return
                sid, created, status = row
                if time.time() - (created or 0) > RETRACT_WINDOW_S:
                    self._send(409, {"error": "超过撤回时间", "window_s": RETRACT_WINDOW_S})
                    return
                newer = conn.execute("SELECT 1 FROM tasks WHERE session_id = ? AND created_at > ? LIMIT 1", (sid, created)).fetchone()
                if newer:
                    self._send(409, {"error": "之后又发了消息，不能撤回这条"})
                    return
                if status in ("running", "waiting_user"):
                    set_task_cancelled(tid)
                    conn.execute("UPDATE tasks SET status = 'cancelled' WHERE task_id = ?", (tid,))
                n = conn.execute("DELETE FROM messages WHERE session_id = ? AND timestamp >= ?", (sid, created)).rowcount
                conn.commit()
            finally:
                conn.close()
            log_event(tid, "cancelled", {"message": "Retracted by user", "retracted": True})
            self._send(200, {"task_id": tid, "status": "retracted", "deleted_messages": n})
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

def warm_browser_now():
    os.makedirs(SHARED_WORKSPACE, exist_ok=True)
    return cloud_browser.execute_browser_action("shared", SHARED_WORKSPACE, {"action": "__warm__"})

def warm_browser():
    """资源设置开启预热时，启动后先把共享浏览器开好，第一次网页操作不用等冷启动。"""
    if not resource_settings().get("browser_warm") or not cloud_browser.is_browser_available():
        return
    os.makedirs(SHARED_WORKSPACE, exist_ok=True)
    res = cloud_browser.execute_browser_action("shared", SHARED_WORKSPACE, {"action": "__warm__"})
    print(f"[startup] browser warm: {res}", flush=True)

def run_server():
    global SERVER_TOKEN
    if not SERVER_TOKEN:
        SERVER_TOKEN = validate_and_load_token()
    global ADMIN_BASE
    ADMIN_BASE = f"http://127.0.0.1:{PORT}"
    server = ThreadingHTTPServer((HOST, PORT), Handler)

    def start_background():
        # 后台服务（定时任务、Telegram 长轮询）放在独立线程启动：任何一项出错或网络不通都不影响 /health 与 API 立即可用
        for name, fn in (("watchdog", start_watchdog), ("scheduler", start_scheduler), ("proxy", start_proxy),
                         ("telegram", start_telegram), ("browser-warm", warm_browser)):
            try:
                fn()
            except Exception as e:
                print(f"[startup] {name} failed to start: {type(e).__name__}: {e}", flush=True)

    threading.Thread(target=start_background, name="startup-background", daemon=True).start()
    print(f"OpenMinis Cloud Computer & Agent running on {HOST}:{PORT}", flush=True)
    server.serve_forever()

if __name__ == "__main__":
    run_server()
