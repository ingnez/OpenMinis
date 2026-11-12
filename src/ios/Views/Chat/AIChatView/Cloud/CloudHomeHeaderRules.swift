//
//  CloudHomeHeaderRules.swift
//  Minis - Bot 首页顶栏的纯逻辑：左上角齿轮上的连接状态点颜色、
//  中间空位飘出的「XX 正在…」一行、下拉出来的「今天」卡片数字、两种首页模式。只用 Foundation，方便在 Linux 上测。
//

import Foundation

/// 首页模式：和 ContentView 的 @AppStorage("OpenMinis_homeMode") 同一个值（local / bots）
enum HomeMode: String, CaseIterable, Identifiable {
    case local, bots
    var id: String { rawValue }
    var title: String { self == .local ? "本地模式" : "云端模式" }
    var symbol: String { self == .local ? "iphone" : "cloud" }
    var detail: String { self == .local ? "模型直接在手机上调用，对话存在本机" : "多个 Bot 跑在你的云电脑上，手机关了也接着干" }
    static func from(_ raw: String) -> HomeMode { raw == "bots" ? .bots : .local }
}

enum CloudHomeHeaderRules {
    /// 齿轮右上角的连接状态点：online 绿、重连 / 连接中 / 服务器要更新 黄、离线或未配置 灰
    enum Dot: String { case green, yellow, gray }
    enum Link { case online(needsAttention: Bool), connecting, retrying, offline, idle }
    static func dot(_ link: Link) -> Dot {
        switch link {
        case .online(let attention): return attention ? .yellow : .green
        case .connecting, .retrying: return .yellow
        case .offline, .idle: return .gray
        }
    }
    /// H2：主 Bot 星号徽章按状态着色（取代齿轮上的小点和头像左下的红点），点一下弹一句说明
    enum StarTone: String { case green, yellow, red }
    static func star(_ link: Link, botError: Bool) -> (tone: StarTone, text: String) {
        switch link {
        case .offline, .idle: return (.red, "服务器断开，点这里重连")
        case .connecting, .retrying: return (.yellow, "正在连接服务器…")
        case .online(let attention):
            if botError { return (.red, "服务器已连接，但这个 Bot 上次出错了，点头像进对话看看") }
            if attention { return (.yellow, "服务器已连接，但有事要处理（服务器要更新或云电脑有问题）") }
            return (.green, "服务器已连接")
        }
    }

    static func dotText(_ d: Dot) -> String {
        switch d { case .green: return "云端在线"; case .yellow: return "云端重连中"; case .gray: return "云端离线" }
    }

    /// 中间空位的一行：没有 Bot 在干活时 nil（藏起来）。一个 Bot：「SWE 正在构建…」；多个：「SWE 等 3 个 Bot 正在干活…」
    /// working 按开始干活的顺序传 (名字, 阶段短标签)，第一个当主角；点这一行跳到它的对话
    static func centerLine(_ working: [(name: String, label: String)]) -> String? {
        guard let first = working.first else { return nil }
        let name = first.name.count > 8 ? String(first.name.prefix(8)) + "…" : first.name
        if working.count == 1 {
            let verb = first.label.hasSuffix("中") ? String(first.label.dropLast()) : first.label
            return "\(name) 正在\(verb.isEmpty ? "干活" : verb)…"
        }
        return "\(name) 等 \(working.count) 个 Bot 正在干活…"
    }

    /// 「今天」卡片：在跑的 Bot 数、今天有消息的对话数（最后一条在今天 0 点之后）
    static func todayCounts(lastAts: [Double], workingCount: Int, now: Date = Date(), calendar: Calendar = .current) -> (running: Int, chatsToday: Int) {
        let start = calendar.startOfDay(for: now).timeIntervalSince1970
        return (workingCount, lastAts.filter { $0 >= start }.count)
    }

    /// 下拉多少显示「今天」卡片、往上滑多少收起
    static let revealPull: Double = 70
    static let hideScroll: Double = -40
    static func todayVisible(was: Bool, scrollTop: Double) -> Bool {
        if scrollTop >= revealPull { return true }
        if scrollTop <= hideScroll { return false }
        return was
    }

    /// 顶部大头像的表情：出错皱眉，在干活时眨眼频率加快（返回下一次眨眼前等待的秒数范围）
    static func blinkWait(working: Bool) -> ClosedRange<Double> { working ? 0.45...1.1 : 1.2...3.2 }
}

/// 首页列表 / 小组件的最后一条预览：去掉 Markdown 记号（引用「> 」、标题「#」、加粗 / 斜体星号、行内代码反引号），
/// 以前列表里直接露出「> 这是**结论：**…」（11-11 E2E 截图）
enum CloudPreviewText {
    /// 一行 / 几行预览（首页「今日」卡片、列表行、小组件）：去掉 Markdown 记号，只留字。
    /// 先整段去记号再交给 lineLimit 截断，不会截在「**」中间露出半个记号。
    static func plain(_ s: String) -> String {
        var lines: [String] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            while line.hasPrefix("#") { line = String(line.dropFirst()) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { line = String(line.dropFirst(2)) }
            if line.hasPrefix("[ ] ") || line.hasPrefix("[x] ") || line.hasPrefix("[X] ") { line = String(line.dropFirst(4)) }
            if line.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil { continue }   // 分隔线
            line = inline(line).trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }
        return lines.joined(separator: " ")
    }

    /// 行内记号：图片 / 链接只留文字，加粗、斜体、删除线、行内代码去掉符号
    static func inline(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "[图片]"),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"\*\*|__|~~"#, ""),
            (#"(^|[^\w*])\*(?=\S)([^*\n]*?\S)\*(?=[^\w*]|$)"#, "$1$2"),   // *斜体*（不碰 3*4 这类）
            (#"(^|[^\w])_(?=\S)([^_\n]*?\S)_(?=[^\w]|$)"#, "$1$2"),         // _斜体_（不碰 snake_case）
            ("`", ""),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return t
    }

    /// 多行可读版（首页「今天有消息」小窗口）：保留换行，「**加粗**」切成加粗段，其余行内记号去掉；
    /// 不交给 cmark（中文标点旁的加粗它判不出来）
    struct Segment: Equatable {
        let text: String
        let bold: Bool
    }

    static func rich(_ s: String) -> [Segment] {
        var out: [Segment] = []
        var lines: [String] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            while line.hasPrefix("#") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { line = "• " + line.dropFirst(2) }
            if line.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil { line = "" }
            if line.isEmpty && (lines.last ?? "").isEmpty { continue }   // 连续空行只留一个
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        let parts = lines.joined(separator: "\n").components(separatedBy: "**")
        for (i, part) in parts.enumerated() {
            // 落单的「**」（被截断的半个加粗）当普通文字，不加粗
            let bold = i % 2 == 1 && i < parts.count - 1
            let text = inline(part)
            guard !text.isEmpty else { continue }
            if let last = out.last, last.bold == bold { out[out.count - 1] = Segment(text: last.text + text, bold: bold) }
            else { out.append(Segment(text: text, bold: bold)) }
        }
        return out
    }
}

/// 首页「今天」统计栏下面的小窗口：「在跑的 Bot」「今天有消息」两格互斥，再点同一格收回
enum CloudTodayPanel: String {
    case running, messages

    static func toggle(_ current: CloudTodayPanel?, tapped: CloudTodayPanel) -> CloudTodayPanel? {
        current == tapped ? nil : tapped
    }
}
