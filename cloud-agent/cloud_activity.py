# -*- coding: utf-8 -*-
"""首页「正在回复」：从正在跑的任务的实时状态（只在内存的 LIVE）推出这个 Bot 此刻在干什么。

phase：thinking（还没出字）/ tool（在跑某个工具）/ replying（正在出字，带最后一行预览）/ delegating（交给别的 Bot 了）。
预览先经 redact（保管库里的值不会出现在首页），只取最后一行的末尾 PREVIEW_MAX 个字。
"""

PREVIEW_MAX = 60


def last_line(text, limit=PREVIEW_MAX):
    lines = [ln.strip() for ln in str(text or "").splitlines() if ln.strip()]
    if not lines:
        return ""
    line = " ".join(lines[-1].split())
    return line if len(line) <= limit else "…" + line[-(limit - 1):]


def describe(live, delegating_to=None, redact=lambda s: s):
    """live：live_get(task_id) 的结果（可能是 None）；delegating_to：正在等的那个 Bot 的名字。"""
    if delegating_to:
        return {"phase": "delegating", "peer": str(delegating_to)[:40]}
    live = live or {}
    tool = live.get("tool")
    if isinstance(tool, dict) and tool.get("name"):
        return {"phase": "tool", "tool": str(tool["name"])[:40]}
    preview = last_line(redact(live.get("text") or ""))
    if preview:
        return {"phase": "replying", "preview": preview}
    return {"phase": "thinking"}


def pending_delegation(events):
    """events：按时间排的 (type, payload dict)。最后一次 delegation_started 之后没有对应的 finished → 返回对方名字。"""
    open_ = {}
    for etype, p in events:
        did = (p or {}).get("delegation_id")
        if etype == "delegation_started":
            open_[did] = (p or {}).get("to_name") or (p or {}).get("to_bot") or "别的 Bot"
        elif etype == "delegation_finished":
            open_.pop(did, None)
    return list(open_.values())[-1] if open_ else None
