#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent — 结构化记忆（SQLite FTS5）。

与手机共用的 Markdown 格式（memory/YYYY-MM-DD.md）：

    <!-- 2026-11-10 08:30:00 #people -->
    ## 张三
    负责 ICU 排班……

每条以 `<!-- yyyy-MM-dd HH:mm:ss [#分类] -->` 开头，到下一条注释头为止；分类可省略（视为 note）。
GLOBAL.md 为用户维护的长期配置，按 `## ` 小节切分，分类记为 profile。

存储：memory_entries 表 + memory_fts（FTS5 trigram，支持中文子串）。trigram 需要查询词 ≥3 字符，
更短的词以 LIKE 匹配；SQLite 不支持 FTS5/trigram 时整体退化为 LIKE。
"""

import hashlib
import re
import time

CATEGORIES = ("profile", "rules", "people", "workstreams", "note")
HEADER_RE = re.compile(r"^<!--\s*(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?)?\s*(?:#([A-Za-z_]+))?\s*-->\s*$")
DAILY_RE = re.compile(r"^memory/(\d{4}-\d{2}-\d{2})\.md$")
MAX_CONTENT = 20000

_fts_state = {}


def normalize_category(category):
    if category is None or category == "":
        return "note"
    if not isinstance(category, str) or category.lower() not in CATEGORIES:
        raise ValueError("category must be one of: " + ", ".join(CATEGORIES))
    return category.lower()


def content_hash(category, content, persona=""):
    norm = "\n".join(line.rstrip() for line in content.strip().splitlines())
    scope = (persona + "\n") if persona else ""  # 默认人格保持旧哈希，兼容已有数据
    return hashlib.sha256((scope + category + "\n" + norm).encode("utf-8")).hexdigest()


def render_entry(entry_time, category, content):
    """渲染为共享格式的一条（不含尾部空行以外的内容）。"""
    tag = f" #{category}" if category and category != "note" else ""
    return f"<!-- {entry_time}{tag} -->\n{content.strip()}\n\n"


def parse_daily(text, default_date=None):
    """解析日志文件，返回 [(entry_time, category, content)]。无注释头时整文件为一条。"""
    entries = []
    cur_time, cur_cat, lines, seen_header = None, None, [], False

    def flush():
        body = "\n".join(lines).strip()
        if body:
            entries.append((cur_time or default_date, cur_cat or "note", body))

    for line in text.splitlines():
        m = HEADER_RE.match(line.strip()) if line.startswith("<!--") else None
        if m:
            flush()
            seen_header = True
            cur_time = (m.group(1) or "").replace("T", " ") or default_date
            cat = (m.group(2) or "").lower()
            cur_cat = cat if cat in CATEGORIES else "note"
            lines = []
        else:
            lines.append(line)
    flush()
    if not seen_header and entries:
        entries = [(default_date, "note", text.strip())]
    return entries


def parse_global(text):
    """GLOBAL.md 按二级标题切分。"""
    sections, cur = [], []
    for line in text.splitlines():
        if line.startswith("## ") and any(l.strip() for l in cur):
            sections.append("\n".join(cur).strip())
            cur = []
        cur.append(line)
    if any(l.strip() for l in cur):
        sections.append("\n".join(cur).strip())
    return [(None, "profile", s) for s in sections if s]


def ensure_schema(conn):
    c = conn.cursor()
    c.execute("""
    CREATE TABLE IF NOT EXISTS memory_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL DEFAULT 'note',
        content TEXT NOT NULL,
        source TEXT NOT NULL,
        origin TEXT,
        entry_time TEXT,
        content_hash TEXT NOT NULL UNIQUE,
        session_id TEXT,
        created_at REAL NOT NULL
    )
    """)
    cols = {row[1] for row in c.execute("PRAGMA table_info(memory_entries)")}
    if "persona" not in cols:
        c.execute("ALTER TABLE memory_entries ADD COLUMN persona TEXT NOT NULL DEFAULT ''")
    c.execute("CREATE INDEX IF NOT EXISTS idx_memory_origin ON memory_entries(source, origin)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_memory_created ON memory_entries(created_at)")
    try:
        c.execute("CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(content, content='memory_entries', content_rowid='id', tokenize='trigram')")
        c.execute("CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memory_entries BEGIN INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content); END")
        c.execute("CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memory_entries BEGIN INSERT INTO memory_fts(memory_fts, rowid, content) VALUES ('delete', old.id, old.content); END")
        c.execute("CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE ON memory_entries BEGIN INSERT INTO memory_fts(memory_fts, rowid, content) VALUES ('delete', old.id, old.content); INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content); END")
        fts = True
    except Exception:
        fts = False
    conn.commit()
    _fts_state["enabled"] = fts
    return fts


def fts_enabled(conn):
    if "enabled" not in _fts_state:
        row = conn.execute("SELECT name FROM sqlite_master WHERE name = 'memory_fts'").fetchone()
        _fts_state["enabled"] = bool(row)
    return _fts_state["enabled"]


def _row(r):
    return {"id": r[0], "category": r[1], "content": r[2], "source": r[3], "origin": r[4],
            "entry_time": r[5], "session_id": r[6], "created_at": r[7], "persona": r[8]}

COLS = "id, category, content, source, origin, entry_time, session_id, created_at, persona"


def write(conn, content, category=None, source="cloud", session_id=None, entry_time=None, origin=None, commit=True, persona=""):
    """写入一条；同分类同内容已存在时返回已有 id。返回 (entry dict, created)。"""
    if not isinstance(content, str) or not content.strip():
        raise ValueError("content must be a non-empty string")
    if len(content) > MAX_CONTENT:
        raise ValueError(f"content too long (max {MAX_CONTENT})")
    category = normalize_category(category)
    now = time.time()
    if entry_time is None:
        entry_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
    persona = persona or ""
    h = content_hash(category, content, persona)
    c = conn.cursor()
    c.execute("INSERT OR IGNORE INTO memory_entries (category, content, source, origin, entry_time, content_hash, session_id, created_at, persona) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
              (category, content.strip(), source, origin, entry_time, h, session_id, now, persona))
    created = c.rowcount == 1
    if commit:
        conn.commit()
    r = c.execute("SELECT " + COLS + " FROM memory_entries WHERE content_hash = ?", (h,)).fetchone()
    return _row(r), created


def delete(conn, entry_id):
    c = conn.cursor()
    c.execute("DELETE FROM memory_entries WHERE id = ?", (entry_id,))
    conn.commit()
    return c.rowcount > 0


def import_file(conn, rel_path, text, source="phone"):
    """导入手机同步来的 memory/*.md。同一来源文件的旧条目整体替换（手机文件为准）。返回导入条数。"""
    if rel_path == "memory/GLOBAL.md":
        entries = parse_global(text)
    else:
        m = DAILY_RE.match(rel_path)
        if not m:
            return 0
        entries = parse_daily(text, default_date=m.group(1))
    c = conn.cursor()
    c.execute("DELETE FROM memory_entries WHERE source = ? AND origin = ?", (source, rel_path))
    n = 0
    for entry_time, category, body in entries:
        if len(body) > MAX_CONTENT:
            body = body[:MAX_CONTENT]
        _, created = write(conn, body, category, source=source, entry_time=entry_time, origin=rel_path, commit=False)
        n += 1 if created else 0
    conn.commit()
    return n


def _tokens(query):
    return [t for t in re.split(r"\s+", (query or "").strip()) if t][:12]


def search(conn, query, category=None, limit=10, source=None, persona=None):
    """关键词检索：FTS5 trigram（≥3 字符的词）+ LIKE（短词），按命中词数、bm25、时间排序。
    persona 为 None 不过滤；否则只看共享记忆（persona = ''）与该人格自己的记忆。"""
    limit = max(1, min(int(limit or 10), 50))
    where, params = [], []
    if persona is not None:
        where.append("(e.persona = '' OR e.persona = ?)")
        params.append(persona)
    if category:
        where.append("e.category = ?")
        params.append(normalize_category(category))
    if source:
        where.append("e.source = ?")
        params.append(source)
    tokens = _tokens(query)
    base_where = (" AND " + " AND ".join(where)) if where else ""
    if not tokens:
        rows = conn.execute("SELECT " + ", ".join("e." + x.strip() for x in COLS.split(",")) +
                            " FROM memory_entries e WHERE 1=1" + base_where + " ORDER BY e.created_at DESC LIMIT ?",
                            params + [limit]).fetchall()
        return [dict(_row(r), score=0) for r in rows]

    candidates = {}
    long_tokens = [t for t in tokens if len(t) >= 3]
    short_tokens = [t for t in tokens if len(t) < 3]
    cols = ", ".join("e." + x.strip() for x in COLS.split(","))
    if long_tokens and fts_enabled(conn):
        match = " OR ".join('"' + t.replace('"', '""') + '"' for t in long_tokens)
        try:
            rows = conn.execute("SELECT " + cols + ", bm25(memory_fts) FROM memory_fts JOIN memory_entries e ON e.id = memory_fts.rowid"
                                " WHERE memory_fts MATCH ?" + base_where + " ORDER BY bm25(memory_fts) LIMIT 200",
                                [match] + params).fetchall()
            for r in rows:
                candidates[r[0]] = (_row(r[:9]), r[9])
        except Exception:
            short_tokens = tokens
    else:
        short_tokens = tokens
    for t in short_tokens:
        esc = t.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        rows = conn.execute("SELECT " + cols + " FROM memory_entries e WHERE e.content LIKE ? ESCAPE '\\'" + base_where +
                            " ORDER BY e.created_at DESC LIMIT 200", ["%" + esc + "%"] + params).fetchall()
        for r in rows:
            candidates.setdefault(r[0], (_row(r), 0.0))
    scored = []
    for entry, rank in candidates.values():
        low = entry["content"].lower()
        hits = sum(1 for t in tokens if t.lower() in low)
        if hits:
            scored.append((hits, -rank, entry["created_at"], entry))
    scored.sort(key=lambda x: (x[0], x[1], x[2]), reverse=True)
    return [dict(e, score=h) for h, _, _, e in scored[:limit]]


def list_entries(conn, since=None, source=None, limit=200):
    where, params = [], []
    if since is not None:
        where.append("created_at > ?")
        params.append(float(since))
    if source:
        where.append("source = ?")
        params.append(source)
    sql = "SELECT " + COLS + " FROM memory_entries" + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY created_at ASC LIMIT ?"
    return [_row(r) for r in conn.execute(sql, params + [max(1, min(int(limit), 1000))]).fetchall()]
