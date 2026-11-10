"""手机 ⇄ 云电脑文件：照片 / 文件直接放进云电脑「下载」文件夹（桌面上的浏览器、文件管理器都能看到），
也能把云电脑下载的文件取回手机。按 id（文件名哈希）取，不让手机传路径。"""
import hashlib
import os
import re
import time

MAX_UPLOAD = 50 * 1024 * 1024
MAX_FETCH = 25 * 1024 * 1024
LIST_LIMIT = 30


def drop_dir():
    d = os.environ.get("OPENMINIS_DESKTOP_DOWNLOADS") or os.path.join(os.path.expanduser("~"), "Downloads")
    os.makedirs(d, exist_ok=True)
    return d


def safe_name(name):
    base = os.path.basename((name or "").replace("\\", "/")).strip()
    base = re.sub(r"[\x00-\x1f]", "", base).lstrip(".")
    return base[:120] or "file"


def file_id(name):
    return hashlib.sha1(name.encode("utf-8")).hexdigest()[:12]


def save(filename, data):
    if len(data) > MAX_UPLOAD:
        raise ValueError("文件超过 50 MB")
    d = drop_dir()
    name = safe_name(filename)
    stem, ext = os.path.splitext(name)
    final, n = name, 1
    while os.path.exists(os.path.join(d, final)):
        n += 1
        final = f"{stem} ({n}){ext}"
    with open(os.path.join(d, final), "wb") as f:
        f.write(data)
    return {"name": final, "id": file_id(final), "bytes": len(data)}


def listing():
    d = drop_dir()
    out = []
    for name in os.listdir(d):
        p = os.path.join(d, name)
        if os.path.isfile(p) and not name.startswith(".") and not name.endswith((".crdownload", ".part")):
            st = os.stat(p)
            out.append({"name": name, "id": file_id(name), "bytes": st.st_size, "mtime": st.st_mtime})
    out.sort(key=lambda x: -x["mtime"])
    return out[:LIST_LIMIT]


def read(fid):
    for item in listing():
        if item["id"] == fid:
            if item["bytes"] > MAX_FETCH:
                raise ValueError("文件超过 25 MB，请在云电脑上用网盘传")
            with open(os.path.join(drop_dir(), item["name"]), "rb") as f:
                return item["name"], f.read()
    return None, None
