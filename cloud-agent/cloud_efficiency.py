# -*- coding: utf-8 -*-
"""提效：自动标题（小模型或截取首句）、非 Claude 模型的提示缓存提示、缓存命中统计、短时缓存、
中转站纯度检查、主模型失败时换备用。全部是纯函数或小工具，模型调用由调用方传入 chat(body) -> resp。"""
import json
import re
import threading
import time
import uuid

# ---------------- 自动标题 ----------------

_TITLE_STRIP = re.compile(r"^[\s\"'“”‘’《》【】\[\]（）()#*>\-:：]+|[\s\"'“”‘’《》【】\[\]（）()#*。！？!?.,，:：]+$")


def heuristic_title(text, limit=16):
    """不调模型：取用户第一句话（去掉称呼、标点），最多 limit 个字。"""
    t = (text or "").strip()
    if t.startswith("["):     # message_parts JSON
        try:
            t = " ".join(p.get("text", "") for p in json.loads(t) if isinstance(p, dict) and p.get("type") == "text")
        except (ValueError, TypeError, AttributeError):
            pass
    t = re.sub(r"^@\S+\s*", "", t)
    t = re.split(r"[\n。！？!?]", t, maxsplit=1)[0]
    t = re.sub(r"^(请|帮我|麻烦|你好[，,]?|hi[，,]?\s*|hello[，,]?\s*)", "", t, flags=re.I)
    t = _TITLE_STRIP.sub("", t)
    return (t[:limit] + ("…" if len(t) > limit else "")) if t else ""


def clean_model_title(raw, limit=20):
    t = (raw or "").strip().splitlines()[0] if (raw or "").strip() else ""
    t = re.sub(r"^(标题|title)\s*[:：]\s*", "", t, flags=re.I)
    t = _TITLE_STRIP.sub("", t)
    return t[:limit]


def title_prompt(user_text, answer_text):
    return [
        {"role": "system", "content": "你给对话起标题。只输出标题本身：中文 4 到 12 个字，概括用户要做的事，不要标点、引号、表情或解释。"},
        {"role": "user", "content": f"用户：{(user_text or '')[:600]}\n助手：{(answer_text or '')[:600]}"},
    ]


def is_default_title(title):
    """创建时的默认标题（「Bot 名 · 日期」「云端会话」「新对话」）才自动改，用户改过的不动。"""
    t = (title or "").strip()
    return not t or t in ("云端会话", "新对话", "新会话") or bool(re.search(r" · .*\d", t))


# ---------------- 非 Claude 模型的提示缓存 ----------------

def cache_family(model):
    m = (model or "").lower()
    if "claude" in m:
        return "claude"
    if "qwen" in m:
        return "qwen"            # 阿里云百炼 OpenAI 兼容接口支持 cache_control 显式缓存
    if re.search(r"(^|/)(gpt-|o\d|chatgpt)", m):
        return "openai"          # 自动前缀缓存；prompt_cache_key 让同一 Bot 的请求落到同一缓存
    if "deepseek" in m or "gemini" in m or "glm" in m or "kimi" in m or "moonshot" in m or "doubao" in m:
        return "auto"            # 服务商自动前缀缓存：只要系统提示保持不变即可命中
    return None


def with_cache_hints(body, cache_key=None, stream=False):
    """按模型家族加缓存提示；返回新 body（不修改原对象）。服务商拒绝时由调用方去掉重试。"""
    fam = cache_family(body.get("model"))
    out = dict(body)
    if stream:
        out["stream_options"] = {"include_usage": True}   # 流式时也拿到 usage（token 统计、缓存命中）
    msgs = out.get("messages") or []
    if fam in ("claude", "qwen") and msgs and msgs[0].get("role") == "system" and isinstance(msgs[0].get("content"), str):
        sys_msg = {"role": "system", "content": [{"type": "text", "text": msgs[0]["content"], "cache_control": {"type": "ephemeral"}}]}
        out["messages"] = [sys_msg] + list(msgs[1:])
    if fam == "openai" and cache_key:
        out["prompt_cache_key"] = str(cache_key)[:64]
    return out


def cached_tokens(usage):
    """各家 usage 里的缓存命中 token：OpenAI prompt_tokens_details.cached_tokens、DeepSeek prompt_cache_hit_tokens、
    Anthropic 兼容 cache_read_input_tokens。"""
    if not isinstance(usage, dict):
        return 0
    for v in ((usage.get("prompt_tokens_details") or {}).get("cached_tokens"),
              usage.get("prompt_cache_hit_tokens"), usage.get("cache_read_input_tokens"), usage.get("cached_tokens")):
        if isinstance(v, (int, float)) and v > 0:
            return int(v)
    return 0


# ---------------- 短时缓存 ----------------

class TTLCache:
    def __init__(self, ttl=15.0, cap=64):
        self.ttl, self.cap = ttl, cap
        self._d = {}
        self._lock = threading.Lock()
        self.generation = 0

    def get(self, key):
        with self._lock:
            hit = self._d.get(key)
            if hit and hit[0] == self.generation and time.time() - hit[1] < self.ttl:
                return hit[2]
            return None

    def put(self, key, value):
        with self._lock:
            if len(self._d) >= self.cap:
                oldest = min(self._d, key=lambda k: self._d[k][1])
                self._d.pop(oldest, None)
            self._d[key] = (self.generation, time.time(), value)

    def invalidate(self):
        with self._lock:
            self.generation += 1


# ---------------- 失败切换 ----------------

def is_failover_error(e):
    """值得换备用服务商的错误：5xx、429、超时、连接失败；4xx 参数错误不换（换了也一样错）。"""
    code = getattr(e, "code", None)
    if isinstance(code, int):
        return code >= 500 or code in (408, 429)
    name = type(e).__name__.lower()
    text = str(e).lower()
    return any(k in name for k in ("timeout", "connection", "remotedisconnected", "urlerror")) or \
        any(k in text for k in ("timed out", "timeout", "connection reset", "connection refused", "remote end closed"))


# ---------------- 中转站纯度检查 ----------------

def _text(resp):
    try:
        return ((resp.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
    except AttributeError:
        return ""


def relay_check(chat, model, needle_tokens=6000):
    """对一个服务商 / 中转站做体检。chat(body) -> (resp, timing)。返回 {"checks": [...], "ok": bool}。
    每项 {"id","name","ok","detail"}，ok 为 None 表示无法判断。只用真实请求的结果，不估计。"""
    checks = []

    def add(cid, name, ok, detail):
        checks.append({"id": cid, "name": name, "ok": ok, "detail": detail})

    # 1. 原样复述：检测是否偷偷注入系统提示 / 改写输出
    code = uuid.uuid4().hex[:12]
    try:
        resp, timing = chat({"model": model, "temperature": 0, "max_tokens": 40, "messages": [
            {"role": "user", "content": f"只回复这串字符，不要任何其他内容：{code}"}]})
        out = _text(resp).strip()
        add("echo", "原样复述", out == code, f"回复「{out[:60]}」，首字 {timing.get('ttft_ms')} ms")
        served = resp.get("model")
        if served:
            same = served.lower().split("/")[-1].startswith(model.lower().split("/")[-1][:12]) or model.lower() in served.lower()
            add("model_name", "返回的模型名", same, f"请求 {model}，返回 {served}")
        else:
            add("model_name", "返回的模型名", None, "没有返回 model 字段")
        u = resp.get("usage") or {}
        pt = u.get("prompt_tokens")
        if isinstance(pt, int):
            # 这条请求实际只有约 30 个 token；远超说明被注入了大段隐藏提示或计费虚高
            add("billing", "输入 token 计费", pt <= 120, f"这条约 30 token 的请求计费 {pt} token" + ("（偏高：可能注入了隐藏提示或计费虚高）" if pt > 120 else ""))
        else:
            add("billing", "输入 token 计费", None, "没有返回 usage")
    except Exception as e:
        add("echo", "原样复述", False, f"请求失败：{type(e).__name__}: {str(e)[:160]}")
        return {"checks": checks, "ok": False}

    # 2. 系统提示是否被替换：要求按系统提示的暗号回答
    secret = uuid.uuid4().hex[:8]
    try:
        resp, _t = chat({"model": model, "temperature": 0, "max_tokens": 40, "messages": [
            {"role": "system", "content": f"暗号是 {secret}。用户问暗号时只回复暗号。"},
            {"role": "user", "content": "暗号是什么？"}]})
        out = _text(resp)
        add("system", "系统提示生效", secret in out, f"回复「{out.strip()[:60]}」")
    except Exception as e:
        add("system", "系统提示生效", False, f"请求失败：{type(e).__name__}")

    # 3. 长上下文截断：开头埋一个数字，约 needle_tokens token 之后问它
    if needle_tokens > 0:
        pin = str(uuid.uuid4().int % 900000 + 100000)
        filler = "这是一段用于测试上下文长度的填充文字，没有任何含义。" * max(1, needle_tokens // 20)
        try:
            resp, _t = chat({"model": model, "temperature": 0, "max_tokens": 30, "messages": [
                {"role": "user", "content": f"记住编号 {pin}。\n{filler}\n上面最开头让你记住的编号是多少？只回复数字。"}]})
            out = _text(resp)
            u = resp.get("usage") or {}
            add("context", f"长上下文（约 {needle_tokens} token）", pin in out,
                f"回复「{out.strip()[:40]}」，计费输入 {u.get('prompt_tokens', '?')} token")
        except Exception as e:
            add("context", f"长上下文（约 {needle_tokens} token）", False, f"请求失败：{type(e).__name__}: {str(e)[:120]}")

    ok = all(c["ok"] is not False for c in checks)
    return {"checks": checks, "ok": ok}


# ---------- 自动选模型 ----------
_HEAVY = re.compile(r"(https?://|```|代码|编程|脚本|写一|写个|写篇|写份|分析|总结|搜索|搜一|查一下|查查|帮我[做办订买发打查找]|打开|网页|浏览器|文件|表格|计划|规划|方案|翻译这|论文|文献|报告|步骤|部署|安装|debug|code|script|search|browse|file|plan|analy|summar|翻译下面)", re.I)


def is_simple_request(content):
    """短、单句、看不出要用工具的问题，交给快速模型；拿不准就不算简单（宁可慢一点也别答坏）。"""
    if not isinstance(content, str):
        return False            # 带图片 / 附件
    t = content.strip()
    if not t or len(t) > 80 or t.count("\n") > 1 or t.startswith("["):
        return False
    return not _HEAVY.search(t)
