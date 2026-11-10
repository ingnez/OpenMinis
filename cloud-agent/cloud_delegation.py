"""Bot 之间的消息与委托：记录表、每对 Bot 的频率限制、层数（hop）和标记文本。

服务端在 cloud_agent_server 里调用这些纯函数；这里不碰模型和网络，方便单独测试。
"""
import threading
import time
from collections import deque

SCHEMA = """
CREATE TABLE IF NOT EXISTS bot_delegations (
    delegation_id TEXT PRIMARY KEY,
    kind TEXT,               -- message / task
    from_bot TEXT,
    to_bot TEXT,
    from_session TEXT,
    from_task TEXT,
    to_session TEXT,
    to_task TEXT,
    content TEXT,
    priority TEXT,
    report_back INTEGER,
    hop INTEGER,
    root_id TEXT,
    status TEXT,             -- running / completed / failed / cancelled / limit_reached
    result TEXT,
    reported INTEGER DEFAULT 0,
    created_at REAL,
    finished_at REAL
)
"""

# 给目标 Bot 的消息、回给请求方的结果都以这些标记开头，App 据此画成卡片
FROM_MARK = "【来自 {name}·{kind}】"
RESULT_MARK = "【{name} 的委托结果·{status}】"
KIND_LABEL = {"message": "消息", "task": "委托"}
STATUS_LABEL = {"completed": "已完成", "failed": "失败", "cancelled": "已取消", "limit_reached": "达到上限",
                "interrupted": "中断", "running": "进行中"}


class LimitError(Exception):
    pass


class PairLimiter:
    """同一对 (from, to) 在 window 秒内最多 limit 次；limit=0 不限。"""

    def __init__(self, window=600):
        self.window = window
        self.lock = threading.Lock()
        self.hits = {}

    def check_and_add(self, a, b, limit, now=None):
        if not limit:
            return
        now = time.time() if now is None else now
        with self.lock:
            q = self.hits.setdefault((a, b), deque())
            while q and now - q[0] > self.window:
                q.popleft()
            if len(q) >= limit:
                wait = int(self.window - (now - q[0])) + 1
                raise LimitError(f"{a or '主助手'} → {b} 委托太频繁（每 {self.window // 60} 分钟最多 {limit} 次），约 {wait} 秒后再试")
            q.append(now)


def check_hop(hop, max_hops):
    """hop 是新任务所在层数（用户直接发起的任务是 0，第一次委托是 1）。"""
    if max_hops <= 0:
        raise LimitError("资源设置里已关闭 Bot 之间的委托")
    if hop > max_hops:
        raise LimitError(f"委托层数已达上限 {max_hops}：请直接完成或把结果交回给用户")


def incoming_text(from_name, kind, body, delegation_id, report_back):
    head = FROM_MARK.format(name=from_name, kind=KIND_LABEL.get(kind, kind))
    tail = ""
    if kind == "task":
        tail = (f"\n\n（委托编号 {delegation_id}。请在你自己的工作区完成，最后一条回复写清结果；"
                + ("结果会自动转交给对方。）" if report_back else "对方不需要回报。）"))
    return f"{head}\n{body.strip()}{tail}"


def result_text(to_name, status, result):
    head = RESULT_MARK.format(name=to_name, status=STATUS_LABEL.get(status, status))
    return f"{head}\n{(result or '（没有文字结果）').strip()}"


def parse_mark(content):
    """App / 测试用：识别标记，返回 (type, name, label) 或 None。"""
    if not isinstance(content, str) or not content.startswith("【"):
        return None
    end = content.find("】")
    if end < 0:
        return None
    inner = content[1:end]
    if inner.startswith("来自 ") and "·" in inner:
        name, label = inner[3:].rsplit("·", 1)
        return ("incoming", name, label)
    if " 的委托结果·" in inner:
        name, label = inner.split(" 的委托结果·", 1)
        return ("result", name, label)
    return None
