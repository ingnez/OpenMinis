# -*- coding: utf-8 -*-
"""随服务端发布的插件目录：公开 MCP 服务器与 OpenMinis 自带技能包。

MCP 条目只是安装说明，安装时才在 VPS 上通过 uvx / npx 拉取对应的开源包，或连接公开的
远程 MCP 端点；需要密钥的条目在填写密钥前处于 needs_auth 状态。
"""

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
