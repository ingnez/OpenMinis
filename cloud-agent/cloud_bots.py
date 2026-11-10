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


def ensure_schema(conn):
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
    for key, maxlen in (("emoji", 16), ("description", 500), ("model", 200)):
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


def skill_allowed(bot, skill_name):
    return bot is None or bot.get("skills") is None or skill_name in bot["skills"]


def prompt(bot, others):
    if not bot:
        return ""
    head = f"[人格：{bot['name']}] 本会话由用户创建的 Bot“{bot['name']}”负责，记忆与其他 Bot 隔离（共享记忆仍可见）。"
    if bot.get("description"):
        head += f"\n简介：{bot['description']}"
    text = head + "\n" + bot["instructions"] + "\n\n"
    if bot.get("is_primary") and others:
        text += ("[主 Bot] 你是用户的主 Bot，负责分派：请求明显属于下列某个 Bot 的专长时，用 subagent_task 并传 persona 把任务转交给它，再整合答复；"
                 "否则自己完成。可用 Bot：" + "；".join(f"{b['persona_id']}（{b['name']}{'：' + b['description'] if b.get('description') else ''}）" for b in others[:20]) + "\n\n")
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
