# -*- coding: utf-8 -*-
"""远程 MCP 插件的 OAuth 登录（MCP 授权规范：受保护资源元数据 → 授权服务器元数据 → 动态注册 → PKCE 授权码）。

流程：手机调 start 拿到授权网址，用系统登录页（ASWebAuthenticationSession）打开，
用户同意后回调 openminis://oauth?code=…&state=…，手机再把 code/state 交给 finish，
服务器用 PKCE verifier 换令牌。令牌加密保存在 secure_settings（"oauth:<插件>"），接口只返回是否已连接。
"""

import base64
import hashlib
import json
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

FLOW_TTL = 600
_FLOWS = {}
_LOCK = threading.Lock()


class OAuthError(Exception):
    pass


def _get_json(url, timeout=10):
    req = urllib.request.Request(url, headers={"Accept": "application/json", "MCP-Protocol-Version": "2025-06-18"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read(512 * 1024).decode("utf-8"))
    except (urllib.error.URLError, ValueError, OSError):
        return None


def _post(url, data, form=True, timeout=15):
    body = urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/x-www-form-urlencoded" if form else "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read(512 * 1024).decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read(4096).decode("utf-8", "replace"))
            msg = detail.get("error_description") or detail.get("error") or ""
        except Exception:
            msg = ""
        raise OAuthError(f"HTTP {e.code} {msg}".strip())
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise OAuthError(f"连不上授权服务器：{e}")


def _well_known(base, name):
    """RFC 8414 / 9728：路径插在 .well-known/<name> 之后；没有路径时就是根。"""
    u = urllib.parse.urlparse(base)
    path = u.path.rstrip("/")
    urls = [f"{u.scheme}://{u.netloc}/.well-known/{name}{path}"]
    if path:
        urls.append(f"{u.scheme}://{u.netloc}/.well-known/{name}")
    return urls


def _resource_metadata_from_401(mcp_url):
    """未授权时 MCP 服务器在 WWW-Authenticate 里给出 resource_metadata 地址。"""
    req = urllib.request.Request(mcp_url, data=b'{"jsonrpc":"2.0","id":0,"method":"ping"}', method="POST",
                                 headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
    try:
        urllib.request.urlopen(req, timeout=10).close()
    except urllib.error.HTTPError as e:
        h = e.headers.get("WWW-Authenticate", "") if e.headers else ""
        for part in h.replace("Bearer", "").split(","):
            k, _, v = part.strip().partition("=")
            if k.strip() == "resource_metadata" and v:
                return v.strip().strip('"')
    except (urllib.error.URLError, OSError):
        pass
    return None


def discover(mcp_url):
    prm = None
    hint = _resource_metadata_from_401(mcp_url)
    for url in ([hint] if hint else []) + _well_known(mcp_url, "oauth-protected-resource"):
        prm = _get_json(url)
        if isinstance(prm, dict) and prm.get("authorization_servers"):
            break
        prm = None
    issuers = (prm or {}).get("authorization_servers") or []
    if not issuers:
        # 旧版规范：授权服务器就是 MCP 服务器所在的源
        u = urllib.parse.urlparse(mcp_url)
        issuers = [f"{u.scheme}://{u.netloc}"]
    for issuer in issuers[:3]:
        for url in _well_known(issuer, "oauth-authorization-server") + _well_known(issuer, "openid-configuration"):
            meta = _get_json(url)
            if isinstance(meta, dict) and meta.get("authorization_endpoint") and meta.get("token_endpoint"):
                meta["_resource"] = (prm or {}).get("resource") or mcp_url
                meta["_scopes"] = (prm or {}).get("scopes_supported") or []
                return meta
    raise OAuthError("这个插件的服务器没有提供 OAuth 登录（找不到授权服务器信息），请改用密钥")


def _https(url):
    u = urllib.parse.urlparse(url or "")
    return u.scheme == "https" or (u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost"))


def valid_redirect(uri):
    u = urllib.parse.urlparse(uri or "")
    return (u.scheme == "openminis" and len(uri) < 200) or (u.scheme == "https" and bool(u.hostname))


def start(pid, mcp_url, redirect_uri, saved_client=None):
    if not valid_redirect(redirect_uri):
        raise OAuthError("redirect_uri 必须是 openminis:// 或 https://")
    meta = discover(mcp_url)
    for k in ("authorization_endpoint", "token_endpoint"):
        if not _https(meta.get(k)):
            raise OAuthError("授权服务器地址必须是 https")
    client = saved_client if saved_client and saved_client.get("redirect_uri") == redirect_uri and saved_client.get("issuer") == meta.get("issuer") else None
    if not client:
        reg = meta.get("registration_endpoint")
        if not reg or not _https(reg):
            raise OAuthError("这个授权服务器不支持自动注册客户端（动态注册），暂时只能用密钥")
        r = _post(reg, {"client_name": "OpenMinis 云电脑", "redirect_uris": [redirect_uri],
                        "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                        "token_endpoint_auth_method": "none"}, form=False)
        if not r.get("client_id"):
            raise OAuthError("注册客户端失败")
        client = {"client_id": r["client_id"], "client_secret": r.get("client_secret"), "redirect_uri": redirect_uri,
                  "issuer": meta.get("issuer")}
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)
    q = {"response_type": "code", "client_id": client["client_id"], "redirect_uri": redirect_uri,
         "code_challenge": challenge, "code_challenge_method": "S256", "state": state, "resource": meta["_resource"]}
    if meta["_scopes"]:
        q["scope"] = " ".join(meta["_scopes"][:20])
    sep = "&" if "?" in meta["authorization_endpoint"] else "?"
    with _LOCK:
        now = time.time()
        for k in [k for k, f in _FLOWS.items() if now - f["at"] > FLOW_TTL]:
            _FLOWS.pop(k, None)
        _FLOWS[state] = {"pid": pid, "verifier": verifier, "client": client, "token_endpoint": meta["token_endpoint"],
                         "resource": meta["_resource"], "at": now}
    return meta["authorization_endpoint"] + sep + urllib.parse.urlencode(q), client


def finish(pid, code, state):
    with _LOCK:
        flow = _FLOWS.pop(state or "", None)
    if not flow or flow["pid"] != pid or time.time() - flow["at"] > FLOW_TTL:
        raise OAuthError("登录已过期或不匹配，请重新连接")
    if not isinstance(code, str) or not code or len(code) > 4000:
        raise OAuthError("缺少授权码")
    c = flow["client"]
    data = {"grant_type": "authorization_code", "code": code, "redirect_uri": c["redirect_uri"], "client_id": c["client_id"],
            "code_verifier": flow["verifier"], "resource": flow["resource"]}
    if c.get("client_secret"):
        data["client_secret"] = c["client_secret"]
    return _tokens(_post(flow["token_endpoint"], data), flow["token_endpoint"], c, flow["resource"])


def _tokens(r, token_endpoint, client, resource, old_refresh=None):
    if not r.get("access_token"):
        raise OAuthError("授权服务器没有返回令牌")
    exp = r.get("expires_in")
    return {"access_token": r["access_token"], "refresh_token": r.get("refresh_token") or old_refresh,
            "expires_at": time.time() + float(exp) if isinstance(exp, (int, float)) else None,
            "token_endpoint": token_endpoint, "client": client, "resource": resource, "connected_at": time.time()}


def needs_refresh(tok, skew=60):
    return bool(tok and tok.get("expires_at") and tok["expires_at"] - skew < time.time() and tok.get("refresh_token"))


def refresh(tok):
    c = tok["client"]
    data = {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"], "client_id": c["client_id"], "resource": tok["resource"]}
    if c.get("client_secret"):
        data["client_secret"] = c["client_secret"]
    return _tokens(_post(tok["token_endpoint"], data), tok["token_endpoint"], c, tok["resource"], old_refresh=tok["refresh_token"])
