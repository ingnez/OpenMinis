"""改系统之前自动拍快照：Bot 要跑 apt / pip / npm -g / systemctl 这类系统级命令前，先记下已装的软件包、
pip 包、全局 npm 包、开机自启的服务，并把 /etc 打包（只要文本配置，上限 MAX_ETC）。
之后可以对比现在和快照的差别，得到回滚计划（卸掉新装的包、恢复改过的 /etc 文件、恢复服务开关），确认后执行。
短时间内连续多条系统命令只拍一次（BUNDLE 秒内复用上一份）。只保留最近 KEEP 份。"""
import io
import json
import os
import shlex
import subprocess
import tarfile
import time

KEEP = 10
BUNDLE = 600
MAX_ETC = 30 * 1024 * 1024
MAX_FILE = 512 * 1024

PROBES = {
    "apt": "dpkg-query -W -f='${Package}=${Version}\\n'",
    "pip": "python3 -m pip freeze --all --disable-pip-version-check",
    "npm": "npm ls -g --depth=0 --json",
    "units": "systemctl list-unit-files --state=enabled --no-legend --plain",
}


def default_run(cmd, timeout=25):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except Exception:
        return 1, ""


def parse(kind, text):
    out = {}
    if kind == "apt" or kind == "pip":
        for line in (text or "").splitlines():
            sep = "==" if kind == "pip" else "="
            if sep in line:
                k, v = line.split(sep, 1)
                out[k.strip()] = v.strip()
    elif kind == "npm":
        try:
            deps = (json.loads(text or "{}").get("dependencies") or {})
            out = {k: (v or {}).get("version", "") for k, v in deps.items()}
        except ValueError:
            pass
    elif kind == "units":
        for line in (text or "").splitlines():
            parts = line.split()
            if parts:
                out[parts[0]] = parts[1] if len(parts) > 1 else "enabled"
    return out


def _etc_tar(root, dest):
    size = 0
    with tarfile.open(dest, "w:gz") as tar:
        for base, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(base, d))]
            for f in files:
                p = os.path.join(base, f)
                try:
                    if os.path.islink(p) or not os.path.isfile(p) or os.path.getsize(p) > MAX_FILE:
                        continue
                    size += os.path.getsize(p)
                    if size > MAX_ETC:
                        return False
                    tar.add(p, arcname=os.path.relpath(p, root))
                except OSError:
                    continue
    return True


def take(store, reason, run=default_run, etc_root="/etc", now=None):
    """拍一份快照；BUNDLE 秒内已有快照就复用。返回快照 id。"""
    now = now or time.time()
    os.makedirs(store, exist_ok=True)
    existing = list_all(store)
    if existing and now - existing[0]["created_at"] < BUNDLE:
        return existing[0]["id"]
    sid = time.strftime("%Y%m%d-%H%M%S", time.localtime(now)) + f"-{int(now * 1000) % 1000:03d}"
    d = os.path.join(store, sid)
    os.makedirs(d, exist_ok=True)
    state = {}
    for kind, cmd in PROBES.items():
        rc, text = run(cmd)
        state[kind] = parse(kind, text) if rc == 0 else None
    etc_ok = os.path.isdir(etc_root) and _etc_tar(etc_root, os.path.join(d, "etc.tar.gz"))
    meta = {"id": sid, "created_at": now, "reason": reason[:200], "etc": bool(etc_ok), "etc_root": etc_root,
            "counts": {k: (len(v) if v is not None else None) for k, v in state.items()}}
    with open(os.path.join(d, "state.json"), "w", encoding="utf-8") as f:
        json.dump({"meta": meta, "state": state}, f, ensure_ascii=False)
    for old in list_all(store)[KEEP:]:
        _remove(os.path.join(store, old["id"]))
    return sid


def _remove(path):
    for base, dirs, files in os.walk(path, topdown=False):
        for f in files:
            os.remove(os.path.join(base, f))
        for x in dirs:
            os.rmdir(os.path.join(base, x))
    os.rmdir(path)


def list_all(store):
    out = []
    if not os.path.isdir(store):
        return out
    for sid in os.listdir(store):
        try:
            with open(os.path.join(store, sid, "state.json"), encoding="utf-8") as f:
                out.append(json.load(f)["meta"])
        except (OSError, ValueError, KeyError):
            continue
    return sorted(out, key=lambda m: m["created_at"], reverse=True)


def load(store, sid):
    if not sid or "/" in sid or ".." in sid:
        return None
    try:
        with open(os.path.join(store, sid, "state.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _etc_changes(store, sid, etc_root):
    path = os.path.join(store, sid, "etc.tar.gz")
    changed = []
    if not os.path.exists(path):
        return changed
    with tarfile.open(path, "r:gz") as tar:
        for m in tar.getmembers():
            if not m.isfile():
                continue
            cur = os.path.join(etc_root, m.name)
            old = tar.extractfile(m).read()
            try:
                with open(cur, "rb") as f:
                    if f.read() == old:
                        continue
            except OSError:
                pass
            changed.append(m.name)
    return changed


def plan(store, sid, run=default_run):
    """对比快照和现在：返回回滚计划（不执行）"""
    snap = load(store, sid)
    if not snap:
        return None
    old, meta = snap["state"], snap["meta"]
    steps, summary = [], []
    for kind, cmd in PROBES.items():
        if old.get(kind) is None:
            continue
        rc, text = run(cmd)
        if rc != 0:
            continue
        now_state = parse(kind, text)
        added = sorted(set(now_state) - set(old[kind]))
        if kind == "units":
            if added:
                steps.append("systemctl disable " + " ".join(shlex.quote(u) for u in added))
            gone = sorted(set(old[kind]) - set(now_state))
            if gone:
                steps.append("systemctl enable " + " ".join(shlex.quote(u) for u in gone))
            if added or gone:
                summary.append(f"开机自启：新开 {len(added)} 个、关掉 {len(gone)} 个")
            continue
        if not added:
            continue
        q = " ".join(shlex.quote(a) for a in added[:200])
        steps.append({"apt": "apt-get remove -y " + q, "pip": "python3 -m pip uninstall -y " + q, "npm": "npm rm -g " + q}[kind])
        summary.append(f"{ {'apt': '系统软件包', 'pip': 'pip 包', 'npm': '全局 npm 包'}[kind] } 新装 {len(added)} 个：" + "、".join(added[:6])
                       + ("…" if len(added) > 6 else ""))
    etc = _etc_changes(store, sid, meta.get("etc_root") or "/etc") if meta.get("etc") else []
    if etc:
        summary.append(f"/etc 改动 {len(etc)} 个文件：" + "、".join(etc[:6]) + ("…" if len(etc) > 6 else ""))
    return {"id": sid, "created_at": meta["created_at"], "reason": meta["reason"], "steps": steps, "etc_files": etc,
            "summary": summary or ["和快照相比没有变化"]}


def restore(store, sid, run=default_run):
    """按回滚计划执行：先恢复 /etc 里改过的文件，再卸包、恢复服务开关。返回每一步的结果。"""
    p = plan(store, sid, run)
    if p is None:
        return None
    results = []
    meta = load(store, sid)["meta"]
    root = meta.get("etc_root") or "/etc"
    if p["etc_files"]:
        with tarfile.open(os.path.join(store, sid, "etc.tar.gz"), "r:gz") as tar:
            for name in p["etc_files"]:
                m = tar.getmember(name)
                dest = os.path.join(root, name)
                if not os.path.realpath(dest).startswith(os.path.realpath(root) + os.sep):
                    continue
                try:
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    with open(dest, "wb") as f:
                        f.write(tar.extractfile(m).read())
                    os.chmod(dest, m.mode)
                    results.append({"step": "恢复 /etc/" + name, "ok": True})
                except OSError as e:
                    results.append({"step": "恢复 /etc/" + name, "ok": False, "error": type(e).__name__})
    for step in p["steps"]:
        rc, out = run(step, timeout=600)
        results.append({"step": step, "ok": rc == 0, "output": (out or "")[-400:]})
    return {"plan": p, "results": results, "ok": all(r["ok"] for r in results)}
