"""群聊辩论与投票。
- 「/辩论 题目」：每个成员（最多 4 个）先各自亮观点 → 看完别人的观点各反驳一次 → 各投一票（不能投自己），系统贴出票数
- 「/投票 问题 | 选项A | 选项B …」：每个成员选一个选项并说一句理由，系统贴出票数
解析和计票是纯函数，方便测试；模型调用走群聊引擎的 llm hook。"""
import re

MAX_DEBATERS = 4


def parse_command(text):
    """返回 ("debate", 题目, []) / ("vote", 问题, [选项…]) / None"""
    t = (text or "").strip()
    m = re.match(r"^/(辩论|debate)\s+(.{2,300})$", t, re.S)
    if m:
        return ("debate", m.group(2).strip(), [])
    m = re.match(r"^/(投票|vote)\s+(.+)$", t, re.S)
    if m:
        parts = [p.strip() for p in re.split(r"[|｜]", m.group(2)) if p.strip()]
        if len(parts) >= 3:
            return ("vote", parts[0][:200], [p[:60] for p in parts[1:9]])
    return None


def parse_choice(text, options):
    """模型回复里选的是哪个：优先「选 N」/「投 N」编号，其次第一个出现的选项原文；都没有返回 None"""
    t = text or ""
    m = re.search(r"(?:选|投|choose|vote)\s*[:：]?\s*(\d{1,2})", t, re.I) or re.match(r"^\s*(\d{1,2})\b", t)
    if m and 1 <= int(m.group(1)) <= len(options):
        return int(m.group(1)) - 1
    hits = [(t.find(o), i) for i, o in enumerate(options) if o and o in t]
    return min(hits)[1] if hits else None


def tally(choices, options):
    """choices：[(投票者名, 选项下标或 None)]。返回结果文字"""
    counts = [0] * len(options)
    for _, c in choices:
        if c is not None:
            counts[c] += 1
    order = sorted(range(len(options)), key=lambda i: -counts[i])
    lines = [f"{options[i]}：{counts[i]} 票" for i in order]
    top = [i for i in order if counts[i] == counts[order[0]] and counts[i] > 0]
    if not top:
        head = "投票结果：没有有效票"
    elif len(top) > 1:
        head = "投票结果：平票（" + "、".join(options[i] for i in top) + "）"
    else:
        head = f"投票结果：「{options[top[0]]}」胜出"
    abst = [n for n, c in choices if c is None]
    return head + "\n" + "\n".join(lines) + (f"\n弃权 / 没看懂：{'、'.join(abst)}" if abst else "")


def opening_prompt(name, topic):
    return f"群里开始辩论，题目：「{topic}」。你是 {name}。用 3～5 句话亮出你的立场和最关键的理由，不要和稀泥。"


def rebuttal_prompt(name, topic, others):
    lines = "\n".join(f"- {n}：{t}" for n, t in others)
    return (f"辩论题目：「{topic}」。其他人的观点：\n{lines}\n\n你是 {name}。挑最站不住的一点反驳（2～4 句），"
            "如果被说服了可以直接承认并说明改变了什么看法。")


def vote_prompt(name, question, options, exclude=None):
    opts = "\n".join(f"{i + 1}. {o}" for i, o in enumerate(options))
    extra = f"不能投你自己（{exclude}）。" if exclude else ""
    return f"投票：{question}\n{opts}\n\n你是 {name}。{extra}第一行只写「选 N」，第二行用一句话说理由。"
