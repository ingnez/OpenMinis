#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Clash / Clash.Meta (mihomo) 订阅 YAML → 分享链接，再交给 cloud_proxy.parse_link。
只读 proxies: 里的节点（ss / vmess / vless 含 REALITY / trojan / hysteria2），规则、分组忽略。
服务器上不一定装了 PyYAML：有就用，没有就用下面这个只认 proxies 写法的小解析器（行内 {…} 和缩进块两种都认）。"""

import base64
import json
import re
import urllib.parse


class ClashError(Exception):
    pass


def looks_like_clash(text):
    return bool(re.search(r"(?m)^proxies\s*:", text or ""))


# ---------------------------------------------------------------- 小 YAML 解析（只够 proxies 用）

def _scalar(v):
    v = v.strip()
    if not v:
        return ""
    if (v[0] == v[-1]) and v[0] in "'\"" and len(v) >= 2:
        return v[1:-1]
    low = v.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    if low in ("null", "~"):
        return None
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v


def _flow(s, i=0):
    """解析 {a: b, c: {d: e}, f: [x, y]}，返回 (值, 结束位置)。"""
    s_len = len(s)

    def skip(j):
        while j < s_len and s[j] in " \t":
            j += 1
        return j

    i = skip(i)
    if s[i] == "{":
        out, i = {}, i + 1
        while True:
            i = skip(i)
            if i < s_len and s[i] == "}":
                return out, i + 1
            m = re.compile(r"\s*('[^']*'|\"[^\"]*\"|[^:,}]+?)\s*:\s*").match(s, i)
            if not m:
                raise ClashError("Clash 节点写法看不懂")
            key = _scalar(m.group(1))
            i = m.end()
            val, i = _flow(s, i)
            out[str(key)] = val
            i = skip(i)
            if i < s_len and s[i] == ",":
                i += 1
    if s[i] == "[":
        out, i = [], i + 1
        while True:
            i = skip(i)
            if i < s_len and s[i] == "]":
                return out, i + 1
            val, i = _flow(s, i)
            out.append(val)
            i = skip(i)
            if i < s_len and s[i] == ",":
                i += 1
    if s[i] in "'\"":
        q = s[i]
        j = s.index(q, i + 1)
        return s[i + 1:j], j + 1
    m = re.compile(r"[^,}\]]*").match(s, i)
    return _scalar(m.group(0)), m.end()


def _block(lines, indent):
    """缩进块 → dict（值可以是行内 {…} / […] 或更深的块）。lines: [(缩进, 文本)]，就地消费。"""
    out = {}
    while lines and lines[0][0] >= indent:
        ind, text = lines[0]
        if ind > indent or text.startswith("- "):
            break
        lines.pop(0)
        key, _, val = text.partition(":")
        key, val = _scalar(key), val.strip()
        if val:
            out[str(key)] = _flow(val)[0] if val[0] in "{[" else _scalar(val)
        elif lines and lines[0][0] > indent:
            if lines[0][1].startswith("- "):
                items = []
                sub = lines[0][0]
                while lines and lines[0][0] == sub and lines[0][1].startswith("- "):
                    items.append(_scalar(lines.pop(0)[1][2:]))
                out[str(key)] = items
            else:
                out[str(key)] = _block(lines, lines[0][0])
        else:
            out[str(key)] = None
    return out


def _mini_proxies(text):
    raw = text.splitlines()
    start = next((i for i, l in enumerate(raw) if re.match(r"^proxies\s*:", l)), None)
    if start is None:
        return []
    lines = []
    for l in raw[start + 1:]:
        if not l.strip() or l.lstrip().startswith("#"):
            continue
        if not l.startswith((" ", "\t", "-")):
            break      # 下一个顶层键（proxy-groups: / rules:）
        stripped = l.lstrip()
        lines.append((len(l) - len(stripped), stripped.rstrip()))
    proxies = []
    while lines:
        ind, text = lines.pop(0)
        if not text.startswith("- "):
            continue
        body = text[2:].strip()
        if body.startswith("{"):
            proxies.append(_flow(body)[0])
        else:
            # 「- name: x」开头的块：第一行是 dash 后的键，后面的键缩进到 dash 后面那一列
            lines.insert(0, (ind + 2, body))
            proxies.append(_block(lines, ind + 2))
    return proxies


def parse_proxies(text):
    try:
        import yaml  # type: ignore
        data = yaml.safe_load(text)
        if isinstance(data, dict) and isinstance(data.get("proxies"), list):
            return [p for p in data["proxies"] if isinstance(p, dict)]
    except ImportError:
        pass
    except Exception:
        raise ClashError("Clash 配置文件不是有效的 YAML")
    return [p for p in _mini_proxies(text) if isinstance(p, dict)]


# ---------------------------------------------------------------- 节点 → 分享链接

def _q(d):
    return urllib.parse.urlencode({k: v for k, v in d.items() if v not in (None, "", False)}, quote_via=urllib.parse.quote)


def _transport(p):
    net = str(p.get("network") or "tcp")
    q = {}
    if net == "ws":
        o = p.get("ws-opts") or {}
        q.update(type="ws", path=o.get("path") or "/", host=(o.get("headers") or {}).get("Host", ""))
    elif net == "grpc":
        q.update(type="grpc", serviceName=(p.get("grpc-opts") or {}).get("grpc-service-name", ""))
    elif net in ("h2", "http"):
        o = p.get("h2-opts") or p.get("http-opts") or {}
        path = o.get("path") or "/"
        q.update(type="http", path=path[0] if isinstance(path, list) else path,
                 host=",".join(o.get("host") or []) if isinstance(o.get("host"), list) else (o.get("host") or ""))
    return q


def _hostport(p):
    server, port = str(p.get("server") or ""), p.get("port")
    if not server or not port:
        raise ClashError(f"节点「{p.get('name', '?')}」缺少 server / port")
    host = f"[{server}]" if ":" in server and not server.startswith("[") else server
    return f"{host}:{port}"


def to_link(p):
    kind = str(p.get("type") or "").lower()
    name = urllib.parse.quote(str(p.get("name") or ""))
    hp = _hostport(p)
    alpn = ",".join(p["alpn"]) if isinstance(p.get("alpn"), list) else (p.get("alpn") or "")
    insecure = "1" if p.get("skip-cert-verify") else ""
    if kind == "ss":
        if p.get("plugin"):
            raise ClashError("暂不支持带 plugin（obfs / v2ray-plugin）的 ss 节点")
        userinfo = base64.urlsafe_b64encode(f"{p.get('cipher', '')}:{p.get('password', '')}".encode()).decode().rstrip("=")
        return f"ss://{userinfo}@{hp}#{name}"
    if kind == "trojan":
        q = dict(sni=p.get("sni") or p.get("servername") or "", alpn=alpn, allowInsecure=insecure,
                 fp=p.get("client-fingerprint") or "", **_transport(p))
        return f"trojan://{urllib.parse.quote(str(p.get('password', '')), safe='')}@{hp}?{_q(q)}#{name}"
    if kind == "vless":
        reality = p.get("reality-opts") or {}
        security = "reality" if reality else ("tls" if p.get("tls") else "none")
        q = dict(encryption="none", security=security, sni=p.get("servername") or p.get("sni") or "",
                 fp=p.get("client-fingerprint") or "", pbk=str(reality.get("public-key") or ""), sid=str(reality.get("short-id") if reality.get("short-id") is not None else ""),
                 flow=p.get("flow") or "", alpn=alpn, allowInsecure=insecure, **_transport(p))
        return f"vless://{str(p.get('uuid') or '')}@{hp}?{_q(q)}#{name}"
    if kind == "vmess":
        tr = _transport(p)
        j = {"v": "2", "ps": str(p.get("name") or ""), "add": str(p.get("server")), "port": str(p.get("port")),
             "id": str(p.get("uuid") or ""), "aid": str(p.get("alterId") or 0), "scy": p.get("cipher") or "auto",
             "net": tr.get("type", "tcp") if tr.get("type") != "http" else "h2", "host": tr.get("host", ""),
             "path": tr.get("path") or tr.get("serviceName") or "", "tls": "tls" if p.get("tls") else "",
             "sni": p.get("servername") or "", "allowInsecure": bool(p.get("skip-cert-verify"))}
        return "vmess://" + base64.b64encode(json.dumps(j, ensure_ascii=False).encode()).decode()
    if kind in ("hysteria2", "hy2"):
        q = dict(sni=p.get("sni") or "", insecure=insecure, alpn=alpn, obfs=p.get("obfs") or "",
                 **{"obfs-password": p.get("obfs-password") or ""})
        return f"hysteria2://{urllib.parse.quote(str(p.get('password', '')), safe='')}@{hp}?{_q(q)}#{name}"
    raise ClashError(f"暂不支持 Clash 里的 {kind or '未知'} 节点")


def to_links(text):
    """Clash YAML → (分享链接列表, 跳过条数, 第一条跳过原因)。"""
    proxies = parse_proxies(text)
    if not proxies:
        raise ClashError("Clash 配置里没有 proxies 节点")
    links, skipped, why = [], 0, None
    for p in proxies:
        try:
            links.append(to_link(p))
        except ClashError as e:
            skipped += 1
            why = why or str(e)
    return links, skipped, why
