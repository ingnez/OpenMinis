#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent Service (cloud_agent_server.py)
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
import urllib.request
import urllib.error
from urllib.parse import urlparse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

HOST = os.environ.get("OPENMINIS_HOST", "127.0.0.1")
PORT = int(os.environ.get("OPENMINIS_PORT", "18765"))
BASE_DIR = os.path.abspath(os.environ.get("OPENMINIS_BASE", os.path.dirname(__file__)))
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
            sys.stderr.write(f"[-] CRITICAL ERROR: Token file permissions must be 600.\n")
            sys.exit(1)
        with open(TOKEN_FILE, "r") as f:
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
    cursor.execute("CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY, title TEXT, created_at REAL)")
    cursor.execute("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT, timestamp REAL)")
    cursor.execute("CREATE TABLE IF NOT EXISTS tasks (task_id TEXT PRIMARY KEY, session_id TEXT, status TEXT, model TEXT, created_at REAL)")
    cursor.execute("CREATE TABLE IF NOT EXISTS task_events (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT, event_type TEXT, payload TEXT, timestamp REAL)")
    cursor.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_session_running ON tasks(session_id) WHERE status = 'running'")
    cursor.execute("UPDATE tasks SET status = 'interrupted' WHERE status IN ('running', 'pending')")
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
                    try: os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except: proc.kill()
                    proc.wait()
                    return {"error": "Command terminated due to cancellation"}
                if time.time() - start_t > timeout:
                    try: os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except: proc.kill()
                    proc.wait()
                    return {"error": f"Timeout after {timeout}s"}
                time.sleep(0.1)
            proc.wait()
            out_f.seek(0)
            err_f.seek(0)
            return {"exit_code": proc.returncode, "stdout": out_f.read(32768).decode("utf-8", "replace"), "stderr": err_f.read(32768).decode("utf-8", "replace")}
    except Exception as e:
        return {"error": str(e)}

def tool_file_read(task_id, session_id, args):
    if is_task_cancelled(task_id): return {"error": "Cancelled"}
    target, err = safe_path_resolve(session_id, args.get("path", ""))
    if err: return {"error": err}
    if not os.path.exists(target) or not os.path.isfile(target): return {"error": "Not found"}
    try:
        if os.path.getsize(target) > 2*1024*1024: return {"error": "Too large (>2MB)"}
        with open(target, "r", encoding="utf-8") as f: return {"content": f.read()}
    except Exception as e: return {"error": str(e)}

def tool_file_write(task_id, session_id, args):
    if is_task_cancelled(task_id): return {"error": "Cancelled"}
    target, err = safe_path_resolve(session_id, args.get("path", ""))
    if err: return {"error": err}
    try:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as f: f.write(args.get("content", ""))
        return {"status": "success", "path": args.get("path")}
    except Exception as e: return {"error": str(e)}

def tool_file_edit(task_id, session_id, args):
    if is_task_cancelled(task_id): return {"error": "Cancelled"}
    target, err = safe_path_resolve(session_id, args.get("path", ""))
    if err: return {"error": err}
    if not os.path.exists(target): return {"error": "Not found"}
    try:
        with open(target, "r", encoding="utf-8") as f: content = f.read()
        old_s, new_s = args.get("old_string", ""), args.get("new_string", "")
        if old_s not in content: return {"error": "old_string not found"}
        with open(target, "w", encoding="utf-8") as f: f.write(content.replace(old_s, new_s, 1))
        return {"status": "success", "path": args.get("path")}
    except Exception as e: return {"error": str(e)}

TOOL_DEFINITIONS = [
    {"type": "function", "function": {"name": "shell_execute", "parameters": {"type": "object", "properties": {"command": {"type": "string"}, "timeout": {"type": "integer"}}, "required": ["command"]}}},
    {"type": "function", "function": {"name": "file_read", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "file_write", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}}},
    {"type": "function", "function": {"name": "file_edit", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "old_string": {"type": "string"}, "new_string": {"type": "string"}}, "required": ["path", "old_string", "new_string"]}}}
]

def log_event(task_id, etype, payload):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("INSERT INTO task_events (task_id, event_type, payload, timestamp) VALUES (?, ?, ?, ?)", (task_id, etype, json.dumps(payload, ensure_ascii=False), time.time()))
    conn.commit()
    conn.close()

def sanitize_err(e):
    import re
    s = str(e)
    s = re.sub(r'sk-[a-zA-Z0-9\-_]{20,}', 'sk-***REDACTED***', s)
    s = re.sub(r'Bearer\s+[a-zA-Z0-9\-_.\s]+', 'Bearer ***REDACTED***', s)
    return s

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

    c.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)", (session_id, "user", initial_content, time.time()))
    conn.commit()
    c.execute("SELECT role, content FROM messages WHERE session_id = ? ORDER BY id ASC", (session_id,))
    rows = c.fetchall()
    conn.close()

    messages = [{"role": "system", "content": instructions}] if instructions else []
    for r, content in rows: messages.append({"role": r, "content": content})

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
                    conn = get_db_connection()
                    c = conn.cursor()
                    c.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)", (session_id, "assistant", content, time.time()))
                    conn.commit()
                    conn.close()
                else:
                    ast_msg["content"] = None
                ast_msg["tool_calls"] = tool_calls
                messages.append(ast_msg)

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

                    if fn_name == "shell_execute": res = tool_shell_execute(task_id, session_id, fn_args)
                    elif fn_name == "file_read": res = tool_file_read(task_id, session_id, fn_args)
                    elif fn_name == "file_write": res = tool_file_write(task_id, session_id, fn_args)
                    elif fn_name == "file_edit": res = tool_file_edit(task_id, session_id, fn_args)
                    else: res = {"error": f"Unknown tool {fn_name}"}

                    log_event(task_id, "tool_result", {"id": tc_id, "tool": fn_name, "result": res})
                    messages.append({"role": "tool", "tool_call_id": tc_id, "content": json.dumps(res, ensure_ascii=False)})
                if final_status == "cancelled": break
            else:
                break
        else:
            final_status = "limit_reached"
            log_event(task_id, "limit_reached", {"message": f"Reached {MAX_TURNS} turns"})
    except Exception as e:
        log_event(task_id, "error", {"error": sanitize_err(e)})
        final_status = "failed"
    finally:
        conn = get_db_connection()
        c = conn.cursor()
        c.execute("UPDATE tasks SET status = ? WHERE task_id = ? AND status = 'running'", (final_status, task_id))
        conn.commit()
        conn.close()
        with active_tasks_lock: active_tasks.pop(task_id, None)

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            self._send(200, {"status": "ok", "service": "openminis-cloud-agent", "version": "2.3.0"})
            return
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:].strip() != SERVER_TOKEN:
            self._send(401, {"error": "Unauthorized"})
            return
        if path == "/v1/sessions":
            conn = get_db_connection()
            c = conn.cursor()
            c.execute("SELECT session_id, title, created_at FROM sessions ORDER BY created_at DESC")
            sessions = [{"session_id": r[0], "title": r[1], "created_at": r[2]} for r in c.fetchall()]
            conn.close()
            self._send(200, {"sessions": sessions})
            return
        if path.startswith("/v1/sessions/"):
            sid = path[len("/v1/sessions/"):]
            conn = get_db_connection()
            c = conn.cursor()
            c.execute("SELECT session_id, title, created_at FROM sessions WHERE session_id = ?", (sid,))
            s = c.fetchone()
            if not s:
                conn.close()
                self._send(404, {"error": "Not found"})
                return
            c.execute("SELECT role, content, timestamp FROM messages WHERE session_id = ? ORDER BY id ASC", (sid,))
            msgs = [{"role": r[0], "content": r[1], "timestamp": r[2]} for r in c.fetchall()]
            c.execute("SELECT task_id, status, model, created_at FROM tasks WHERE session_id = ? ORDER BY created_at DESC", (sid,))
            tasks = [{"task_id": tr[0], "status": tr[1], "model": tr[2], "created_at": tr[3]} for tr in c.fetchall()]
            conn.close()
            self._send(200, {"session_id": s[0], "title": s[1], "created_at": s[2], "messages": msgs, "tasks": tasks})
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
            c.execute("SELECT event_type, payload, timestamp FROM task_events WHERE task_id = ? ORDER BY id ASC", (tid,))
            events = [{"type": er[0], "payload": json.loads(er[1]), "timestamp": er[2]} for er in c.fetchall()]
            conn.close()
            self._send(200, {"task_id": t[0], "session_id": t[1], "status": t[2], "model": t[3], "created_at": t[4], "events": events})
            return
        self._send(404, {"error": "Not found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:].strip() != SERVER_TOKEN:
            self._send(401, {"error": "Unauthorized"})
            return
        
        raw_len = self.headers.get("Content-Length", 0)
        try:
            length = int(raw_len)
        except Exception:
            self._send(400, {"error": "Invalid Content-Length"})
            return

        if length < 0 or length > 2 * 1024 * 1024:
            self._send(400 if length < 0 else 413, {"error": "Invalid body size or exceeds 2MB limit"})
            return

        req_json = {}
        if length > 0:
            try:
                body_bytes = self.rfile.read(length)
                req_json = json.loads(body_bytes.decode("utf-8"))
            except Exception:
                self._send(400, {"error": "Invalid JSON body"})
                return

        if not isinstance(req_json, dict):
            self._send(400, {"error": "Request body must be a JSON object"})
            return

        if path == "/v1/sessions":
            title = req_json.get("title", "Cloud Session")
            if not isinstance(title, str):
                self._send(400, {"error": "title must be a string"})
                return
            sid = "sess_" + uuid.uuid4().hex[:12]
            created_at = time.time()
            conn = get_db_connection()
            c = conn.cursor()
            c.execute("INSERT INTO sessions (session_id, title, created_at) VALUES (?, ?, ?)", (sid, title, created_at))
            conn.commit()
            conn.close()
            self._send(201, {"session_id": sid, "title": title, "created_at": created_at})
            return

        if path.startswith("/v1/sessions/") and path.endswith("/messages"):
            parts = path.split("/")
            sid = parts[3] if len(parts) >= 4 else ""
            
            content = req_json.get("content")
            if not isinstance(content, str) or not content.strip():
                self._send(400, {"error": "content must be a non-empty string"})
                return

            model = req_json.get("model", "gpt-4o")
            if not isinstance(model, str) or not model.strip():
                self._send(400, {"error": "model must be a non-empty string"})
                return

            provider = req_json.get("provider", {})
            if not isinstance(provider, dict):
                self._send(400, {"error": "provider must be a dictionary"})
                return

            protocol = provider.get("protocol", "chat")
            if not isinstance(protocol, str) or protocol != "chat":
                self._send(400, {"error": "Unsupported provider protocol. Only 'chat' is supported."})
                return

            api_key = provider.get("api_key", "")
            if not isinstance(api_key, str):
                self._send(400, {"error": "api_key must be a string"})
                return

            instructions = req_json.get("instructions", "You are a helpful cloud agent in OpenMinis.")
            if not isinstance(instructions, str):
                self._send(400, {"error": "instructions must be a string"})
                return

            base_url = provider.get("base_url", "https://api.openai.com/v1")
            ok, err = validate_base_url(base_url)
            if not ok:
                self._send(400, {"error": err})
                return

            conn = get_db_connection()
            c = conn.cursor()
            try:
                c.execute("BEGIN IMMEDIATE")
                c.execute("SELECT session_id FROM sessions WHERE session_id = ?", (sid,))
                if not c.fetchone():
                    conn.rollback()
                    conn.close()
                    self._send(404, {"error": "Session not found"})
                    return

                c.execute("SELECT task_id FROM tasks WHERE session_id = ? AND status = 'running'", (sid,))
                running = c.fetchone()
                if running:
                    conn.rollback()
                    conn.close()
                    self._send(409, {"error": "Conflict: Session has a running task", "running_task_id": running[0]})
                    return

                tid = "task_" + uuid.uuid4().hex[:12]
                created_at = time.time()
                c.execute("INSERT INTO tasks (task_id, session_id, status, model, created_at) VALUES (?, ?, 'running', ?, ?)", (tid, sid, model, created_at))
                conn.commit()
            except sqlite3.IntegrityError:
                conn.rollback()
                conn.close()
                self._send(409, {"error": "Conflict: Session already has a running task (integrity)"})
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

            with active_tasks_lock: active_tasks[tid] = {"process": None, "cancelled": False, "pid": None}
            threading.Thread(target=run_agent_task, args=(tid, sid, content, model, provider, instructions), daemon=True).start()
            self._send(202, {"task_id": tid, "session_id": sid, "status": "running"})
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
            c.execute("UPDATE tasks SET status = 'cancelled' WHERE task_id = ? AND status = 'running'", (tid,))
            conn.commit()
            conn.close()
            log_event(tid, "cancelled", {"message": "Cancelled via API"})
            self._send(200, {"task_id": tid, "status": "cancelled"})
            return

        self._send(404, {"error": "Not found"})

    def log_message(self, format, *args): pass

CloudAgentHandler = Handler

def run_server():
    global SERVER_TOKEN
    if not SERVER_TOKEN: SERVER_TOKEN = validate_and_load_token()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"OpenMinis Cloud Agent running on {HOST}:{PORT}")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
