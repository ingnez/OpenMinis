"""多 Bot 接力：把一个 Bot 的结果一键交给另一个 Bot 继续做。"""

FIELD_LIMITS = {"result": 8000, "context": 6000, "goal": 2000, "from_name": 80, "to_name": 80}


class RelayError(ValueError):
    pass


def clean(req):
    if not isinstance(req, dict):
        raise RelayError("请求必须是对象")
    to_bot = req.get("to_bot")
    if not isinstance(to_bot, str) or not to_bot.strip():
        raise RelayError("必须指定 to_bot")
    to_bot = to_bot.strip()
    from_bot = req.get("from_bot")
    if from_bot is not None:
        if not isinstance(from_bot, str) or not from_bot.strip():
            raise RelayError("from_bot 必须是 Bot ID")
        from_bot = from_bot.strip()
        if from_bot == to_bot:
            raise RelayError("不能交给同一个 Bot")
    fields = {}
    for k, limit in FIELD_LIMITS.items():
        v = req.get(k)
        if v is None:
            continue
        if not isinstance(v, str):
            raise RelayError(f"{k} 必须是字符串")
        fields[k] = v.strip()[:limit]
    if not fields.get("result") and not fields.get("goal"):
        raise RelayError("至少要带上 result（上一个 Bot 的结果）或 goal")
    from_session = req.get("from_session")
    if from_session is not None and (not isinstance(from_session, str) or not from_session.startswith("sess_")):
        raise RelayError("from_session 必须是会话 ID")
    return {
        "to_bot": to_bot,
        "from_bot": from_bot,
        "from_session": from_session,
        "fields": fields,
        "client_nonce": req.get("client_nonce") if isinstance(req.get("client_nonce"), str) else None,
    }


def compose(fields, from_name, redact=lambda s: s):
    who = from_name or fields.get("from_name") or "上一个 Bot"
    lines = [f"【Bot 接力】请接着 {who} 的工作继续做完。"]
    if fields.get("goal"):
        lines.append("目标：" + fields["goal"])
    if fields.get("result"):
        lines.append("已有结果：\n" + fields["result"])
    if fields.get("context"):
        lines.append("背景：\n" + fields["context"])
    lines.append("先用一句话确认已经接手，再继续做；需要用户确认时直接说明。不要重复已经完成的步骤。")
    return redact("\n\n".join(lines))
