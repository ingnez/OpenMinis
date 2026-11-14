#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""大附件原始字节流上传（PUT /v1/sessions/<sid>/upload/raw）的回归测试。

用法（在 cloud-agent 目录里，且已打好 big-file-upload.patch）：
    python3 test_raw_upload.py
不依赖外部服务：自己起一个临时 DB + 随机端口的服务，跑完即退。退出码非 0 = 有用例失败。
"""
import hashlib
import json
import os
import socket
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp()
PORT = 18899
TOKEN = "raw-upload-test-token"
SID = "sess_abcdef123456"

os.environ["OPENMINIS_DB"] = os.path.join(TMP, "t.db")
os.environ["OPENMINIS_TOKEN"] = TOKEN
os.environ["OPENMINIS_PORT"] = str(PORT)
sys.path.insert(0, HERE)

import cloud_agent_server as S  # noqa: E402

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

from http.server import ThreadingHTTPServer  # noqa: E402

srv = ThreadingHTTPServer(("127.0.0.1", PORT), S.Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(0.4)

failures = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (("  — " + str(detail)) if detail and not cond else ""))
    if not cond:
        failures.append(name)


def request(method, path, data=b"", token=TOKEN, ctype="application/octet-stream", headers=None):
    h = {"Authorization": "Bearer " + token, "Content-Type": ctype}
    if headers:
        h.update(headers)
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path), data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def workspace_file(rel):
    target, err = S.safe_path_resolve(SID, rel)
    return target if not err and target and os.path.exists(target) else None


# 1) 80MB（超过 24MB base64 上限）能传上去，字节一致
big = os.path.join(TMP, "Big.ipa")
with open(big, "wb") as f:
    f.write(b"PK\x03\x04")
    for _ in range(80):
        f.write(os.urandom(1024 * 1024))
size = os.path.getsize(big)
digest = hashlib.sha256(open(big, "rb").read()).hexdigest()
t0 = time.time()
status, body = request("PUT", "/v1/sessions/%s/upload/raw?filename=Big.ipa" % SID, open(big, "rb").read(),
                       headers={"Content-Length": str(size)})
check("80MB raw upload 200", status == 200, body)
check("receipt keeps the json shape",
      isinstance(body.get("file_path"), str) and body.get("bytes") == size and "attachment_url" in body, body)
saved = workspace_file(body.get("file_path", ""))
check("file on disk", saved is not None)
check("size matches", saved and os.path.getsize(saved) == size)
check("sha256 matches", saved and hashlib.sha256(open(saved, "rb").read()).hexdigest() == digest)
print("      (%.2fs)" % (time.time() - t0))

# 2) 没有 .part 残留
att_dir, _ = S.safe_path_resolve(SID, "attachments")
check("no .part left behind", not [n for n in os.listdir(att_dir) if n.endswith(".part")])

# 3) 鉴权 / 参数 / 会话
check("401 without a valid token", request("PUT", "/v1/sessions/%s/upload/raw?filename=a.ipa" % SID,
                                           b"x", token="nope")[0] == 401)
check("400 without filename", request("PUT", "/v1/sessions/%s/upload/raw" % SID, b"x")[0] == 400)
check("404 for an unknown session",
      request("PUT", "/v1/sessions/sess_ffffffffffff/upload/raw?filename=a.ipa", b"x")[0] == 404)

# 4) 声明比实发大（手机中途断开）：拒绝 + 不留残骸
s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
s.sendall(("PUT /v1/sessions/%s/upload/raw?filename=half.ipa HTTP/1.1\r\nHost: 127.0.0.1\r\n"
           "Authorization: Bearer %s\r\nContent-Length: 4000000\r\n\r\n" % (SID, TOKEN)).encode() + b"x" * 100000)
s.close()
time.sleep(1.5)
names = os.listdir(att_dir)
check("aborted upload leaves no file", not [n for n in names if "half" in n], names)
check("aborted upload leaves no .part", not [n for n in names if n.endswith(".part")], names)

# 5) 老接口（base64 JSON POST）没被改坏
status, body = request("POST", "/v1/sessions/%s/upload" % SID,
                       json.dumps({"filename": "x.txt", "data_base64": "aGVsbG8="}).encode(),
                       ctype="application/json")
check("legacy POST /upload still works", status == 200 and body.get("bytes") == 5, body)

srv.shutdown()
print()
print("FAILED: %d" % len(failures) if failures else "ALL PASS")
sys.exit(1 if failures else 0)
