# -*- coding: utf-8 -*-
"""看图：图片附件按图片发给模型；模型确实不能看图时转给「看图模型」读图，再把文字交给主模型。

能力登记（model_caps）只记有依据的结论：服务商 /models 列表里明确写了输入模态，或者调用时服务商明确报错“不支持图片”。
没有依据就当能看图、照常发图片——不按模型名猜。"""

import base64
import hashlib
import io
import json
import os
import re
import time
import urllib.request

IMAGE_EXTS = {"png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "bmp"}
MAX_IMAGE_BYTES = 1_400_000
MAX_IMAGES = 9          # 一条消息最多带几张图给模型（手机一次最多选 9 张）
MAX_RAW_BYTES = 8_000_000   # 没有 Pillow 压不了时，原图不超过这个大小也照发（以前直接丢掉，模型只看到路径去 OCR）
PROBE_TTL = 6 * 3600
DESCRIBE_PROMPT = ("请仔细看这张图片，用中文完整描述其中的内容：先逐字转写图里所有文字（保持原有分行和顺序），"
                   "再说明界面 / 图表 / 照片里有什么、关键数字和细节。只描述看到的东西，不要推测。")
NO_VISION_REPLY = ("这张图片我暂时看不了：当前模型不支持图片，也还没有可用的看图模型。"
                   "请在「设置 → 性能 → 看图模型」里选一个支持图片的模型（与当前服务商相同），再把图片发一次。")
UNSUPPORTED_RE = re.compile(
    r"(image|vision|multimodal|multi-modal|image_url|图片|图像|多模态).{0,60}(not support|unsupported|不支持|无法|not allowed|invalid|not available)"
    r"|(not support|unsupported|不支持|does not accept).{0,60}(image|vision|multimodal|image_url|图片|图像|多模态)"
    r"|unknown variant [`']?image_url|content must be a string|expected a string",
    re.I | re.S)

_PROBED = {}          # base_url → 上次探测时间


def ensure_schema(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS model_caps (
        base_url TEXT NOT NULL, model TEXT NOT NULL, vision INTEGER NOT NULL, source TEXT, updated_at REAL,
        PRIMARY KEY (base_url, model))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS vision_notes (
        image_hash TEXT PRIMARY KEY, model TEXT, text TEXT, created_at REAL)""")


def base_of(chat_url):
    u = (chat_url or "").rstrip("/")
    return u[: -len("/chat/completions")] if u.endswith("/chat/completions") else u


# ---------- 能力登记 ----------

def record(conn, base_url, model, vision, source):
    conn.execute("INSERT INTO model_caps (base_url, model, vision, source, updated_at) VALUES (?, ?, ?, ?, ?) "
                 "ON CONFLICT(base_url, model) DO UPDATE SET vision = excluded.vision, source = excluded.source, "
                 "updated_at = excluded.updated_at", (base_url, model, 1 if vision else 0, source, time.time()))
    conn.commit()


def supports(conn, base_url, model):
    """True / False = 有依据的结论；None = 不知道（照常发图片）。"""
    row = conn.execute("SELECT vision FROM model_caps WHERE base_url = ? AND model = ?", (base_url, model)).fetchone()
    return None if row is None else bool(row[0])


def vision_models(conn, base_url, exclude=None):
    rows = conn.execute("SELECT model FROM model_caps WHERE base_url = ? AND vision = 1 ORDER BY updated_at DESC",
                        (base_url,)).fetchall()
    return [r[0] for r in rows if r[0] != exclude]


def modalities_of(entry):
    """从 /models 列表的一项里读输入模态；没写就返回 None。"""
    if not isinstance(entry, dict):
        return None
    for path in (("input_modalities",), ("modalities", "input"), ("modalities",), ("architecture", "input_modalities"),
                 ("architecture", "modality")):
        v = entry
        for k in path:
            v = v.get(k) if isinstance(v, dict) else None
        if isinstance(v, list) and v:
            return {str(x).lower() for x in v}
        if isinstance(v, str) and v:
            left = v.split("->")[0]
            return {p.strip().lower() for p in re.split(r"[+,\s]", left) if p.strip()}
    caps = entry.get("capabilities")
    if isinstance(caps, dict) and isinstance(caps.get("vision"), bool):
        return {"text", "image"} if caps["vision"] else {"text"}
    for k in ("supports_vision", "vision"):
        if isinstance(entry.get(k), bool):
            return {"text", "image"} if entry[k] else {"text"}
    return None


def learn_from_models(conn, base_url, payload):
    """服务商 /models 的返回 → 登记写明了输入模态的模型。返回登记了几个。"""
    items = payload.get("data") if isinstance(payload, dict) else payload
    n = 0
    for entry in items or []:
        mods = modalities_of(entry)
        mid = entry.get("id") if isinstance(entry, dict) else None
        if mods is None or not mid:
            continue
        record(conn, base_url, mid, bool(mods & {"image", "images", "vision", "image_url"}), "models")
        n += 1
    return n


def probe(conn, base_url, api_key, timeout=4.0, fetch=None):
    """向服务商要一次模型列表（每个地址 6 小时一次），登记写明了模态的模型。失败不影响任务。"""
    now = time.time()
    if now - _PROBED.get(base_url, 0) < PROBE_TTL:
        return 0
    _PROBED[base_url] = now
    try:
        if fetch is not None:
            payload = fetch(base_url, api_key)
        else:
            req = urllib.request.Request(base_url.rstrip("/") + "/models", headers={"Authorization": f"Bearer {api_key}"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                payload = json.loads(r.read().decode("utf-8", "replace"))
        return learn_from_models(conn, base_url, payload)
    except Exception:
        return 0


def is_unsupported_error(text):
    return bool(text) and bool(UNSUPPORTED_RE.search(text))


# ---------- 消息里的图片 ----------

def has_images(messages):
    return any(isinstance(m.get("content"), list) and any(isinstance(p, dict) and p.get("type") == "image_url" for p in m["content"])
               for m in messages if m.get("role") == "user")


def image_hash(url):
    return hashlib.sha256((url or "").encode("utf-8", "replace")).hexdigest()[:32]


def cached_note(conn, h):
    row = conn.execute("SELECT model, text FROM vision_notes WHERE image_hash = ?", (h,)).fetchone()
    return row


def save_note(conn, h, model, text):
    conn.execute("INSERT OR REPLACE INTO vision_notes (image_hash, model, text, created_at) VALUES (?, ?, ?, ?)",
                 (h, model, text, time.time()))
    conn.commit()


def replace_images(conn, messages, vision_model, describe):
    """把用户消息里的图片换成看图模型读出来的文字（同一张图只读一次，存进 vision_notes）。
    describe(url) → 文字；读不出来抛异常。返回新的消息列表。"""
    out = []
    for m in messages:
        c = m.get("content")
        if m.get("role") != "user" or not isinstance(c, list):
            out.append(m)
            continue
        parts = []
        for p in c:
            if not (isinstance(p, dict) and p.get("type") == "image_url"):
                parts.append(p)
                continue
            url = p["image_url"]["url"] if isinstance(p.get("image_url"), dict) else str(p.get("image_url") or "")
            h = image_hash(url)
            hit = cached_note(conn, h)
            if hit:
                who, text = hit
            else:
                who, text = vision_model, describe(url).strip()
                save_note(conn, h, vision_model, text)
            parts.append({"type": "text", "text": f"[图片内容（由 {who} 读图）]\n{text}"})
        texts = [p.get("text", "") for p in parts if isinstance(p, dict) and p.get("type") == "text"]
        out.append({**m, "content": "\n\n".join(t for t in texts if t)})
    return out


# ---------- 上传的图片文件 → 图片内容 ----------

ATTACH_LINE_RE = re.compile(r"(attachments/up_[A-Za-z0-9._-]{1,160})")


def _sniff(data):
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    return None


def has_pil():
    try:
        import PIL.Image  # noqa: F401
        return True
    except Exception:
        return False


def missing_note(n):
    """有图片没能作为图片给模型时，写进任务状态的中文说明（说清楚怎么办）"""
    if not has_pil():
        return (f"有 {n} 张图片没能给模型看（服务器缺 Pillow，超过 8 MB 的图压不了）："
                "在 App 里「更新服务器 Agent」会自动装上，或发图时关掉「保留原图」")
    return f"有 {n} 张图片读不出来（文件不在或格式不认识），模型只看到文件名"


def shrink(data, max_bytes=MAX_IMAGE_BYTES):
    """太大的图片缩小重压成 JPEG。没有 PIL 时：JPEG / PNG / WebP / GIF 原图 ≤ MAX_RAW_BYTES 照发，
    更大或认不出格式才放弃（返回 None）。"""
    if len(data) <= max_bytes:
        if data[:3] == b"\xff\xd8\xff":
            return data, "image/jpeg"
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            return data, "image/png"
    try:
        from PIL import Image
    except Exception:
        mime = _sniff(data)
        return (data, mime) if mime and len(data) <= MAX_RAW_BYTES else None
    try:
        im = Image.open(io.BytesIO(data)).convert("RGB")
    except Exception:
        return None
    for side, q in ((1600, 80), (1280, 72), (1024, 65), (800, 60)):
        if max(im.size) > side:
            scaled = im.copy()
            scaled.thumbnail((side, side))
        else:
            scaled = im
        buf = io.BytesIO()
        scaled.save(buf, "JPEG", quality=q)
        if buf.tell() <= max_bytes:
            return buf.getvalue(), "image/jpeg"
    return None


def parts_from_uploads(content, resolve):
    """手机只给了附件路径（老版本 App、从「文件」选的图片）：服务器自己把上传的图片作为图片内容带上。
    resolve(rel_path) → 绝对路径或 None。没有图片返回 None。"""
    images = []
    for rel in ATTACH_LINE_RE.findall(content or ""):
        ext = rel.rsplit(".", 1)[-1].lower() if "." in rel else ""
        if ext not in IMAGE_EXTS or len(images) >= MAX_IMAGES:
            continue
        path = resolve(rel)
        if not path or not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            got = shrink(f.read())
        if got:
            data, mime = got
            images.append({"type": "image_url", "image_url": {"url": f"data:{mime};base64," + base64.b64encode(data).decode()}})
    if not images:
        return None
    return [{"type": "text", "text": content}] + images


def image_lines(content):
    """消息文字里的图片附件路径（按顺序、去重）"""
    out = []
    for rel in ATTACH_LINE_RE.findall(content or ""):
        ext = rel.rsplit(".", 1)[-1].lower() if "." in rel else ""
        if ext in IMAGE_EXTS and rel not in out:
            out.append(rel)
    return out


def expand_attachment_images(messages, resolve, recent=6):
    """调用模型前：最近几条用户消息里只有附件路径（「[附件] … → 工作区 attachments/up_*.jpg」）的图片，
    读上传的文件补成 image_url（手机不再把图片 base64 塞进 message_parts，避免 2 MB 上限）。
    已经是图片内容的消息不动。返回 (补了几张, 读不出来几张)。"""
    added, missing = 0, 0
    start = max(0, len(messages) - recent)
    for i in range(start, len(messages)):
        m = messages[i]
        if m.get("role") != "user" or not isinstance(m.get("content"), str) or not image_lines(m["content"]):
            continue
        parts = parts_from_uploads(m["content"], resolve)
        got = len(parts) - 1 if parts else 0
        want = min(len(image_lines(m["content"])), MAX_IMAGES)
        missing += max(0, want - got)
        if parts:
            messages[i] = {**m, "content": parts}
            added += got
    return added, missing
