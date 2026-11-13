# -*- coding: utf-8 -*-
"""Grok Bot 式的对话行为：表情回应、选项卡片、引用回复、里程碑、分层记忆、回复风格。

都是纯数据层（SQLite + 校验 + 提示文字），服务器负责把它们接进工具和 HTTP。
"""

import json
import re
import time

REACTION_MAX = 8                       # 一个表情（含肤色 / 组合字符）最多 8 个码位
CHOICE_MAX_OPTIONS = 8
MILESTONE_MAX = 3                      # 每个后台任务最多往聊天里发 3 条里程碑
PROFILE_MAX_CHARS = 1500               # 常驻上下文的档案：每层最多这么多字
END_TURN_TOOLS = {"ask_choice"}        # 调用后这一轮就结束（等用户点选）
ANSWER_TOOLS = {"react", "ask_choice"}  # 只回应一个表情 / 一张卡片也算回答了


class RunModelError(ValueError):
    pass


def ensure_schema(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS message_reactions (message_id INTEGER NOT NULL, session_id TEXT NOT NULL, "
                 "actor TEXT NOT NULL, emoji TEXT NOT NULL, at REAL NOT NULL, PRIMARY KEY (message_id, actor))")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_reactions_session ON message_reactions(session_id)")
    conn.commit()


# ---------- 表情回应 ----------
def _emoji_ok(e):
    if not isinstance(e, str) or not e.strip() or len(e.strip()) > REACTION_MAX:
        return False
    return not re.search(r"[A-Za-z0-9\s<>\"'`]", e.strip())


def set_reaction(conn, session_id, message_id, actor, emoji):
    """actor 是 bot 或 user；emoji 为空表示取消。返回这条消息现在的回应。"""
    if actor not in ("bot", "user"):
        raise RunModelError("actor 只能是 bot 或 user")
    row = conn.execute("SELECT role FROM messages WHERE id = ? AND session_id = ?", (message_id, session_id)).fetchone()
    if not row or row[0] not in ("user", "assistant"):
        raise RunModelError("没有这条消息")
    if actor == "bot" and row[0] != "user":
        raise RunModelError("Bot 只能回应用户的消息")
    if actor == "user" and row[0] != "assistant":
        raise RunModelError("只能回应 Bot 的消息")
    if emoji in (None, ""):
        conn.execute("DELETE FROM message_reactions WHERE message_id = ? AND actor = ?", (message_id, actor))
    else:
        if not _emoji_ok(emoji):
            raise RunModelError("emoji 必须是一个表情")
        conn.execute("INSERT OR REPLACE INTO message_reactions (message_id, session_id, actor, emoji, at) VALUES (?, ?, ?, ?, ?)",
                     (message_id, session_id, actor, emoji.strip(), time.time()))
    conn.commit()
    return reactions_of(conn, message_id)


def reactions_of(conn, message_id):
    return [{"actor": a, "emoji": e} for a, e in conn.execute(
        "SELECT actor, emoji FROM message_reactions WHERE message_id = ? ORDER BY at", (message_id,)).fetchall()]


def reactions_for(conn, session_id):
    out = {}
    for mid, a, e in conn.execute("SELECT message_id, actor, emoji FROM message_reactions WHERE session_id = ? ORDER BY at", (session_id,)):
        out.setdefault(mid, []).append({"actor": a, "emoji": e})
    return out


def last_user_message_id(conn, session_id):
    r = conn.execute("SELECT MAX(id) FROM messages WHERE session_id = ? AND role = 'user'", (session_id,)).fetchone()
    return r[0] if r else None


# ---------- 选项卡片 ----------
def validate_choice(args):
    if not isinstance(args, dict):
        raise RunModelError("参数必须是对象")
    q = args.get("question")
    if not isinstance(q, str) or not q.strip() or len(q) > 300:
        raise RunModelError("question 必须是 1-300 字")
    opts = args.get("options")
    if not isinstance(opts, list) or not (2 <= len(opts) <= CHOICE_MAX_OPTIONS):
        raise RunModelError(f"options 需要 2-{CHOICE_MAX_OPTIONS} 个")
    out, seen = [], set()
    for i, o in enumerate(opts):
        if isinstance(o, str):
            o = {"label": o}
        if not isinstance(o, dict) or not isinstance(o.get("label"), str) or not o["label"].strip() or len(o["label"]) > 80:
            raise RunModelError("每个选项需要 1-80 字的 label")
        label = o["label"].strip()
        if label in seen:
            raise RunModelError("选项重复：" + label)
        seen.add(label)
        item = {"id": str(i + 1), "label": label}
        if isinstance(o.get("detail"), str) and o["detail"].strip():
            item["detail"] = o["detail"].strip()[:160]
        out.append(item)
    return {"question": q.strip(), "options": out, "multi": bool(args.get("multi")),
            "allow_custom": args.get("allow_custom", True) is not False}


def choice_answer_text(choice, selected, custom, dismissed):
    """用户在卡片上的选择 → 发给 Bot 的那条消息（App 也可以自己拼，服务器以这里为准）。"""
    if dismissed:
        return "（我先不选，跳过这个问题）"
    labels = {o["id"]: o["label"] for o in choice["options"]}
    picked = [labels[s] for s in selected or [] if s in labels]
    if not choice.get("multi"):
        picked = picked[:1]
    parts = list(picked)
    if custom and choice.get("allow_custom"):
        parts.append(custom.strip()[:500])
    if not parts:
        raise RunModelError("至少选一个，或者写自定义答案")
    return "我选：" + "；".join(parts)


def mark_choice(conn, session_id, message_id, selected, custom, dismissed):
    row = conn.execute("SELECT meta FROM messages WHERE id = ? AND session_id = ? AND role = 'assistant'", (message_id, session_id)).fetchone()
    meta = json.loads(row[0]) if row and row[0] else {}
    choice = meta.get("choice")
    if not choice:
        raise RunModelError("这条消息不是选项卡片")
    if choice.get("answer"):
        raise RunModelError("已经选过了")
    text = choice_answer_text(choice, selected, custom, dismissed)
    choice["answer"] = {"selected": [s for s in selected or [] if isinstance(s, str)], "custom": custom or None,
                        "dismissed": bool(dismissed), "at": time.time()}
    conn.execute("UPDATE messages SET meta = ? WHERE id = ?", (json.dumps(meta, ensure_ascii=False), message_id))
    conn.commit()
    return text


# ---------- 引用回复 ----------
def reply_ref(conn, session_id, message_id):
    if not isinstance(message_id, int) or isinstance(message_id, bool):
        raise RunModelError("reply_to 必须是消息 id")
    r = conn.execute("SELECT role, content FROM messages WHERE id = ? AND session_id = ? AND role IN ('user', 'assistant')",
                     (message_id, session_id)).fetchone()
    if not r or not r[1]:
        raise RunModelError("要回复的消息不存在")
    return {"id": message_id, "role": r[0], "excerpt": " ".join(str(r[1]).split())[:140]}


def model_content(role, content, meta):
    """给模型看的内容：引用回复的消息前面带上被引用的那句。"""
    if role != "user" or not meta or not isinstance(content, str):
        return content
    try:
        m = json.loads(meta) if isinstance(meta, str) else meta
    except ValueError:
        return content
    ref = (m or {}).get("reply_to")
    if not ref:
        return content
    who = "你之前说" if ref.get("role") == "assistant" else "我之前说"
    return f"> 回复（{who}）：{ref.get('excerpt', '')}\n\n{content}"


def public_meta(meta):
    """消息列表里给 App 的字段。"""
    keep = ("worker_id", "worker_status", "choice", "reply_to", "milestone", "page", "teammate", "beats",
            "reminder_draft", "shortcut_draft", "deliverables", "delegation_id")
    return {k: meta[k] for k in keep if k in meta}


# ---------- 回复风格 / 分段 ----------
REPLY_STYLE_NOTE = (
    "\n\n[回复风格] 先给答案再解释；简洁，不说客套话和「好的，我来…」之类的填充；链接用 Markdown [文字](网址)。"
    "要用户做选择时用 ask_choice 给选项卡片，不要在文字里列 A/B/C 让用户打字。只需要表示收到 / 赞同 / 感谢时可以只用 react 回一个表情，不用再写字。"
    "内容超过一屏的报告、表格、看板用 page_write 存成页面，聊天里只放一句结论。"
    "一条回复里有两三个独立的意思时，用单独一行 --- 分开，手机会拆成几个气泡。"
    "回复会超过 3 行时，第一行写「一句话：」加一句结论（数字、要做的动作），再空一行写细节；手机会把细节折叠起来。"
    "涉及医学（剂量、诊断、处理、指南）时，最后单独一行写「依据：指南 / 说明书 / 文献名（能给链接就给）｜把握度：高 / 中 / 低」；"
    "说不出具体出处就写「依据：无明确出处｜把握度：低」，不要编造指南名、条款或文献。")

SOURCE_PREFIX = "依据："


def source_line(text):
    """取回复里的「依据：…｜把握度：…」行 → (依据, 把握度)；没有返回 None。手机端 CloudSourceLine 同口径。"""
    for line in reversed((text or "").splitlines()):
        t = line.strip()
        if t.startswith(SOURCE_PREFIX):
            body = t[len(SOURCE_PREFIX):]
            src, _, conf = body.partition("｜把握度：")
            return src.strip(), (conf.strip() or None)
    return None

ONE_LINE_PREFIX = "一句话："


def split_one_line(text):
    """回复以「一句话：」开头时拆成 (结论, 细节)；不是这种格式返回 (None, text)。手机端同口径（CloudOneLine）。"""
    t = (text or "").lstrip()
    if not t.startswith(ONE_LINE_PREFIX):
        return None, text
    first, _, rest = t.partition("\n")
    head = first[len(ONE_LINE_PREFIX):].strip()
    return (head or None), rest.strip()

BEAT_SPLIT = re.compile(r"\n\s*---\s*\n")


def split_beats(text, limit=3):
    """按单独一行的 --- 拆成最多 limit 个气泡；代码块里的 --- 不拆。"""
    if not isinstance(text, str) or "---" not in text or "```" in text:
        return None
    parts = [p.strip() for p in BEAT_SPLIT.split(text) if p.strip()]
    if len(parts) < 2:
        return None
    if len(parts) > limit:
        parts = parts[:limit - 1] + ["\n\n".join(parts[limit - 1:])]
    return parts


# ---------- 分层记忆 ----------
def profile_block(conn, bot_id, bot_name=None):
    """常驻上下文：这个 Bot 自己的档案（category=profile/rules 且 persona=bot）+ 所有 Bot 共用的用户档案（persona 为空的 profile）。
    较早的日记条目（note / workstreams / people）不放进来，用 memory_search 查。"""
    def take(rows):
        out, total = [], 0
        for (c,) in rows:
            c = " ".join(str(c).split())
            if total + len(c) > PROFILE_MAX_CHARS:
                break
            out.append("- " + c)
            total += len(c)
        return out
    shared = take(conn.execute("SELECT content FROM memory_entries WHERE COALESCE(persona, '') = '' AND category = 'profile' "
                               "ORDER BY entry_time DESC LIMIT 30").fetchall())
    own = take(conn.execute("SELECT content FROM memory_entries WHERE persona = ? AND category IN ('profile', 'rules') "
                            "ORDER BY entry_time DESC LIMIT 30", (bot_id,)).fetchall()) if bot_id else []
    if not shared and not own:
        return ""
    text = "\n\n[记忆]"
    if shared:
        text += "\n用户档案（所有 Bot 共用）：\n" + "\n".join(shared)
    if own:
        text += f"\n{bot_name or '你'}自己的档案：\n" + "\n".join(own)
    return text


MEMORY_NOTE = (
    "\n\n[记忆习惯] 用户提到值得长期记住的事实（偏好、身份、人物、约定）时，直接用 memory_write 记下，不用问；"
    "回复里顺带一句「记下了」即可。scope=shared 写进所有 Bot 共用的用户档案，默认只记在你自己的档案 / 日记里。"
    "更早的事用 memory_search 查。\n[技能] 完成了一套以后可能重复的多步流程（比如某网站的下单步骤），用 skill_save 存成技能；"
    "遇到类似任务先 skill_load。\n[例行任务] 用户的请求是周期性的（每天 / 每周 / 到点提醒 / 有变化告诉我）时，主动用 routine_create 建一个，"
    "建之前用一句话说明时间。监控类（「X 有变化时告诉我」）的例行任务在没有变化时只回复 [SKIP]，不要发「无变化」。")


# ---------- 附件与长时间等待的规矩（所有 Bot） ----------

ATTACHMENT_NOTE = (
    "\n\n【附件与等待】用户发来的图片已经作为图片直接给你看了（看不了时系统会先转成文字给你），"
    "不要为了读图片 / 附件去安装 OCR、pip / apt 装包或下载模型；已有内置能力就直接用。"
    "安装、等待、重试这类步骤累计超过约 60 秒还没有进展，就停下来如实告诉用户卡在哪里，不要反复换源重试。"
    "说「完成了」之前先核对结果（看输出、读文件或截图），没核对过就说明还没确认。")

_INSTALL_RE = re.compile(
    r"\b(pip3?|python3? -m pip|apt(-get)?|yum|dnf|apk|brew|npm|pnpm|yarn|conda|cargo)\b[^|;&\n]{0,40}\b(install|add)\b"
    r"|\bsleep\s+\d|\btimeout\s+\d|\bwhile\b.*\bsleep\b|\bwget\b|\bcurl\b[^|;&\n]*\b(-o|-O|--output)\b|tesseract|easyocr|paddleocr",
    re.I)


class LoopGuard:
    """一次任务里的「安装 / 等待 / 重试」预算：这类命令累计超过 budget 秒，或同一步原样重复 repeat 次，就不再执行，
    改为返回提示让模型停下来向用户说明。"""

    def __init__(self, budget=60.0, max_calls=4, repeat=3):
        self.budget, self.max_calls, self.repeat = budget, max_calls, repeat
        self.spent = 0.0
        self.calls = 0
        self.last_key = None
        self.same = 0

    @staticmethod
    def is_install_or_wait(name, args):
        return name == "shell_execute" and bool(_INSTALL_RE.search(str((args or {}).get("command") or "")))

    def check(self, name, args):
        """执行前调用：返回 None 表示放行，否则返回给模型的工具结果。"""
        key = name + ":" + json.dumps(args or {}, sort_keys=True, ensure_ascii=False)[:500]
        self.same = self.same + 1 if key == self.last_key else 1
        self.last_key = key
        if self.same >= self.repeat:
            return {"error": "同一步已经原样重复了好几次，没有进展。停止重试，向用户说明卡在哪里、需要什么。", "blocked": "repeat"}
        if self.is_install_or_wait(name, args):
            if self.spent >= self.budget or self.calls >= self.max_calls:
                return {"error": f"安装 / 等待类步骤已用掉约 {int(self.spent)} 秒（{self.calls} 次），按规定停止。"
                                 "现在直接告诉用户情况和下一步建议，不要再换源或重试。", "blocked": "install_budget"}
            self.calls += 1
        return None

    def spend(self, name, args, duration_ms):
        if self.is_install_or_wait(name, args) and duration_ms:
            self.spent += duration_ms / 1000.0
