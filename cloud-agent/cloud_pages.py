#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent — Pages（HTML 报告库）。

云端 Agent 用 page_write 把报告、看板、交互式 HTML 保存到库里；手机在“云端页面库”中浏览。
页面在 iOS 端以无 baseURL 的 WKWebView 渲染（不带登录态、不能访问 VPS 接口）。
"""

import re
import time
import uuid

PAGE_ID_RE = re.compile(r"^page_[a-f0-9]{12}$")
MAX_HTML = 2 * 1024 * 1024
MAX_TITLE = 200


def ensure_schema(conn):
    conn.execute("""
    CREATE TABLE IF NOT EXISTS pages (
        page_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        html TEXT NOT NULL,
        summary TEXT,
        session_id TEXT,
        task_id TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_pages_updated ON pages(updated_at)")
    conn.commit()


def wrap_html(title, html):
    """片段补全为完整文档（含 viewport 与基础样式，适配手机与深色模式）。"""
    if re.search(r"<html[\s>]", html, re.I):
        return html
    esc = (title.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
    return ("<!doctype html><html lang=\"zh\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            f"<title>{esc}</title><style>:root{{color-scheme:light dark}}body{{font-family:-apple-system,system-ui,sans-serif;"
            "margin:16px;line-height:1.55}table{border-collapse:collapse}td,th{border:1px solid #8884;padding:4px 8px}"
            "img{max-width:100%}</style></head><body>" + html + "</body></html>")


def _summary(html):
    text = re.sub(r"<(script|style|head|title)[^>]*>.*?</\1>", " ", html, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    return " ".join(text.split())[:200]


def write(conn, title, html, page_id=None, session_id=None, task_id=None):
    """新建或更新页面，返回元数据 dict。非法输入抛 ValueError；page_id 不存在抛 KeyError。"""
    if not isinstance(title, str) or not title.strip() or len(title) > MAX_TITLE:
        raise ValueError(f"title must be a non-empty string (max {MAX_TITLE})")
    if not isinstance(html, str) or not html.strip():
        raise ValueError("html must be a non-empty string")
    doc = wrap_html(title.strip(), html)
    if len(doc.encode("utf-8")) > MAX_HTML:
        raise ValueError("page too large (max 2MB)")
    now = time.time()
    summary = _summary(doc)
    if page_id:
        if not isinstance(page_id, str) or not PAGE_ID_RE.match(page_id):
            raise KeyError(page_id)
        cur = conn.execute("UPDATE pages SET title = ?, html = ?, summary = ?, version = version + 1, updated_at = ?, task_id = COALESCE(?, task_id) WHERE page_id = ?",
                           (title.strip(), doc, summary, now, task_id, page_id))
        if cur.rowcount == 0:
            raise KeyError(page_id)
    else:
        page_id = "page_" + uuid.uuid4().hex[:12]
        conn.execute("INSERT INTO pages (page_id, title, html, summary, session_id, task_id, version, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)",
                     (page_id, title.strip(), doc, summary, session_id, task_id, now, now))
    conn.commit()
    return get(conn, page_id, with_html=False)


def get(conn, page_id, with_html=True):
    cols = "page_id, title, summary, session_id, task_id, version, created_at, updated_at, length(html)" + (", html" if with_html else "")
    r = conn.execute("SELECT " + cols + " FROM pages WHERE page_id = ?", (page_id,)).fetchone()
    if not r:
        return None
    d = {"page_id": r[0], "title": r[1], "summary": r[2], "session_id": r[3], "task_id": r[4], "version": r[5],
         "created_at": r[6], "updated_at": r[7], "size": r[8]}
    if with_html:
        d["html"] = r[9]
    return d


def list_pages(conn, limit=200):
    rows = conn.execute("SELECT page_id FROM pages ORDER BY updated_at DESC LIMIT ?", (max(1, min(int(limit), 1000)),)).fetchall()
    return [get(conn, r[0], with_html=False) for r in rows]


def delete(conn, page_id):
    cur = conn.execute("DELETE FROM pages WHERE page_id = ?", (page_id,))
    conn.commit()
    return cur.rowcount > 0
