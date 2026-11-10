import Foundation

/// 本地对话的通话分隔线「♪ 语音聊天 · 03:12」：挂断后记下第一条通话文字的排序号和时长，
/// 打开对话时插在那条消息前面。只是界面上的一行（systemInfo），不进模型上下文，也不写进对话数据库。
struct LocalCallDivider: Codable, Equatable {
    /// 通话第一条文字记录在数据库里的 sort_order
    let sortOrder: Int
    let seconds: Int

    static func text(seconds: Int) -> String {
        let s = max(0, seconds)
        return "♪ 语音聊天 · " + String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static func key(_ sessionId: String) -> String { "OpenMinisLocalCallDividers." + sessionId }

    static func load(_ sessionId: String, defaults: UserDefaults = .standard) -> [LocalCallDivider] {
        guard let data = defaults.data(forKey: key(sessionId)),
              let list = try? JSONDecoder().decode([LocalCallDivider].self, from: data) else { return [] }
        return list
    }

    static func add(_ sessionId: String, _ divider: LocalCallDivider, defaults: UserDefaults = .standard) {
        guard !sessionId.isEmpty, divider.seconds > 0 else { return }
        var list = load(sessionId, defaults: defaults).filter { $0.sortOrder != divider.sortOrder }
        list.append(divider)
        list.sort { $0.sortOrder < $1.sortOrder }
        if let data = try? JSONEncoder().encode(Array(list.suffix(200))) { defaults.set(data, forKey: key(sessionId)) }
    }

    /// 每条分隔线插在哪：排在第一条 sort_order ≥ 它的消息前面（从后往前插，下标不会错位）。
    /// 消息被删了、对应位置已经不存在的分隔线不画。
    static func insertions(sortOrders: [Int?], dividers: [LocalCallDivider]) -> [(index: Int, divider: LocalCallDivider)] {
        dividers.compactMap { d in
            guard let i = sortOrders.firstIndex(where: { ($0 ?? Int.min) >= d.sortOrder }) else { return nil }
            return (i, d)
        }
        .sorted { $0.index > $1.index }
    }
}
