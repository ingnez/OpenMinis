# -*- coding: utf-8 -*-
"""成果直达聊天：把任务产出的文件变成聊天里的交付卡片，而不是只报一条路径。

- deliver_file(path)：Agent 主动交出工作区或 @shared 里的文件
- 任务开始时对工作区和 shared 做快照，结束时把新文件自动附到最后一条助手消息
- 子 Bot / 后台任务产出的文件会复制到发起对话
- 列表、下载（支持 Range 续传）、缩略图
"""

from __future__ import annotations

import hashlib
import io
import json
import mimetypes
import plistlib
import os
import re
import shutil
import time
import tempfile
import subprocess
import zipfile

DELIVER_ID_RE = re.compile(r"^dl_[a-f0-9]{16}$")
MAX_AUTO = 20
MAX_BYTES = 500 * 1024 * 1024
MAX_ZIP_ENTRIES = 50
THUMB_MAX = 240

IMAGE_EXTS = {"png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff"}
OFFICE_EXTS = {"ppt", "pptx", "pptm", "pdf", "doc", "docx", "xls", "xlsx", "xlsm", "odt", "odp", "ods"}
HTML_EXTS = {"html", "htm"}
SKIP_DIR_PARTS = {".outputs", "deliveries", "__pycache__", ".git", ".cache", "node_modules"}
SKIP_NAME_PREFIXES = ("br_screenshot", "screenshot_", ".")
SKIP_NAMES = {".ds_store", "thumbs.db", "nohup.out", ".gitignore"}
SKIP_EXTS = {"pyc", "pyo", "swp", "tmp", "crdownload", "part"}

# 任务进行中：快照与主动交付（task_id -> ...）
TASK_SNAPSHOT = {}
TASK_DELIVERED = {}
_LOCK_DIR = {}

DELIVER_NOTE = (
    "\n[交付成果] 做出来的文件（PPT、PDF、Word、Excel、图片、网页、安装包、压缩包等）必须用 deliver_file 交给用户，"
    "让文件作为卡片出现在聊天里。禁止只在文字里写工作区路径、@shared 路径或附件路径让用户自己去找。"
    "任务结束时，工作区和 @shared 里这次新产生的文件也会自动附到回复上，但你仍应主动调用 deliver_file。"
    "网页链接请用 Markdown [标题](网址) 写出，手机会显示成可点开的链接卡片。"
)

TOOL_DEFINITION = {
    "type": "function",
    "function": {
        "name": "deliver_file",
        "description": (
            "Attach a file from the session workspace or @shared so it appears as a card in the user's chat. "
            "Pass a workspace-relative path, or @shared/... for the shared folder. "
            "Do not answer with only a file path — call this tool instead."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Workspace-relative path or @shared/..."}
            },
            "required": ["path"],
        },
    },
}

LINK_MD_RE = re.compile(r"\[([^\]]{1,200})\]\((https?://[^\s)]+)\)")
LINK_BARE_RE = re.compile(r"(?<!\()(?<!\])(?P<url>https?://[^\s<>\"'）)\]。，、；：]+)")


def _srv():
    import cloud_agent_server as srv
    return srv


def shared_dir():
    return os.path.join(_srv().GLOBAL_WORKSPACE, "shared")


def deliveries_dir(session_id):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", session_id):
        raise ValueError("Invalid session id")
    return os.path.join(_srv().GLOBAL_WORKSPACE, ".deliveries", session_id)


def _kind_for(name, mime=None):
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if ext in IMAGE_EXTS:
        return "image"
    if ext == "ipa":
        return "ipa"
    if ext == "zip":
        return "zip"
    if ext in HTML_EXTS:
        return "html"
    if ext in OFFICE_EXTS:
        return "office"
    if mime and mime.startswith("image/"):
        return "image"
    return "file"


def _should_skip(rel, name):
    parts = rel.replace("\\", "/").split("/")
    if any(p in SKIP_DIR_PARTS or p.startswith(".") for p in parts[:-1]):
        return True
    low = name.lower()
    if low in SKIP_NAMES:
        return True
    if any(low.startswith(p) for p in SKIP_NAME_PREFIXES):
        return True
    ext = low.rsplit(".", 1)[-1] if "." in low else ""
    if ext in SKIP_EXTS:
        return True
    return False


def _walk_files(root, prefix=""):
    """Yield (relpath, abs_path, st_mtime, st_size). relpath uses prefix ('' or '@shared/')."""
    if not os.path.isdir(root):
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_PARTS and not d.startswith(".")]
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace("\\", "/")
            key = (prefix + rel) if prefix else rel
            if _should_skip(key, name):
                continue
            try:
                st = os.stat(full)
            except OSError:
                continue
            if not os.path.isfile(full):
                continue
            yield key, full, st.st_mtime, st.st_size


def snapshot(session_id):
    """Record existing files in the session workspace and the shared folder."""
    ws = _srv().get_session_workspace(session_id)
    out = {}
    for key, full, mtime, size in _walk_files(ws):
        out[key] = (mtime, size, full)
    shared = shared_dir()
    os.makedirs(shared, exist_ok=True)
    for key, full, mtime, size in _walk_files(shared, prefix="@shared/"):
        out[key] = (mtime, size, full)
    return out


def begin_task(task_id, session_id):
    TASK_SNAPSHOT[task_id] = (snapshot(session_id), time.time())
    TASK_DELIVERED.setdefault(task_id, [])


def forget_task(task_id):
    TASK_SNAPSHOT.pop(task_id, None)
    TASK_DELIVERED.pop(task_id, None)


def new_files(session_id, before):
    """Files that appeared or grew after the snapshot."""
    before = before or {}
    found = []
    seen = set()
    for key, full, mtime, size in list(_walk_files(_srv().get_session_workspace(session_id))) + \
            list(_walk_files(shared_dir(), prefix="@shared/")):
        if key in seen:
            continue
        seen.add(key)
        prev = before.get(key)
        if prev and prev[0] >= mtime - 0.001 and prev[1] == size:
            continue
        if size <= 0 or size > MAX_BYTES:
            continue
        found.append((key, full, size))
    found.sort(key=lambda x: x[0])
    return found[:MAX_AUTO]


def _sha256(path, limit=MAX_BYTES):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        left = limit
        while left:
            chunk = f.read(min(1024 * 1024, left))
            if not chunk:
                break
            h.update(chunk)
            left -= len(chunk)
    return h.hexdigest()


def _pdf_pages(path):
    try:
        with open(path, "rb") as f:
            data = f.read(8 * 1024 * 1024)
        return len(re.findall(rb"/Type\s*/Page(?!s)\b", data)) or None
    except OSError:
        return None


def _zip_namelist(path):
    try:
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if not n.endswith("/") and "__MACOSX" not in n
                     and not os.path.basename(n).startswith(".")]
        return names[:MAX_ZIP_ENTRIES], len(names)
    except (zipfile.BadZipFile, OSError, RuntimeError):
        return [], 0


def _pptx_pages(path):
    try:
        with zipfile.ZipFile(path) as z:
            slides = [n for n in z.namelist() if re.match(r"ppt/slides/slide\d+\.xml$", n)]
        return len(slides) or None
    except (zipfile.BadZipFile, OSError, RuntimeError):
        return None


def _ipa_meta(path):
    try:
        with zipfile.ZipFile(path) as z:
            plists = [n for n in z.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist")]
            if not plists:
                return {}
            raw = z.read(plists[0])
        info = plistlib.loads(raw)
        version = info.get("CFBundleShortVersionString") or info.get("CFBundleVersion")
        build = info.get("CFBundleVersion")
        out = {}
        if version:
            out["version"] = str(version)
        if build and str(build) != str(version):
            out["build"] = str(build)
        name = info.get("CFBundleDisplayName") or info.get("CFBundleName")
        if name:
            out["app_name"] = str(name)
        return out
    except (zipfile.BadZipFile, OSError, RuntimeError, ValueError, KeyError, plistlib.InvalidFileException):
        return {}


def _office_pages(path, name):
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if ext == "pdf":
        return _pdf_pages(path)
    if ext in {"pptx", "pptm", "ppt"}:
        return _pptx_pages(path)
    return None


def _make_thumb(src, dest, name):
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    try:
        if ext in IMAGE_EXTS:
            return _thumb_image(src, dest)
        if ext in {"pptx", "pptm"}:
            return _thumb_pptx(src, dest)
        if ext == "pdf":
            return _thumb_pdf(src, dest)
    except Exception:
        return False
    return False


def _thumb_image(src, dest):
    try:
        from PIL import Image
    except ImportError:
        # 没有 Pillow 就原样拷一份很小的图（仅小于 200 KB 的）
        if os.path.getsize(src) <= 200 * 1024:
            shutil.copy2(src, dest)
            return True
        return False
    with Image.open(src) as im:
        im = im.convert("RGB")
        im.thumbnail((THUMB_MAX, THUMB_MAX))
        im.save(dest, "JPEG", quality=80)
    return True


def _thumb_pptx(src, dest):
    with zipfile.ZipFile(src) as z:
        for cand in ("docProps/thumbnail.jpeg", "docProps/thumbnail.jpg", "docProps/thumbnail.png"):
            if cand in z.namelist():
                data = z.read(cand)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as f:
                    f.write(data)
                if cand.endswith(".png"):
                    try:
                        return _thumb_image(dest, dest)
                    except Exception:
                        return True
                return True
        media = [n for n in z.namelist() if n.startswith("ppt/media/") and n.rsplit(".", 1)[-1].lower() in IMAGE_EXTS]
        if media:
            tmp = dest + ".src"
            with open(tmp, "wb") as f:
                f.write(z.read(media[0]))
            ok = _thumb_image(tmp, dest)
            try:
                os.remove(tmp)
            except OSError:
                pass
            return ok
    return False


def _thumb_pdf(src, dest):
    renderer = shutil.which("pdftoppm")
    if not renderer:
        return False
    with tempfile.TemporaryDirectory() as tmp:
        prefix = os.path.join(tmp, "preview")
        result = subprocess.run(
            [renderer, "-f", "1", "-l", "1", "-scale-to", str(THUMB_MAX), "-singlefile", "-jpeg", src, prefix],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
        )
        preview = prefix + ".jpg"
        if result.returncode or not os.path.isfile(preview):
            return False
        shutil.copyfile(preview, dest)
        return True


def _make_id(session_id, rel, size, mtime):
    raw = f"{session_id}|{rel}|{size}|{mtime:.3f}".encode()
    return "dl_" + hashlib.sha256(raw).hexdigest()[:16]


def describe_file(session_id, user_path, source="auto"):
    """Resolve a workspace / @shared path and return card metadata after copying into deliveries/."""
    target, err = _srv().safe_path_resolve(session_id, user_path)
    if err:
        return None, err
    if not target or not os.path.isfile(target):
        return None, "文件不存在"
    try:
        size = os.path.getsize(target)
    except OSError as e:
        return None, str(e)
    if size > MAX_BYTES:
        return None, f"文件超过 {MAX_BYTES // (1024 * 1024)} MB 上限"
    name = os.path.basename(target)
    mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
    kind = _kind_for(name, mime)
    st = os.stat(target)
    did = _make_id(session_id, user_path, size, st.st_mtime)
    ddir = os.path.join(deliveries_dir(session_id), did)
    os.makedirs(ddir, exist_ok=True)
    stored_name = "payload-" + (re.sub(r"[^A-Za-z0-9._+\u4e00-\u9fff-]+", "_", name).strip("._") or "file")
    stored = os.path.join(ddir, stored_name)
    if not os.path.isfile(stored):
        with tempfile.NamedTemporaryFile(dir=ddir, prefix=".copy-", delete=False) as temp:
            temp_path = temp.name
        try:
            shutil.copy2(target, temp_path)
            os.replace(temp_path, stored)
        finally:
            if os.path.exists(temp_path):
                os.unlink(temp_path)
    item = {
        "id": did,
        "kind": kind,
        "name": name,
        "path": user_path,
        "bytes": size,
        "mime": mime,
        "sha256": _sha256(stored),
        "source": source,
        "url": f"/v1/sessions/{session_id}/deliveries/{did}/file",
        "at": st.st_mtime,
    }
    pages = _office_pages(stored, name)
    if pages:
        item["pages"] = pages
    if kind == "zip":
        names, total = _zip_namelist(stored)
        item["entries"] = names
        item["entry_count"] = total
    if kind == "ipa":
        item.update({k: v for k, v in _ipa_meta(stored).items() if v})
        names, total = _zip_namelist(stored)
        if names:
            item["entries"] = names[:10]
            item["entry_count"] = total
    thumb = os.path.join(ddir, "thumb.jpg")
    if os.path.isfile(thumb) or _make_thumb(stored, thumb, name):
        item["thumb_url"] = f"/v1/sessions/{session_id}/deliveries/{did}/thumb"
    meta_path = os.path.join(ddir, "meta.json")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(item, f, ensure_ascii=False)
    return item, None


def tool_deliver_file(task_id, session_id, args):
    path = (args or {}).get("path")
    if not isinstance(path, str) or not path.strip():
        return {"error": "缺少 path"}
    item, err = describe_file(session_id, path.strip(), source="deliver_file")
    if err:
        return {"error": err}
    TASK_DELIVERED.setdefault(task_id, [])
    if not any(d.get("id") == item["id"] for d in TASK_DELIVERED[task_id]):
        TASK_DELIVERED[task_id].append(item)
        try:
            _srv().log_event(task_id, "deliverable", {"item": item, "message": f"已交付 {item['name']}"})
        except Exception:
            pass
    return {"status": "ok", "deliverable": item, "note": "文件会作为卡片出现在聊天里，不用再向用户报路径。"}


def remember_task_items(task_id, items):
    if items:
        current = TASK_DELIVERED.setdefault(task_id, [])
        TASK_DELIVERED[task_id] = merge_items(current, items, [])


def extract_links(text):
    """Markdown 链接和裸 URL → 链接卡片（不主动抓取远程页面，避免 SSRF）。"""
    items, seen = [], set()
    if not text:
        return items
    for title, url in LINK_MD_RE.findall(text):
        url = url.rstrip(".,;:!?）)。，")
        if url in seen or not url.startswith(("http://", "https://")):
            continue
        seen.add(url)
        items.append(_link_item(url, title.strip() or None))
    for m in LINK_BARE_RE.finditer(text):
        url = m.group("url").rstrip(".,;:!?）)。，")
        if url in seen or not url.startswith(("http://", "https://")):
            continue
        seen.add(url)
        items.append(_link_item(url, None))
    return items


def _link_item(url, title):
    host = ""
    try:
        from urllib.parse import urlparse
        host = urlparse(url).hostname or ""
    except Exception:
        host = ""
    did = "dl_" + hashlib.sha256(url.encode()).hexdigest()[:16]
    return {
        "id": did,
        "kind": "link",
        "name": title or host or url,
        "title": title or host or url,
        "href": url,
        "site": host,
        "source": "link",
        "bytes": 0,
    }


def merge_items(explicit, auto, links):
    out, seen = [], set()
    for item in (explicit or []) + (auto or []) + (links or []):
        key = item.get("id") or item.get("href") or item.get("path")
        if not key or key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def capture_for_task(task_id, session_id, final_text=""):
    """Merge explicit deliver_file results, auto-captured new files, and links in the final text."""
    snapshot_state = TASK_SNAPSHOT.get(task_id)
    auto = []
    for key, full, size in new_files(session_id, snapshot_state[0]) if snapshot_state else ():
        item, err = describe_file(session_id, key, source="auto")
        if item:
            auto.append(item)
    explicit = list(TASK_DELIVERED.get(task_id) or [])
    links = extract_links(final_text)
    return merge_items(explicit, auto, links)


def last_assistant_row(session_id, since=0):
    conn = _srv().get_db_connection()
    try:
        return conn.execute(
            "SELECT id, content, meta FROM messages WHERE session_id = ? AND role = 'assistant' "
            "AND content IS NOT NULL AND TRIM(content) != '' AND (tool_calls IS NULL OR tool_calls = '') "
            "AND timestamp >= ? ORDER BY id DESC LIMIT 1",
            (session_id, since),
        ).fetchone()
    finally:
        conn.close()


def attach_to_last_assistant(session_id, items, extra_meta=None, since=0):
    """Write deliverables onto the last visible assistant message, or insert a short one."""
    if not items:
        return None
    conn = _srv().get_db_connection()
    try:
        row = conn.execute(
            "SELECT id, content, meta FROM messages WHERE session_id = ? AND role = 'assistant' "
            "AND content IS NOT NULL AND TRIM(content) != '' AND (tool_calls IS NULL OR tool_calls = '') "
            "AND timestamp >= ? ORDER BY id DESC LIMIT 1",
            (session_id, since),
        ).fetchone()
        if row:
            mid, content, raw = row
            meta = {}
            if raw:
                try:
                    meta = json.loads(raw) or {}
                except ValueError:
                    meta = {}
            existing = meta.get("deliverables") or []
            meta["deliverables"] = merge_items(existing, items, [])
            if extra_meta:
                meta.update(extra_meta)
            conn.execute("UPDATE messages SET meta = ? WHERE id = ?",
                         (json.dumps(meta, ensure_ascii=False), mid))
            conn.commit()
            return mid
        text = "做好了，文件在下面。"
        meta = {"deliverables": items}
        if extra_meta:
            meta.update(extra_meta)
        conn.execute(
            "INSERT INTO messages (session_id, role, content, timestamp, meta) "
            "SELECT session_id, 'assistant', ?, ?, ? FROM sessions WHERE session_id = ?",
            (text, time.time(), json.dumps(meta, ensure_ascii=False), session_id),
        )
        conn.commit()
        return conn.execute("SELECT last_insert_rowid()").fetchone()[0]
    finally:
        conn.close()


def finish_task(task_id, session_id, final_status):
    """Attach captured files to the last assistant message when a task ends."""
    try:
        if final_status in ("cancelled",):
            return []
        text = ""
        snapshot_state = TASK_SNAPSHOT.get(task_id)
        since = snapshot_state[1] if snapshot_state else 0
        row = last_assistant_row(session_id, since)
        if row:
            text = row[1] or ""
        items = capture_for_task(task_id, session_id, text)
        if items:
            attach_to_last_assistant(session_id, items, since=since)
        return items
    finally:
        forget_task(task_id)


def list_session_deliveries(session_id, query=None):
    """All deliverables in this chat, newest first. Optional case-insensitive name/path search."""
    items, seen = [], set()
    conn = _srv().get_db_connection()
    try:
        rows = conn.execute(
            "SELECT meta, timestamp FROM messages WHERE session_id = ? AND meta IS NOT NULL ORDER BY id DESC",
            (session_id,),
        ).fetchall()
    finally:
        conn.close()
    for raw, ts in rows:
        try:
            meta = json.loads(raw) or {}
        except ValueError:
            continue
        for item in meta.get("deliverables") or []:
            did = item.get("id")
            if not did or did in seen:
                continue
            seen.add(did)
            entry = dict(item)
            entry.setdefault("at", ts)
            items.append(entry)
    # deliveries/ 里尚未挂到消息上的（少见）
    root = deliveries_dir(session_id)
    if os.path.isdir(root):
        for name in os.listdir(root):
            if not DELIVER_ID_RE.match(name) or name in seen:
                continue
            meta_path = os.path.join(root, name, "meta.json")
            if not os.path.isfile(meta_path):
                continue
            try:
                with open(meta_path, encoding="utf-8") as f:
                    item = json.load(f)
            except (OSError, ValueError):
                continue
            if item.get("id"):
                seen.add(item["id"])
                items.append(item)
    items.sort(key=lambda i: i.get("at") or 0, reverse=True)
    if query:
        q = query.lower()
        items = [i for i in items if q in (i.get("name") or "").lower()
                 or q in (i.get("path") or "").lower()
                 or q in (i.get("title") or "").lower()
                 or q in (i.get("href") or "").lower()
                 or q in (i.get("site") or "").lower()]
    return items


def load_item(session_id, did):
    if not DELIVER_ID_RE.match(did or ""):
        return None
    meta_path = os.path.join(deliveries_dir(session_id), did, "meta.json")
    if os.path.isfile(meta_path):
        try:
            with open(meta_path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None
    for item in list_session_deliveries(session_id):
        if item.get("id") == did:
            return item
    return None


def file_path(session_id, did):
    item = load_item(session_id, did)
    if not item:
        return None, None
    ddir = os.path.join(deliveries_dir(session_id), did)
    if os.path.isdir(ddir):
        for name in os.listdir(ddir):
            if name in ("meta.json", "thumb.jpg", "thumb.png") or name.startswith(".copy-"):
                continue
            full = os.path.join(ddir, name)
            if os.path.isfile(full):
                return item, full
    # 链接没有文件
    if item.get("kind") == "link":
        return item, None
    return item, None


def thumb_path(session_id, did):
    p = os.path.join(deliveries_dir(session_id), did, "thumb.jpg")
    return p if os.path.isfile(p) else None


def copy_items_to_session(src_session, dest_session, items, source="delegate"):
    """Copy delivered files into another session (sub-Bot / worker → originating chat)."""
    out = []
    for item in items or []:
        if item.get("kind") == "link":
            copied = dict(item)
            copied["source"] = source
            copied.pop("url", None)
            out.append(copied)
            continue
        src_item, src_file = file_path(src_session, item.get("id"))
        if not src_file or not os.path.isfile(src_file):
            # 尝试按原路径在源会话工作区再找一次
            path = item.get("path")
            if path:
                # 不能用 dest 的 path 解析源文件；用源会话再交付到目标
                target, err = _srv().safe_path_resolve(src_session, path) if path else (None, "no path")
                if not err and target and os.path.isfile(target):
                    # 把源文件拷进目标工作区 attachments/ 再交付
                    dest_rel = _place_in_dest(dest_session, target, os.path.basename(target))
                    described, err = describe_file(dest_session, dest_rel, source=source)
                    if described:
                        out.append(described)
                continue
            continue
        original = item.get("name") or os.path.basename(src_file)
        dest_rel = _place_in_dest(dest_session, src_file, original)
        described, err = describe_file(dest_session, dest_rel, source=source)
        if described:
            described["name"] = original
            for k in ("title", "site", "href", "version", "build", "app_name", "pages", "entries", "entry_count"):
                if k in item and k not in described:
                    described[k] = item[k]
            described["source"] = source
            # 刷新 meta.json 里的显示名
            try:
                meta_path = os.path.join(deliveries_dir(dest_session), described["id"], "meta.json")
                with open(meta_path, "w", encoding="utf-8") as f:
                    json.dump(described, f, ensure_ascii=False)
            except OSError:
                pass
            out.append(described)
    return out


def _place_in_dest(dest_session, src_file, name):
    safe = re.sub(r"[^A-Za-z0-9._+\u4e00-\u9fff-]+", "_", name).strip("._") or "file"
    rel = "attachments/frombot_" + hashlib.sha256((src_file + safe).encode()).hexdigest()[:8] + "_" + safe
    target, err = _srv().safe_path_resolve(dest_session, rel)
    if err:
        raise ValueError(err)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if not os.path.isfile(target):
        shutil.copy2(src_file, target)
    return rel


def items_from_session(session_id, since=None):
    """Read the result of a specific run, or the latest result for legacy callers."""
    row = last_assistant_row(session_id, since or 0)
    if row and row[2]:
        try:
            meta = json.loads(row[2]) or {}
            items = meta.get("deliverables") or []
            if items:
                return items
        except ValueError:
            pass
    return list_session_deliveries(session_id) if since is None else []


def propagate(src_session, dest_session, source, dest_text=None, extra_meta=None):
    """Copy src session deliverables into dest and attach them to dest's last assistant message (or insert)."""
    items = items_from_session(src_session)
    if not items:
        return []
    copied = copy_items_to_session(src_session, dest_session, items, source=source)
    if dest_text:
        copied = merge_items(copied, [], extract_links(dest_text))
    if copied:
        attach_to_last_assistant(dest_session, copied, extra_meta=extra_meta)
    return copied


def send_file(handler, path, content_type, filename=None):
    """Write a file to the HTTP handler, honoring Range for resume. Returns True if sent."""
    if not path or not os.path.isfile(path):
        return False
    size = os.path.getsize(path)
    rng = handler.headers.get("Range") or handler.headers.get("range")
    start, end = 0, size - 1
    status = 200
    if rng and rng.startswith("bytes=") and size > 0:
        spec = rng[6:].strip()
        if "," not in spec:
            a, _, b = spec.partition("-")
            try:
                if a and b:
                    start, end = int(a), int(b)
                elif a:
                    start, end = int(a), size - 1
                elif b:
                    start, end = max(0, size - int(b)), size - 1
                else:
                    start, end = 0, size - 1
            except ValueError:
                start, end = 0, size - 1
            start = max(0, min(start, size - 1))
            end = max(start, min(end, size - 1))
            if start != 0 or end != size - 1:
                status = 206
    length = end - start + 1
    handler.send_response(status)
    handler.send_header("Content-Type", content_type or "application/octet-stream")
    handler.send_header("Content-Length", str(length))
    handler.send_header("Accept-Ranges", "bytes")
    if status == 206:
        handler.send_header("Content-Range", f"bytes {start}-{end}/{size}")
    if filename:
        from urllib.parse import quote
        handler.send_header("Content-Disposition", f"attachment; filename*=UTF-8''{quote(filename)}")
    handler.end_headers()
    with open(path, "rb") as f:
        f.seek(start)
        left = length
        while left > 0:
            chunk = f.read(min(1024 * 256, left))
            if not chunk:
                break
            handler.wfile.write(chunk)
            left -= len(chunk)
    return True


def handle_get(handler, path, query_params=None):
    """GET /v1/sessions/{sid}/deliveries[/{id}[/file|/thumb]]. Returns True if handled."""
    m = re.match(r"^/v1/sessions/([A-Za-z0-9_-]{1,64})/deliveries(?:/([A-Za-z0-9_]+))?(?:/(file|thumb))?$", path)
    if not m:
        return False
    sid, did, part = m.group(1), m.group(2), m.group(3)
    conn = _srv().get_db_connection()
    try:
        exists = conn.execute(
            "SELECT 1 FROM sessions WHERE session_id = ? AND COALESCE(incognito, 0) = 0", (sid,)
        ).fetchone()
    finally:
        conn.close()
    if not exists:
        handler._send(404, {"error": "Session not found"})
        return True
    if not did:
        q = None
        if query_params and query_params.get("q"):
            q = (query_params.get("q") or [None])[0]
        handler._send(200, {"deliveries": list_session_deliveries(sid, q)})
        return True
    if not DELIVER_ID_RE.match(did):
        handler._send(400, {"error": "Invalid delivery id"})
        return True
    if part == "thumb":
        tp = thumb_path(sid, did)
        if not tp:
            handler._send(404, {"error": "Thumbnail not found"})
            return True
        send_file(handler, tp, "image/jpeg")
        return True
    if part == "file":
        item, fp = file_path(sid, did)
        if not item:
            handler._send(404, {"error": "Delivery not found"})
            return True
        if item.get("kind") == "link":
            handler._send(400, {"error": "Link has no file body"})
            return True
        if not fp:
            handler._send(404, {"error": "File not found"})
            return True
        send_file(handler, fp, item.get("mime") or "application/octet-stream", item.get("name"))
        return True
    item = load_item(sid, did)
    if not item:
        handler._send(404, {"error": "Delivery not found"})
        return True
    handler._send(200, {"deliverable": item})
    return True
