# -*- coding: utf-8 -*-
"""命名密钥占位符与脱敏。

模型与事件里只允许出现 {{secret:NAME}}（NAME 为 UPPER_SNAKE）。
真实值只在工具真正执行前一刻替换进去；写库、回给模型、推到界面之前都要脱敏。
脱敏会同时覆盖明文以及常见编码变体（JSON 转义、URL、hex、Base64），避免绕过。

用户把疑似密钥贴进对话时，入站文本会先被换成「[疑似密钥已隐藏]」，原文不进消息表、不进模型。
本模块的测试与示例只用明显的假值，不存放真实密钥。
"""

import base64
import binascii
import json
import re
import time
import urllib.parse

import cloud_secrets

# 占位符：{{secret:NAME}}，NAME 以大写字母开头，后接大写字母/数字/下划线，最长 64
NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
PLACEHOLDER_RE = re.compile(r"\{\{secret:([A-Z][A-Z0-9_]{0,63})\}\}")
MASK = "[疑似密钥已隐藏]"
HIDDEN = "[secret:%s]"

# 常见公开前缀（厂商文档里的格式）。只用来遮罩误贴进聊天的内容。
# 不把匹配到的原文写入日志。
_PASTED = re.compile(
    r"\b("
    r"sk-ant-[A-Za-z0-9_\-]{20,}"
    r"|sk-[A-Za-z0-9_\-]{20,}"
    r"|xai-[A-Za-z0-9]{20,}"
    r"|gh[pousr]_[A-Za-z0-9]{30,}"
    r"|github_pat_[A-Za-z0-9_]{30,}"
    r"|glpat-[A-Za-z0-9_\-]{20,}"
    r"|xox[abprs]-[A-Za-z0-9\-]{10,}"
    r"|AKIA[0-9A-Z]{16}"
    r"|AIza[0-9A-Za-z_\-]{35}"
    r")\b"
)


class SecretRefError(ValueError):
    pass


def valid_name(name):
    return isinstance(name, str) and bool(NAME_RE.match(name))


def find_refs(text):
    if not isinstance(text, str):
        return []
    seen, out = set(), []
    for name in PLACEHOLDER_RE.findall(text):
        if name not in seen:
            seen.add(name)
            out.append(name)
    return out


def refs_in(value):
    names = []
    def walk(v):
        if isinstance(v, str):
            names.extend(find_refs(v))
        elif isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    walk(value)
    # 去重且保序
    seen, out = set(), []
    for n in names:
        if n not in seen:
            seen.add(n)
            out.append(n)
    return out


def encoded_variants(value):
    """一个密钥可能出现的编码形式：原文、JSON 转义、URL、hex、常见 Base64。"""
    if not isinstance(value, str) or len(value) < 4:
        return []
    raw = value.encode("utf-8")
    found = {value}
    try:
        dumped = json.dumps(value, ensure_ascii=False)
        if len(dumped) >= 2 and dumped[0] == dumped[-1] == '"':
            found.add(dumped[1:-1])
    except Exception:
        pass
    if len(value) >= 6:
        found.add(urllib.parse.quote(value, safe=""))
        found.add(urllib.parse.quote(value, safe="/"))
        found.add(binascii.hexlify(raw).decode("ascii"))
        found.add(binascii.hexlify(raw).decode("ascii").upper())
        for encoder in (base64.standard_b64encode, base64.urlsafe_b64encode):
            padded = encoder(raw).decode("ascii")
            found.add(padded)
            found.add(padded.rstrip("="))
    return [s for s in found if len(s) >= 4]


def mask_pasted(text):
    """把疑似贴进来的密钥换成固定遮罩。返回 (新文本, 是否发生了替换)。"""
    if not isinstance(text, str) or not text:
        return text, False
    new, n = _PASTED.subn(MASK, text)
    return new, n > 0


def mask_value(value):
    """对字符串或 message_parts 结构做入站遮罩。返回 (新值, 是否替换)。"""
    changed = False
    if isinstance(value, str):
        return mask_pasted(value)
    if isinstance(value, list):
        out = []
        for item in value:
            if isinstance(item, dict) and item.get("type") == "text" and isinstance(item.get("text"), str):
                text, hit = mask_pasted(item["text"])
                if hit:
                    changed = True
                    item = dict(item)
                    item["text"] = text
            out.append(item)
        return out, changed
    return value, False


def _aad(name):
    return "named-secret:" + name


def ensure_schema(conn):
    conn.execute(
        "CREATE TABLE IF NOT EXISTS named_secrets ("
        "name TEXT PRIMARY KEY, description TEXT, secret BLOB NOT NULL, "
        "created_at REAL NOT NULL, updated_at REAL NOT NULL)"
    )
    conn.commit()


def list_names(conn):
    rows = conn.execute("SELECT name, description, updated_at FROM named_secrets ORDER BY name").fetchall()
    return [{"name": n, "description": d or "", "updated_at": t} for n, d, t in rows]


def has(conn, name):
    if not valid_name(name):
        return False
    return conn.execute("SELECT 1 FROM named_secrets WHERE name = ?", (name,)).fetchone() is not None


def put(conn, name, value, description=""):
    if not valid_name(name):
        raise SecretRefError("名字必须是 UPPER_SNAKE（例如 GITHUB_TOKEN）")
    if not isinstance(value, str) or not value:
        raise SecretRefError("密钥值不能为空")
    if len(value) > 8000:
        raise SecretRefError("密钥值过长")
    if description is None:
        description = ""
    if not isinstance(description, str) or len(description) > 200:
        raise SecretRefError("说明必须是不超过 200 字的字符串")
    box = cloud_secrets.get_box()
    blob = box.encrypt(value, _aad(name))
    now = time.time()
    exists = has(conn, name)
    if exists:
        conn.execute(
            "UPDATE named_secrets SET description = ?, secret = ?, updated_at = ? WHERE name = ?",
            (description, blob, now, name),
        )
    else:
        conn.execute(
            "INSERT INTO named_secrets (name, description, secret, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            (name, description, blob, now, now),
        )
    conn.commit()
    _values_cache["data"] = None
    return {"name": name, "description": description, "updated": exists}


def delete(conn, name):
    if not valid_name(name):
        raise SecretRefError("名字必须是 UPPER_SNAKE（例如 GITHUB_TOKEN）")
    cur = conn.execute("DELETE FROM named_secrets WHERE name = ?", (name,))
    conn.commit()
    _values_cache["data"] = None
    if cur.rowcount == 0:
        raise SecretRefError("没有这个命名密钥")
    return True


def _decrypt_one(name, blob):
    return cloud_secrets.get_box().decrypt(blob, _aad(name))


def values(conn, names):
    """返回 {name: plaintext}。缺的名字不会出现在结果里。"""
    want = [n for n in names if valid_name(n)]
    if not want:
        return {}
    out = {}
    q = ",".join("?" * len(want))
    for name, blob in conn.execute("SELECT name, secret FROM named_secrets WHERE name IN (%s)" % q, want):
        try:
            out[name] = _decrypt_one(name, blob)
        except Exception:
            continue
    return out


def inject(args, mapping):
    """把参数里的占位符换成真实值。mapping 缺的名字列入 missing。

    返回 (new_args, missing_names)。caller 在 missing 非空时不得执行工具。
    """
    missing = []

    def walk(v):
        if isinstance(v, str):
            def repl(m):
                name = m.group(1)
                if name not in mapping:
                    missing.append(name)
                    return m.group(0)
                return mapping[name]
            return PLACEHOLDER_RE.sub(repl, v)
        if isinstance(v, dict):
            return {k: walk(x) for k, x in v.items()}
        if isinstance(v, list):
            return [walk(x) for x in v]
        return v

    return walk(args), list(dict.fromkeys(missing))


def all_plain_values(conn):
    """当前库里所有命名密钥的明文（只给脱敏表用，不得输出）。"""
    out = []
    try:
        for name, blob in conn.execute("SELECT name, secret FROM named_secrets").fetchall():
            try:
                out.append(_decrypt_one(name, blob))
            except Exception:
                continue
    except Exception:
        return []
    return out


_values_cache = {"data": None}


def invalidate():
    _values_cache["data"] = None


def redact(text, extra_values=None):
    """把文本里出现的已知密钥（含编码变体）换成 [secret:hidden]。"""
    if not text or not isinstance(text, str):
        return text
    vals = list(extra_values or [])
    # 缓存由调用方通过 set_loader 提供时再读库；这里只处理传入的 extra
    # 长短优先，避免短串先替换把长串拆碎
    variants = []
    for v in vals:
        for enc in encoded_variants(v):
            variants.append(enc)
    variants.sort(key=len, reverse=True)
    for enc in variants:
        if enc and enc in text:
            text = text.replace(enc, "[secret:hidden]")
    return text


_loader = {"fn": None}


def set_loader(fn):
    """fn() -> sqlite 连接，用来在脱敏时读出命名密钥。"""
    _loader["fn"] = fn
    invalidate()


def _cached_values():
    if _values_cache["data"] is not None:
        return _values_cache["data"]
    vals = []
    fn = _loader["fn"]
    if fn:
        conn = fn()
        try:
            vals = all_plain_values(conn)
        finally:
            try:
                conn.close()
            except Exception:
                pass
    _values_cache["data"] = vals
    return vals


def redact_known(text):
    return redact(text, _cached_values())
