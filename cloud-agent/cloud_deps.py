# -*- coding: utf-8 -*-
"""插件运行依赖（npx / uvx）安装器。

- 只安装两种固定工具：Node.js（提供 node/npm/npx）与 uv（提供 uv/uvx），来源固定为官方发布地址。
- 下载后用官方 SHA-256 校验和比对，不一致即放弃；安装到用户目录（无需 root），并加入本进程 PATH。
- 由接口在用户明确确认后触发，后台运行，状态与日志可查询。
"""

import hashlib
import io
import json
import os
import platform
import shutil
import re
import tarfile
import threading
import zipfile
import time
import urllib.parse
import urllib.request

NODE_DIST = os.environ.get("OPENMINIS_NODE_DIST", "https://nodejs.org/dist/latest-v22.x")
UV_DIST = os.environ.get("OPENMINIS_UV_DIST", "https://github.com/astral-sh/uv/releases/latest/download")
# 国内 VPS 常无法访问 nodejs.org / GitHub：官方源失败后依次尝试国内镜像（同样校验 SHA-256）
NODE_MIRRORS = ["https://cdn.npmmirror.com/binaries/node/latest-v22.x"]
PYPI_INDEXES = ["https://pypi.org/simple", "https://mirrors.aliyun.com/pypi/simple", "https://pypi.tuna.tsinghua.edu.cn/simple"]
PREFIX = os.path.expanduser(os.environ.get("OPENMINIS_DEPS_PREFIX", "~/.local"))
MAX_DOWNLOAD = 200 * 1024 * 1024

TOOLS = {
    "node": {"provides": ["node", "npm", "npx"], "label": "Node.js（node / npm / npx）", "source": "nodejs.org"},
    "uv": {"provides": ["uv", "uvx"], "label": "uv（uv / uvx）", "source": "github.com/astral-sh/uv"},
}
ALIASES = {"npx": "node", "npm": "node", "node": "node", "uvx": "uv", "uv": "uv"}

_lock = threading.Lock()
_jobs = {}   # tool -> {status, log, started_at, finished_at, error}


class DepsError(RuntimeError):
    pass


def bin_dir():
    return os.path.join(PREFIX, "bin")


def ensure_path():
    """把安装目录加入本进程 PATH，使 shutil.which 与子进程能找到新装的工具。"""
    b = bin_dir()
    parts = os.environ.get("PATH", "").split(os.pathsep)
    if b not in parts:
        os.environ["PATH"] = os.pathsep.join([b] + [p for p in parts if p])


def tool_for(executable):
    return ALIASES.get(executable)


def status():
    ensure_path()
    with _lock:
        jobs = {k: dict(v) for k, v in _jobs.items()}
    out = {}
    for tool, info in TOOLS.items():
        found = {e: shutil.which(e) for e in info["provides"]}
        out[tool] = {"label": info["label"], "source": info["source"], "installed": all(found.values()),
                     "paths": found, "job": jobs.get(tool)}
    return out


def _arch(kind):
    m = platform.machine().lower()
    if m in ("x86_64", "amd64"):
        return "x64" if kind == "node" else "x86_64"
    if m in ("aarch64", "arm64"):
        return "arm64" if kind == "node" else "aarch64"
    raise DepsError(f"不支持的 CPU 架构：{m}")


# 云电脑代理在运行时返回经代理的 opener（服务端设置）；GitHub 等下载走代理，代理没开时直连
OPENER_FN = None


def _fetch(url, limit=MAX_DOWNLOAD):
    req = urllib.request.Request(url, headers={"User-Agent": "OpenMinis-cloud-agent"})
    try:
        opener = OPENER_FN() if OPENER_FN else None
    except Exception:
        opener = None
    with (opener.open(req, timeout=120) if opener else urllib.request.urlopen(req, timeout=120)) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise DepsError(f"下载过大：{url}")
    return data


def _verify(data, expected, name):
    got = hashlib.sha256(data).hexdigest()
    if not expected or got.lower() != expected.lower():
        raise DepsError(f"{name} 校验和不匹配，已放弃安装（期望 {expected}，实际 {got}）")


def _extract(data, dest, mode):
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    with tarfile.open(fileobj=io.BytesIO(data), mode=mode) as tf:
        if hasattr(tarfile, "data_filter"):
            tf.extractall(dest, filter="data")
        else:
            for m in tf.getmembers():
                target = os.path.realpath(os.path.join(dest, m.name))
                if not target.startswith(os.path.realpath(dest) + os.sep) or m.isdev():
                    raise DepsError(f"压缩包含有不安全路径：{m.name}")
            tf.extractall(dest)


def _link(src, name):
    os.makedirs(bin_dir(), exist_ok=True)
    dst = os.path.join(bin_dir(), name)
    if os.path.lexists(dst):
        os.remove(dst)
    os.symlink(src, dst)


def _try_sources(log, attempts):
    """依次尝试 [(说明, 函数)]，返回第一个成功的结果；全部失败时汇总报错。校验和不匹配不换源重试以外的处理。"""
    errors = []
    for label, fn in attempts:
        try:
            return fn()
        except Exception as e:
            msg = f"{label}：{type(e).__name__}: {e}"[:300]
            errors.append(msg)
            log("失败，换下一个下载源 — " + msg)
    raise DepsError("所有下载源都失败：" + "；".join(errors))


def install_node(log):
    return _try_sources(log, [(base, (lambda b=base: _install_node_from(b, log))) for base in [NODE_DIST] + NODE_MIRRORS])


def _install_node_from(dist, log):
    arch = _arch("node")
    sums = _fetch(f"{dist}/SHASUMS256.txt", 1024 * 1024).decode()
    entry = next((line.split() for line in sums.splitlines() if line.endswith(f"-linux-{arch}.tar.gz")), None)
    if not entry:
        raise DepsError("SHASUMS256.txt 中找不到适用于本机的 Node.js 包")
    expected, fname = entry[0], entry[-1]
    log(f"下载 {dist}/{fname}")
    data = _fetch(f"{dist}/{fname}")
    _verify(data, expected, fname)
    dest = os.path.join(PREFIX, "lib", "openminis-node")
    _extract(data, dest, "r:gz")
    root = os.path.join(dest, fname[:-len(".tar.gz")])
    for e in TOOLS["node"]["provides"]:
        p = os.path.join(root, "bin", e)
        if not os.path.lexists(p):
            raise DepsError(f"Node.js 包缺少 bin/{e}")
        _link(p, e)


def install_uv(log):
    attempts = [(UV_DIST, lambda: _install_uv_github(log))]
    attempts += [(idx, (lambda i=idx: _install_uv_wheel(i, log))) for idx in PYPI_INDEXES]
    return _try_sources(log, attempts)


def _version_key(v):
    return tuple(int(x) for x in v.split("."))


def _install_uv_wheel(index, log):
    """从 PyPI（或国内镜像）的 simple 索引取 uv 的 manylinux wheel；索引链接自带 sha256。"""
    arch = _arch("uv")
    page = _fetch(f"{index.rstrip('/')}/uv/", 8 * 1024 * 1024).decode("utf-8", "replace")
    pat = re.compile(r'href="([^"]*/uv-(\d+\.\d+\.\d+)-py3-none-[^"]*manylinux[^"]*_' + arch + r'\.whl)#sha256=([0-9a-f]{64})"')
    found = [(m.group(2), m.group(1), m.group(3)) for m in pat.finditer(page)]
    if not found:
        raise DepsError("索引中找不到适用于本机的 uv wheel")
    version, href, expected = max(found, key=lambda f: _version_key(f[0]))
    url = urllib.parse.urljoin(f"{index.rstrip('/')}/uv/", href)
    log(f"下载 uv {version} wheel（{index}）")
    data = _fetch(url)
    _verify(data, expected, f"uv-{version}.whl")
    dest = os.path.join(PREFIX, "lib", "openminis-uv")
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        for e in TOOLS["uv"]["provides"]:
            member = f"uv-{version}.data/scripts/{e}"
            try:
                body = zf.read(member)
            except KeyError:
                raise DepsError(f"uv wheel 缺少 {member}")
            p = os.path.join(dest, e)
            with open(p, "wb") as f:
                f.write(body)
            os.chmod(p, 0o755)
            _link(p, e)


def _install_uv_github(log):
    arch = _arch("uv")
    fname = f"uv-{arch}-unknown-linux-gnu.tar.gz"
    expected = _fetch(f"{UV_DIST}/{fname}.sha256", 4096).decode().split()[0]
    log(f"下载 {fname}")
    data = _fetch(f"{UV_DIST}/{fname}")
    _verify(data, expected, fname)
    dest = os.path.join(PREFIX, "lib", "openminis-uv")
    _extract(data, dest, "r:gz")
    root = os.path.join(dest, fname[:-len(".tar.gz")])
    for e in TOOLS["uv"]["provides"]:
        p = os.path.join(root, e)
        if not os.path.exists(p):
            raise DepsError(f"uv 包缺少 {e}")
        os.chmod(p, 0o755)
        _link(p, e)


INSTALLERS = {"node": install_node, "uv": install_uv}


def start_install(tool, on_done=None):
    """后台安装；返回任务状态。同一工具已在安装中则直接返回该任务。"""
    if tool not in TOOLS:
        raise DepsError(f"未知依赖：{tool}")
    with _lock:
        job = _jobs.get(tool)
        if job and job["status"] == "running":
            return dict(job)
        job = {"tool": tool, "status": "running", "log": [], "started_at": time.time(), "finished_at": None, "error": None}
        _jobs[tool] = job

    def log(msg):
        with _lock:
            job["log"].append(msg)

    def run():
        try:
            INSTALLERS[tool](log)
            ensure_path()
            missing = [e for e in TOOLS[tool]["provides"] if not shutil.which(e)]
            if missing:
                raise DepsError("安装后仍找不到：" + ", ".join(missing))
            log("安装完成")
            final = ("succeeded", None)
        except Exception as e:
            final = ("failed", str(e))
        with _lock:
            job["status"], job["error"] = final
            job["finished_at"] = time.time()
        if on_done:
            try:
                on_done(tool, final[0])
            except Exception:
                pass

    threading.Thread(target=run, daemon=True, name=f"deps-{tool}").start()
    with _lock:
        return dict(job)


ensure_path()
