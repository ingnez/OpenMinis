"""模型调用的提速工具：连接复用、流式输出、按需发送工具定义、过长上下文自动裁剪。

- HTTPPool：按 (scheme, host, port) 复用 keep-alive 连接（含 TLS 会话），出错自动重连一次；不跟随重定向。
- chat_completion：stream=True 时边收边回调 on_text(累计文字)，最后拼出与非流式一致的 message；
  服务商忽略 stream 直接回 JSON 也能处理。
- select_tools：只发核心工具 + 和对话相关的工具 + 会话里用过的工具，另给一个 request_tools 让模型按需加。
- trim_messages：估算 token 超过阈值时，先截短旧的工具输出，再从最早的完整轮次开始省略。
"""
import http.client
import io
import json
import re
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class HTTPPool:
    def __init__(self, max_idle=4):
        self.lock = threading.Lock()
        self.idle = {}
        self.max_idle = max_idle
        self.ctx = ssl.create_default_context()
        self.stats = {"new": 0, "reused": 0}
        self.recent = {}          # 最近用过的服务商地址 -> 时间，用于预热

    def _key(self, u):
        port = u.port or (443 if u.scheme == "https" else 80)
        return (u.scheme, u.hostname, port)

    def _get(self, key, timeout):
        with self.lock:
            lst = self.idle.get(key) or []
            while lst:
                conn, t = lst.pop()
                if time.time() - t < 50:      # 服务商一般 60s 关闭空闲连接
                    self.stats["reused"] += 1
                    conn.timeout = timeout
                    if conn.sock:
                        conn.sock.settimeout(timeout)
                    return conn, True
                conn.close()
        self.stats["new"] += 1
        scheme, host, port = key
        if scheme == "https":
            return http.client.HTTPSConnection(host, port, timeout=timeout, context=self.ctx), False
        return http.client.HTTPConnection(host, port, timeout=timeout), False

    def _put(self, key, conn):
        with self.lock:
            lst = self.idle.setdefault(key, [])
            if len(lst) < self.max_idle:
                lst.append((conn, time.time()))
                return
        conn.close()

    def close_all(self):
        """关闭所有空闲连接（换服务商 / 测试收尾时用）。"""
        with self.lock:
            conns = [c for lst in self.idle.values() for c, _ in lst]
            self.idle.clear()
        for c in conns:
            try:
                c.close()
            except Exception:
                pass

    def warm(self, url, timeout=5):
        """预先建立连接（TCP + TLS），用户打开对话 / 开始输入时调用。"""
        u = urllib.parse.urlsplit(url)
        key = self._key(u)
        with self.lock:
            if self.idle.get(key):
                return False
        conn, _ = self._get(key, timeout)
        try:
            conn.connect()
            self._put(key, conn)
            return True
        except OSError:
            conn.close()
            return False

    def warm_known(self, max_age=1800):
        """预热最近半小时用过的服务商连接；返回新建的连接数。"""
        now = time.time()
        with self.lock:
            urls = [u for u, t in self.recent.items() if now - t < max_age]
        return sum(1 for u in urls if self.warm(u))

    def post(self, url, headers, payload, timeout=120):
        """返回 (response, release)。调用方读完后调用 release(ok)。"""
        u = urllib.parse.urlsplit(url)
        with self.lock:
            self.recent[url] = time.time()
            if len(self.recent) > 16:
                self.recent.pop(min(self.recent, key=self.recent.get))
        if u.scheme not in ("http", "https"):
            raise ValueError("unsupported url scheme")
        key = self._key(u)
        path = (u.path or "/") + (("?" + u.query) if u.query else "")
        body = json.dumps(payload).encode("utf-8")
        hdrs = dict(headers)
        hdrs["Content-Length"] = str(len(body))
        hdrs.setdefault("Connection", "keep-alive")
        for attempt in (0, 1):
            conn, reused = self._get(key, timeout)
            try:
                conn.request("POST", path, body=body, headers=hdrs)
                resp = conn.getresponse()
            except (http.client.HTTPException, OSError):
                conn.close()
                if reused and attempt == 0:
                    continue          # 复用的连接已被对方关闭：换新连接重试一次
                raise

            def release(ok, conn=conn, resp=resp):
                if ok and not resp.will_close:
                    self._put(key, conn)
                else:
                    conn.close()
            return resp, release
        raise OSError("unreachable")


POOL = HTTPPool()


def _proxied(url):
    u = urllib.parse.urlsplit(url)
    proxies = urllib.request.getproxies()
    return bool(proxies.get(u.scheme)) and not urllib.request.proxy_bypass(u.hostname or "")


def _http_error(url, resp, data):
    return urllib.error.HTTPError(url, resp.status, resp.reason, resp.headers, io.BytesIO(data))


class Aborted(Exception):
    """调用方要求中止正在接收的回复（例如用户插话）。"""


def _reasoning_of(d):
    # DeepSeek / Qwen / Kimi 用 reasoning_content，OpenRouter 等用 reasoning
    v = d.get("reasoning_content")
    if not v and isinstance(d.get("reasoning"), str):
        v = d["reasoning"]
    return v or None


def chat_completion(url, headers, body, stream=False, on_text=None, timeout=120, pool=POOL, on_reasoning=None, should_abort=None):
    """返回 (response_dict, timing)。timing: ttft_ms（首个内容块）、total_ms、streamed。"""
    t0 = time.perf_counter()
    if _proxied(url):
        # 配了 HTTP(S) 代理：走 urllib（自动用代理），不流式
        req = urllib.request.Request(url, data=json.dumps(dict(body, stream=False)).encode("utf-8"), headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            out = json.loads(r.read().decode("utf-8"))
        ms = (time.perf_counter() - t0) * 1000
        return out, {"ttft_ms": round(ms, 1), "total_ms": round(ms, 1), "streamed": False}
    payload = dict(body, stream=bool(stream))
    resp, release = pool.post(url, headers, payload, timeout)
    ok = False
    try:
        if resp.status >= 300:
            data = resp.read()
            ok = True
            raise _http_error(url, resp, data)
        ctype = (resp.getheader("Content-Type") or "").lower()
        if not stream or "text/event-stream" not in ctype:
            data = resp.read()
            ok = True
            out = json.loads(data.decode("utf-8"))
            ms = (time.perf_counter() - t0) * 1000
            m0 = ((out.get("choices") or [{}])[0].get("message") or {}) if isinstance(out, dict) else {}
            text = m0.get("content")
            r0 = _reasoning_of(m0)
            if r0:
                m0["reasoning_content"] = r0
                if on_reasoning:
                    on_reasoning(r0)
            if text and on_text:
                on_text(text)
            return out, {"ttft_ms": round(ms, 1), "total_ms": round(ms, 1), "streamed": False}
        content, tool_calls, usage, finish, role = [], {}, None, None, "assistant"
        served_model = None
        reasoning = []
        ttft = None
        last_emit = 0.0
        last_r_emit = 0.0
        while True:
            if should_abort and should_abort():
                raise Aborted()
            line = resp.readline()
            if not line:
                break
            line = line.strip()
            if not line.startswith(b"data:"):
                continue
            data = line[5:].strip()
            if data == b"[DONE]":
                break
            try:
                chunk = json.loads(data.decode("utf-8"))
            except ValueError:
                continue
            if chunk.get("usage"):
                usage = chunk["usage"]
            if chunk.get("model"):
                served_model = chunk["model"]
            for ch in chunk.get("choices") or []:
                d = ch.get("delta") or {}
                rdelta = _reasoning_of(d)
                if ttft is None and (d.get("content") or d.get("tool_calls") or rdelta):
                    ttft = (time.perf_counter() - t0) * 1000
                if d.get("content"):
                    content.append(d["content"])
                    now = time.perf_counter()
                    if on_text and now - last_emit > 0.08:
                        last_emit = now
                        on_text("".join(content))
                if rdelta:
                    reasoning.append(rdelta)
                    now = time.perf_counter()
                    if on_reasoning and now - last_r_emit > 0.15:
                        last_r_emit = now
                        on_reasoning("".join(reasoning))
                for tc in d.get("tool_calls") or []:
                    slot = tool_calls.setdefault(tc.get("index", 0), {"id": None, "type": "function", "function": {"name": "", "arguments": ""}})
                    if tc.get("id"):
                        slot["id"] = tc["id"]
                    fn = tc.get("function") or {}
                    if fn.get("name"):
                        slot["function"]["name"] += fn["name"]
                    if fn.get("arguments"):
                        slot["function"]["arguments"] += fn["arguments"]
                if ch.get("finish_reason"):
                    finish = ch["finish_reason"]
        try:
            resp.read()          # 读完剩余部分（结束块），连接才能复用
            ok = True
        except (http.client.HTTPException, OSError):
            ok = False
        text = "".join(content)
        if on_reasoning and reasoning:
            on_reasoning("".join(reasoning))
        if on_text and text:
            on_text(text)
        msg = {"role": role, "content": text or None}
        if reasoning:
            # DeepSeek 等思考模式：带工具调用的这一轮要把 reasoning_content 原样传回，否则下一次请求会 400
            msg["reasoning_content"] = "".join(reasoning)
        if tool_calls:
            msg["tool_calls"] = [dict(v, id=v["id"] or f"call_{i}") for i, v in sorted(tool_calls.items())]
        out = {"choices": [{"index": 0, "message": msg, "finish_reason": finish or "stop"}]}
        if usage:
            out["usage"] = usage
        if served_model:
            out["model"] = served_model     # 中转站实际返回的模型名（纯度检查用）
        total = (time.perf_counter() - t0) * 1000
        return out, {"ttft_ms": round(ttft if ttft is not None else total, 1), "total_ms": round(total, 1), "streamed": True}
    finally:
        release(ok)


# ---------------- 按需发送工具 ----------------

CORE_TOOLS = {"shell_execute", "file_read", "file_write", "file_edit", "memory_write", "memory_search", "skill_load",
              "subagent_task", "background_jobs"}
TOOL_TRIGGERS = {
    "create_bot": r"bot|机器人|助手|新建|创建|建一个|加一个",
    "update_bot": r"bot|机器人|助手|改|设置|提示词|模型|头像",
    "delete_bot": r"bot|机器人|助手|删",
    "restore_bot": r"bot|机器人|助手|恢复|回收站|撤销",
    "set_primary_bot": r"主 ?bot|主机器人|主助手",
    "admin_api": r"bot|机器人|插件|代理|记忆|技能|例行|定时|设置|权限|审批|隔离|云电脑|桌面|管理|日志|plugin|proxy|memory|skill|routine",
    "recall_snapshot": r"快照|snapshot|之前|上次|刚才|前面|重置|reset|继续|接着",
    "browser_action": r"网页|网站|浏览|链接|http|www\.|url|登录|搜索|查一下|search|web|打开|下单|购买|价格|新闻|天气",
    "desktop_action": r"桌面|屏幕|desktop|screen|点击|窗口|截图|gui",
    "request_user_takeover": r"登录|验证码|captcha|login|扫码|二维码|帮我登",
    "image_generate": r"图片|画一|画个|生成图|配图|插画|海报|image|picture|draw|logo|头像",
    "send_message": r"telegram|推送|通知我|提醒我|发给我|发消息|send",
    "page_write": r"页面|报告|dashboard|看板|html|图表|仪表盘|page|可视化",
    "list_bots": r"bot|@|交给|委托|让.{0,12}(做|查|写|看)|问问|其他助手",
    "send_to_bot": r"bot|@|交给|委托|让.{0,12}(做|查|写|看)|问问|告诉",
    "delegate_task": r"bot|@|交给|委托|让.{0,12}(做|查|写|看)|问问",
    "skill_save": r"技能|skill|流程|工作流|下次|以后|保存.*步骤|记住.*做法",
}
REQUEST_TOOLS_DEF = {"type": "function", "function": {
    "name": "request_tools",
    "description": "Enable more tools for the next step when the ones you have are not enough. Available: {names}.",
    "parameters": {"type": "object", "properties": {"names": {"type": "array", "items": {"type": "string"}}}, "required": ["names"]}}}


def _text_of(m):
    c = m.get("content")
    if isinstance(c, list):
        return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
    return c or ""


def select_tools(all_defs, messages, extra=(), always_all=False):
    """返回 (tools, omitted_names)。always_all=True 时全部发送（关闭按需加载）。"""
    if always_all:
        return list(all_defs), []
    names = {d["function"]["name"] for d in all_defs}
    keep = set(CORE_TOOLS) | set(extra)
    used = set()
    for m in messages:
        for tc in m.get("tool_calls") or []:
            used.add(((tc.get("function") or {}).get("name")) or "")
    keep |= used
    recent = " ".join(_text_of(m) for m in messages[-6:] if m.get("role") in ("user", "assistant")).lower()
    for name, pat in TOOL_TRIGGERS.items():
        if re.search(pat, recent, re.IGNORECASE):
            keep.add(name)
    # 不认识的（插件等）工具一律保留
    keep |= {n for n in names if n not in CORE_TOOLS and n not in TOOL_TRIGGERS}
    tools = [d for d in all_defs if d["function"]["name"] in keep]
    omitted = sorted(n for n in names if n not in keep)
    if omitted:
        meta = json.loads(json.dumps(REQUEST_TOOLS_DEF))
        meta["function"]["description"] = meta["function"]["description"].format(names=", ".join(omitted))
        tools.append(meta)
    return tools, omitted


# ---------------- 上下文裁剪 ----------------

def estimate_tokens(obj):
    s = obj if isinstance(obj, str) else json.dumps(obj, ensure_ascii=False)
    cjk = sum(1 for ch in s if "\u4e00" <= ch <= "\u9fff")
    return cjk + (len(s) - cjk) // 4 + 1


def trim_messages(messages, limit, keep_recent=8, tool_keep_chars=600):
    """messages[0] 是 system。返回 (新列表, 说明 or None)；不修改传入的列表。"""
    if not limit or estimate_tokens(messages) <= limit:
        return messages, None
    out = [dict(m) for m in messages]
    cut_tools = 0
    for m in out[1:-keep_recent]:
        if m.get("role") == "tool" and isinstance(m.get("content"), str) and len(m["content"]) > tool_keep_chars:
            n = len(m["content"])
            m["content"] = m["content"][:tool_keep_chars] + f"…[较早的工具输出已截短，原文 {n} 字]"
            cut_tools += 1
    dropped = 0
    while estimate_tokens(out) > limit and len(out) > keep_recent + 2:
        # 从最早的一轮开始整轮删除（到下一条 user 消息为止），保证 tool_calls 与 tool 结果成对
        i = 1
        j = i + 1
        while j < len(out) - keep_recent and out[j].get("role") != "user":
            j += 1
        if j >= len(out) - keep_recent:
            break
        dropped += j - i
        del out[i:j]
    note = None
    if cut_tools or dropped:
        note = f"[上下文已自动精简：截短 {cut_tools} 条较早的工具输出，省略最早的 {dropped} 条消息]"
        if isinstance(out[0].get("content"), str):
            out[0]["content"] = out[0]["content"] + "\n" + note
    return out, note
