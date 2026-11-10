"""手动检查：用 git 里旧版本的服务器生成数据，再用当前代码启动同一份数据，核对主要接口不出 5xx。
用法：python3 scripts/check_server_upgrade.py <旧提交> [<旧提交> ...]（需要完整 git 历史）"""
import json, os, subprocess, sys, tempfile, time, urllib.request, shutil, base64, secrets
REPO = "/workspace/OpenMinis"
TOKEN = "t" * 64

def export(commit, dest):
    os.makedirs(dest, exist_ok=True)
    tar = subprocess.run(["git", "-C", REPO, "archive", commit, "cloud-agent"], capture_output=True, check=True).stdout
    subprocess.run(["tar", "-x", "-C", dest, "--strip-components=1"], input=tar, check=True)

def req(port, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method,
                               headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}

def start(code_dir, state, port):
    env = dict(os.environ, OPENMINIS_HOST="127.0.0.1", OPENMINIS_PORT=str(port),
               OPENMINIS_DB=f"{state}/data/openminis_agent.db", OPENMINIS_WORKSPACE=f"{state}/workspace",
               OPENMINIS_TOKEN_FILE=f"{state}/token", OPENMINIS_MASTER_KEY_FILE=f"{state}/master.key")
    log = open(f"{state}/server-{os.path.basename(code_dir)}.log", "w")
    p = subprocess.Popen([sys.executable, f"{code_dir}/cloud_agent_server.py"], cwd=state, env=env, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(60):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
                return p, json.loads(r.read())
        except Exception:
            if p.poll() is not None: break
            time.sleep(0.5)
    p.kill(); raise SystemExit(f"server {code_dir} failed to start; log:\n" + open(log.name).read()[-3000:])

def stop(p):
    p.terminate()
    try: p.wait(10)
    except Exception: p.kill()

def run(old_commit):
    root = tempfile.mkdtemp(prefix="upg-")
    state = f"{root}/state"
    for d in ("data", "workspace"): os.makedirs(f"{state}/{d}")
    open(f"{state}/token", "w").write(TOKEN); os.chmod(f"{state}/token", 0o600)
    open(f"{state}/master.key", "w").write(base64.b64encode(secrets.token_bytes(32)).decode()); os.chmod(f"{state}/master.key", 0o600)
    export(old_commit, f"{root}/old"); export("HEAD", f"{root}/new")
    port = 19000 + secrets.randbelow(500)
    p, h = start(f"{root}/old", state, port)
    sid = req(port, "POST", "/v1/sessions", {"title": "旧会话"})[1].get("session_id")
    req(port, "PUT", "/v1/bots/oldbot", {"name": "旧Bot", "instructions": "x"})
    sid2 = req(port, "POST", "/v1/sessions", {"title": "bot 会话", "persona_id": "oldbot"})[1].get("session_id")
    req(port, "POST", "/v1/routines", {"name": "r", "prompt": "p", "schedule": "every 1d", "enabled": False})
    req(port, "PUT", "/v1/resources", {"bark_url": ""})
    stop(p)
    p, h2 = start(f"{root}/new", state, port)
    problems = []
    checks = [("GET", "/v1/sessions"), ("GET", f"/v1/sessions/{sid}"), ("GET", "/v1/bots"), ("GET", "/v1/bots/oldbot"),
              ("GET", "/v1/bots/oldbot/library"), ("GET", "/v1/routines"), ("GET", "/v1/resources"),
              ("GET", "/v1/search?q=%E6%97%A7"), ("GET", "/v1/notifications?after=0&wait=0"), ("GET", "/v1/groups"),
              ("GET", "/v1/usage"), ("GET", "/v1/audit"), ("GET", "/v1/feed")]
    for m, path in checks:
        st, body = req(port, m, path)
        if st >= 500 or (st == 404 and path in ("/v1/sessions", "/v1/bots")):
            problems.append(f"{m} {path} -> {st} {str(body)[:200]}")
    st, body = req(port, "POST", f"/v1/sessions/{sid2}/transcript", {"lines": [{"role": "user", "text": "升级后"}]})
    if st != 200: problems.append(f"transcript -> {st} {body}")
    has_bot = req(port, "GET", "/v1/bots/oldbot")[0] == 200
    st, body = req(port, "POST", "/v1/sessions", {"title": "无痕", "persona_id": "oldbot", "incognito": True} if has_bot else {"title": "无痕", "incognito": True})
    if st >= 400: problems.append(f"incognito -> {st} {body}")
    stop(p)
    log = open(f"{state}/server-new.log").read()
    tb = [l for l in log.splitlines() if "Traceback" in l or "OperationalError" in l or "no such column" in l]
    print(f"{old_commit} ({h.get('agent_version', h.get('version','?'))}) -> HEAD ({h2.get('agent_version')}): " + ("OK" if not problems and not tb else "PROBLEMS"))
    for x in problems: print("   ", x)
    if tb:
        print("    log:", "\n".join(log.splitlines()[-40:]))
    shutil.rmtree(root, ignore_errors=True)
    return not problems and not tb

ok = all([run(c) for c in sys.argv[1:]])
sys.exit(0 if ok else 1)
