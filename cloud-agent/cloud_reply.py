# -*- coding: utf-8 -*-
"""回复方式（2.50.0）：「秒回」= 前台 + 后台；「详细」= 原来的实时步骤。

秒回：前台用快模型（Bot 的 front_model，没填用资源设置的 fast_model，再没有就用主模型）马上回一句，
前台只拿到派活 / 查进度 / 转话 / 停止这几样工具，真正干活的工具一律交给后台 worker（Bot 的 back_model，没填用主模型）。
worker 跑的时候用户的新消息照常进前台：前台立刻回话，需要时用 task_message 把话转给 worker。
worker 的每一步不往聊天里刷，只汇总成底部状态行的一句短语（status_phrase），加上用时和（有真实历史数据时）预计剩余。

每个 Bot 一个默认（bot_reply 表），每个对话可以单独覆盖（session_reply 表）。不设置 = 秒回。
"""

import os
import re
import statistics
import time

MODES = ("instant", "verbose")
DEFAULT_MODE = "instant"
MODEL_RE = re.compile(r"^[A-Za-z0-9_./:@+-]{1,128}$")

# 前台在秒回模式下能用的工具：派活、查进度、转话、停止、继续，外加表情 / 选项卡 / 记忆这类不耗时的
FRONT_TOOLS = frozenset({"spawn_task", "task_status", "task_message", "task_stop", "task_resume",
                         "react", "ask_choice", "memory_search", "memory_write", "recall_snapshot"})

FRONT_INSTANT_NOTE = (
    "\n\n[秒回 · 前台] 你是前台：用户发来的每条消息，先在一两句话里马上回应（直接答案、确认、或者追问），语气自然。"
    "你自己不做多步操作，也没有命令行、浏览器、文件等工具。凡是需要查资料、跑命令、改文件、上网、超过几秒的事，"
    "先写一句简短回应（比如「好，我让后台去查，做完告诉你」），再在同一条回复里调用 spawn_task 把目标和需要的背景交给后台。"
    "后台正在做事时用户又发来消息：先直接回答他；如果是对进行中任务的补充或修改，用 task_message 转给后台；要停就 task_stop；"
    "问进度就看下面的任务摘要或 task_status，用一句话告诉他。不要复述后台的每一步。")

ETA_MIN_SAMPLES = 3


class ReplyError(ValueError):
    pass


def ensure_schema(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS bot_reply (bot_id TEXT PRIMARY KEY, mode TEXT, front_model TEXT, back_model TEXT, "
                 "updated_at REAL NOT NULL)")
    conn.execute("CREATE TABLE IF NOT EXISTS session_reply (session_id TEXT PRIMARY KEY, mode TEXT NOT NULL, updated_at REAL NOT NULL)")
    conn.commit()


def _key(bot_id):
    return bot_id or "_default"


def default_mode():
    """没设置过时的回复方式：秒回。OPENMINIS_REPLY_DEFAULT 只给测试用（老测试按「详细」跑）。"""
    v = os.environ.get("OPENMINIS_REPLY_DEFAULT", "")
    return v if v in MODES else DEFAULT_MODE


def bot_settings(conn, bot_id):
    r = conn.execute("SELECT mode, front_model, back_model FROM bot_reply WHERE bot_id = ?", (_key(bot_id),)).fetchone()
    return {"mode": (r[0] if r and r[0] in MODES else default_mode()),
            "front_model": (r[1] if r else None) or None, "back_model": (r[2] if r else None) or None}


def _clean_model(v, field):
    if v in (None, ""):
        return None
    if not isinstance(v, str) or not MODEL_RE.match(v.strip()):
        raise ReplyError(f"{field} 不是有效的模型名")
    return v.strip()


def set_bot_settings(conn, bot_id, body):
    """PUT /v1/bots/<id>/reply {mode?, front_model?, back_model?}：没带的字段不变，空字符串 = 清空（跟随默认）。"""
    if not isinstance(body, dict):
        raise ReplyError("请求体必须是对象")
    cur = bot_settings(conn, bot_id)
    if "mode" in body:
        if body["mode"] not in MODES:
            raise ReplyError("mode 只能是 instant（秒回）或 verbose（详细）")
        cur["mode"] = body["mode"]
    for f in ("front_model", "back_model"):
        if f in body:
            cur[f] = _clean_model(body[f], f)
    conn.execute("INSERT INTO bot_reply (bot_id, mode, front_model, back_model, updated_at) VALUES (?, ?, ?, ?, ?) "
                 "ON CONFLICT(bot_id) DO UPDATE SET mode = excluded.mode, front_model = excluded.front_model, "
                 "back_model = excluded.back_model, updated_at = excluded.updated_at",
                 (_key(bot_id), cur["mode"], cur["front_model"], cur["back_model"], time.time()))
    conn.commit()
    return cur


def session_override(conn, session_id):
    r = conn.execute("SELECT mode FROM session_reply WHERE session_id = ?", (session_id,)).fetchone()
    return r[0] if r and r[0] in MODES else None


def set_session_override(conn, session_id, mode):
    """PUT /v1/sessions/<sid>/reply {mode: instant|verbose|null}：null = 跟随 Bot 设置。"""
    if mode in (None, "", "bot"):
        conn.execute("DELETE FROM session_reply WHERE session_id = ?", (session_id,))
    elif mode in MODES:
        conn.execute("INSERT INTO session_reply (session_id, mode, updated_at) VALUES (?, ?, ?) "
                     "ON CONFLICT(session_id) DO UPDATE SET mode = excluded.mode, updated_at = excluded.updated_at",
                     (session_id, mode, time.time()))
    else:
        raise ReplyError("mode 只能是 instant、verbose 或 null")
    conn.commit()


def resolve(conn, bot_id, session_id, main_model, fast_model=None):
    """这一轮用哪种回复方式、前台 / 后台各用哪个模型。"""
    s = bot_settings(conn, bot_id)
    override = session_override(conn, session_id) if session_id else None
    mode = override or s["mode"]
    front = s["front_model"] or fast_model or main_model
    back = s["back_model"] or main_model
    return {"mode": mode, "source": "chat" if override else "bot", "bot_mode": s["mode"], "override": override,
            "front_model": front, "back_model": back,
            "front_model_set": s["front_model"], "back_model_set": s["back_model"]}


def front_blocked(name):
    """秒回前台调了干活的工具（模型没照提示做）：不执行，告诉它交给后台。"""
    if name in FRONT_TOOLS:
        return None
    return {"error": "秒回模式下前台不直接干活：先回用户一句，再用 spawn_task 把这件事交给后台。"}


def front_tools(tools):
    """秒回前台：只留派活 / 转话 / 停止这类工具（干活的工具一律交给后台）。"""
    return [t for t in tools if t.get("function", {}).get("name") in FRONT_TOOLS]


# ---------- 状态短语：把 worker 的工具步骤汇总成一句人话 ----------

_TOOL_PHRASE = {
    "shell_execute": "运行命令", "background_jobs": "查看后台程序", "file_read": "阅读文件", "file_write": "写文件",
    "file_edit": "修改文件", "memory_search": "翻看记忆", "memory_write": "记下要点", "recall_snapshot": "回顾之前的对话",
    "skill_load": "加载技能", "skill_save": "保存技能", "page_write": "整理成页面", "image_generate": "生成图片",
    "subagent_task": "分派子任务", "delegate_task": "请其他 Bot 帮忙", "send_to_bot": "联系其他 Bot", "list_bots": "查看 Bot 列表",
    "vault_list": "查找保管库", "vault_fill": "填写登录信息", "vault_totp": "填写验证码", "send_message": "起草消息",
    "request_user_takeover": "等你接手云电脑", "report_progress": "汇报进展", "ask_choice": "等你决定",
    "routine_create": "设置例行任务", "routine_list": "查看例行任务", "routine_delete": "调整例行任务",
}
_BROWSER_PHRASE = {"navigate": "打开网页", "open": "打开网页", "click": "点击网页", "type": "在网页里输入", "fill": "在网页里输入",
                   "scroll": "浏览网页", "screenshot": "查看网页", "extract": "读取网页内容", "read": "读取网页内容",
                   "search": "搜索资料", "back": "返回上一页", "wait": "等网页加载"}
_DESKTOP_PHRASE = {"screenshot": "查看云电脑屏幕", "click": "操作云电脑", "type": "在云电脑里输入", "key": "在云电脑里按键",
                   "scroll": "浏览云电脑", "open": "打开云电脑程序", "launch": "打开云电脑程序"}
_SHELL_HINTS = (("pip install", "安装依赖"), ("apt", "安装软件"), ("npm install", "安装依赖"), ("git clone", "下载代码"),
                ("curl", "下载资料"), ("wget", "下载资料"), ("python", "运行脚本"), ("pytest", "跑测试"), ("make", "编译"),
                ("grep", "查找内容"), ("rg ", "查找内容"), ("ls", "查看文件"), ("cat ", "阅读文件"), ("sleep", "等待结果"))
START_PHRASE = "分析工作方案"
QUEUED_PHRASE = "排队等待开始"
FINISH_PHRASE = "整理结果"
PHRASE_MAX = 16


def _short(text, limit=PHRASE_MAX):
    t = " ".join(str(text).split()).strip("。.，, ")
    return t if len(t) <= limit else t[:limit - 1] + "…"


def tool_phrase(tool, args=None):
    """一步工具调用 → 一句短语（≤16 字）。有模型写的 tool_title 就用它。"""
    args = args if isinstance(args, dict) else {}
    title = args.get("tool_title") or args.get("title")
    if isinstance(title, str) and title.strip():
        return _short(title)
    tool = tool or ""
    if tool == "browser_action":
        return _BROWSER_PHRASE.get(str(args.get("action") or "").lower(), "浏览网页")
    if tool == "desktop_action":
        return _DESKTOP_PHRASE.get(str(args.get("action") or "").lower(), "操作云电脑")
    if tool == "shell_execute":
        cmd = str(args.get("command") or "").strip().lower()
        for needle, phrase in _SHELL_HINTS:
            if cmd.startswith(needle) or (" " + needle) in cmd or ("&& " + needle) in cmd:
                return phrase
        return "运行命令"
    if tool in _TOOL_PHRASE:
        return _TOOL_PHRASE[tool]
    if "__" in tool or "." in tool:
        return "使用插件"
    return "处理中"


def status_phrase(status, steps):
    """worker 当前在做什么：steps 是按时间排的 [(tool, args, done)]；还没有步骤 = 分析工作方案；最后一步做完在等模型 = 整理结果。"""
    if status == "queued":
        return QUEUED_PHRASE
    if status not in ("running",):
        return {"completed": "已完成", "failed": "没做完", "cancelled": "已停止", "interrupted": "中断了",
                "limit_reached": "步数到上限了", "paused": "已暂停，进度已保存"}.get(status, "已结束")
    if not steps:
        return START_PHRASE
    tool, args, done = steps[-1]
    if tool == "ask_choice":
        return "等你决定"
    if done:
        # 上一步已经做完、模型在想下一步：步数还少时是「思考下一步」，做了几步之后多半在收尾
        return FINISH_PHRASE if len(steps) >= 4 else "思考下一步"
    return tool_phrase(tool, args)


def eta_seconds(history_durations, elapsed):
    """预计剩余：只用真实数据。这个 Bot 最近完成的后台任务至少 3 个时，取用时中位数减去已用时间；
    样本不够、已经超过中位数时返回 None（不显示，不瞎猜）。"""
    xs = [float(d) for d in history_durations if isinstance(d, (int, float)) and d > 0]
    if len(xs) < ETA_MIN_SAMPLES:
        return None
    left = statistics.median(xs) - float(elapsed or 0)
    return int(round(left)) if left >= 5 else None


def recent_durations(conn, bot_id, limit=12):
    rows = conn.execute("SELECT finished_at - COALESCE(started_at, created_at) FROM bot_workers WHERE COALESCE(bot_id, '') = ? "
                        "AND status = 'completed' AND finished_at IS NOT NULL ORDER BY finished_at DESC LIMIT ?",
                        (bot_id or "", limit)).fetchall()
    return [r[0] for r in rows if r[0] is not None]


def decision_needed(conn, task_id):
    """worker 是否在等用户（审批 / 选项卡）：给手机「需要你决定」的提示音用。"""
    if not task_id:
        return False
    r = conn.execute("SELECT status FROM tasks WHERE task_id = ?", (task_id,)).fetchone()
    return bool(r and r[0] == "waiting_user")
