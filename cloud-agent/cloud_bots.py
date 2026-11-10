# -*- coding: utf-8 -*-
"""多 Bot：在 personas 表上扩展（旧人格自动成为 Bot）。

每个 Bot 有名称、头像（emoji）、简介、指令、可选的模型与凭据、技能白名单、插件授权，
以及可选的“主 Bot”（管理者，负责把请求转交给其他 Bot）。Bot 的会话、例行任务、Telegram
渠道与私有记忆通过 persona_id 关联。导出 / 导入为 JSON（不含任何密钥）。
"""

import json
import re
import time

BOT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
EXPORT_FORMAT = "openminis-bot/1"

EXTRA_COLUMNS = {
    "description": "TEXT",
    "model": "TEXT",
    "credential": "TEXT",
    "skills": "TEXT",      # JSON 列表；NULL 表示全部技能
    "plugins": "TEXT",     # JSON 列表：授权给此 Bot 的插件 id
    "is_primary": "INTEGER NOT NULL DEFAULT 0",
    "reasoning_effort": "TEXT",   # off / low / medium / high / xhigh；NULL = 跟随客户端
    "fast_mode": "INTEGER NOT NULL DEFAULT 0",   # 快速模式：低思考强度、短回答
}

COLS = "persona_id, name, instructions, emoji, created_at, updated_at, description, model, credential, skills, plugins, is_primary, reasoning_effort, fast_mode"
EFFORTS = ("off", "low", "medium", "high", "xhigh")


class BotError(ValueError):
    pass


VERSIONS_KEEP = 20
SNAPSHOT_KEYS = ("name", "instructions", "emoji", "description", "model", "credential", "skills", "plugins", "reasoning_effort", "fast_mode")


def ensure_schema(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS bot_versions (id INTEGER PRIMARY KEY AUTOINCREMENT, bot_id TEXT NOT NULL, "
                 "snapshot TEXT NOT NULL, created_at REAL NOT NULL)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_bot_versions ON bot_versions(bot_id, id)")
    cols = {r[1] for r in conn.execute("PRAGMA table_info(personas)").fetchall()}
    for name, decl in EXTRA_COLUMNS.items():
        if name not in cols:
            conn.execute(f"ALTER TABLE personas ADD COLUMN {name} {decl}")
    conn.commit()


def _row(r):
    if not r:
        return None
    def lst(v):
        try:
            out = json.loads(v) if v else None
            return out if isinstance(out, list) else None
        except ValueError:
            return None
    return {"persona_id": r[0], "bot_id": r[0], "name": r[1], "instructions": r[2], "emoji": r[3],
            "created_at": r[4], "updated_at": r[5], "description": r[6] or "", "model": r[7],
            "credential": r[8], "skills": lst(r[9]), "plugins": lst(r[10]) or [], "is_primary": bool(r[11]),
            "reasoning_effort": r[12] if len(r) > 12 else None,
            "fast_mode": bool(r[13]) if len(r) > 13 else False}


def get(conn, bot_id):
    if not bot_id:
        return None
    return _row(conn.execute(f"SELECT {COLS} FROM personas WHERE persona_id = ?", (bot_id,)).fetchone())


def list_bots(conn):
    return [_row(r) for r in conn.execute(f"SELECT {COLS} FROM personas ORDER BY is_primary DESC, created_at ASC").fetchall()]


def primary(conn):
    return _row(conn.execute(f"SELECT {COLS} FROM personas WHERE is_primary = 1 LIMIT 1").fetchone())


def _str(body, key, maxlen, required=False, allow_empty=True):
    v = body.get(key)
    if v is None:
        if required:
            raise BotError(f"{key} is required")
        return None
    if not isinstance(v, str) or len(v) > maxlen or (not allow_empty and not v.strip()):
        raise BotError(f"{key} must be a {'non-empty ' if not allow_empty else ''}string (max {maxlen})")
    return v


def _name_list(body, key, pattern, limit=200):
    if key not in body:
        return False, None
    v = body[key]
    if v is None:
        return True, None
    if not isinstance(v, list) or len(v) > limit or not all(isinstance(x, str) and pattern.match(x) for x in v):
        raise BotError(f"{key} must be a list of names")
    return True, sorted(set(v))


NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$")


def validate(body, existing=None, credential_exists=None):
    """返回待写入的字段；existing 为当前记录（更新时缺省字段沿用）。"""
    if not isinstance(body, dict):
        raise BotError("body must be an object")
    out = {}
    name = _str(body, "name", 60, required=existing is None, allow_empty=False)
    if name is not None:
        out["name"] = name.strip()
    instr = _str(body, "instructions", 20000, required=existing is None, allow_empty=False)
    if instr is not None:
        out["instructions"] = instr
    for key, maxlen in (("emoji", 40), ("description", 500), ("model", 200)):
        if key in body:
            v = _str(body, key, maxlen)
            out[key] = v if v else None
    if "credential" in body:
        v = body.get("credential")
        if v in (None, ""):
            out["credential"] = None
        else:
            if not isinstance(v, str) or not re.match(r"^[A-Za-z0-9_.-]{1,64}$", v) or (credential_exists and not credential_exists(v)):
                raise BotError("credential must name a stored credential")
            out["credential"] = v
    present, skills = _name_list(body, "skills", NAME_RE)
    if present:
        out["skills"] = None if skills is None else json.dumps(skills, ensure_ascii=False)
    present, plugins = _name_list(body, "plugins", NAME_RE)
    if present:
        out["plugins"] = json.dumps(plugins or [], ensure_ascii=False)
    if "reasoning_effort" in body:
        v = body["reasoning_effort"]
        if v not in (None, "") and v not in EFFORTS:
            raise BotError("reasoning_effort must be one of off/low/medium/high/xhigh or null")
        out["reasoning_effort"] = v or None
    if "fast_mode" in body:
        if not isinstance(body["fast_mode"], bool):
            raise BotError("fast_mode must be a boolean")
        out["fast_mode"] = 1 if body["fast_mode"] else 0
    if "is_primary" in body:
        if not isinstance(body["is_primary"], bool):
            raise BotError("is_primary must be a boolean")
        out["is_primary"] = 1 if body["is_primary"] else 0
    merged_model = out.get("model", existing.get("model") if existing else None)
    merged_cred = out.get("credential", existing.get("credential") if existing else None)
    if bool(merged_model) != bool(merged_cred):
        raise BotError("model and credential must be set together (or both empty to use the client's choice)")
    return out


def upsert(conn, bot_id, body, credential_exists=None):
    if not isinstance(bot_id, str) or not BOT_ID_RE.match(bot_id):
        raise BotError("bot_id must match ^[a-z0-9][a-z0-9_-]{0,31}$")
    existing = get(conn, bot_id)
    fields = validate(body, existing, credential_exists)
    now = time.time()
    if fields.get("is_primary"):
        conn.execute("UPDATE personas SET is_primary = 0 WHERE persona_id != ?", (bot_id,))
    if existing:
        if fields and _changes(existing, fields):
            save_version(conn, existing, now)
        if fields:
            sets = ", ".join(f"{k} = ?" for k in fields)
            conn.execute(f"UPDATE personas SET {sets}, updated_at = ? WHERE persona_id = ?", (*fields.values(), now, bot_id))
    else:
        fields.setdefault("plugins", "[]")
        keys = ["persona_id", "created_at", "updated_at"] + list(fields)
        conn.execute(f"INSERT INTO personas ({', '.join(keys)}) VALUES ({', '.join('?' for _ in keys)})",
                     (bot_id, now, now, *fields.values()))
    conn.commit()
    return get(conn, bot_id), existing is None


def _snapshot(bot):
    return {k: bot.get(k) for k in SNAPSHOT_KEYS}


def _changes(existing, fields):
    """只有设置真的变了才存版本（只改主 Bot 标记不算）。"""
    cur = {"name": existing.get("name"), "instructions": existing.get("instructions"), "emoji": existing.get("emoji"),
           "description": existing.get("description") or None, "model": existing.get("model"), "credential": existing.get("credential"),
           "skills": None if existing.get("skills") is None else json.dumps(existing["skills"], ensure_ascii=False),
           "plugins": json.dumps(existing.get("plugins") or [], ensure_ascii=False),
           "reasoning_effort": existing.get("reasoning_effort"), "fast_mode": 1 if existing.get("fast_mode") else 0}
    return any(k in cur and cur[k] != v for k, v in fields.items())


def save_version(conn, bot, now=None):
    c = conn.execute("INSERT INTO bot_versions (bot_id, snapshot, created_at) VALUES (?, ?, ?)",
                     (bot["bot_id"], json.dumps(_snapshot(bot), ensure_ascii=False), now or time.time()))
    conn.execute("DELETE FROM bot_versions WHERE bot_id = ? AND id NOT IN (SELECT id FROM bot_versions WHERE bot_id = ? ORDER BY id DESC LIMIT ?)",
                 (bot["bot_id"], bot["bot_id"], VERSIONS_KEEP))
    return c.lastrowid


def versions(conn, bot_id):
    rows = conn.execute("SELECT id, snapshot, created_at FROM bot_versions WHERE bot_id = ? ORDER BY id DESC", (bot_id,)).fetchall()
    out = []
    for vid, snap, at in rows:
        d = json.loads(snap)
        out.append({"id": vid, "created_at": at, "name": d.get("name"), "emoji": d.get("emoji"),
                    "instructions_preview": " ".join(str(d.get("instructions") or "").split())[:120], "snapshot": d})
    return out


def restore_version(conn, bot_id, version_id, credential_exists=None):
    """恢复到某个版本（当前设置会先存成一个新版本，所以恢复也能再撤回）。"""
    row = conn.execute("SELECT snapshot FROM bot_versions WHERE id = ? AND bot_id = ?", (version_id, bot_id)).fetchone()
    if not row:
        raise BotError("没有这个版本")
    snap = json.loads(row[0])
    body = {k: v for k, v in snap.items() if k in SNAPSHOT_KEYS}
    body["fast_mode"] = bool(body.get("fast_mode"))
    if body.get("credential") and credential_exists and not credential_exists(body["credential"]):
        # 当时用的凭据已删掉：恢复成跟随 App 的模型
        body["credential"], body["model"] = None, None
    return upsert(conn, bot_id, body, credential_exists)[0]


def skill_allowed(bot, skill_name):
    return bot is None or bot.get("skills") is None or skill_name in bot["skills"]


def prompt(bot, others):
    if not bot:
        return ""
    head = f"[人格：{bot['name']}] 本会话由用户创建的 Bot“{bot['name']}”负责，记忆与其他 Bot 隔离（共享记忆仍可见）。"
    if bot.get("description"):
        head += f"\n简介：{bot['description']}"
    text = head + "\n" + bot["instructions"] + "\n\n"
    if bot.get("is_primary"):
        text += ("[主 Bot] [管理员] 你是用户的主 Bot，拥有最高权限：用户让你新建、修改、删除、恢复 Bot，或调整别的 Bot 的记忆、技能、例行任务、"
                 "设置、插件、代理、云电脑时，直接用 create_bot / update_bot / delete_bot / restore_bot / set_primary_bot / list_bots / admin_api 去做，"
                 "不要让用户自己去设置里点。删除只是进回收站，改动都记在操作记录里可撤销。")
        if others:
            text += ("请求明显属于下列某个 Bot 的专长时，用 subagent_task 并传 persona 把任务转交给它，再整合答复；否则自己完成。可用 Bot："
                     + "；".join(f"{b['persona_id']}（{b['name']}{'：' + b['description'] if b.get('description') else ''}）" for b in others[:20]))
        text += "\n\n"
    return text


def export_bundle(conn, bot_id, routines, memory_entries):
    bot = get(conn, bot_id)
    if not bot:
        return None
    clean = {k: bot[k] for k in ("name", "emoji", "description", "instructions", "model", "skills", "plugins", "reasoning_effort", "fast_mode")}
    return {
        "format": EXPORT_FORMAT,
        "bot_id": bot_id,
        "bot": clean,   # 不导出 credential：导入方须使用自己的凭据
        "routines": [{k: r[k] for k in ("name", "prompt", "schedule", "instructions", "enabled", "max_runs") if k in r} for r in routines],
        "memory": [{"category": m["category"], "content": m["content"], "entry_time": m.get("entry_time")} for m in memory_entries],
        "exported_at": time.time(),
    }


def mentions(text, bots):
    """返回消息中 @提到的 Bot id（按出现顺序，去重）。"""
    ids = {b["persona_id"]: b for b in bots}
    names = {b["name"]: b["persona_id"] for b in bots}
    found = []
    for m in re.finditer(r"@([^\s@，。,.!?！？:：]+)", text or ""):
        token = m.group(1)
        pid = token if token in ids else names.get(token)
        if pid and pid not in found:
            found.append(pid)
    return found
