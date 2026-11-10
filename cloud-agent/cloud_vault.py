# -*- coding: utf-8 -*-
"""保管库：所有 Bot 共用的登录信息、卡片和联系信息。

- 机密字段（密码、TOTP 密钥、卡号、有效期、CVV、电话、邮箱、地址、备注）整包用 cloud_secrets 的
  AES-256-GCM 加密，AAD 绑定 "vault:<id>"；库里只有明文的元数据（标题、网站、用户名、卡号后四位）。
- 给模型的只有元数据（vault_list）；vault_fill / vault_totp 在服务器里解密后直接填进云电脑的网页，
  工具结果只说「填了哪些栏」，永远不带值。
- 每次使用记一条 vault_uses（哪个 Bot、哪一项、什么时候、填到哪个网站），保管库页面能看到。
- redact()：万一机密出现在网页文字、报错或模型回复里，写库 / 发给模型前替换成 [保管库已隐藏]。
"""

import base64
import csv
import hashlib
import hmac
import io
import json
import re
import struct
import threading
import time
import uuid
from urllib.parse import urlparse, parse_qs, unquote

import cloud_secrets

KINDS = ("login", "card", "contact", "note")
ID_RE = re.compile(r"^v_[a-f0-9]{10}$")
MASK = "[保管库已隐藏]"
SECRET_KEYS = {
    "login": ("password", "totp", "notes"),
    "card": ("number", "expiry", "cvv", "notes", "billing", "hint"),
    "contact": ("phone", "email", "addresses", "notes"),
    "note": ("body",),
}
# 太常见、一猜就中的密码（弱密码判断用；只在服务端对比，不外传）
COMMON_PASSWORDS = {"123456", "12345678", "123456789", "password", "qwerty", "111111", "abc123", "password1", "iloveyou",
                    "000000", "1234567890", "a123456", "woaini1314", "qwerty123", "1q2w3e4r", "admin", "letmein", "welcome"}
MULTI_SUFFIX = {"co.uk", "org.uk", "ac.uk", "gov.uk", "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "com.hk", "com.tw",
                "com.au", "net.au", "org.au", "co.jp", "ne.jp", "or.jp", "co.kr", "com.sg", "com.br", "co.in", "co.nz",
                "com.mx", "com.tr", "co.za", "com.my", "com.ph", "co.id", "com.vn", "com.ar"}


class VaultError(ValueError):
    pass


def ensure_schema(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS vault_items (id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, "
                 "site TEXT, username TEXT, name TEXT, last4 TEXT, brand TEXT, is_default INTEGER NOT NULL DEFAULT 0, "
                 "has_totp INTEGER NOT NULL DEFAULT 0, allow_bots INTEGER NOT NULL DEFAULT 1, secret BLOB NOT NULL, "
                 "created_at REAL NOT NULL, updated_at REAL NOT NULL, last_used_at REAL)")
    conn.execute("CREATE TABLE IF NOT EXISTS vault_uses (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id TEXT NOT NULL, "
                 "item_title TEXT, actor TEXT, session_id TEXT, action TEXT NOT NULL, target TEXT, ok INTEGER NOT NULL, "
                 "detail TEXT, at REAL NOT NULL)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_vault_uses_at ON vault_uses(at)")
    cols = {r[1] for r in conn.execute("PRAGMA table_info(vault_items)").fetchall()}
    if "allowed_bots" not in cols:
        # 只允许哪些 Bot 使用（JSON 数组）；NULL = 所有 Bot
        conn.execute("ALTER TABLE vault_items ADD COLUMN allowed_bots TEXT")
    conn.commit()


# ---------- 域名 ----------

def host_of(text):
    s = (text or "").strip().lower()
    if not s:
        return ""
    if "://" not in s:
        s = "https://" + s
    try:
        h = urlparse(s).hostname or ""
    except ValueError:
        return ""
    return h[4:] if h.startswith("www.") else h


def site_key(text):
    """eTLD+1 的近似：常见两段后缀（co.uk、com.cn…）取三段，其余取两段；IP 原样。"""
    h = host_of(text)
    if not h or re.match(r"^[\d.]+$", h) or ":" in h:
        return h
    parts = h.split(".")
    if len(parts) >= 3 and ".".join(parts[-2:]) in MULTI_SUFFIX:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


# ---------- TOTP（RFC 6238） ----------

def totp_secret(raw):
    s = (raw or "").strip()
    if s.lower().startswith("otpauth://"):
        q = parse_qs(urlparse(s).query)
        s = (q.get("secret") or [""])[0]
    s = re.sub(r"[\s-]", "", unquote(s)).upper()
    if not s or not re.match(r"^[A-Z2-7]+=*$", s):
        raise VaultError("TOTP 密钥不是有效的 Base32（或 otpauth:// 链接）")
    return s


def totp_code(raw, at=None, step=30, digits=6):
    key = base64.b32decode(totp_secret(raw) + "=" * (-len(totp_secret(raw)) % 8))
    counter = int((time.time() if at is None else at) // step)
    mac = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    off = mac[-1] & 0x0F
    num = (struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF) % (10 ** digits)
    return str(num).zfill(digits), step - int((time.time() if at is None else at) % step)


# ---------- 加解密 ----------

def _aad(item_id):
    return "vault:" + item_id


def _seal(item_id, secret):
    return cloud_secrets.get_box().encrypt(json.dumps(secret, ensure_ascii=False), _aad(item_id))


def _open(item_id, blob):
    return json.loads(cloud_secrets.get_box().decrypt(blob, _aad(item_id)))


COLS = ("id", "kind", "title", "site", "username", "name", "last4", "brand", "is_default", "has_totp", "allow_bots",
        "created_at", "updated_at", "last_used_at", "allowed_bots")


def _public(row):
    d = dict(zip(COLS, row))
    for k in ("is_default", "has_totp", "allow_bots"):
        d[k] = bool(d[k])
    try:
        bots = json.loads(d.get("allowed_bots") or "null")
    except ValueError:
        bots = None
    d["allowed_bots"] = [b for b in bots if isinstance(b, str)] if isinstance(bots, list) else None
    return {k: v for k, v in d.items() if v not in (None, "") or k in ("allow_bots",)}


def _row(conn, item_id):
    if not isinstance(item_id, str) or not ID_RE.match(item_id):
        raise VaultError("没有这一项")
    r = conn.execute(f"SELECT {', '.join(COLS)}, secret FROM vault_items WHERE id = ?", (item_id,)).fetchone()
    if not r:
        raise VaultError("没有这一项")
    return r


def _brand(number):
    n = number or ""
    if n.startswith("4"):
        return "Visa"
    if re.match(r"^(5[1-5]|2[2-7])", n):
        return "Mastercard"
    if re.match(r"^3[47]", n):
        return "American Express"
    if n.startswith("62"):
        return "银联"
    if re.match(r"^35", n):
        return "JCB"
    return "卡"


def _clean_str(v, limit=500):
    if v is None:
        return None
    if not isinstance(v, str):
        raise VaultError("字段必须是字符串")
    v = v.strip()
    if len(v) > limit:
        raise VaultError("字段太长")
    return v


def _addresses(v):
    if v is None:
        return None
    if not isinstance(v, list) or len(v) > 10:
        raise VaultError("addresses 必须是数组（最多 10 个）")
    out = []
    for a in v:
        if not isinstance(a, dict):
            raise VaultError("地址格式不对")
        clean = {k: _clean_str(a.get(k), 200) for k in ("label", "line1", "line2", "city", "region", "postal", "country")
                 if a.get(k) not in (None, "")}
        clean["default"] = bool(a.get("default"))
        out.append(clean)
    if out and not any(a["default"] for a in out):
        out[0]["default"] = True
    return out


def _apply(kind, meta, secret, body):
    """把请求里的字段并进元数据和机密；机密字段缺省 = 保持不变，空字符串 = 清空。"""
    for k in ("title", "site", "username", "name"):
        if k in body:
            meta[k] = _clean_str(body[k], 200) or None
    if "allow_bots" in body:
        meta["allow_bots"] = 1 if body["allow_bots"] else 0
    if "is_default" in body:
        meta["is_default"] = 1 if body["is_default"] else 0
    if "allowed_bots" in body:
        v = body["allowed_bots"]
        if v is None or v == []:
            meta["allowed_bots"] = None
        elif isinstance(v, list) and all(isinstance(b, str) and re.match(r"^[A-Za-z0-9_-]{1,64}$", b) for b in v):
            meta["allowed_bots"] = json.dumps(sorted(set(v))[:50])
        else:
            raise VaultError("allowed_bots 应为 Bot ID 列表")
    for k in SECRET_KEYS[kind]:
        if k not in body:
            continue
        v = _addresses(body[k]) if k == "addresses" else _clean_str(body[k], 4000 if k == "notes" else 500)
        if v in (None, "", []):
            secret.pop(k, None)
        else:
            secret[k] = v
    if kind == "login":
        if meta.get("site"):
            h = host_of(meta["site"])
            if not h:
                raise VaultError("网站地址不对")
            meta["site"] = h
        if secret.get("totp"):
            totp_secret(secret["totp"])
        meta["has_totp"] = 1 if secret.get("totp") else 0
        meta["title"] = meta.get("title") or meta.get("site") or meta.get("username")
    elif kind == "card":
        if secret.get("number"):
            num = re.sub(r"[\s-]", "", secret["number"])
            if not re.match(r"^\d{12,19}$", num):
                raise VaultError("卡号应为 12–19 位数字")
            secret["number"] = num
            meta["last4"], meta["brand"] = num[-4:], _brand(num)
        if secret.get("expiry"):
            m = re.match(r"^(\d{1,2})\s*/\s*(\d{2}|\d{4})$", secret["expiry"])
            if not m or not 1 <= int(m.group(1)) <= 12:
                raise VaultError("有效期格式应为 MM/YY")
            secret["expiry"] = f"{int(m.group(1)):02d}/{m.group(2)[-2:]}"
        if secret.get("cvv") and not re.match(r"^\d{3,4}$", secret["cvv"]):
            raise VaultError("CVV 应为 3–4 位数字")
        meta["title"] = meta.get("title") or f"{meta.get('brand') or '卡'} •••• {meta.get('last4') or ''}".strip()
    elif kind == "note":
        meta["title"] = meta.get("title") or "安全备注"
    else:
        meta["title"] = meta.get("title") or meta.get("name") or "联系信息"
    if not meta.get("title"):
        raise VaultError("至少填写网站或用户名")


def _save(conn, item_id, meta, secret, created):
    now = time.time()
    blob = _seal(item_id, secret)
    if created:
        conn.execute("INSERT INTO vault_items (id, kind, title, site, username, name, last4, brand, is_default, has_totp, allow_bots, "
                     "secret, created_at, updated_at, allowed_bots) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                     (item_id, meta["kind"], meta["title"], meta.get("site"), meta.get("username"), meta.get("name"), meta.get("last4"),
                      meta.get("brand"), meta.get("is_default", 0), meta.get("has_totp", 0), meta.get("allow_bots", 1), blob, now, now,
                      meta.get("allowed_bots")))
    else:
        conn.execute("UPDATE vault_items SET title = ?, site = ?, username = ?, name = ?, last4 = ?, brand = ?, is_default = ?, "
                     "has_totp = ?, allow_bots = ?, secret = ?, updated_at = ?, allowed_bots = ? WHERE id = ?",
                     (meta["title"], meta.get("site"), meta.get("username"), meta.get("name"), meta.get("last4"), meta.get("brand"),
                      meta.get("is_default", 0), meta.get("has_totp", 0), meta.get("allow_bots", 1), blob, now,
                      meta.get("allowed_bots"), item_id))
    if meta.get("is_default"):
        conn.execute("UPDATE vault_items SET is_default = 0 WHERE kind = ? AND id != ?", (meta["kind"], item_id))
    conn.commit()
    _invalidate()
    return get(conn, item_id)


def create(conn, body):
    if not isinstance(body, dict) or body.get("kind") not in KINDS:
        raise VaultError("kind 必须是 login / card / contact / note")
    item_id = "v_" + uuid.uuid4().hex[:10]
    meta, secret = {"kind": body["kind"], "allow_bots": 1}, {}
    _apply(body["kind"], meta, secret, body)
    return _save(conn, item_id, meta, secret, True)


def update(conn, item_id, body):
    r = _row(conn, item_id)
    meta = dict(zip(COLS, r[:-1]))
    secret = _open(item_id, r[-1])
    _apply(meta["kind"], meta, secret, body if isinstance(body, dict) else {})
    return _save(conn, item_id, meta, secret, False)


def delete(conn, item_id):
    _row(conn, item_id)
    conn.execute("DELETE FROM vault_items WHERE id = ?", (item_id,))
    conn.commit()
    _invalidate()


def get(conn, item_id):
    return _public(_row(conn, item_id)[:-1])


def secret(conn, item_id):
    r = _row(conn, item_id)
    return _public(r[:-1]), _open(item_id, r[-1])


def password_weak(pw):
    """弱密码：太短、太常见，或字符种类少于 3 种（小写 / 大写 / 数字 / 符号）"""
    pw = pw or ""
    kinds = sum(bool(re.search(p, pw)) for p in (r"[a-z]", r"[A-Z]", r"\d", r"[^A-Za-z0-9]"))
    return len(pw) < 10 or pw.lower() in COMMON_PASSWORDS or kinds < 3


def _hints(conn, items):
    """只给 App 列表看的提示（不进模型）：卡片有效期 MM/YY、联系信息的默认地址、密码弱 / 重复。
    机密在这里解密后只算出提示，原值不外传。"""
    by_id = {i["id"]: i for i in items}
    pw_count = {}
    pw_of = {}
    for item_id, blob in conn.execute("SELECT id, secret FROM vault_items").fetchall():
        it = by_id.get(item_id)
        if not it:
            continue
        try:
            sec = _open(item_id, blob)
        except Exception:
            continue
        if it["kind"] == "card" and sec.get("expiry"):
            it["expiry_hint"] = sec["expiry"]
        elif it["kind"] == "contact":
            addrs = sec.get("addresses") or []
            a = next((x for x in addrs if x.get("default")), addrs[0] if addrs else None)
            if a:
                it["address_hint"] = " ".join(str(a.get(k)) for k in ("line1", "line2", "city", "region", "postal", "country") if a.get(k))[:200]
        elif it["kind"] == "login" and sec.get("password"):
            digest = hashlib.sha256(sec["password"].encode("utf-8")).hexdigest()
            pw_of[item_id] = digest
            pw_count[digest] = pw_count.get(digest, 0) + 1
            it["pw_weak"] = password_weak(sec["password"])
    for item_id, digest in pw_of.items():
        by_id[item_id]["pw_reused"] = pw_count[digest] > 1


def list_items(conn, kind=None, query=None, hints=False):
    rows = conn.execute(f"SELECT {', '.join(COLS)} FROM vault_items ORDER BY kind, is_default DESC, title COLLATE NOCASE").fetchall()
    items = [_public(r) for r in rows]
    if hints:
        try:
            _hints(conn, items)
        except Exception:
            pass
    if kind in KINDS:
        items = [i for i in items if i["kind"] == kind]
    q = (query or "").strip().lower()
    if q:
        key = site_key(q) if "." in q else ""
        def hit(i):
            if key and i.get("site") and site_key(i["site"]) == key:
                return True
            return any(q in str(i.get(f) or "").lower()
                       for f in ("title", "site", "username", "name", "last4", "brand", "expiry_hint", "address_hint"))
        items = [i for i in items if hit(i)]
    return items


def bot_allowed(item, bot_id):
    """这一项能不能给这个 Bot 用：总开关 + 可选的 Bot 名单"""
    if not item.get("allow_bots", True):
        return False
    bots = item.get("allowed_bots")
    return not bots or (bot_id or "default") in bots


def for_model(item, bot_id=None):
    """给模型看的字段：只有元数据（不含有效期、地址等提示，也不含安全备注内容）。"""
    keep = ("id", "kind", "title", "site", "username", "name", "last4", "brand", "is_default", "has_totp")
    out = {k: item[k] for k in keep if k in item}
    out["allowed"] = bot_allowed(item, bot_id) and item.get("kind") != "note"
    return out


# ---------- 使用记录 ----------

def record_use(conn, item, actor, session_id, action, target, ok, detail=None):
    now = time.time()
    conn.execute("INSERT INTO vault_uses (item_id, item_title, actor, session_id, action, target, ok, detail, at) "
                 "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                 (item["id"], item.get("title"), actor, session_id, action, target, 1 if ok else 0, redact(detail or "")[:300] or None, now))
    if ok:
        conn.execute("UPDATE vault_items SET last_used_at = ? WHERE id = ?", (now, item["id"]))
    conn.execute("DELETE FROM vault_uses WHERE id NOT IN (SELECT id FROM vault_uses ORDER BY id DESC LIMIT 2000)")
    conn.commit()


def uses(conn, item_id=None, limit=200):
    sql = "SELECT id, item_id, item_title, actor, session_id, action, target, ok, detail, at FROM vault_uses"
    args = ()
    if item_id:
        sql += " WHERE item_id = ?"
        args = (item_id,)
    rows = conn.execute(sql + " ORDER BY id DESC LIMIT ?", args + (max(1, min(int(limit), 500)),)).fetchall()
    keys = ("id", "item_id", "item_title", "actor", "session_id", "action", "target", "ok", "detail", "at")
    return [dict(zip(keys, r), ok=bool(r[7])) for r in rows]


# ---------- 填写用的字段 ----------

def fill_fields(kind, item, sec, address_index=None):
    if kind == "login":
        f = {"password": sec.get("password")}
        if item.get("username"):
            f["username"] = item["username"]
    elif kind == "card":
        exp = sec.get("expiry") or ""
        f = {"cc_number": sec.get("number"), "cc_exp": exp, "cc_csc": sec.get("cvv"), "cc_name": item.get("name")}
        if exp:
            f["cc_exp_month"], f["cc_exp_year"] = exp[:2], "20" + exp[-2:]
    elif kind == "note":
        return {}
    else:
        addrs = sec.get("addresses") or []
        a = {}
        if addrs:
            a = addrs[address_index] if isinstance(address_index, int) and 0 <= address_index < len(addrs) else \
                next((x for x in addrs if x.get("default")), addrs[0])
        f = {"name": item.get("name"), "tel": sec.get("phone"), "email": sec.get("email"), "street": a.get("line1"),
             "street2": a.get("line2"), "city": a.get("city"), "region": a.get("region"), "postal": a.get("postal"),
             "country": a.get("country")}
    return {k: v for k, v in f.items() if v}


# ---------- 防泄漏 ----------

_cache = {"values": None}
_cache_lock = threading.Lock()
_loader = {"fn": None}


def set_loader(fn):
    """fn() -> sqlite 连接；用来在需要时读出所有机密做替换表。"""
    _loader["fn"] = fn
    _invalidate()


def _invalidate():
    with _cache_lock:
        _cache["values"] = None


def _variants(kind, key, value):
    v = str(value)
    if key == "number":
        return [v, " ".join(v[i:i + 4] for i in range(0, len(v), 4)), "-".join(v[i:i + 4] for i in range(0, len(v), 4))]
    if key == "totp":
        try:
            return [v, totp_secret(v)]
        except VaultError:
            return [v]
    return [v]


def _secret_values():
    with _cache_lock:
        if _cache["values"] is not None:
            return _cache["values"]
    vals = set()
    fn = _loader["fn"]
    if fn:
        conn = fn()
        try:
            for item_id, kind, blob in conn.execute("SELECT id, kind, secret FROM vault_items").fetchall():
                try:
                    sec = _open(item_id, blob)
                except Exception:
                    continue
                for key in ("password", "totp", "number", "body"):
                    if sec.get(key):
                        vals.update(x for x in _variants(kind, key, sec[key]) if len(x) >= 6)
        except Exception:
            pass
        finally:
            conn.close()
    ordered = sorted(vals, key=len, reverse=True)
    with _cache_lock:
        _cache["values"] = ordered
    return ordered


def redact(text):
    if not text or not isinstance(text, str):
        return text
    for v in _secret_values():
        if v in text:
            text = text.replace(v, MASK)
    return text


# ---------- CSV 导入（Chrome / 1Password / Bitwarden / Safari） ----------

CSV_COLUMNS = {
    "site": ("url", "login_uri", "website", "web site", "urls"),
    "title": ("name", "title"),
    "username": ("username", "login_username", "login name", "user name", "email"),
    "password": ("password", "login_password"),
    "totp": ("otpauth", "login_totp", "totp", "one-time password", "otp"),
    "notes": ("note", "notes", "extra"),
}


def import_csv(conn, text):
    if not isinstance(text, str) or not text.strip():
        raise VaultError("CSV 为空")
    reader = csv.DictReader(io.StringIO(text.lstrip("\ufeff")))
    if not reader.fieldnames:
        raise VaultError("CSV 没有表头")
    lower = {f.strip().lower(): f for f in reader.fieldnames if f}
    pick = {k: next((lower[c] for c in cands if c in lower), None) for k, cands in CSV_COLUMNS.items()}
    if not pick["password"]:
        raise VaultError("CSV 里没有 password 列（支持 Chrome / 1Password / Bitwarden 导出格式）")
    type_col = lower.get("type")
    imported, skipped = 0, 0
    for rec in reader:
        if type_col and (rec.get(type_col) or "login").strip().lower() not in ("login", ""):
            skipped += 1
            continue
        body = {"kind": "login"}
        for k, col in pick.items():
            if col and (rec.get(col) or "").strip():
                body[k] = rec[col].strip()
        if not body.get("password") or not (body.get("site") or body.get("username")):
            skipped += 1
            continue
        if body.get("site"):
            body["site"] = body["site"].split(",")[0].strip()
        try:
            if body.get("totp"):
                totp_secret(body["totp"])
        except VaultError:
            body.pop("totp")
        try:
            create(conn, body)
            imported += 1
        except VaultError:
            skipped += 1
        if imported >= 2000:
            break
    return {"imported": imported, "skipped": skipped}
