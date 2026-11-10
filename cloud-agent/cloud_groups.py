"""群聊：用户和多个 Bot 在一个房间里聊天。

- 存储：groups / group_messages 两张表（SQLite）。
- 编排：每条用户消息决定哪些 Bot 回复（被 @ 的一定回复，其余按相关度 + 随机），错开时间、
  显示「正在输入」，回复简短；Bot 之间可以接话、点表情；每条用户消息的 Bot 发言数、每分钟 token、
  同时在想的 Bot 数都有上限（来自资源设置，群可覆盖活跃度）。
- 被 @ 且需要真正动手的事（[TASK]）交给服务端在该 Bot 自己的工作区跑一个任务，结果再贴回群里。

模型调用、Bot 资料、任务启动都通过 hooks 注入，方便测试。
"""
import json
import random
import re
import threading
import time
import uuid

import cloud_bots
from collections import deque

SCHEMA = [
    """CREATE TABLE IF NOT EXISTS groups (
        group_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        members TEXT NOT NULL,
        activity TEXT,
        created_at REAL,
        updated_at REAL
    )""",
    """CREATE TABLE IF NOT EXISTS group_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id TEXT NOT NULL,
        sender TEXT NOT NULL,
        kind TEXT NOT NULL,
        content TEXT,
        reply_to INTEGER,
        meta TEXT,
        timestamp REAL
    )""",
    "CREATE INDEX IF NOT EXISTS idx_group_messages ON group_messages(group_id, id)",
]

ACTIVITY = {
    # 被 @ 以外的 Bot 主动回复的基础概率、Bot 之间接话的概率、错开的延迟区间（秒）
    "quiet": {"base": 0.12, "chain": 0.10, "delay": (1.6, 4.0), "react": 0.15},
    "normal": {"base": 0.35, "chain": 0.25, "delay": (0.8, 2.6), "react": 0.30},
    "lively": {"base": 0.65, "chain": 0.45, "delay": (0.4, 1.6), "react": 0.45},
}
REACTIONS = ["👍", "😂", "❤️", "🎉", "🤔", "👀", "🙏", "💯", "😮"]
MAX_MEMBERS = 12
NAME_MAX = 40


class GroupError(ValueError):
    pass


# ---------------- 存储 ----------------

def ensure_schema(conn):
    for s in SCHEMA:
        conn.execute(s)
    conn.commit()


def _group_row(r):
    return {"group_id": r[0], "name": r[1], "members": json.loads(r[2] or "[]"), "activity": r[3],
            "created_at": r[4], "updated_at": r[5]}


def validate_fields(body, bot_exists, partial=False):
    if not isinstance(body, dict):
        raise GroupError("请求体必须是对象")
    out = {}
    if "name" in body or not partial:
        name = body.get("name")
        if not isinstance(name, str) or not name.strip() or len(name.strip()) > NAME_MAX:
            raise GroupError(f"群名必须是 1–{NAME_MAX} 个字符")
        out["name"] = name.strip()
    if "members" in body or not partial:
        m = body.get("members")
        if not isinstance(m, list) or not m or not all(isinstance(x, str) for x in m):
            raise GroupError("members 必须是至少一个 Bot ID 的数组（你自己总在群里，不用填）")
        seen = []
        for x in m:
            if x not in seen:
                seen.append(x)
        if len(seen) > MAX_MEMBERS:
            raise GroupError(f"一个群最多 {MAX_MEMBERS} 个 Bot")
        missing = [x for x in seen if not bot_exists(x)]
        if missing:
            raise GroupError("Bot 不存在：" + "、".join(missing))
        out["members"] = seen
    if "activity" in body:
        a = body.get("activity")
        if a not in (None, "", "quiet", "normal", "lively"):
            raise GroupError("activity 只能是 quiet、normal、lively 或留空（跟随全局设置）")
        out["activity"] = a or None
    return out


def create_group(conn, fields):
    gid = "grp_" + uuid.uuid4().hex[:10]
    now = time.time()
    conn.execute("INSERT INTO groups (group_id, name, members, activity, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                 (gid, fields["name"], json.dumps(fields["members"]), fields.get("activity"), now, now))
    conn.commit()
    return get_group(conn, gid)


def get_group(conn, gid):
    r = conn.execute("SELECT group_id, name, members, activity, created_at, updated_at FROM groups WHERE group_id = ?", (gid,)).fetchone()
    return _group_row(r) if r else None


def list_groups(conn):
    rows = conn.execute("SELECT group_id, name, members, activity, created_at, updated_at FROM groups ORDER BY updated_at DESC").fetchall()
    out = []
    for r in rows:
        g = _group_row(r)
        last = conn.execute("SELECT sender, kind, content, timestamp FROM group_messages WHERE group_id = ? AND kind != 'reaction' "
                            "ORDER BY id DESC LIMIT 1", (g["group_id"],)).fetchone()
        g["last_message"] = {"sender": last[0], "kind": last[1], "content": (last[2] or "")[:200], "timestamp": last[3]} if last else None
        out.append(g)
    return out


def update_group(conn, gid, fields):
    g = get_group(conn, gid)
    if not g:
        return None
    merged = {**g, **fields}
    conn.execute("UPDATE groups SET name = ?, members = ?, activity = ?, updated_at = ? WHERE group_id = ?",
                 (merged["name"], json.dumps(merged["members"]), merged.get("activity"), time.time(), gid))
    conn.commit()
    return get_group(conn, gid)


def delete_group(conn, gid):
    conn.execute("DELETE FROM group_messages WHERE group_id = ?", (gid,))
    cur = conn.execute("DELETE FROM groups WHERE group_id = ?", (gid,))
    conn.commit()
    return cur.rowcount > 0


def add_message(conn, gid, sender, kind, content, reply_to=None, meta=None):
    now = time.time()
    cur = conn.execute("INSERT INTO group_messages (group_id, sender, kind, content, reply_to, meta, timestamp) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       (gid, sender, kind, content, reply_to, json.dumps(meta, ensure_ascii=False) if meta else None, now))
    conn.execute("UPDATE groups SET updated_at = ? WHERE group_id = ?", (now, gid))
    conn.commit()
    return cur.lastrowid


def messages_after(conn, gid, after=0, limit=200):
    rows = conn.execute("SELECT id, sender, kind, content, reply_to, meta, timestamp FROM group_messages WHERE group_id = ? AND id > ? "
                        "ORDER BY id ASC LIMIT ?", (gid, after, limit)).fetchall()
    return [{"id": r[0], "sender": r[1], "kind": r[2], "content": r[3], "reply_to": r[4],
             "meta": json.loads(r[5]) if r[5] else None, "timestamp": r[6]} for r in rows]


def recent_messages(conn, gid, limit=30):
    rows = conn.execute("SELECT id, sender, kind, content, reply_to, meta, timestamp FROM group_messages WHERE group_id = ? "
                        "ORDER BY id DESC LIMIT ?", (gid, limit)).fetchall()
    return [{"id": r[0], "sender": r[1], "kind": r[2], "content": r[3], "reply_to": r[4],
             "meta": json.loads(r[5]) if r[5] else None, "timestamp": r[6]} for r in reversed(rows)]


# ---------------- 编排（纯函数） ----------------

_WORD_RE = re.compile(r"[A-Za-z0-9]{2,}|[\u4e00-\u9fff]")


def _terms(text):
    words = _WORD_RE.findall((text or "").lower())
    out = set(w for w in words if len(w) > 1)
    # 中文按相邻两字切分
    cjk = [w for w in words if len(w) == 1]
    out.update(a + b for a, b in zip(cjk, cjk[1:]))
    return out


def relevance(text, bot):
    """消息和 Bot 名称 / 简介 / 指令的词重合度，0–1。"""
    msg = _terms(text)
    if not msg:
        return 0.0
    profile = _terms(" ".join([bot.get("name") or "", bot.get("description") or "", (bot.get("instructions") or "")[:600]]))
    hit = len(msg & profile)
    return min(1.0, hit / max(3, len(msg) ** 0.5 * 2))


def mentioned(text, bots):
    """@名字 或 @id（不区分大小写）；@所有人 / @all 表示全部。"""
    if not isinstance(text, str) or "@" not in text:
        return []
    low = text.lower()
    if "@所有人" in text or "@all" in low or "@everyone" in low:
        return [b["persona_id"] for b in bots]
    out = []
    for b in sorted(bots, key=lambda b: -len(b.get("name") or "")):
        for token in (b.get("name") or "", b["persona_id"]):
            if token and ("@" + token.lower()) in low:
                if b["persona_id"] not in out:
                    out.append(b["persona_id"])
                break
    return out


def choose_responders(text, bots, activity, rng=random, exclude=(), recent=()):
    """返回 [(bot_id, reason)]：被 @ 的全部回复；没人被 @ 时至少一个 Bot 回复（相关度最高的）。"""
    a = ACTIVITY.get(activity, ACTIVITY["normal"])
    cands = [b for b in bots if b["persona_id"] not in exclude]
    ments = mentioned(text, cands)
    picked = [(bid, "mention") for bid in ments]
    others = [b for b in cands if b["persona_id"] not in ments]
    scored = sorted(((relevance(text, b), b) for b in others), key=lambda x: -x[0])
    for score, b in scored:
        # 刚说过话的 Bot 降一点概率，避免一个 Bot 刷屏
        p = a["base"] + 0.5 * score - (0.15 if b["persona_id"] in recent else 0)
        if rng.random() < max(0.0, min(0.95, p)):
            picked.append((b["persona_id"], "relevant" if score > 0.2 else "chime"))
    if not picked and scored and not ments:
        best = scored[0][1] if scored[0][0] > 0 else rng.choice([b for _, b in scored])
        picked.append((best["persona_id"], "default"))
    return picked


def estimate_tokens(text):
    if not text:
        return 0
    cjk = sum(1 for ch in text if "\u4e00" <= ch <= "\u9fff")
    return int(cjk * 1.0 + (len(text) - cjk) / 4) + 1


class TokenBudget:
    """每个群每分钟的 token 预算（估算）；limit=0 不限。"""

    def __init__(self):
        self.lock = threading.Lock()
        self.used = {}

    def _window(self, gid, now):
        q = self.used.setdefault(gid, deque())
        while q and now - q[0][0] > 60:
            q.popleft()
        return q

    def remaining(self, gid, limit, now=None):
        if not limit:
            return 10 ** 9
        now = time.time() if now is None else now
        with self.lock:
            return limit - sum(n for _, n in self._window(gid, now))

    def add(self, gid, n, now=None):
        now = time.time() if now is None else now
        with self.lock:
            self._window(gid, now).append((now, n))

    def reserve(self, gid, limit, n, now=None):
        """预算还有剩余时先记上预估用量并返回 True（并发的 Bot 不会一起超支）。"""
        now = time.time() if now is None else now
        with self.lock:
            q = self._window(gid, now)
            if limit and sum(x for _, x in q) >= limit:
                return False
            q.append((now, n))
            return True


REPLY_RULES = (
    "\n\n[群聊规则] 你在一个群聊里，成员有用户和其他 Bot（{others}）。像真人在群里聊天一样：\n"
    "- 回复要短，一般一两句话，不要长篇大论，不用 Markdown 标题。\n"
    "- 只说你自己专长的部分，别人已经说过的不要重复。\n"
    "- 没什么值得补充时只回 [PASS]；只想表个态可以只回 [REACT:表情]（例如 [REACT:👍]）。\n"
    "- 想请另一个 Bot 接话就在回复里 @它的名字。\n"
    "{task_rule}"
)
TASK_RULE = ("- 用户点名让你做需要动手的事（查网页、写文件、运行命令、做图表等）时，先回一句简短的确认，"
             "然后另起一行写 [TASK] 后接完整的任务说明；任务会在你自己的工作区完成，结果会自动发回群里。\n")


def build_prompt(bot, persona_text, group, history, members, me_reason):
    others = "、".join(f"{m.get('name')}（{m['persona_id']}）" for m in members if m["persona_id"] != bot["persona_id"]) or "无"
    sys_text = (persona_text or f"你是「{bot.get('name')}」。") + REPLY_RULES.format(
        others=others, task_rule=TASK_RULE if me_reason == "mention" else "")
    sys_text += cloud_bots.language_tail(bot)      # 灵魂设定的回复语言
    names = {m["persona_id"]: m.get("name") or m["persona_id"] for m in members}
    lines = []
    for h in history:
        if h["kind"] == "reaction":
            continue
        who = "用户" if h["sender"] == "user" else names.get(h["sender"], h["sender"])
        lines.append(f"{who}：{h['content']}")
    convo = "\n".join(lines[-30:])
    user_text = (f"群「{group['name']}」最近的聊天：\n{convo}\n\n"
                 f"现在轮到你（{bot.get('name')}）发言。直接写你要发的内容。")
    return [{"role": "system", "content": sys_text}, {"role": "user", "content": user_text}]


def parse_reply(text, name=None):
    """返回 dict(kind=pass|react|text, content, emoji, task)。"""
    t = (text or "").strip()
    # 模型有时会照着聊天记录的格式在开头写「名字：」
    for prefix in ([name + "：", name + ":"] if name else []):
        if t.startswith(prefix):
            t = t[len(prefix):].strip()
    if not t or t.upper().startswith("[PASS]"):
        return {"kind": "pass"}
    m = re.fullmatch(r"\[REACT:\s*(.{1,8}?)\s*\]", t)
    if m:
        return {"kind": "react", "emoji": m.group(1)}
    task = None
    if "[TASK]" in t:
        t, _, task = t.partition("[TASK]")
        t = t.strip()
        task = task.strip() or None
    if len(t) > 1200:
        t = t[:1200].rstrip() + "…"
    return {"kind": "text", "content": t or ("好的，我来处理。" if task else ""), "task": task}


# ---------------- 运行时 ----------------

class GroupEngine:
    """每个群一个「轮次」：用户发言触发，Bot 回复与互相接话都计入这一轮的发言上限。"""

    def __init__(self, hooks):
        # hooks: db() -> conn, settings() -> dict, bot(id) -> dict|None, persona_text(bot) -> str,
        #        llm(bot, messages, fallback) -> (text, tokens), start_task(group, bot, task, msg_id) -> None,
        #        rng (可选), sleep (可选)
        self.h = hooks
        self.rng = hooks.get("rng") or random.Random()
        self.sleep = hooks.get("sleep") or time.sleep
        self.cond = threading.Condition()
        self.typing = {}       # gid -> {bot_id: since}
        self.rounds = {}       # gid -> round id
        self.budget = TokenBudget()
        self.thinking = {}     # gid -> 正在想的 Bot 数

    # ---- 状态 / 长轮询 ----
    def notify(self):
        with self.cond:
            self.cond.notify_all()

    def typing_list(self, gid):
        with self.cond:
            return sorted(self.typing.get(gid, {}).keys())

    def wait_for(self, gid, after, timeout):
        """有新消息或输入状态变化时返回（长轮询）。"""
        deadline = time.time() + max(0.0, min(timeout, 25.0))
        last_typing = self.typing_list(gid)
        while True:
            conn = self.h["db"]()
            try:
                msgs = messages_after(conn, gid, after)
            finally:
                conn.close()
            typing = self.typing_list(gid)
            if msgs or typing != last_typing or time.time() >= deadline:
                return msgs, typing
            with self.cond:
                self.cond.wait(timeout=min(0.5, max(0.01, deadline - time.time())))

    def _set_typing(self, gid, bid, on):
        with self.cond:
            d = self.typing.setdefault(gid, {})
            if on:
                d[bid] = time.time()
            else:
                d.pop(bid, None)
            self.cond.notify_all()

    # ---- 轮次 ----
    def on_user_message(self, gid, msg_id, text, fallback):
        conn = self.h["db"]()
        try:
            group = get_group(conn, gid)
        finally:
            conn.close()
        if not group:
            return None
        rid = uuid.uuid4().hex[:8]
        with self.cond:
            self.rounds[gid] = rid       # 新的用户消息开启新一轮，旧一轮剩下的接话作废
        th = threading.Thread(target=self._run_round, args=(group, rid, msg_id, text, fallback), daemon=True, name="group-round")
        th.start()
        return th

    def _activity(self, group, s):
        return group.get("activity") or s.get("group_activity") or "normal"

    def _run_round(self, group, rid, msg_id, text, fallback):
        s = self.h["settings"]()
        gid = group["group_id"]
        members = [b for b in (self.h["bot"](m) for m in group["members"]) if b]
        if not members:
            return
        act = self._activity(group, s)
        a = ACTIVITY.get(act, ACTIVITY["normal"])
        state = {"turns": 0, "max": s.get("group_max_bot_turns", 6) or 10 ** 6, "lock": threading.Lock(), "spoke": []}
        sem_n = s.get("group_max_concurrent", 2) or 64
        sem = threading.Semaphore(sem_n)
        threads = []

        def schedule(bid, reason, trigger_id, trigger_text, delay):
            t = threading.Thread(target=self._reply, daemon=True, name="group-reply",
                                 args=(group, rid, members, bid, reason, trigger_id, trigger_text, delay, sem, state, fallback, a, schedule, s))
            threads.append(t)
            t.start()

        picked = choose_responders(text, members, act, self.rng)
        base = 0.0
        for i, (bid, reason) in enumerate(picked):
            lo, hi = a["delay"]
            base += self.rng.uniform(lo, hi) * (0.6 if reason == "mention" else 1.0) if i else self.rng.uniform(lo * 0.5, lo)
            schedule(bid, reason, msg_id, text, base)
        # 等这一轮所有回复（包括接话）结束
        while True:
            alive = [t for t in list(threads) if t.is_alive()]
            if not alive:
                break
            for t in alive:
                t.join(timeout=0.5)

    def _round_active(self, gid, rid):
        with self.cond:
            return self.rounds.get(gid) == rid

    def _reply(self, group, rid, members, bid, reason, trigger_id, trigger_text, delay, sem, state, fallback, a, schedule, s):
        gid = group["group_id"]
        self.sleep(delay)
        if not self._round_active(gid, rid):
            return
        with state["lock"]:
            if state["turns"] >= state["max"]:
                return
            state["turns"] += 1          # 先占名额，回 [PASS] 时再还回去
        bot = next((m for m in members if m["persona_id"] == bid), None)
        if not bot:
            return
        limit = s.get("group_tokens_per_min", 60000)
        with sem:
            if not self._round_active(gid, rid):
                return
            self._set_typing(gid, bid, True)
            try:
                conn = self.h["db"]()
                try:
                    history = recent_messages(conn, gid, 30)
                finally:
                    conn.close()
                msgs = build_prompt(bot, self.h["persona_text"](bot), group, history, members, reason)
                est = sum(estimate_tokens(m["content"]) for m in msgs) + 150
                if not self.budget.reserve(gid, limit, est):
                    with state["lock"]:
                        state["turns"] -= 1
                    return
                try:
                    out, tokens = self.h["llm"](bot, msgs, fallback)
                except Exception as e:  # 模型出错：群里提示一下，不影响其他 Bot
                    out, tokens = None, 0
                    conn = self.h["db"]()
                    try:
                        add_message(conn, gid, bid, "system", f"{bot.get('name')} 暂时回不了：{str(e)[:160]}")
                    finally:
                        conn.close()
                if tokens:
                    self.budget.add(gid, tokens - est)   # 用实际用量校正预估
                parsed = parse_reply(out, bot.get("name")) if out is not None else {"kind": "pass"}
                # 打字时间和长度相关，显得自然（上限 2.5 秒）
                if parsed["kind"] == "text":
                    self.sleep(min(2.5, 0.25 + len(parsed["content"]) / 60))
            finally:
                self._set_typing(gid, bid, False)
        if not self._round_active(gid, rid):
            return
        conn = self.h["db"]()
        try:
            if parsed["kind"] == "pass":
                with state["lock"]:
                    state["turns"] -= 1
                return
            if parsed["kind"] == "react":
                with state["lock"]:
                    state["turns"] -= 1          # 表情不算发言
                add_message(conn, gid, bid, "reaction", parsed["emoji"], reply_to=trigger_id)
                self.notify()
                return
            mid = add_message(conn, gid, bid, "text", parsed["content"], reply_to=trigger_id,
                              meta={"reason": reason, "model": bot.get("model") or ""})
        finally:
            conn.close()
        with state["lock"]:
            state["spoke"].append(bid)
        self.notify()
        if parsed.get("task") and reason == "mention":
            try:
                self.h["start_task"](group, bot, parsed["task"], mid)
            except Exception as e:
                conn = self.h["db"]()
                try:
                    add_message(conn, gid, bid, "system", f"{bot.get('name')} 的任务没能开始：{str(e)[:160]}")
                finally:
                    conn.close()
                self.notify()
        # 其他 Bot 接话：被这条回复 @ 的必接，其余按活跃度随机；也可能只点个表情
        others = [m for m in members if m["persona_id"] != bid]
        chained = mentioned(parsed["content"], others)
        for m in others:
            mid_bid = m["persona_id"]
            if mid_bid in chained:
                schedule(mid_bid, "mention", mid, parsed["content"], self.rng.uniform(*a["delay"]))
            elif self.rng.random() < a["chain"] * (0.6 if mid_bid in state["spoke"] else 1.0):
                schedule(mid_bid, "chain", mid, parsed["content"], self.rng.uniform(*a["delay"]) * 1.5)
            elif self.rng.random() < a["react"]:
                emoji = self.rng.choice(REACTIONS)
                conn = self.h["db"]()
                try:
                    add_message(conn, gid, mid_bid, "reaction", emoji, reply_to=mid)
                finally:
                    conn.close()
                self.notify()
