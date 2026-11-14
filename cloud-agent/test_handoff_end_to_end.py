#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""交接端到端（打桩 Bot / 模型 / 任务线程）：暂存 30MB ipa → /v1/handoff 带
staging_id → 文件落进会话工作区、消息里列出路径。

用法（在 cloud-agent 目录里，且已打好 handoff-files-staging.patch）：
    python3 test_handoff_end_to_end.py
打桩的只有 Bot 查询 / 模型解析 / 会话创建 / agent 线程；文件落盘和数据库写入都是真的。
"""
import os, sys, json, tempfile, threading, time, hashlib
tmp = tempfile.mkdtemp()
os.environ["OPENMINIS_DB"] = os.path.join(tmp, "t.db")
os.environ["OPENMINIS_TOKEN"] = "testtoken123"
os.environ["OPENMINIS_PORT"] = "18887"
sys.path.insert(0, os.path.abspath("."))
import cloud_agent_server as S
S.SERVER_TOKEN = "testtoken123"
import cloud_handoff as H
try:
    S.init_db()
except Exception:
    pass

failures = []
def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("" if cond else f"  — {detail}"))
    if not cond: failures.append(name)

SID = "sess_abcdef123456"

def insert_session(sid, title="交接测试"):
    conn = S.get_db_connection()
    cols = [r[1] for r in conn.execute("PRAGMA table_info(sessions)").fetchall()]
    vals = []
    for c in cols:
        if c == "session_id": vals.append(sid)
        elif c == "persona_id": vals.append("medbot")
        elif c == "title": vals.append(title)
        elif c == "created_at": vals.append(time.time())
        else: vals.append(None)
    conn.execute(f"INSERT OR IGNORE INTO sessions ({','.join(cols)}) VALUES ({','.join('?'*len(cols))})", vals)
    conn.commit(); conn.close()

insert_session(SID)

# --- 打桩：Bot / 模型 / 会话创建 / 任务线程 ------------------------------------
S.get_persona = lambda bid: {"id": bid, "name": "医助", "model": "gpt-test", "credential": "cred_x"} if bid == "medbot" else None
S.resolve_provider = lambda req: ({"protocol": "openai"}, "ok", None)
S._handoff_session = lambda bid, title: SID
S.run_agent_task = lambda *a, **k: None
S.log_event = lambda *a, **k: None

# --- 暂存一个 30MB 的文件（超过 20MB 内联上限） --------------------------------
payload = os.urandom(30 * 1024 * 1024)
digest = hashlib.sha256(payload).hexdigest()
rec = S.handoff_staging_write(__import__("io").BytesIO(payload), len(payload), "本地应用.ipa")
staging_id = rec["staging_id"]
check("staged 30MB", rec["bytes"] == len(payload), rec)

out = S.start_handoff({
    "goal": "把这个 ipa 装到云电脑的模拟器里看看能不能起来",
    "summary": "本地已经解包过，结构正常",
    "remaining": "安装并检查启动日志",
    "target_bot": "medbot",
    "files": [
        {"filename": "Small.txt", "data_base64": "aGVsbG8="},
        {"filename": "本地应用.ipa", "staging_id": staging_id},
    ],
})
check("handoff returned receipt", out.get("session_id") == SID and out.get("bot_id") == "medbot", out)
check("both files reported", len(out.get("files", [])) == 2, out.get("files"))

# 文件真的到了会话工作区，内容一致
ipa_rel = [p for p in out["files"] if p.endswith(".ipa")][0]
target, err = S.safe_path_resolve(SID, ipa_rel)
check("ipa in workspace", os.path.exists(target), target)
check("ipa content intact", os.path.exists(target) and hashlib.sha256(open(target, "rb").read()).hexdigest() == digest)
check("staging slot consumed", not os.path.exists(os.path.join(S.handoff_staging_dir(), staging_id)))

# 交给 Bot 的那条消息里列出了文件路径
conn = S.get_db_connection()
row = conn.execute("SELECT content FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT 1", (SID,)).fetchone()
conn.close()
content = row[0] if row else ""
check("message lists the ipa path", ipa_rel in content, content[:300])
check("message keeps the goal", "模拟器" in content, content[:200])
check("message has no base64 blob", "data_base64" not in content and len(content) < 4000, len(content))

# 重用同一个 staging_id 会被拒（不能二次搬运）
try:
    S.start_handoff({"goal": "再交一次", "target_bot": "medbot", "files": [{"filename": "x.ipa", "staging_id": staging_id}]})
    check("reused staging_id rejected", False)
except H.HandoffError as e:
    check("reused staging_id rejected", "已经不在了" in str(e), e)

print()
print("FAILED: %d" % len(failures) if failures else "ALL PASS")
sys.exit(1 if failures else 0)
