"""事件触发：不是按时间，而是「有事发生」时运行一个例行任务。
- github：轮询公开仓库（或带只读 token 的私有仓库）的事件流，新的 issues / PR / push / release 触发
- email：IMAP 轮询收件箱的未读邮件，按发件人 / 主题过滤，新邮件触发（密码加密存在 secure_settings）
- telegram：Telegram 渠道收到包含关键词的消息时触发
触发时把事件摘要（打码、截短）作为「上一步的结果」交给例行任务，由绑定的 Bot 去处理。
网络请求通过可替换的 fetch 函数完成，测试里换成假的。"""
import email
import email.header
import imaplib
import json
import re
import time
import urllib.request
import uuid

KINDS = ("github", "email", "telegram")
GITHUB_EVENTS = {"issues": "IssuesEvent", "pull_request": "PullRequestEvent", "push": "PushEvent",
                 "release": "ReleaseEvent", "issue_comment": "IssueCommentEvent"}
POLL_SECONDS = 300
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]{1,39}/[A-Za-z0-9_.-]{1,100}$")
HOST_RE = re.compile(r"^[A-Za-z0-9.-]{3,253}$")


def ensure_schema(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS event_triggers (id TEXT PRIMARY KEY, kind TEXT NOT NULL, config TEXT NOT NULL, "
                 "routine_id TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, cursor TEXT NOT NULL DEFAULT '', "
                 "last_poll REAL NOT NULL DEFAULT 0, last_fired REAL NOT NULL DEFAULT 0, fired_count INTEGER NOT NULL DEFAULT 0, "
                 "last_error TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL)")


def validate(kind, cfg):
    """返回 (公开配置, 秘密)；秘密（token / 密码）单独加密保存，不进 config"""
    if kind not in KINDS or not isinstance(cfg, dict):
        raise ValueError("kind 只能是 github / email / telegram")
    secret = None
    if kind == "github":
        repo = cfg.get("repo") or ""
        events = cfg.get("events") or ["issues", "pull_request", "release"]
        if not REPO_RE.match(repo) or not isinstance(events, list) or not events or any(e not in GITHUB_EVENTS for e in events):
            raise ValueError("github 需要 repo（owner/name）和 events（issues / pull_request / push / release / issue_comment）")
        out = {"repo": repo, "events": sorted(set(events))}
        secret = cfg.get("token") or None
    elif kind == "email":
        host, user = cfg.get("host") or "", cfg.get("user") or ""
        if not HOST_RE.match(host) or not isinstance(user, str) or not (0 < len(user) <= 200):
            raise ValueError("email 需要 IMAP host 和 user")
        out = {"host": host, "user": user, "folder": str(cfg.get("folder") or "INBOX")[:100],
               "from": str(cfg.get("from") or "")[:200], "subject": str(cfg.get("subject") or "")[:200]}
        secret = cfg.get("password") or None
        if not secret and not cfg.get("_keep_secret"):
            raise ValueError("email 需要 password（授权码）")
    else:
        kw = [k.strip() for k in (cfg.get("keywords") or []) if isinstance(k, str) and k.strip()]
        if not kw or len(kw) > 10:
            raise ValueError("telegram 需要 1～10 个关键词")
        out = {"keywords": [k[:40] for k in kw]}
    return out, secret


def create(conn, kind, cfg, routine_id, now=None):
    tid = "evt_" + uuid.uuid4().hex[:10]
    conn.execute("INSERT INTO event_triggers (id, kind, config, routine_id, created_at) VALUES (?, ?, ?, ?, ?)",
                 (tid, kind, json.dumps(cfg, ensure_ascii=False), routine_id, now or time.time()))
    conn.commit()
    return tid


def _row(r):
    return {"id": r[0], "kind": r[1], "config": json.loads(r[2]), "routine_id": r[3], "enabled": bool(r[4]), "cursor": r[5],
            "last_poll": r[6], "last_fired": r[7], "fired_count": r[8], "last_error": r[9], "created_at": r[10]}


COLS = "id, kind, config, routine_id, enabled, cursor, last_poll, last_fired, fired_count, last_error, created_at"


def list_all(conn):
    return [_row(r) for r in conn.execute(f"SELECT {COLS} FROM event_triggers ORDER BY created_at DESC")]


def get(conn, tid):
    r = conn.execute(f"SELECT {COLS} FROM event_triggers WHERE id = ?", (tid,)).fetchone()
    return _row(r) if r else None


def delete(conn, tid):
    c = conn.execute("DELETE FROM event_triggers WHERE id = ?", (tid,))
    conn.commit()
    return c.rowcount > 0


def set_enabled(conn, tid, on):
    conn.execute("UPDATE event_triggers SET enabled = ? WHERE id = ?", (1 if on else 0, tid))
    conn.commit()


def mark(conn, tid, cursor=None, error=None, fired=0, now=None):
    now = now or time.time()
    sets, args = ["last_poll = ?", "last_error = ?"], [now, (error or "")[:200]]
    if cursor is not None:
        sets.append("cursor = ?")
        args.append(str(cursor))
    if fired:
        sets += ["last_fired = ?", "fired_count = fired_count + ?"]
        args += [now, fired]
    conn.execute(f"UPDATE event_triggers SET {', '.join(sets)} WHERE id = ?", args + [tid])
    conn.commit()


# ---------- GitHub ----------

def http_json(url, headers, timeout=15):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def github_summary(ev):
    t, p, actor = ev.get("type"), ev.get("payload") or {}, (ev.get("actor") or {}).get("login", "")
    if t == "IssuesEvent":
        i = p.get("issue") or {}
        return f"Issue #{i.get('number')} {p.get('action')}：{i.get('title')}（{actor}）\n{(i.get('body') or '')[:500]}\n{i.get('html_url', '')}"
    if t == "PullRequestEvent":
        pr = p.get("pull_request") or {}
        return f"PR #{pr.get('number')} {p.get('action')}：{pr.get('title')}（{actor}）\n{(pr.get('body') or '')[:500]}\n{pr.get('html_url', '')}"
    if t == "PushEvent":
        commits = p.get("commits") or []
        return f"{actor} 推送了 {len(commits)} 个提交到 {p.get('ref')}：\n" + "\n".join("· " + (c.get("message") or "").split("\n")[0][:100] for c in commits[:8])
    if t == "ReleaseEvent":
        r = p.get("release") or {}
        return f"发布 {r.get('tag_name')}：{r.get('name')}\n{(r.get('body') or '')[:500]}\n{r.get('html_url', '')}"
    if t == "IssueCommentEvent":
        i, c = p.get("issue") or {}, p.get("comment") or {}
        return f"#{i.get('number')} {i.get('title')} 有新评论（{actor}）：\n{(c.get('body') or '')[:500]}\n{c.get('html_url', '')}"
    return f"{t}（{actor}）"


def poll_github(trig, token=None, fetch=http_json):
    """返回 (新事件摘要列表（旧→新）, 新 cursor)。第一次只记下当前最新的事件 id，不触发（不把历史当新事件）"""
    cfg = trig["config"]
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "OpenMinis"}
    if token:
        headers["Authorization"] = "Bearer " + token
    events = fetch(f"https://api.github.com/repos/{cfg['repo']}/events?per_page=50", headers)
    wanted = {GITHUB_EVENTS[e] for e in cfg["events"]}
    ids = [int(e["id"]) for e in events if str(e.get("id", "")).isdigit()]
    if not ids:
        return [], trig["cursor"]
    newest = max(ids)
    if not trig["cursor"]:
        return [], str(newest)
    last = int(trig["cursor"])
    fresh = sorted((e for e in events if str(e.get("id", "")).isdigit() and int(e["id"]) > last and e.get("type") in wanted),
                   key=lambda e: int(e["id"]))
    return [f"[GitHub {cfg['repo']}] " + github_summary(e) for e in fresh], str(max(newest, last))


# ---------- 邮件 ----------

def _decode(v):
    try:
        return str(email.header.make_header(email.header.decode_header(v or "")))
    except Exception:
        return v or ""


def _body(msg):
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain" and not part.get_filename():
                return (part.get_payload(decode=True) or b"").decode(part.get_content_charset() or "utf-8", "replace")
        return ""
    return (msg.get_payload(decode=True) or b"").decode(msg.get_content_charset() or "utf-8", "replace")


def imap_fetch(cfg, password, since_uid):
    """返回 [(uid, raw bytes)]，只取 uid > since_uid 的；不改已读状态（BODY.PEEK）"""
    m = imaplib.IMAP4_SSL(cfg["host"], timeout=20)
    try:
        m.login(cfg["user"], password)
        m.select(cfg.get("folder") or "INBOX", readonly=True)
        typ, data = m.uid("search", None, f"UID {since_uid + 1}:*")
        uids = [int(x) for x in (data[0] or b"").split() if int(x) > since_uid][-20:]
        out = []
        for u in uids:
            typ, d = m.uid("fetch", str(u), "(BODY.PEEK[])")
            if d and isinstance(d[0], tuple):
                out.append((u, d[0][1]))
        return out
    finally:
        try:
            m.logout()
        except Exception:
            pass


def poll_email(trig, password, fetch=imap_fetch):
    cfg = trig["config"]
    since = int(trig["cursor"] or 0)
    msgs = fetch(cfg, password, since)
    if not msgs:
        return [], trig["cursor"]
    newest = max(u for u, _ in msgs)
    if not trig["cursor"]:
        return [], str(newest)      # 第一次：只记位置，不把旧邮件当新邮件
    out = []
    for uid, raw in sorted(msgs):
        msg = email.message_from_bytes(raw)
        frm, subj = _decode(msg.get("From")), _decode(msg.get("Subject"))
        if cfg.get("from") and cfg["from"].lower() not in frm.lower():
            continue
        if cfg.get("subject") and cfg["subject"].lower() not in subj.lower():
            continue
        out.append(f"[新邮件] 发件人：{frm}\n主题：{subj}\n{' '.join(_body(msg).split())[:800]}")
    return out, str(newest)


def telegram_matches(trig, text):
    t = (text or "").lower()
    return any(k.lower() in t for k in trig["config"].get("keywords") or [])
