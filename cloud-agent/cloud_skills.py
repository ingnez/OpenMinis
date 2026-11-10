#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent — 技能按需加载。

手机把 skills/<名称>/SKILL.md 同步到 VPS 的 skills 表；每次对话只把“名称 + 描述”索引放进
system 消息，模型需要时调用 skill_load(name) 读取全文，避免把全部技能塞进上下文。
"""

import hashlib
import re
import time

NAME_RE = re.compile(r"^[^/\\\x00-\x1f]{1,80}$")
MAX_CONTENT = 300_000
MAX_SKILLS = 1000
INDEX_DESC_CHARS = 240
INDEX_MAX_CHARS = 24_000


def ensure_schema(conn):
    conn.execute("""
    CREATE TABLE IF NOT EXISTS skills (
        name TEXT PRIMARY KEY,
        description TEXT,
        content TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        source TEXT NOT NULL,
        updated_at REAL NOT NULL
    )
    """)
    conn.commit()


def parse_description(content):
    """YAML frontmatter 的 description（支持单行与 `>`/`|` 折叠块），否则取首个非标题段落。"""
    text = content.lstrip("\ufeff")
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            lines = text[3:end].splitlines()
            for i, line in enumerate(lines):
                m = re.match(r"^description\s*:\s*(.*)$", line)
                if not m:
                    continue
                val = m.group(1).strip()
                if val in (">", "|", ">-", "|-", ""):
                    block = []
                    for nxt in lines[i + 1:]:
                        if nxt.startswith((" ", "\t")):
                            block.append(nxt.strip())
                        else:
                            break
                    val = " ".join(block)
                return val.strip().strip("\"'")
            text = text[end + 4:]
    for para in re.split(r"\n\s*\n", text):
        p = para.strip()
        if p and not p.startswith("#"):
            return " ".join(p.split())[:INDEX_DESC_CHARS]
    return ""


def validate_name(name):
    if not isinstance(name, str) or not NAME_RE.match(name) or name in (".", "..") or name != name.strip():
        raise ValueError("invalid skill name")
    return name


def upsert(conn, name, content, description=None, source="phone", commit=True):
    """返回 'added' / 'updated' / 'unchanged'。"""
    validate_name(name)
    if not isinstance(content, str) or not content.strip():
        raise ValueError("content must be a non-empty string")
    if len(content.encode("utf-8")) > MAX_CONTENT:
        raise ValueError("skill too large (max 300KB)")
    if description is None or not str(description).strip():
        description = parse_description(content)
    description = " ".join(str(description).split())[:1000]
    h = hashlib.sha256(content.encode("utf-8")).hexdigest()
    row = conn.execute("SELECT content_hash, description FROM skills WHERE name = ?", (name,)).fetchone()
    if row and row[0] == h and row[1] == description:
        return "unchanged"
    conn.execute("INSERT INTO skills (name, description, content, content_hash, source, updated_at) VALUES (?, ?, ?, ?, ?, ?) "
                 "ON CONFLICT(name) DO UPDATE SET description = excluded.description, content = excluded.content, "
                 "content_hash = excluded.content_hash, source = excluded.source, updated_at = excluded.updated_at",
                 (name, description, content, h, source, time.time()))
    if commit:
        conn.commit()
    return "updated" if row else "added"


def sync(conn, skills, prune=False, source="phone"):
    """批量同步；prune 时删除同来源中不在列表里的技能。全部校验通过才写入。"""
    if not isinstance(skills, list) or len(skills) > MAX_SKILLS:
        raise ValueError(f"skills must be a list (max {MAX_SKILLS})")
    seen = set()
    for s in skills:
        if not isinstance(s, dict):
            raise ValueError("each skill must be an object")
        validate_name(s.get("name"))
        if s["name"] in seen:
            raise ValueError("duplicate skill name: " + s["name"])
        seen.add(s["name"])
    counts = {"added": 0, "updated": 0, "unchanged": 0, "removed": 0}
    try:
        for s in skills:
            counts[upsert(conn, s["name"], s.get("content"), s.get("description"), source=source, commit=False)] += 1
        if prune:
            existing = [r[0] for r in conn.execute("SELECT name FROM skills WHERE source = ?", (source,)).fetchall()]
            for name in existing:
                if name not in seen:
                    conn.execute("DELETE FROM skills WHERE name = ?", (name,))
                    counts["removed"] += 1
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    counts["total"] = conn.execute("SELECT COUNT(*) FROM skills").fetchone()[0]
    return counts


def delete(conn, name):
    cur = conn.execute("DELETE FROM skills WHERE name = ?", (name,))
    conn.commit()
    return cur.rowcount > 0


def list_index(conn):
    rows = conn.execute("SELECT name, description, length(content), source, updated_at FROM skills ORDER BY name").fetchall()
    return [{"name": r[0], "description": r[1], "size": r[2], "source": r[3], "updated_at": r[4]} for r in rows]


def load(conn, name):
    row = conn.execute("SELECT name, description, content, updated_at FROM skills WHERE name = ?", (name,)).fetchone()
    if not row:
        return None
    return {"name": row[0], "description": row[1], "content": row[2], "updated_at": row[3]}


def index_text(conn):
    """system 消息中的技能索引；无技能时返回空串。"""
    items = list_index(conn)
    if not items:
        return ""
    lines, used = [], 0
    for it in items:
        desc = (it["description"] or "")[:INDEX_DESC_CHARS]
        line = f"- {it['name']}: {desc}" if desc else f"- {it['name']}"
        if used + len(line) > INDEX_MAX_CHARS:
            lines.append(f"- ……另有 {len(items) - len(lines)} 个技能未列出，可用 skill_load 按名称加载")
            break
        lines.append(line)
        used += len(line) + 1
    return ("\n\n[技能] 以下是用户同步到 VPS 的技能索引（只有名称与描述）。任务与某个技能相关时，先调用 skill_load(name) 读取完整说明再按其执行；"
            "技能中引用的脚本或二进制若不在 VPS 上，应先核实再使用，不要假定存在。\n" + "\n".join(lines))
