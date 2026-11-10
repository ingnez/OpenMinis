# -*- coding: utf-8 -*-
"""本地 → 云端交接：本地模式做不完的工作打包（目标、进展、关键输出、文件、剩余步骤）交给 Bot 在云端继续。
没指定 Bot 时交给主 Bot，由它判断自己做还是转给最合适的 Bot。"""

MAX_FILES = 10
MAX_FILE_BYTES = 20 * 1024 * 1024
FIELD_LIMITS = {"goal": 2000, "progress": 6000, "outputs": 8000, "remaining": 3000, "summary": 8000}


class HandoffError(ValueError):
    pass


def clean(req):
    """校验请求字段，返回 (字段, 文件列表)。文件是 [{filename, data_base64}]。"""
    out = {}
    for k, limit in FIELD_LIMITS.items():
        v = req.get(k)
        if v is None:
            continue
        if not isinstance(v, str):
            raise HandoffError(f"{k} 必须是字符串")
        out[k] = v.strip()[:limit]
    if not out.get("goal") and not out.get("summary"):
        raise HandoffError("至少要写明 goal（要完成什么）")
    files = req.get("files") or []
    if not isinstance(files, list) or len(files) > MAX_FILES:
        raise HandoffError(f"files 最多 {MAX_FILES} 个")
    for f in files:
        if not isinstance(f, dict) or not isinstance(f.get("filename"), str) or not isinstance(f.get("data_base64"), str):
            raise HandoffError("files 每项需要 filename 和 data_base64")
    target = req.get("target_bot")
    if target is not None and (not isinstance(target, str) or not target):
        raise HandoffError("target_bot 必须是 Bot ID")
    return out, files


def compose(fields, saved_paths, routed, redact=lambda s: s):
    """交给 Bot 的那条消息。routed=True 表示没指定 Bot，由主 Bot 分派。"""
    lines = ["【从本地模式交接的工作】本地没能做完，请在云端接着做完。"]
    if fields.get("goal"):
        lines.append("目标：" + fields["goal"])
    if fields.get("summary"):
        lines.append("背景摘要：\n" + fields["summary"])
    if fields.get("progress"):
        lines.append("已完成的进展：\n" + fields["progress"])
    if fields.get("outputs"):
        lines.append("关键输出：\n" + fields["outputs"])
    if saved_paths:
        lines.append("已传到云电脑的文件：\n" + "\n".join(f"- {p}" for p in saved_paths))
    if fields.get("remaining"):
        lines.append("剩余步骤：\n" + fields["remaining"])
    if routed:
        lines.append("你是主 Bot：先判断这件事最适合谁做——自己做，或者用 delegate_task 交给最合适的 Bot。"
                     "活比较长就用 spawn_task 在后台继续，先用一句话告诉用户已经接手、由谁在做。")
    else:
        lines.append("活比较长就用 spawn_task 在后台继续，先用一句话告诉用户已经接手。")
    lines.append("做完后核对结果再汇报；需要用户的登录或确认时直接说明。")
    return redact("\n\n".join(lines))
