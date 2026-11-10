#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent — Telegram 渠道（Bot API 长轮询）。

只负责配置校验与 Bot API 调用；会话映射、任务启动与审批按钮在 cloud_agent_server 中实现。
Bot Token 与整份配置由 cloud_notify 的 secure_settings 表以 AES-256-GCM 加密保存。
"""

import http.client
import ipaddress
import json
import re
import socket
import ssl
import struct
import urllib.error
import urllib.parse
import urllib.request

SETTING_NAME = "telegram"
TOKEN_RE = re.compile(r"^\d{5,16}:[A-Za-z0-9_-]{30,64}$")
MAX_TEXT = 4000


class TelegramConfigError(ValueError):
    pass


class TelegramAPIError(Exception):
    """kind：network（连不上 / 超时，多半需要代理）、unauthorized（Token 无效）、other。"""

    def __init__(self, message, kind="other"):
        super().__init__(message)
        self.kind = kind


PROXY_SCHEMES = ("http", "https", "socks5", "socks5h")


def parse_proxy(url):
    """校验代理地址，返回规范化字符串；空值返回 None。"""
    if url is None or (isinstance(url, str) and not url.strip()):
        return None
    if not isinstance(url, str) or len(url) > 500:
        raise TelegramConfigError("proxy must be a URL string")
    p = urllib.parse.urlparse(url.strip())
    if p.scheme not in PROXY_SCHEMES or not p.hostname:
        raise TelegramConfigError("proxy 必须形如 http://host:port、https://host:port 或 socks5://[user:pass@]host:port")
    try:
        port = p.port
    except ValueError:
        raise TelegramConfigError("proxy 端口无效")
    if not port:
        raise TelegramConfigError("proxy 需要写明端口，例如 socks5://127.0.0.1:1080")
    if p.path not in ("", "/") or p.query or p.fragment:
        raise TelegramConfigError("proxy 只能包含协议、账号、主机和端口")
    return url.strip().rstrip("/")


def mask_proxy(url):
    if not url:
        return None
    p = urllib.parse.urlparse(url)
    auth = "***@" if p.username else ""
    return f"{p.scheme}://{auth}{p.hostname}:{p.port}"


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise OSError("SOCKS5 代理提前关闭连接")
        buf += chunk
    return buf


def socks5_connect(proxy_url, host, port, timeout):
    """最小 SOCKS5 CONNECT（RFC 1928 / 1929 用户名密码）。socks5h 由代理解析域名。"""
    p = urllib.parse.urlparse(proxy_url)
    sock = socket.create_connection((p.hostname, p.port), timeout=timeout)
    try:
        user = urllib.parse.unquote(p.username or "")
        pwd = urllib.parse.unquote(p.password or "")
        methods = b"\x00\x02" if user else b"\x00"
        sock.sendall(b"\x05" + bytes([len(methods)]) + methods)
        ver, method = _recv_exact(sock, 2)
        if ver != 5 or method == 0xFF:
            raise OSError("SOCKS5 代理拒绝了认证方式")
        if method == 2:
            u, w = user.encode()[:255], pwd.encode()[:255]
            sock.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(w)]) + w)
            if _recv_exact(sock, 2)[1] != 0:
                raise OSError("SOCKS5 代理用户名或密码错误")
        target = host
        if p.scheme == "socks5":
            target = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)[0][4][0]
        try:
            ip = ipaddress.ip_address(target)
            addr = (b"\x01" if ip.version == 4 else b"\x04") + ip.packed
        except ValueError:
            h = target.encode("idna")
            addr = b"\x03" + bytes([len(h)]) + h
        sock.sendall(b"\x05\x01\x00" + addr + struct.pack(">H", port))
        head = _recv_exact(sock, 4)
        if head[1] != 0:
            raise OSError(f"SOCKS5 代理无法连接目标（错误码 {head[1]}）")
        atyp = head[3]
        skip = 4 if atyp == 1 else 16 if atyp == 4 else _recv_exact(sock, 1)[0]
        _recv_exact(sock, skip + 2)
        return sock
    except Exception:
        sock.close()
        raise


class _SocksHTTPConnection(http.client.HTTPConnection):
    proxy_url = None

    def connect(self):
        self.sock = socks5_connect(self.proxy_url, self.host, self.port, self.timeout)


class _SocksHTTPSConnection(http.client.HTTPSConnection):
    proxy_url = None

    def connect(self):
        sock = socks5_connect(self.proxy_url, self.host, self.port, self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


class _SocksHandler(urllib.request.HTTPHandler, urllib.request.HTTPSHandler):
    def __init__(self, proxy_url):
        urllib.request.HTTPHandler.__init__(self)
        urllib.request.HTTPSHandler.__init__(self, context=ssl.create_default_context())
        self.proxy_url = proxy_url

    def _cls(self, base):
        return type("Conn", (base,), {"proxy_url": self.proxy_url})

    def http_open(self, req):
        return self.do_open(self._cls(_SocksHTTPConnection), req)

    def https_open(self, req):
        return self.do_open(self._cls(_SocksHTTPSConnection), req, context=self._context)


def build_opener(proxy=None):
    handlers = [_NoRedirect]
    if proxy and proxy.startswith("socks5"):
        handlers += [urllib.request.ProxyHandler({}), _SocksHandler(proxy)]
    elif proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    return urllib.request.build_opener(*handlers)


def _network_reason(e):
    reason = getattr(e, "reason", e)
    if isinstance(reason, (socket.timeout, TimeoutError)) or "timed out" in str(reason):
        return "连接超时"
    if isinstance(reason, socket.gaierror):
        return "域名解析失败"
    if isinstance(reason, ConnectionRefusedError):
        return "连接被拒绝"
    if isinstance(reason, ssl.SSLError):
        return "TLS 握手失败"
    text = str(reason)
    return text[:160] if text else type(reason).__name__


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "Redirection prohibited", headers, fp)


def validate(cfg, credential_exists):
    if not isinstance(cfg, dict):
        raise TelegramConfigError("config must be an object")
    token = cfg.get("bot_token")
    if token is None or (isinstance(token, str) and not token.strip()):
        raise TelegramConfigError("Bot Token 为空：请粘贴 @BotFather 发给你的 Token（形如 123456789:AA…）")
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
    proxy = parse_proxy(cfg.get("proxy"))
    if proxy:
        out["proxy"] = proxy
    if instructions:
        out["instructions"] = instructions
    return out


def masked(cfg):
    if not cfg:
        return None
    return {"bot_id": cfg["bot_token"].split(":")[0], "allowed_chat_ids": cfg["allowed_chat_ids"], "credential": cfg["credential"],
            "model": cfg["model"], "enabled": cfg.get("enabled", True), "api_base": cfg["api_base"],
            "has_instructions": bool(cfg.get("instructions")), "bot_username": cfg.get("bot_username"),
            "proxy": mask_proxy(cfg.get("proxy")), "has_proxy": bool(cfg.get("proxy"))}


def call(cfg, method, params=None, timeout=35):
    """调用 Bot API，返回 result。错误信息不包含 Token。"""
    url = f"{cfg['api_base']}/bot{cfg['bot_token']}/{method}"
    data = json.dumps(params or {}, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    opener = build_opener(cfg.get("proxy"))
    try:
        with opener.open(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            desc = json.loads(e.read().decode("utf-8")).get("description", "")
        except Exception:
            desc = ""
        kind = "unauthorized" if e.code in (401, 404) and method == "getMe" else "other"
        if e.code == 407:
            kind = "network"
            desc = desc or "代理需要认证"
        raise TelegramAPIError(f"{method}: HTTP {e.code} {desc}".strip(), kind)
    except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
        raise TelegramAPIError(f"{method}: {_network_reason(e)}", "network")
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
