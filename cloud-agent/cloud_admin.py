# -*- coding: utf-8 -*-
"""主 Bot 的管理工具：新建 / 修改 / 删除（进回收站）/ 恢复 / 设为主 Bot。

只有主 Bot（personas.is_primary = 1）的顶层任务能用，服务器在出工具清单和执行时各查一次。
每次改动都写进审计日志，并附带撤销信息（kind = "bot"）：新建可撤销成删除、修改可撤销回旧设置、
删除可撤销成恢复。删除不清记忆、不删会话：整行和例行任务的归属先放进 bot_trash，恢复时原样放回。
"""

import json
import re
import time
import uuid

import cloud_bots

TRASH_KEEP_DAYS = 30
SETTING_KEYS = ("name", "instructions", "emoji", "description", "model", "credential", "skills", "plugins",
                "reasoning_effort", "fast_mode", "soul")


class AdminError(ValueError):
    pass


def ensure_schema(conn):
    # 首页长按菜单：置顶 / 隐藏 / 手动标为未读，以及「已读到」的时间（换手机也一致）
    conn.execute("CREATE TABLE IF NOT EXISTS bot_prefs (bot_id TEXT PRIMARY KEY, pinned INTEGER NOT NULL DEFAULT 0, "
                 "hidden INTEGER NOT NULL DEFAULT 0, unread INTEGER NOT NULL DEFAULT 0, seen_at REAL NOT NULL DEFAULT 0, pinned_at REAL)")
    cols = {r[1] for r in conn.execute("PRAGMA table_info(bot_prefs)")}
    if "section_id" not in cols:
        conn.execute("ALTER TABLE bot_prefs ADD COLUMN section_id TEXT")
    # 首页分组（可折叠的小节）
    conn.execute("CREATE TABLE IF NOT EXISTS bot_sections (section_id TEXT PRIMARY KEY, name TEXT NOT NULL, "
                 "collapsed INTEGER NOT NULL DEFAULT 0, position REAL NOT NULL, created_at REAL NOT NULL)")
    conn.execute("CREATE TABLE IF NOT EXISTS bot_trash (bot_id TEXT PRIMARY KEY, bot TEXT NOT NULL, routines TEXT, "
                 "deleted_by TEXT, deleted_at REAL NOT NULL)")
    conn.commit()


def _slug(name):
    s = re.sub(r"[^a-z0-9_-]+", "-", (name or "").lower()).strip("-_")[:24]
    return s if s and cloud_bots.BOT_ID_RE.match(s) else ""


def new_bot_id(conn, name):
    base = _slug(name) or "bot"
    for i in range(50):
        cand = base if i == 0 and base != "bot" else f"{base[:24]}-{uuid.uuid4().hex[:4]}"
        if not cloud_bots.get(conn, cand) and not conn.execute("SELECT 1 FROM bot_trash WHERE bot_id = ?", (cand,)).fetchone():
            return cand
    raise AdminError("没法生成新的 Bot id")


def settings_body(bot):
    body = {k: bot.get(k) for k in SETTING_KEYS}
    body["fast_mode"] = bool(body.get("fast_mode"))
    body["description"] = body.get("description") or None
    return body


def create(conn, args, credential_exists=None):
    body = {k: args[k] for k in SETTING_KEYS if k in args}
    if not body.get("instructions"):
        body["instructions"] = args.get("system_prompt") or f"你是「{args.get('name') or 'Bot'}」。" + (args.get("description") or "")
    bot_id = args.get("bot_id") or new_bot_id(conn, args.get("name"))
    if cloud_bots.get(conn, bot_id):
        raise AdminError(f"已经有 id 为 {bot_id} 的 Bot")
    try:
        bot, _ = cloud_bots.upsert(conn, bot_id, body, credential_exists)
    except cloud_bots.BotError as e:
        raise AdminError(str(e))
    return bot


def update(conn, bot_id, args, credential_exists=None):
    cur = cloud_bots.get(conn, bot_id)
    if not cur:
        raise AdminError("没有这个 Bot")
    before = settings_body(cur)
    body = {k: args[k] for k in SETTING_KEYS if k in args}
    if "system_prompt" in args and "instructions" not in body:
        body["instructions"] = args["system_prompt"]
    if not body:
        raise AdminError("没有要改的设置")
    try:
        bot, _ = cloud_bots.upsert(conn, bot_id, body, credential_exists)
    except cloud_bots.BotError as e:
        raise AdminError(str(e))
    return bot, before


def delete(conn, bot_id, actor_id=None):
    """放进回收站。主 Bot 不能删（先把别的 Bot 设为主 Bot）。"""
    cur = cloud_bots.get(conn, bot_id)
    if not cur:
        raise AdminError("没有这个 Bot")
    if cur.get("is_primary") or bot_id == actor_id:
        raise AdminError("主 Bot 不能删除自己；要删请先把别的 Bot 设为主 Bot")
    routines = [r[0] for r in conn.execute("SELECT routine_id FROM routines WHERE persona_id = ? AND enabled = 1", (bot_id,))]
    conn.execute("INSERT OR REPLACE INTO bot_trash (bot_id, bot, routines, deleted_by, deleted_at) VALUES (?, ?, ?, ?, ?)",
                 (bot_id, json.dumps(cur, ensure_ascii=False), json.dumps(routines), actor_id, time.time()))
    conn.execute("UPDATE routines SET enabled = 0 WHERE persona_id = ?", (bot_id,))
    conn.execute("DELETE FROM personas WHERE persona_id = ?", (bot_id,))
    conn.commit()
    return cur


def trash(conn):
    cutoff = time.time() - TRASH_KEEP_DAYS * 86400
    conn.execute("DELETE FROM bot_trash WHERE deleted_at < ?", (cutoff,))
    conn.commit()
    out = []
    for bid, bot, at in conn.execute("SELECT bot_id, bot, deleted_at FROM bot_trash ORDER BY deleted_at DESC"):
        b = json.loads(bot)
        out.append({"bot_id": bid, "name": b.get("name"), "emoji": b.get("emoji"), "deleted_at": at})
    return out


def restore(conn, bot_id, credential_exists=None):
    r = conn.execute("SELECT bot, routines FROM bot_trash WHERE bot_id = ?", (bot_id,)).fetchone()
    if not r:
        raise AdminError("回收站里没有这个 Bot")
    if cloud_bots.get(conn, bot_id):
        raise AdminError("已经有同 id 的 Bot")
    bot = json.loads(r[0])
    body = settings_body(bot)
    if body.get("credential") and credential_exists and not credential_exists(body["credential"]):
        body["credential"], body["model"] = None, None
    try:
        restored, _ = cloud_bots.upsert(conn, bot_id, body, credential_exists)
    except cloud_bots.BotError as e:
        raise AdminError(str(e))
    for rid in json.loads(r[1] or "[]"):
        conn.execute("UPDATE routines SET enabled = 1 WHERE routine_id = ? AND persona_id = ?", (rid, bot_id))
    conn.execute("DELETE FROM bot_trash WHERE bot_id = ?", (bot_id,))
    conn.commit()
    return restored


def set_primary(conn, bot_id):
    """换主 Bot：一次事务里清掉旧主 Bot 的标记、给新主 Bot 打上。管理权限只看「当前主 Bot 是谁」，所以随之转移。"""
    if not cloud_bots.get(conn, bot_id):
        raise AdminError("没有这个 Bot")
    prev = cloud_bots.primary(conn)
    with conn:
        conn.execute("UPDATE personas SET is_primary = CASE WHEN persona_id = ? THEN 1 ELSE 0 END, updated_at = ? "
                     "WHERE is_primary = 1 OR persona_id = ?", (bot_id, time.time(), bot_id))
        conn.execute("UPDATE bot_prefs SET hidden = 0 WHERE bot_id = ?", (bot_id,))
    return prev["bot_id"] if prev else None


def undo(conn, info, credential_exists=None):
    """审计日志里 kind = "bot" 的撤销。返回 (ok, 说明)。"""
    op, bid = info.get("op"), info.get("bot_id")
    try:
        if op == "create":
            delete(conn, bid)
            return True, "已把新建的 Bot 移进回收站"
        if op == "update":
            cloud_bots.upsert(conn, bid, info.get("before") or {}, credential_exists)
            return True, "已恢复修改前的设置"
        if op == "delete":
            restore(conn, bid, credential_exists)
            return True, "已从回收站恢复"
        if op == "set_primary" and info.get("previous"):
            set_primary(conn, info["previous"])
            return True, "已改回原来的主 Bot"
    except (AdminError, cloud_bots.BotError) as e:
        return False, str(e)
    return False, "这条操作不能撤销"


PREF_KEYS = ("pinned", "hidden", "unread", "seen_at", "section_id")


def prefs(conn, bot_id):
    r = conn.execute("SELECT pinned, hidden, unread, seen_at, pinned_at, section_id FROM bot_prefs WHERE bot_id = ?", (bot_id,)).fetchone()
    if not r:
        return {"pinned": False, "hidden": False, "unread": False, "seen_at": 0.0, "pinned_at": None, "section_id": None}
    return {"pinned": bool(r[0]), "hidden": bool(r[1]), "unread": bool(r[2]), "seen_at": r[3] or 0.0, "pinned_at": r[4],
            "section_id": r[5]}


def set_prefs(conn, bot_id, body):
    if not cloud_bots.get(conn, bot_id):
        raise AdminError("没有这个 Bot")
    if not isinstance(body, dict) or not any(k in body for k in PREF_KEYS):
        raise AdminError("没有要改的项（pinned / hidden / unread / seen_at）")
    cur = prefs(conn, bot_id)
    for k in ("pinned", "hidden", "unread"):
        if k in body:
            if not isinstance(body[k], bool):
                raise AdminError(f"{k} 必须是 true / false")
            if k == "pinned" and body[k] and not cur["pinned"]:
                cur["pinned_at"] = time.time()
            cur[k] = body[k]
    if "seen_at" in body:
        if not isinstance(body["seen_at"], (int, float)):
            raise AdminError("seen_at 必须是时间戳")
        cur["seen_at"] = max(cur["seen_at"], float(body["seen_at"]))
    if "section_id" in body:
        sid = body["section_id"]
        if sid is not None and not conn.execute("SELECT 1 FROM bot_sections WHERE section_id = ?", (sid,)).fetchone():
            raise AdminError("没有这个分组")
        cur["section_id"] = sid
    conn.execute("INSERT OR REPLACE INTO bot_prefs (bot_id, pinned, hidden, unread, seen_at, pinned_at, section_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
                 (bot_id, int(cur["pinned"]), int(cur["hidden"]), int(cur["unread"]), cur["seen_at"], cur["pinned_at"], cur["section_id"]))
    conn.commit()
    return prefs(conn, bot_id)


def sections(conn):
    rows = conn.execute("SELECT section_id, name, collapsed, position FROM bot_sections ORDER BY position, created_at").fetchall()
    return [{"section_id": r[0], "name": r[1], "collapsed": bool(r[2]), "position": r[3],
             "bots": [b[0] for b in conn.execute("SELECT bot_id FROM bot_prefs WHERE section_id = ?", (r[0],))]} for r in rows]


def _section_name(v):
    if not isinstance(v, str) or not v.strip() or len(v.strip()) > 40:
        raise AdminError("分组名 1–40 个字")
    return v.strip()


def create_section(conn, name, bot_id=None):
    sid = "sec_" + uuid.uuid4().hex[:10]
    pos = (conn.execute("SELECT MAX(position) FROM bot_sections").fetchone()[0] or 0) + 1
    conn.execute("INSERT INTO bot_sections (section_id, name, collapsed, position, created_at) VALUES (?, ?, 0, ?, ?)",
                 (sid, _section_name(name), pos, time.time()))
    conn.commit()
    if bot_id:
        set_prefs(conn, bot_id, {"section_id": sid})
    return next(x for x in sections(conn) if x["section_id"] == sid)


def update_section(conn, sid, body):
    if not conn.execute("SELECT 1 FROM bot_sections WHERE section_id = ?", (sid,)).fetchone():
        raise AdminError("没有这个分组")
    if "name" in body:
        conn.execute("UPDATE bot_sections SET name = ? WHERE section_id = ?", (_section_name(body["name"]), sid))
    if "collapsed" in body:
        if not isinstance(body["collapsed"], bool):
            raise AdminError("collapsed 必须是 true / false")
        conn.execute("UPDATE bot_sections SET collapsed = ? WHERE section_id = ?", (int(body["collapsed"]), sid))
    conn.commit()
    return next(x for x in sections(conn) if x["section_id"] == sid)


def delete_section(conn, sid):
    """删除分组：里面的 Bot 回到未分组，不删 Bot。"""
    if not conn.execute("SELECT 1 FROM bot_sections WHERE section_id = ?", (sid,)).fetchone():
        raise AdminError("没有这个分组")
    conn.execute("UPDATE bot_prefs SET section_id = NULL WHERE section_id = ?", (sid,))
    conn.execute("DELETE FROM bot_sections WHERE section_id = ?", (sid,))
    conn.commit()
