#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""云电脑代理：导入节点（vless / REALITY、vmess、trojan、ss、hysteria2 分享链接与订阅），
用 sing-box 在本机开一个 http + socks 混合端口，给 Bot 的终端、浏览器、pip / npm 和服务器自己的下载用。

- 节点（含密码 / uuid / 订阅地址）整体用主密钥加密保存，接口和日志只给出名称、类型、地址、端口。
- 运行时 sing-box 需要明文配置：写在只有服务账号可读（0600）的文件里，停止时删除。
- 分流：rules = 只有 GitHub / pypi / npm 等开发常用域名走代理；global = 除本机和内网外都走代理；off = 关闭。
"""

import base64
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import tarfile
import tempfile
import threading
import time
import urllib.parse
import urllib.request

SINGBOX_VERSION = "1.14.4"
# GitHub release 资源的 sha256（与 GitHub API 的 digest 字段一致）。镜像下载的文件必须和这里一致才会安装。
SINGBOX_SHA256 = {
    "amd64": "699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968",
    "arm64": "436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26",
}
GITHUB_MIRRORS = ("", "https://ghfast.top/", "https://gh-proxy.com/", "https://ghproxy.net/")
DEFAULT_PORT = 17890
MODES = ("off", "rules", "global")
RULE_DOMAINS = (
    "github.com", "githubusercontent.com", "githubassets.com", "github.io", "githubapp.com", "ghcr.io",
    "pypi.org", "pythonhosted.org", "npmjs.org", "npmjs.com", "yarnpkg.com", "nodejs.org",
    "docker.io", "docker.com", "gcr.io", "k8s.io", "go.dev", "golang.org", "huggingface.co", "hf.co",
    "astral.sh", "rust-lang.org", "crates.io", "playwright.dev", "playwright.azureedge.net", "sourceforge.net",
)
TEST_URL = "https://www.gstatic.com/generate_204"
MAX_NODES = 300


class ProxyError(Exception):
    pass


# ---------------------------------------------------------------- 分享链接解析

def _b64decode(s):
    s = s.strip().replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    return base64.b64decode(s).decode("utf-8")


def _port(v, what="端口"):
    try:
        p = int(v)
    except (TypeError, ValueError):
        raise ProxyError(f"{what}无效：{v}")
    if not 0 < p < 65536:
        raise ProxyError(f"{what}超出范围：{p}")
    return p


def _host(h):
    h = (h or "").strip()
    if h.startswith("[") and h.endswith("]"):
        h = h[1:-1]
    if not h or not re.match(r"^[A-Za-z0-9.:_-]+$", h):
        raise ProxyError("服务器地址无效")
    return h


def _truthy(v):
    return str(v or "").lower() in ("1", "true", "yes")


def _transport(net, host, path, service):
    net = (net or "tcp").lower()
    if net in ("tcp", "raw", "none", ""):
        return None
    if net == "ws":
        t = {"type": "ws", "path": path or "/"}
        if host:
            t["headers"] = {"Host": host}
        return t
    if net == "grpc":
        return {"type": "grpc", "service_name": service or ""}
    if net in ("http", "h2"):
        t = {"type": "http", "path": path or "/"}
        if host:
            t["host"] = [h.strip() for h in host.split(",") if h.strip()]
        return t
    if net == "httpupgrade":
        t = {"type": "httpupgrade", "path": path or "/"}
        if host:
            t["host"] = host
        return t
    raise ProxyError(f"sing-box 不支持 {net} 传输（xhttp / splithttp / kcp 等请换用 tcp / ws / grpc 节点）")


def _tls(security, sni, fp, alpn, insecure, pbk=None, sid=None):
    security = (security or "").lower()
    if security in ("", "none"):
        return None
    tls = {"enabled": True}
    if sni:
        tls["server_name"] = sni
    if insecure:
        tls["insecure"] = True
    if alpn:
        tls["alpn"] = [a.strip() for a in alpn.split(",") if a.strip()]
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    if security == "reality":
        if not pbk:
            raise ProxyError("REALITY 节点缺少公钥 pbk")
        tls["reality"] = {"enabled": True, "public_key": pbk, "short_id": sid or ""}
        tls.setdefault("utls", {"enabled": True, "fingerprint": "chrome"})
        tls.pop("alpn", None)
    elif security != "tls":
        raise ProxyError(f"不认识的加密方式：{security}")
    return tls


def _qs(u):
    return {k: v[-1] for k, v in urllib.parse.parse_qs(u.query, keep_blank_values=True).items()}


def _name(u, fallback):
    return urllib.parse.unquote(u.fragment).strip() or fallback


_SR_OBFS = {"websocket": "ws", "ws": "ws", "grpc": "grpc", "h2": "h2", "http": "http", "httpupgrade": "httpupgrade", "none": ""}


def _shadowrocket(link):
    """Shadowrocket 写法 → 标准写法：scheme://base64url("方法:密码或uuid@host:port")?remarks=&tls=1&peer=&xtls=&pbk=&sid=&obfs=…
    不是这种写法返回 None。"""
    scheme, rest = link.split("://", 1)
    scheme = scheme.lower()
    if scheme not in ("vless", "vmess", "trojan"):
        return None
    body, _, frag = rest.partition("#")
    head, _, query = body.partition("?")
    head = head.rstrip("/")
    if "@" in head:
        return None
    try:
        decoded = _b64decode(urllib.parse.unquote(head))
    except Exception:
        return None
    m = re.match(r"^([^:@]*):(.+)@(\[[0-9A-Fa-f:]+\]|[^:@\[\]]+):(\d+)$", decoded.strip())
    if not m:
        return None
    method, secret, host, port = m.groups()
    q = {k: v[-1] for k, v in urllib.parse.parse_qs(query, keep_blank_values=True).items()}
    name = q.get("remarks") or urllib.parse.unquote(frag) or ""
    tls_on = _truthy(q.get("tls")) or q.get("security") in ("tls", "reality")
    pbk, sid = q.get("pbk", ""), q.get("sid", "")
    sni = q.get("peer") or q.get("sni") or ""
    fp = q.get("fingerprint") or q.get("fp") or ""
    obfs = (q.get("obfs") or q.get("type") or "").lower()
    if obfs and obfs not in _SR_OBFS:
        raise ProxyError(f"sing-box 不支持 {obfs} 传输")
    net = _SR_OBFS.get(obfs, "")
    path = q.get("path", "")
    obfs_host = q.get("obfsParam") or q.get("host") or ""
    if obfs_host.startswith("{"):
        try:
            obfs_host = json.loads(obfs_host).get("Host", "")
        except ValueError:
            obfs_host = ""
    insecure = _truthy(q.get("allowInsecure") or q.get("insecure"))
    if scheme == "vmess":
        j = {"v": "2", "ps": name, "add": host.strip("[]"), "port": port, "id": secret, "aid": q.get("aid", "0"),
             "scy": method or "auto", "net": net or "tcp", "host": obfs_host, "path": path,
             "tls": "tls" if tls_on else "", "sni": sni, "fp": fp, "allowInsecure": "1" if insecure else ""}
        return "vmess://" + base64.b64encode(json.dumps(j).encode()).decode()
    out = {}
    if tls_on:
        out["security"] = "reality" if pbk else "tls"
    elif scheme == "trojan":
        out["security"] = "tls"
    for k, v in (("sni", sni), ("fp", fp), ("pbk", pbk), ("sid", sid)):
        if v:
            out[k] = v
    if insecure:
        out["allowInsecure"] = "1"
    xtls = q.get("xtls", "")
    if q.get("flow"):
        out["flow"] = q["flow"]
    elif xtls == "2":
        out["flow"] = "xtls-rprx-vision"
    elif xtls == "1":
        raise ProxyError("这个节点用的是 xtls-rprx-direct（xtls=1），sing-box 已不支持；请在机场换成 Vision（xtls=2）节点")
    if net:
        out["type"] = net
        if net == "grpc":
            out["serviceName"] = path or obfs_host
        else:
            if path:
                out["path"] = path
            if obfs_host:
                out["host"] = obfs_host
    hostpart = host if host.startswith("[") or ":" not in host else f"[{host}]"
    return (f"{scheme}://{urllib.parse.quote(secret, safe='')}@{hostpart}:{port}?{urllib.parse.urlencode(out)}"
            + (f"#{urllib.parse.quote(name)}" if name else ""))


def parse_link(link):
    """一条分享链接 → 节点：{name, type, server, port, outbound(sing-box), extra}。不支持的写法抛 ProxyError（中文原因）。"""
    link = (link or "").strip()
    if "://" not in link:
        raise ProxyError("不是分享链接")
    if not link.lower().startswith("vmess://") or "?" in link.split("#", 1)[0]:
        link = _shadowrocket(link) or link
    scheme = link.split("://", 1)[0].lower()
    if scheme == "vmess":
        return _parse_vmess(link)
    u = urllib.parse.urlsplit(link)
    if scheme == "vless":
        return _parse_vless(u)
    if scheme == "trojan":
        return _parse_trojan(u)
    if scheme == "ss":
        return _parse_ss(link)
    if scheme in ("hysteria2", "hy2"):
        return _parse_hy2(u)
    raise ProxyError(f"暂不支持 {scheme}:// 链接")


def _node(name, kind, server, port, outbound, extra=None):
    outbound = dict(outbound, server=server, server_port=port)
    return {"name": name[:80], "type": kind, "server": server, "port": port, "outbound": outbound, "extra": extra or {}}


def _parse_vless(u):
    q = _qs(u)
    uuid_ = urllib.parse.unquote(u.username or "")
    if not uuid_:
        raise ProxyError("vless 链接缺少 uuid")
    server, port = _host(u.hostname), _port(u.port)
    ob = {"type": "vless", "uuid": uuid_}
    flow = q.get("flow", "")
    if flow:
        if flow not in ("xtls-rprx-vision", "xtls-rprx-vision-udp443"):
            raise ProxyError(f"sing-box 不支持 flow={flow}")
        ob["flow"] = "xtls-rprx-vision"
    security = q.get("security", "none")
    tls = _tls(security, q.get("sni") or q.get("peer"), q.get("fp"), q.get("alpn"),
               _truthy(q.get("allowInsecure") or q.get("insecure")), q.get("pbk"), q.get("sid"))
    if tls:
        ob["tls"] = tls
    tr = _transport(q.get("type"), q.get("host"), urllib.parse.unquote(q.get("path", "")), q.get("serviceName"))
    if tr:
        ob["transport"] = tr
    if q.get("packetEncoding"):
        ob["packet_encoding"] = q["packetEncoding"]
    # spx（spiderX）只有 xray 用，sing-box 的 REALITY 客户端没有这个参数：解析出来如实显示，不影响连接
    extra = {k: q[k] for k in ("spx",) if q.get(k)}
    return _node(_name(u, server), "vless", server, port, ob, extra)


def _parse_vmess(link):
    body = link.split("://", 1)[1].split("#", 1)[0]
    try:
        j = json.loads(_b64decode(body))
    except Exception:
        raise ProxyError("vmess 链接内容无法解码")
    server, port = _host(str(j.get("add", ""))), _port(j.get("port"))
    ob = {"type": "vmess", "uuid": str(j.get("id") or ""), "security": j.get("scy") or "auto",
          "alter_id": int(j.get("aid") or 0)}
    if not ob["uuid"]:
        raise ProxyError("vmess 链接缺少 id")
    tls = _tls("tls" if str(j.get("tls", "")).lower() == "tls" else "", j.get("sni") or j.get("host"), j.get("fp"),
               j.get("alpn"), _truthy(j.get("allowInsecure")))
    if tls:
        ob["tls"] = tls
    net = j.get("net") or "tcp"
    if net == "tcp" and j.get("type") == "http":
        tr = {"type": "http", "path": j.get("path") or "/"}
        if j.get("host"):
            tr["host"] = [j["host"]]
    else:
        tr = _transport(net, j.get("host"), j.get("path"), j.get("path"))
    if tr:
        ob["transport"] = tr
    return _node(str(j.get("ps") or server), "vmess", server, port, ob)


def _parse_trojan(u):
    q = _qs(u)
    pw = urllib.parse.unquote(u.username or "")
    if not pw:
        raise ProxyError("trojan 链接缺少密码")
    server, port = _host(u.hostname), _port(u.port)
    security = q.get("security") or "tls"
    ob = {"type": "trojan", "password": pw}
    tls = _tls(security, q.get("sni") or q.get("peer") or server, q.get("fp"), q.get("alpn"),
               _truthy(q.get("allowInsecure") or q.get("insecure")), q.get("pbk"), q.get("sid"))
    if tls:
        ob["tls"] = tls
    tr = _transport(q.get("type"), q.get("host"), urllib.parse.unquote(q.get("path", "")), q.get("serviceName"))
    if tr:
        ob["transport"] = tr
    return _node(_name(u, server), "trojan", server, port, ob)


SS_METHODS = ("aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
              "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305", "none")


def _parse_ss(link):
    rest = link.split("://", 1)[1]
    rest, _, frag = rest.partition("#")
    rest, _, query = rest.partition("?")
    rest = rest.rstrip("/")
    if "@" in rest:
        userinfo, hostport = rest.rsplit("@", 1)
        userinfo = urllib.parse.unquote(userinfo)
        if ":" not in userinfo:
            try:
                userinfo = _b64decode(userinfo)
            except Exception:
                raise ProxyError("ss 链接的加密方式 / 密码无法解码")
    else:
        try:
            decoded = _b64decode(rest)
        except Exception:
            raise ProxyError("ss 链接无法解码")
        if "@" not in decoded:
            raise ProxyError("ss 链接缺少服务器地址")
        userinfo, hostport = decoded.rsplit("@", 1)
    method, _, password = userinfo.partition(":")
    if method.lower() not in SS_METHODS:
        raise ProxyError(f"sing-box 不支持 ss 加密方式 {method}")
    q = {k: v[-1] for k, v in urllib.parse.parse_qs(query).items()}
    if q.get("plugin"):
        raise ProxyError("暂不支持带 plugin（obfs / v2ray-plugin）的 ss 节点")
    hp = urllib.parse.urlsplit("//" + hostport)
    server, port = _host(hp.hostname), _port(hp.port)
    ob = {"type": "shadowsocks", "method": method.lower(), "password": password}
    return _node(urllib.parse.unquote(frag).strip() or server, "ss", server, port, ob)


def _parse_hy2(u):
    q = _qs(u)
    auth = urllib.parse.unquote(u.username or "")
    if u.password:
        auth += ":" + urllib.parse.unquote(u.password)
    server = _host(u.hostname)
    port = _port(u.port or 443)
    ob = {"type": "hysteria2", "password": auth,
          "tls": {"enabled": True, "server_name": q.get("sni") or server}}
    if _truthy(q.get("insecure")):
        ob["tls"]["insecure"] = True
    if q.get("alpn"):
        ob["tls"]["alpn"] = [a for a in q["alpn"].split(",") if a]
    if q.get("obfs"):
        if q["obfs"] != "salamander":
            raise ProxyError(f"不支持 hysteria2 混淆 {q['obfs']}")
        ob["obfs"] = {"type": "salamander", "password": q.get("obfs-password", "")}
    return _node(_name(u, server), "hysteria2", server, port, ob)


def parse_subscription(text):
    """订阅内容（base64 或一行一条）→ (节点列表, 跳过的条数, 第一条跳过原因)。"""
    text = (text or "").strip()
    if not text:
        raise ProxyError("订阅内容为空")
    if "://" not in text:
        try:
            text = _b64decode(re.sub(r"\s+", "", text))
        except Exception:
            raise ProxyError("订阅内容既不是分享链接也不是 base64（Clash / sing-box 配置文件格式暂不支持）")
    nodes, skipped, why = [], 0, None
    for line in text.splitlines():
        line = line.strip()
        if not line or "://" not in line:
            continue
        try:
            nodes.append(parse_link(line))
        except ProxyError as e:
            skipped += 1
            why = why or str(e)
    if not nodes:
        raise ProxyError("订阅里没有可用节点" + (f"：{why}" if why else ""))
    return nodes, skipped, why


# ---------------------------------------------------------------- sing-box 配置

def outbound_for(node, tag="proxy"):
    return dict(node["outbound"], tag=tag)


def build_config(node, mode, port=DEFAULT_PORT, extra_domains=()):
    if mode not in ("rules", "global"):
        raise ProxyError("代理已关闭")
    rules = [{"action": "sniff"}, {"ip_is_private": True, "outbound": "direct"},
             {"domain_suffix": ["localhost"], "outbound": "direct"}]
    if mode == "rules":
        rules.append({"domain_suffix": sorted(set(RULE_DOMAINS) | set(extra_domains)), "outbound": "proxy"})
    return {
        "log": {"level": "warn", "timestamp": True},
        "dns": {"servers": [{"type": "local", "tag": "local"}]},
        "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": port}],
        "outbounds": [outbound_for(node), {"type": "direct", "tag": "direct"}],
        "route": {"rules": rules, "final": "proxy" if mode == "global" else "direct",
                  "default_domain_resolver": "local", "auto_detect_interface": True},
    }


def build_test_config(nodes, base_port):
    """测速用：每个节点一个本机端口，各自直连对应节点。"""
    inbounds, outbounds, rules = [], [], []
    for i, n in enumerate(nodes):
        inbounds.append({"type": "mixed", "tag": f"in-{i}", "listen": "127.0.0.1", "listen_port": base_port + i})
        outbounds.append(outbound_for(n, f"n-{i}"))
        rules.append({"inbound": [f"in-{i}"], "outbound": f"n-{i}"})
    outbounds.append({"type": "direct", "tag": "direct"})
    return {"log": {"level": "error"}, "dns": {"servers": [{"type": "local", "tag": "local"}]},
            "inbounds": inbounds, "outbounds": outbounds,
            "route": {"rules": rules, "final": "direct", "default_domain_resolver": "local"}}


def proxy_env(port):
    http = f"http://127.0.0.1:{port}"
    env = {"HTTP_PROXY": http, "HTTPS_PROXY": http, "http_proxy": http, "https_proxy": http,
           "ALL_PROXY": f"socks5h://127.0.0.1:{port}", "all_proxy": f"socks5h://127.0.0.1:{port}",
           "NO_PROXY": "localhost,127.0.0.1,::1", "no_proxy": "localhost,127.0.0.1,::1",
           "npm_config_proxy": http, "npm_config_https_proxy": http,
           # git 用环境变量里的配置，不改用户的 ~/.gitconfig
           "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.proxy", "GIT_CONFIG_VALUE_0": http}
    return env


# ---------------------------------------------------------------- 安装 sing-box

def arch():
    m = platform.machine().lower()
    if m in ("x86_64", "amd64"):
        return "amd64"
    if m in ("aarch64", "arm64"):
        return "arm64"
    raise ProxyError(f"不支持的 CPU 架构：{m}")


def release_url(a):
    return (f"https://github.com/SagerNet/sing-box/releases/download/v{SINGBOX_VERSION}/"
            f"sing-box-{SINGBOX_VERSION}-linux-{a}.tar.gz")


def install_singbox(bin_dir, fetch=None, mirrors=GITHUB_MIRRORS, opener=None):
    """从 GitHub release 下载（依次试镜像），sha256 对上才解压安装。返回 sing-box 路径。"""
    a = arch()
    want = SINGBOX_SHA256[a]
    url = release_url(a)
    errors = []
    for m in mirrors:
        try:
            data = fetch(m + url) if fetch else _download(m + url, opener)
        except Exception as e:
            errors.append(f"{m or 'github.com'}：{type(e).__name__}")
            continue
        got = hashlib.sha256(data).hexdigest()
        if got != want:
            errors.append(f"{m or 'github.com'}：校验不一致")
            continue
        os.makedirs(bin_dir, exist_ok=True)
        with tempfile.TemporaryDirectory() as td:
            p = os.path.join(td, "sb.tgz")
            with open(p, "wb") as f:
                f.write(data)
            with tarfile.open(p) as tf:
                for member in tf.getmembers():
                    base = os.path.basename(member.name)
                    if member.isfile() and base in ("sing-box", "libcronet.so"):
                        src = tf.extractfile(member)
                        dst = os.path.join(bin_dir, base + ".new")
                        with open(dst, "wb") as out:
                            shutil.copyfileobj(src, out)
                        os.chmod(dst, 0o755)
                        os.replace(dst, os.path.join(bin_dir, base))
        path = os.path.join(bin_dir, "sing-box")
        if not os.path.exists(path):
            raise ProxyError("安装包里没有 sing-box")
        return path
    raise ProxyError("下载 sing-box 失败：" + "；".join(errors))


def _download(url, opener=None, limit=80 * 1024 * 1024):
    req = urllib.request.Request(url, headers={"User-Agent": "OpenMinis-cloud-agent"})
    with (opener.open(req, timeout=60) if opener else urllib.request.urlopen(req, timeout=60)) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ProxyError("下载过大")
    return data


# ---------------------------------------------------------------- 状态保存（加密）与运行

def _node_id(node):
    o = node["outbound"]
    key = json.dumps({k: o.get(k) for k in sorted(o)}, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(key.encode()).hexdigest()[:12]


def public_node(n):
    """给 App 看的节点信息：不含 uuid / 密码 / 公钥。"""
    o = n["outbound"]
    tls = o.get("tls") or {}
    sec = "REALITY" if (tls.get("reality") or {}).get("enabled") else ("TLS" if tls.get("enabled") else "")
    out = {"id": n["id"], "name": n["name"], "type": n["type"], "server": n["server"], "port": n["port"],
           "security": sec, "transport": (o.get("transport") or {}).get("type", "tcp"),
           "subscription": n.get("sub"), "latency_ms": n.get("latency_ms"), "tested_at": n.get("tested_at"),
           "test_error": n.get("test_error")}
    if o.get("flow"):
        out["flow"] = o["flow"]
    if tls.get("server_name"):
        out["sni"] = tls["server_name"]
    return out


def secret_strings(state):
    """会出现在日志里就算泄露的字符串（用于脱敏 sing-box 输出）。"""
    vals = set()
    for n in state.get("nodes", []):
        o = n["outbound"]
        for k in ("uuid", "password"):
            if o.get(k):
                vals.add(str(o[k]))
        r = (o.get("tls") or {}).get("reality") or {}
        for k in ("public_key", "short_id"):
            if r.get(k):
                vals.add(str(r[k]))
    for s in state.get("subscriptions", []):
        vals.add(s.get("url", ""))
    return {v for v in vals if len(v) >= 4}


def scrub(text, secrets):
    for s in sorted(secrets, key=len, reverse=True):
        text = text.replace(s, "***")
    return text


class ProxyManager:
    def __init__(self, state_dir, box_fn, port=DEFAULT_PORT):
        self.dir = state_dir
        self.box_fn = box_fn
        self.port = port
        self.lock = threading.RLock()
        self.proc = None
        self.last_error = None
        self.started_at = None
        self.restarts = 0
        self._state = None
        self._stop = threading.Event()
        self._watch = None
        self.installing = False
        self.install_error = None

    # -- 存储
    @property
    def state_path(self):
        return os.path.join(self.dir, "proxy_state.bin")

    @property
    def bin_dir(self):
        return os.path.join(self.dir, "proxy", "bin")

    @property
    def run_dir(self):
        return os.path.join(self.dir, "proxy", "run")

    def state(self):
        with self.lock:
            if self._state is None:
                self._state = {"mode": "off", "selected": None, "nodes": [], "subscriptions": [], "extra_domains": []}
                if os.path.exists(self.state_path):
                    with open(self.state_path, "rb") as f:
                        blob = f.read()
                    self._state.update(json.loads(self.box_fn().decrypt(blob, "proxy:state")))
            return self._state

    def _save(self):
        os.makedirs(self.dir, exist_ok=True)
        blob = self.box_fn().encrypt(json.dumps(self._state, ensure_ascii=False), "proxy:state")
        tmp = self.state_path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(blob)
        os.replace(tmp, self.state_path)

    # -- 节点
    def add_nodes(self, nodes, sub=None):
        with self.lock:
            st = self.state()
            have = {n["id"] for n in st["nodes"]}
            added = []
            for n in nodes:
                n = dict(n, id=_node_id(n))
                if sub:
                    n["sub"] = sub
                if n["id"] in have:
                    continue
                if len(st["nodes"]) >= MAX_NODES:
                    raise ProxyError(f"最多保存 {MAX_NODES} 个节点")
                st["nodes"].append(n)
                have.add(n["id"])
                added.append(n)
            if not st["selected"] and st["nodes"]:
                st["selected"] = st["nodes"][0]["id"]
            self._save()
            return added

    def import_text(self, text, fetch_sub=None):
        """粘贴的内容：一条或多条分享链接，或一个订阅地址（http/https）。"""
        text = (text or "").strip()
        if re.match(r"^https?://", text) and "\n" not in text:
            return self.add_subscription(text, fetch_sub)
        if "://" in text and len(text.splitlines()) == 1:
            return {"added": [public_node(n) for n in self.add_nodes([parse_link(text)])], "skipped": 0}
        nodes, skipped, why = parse_subscription(text)
        return {"added": [public_node(n) for n in self.add_nodes(nodes)], "skipped": skipped, "skip_reason": why}

    def add_subscription(self, url, fetch_sub=None):
        sid = hashlib.sha256(url.encode()).hexdigest()[:10]
        nodes, skipped, why = parse_subscription((fetch_sub or self.fetch_subscription)(url))
        with self.lock:
            st = self.state()
            subs = [s for s in st["subscriptions"] if s["id"] != sid]
            host = urllib.parse.urlsplit(url).hostname or "订阅"
            subs.append({"id": sid, "url": url, "host": host, "updated_at": time.time(), "count": len(nodes)})
            st["subscriptions"] = subs
            old_sel = st["selected"]
            st["nodes"] = [n for n in st["nodes"] if n.get("sub") != sid]
            added = self.add_nodes(nodes, sub=sid)
            if old_sel and any(n["id"] == old_sel for n in st["nodes"]):
                st["selected"] = old_sel
                self._save()
        self.apply()
        return {"added": [public_node(n) for n in added], "skipped": skipped, "skip_reason": why, "subscription": sid}

    def refresh_subscriptions(self, fetch_sub=None):
        out = []
        for s in list(self.state()["subscriptions"]):
            try:
                r = self.add_subscription(s["url"], fetch_sub)
                out.append({"id": s["id"], "count": len(r["added"])})
            except Exception as e:
                out.append({"id": s["id"], "error": str(e)})
        return out

    def fetch_subscription(self, url):
        # 订阅地址常在国外：先直连，失败且代理在运行时再经代理取
        req = urllib.request.Request(url, headers={"User-Agent": "sing-box/" + SINGBOX_VERSION})
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=20) as r:
                return r.read(4 * 1024 * 1024).decode("utf-8", "replace")
        except Exception:
            op = self.opener()
            if not op:
                raise ProxyError("订阅地址无法访问")
            with op.open(req, timeout=30) as r:
                return r.read(4 * 1024 * 1024).decode("utf-8", "replace")

    def delete(self, node_id=None, sub_id=None):
        with self.lock:
            st = self.state()
            if sub_id:
                st["subscriptions"] = [s for s in st["subscriptions"] if s["id"] != sub_id]
                st["nodes"] = [n for n in st["nodes"] if n.get("sub") != sub_id]
            if node_id:
                st["nodes"] = [n for n in st["nodes"] if n["id"] != node_id]
            if st["selected"] not in {n["id"] for n in st["nodes"]}:
                st["selected"] = st["nodes"][0]["id"] if st["nodes"] else None
            self._save()
        self.apply()

    def update(self, patch):
        with self.lock:
            st = self.state()
            if "mode" in patch:
                if patch["mode"] not in MODES:
                    raise ProxyError("mode 只能是 off / rules / global")
                st["mode"] = patch["mode"]
            if "selected" in patch:
                if patch["selected"] not in {n["id"] for n in st["nodes"]}:
                    raise ProxyError("没有这个节点")
                st["selected"] = patch["selected"]
            if "extra_domains" in patch:
                doms = patch["extra_domains"]
                if not isinstance(doms, list) or len(doms) > 200:
                    raise ProxyError("extra_domains 必须是域名列表")
                clean = []
                for d in doms:
                    d = str(d).strip().lower().lstrip("*.").strip(".")
                    if not re.match(r"^[a-z0-9-]+(\.[a-z0-9-]+)+$", d):
                        raise ProxyError(f"域名无效：{d}")
                    clean.append(d)
                st["extra_domains"] = sorted(set(clean))
            if st["mode"] != "off" and not st["selected"]:
                raise ProxyError("先添加一个节点")
            self._save()
        return self.apply()

    # -- 运行
    def binary(self):
        p = os.environ.get("OPENMINIS_SINGBOX")
        if p and os.path.exists(p):
            return p
        p = os.path.join(self.bin_dir, "sing-box")
        if os.path.exists(p):
            return p
        return shutil.which("sing-box")

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def selected_node(self):
        st = self.state()
        return next((n for n in st["nodes"] if n["id"] == st["selected"]), None)

    def apply(self):
        """按当前设置启动 / 重启 / 停止 sing-box。"""
        with self.lock:
            self._stop_proc()
            st = self.state()
            node = self.selected_node()
            if st["mode"] == "off" or not node:
                self.last_error = None
                return self.status()
            exe = self.binary()
            if not exe:
                self.last_error = "还没安装 sing-box"
                return self.status()
            cfg = build_config(node, st["mode"], self.port, st.get("extra_domains", []))
            self._spawn(exe, cfg)
            return self.status()

    def _write_config(self, cfg, name):
        os.makedirs(self.run_dir, mode=0o700, exist_ok=True)
        path = os.path.join(self.run_dir, name)
        fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(cfg, f)
        os.replace(path + ".tmp", path)
        return path

    def _spawn(self, exe, cfg):
        path = self._write_config(cfg, "config.json")
        log = open(os.path.join(self.run_dir, "sing-box.log"), "ab")
        self.proc = subprocess.Popen([exe, "run", "-c", path], stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
        log.close()
        self.started_at = time.time()
        if not _wait_port(self.port, 5) and self.proc.poll() is not None:
            self.last_error = "sing-box 启动失败：" + self._log_tail()
            self._stop_proc()
        else:
            self.last_error = None

    def _log_tail(self):
        try:
            with open(os.path.join(self.run_dir, "sing-box.log"), "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 600))
                tail = f.read().decode("utf-8", "replace").strip().splitlines()[-1:]
        except OSError:
            tail = []
        return scrub(tail[0] if tail else "没有输出", secret_strings(self.state()))[:300]

    def _stop_proc(self):
        if self.proc is not None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            self.proc = None
        try:
            os.remove(os.path.join(self.run_dir, "config.json"))
        except OSError:
            pass

    def shutdown(self):
        self._stop.set()
        with self.lock:
            self._stop_proc()

    def watch(self, interval=10):
        """sing-box 意外退出时静默重启（退避），连续失败才在状态里显示原因。"""
        def loop():
            fails = 0
            while not self._stop.wait(interval if fails == 0 else min(300, interval * 2 ** fails)):
                with self.lock:
                    st = self.state()
                    if st["mode"] == "off" or self.running() or not self.binary():
                        fails = 0 if self.running() else fails
                        continue
                    self.restarts += 1
                    self.apply()
                    fails = 0 if self.running() else fails + 1
        if not self._watch:
            self._watch = threading.Thread(target=loop, daemon=True, name="proxy-watch")
            self._watch.start()

    def active_port(self):
        st = self.state()
        return self.port if st["mode"] != "off" and self.running() else None

    def env(self):
        """Bot 终端用的环境变量；代理没在跑时返回空（不让命令连到一个不存在的端口）。"""
        p = self.active_port()
        return proxy_env(p) if p else {}

    def browser_proxy(self):
        p = self.active_port()
        return f"http://127.0.0.1:{p}" if p else None

    def opener(self):
        p = self.active_port()
        if not p:
            return None
        u = f"http://127.0.0.1:{p}"
        return urllib.request.build_opener(urllib.request.ProxyHandler({"http": u, "https": u}))

    def status(self):
        st = self.state()
        exe = self.binary()
        return {"mode": st["mode"], "selected": st["selected"], "running": self.running(), "port": self.port,
                "installed": bool(exe), "version": SINGBOX_VERSION if exe else None, "error": self.last_error,
                "started_at": self.started_at if self.running() else None, "restarts": self.restarts,
                "installing": self.installing, "install_error": self.install_error,
                "rule_domains": list(RULE_DOMAINS), "extra_domains": st.get("extra_domains", []),
                "nodes": [public_node(n) for n in st["nodes"]],
                "subscriptions": [{k: s.get(k) for k in ("id", "host", "updated_at", "count")} for s in st["subscriptions"]]}

    def install(self, fetch=None):
        path = install_singbox(self.bin_dir, fetch=fetch, opener=self.opener())
        self.apply()
        return path

    def install_async(self, fetch=None):
        """App 里点「安装」：后台下载（国内直连 GitHub 可能要几分钟），状态里看进度。"""
        with self.lock:
            if self.installing:
                return
            self.installing, self.install_error = True, None

        def work():
            try:
                self.install(fetch)
            except Exception as e:
                self.install_error = str(e)[:300]
            finally:
                self.installing = False
        threading.Thread(target=work, daemon=True, name="singbox-install").start()

    # -- 测速
    def test(self, node_ids=None, url=TEST_URL, timeout=8):
        """真连一次：临时开一个 sing-box，每个节点一个本机端口，经它访问 generate_204 计时。
        没装 sing-box 时退回 TCP 连接耗时（hysteria2 走 UDP，测不了）。"""
        st = self.state()
        nodes = [n for n in st["nodes"] if not node_ids or n["id"] in node_ids][:50]
        if not nodes:
            raise ProxyError("没有可测的节点")
        exe = self.binary()
        results = {}
        if exe:
            base = _free_port_block(len(nodes))
            path = self._write_config(build_test_config(nodes, base), "test.json")
            proc = subprocess.Popen([exe, "run", "-c", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    stdin=subprocess.DEVNULL, start_new_session=True)
            try:
                _wait_port(base + len(nodes) - 1, 5)
                lock = threading.Lock()

                def one(i, n):
                    r = _url_latency(url, base + i, timeout)
                    with lock:
                        results[n["id"]] = r
                threads = [threading.Thread(target=one, args=(i, n)) for i, n in enumerate(nodes)]
                for t in threads:
                    t.start()
                for t in threads:
                    t.join(timeout + 5)
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except Exception:
                    proc.kill()
                try:
                    os.remove(path)
                except OSError:
                    pass
        else:
            for n in nodes:
                results[n["id"]] = _tcp_latency(n) if n["type"] != "hysteria2" else {"error": "UDP 协议需安装 sing-box 后测"}
        with self.lock:
            now = time.time()
            for n in st["nodes"]:
                if n["id"] in results:
                    r = results[n["id"]]
                    n["latency_ms"], n["test_error"], n["tested_at"] = r.get("ms"), r.get("error"), now
            self._save()
        return [dict(results.get(n["id"], {"error": "超时"}), id=n["id"], method="url" if exe else "tcp") for n in nodes]


def _url_latency(url, port, timeout):
    u = f"http://127.0.0.1:{port}"
    op = urllib.request.build_opener(urllib.request.ProxyHandler({"http": u, "https": u}))
    t0 = time.monotonic()
    try:
        with op.open(urllib.request.Request(url, method="GET"), timeout=timeout) as r:
            r.read(64)
        return {"ms": int((time.monotonic() - t0) * 1000)}
    except Exception as e:
        return {"error": _short_err(e)}


def _tcp_latency(node, timeout=4):
    t0 = time.monotonic()
    try:
        with socket.create_connection((node["server"], node["port"]), timeout=timeout):
            pass
        return {"ms": int((time.monotonic() - t0) * 1000)}
    except Exception as e:
        return {"error": _short_err(e)}


def _short_err(e):
    s = str(getattr(e, "reason", "") or e)
    if "timed out" in s or isinstance(e, socket.timeout):
        return "超时"
    if "refused" in s:
        return "连接被拒绝"
    return "连接失败"


def _wait_port(port, timeout):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def _free_port_block(n):
    for _ in range(50):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            base = s.getsockname()[1]
        if base + n >= 65535:
            continue
        ok = True
        for p in range(base, base + n):
            with socket.socket() as s:
                try:
                    s.bind(("127.0.0.1", p))
                except OSError:
                    ok = False
                    break
        if ok:
            return base
    raise ProxyError("找不到空闲端口")


if __name__ == "__main__":
    # install.sh 调用：python3 cloud_proxy.py install <bin_dir>（失败不影响主服务安装）
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == "install":
        try:
            print(install_singbox(sys.argv[2]))
        except Exception as e:
            print(f"[-] sing-box 安装失败：{e}", file=sys.stderr)
            sys.exit(1)
    else:
        print("usage: cloud_proxy.py install <bin_dir>", file=sys.stderr)
        sys.exit(2)
