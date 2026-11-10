#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent — Telegram 渠道（Bot API 长轮询）。

只负责配置校验与 Bot API 调用；会话映射、任务启动与审批按钮在 cloud_agent_server 中实现。
Bot Token 与整份配置由 cloud_notify 的 secure_settings 表以 AES-256-GCM 加密保存。
"""

import json
import re
import urllib.error
import urllib.parse
import urllib.request

SETTING_NAME = "telegram"
TOKEN_RE = re.compile(r"^\d{5,16}:[A-Za-z0-9_-]{30,64}$")
MAX_TEXT = 4000


class TelegramConfigError(ValueError):
    pass


class TelegramAPIError(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "Redirection prohibited", headers, fp)


def validate(cfg, credential_exists):
    if not isinstance(cfg, dict):
        raise TelegramConfigError("config must be an object")
    token = cfg.get("bot_token")
    if not isinstance(token, str) or not TOKEN_RE.match(token.strip()):
        raise TelegramConfigError("bot_token looks invalid (expected <digits>:<secret> from @BotFather)")
    chats = cfg.get("allowed_chat_ids", [])
    if not isinstance(chats, list) or len(chats) > 50 or not all(isinstance(c, int) and not isinstance(c, bool) for c in chats):
        raise TelegramConfigError("allowed_chat_ids must be a list of integers (max 50)")
    credential = cfg.get("credential")
    if not isinstance(credential, str) or not credential_exists(credential):
        raise TelegramConfigError("credential must name a stored credential (PUT /v1/credentials/{name} first)")
    model = cfg.get("model")
    if not isinstance(model, str) or not model.strip() or len(model) > 200:
        raise TelegramConfigError("model is required")
    api_base = cfg.get("api_base") or "https://api.telegram.org"
    p = urllib.parse.urlparse(api_base)
    if p.scheme not in ("http", "https") or not p.netloc:
        raise TelegramConfigError("api_base must be an http(s) URL")
    instructions = cfg.get("instructions")
    if instructions is not None and (not isinstance(instructions, str) or len(instructions) > 20000):
        raise TelegramConfigError("instructions must be a string")
    out = {"bot_token": token.strip(), "allowed_chat_ids": chats, "credential": credential, "model": model.strip(),
           "api_base": api_base.rstrip("/"), "enabled": bool(cfg.get("enabled", True))}
    if instructions:
        out["instructions"] = instructions
    return out


def masked(cfg):
    if not cfg:
        return None
    return {"bot_id": cfg["bot_token"].split(":")[0], "allowed_chat_ids": cfg["allowed_chat_ids"], "credential": cfg["credential"],
            "model": cfg["model"], "enabled": cfg.get("enabled", True), "api_base": cfg["api_base"],
            "has_instructions": bool(cfg.get("instructions")), "bot_username": cfg.get("bot_username")}


def call(cfg, method, params=None, timeout=35):
    """调用 Bot API，返回 result。错误信息不包含 Token。"""
    url = f"{cfg['api_base']}/bot{cfg['bot_token']}/{method}"
    data = json.dumps(params or {}, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            desc = json.loads(e.read().decode("utf-8")).get("description", "")
        except Exception:
            desc = ""
        raise TelegramAPIError(f"{method}: HTTP {e.code} {desc}".strip())
    except Exception as e:
        raise TelegramAPIError(f"{method}: {type(e).__name__}")
    if not body.get("ok"):
        raise TelegramAPIError(f"{method}: {body.get('description', 'not ok')}")
    return body.get("result")


def chunks(text, size=MAX_TEXT):
    text = text or "（无文字回复）"
    out = []
    while text:
        if len(text) <= size:
            out.append(text)
            break
        cut = text.rfind("\n", 0, size)
        if cut < size // 2:
            cut = size
        out.append(text[:cut])
        text = text[cut:].lstrip("\n")
    return out


def send_text(cfg, chat_id, text, reply_markup=None):
    parts = chunks(text)
    for i, part in enumerate(parts):
        params = {"chat_id": chat_id, "text": part, "disable_web_page_preview": True}
        if reply_markup and i == len(parts) - 1:
            params["reply_markup"] = reply_markup
        call(cfg, "sendMessage", params, timeout=20)
