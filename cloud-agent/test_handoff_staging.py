#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""交接暂存（POST /v1/handoff/files → /v1/handoff 里带 staging_id）的回归测试。

用法（在 cloud-agent 目录里，且已打好 handoff-files-staging.patch）：
    python3 test_handoff_staging.py
自建临时 DB + 随机端口，跑完即退；退出码非 0 = 有用例失败。
"""
import hashlib
import io
import os
import socket
import sys
import tempfile
import threading
import time
import json
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp()
PORT = 18896
TOKEN = "handoff-staging-test-token"
SID = "sess_abcdef123456"

os.environ["OPENMINIS_DB"] = os.path.join(TMP, "t.db")
os.environ["OPENMINIS_TOKEN"] = TOKEN
os.environ["OPENMINIS_PORT"] = str(PORT)
sys.path.insert(0, HERE)

import cloud_agent_server as S  # noqa: E402
import cloud_handoff as H  # noqa: E402

S.SERVER_TOKEN = TOKEN
try:
    S.init_db()
except Exception:
    pass

conn = S.get_db_connection()
cols = [r[1] for r in conn.execute("PRAGMA table_info(sessions)").fetchall()]
vals = [SID if c == "session_id" else ("_default" if c == "persona_id" else None) for c in cols]
conn.execute(f"INSERT OR IGNORE INTO sessions ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", vals)
conn.commit()
conn.close()

failures = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (("  — " + str(detail)) if detail and not cond else ""))
    if not cond:
        failures.append(name)


# 1) 协议层：clean() 接受 staging_id，也仍然接受 data_base64
fields, files = H.clean({"goal": "装个 ipa", "files": [
    {"filename": "Small.txt", "data_base64": "aGVsbG8="},
    {"filename": "Big.ipa", "staging_id": "hf_0123456789ab"},
]})
check("clean() accepts inline + staged", len(files) == 2, files)
for bad in ({"filename": "x.ipa"}, {"staging_id": "hf_0123456789ab"},
            {"filename": "x", "data_base64": 1, "staging_id": 2}):
    try:
        H.clean({"goal": "g", "files": [bad]})
        check("clean() rejects %s" % bad, False)
    except H.HandoffError:
        check("clean() rejects %s" % bad, True)

# 2) HTTP 暂存
from http.server import ThreadingHTTPServer  # noqa: E402

srv = ThreadingHTTPServer(("127.0.0.1", PORT), S.Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(0.4)


def post_raw(path, data, token=TOKEN):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path), data=data, method="POST",
                                 headers={"Authorization": "Bearer " + token,
                                          "Content-Type": "application/octet-stream",
                                          "Content-Length": str(len(data))})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


payload = os.urandom(5 * 1024 * 1024)
status, body = post_raw("/v1/handoff/files?filename=Big.ipa", payload)
staging_id = body.get("staging_id", "")
check("staging upload 200", status == 200, body)
check("staging_id shape", staging_id.startswith("hf_") and len(staging_id) == 15, staging_id)
check("reports bytes", body.get("bytes") == len(payload), body)
check("401 on bad token", post_raw("/v1/handoff/files?filename=a.ipa", b"x", token="nope")[0] == 401)
check("400 without filename", post_raw("/v1/handoff/files", b"x")[0] == 400)

# 3) 取走 + 搬进工作区
path, name = S.handoff_staging_take(staging_id)
check("take returns path + name", os.path.exists(path) and name == "Big.ipa", (path, name))
check("sidecar .name removed", not os.path.exists(path + ".name"))
digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
rec = S.save_upload_from_path(SID, name, path)
target, err = S.safe_path_resolve(SID, rec["file_path"])
check("moved into workspace", os.path.exists(target) and os.path.getsize(target) == len(payload), rec)
check("content intact", os.path.exists(target) and hashlib.sha256(open(target, "rb").read()).hexdigest() == digest)
check("staging copy gone", not os.path.exists(path))
try:
    S.handoff_staging_take(staging_id)
    check("taking twice fails", False)
except ValueError as e:
    check("taking twice fails", "不在了" in str(e), e)
try:
    S.handoff_staging_take("../../etc/passwd")
    check("bad staging id rejected", False)
except ValueError:
    check("bad staging id rejected", True)

# 4) 中途断开：不留残骸
d = S.handoff_staging_dir()
before = set(os.listdir(d))
s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
s.sendall(("POST /v1/handoff/files?filename=half.ipa HTTP/1.1\r\nHost: 127.0.0.1\r\n"
           "Authorization: Bearer %s\r\nContent-Length: 4000000\r\n\r\n" % TOKEN).encode() + b"x" * 100000)
s.close()
time.sleep(1.5)
left = set(os.listdir(d)) - before
check("aborted staging leaves nothing", not left, left)

srv.shutdown()
print()
print("FAILED: %d" % len(failures) if failures else "ALL PASS")
sys.exit(1 if failures else 0)
