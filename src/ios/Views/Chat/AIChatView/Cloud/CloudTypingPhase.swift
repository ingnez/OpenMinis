import Foundation

/// 首页「正在回复」：Bot 或本地对话此刻在干什么。只来自真实状态——
/// 多 Bot 模式是服务器 /v1/bots 的 `activity`（运行中任务的实时状态），本地是 SessionActivityTracker 的工具信息。
struct CloudTypingPhase: Hashable {
    enum Kind: String { case thinking, tool, replying, delegating }
    var kind: Kind
    var tool: String?
    var peer: String?
    var preview: String?
    var taskId: String? = nil

    init(kind: Kind, tool: String? = nil, peer: String? = nil, preview: String? = nil) {
        self.kind = kind; self.tool = tool; self.peer = peer; self.preview = preview
    }

    /// 服务器 2.33.0+ 的 activity；老服务器没有这个字段 → nil（首页退回原来的「处理中」）
    init?(json: Any?) {
        guard let d = json as? [String: Any], let k = Kind(rawValue: d["phase"] as? String ?? "") else { return nil }
        self.init(kind: k, tool: Self.clean(d["tool"]), peer: Self.clean(d["peer"]), preview: Self.clean(d["preview"]))
        taskId = Self.clean(d["task_id"])
    }

    /// 本地对话：SSE 流里 toolName 为 "text" = 正在出字，"thinking" / 空 = 思考，其余是工具名；有子代理在跑 = 委派
    static func local(toolName: String, delegating: Bool) -> CloudTypingPhase {
        if delegating { return CloudTypingPhase(kind: .delegating, peer: "子代理") }
        switch toolName {
        case "text": return CloudTypingPhase(kind: .replying)
        case "", "thinking": return CloudTypingPhase(kind: .thinking)
        default: return CloudTypingPhase(kind: .tool, tool: toolName)
        }
    }

    private static func clean(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 常用工具的中文名；没收录的就显示原名
    static func toolLabel(_ name: String) -> String {
        let known: [String: String] = [
            "shell_execute": "终端", "web_search": "搜索", "web_fetch": "读网页", "browser": "浏览器",
            "browser_action": "浏览器", "read_file": "读文件", "write_file": "写文件", "edit_file": "改文件",
            "python": "Python", "computer": "电脑", "memory_save": "记忆", "vault_fill": "保管库",
            "generate_image": "画图", "spawn_worker": "后台任务"]
        return known[name] ?? name
    }

    /// 首页第二行（不带预览）
    var label: String {
        switch kind {
        case .thinking: return "正在思考"
        case .tool: return "正在用工具" + (tool.map { " · " + Self.toolLabel($0) } ?? "")
        case .replying: return "正在回复"
        case .delegating: return "正在委派给 " + (peer ?? "别的 Bot")
        }
    }

    /// 首页第二行：正在回复时跟上正在生成的最后一行
    var subtitle: String {
        if kind == .replying, let p = preview { return "正在回复：" + p }
        return label + "…"
    }

    /// 顶部大头像下面的短标签
    var shortLabel: String {
        switch kind {
        case .thinking: return "思考中"
        case .tool: return "用工具"
        case .replying: return "回复中"
        case .delegating: return "委派中"
        }
    }
}

enum CloudTypingRules {
    /// 有 Bot 在干活时首页 3 秒刷一次（跟得上阶段变化），都闲着 15 秒
    static func pollSeconds(anyWorking: Bool) -> UInt64 { anyWorking ? 3 : 15 }

    /// 排序用的时间：正在干活的当作「现在」，排到最上面，时间也显示现在
    static func sortTime(lastAt: Double, working: Bool, now: Date = Date()) -> Double {
        working ? max(lastAt, now.timeIntervalSince1970) : lastAt
    }

    /// 上一次刷新还在干活、这一次停了的（首页看着时轻震一下）
    static func justFinished(before: Set<String>, after: Set<String>) -> Set<String> { before.subtracting(after) }

    /// 三个点的亮度：第 i 个点比前一个晚 0.18 秒，周期 1.2 秒；返回 0.35...1
    static func dotLevel(index: Int, time: Double) -> Double {
        let phase = (time - Double(index) * 0.18).truncatingRemainder(dividingBy: 1.2) / 1.2
        let p = phase < 0 ? phase + 1 : phase
        let wave = p < 0.5 ? sin(p * 2 * .pi) : 0     // 前半周期亮一下，后半周期歇着
        return 0.35 + 0.65 * max(0, wave)
    }
}
