# -*- coding: utf-8 -*-
"""随服务端发布的插件目录：公开 MCP 服务器与 OpenMinis 自带技能包。

MCP 条目只是安装说明，安装时才在 VPS 上通过 uvx / npx 拉取对应的开源包，或连接公开的
远程 MCP 端点；需要密钥的条目在填写密钥前处于 needs_auth 状态。
"""

import os
import shutil
import subprocess
import sys


CATALOG = [
    {
        "id": "fetch", "kind": "mcp", "name": "网页抓取 Fetch",
        "description": "抓取网页并转成 Markdown（Model Context Protocol 官方参考服务器 mcp-server-fetch）。",
        "homepage": "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch",
        "mcp": {"transport": "stdio", "command": "uvx", "args": ["mcp-server-fetch"]},
        "requires": ["uvx"],
    },
    {
        "id": "time", "kind": "mcp", "name": "时间与时区 Time",
        "description": "获取当前时间、时区换算（官方参考服务器 mcp-server-time）。",
        "homepage": "https://github.com/modelcontextprotocol/servers/tree/main/src/time",
        "mcp": {"transport": "stdio", "command": "uvx", "args": ["mcp-server-time"]},
        "requires": ["uvx"],
    },
    {
        "id": "memory-graph", "kind": "mcp", "name": "知识图谱记忆 Memory",
        "description": "基于本地知识图谱的实体/关系记忆（官方参考服务器 @modelcontextprotocol/server-memory）。",
        "homepage": "https://github.com/modelcontextprotocol/servers/tree/main/src/memory",
        "mcp": {"transport": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"]},
        "requires": ["npx"],
    },
    {
        "id": "sequential-thinking", "kind": "mcp", "name": "分步思考 Sequential Thinking",
        "description": "把复杂问题拆成可修订的思考步骤（官方参考服务器）。",
        "homepage": "https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking",
        "mcp": {"transport": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"]},
        "requires": ["npx"],
    },
    {
        "id": "filesystem", "kind": "mcp", "name": "插件文件区 Filesystem",
        "description": "在 VPS 的插件文件目录内读写文件（官方参考服务器，限制在 {plugin_dir} 内）。",
        "homepage": "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem",
        "mcp": {"transport": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "{plugin_dir}"]},
        "requires": ["npx"],
        "confirm_pattern": "^(write|edit|move|create)",
    },
    {
        "id": "deepwiki", "kind": "mcp", "name": "DeepWiki",
        "description": "查询 GitHub 开源仓库的文档与问答（公开远程 MCP，无需密钥）。",
        "homepage": "https://docs.devin.ai/work-with-devin/deepwiki-mcp",
        "mcp": {"transport": "http", "url": "https://mcp.deepwiki.com/mcp"},
    },
    {
        "id": "context7", "kind": "mcp", "name": "Context7 文档",
        "description": "按库名检索最新的编程库文档与示例（公开远程 MCP）。",
        "homepage": "https://github.com/upstash/context7",
        "mcp": {"transport": "http", "url": "https://mcp.context7.com/mcp"},
    },
    {
        "id": "github", "kind": "mcp", "name": "GitHub",
        "description": "GitHub 官方远程 MCP：仓库、Issue、PR。写操作每次先请你确认。",
        "homepage": "https://github.com/github/github-mcp-server",
        "mcp": {"transport": "http", "url": "https://api.githubcopilot.com/mcp/"},
        "secrets": [{"name": "GITHUB_TOKEN", "label": "GitHub Personal Access Token", "target": "header:Authorization", "format": "Bearer {value}"}],
        "confirm_pattern": "^(create|update|delete|merge|push|add|fork|assign|close|request)",
    },
    {
        "id": "brave-search", "kind": "mcp", "name": "Brave 搜索",
        "description": "Brave Search API 网页搜索（官方 @brave/brave-search-mcp-server，需要 API Key）。",
        "homepage": "https://github.com/brave/brave-search-mcp-server",
        "mcp": {"transport": "stdio", "command": "npx", "args": ["-y", "@brave/brave-search-mcp-server"]},
        "secrets": [{"name": "BRAVE_API_KEY", "label": "Brave Search API Key", "target": "env"}],
        "requires": ["npx"],
    },
    {
        "id": "skills-research", "kind": "skill", "name": "调研技能包",
        "description": "OpenMinis 自带：网页调研、文献速读两个技能。",
        "skills": [
            {"name": "web-research", "content": "---\ndescription: 需要联网调研某个问题、对比多方信息时使用\n---\n1. 先列出 3-5 个具体检索问题。\n2. 每个问题至少打开 2 个独立来源（浏览器或 fetch 插件），记录链接。\n3. 交叉核对关键事实，来源冲突时说明。\n4. 输出：结论先行，随后要点 + 来源链接；不确定的标注“未核实”。\n"},
            {"name": "paper-skim", "content": "---\ndescription: 用户给出论文链接/PDF 要快速读懂时使用\n---\n按以下结构输出：研究问题、方法（数据/样本/设计）、主要结果（含效应量与置信区间）、局限、对用户的意义。不编造原文没有的数字；引用原文时给出页码或小节。\n"},
        ],
    },
    {
        "id": "skills-daily", "kind": "skill", "name": "每日简报技能包",
        "description": "OpenMinis 自带：每日简报、周复盘的固定格式。",
        "skills": [
            {"name": "daily-briefing", "content": "---\ndescription: 生成每日简报时使用（例行任务“每日简报”）\n---\n结构：今日要点（3 条以内）→ 日程与待办 → 关注主题的新消息（每条附来源）→ 一句建议。总长度控制在手机一屏内。\n"},
            {"name": "weekly-review", "content": "---\ndescription: 做每周复盘时使用\n---\n结构：本周完成 → 未完成及原因 → 下周 3 个重点 → 需要用户决定的事项。先检索记忆中的 workstreams 类别。\n"},
        ],
    },
]

def entries():
    """当前插件目录。e2e 可通过 OPENMINIS_E2E_FAKE_PLUGIN 追加一个不访问网络的假 stdio MCP。"""
    items = list(CATALOG)
    path = (os.environ.get("OPENMINIS_E2E_FAKE_PLUGIN") or "").strip()
    if not path:
        return items
    script = path if os.path.isfile(path) else os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_fake_mcp_server.py")
    if not os.path.isfile(script):
        return items
    if any(c["id"] == "e2e-echo" for c in items):
        return items
    # 插到目录最前面：插件市场「插件目录」在运行依赖下面，假插件若排在最后会滚出控件树，
    # XCUITest 等「E2E 回声」会误判成目录里没有。
    items.insert(0, {
        "id": "e2e-echo", "kind": "mcp", "name": "E2E 回声",
        "description": "端到端测试用假 stdio MCP，不访问网络。",
        "mcp": {"transport": "stdio", "command": sys.executable, "args": [script]},
    })
    return items


def uvx_catalog_packages():
    """目录里通过 uvx 启动的 Python 包名（如 mcp-server-time）。"""
    pkgs = []
    for c in CATALOG:
        mcp = c.get("mcp") or {}
        if mcp.get("transport", "stdio") != "stdio" or mcp.get("command") != "uvx":
            continue
        args = mcp.get("args") or []
        if args and isinstance(args[0], str) and args[0] not in pkgs:
            pkgs.append(args[0])
    return pkgs


def _find_uvx():
    for candidate in (
        os.path.expanduser("~/.local/bin/uvx"),
        shutil.which("uvx"),
        os.path.expanduser("~/.local/bin/uv"),
        shutil.which("uv"),
    ):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


# 与 cloud_deps.PYPI_INDEXES 保持一致：官方失败后再试国内镜像
_WARM_INDEXES = [None, "https://mirrors.aliyun.com/pypi/simple", "https://pypi.tuna.tsinghua.edu.cn/simple"]


def _ensure_uvx():
    found = _find_uvx()
    if found:
        return found
    try:
        import cloud_deps
        cloud_deps.ensure_path()
        found = _find_uvx()
        if found:
            return found
        log = []
        cloud_deps.install_uv(log.append)
        cloud_deps.ensure_path()
        return _find_uvx()
    except Exception:
        return None


def _uvx_help_cmd(uvx, package):
    name = os.path.basename(uvx)
    if name == "uv":
        return [uvx, "tool", "run", "--from", package, package, "--help"]
    return [uvx, "--from", package, package, "--help"]


def warm_uvx_plugins(timeout_per=90):
    """预装/缓存目录里的 uvx Python 插件，避免用户第一次打开时 initialize 超时。"""
    uvx = _ensure_uvx()
    if not uvx:
        return {"ok": False, "reason": "uvx 未安装，跳过预热（可在插件市场 › 运行依赖里安装 uv）", "results": []}
    results = []
    for pkg in uvx_catalog_packages():
        ok, last, used = False, "", "default"
        for index in _WARM_INDEXES:
            env = os.environ.copy()
            if index:
                env["UV_DEFAULT_INDEX"] = index
                env["UV_INDEX_URL"] = index
                used = index
            try:
                r = subprocess.run(_uvx_help_cmd(uvx, pkg), env=env, timeout=timeout_per,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                last = (r.stdout or "")[-800]
                if r.returncode == 0:
                    ok = True
                    break
            except Exception as e:
                last = str(e)
        results.append({"package": pkg, "ok": ok, "index": used if ok else None, "error": None if ok else last})
    return {"ok": all(r["ok"] for r in results) if results else True, "results": results}


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("--warm", "warm"):
        report = warm_uvx_plugins()
        for r in report.get("results") or []:
            if r["ok"]:
                print(f"[+] 已预热 {r['package']}（{'默认源' if r['index'] in (None, 'default') else r['index']}）")
            else:
                print(f"[-] 预热 {r['package']} 失败：{(r.get('error') or '')[-200:]}")
        if report.get("reason"):
            print("[-] " + report["reason"])
        sys.exit(0 if report.get("ok") else 1)
