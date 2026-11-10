import Foundation

/// 输入框最右边那个会变形的圆按钮（Bot 模式和本地模式共用）：
/// 没字 = 声波（开始实时语音，长按按住说话），有字 = 上箭头（发送）。
/// Bot / 本地 Agent 在干活时不变成停止键：照样能发，有字就是插话或排队（停止在任务卡片 / 状态行上）。
/// 提交中显示转圈。
enum CloudBotComposerAction: Equatable {
    case call
    case send
    case steer(interrupt: Bool)
    case busy

    static func of(hasDraft: Bool, working: Bool, submitting: Bool, steerInterrupt: Bool) -> CloudBotComposerAction {
        if submitting { return .busy }
        if hasDraft { return working ? .steer(interrupt: steerInterrupt) : .send }
        return .call
    }

    var symbol: String {
        switch self {
        case .call: return "waveform"
        case .send: return "arrow.up"
        case .steer(let interrupt): return interrupt ? "arrow.turn.up.right" : "text.badge.plus"
        case .busy: return ""
        }
    }

    func accessibilityLabel(local: Bool = false) -> String {
        switch self {
        case .call: return "开始实时语音（长按按住说话）"
        case .send: return "发送"
        case .steer(let interrupt): return interrupt ? "插话" : "排队发送"
        case .busy: return "正在提交"
        }
    }

    /// 通话中声波不可点（已经在通话了）；提交中不可点
    func enabled(inCall: Bool) -> Bool {
        switch self {
        case .busy: return false
        case .call: return !inCall
        default: return true
        }
    }

    /// 只有声波状态支持长按「按住说话」
    var supportsPushToTalk: Bool { self == .call }

    /// 变形动画用的标识：同一种状态不重复触发动画
    var morphKey: String {
        switch self {
        case .steer(let i): return "steer\(i)"
        default: return symbol.isEmpty ? "busy" : symbol
        }
    }

    /// 输入框占位：Bot 模式「向 X 提问」；本地模式保留「@ 交给 Bot」的提示
    static func placeholder(botName: String?, localHint: Bool) -> String {
        if let botName, !botName.isEmpty { return "向 \(botName) 提问" }
        return localHint ? "发消息，@ 交给 Bot" : "发消息"
    }
}

/// 通话状态行和挂断后插进对话里的分隔线
enum CloudBotCallText {
    static func clock(_ seconds: Int) -> String { String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60) }
    static func divider(seconds: Int) -> String { "♪ 语音聊天 · " + clock(seconds) }

    /// 最后一条消息下面的状态：从真实的任务状态和正在跑的工具推出来
    static func typingStatus(taskStatus: String?, tool: String?) -> String? {
        guard let s = taskStatus, s == "running" || s == "queued" || s == "waiting_user" else { return nil }
        if s == "queued" { return "排队中…" }
        if s == "waiting_user" { return "等你确认" }
        switch tool ?? "" {
        case "": return "正在输入…"
        case let t where t.contains("shell") || t.contains("python") || t.contains("code") || t.contains("file_write") || t.contains("exec"):
            return "编写代码中"
        case let t where t.contains("browser") || t.contains("web") || t.contains("search") || t.contains("fetch"):
            return "查资料中"
        case let t where t.contains("desktop") || t.contains("computer"):
            return "操作电脑中"
        case let t where t.contains("image"): return "画图中"
        case let t where t.contains("memory"): return "翻记忆中"
        case let t where t.contains("file"): return "看文件中"
        default: return "处理中…"
        }
    }
}

/// 按钮底色是 Bot 头像色：用相对亮度挑白色或深色图标，保证深浅色模式都看得清
enum CloudTintContrast {
    /// r/g/b 0…1（sRGB）；返回 true 表示底色偏亮，图标应该用深色
    static func prefersDarkGlyph(r: Double, g: Double, b: Double) -> Bool {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        // 与白色、黑色的对比度谁高用谁
        let vsWhite = 1.05 / (l + 0.05), vsBlack = (l + 0.05) / 0.05
        return vsBlack > vsWhite
    }
}

/// 通话结束后插进对话里的「♪ 语音聊天 · mm:ss」分隔线：只存在这台手机上（按会话），放在通话开始的位置，后面跟通话字幕
struct CloudCallDivider: Codable, Equatable, Identifiable {
    let t: Double
    let seconds: Int
    var id: Double { t }

    private static func key(_ sessionId: String) -> String { "OpenMinisCallDividers." + sessionId }

    static func load(_ sessionId: String, defaults: UserDefaults = .standard) -> [CloudCallDivider] {
        guard let data = defaults.data(forKey: key(sessionId)),
              let list = try? JSONDecoder().decode([CloudCallDivider].self, from: data) else { return [] }
        return list
    }

    static func add(_ sessionId: String, start: Date, seconds: Int, defaults: UserDefaults = .standard) {
        guard !sessionId.isEmpty, seconds > 0 else { return }
        var list = load(sessionId, defaults: defaults)
        list.append(CloudCallDivider(t: start.timeIntervalSince1970, seconds: seconds))
        if let data = try? JSONEncoder().encode(Array(list.suffix(50))) { defaults.set(data, forKey: key(sessionId)) }
    }

    /// 放在哪条消息后面：时间早于它的最后一条消息的下标；比所有消息都早返回 -1
    static func anchor(_ d: CloudCallDivider, timestamps: [Double]) -> Int {
        var idx = -1
        for (i, t) in timestamps.enumerated() where t <= d.t { idx = i }
        return idx
    }
}
