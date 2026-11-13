import Foundation

/// Bot 之间的只读对话线程（服务器 2.16.0 /v1/bot-threads）。只依赖 Foundation，规则在 scripts/CloudBotThreadsTests.swift 里测。
struct CloudBotThreadMessage: Identifiable, Equatable {
    let id: Int
    let sender: String
    let recipient: String
    let text: String
    let at: Date
    let priority: String
    let kind: String          // message / task / result
    let status: String?
    let delegationId: String?
    let taskId: String?
    let sessionId: String?

    var isPriority: Bool { priority == "high" }

    init?(_ d: [String: Any]) {
        guard let id = (d["id"] as? NSNumber)?.intValue, let s = d["sender"] as? String, let r = d["recipient"] as? String else { return nil }
        self.id = id
        sender = s
        recipient = r
        text = d["text"] as? String ?? ""
        at = Date(timeIntervalSince1970: (d["ts"] as? NSNumber)?.doubleValue ?? 0)
        priority = d["priority"] as? String ?? "normal"
        kind = d["kind"] as? String ?? "message"
        status = d["status"] as? String
        delegationId = d["delegation_id"] as? String
        taskId = d["task_id"] as? String
        sessionId = d["session_id"] as? String
    }
}

/// 一对 Bot 的线程（列表里的一行）
struct CloudBotThreadSummary: Identifiable, Equatable {
    let pair: String
    let bots: [String]
    let names: [String: String]
    let count: Int
    let lastAt: Date
    let lastText: String
    let working: [String]
    let highPriority: Int
    let peer: String?
    let preview: String?
    var id: String { pair }

    init?(_ d: [String: Any]) {
        guard let pair = d["pair"] as? String, let bots = d["bots"] as? [String], bots.count == 2 else { return nil }
        self.pair = pair
        self.bots = bots
        names = d["names"] as? [String: String] ?? [:]
        count = (d["count"] as? NSNumber)?.intValue ?? 0
        lastAt = Date(timeIntervalSince1970: (d["last_at"] as? NSNumber)?.doubleValue ?? 0)
        lastText = (d["last"] as? [String: Any])?["text"] as? String ?? ""
        working = d["working"] as? [String] ?? []
        highPriority = (d["high_priority"] as? NSNumber)?.intValue ?? 0
        peer = d["peer"] as? String
        preview = d["preview"] as? String
    }
}

/// 用户对话里那条折叠行「N 条消息，与 X」
struct CloudBotThreadCollapsed: Identifiable, Equatable {
    let me: String
    let peer: String
    let peerName: String
    let count: Int
    let firstAt: Date
    let lastAt: Date
    let outgoing: Bool?
    let delegationIDs: [String]
    var id: String { me + "|" + peer }
    var label: String { CloudBotThreadRules.collapsedLabel(count: count, peerName: peerName, outgoing: outgoing) }
    var route: String { CloudBotThreadRules.route(me, peer) }

    init?(_ d: [String: Any]) {
        guard let peer = d["peer"] as? String, let count = (d["count"] as? NSNumber)?.intValue, count > 0 else { return nil }
        self.peer = peer
        me = d["me"] as? String ?? "_main"
        peerName = d["peer_name"] as? String ?? peer
        self.count = count
        delegationIDs = d["delegations"] as? [String] ?? []
        firstAt = Date(timeIntervalSince1970: (d["first_at"] as? NSNumber)?.doubleValue ?? 0)
        lastAt = Date(timeIntervalSince1970: (d["last_at"] as? NSNumber)?.doubleValue ?? 0)
        if let o = d["outgoing"] as? Bool { outgoing = o }
        else if let n = d["outgoing"] as? NSNumber { outgoing = n.boolValue }
        else { outgoing = nil }
    }
}

struct CloudBotThreadDay: Identifiable {
    let day: Date
    var messages: [CloudBotThreadMessage]
    var id: Date { day }
}

enum CloudBotThreadRules {
    static let routePrefix = "thread:"

    /// 首页导航用：thread:<a>|<b>（两个 id 排好序，同一对只有一个地址）
    static func route(_ a: String, _ b: String) -> String { routePrefix + [a, b].sorted().joined(separator: "|") }

    static func parseRoute(_ s: String) -> (String, String)? {
        guard s.hasPrefix(routePrefix) else { return nil }
        let parts = s.dropFirst(routePrefix.count).split(separator: "|").map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.range(of: #"^[a-z0-9_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil }) else { return nil }
        return (parts[0], parts[1])
    }

    static func collapsedLabel(count: Int, peerName: String, outgoing: Bool? = nil) -> String {
        if count <= 1 {
            return outgoing == false ? "收到 ◯\(peerName) 的消息" : "发消息给 ◯\(peerName)"
        }
        return "与 \(peerName) 往来 \(count) 条"
    }

    /// 线程页里超过这个字数或行数先收起，点「展开」再看全文
    static let longMessageChars = 280
    static let longMessageLines = 8
    static func isLongMessage(_ text: String) -> Bool {
        text.count > longMessageChars || text.split(separator: "\n", omittingEmptySubsequences: false).count > longMessageLines
    }

    /// 首页预览：Bot 间消息比最后一条对话更新时用它（「➤ 已发消息给 X：…」/「← 来自 X：…」）
    static func homePreview(chat: String, chatAt: Date?, thread: String?, threadAt: Date?) -> (text: String, isThread: Bool) {
        guard let thread, !thread.isEmpty, let threadAt else { return (chat, false) }
        if let chatAt, chatAt > threadAt.addingTimeInterval(0.5), !chat.isEmpty { return (chat, false) }
        return (thread, true)
    }

    /// 日期分隔：按自然日分组，保持原顺序
    static func daySections(_ msgs: [CloudBotThreadMessage], calendar: Calendar = .current) -> [CloudBotThreadDay] {
        var out: [CloudBotThreadDay] = []
        for m in msgs {
            let day = calendar.startOfDay(for: m.at)
            if let last = out.last, last.day == day {
                out[out.count - 1].messages.append(m)
            } else {
                out.append(CloudBotThreadDay(day: day, messages: [m]))
            }
        }
        return out
    }

    static func dayLabel(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = calendar.isDate(day, equalTo: now, toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return f.string(from: day)
    }

    /// 消息里 @ 到的 Bot（按名字匹配，先长后短，避免「小王」吃掉「小王子」），返回 id，按出现顺序去重
    static func mentions(in text: String, names: [String: String]) -> [String] {
        var hits: [(Int, String)] = []
        var taken: [Range<String.Index>] = []
        for (id, name) in names.sorted(by: { $0.value.count > $1.value.count }) where !name.isEmpty {
            for mark in ["@", "＠"] {
                var from = text.startIndex
                while let r = text.range(of: mark + name, range: from..<text.endIndex) {
                    if !taken.contains(where: { $0.overlaps(r) }) {
                        taken.append(r)
                        hits.append((text.distance(from: text.startIndex, to: r.lowerBound), id))
                    }
                    from = r.upperBound
                }
            }
        }
        var seen = Set<String>()
        return hits.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0).inserted }
    }

    /// 折叠行放在对话里的位置：最后一条时间不晚于线程第一条消息的那一轮后面；返回轮次下标（-1 = 最前面）
    static func anchor(firstAt: Date, turnTimes: [Date?]) -> Int {
        var idx = -1
        for (i, t) in turnTimes.enumerated() {
            if let t, t <= firstAt.addingTimeInterval(0.5) { idx = i }
        }
        return idx
    }

    /// 长按「引用到我的对话」的草稿
    static func quote(senderName: String, text: String) -> String {
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).map { "> " + $0 }.joined(separator: "\n")
        return "> \(senderName)：\n\(body)\n\n"
    }
}
