# -*- coding: utf-8 -*-
"""最小 MCP 客户端（标准库）：stdio（换行分隔 JSON-RPC）与 Streamable HTTP。

只实现 Agent 需要的 initialize / tools/list / tools/call。HTTP 传输兼容返回
application/json 与 text/event-stream 两种响应，并回传 Mcp-Session-Id。
"""

import json
import os
import queue
import subprocess
import threading
import time
import urllib.error
import urllib.request

PROTOCOL_VERSION = "2025-03-26"
CLIENT_INFO = {"name": "openminis-cloud-agent", "version": "1.0"}


class MCPError(Exception):
    pass


class MCPAuthRequired(MCPError):
    """远端返回 401/403：需要用户补充或更新凭据 / 完成 OAuth。"""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "Redirection prohibited", headers, fp)


STDERR_TAIL_CHARS = 4000
# 首次 initialize：uvx/npx 可能要从 PyPI/npm 拉包，60 秒经常不够
STDIO_INIT_TIMEOUT = 180


class StdioClient:
    def __init__(self, command, args=None, env=None, cwd=None, timeout=60):
        self.timeout = timeout
        full_env = dict(os.environ)
        full_env.update(env or {})
        self._stderr_chunks = []
        self._stderr_lock = threading.Lock()
        self.proc = subprocess.Popen([command] + list(args or []), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=full_env, cwd=cwd, text=True, bufsize=1)
        self._lines = queue.Queue()
        self._next = 0
        self._lock = threading.Lock()
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._stderr_reader, daemon=True).start()

    def _stderr_reader(self):
        # 必须按行读：read(n) 会等到满 n 个字符或 EOF，短日志在超时前一直进不了缓冲区
        try:
            for line in iter(self.proc.stderr.readline, ""):
                with self._stderr_lock:
                    self._stderr_chunks.append(line)
                    joined = "".join(self._stderr_chunks)
                    if len(joined) > STDERR_TAIL_CHARS * 2:
                        self._stderr_chunks = [joined[-STDERR_TAIL_CHARS:]]
        except Exception:
            pass

    def stderr_tail(self):
        with self._stderr_lock:
            text = "".join(self._stderr_chunks)
        return text[-STDERR_TAIL_CHARS:].strip()

    def _reader(self):
        for line in self.proc.stdout:
            self._lines.put(line)
        self._lines.put(None)

    def _send(self, obj):
        self.proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def request(self, method, params=None, timeout=None):
        with self._lock:
            self._next += 1
            rid = self._next
            try:
                self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
            except (BrokenPipeError, OSError) as e:
                raise MCPError(f"MCP 进程已退出：{e}")
            while True:
                try:
                    line = self._lines.get(timeout=timeout or self.timeout)
                except queue.Empty:
                    raise MCPError(f"MCP 请求超时：{method}")
                if line is None:
                    raise MCPError("MCP 进程已退出")
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue  # 忽略非 JSON 输出（部分服务器会打印日志）
                if msg.get("id") == rid and ("result" in msg or "error" in msg):
                    if "error" in msg:
                        raise MCPError(str(msg["error"].get("message") if isinstance(msg["error"], dict) else msg["error"]))
                    return msg["result"]

    def notify(self, method, params=None):
        with self._lock:
            self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def alive(self):
        return self.proc.poll() is None

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


class HttpClient:
    def __init__(self, url, headers=None, timeout=60):
        self.url = url
        self.headers = dict(headers or {})
        self.timeout = timeout
        self.session_id = None
        self._next = 0
        self._lock = threading.Lock()
        self._opener = urllib.request.build_opener(_NoRedirect)

    def _post(self, obj, timeout=None):
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
             "MCP-Protocol-Version": PROTOCOL_VERSION}
        h.update(self.headers)
        if self.session_id:
            h["Mcp-Session-Id"] = self.session_id
        req = urllib.request.Request(self.url, data=json.dumps(obj).encode("utf-8"), headers=h, method="POST")
        try:
            resp = self._opener.open(req, timeout=timeout or self.timeout)
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise MCPAuthRequired(f"HTTP {e.code}：需要授权")
            raise MCPError(f"HTTP {e.code}")
        except urllib.error.URLError as e:
            raise MCPError(f"无法连接 MCP 服务器：{e.reason}")
        with resp:
            sid = resp.headers.get("Mcp-Session-Id")
            if sid:
                self.session_id = sid
            ctype = resp.headers.get("Content-Type", "")
            body = resp.read(8 * 1024 * 1024).decode("utf-8", "replace")
        if not body.strip():
            return []
        if "text/event-stream" in ctype:
            out = []
            for block in body.split("\n\n"):
                data = "\n".join(l[5:].lstrip() for l in block.splitlines() if l.startswith("data:"))
                if data:
                    try:
                        out.append(json.loads(data))
                    except ValueError:
                        pass
            return out
        parsed = json.loads(body)
        return parsed if isinstance(parsed, list) else [parsed]

    def request(self, method, params=None, timeout=None):
        with self._lock:
            self._next += 1
            rid = self._next
        for msg in self._post({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}, timeout):
            if isinstance(msg, dict) and msg.get("id") == rid:
                if "error" in msg:
                    raise MCPError(str(msg["error"].get("message") if isinstance(msg["error"], dict) else msg["error"]))
                return msg.get("result")
        raise MCPError(f"MCP 服务器没有返回 {method} 的结果")

    def notify(self, method, params=None):
        try:
            self._post({"jsonrpc": "2.0", "method": method, "params": params or {}})
        except MCPAuthRequired:
            raise
        except MCPError:
            pass

    def alive(self):
        return True

    def close(self):
        pass


def _annotate_mcp_error(err, client):
    """把 stdio 进程 stderr 尾部附进错误，方便定位 uvx/npx 拉包失败。"""
    if hasattr(client, "stderr_tail") and not client.stderr_tail():
        time.sleep(0.05)
    tail = client.stderr_tail() if hasattr(client, "stderr_tail") else ""
    if not tail:
        return err if isinstance(err, MCPError) else MCPError(str(err))
    msg = str(err)
    if "stderr：" in msg or tail[:200] in msg:
        return err if isinstance(err, MCPError) else MCPError(msg)
    annotated = f"{msg}（stderr：{tail[-800:]}）"
    if isinstance(err, MCPAuthRequired):
        return err
    return MCPError(annotated)


def connect(spec, env=None, headers=None, cwd=None, timeout=None):
    """按 spec（{"transport":"stdio","command","args"} 或 {"transport":"http","url"}）建立连接并完成握手。

    stdio 首次 initialize 默认等 180 秒（uvx 冷启动拉包），失败再自动重试一次；
    显式传入 timeout 时以传入值为准（单元测试可缩短）。HTTP 默认仍是 60 秒。
    """
    http = spec.get("transport") == "http"
    if timeout is None:
        init_timeout = 60 if http else STDIO_INIT_TIMEOUT
    else:
        init_timeout = timeout
    later_timeout = timeout if timeout is not None else 60

    def _handshake():
        if http:
            client = HttpClient(spec["url"], headers=headers, timeout=later_timeout)
        else:
            client = StdioClient(spec["command"], spec.get("args"), env=env, cwd=cwd, timeout=later_timeout)
        try:
            client.request("initialize", {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": CLIENT_INFO},
                           timeout=init_timeout)
            client.notify("notifications/initialized")
            client.timeout = later_timeout
            return client
        except MCPAuthRequired:
            client.close()
            raise
        except Exception as e:
            wrapped = _annotate_mcp_error(e, client)
            client.close()
            raise wrapped

    try:
        return _handshake()
    except MCPAuthRequired:
        raise
    except MCPError:
        if http:
            raise
        # 第一次 uvx 可能在下载中途失败；新进程常能命中缓存
        return _handshake()


def list_tools(client):
    tools, cursor = [], None
    for _ in range(20):
        res = client.request("tools/list", {"cursor": cursor} if cursor else {}) or {}
        tools.extend(t for t in res.get("tools", []) if isinstance(t, dict) and isinstance(t.get("name"), str))
        cursor = res.get("nextCursor")
        if not cursor:
            break
    return tools


def call_tool(client, name, arguments, timeout=120):
    res = client.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=timeout) or {}
    parts = []
    for c in res.get("content", []) or []:
        if not isinstance(c, dict):
            continue
        if c.get("type") == "text":
            parts.append(c.get("text", ""))
        elif c.get("type") == "resource" and isinstance(c.get("resource"), dict):
            parts.append(c["resource"].get("text") or f"[resource {c['resource'].get('uri')}]")
        else:
            parts.append(f"[{c.get('type')} 内容未展开]")
    out = {"content": "\n".join(parts)[:60000], "is_error": bool(res.get("isError"))}
    if res.get("structuredContent") is not None:
        out["structured"] = res["structuredContent"]
    return out
