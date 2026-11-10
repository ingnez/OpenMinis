import Foundation

/// Spotlight 搜索 Bot 的规则（纯逻辑）：上锁 / 隐藏的 Bot 不进索引；简介只放 Bot 自己的一句话，不放聊天内容。
enum CloudSpotlightRules {
    static let key = "OpenMinisSpotlightBots"
    static let prefix = "openminis.bot:"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    struct Entry: Equatable {
        let identifier: String
        let title: String
        let detail: String
        let keywords: [String]
    }

    static func entries(_ bots: [(id: String, name: String, summary: String, locked: Bool, hidden: Bool)]) -> [Entry] {
        bots.filter { !$0.locked && !$0.hidden }.prefix(100).map { b in
            Entry(identifier: prefix + b.id, title: b.name,
                  detail: b.summary.isEmpty ? "Minis 里的 Bot，点开直接对话" : String(b.summary.prefix(120)),
                  keywords: [b.name, "Minis", "Bot"])
        }
    }

    static func botId(from identifier: String) -> String? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let id = String(identifier.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}
