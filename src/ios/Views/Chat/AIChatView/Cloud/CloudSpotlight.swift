@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// 把 Bot 放进系统 Spotlight：下拉搜索输入 Bot 名字就能直接打开对话（iOS 16 可用）
enum CloudSpotlight {
    private static let domain = "openminis.bots"
    private static var lastSignature = ""

    @MainActor
    static func index(_ bots: [CloudBot]) {
        let rows = bots.map { (id: $0.id, name: $0.name, summary: $0.summary, locked: CloudBotLock.isLockedStored($0.id), hidden: $0.hidden) }
        let entries = CloudSpotlightRules.enabled ? CloudSpotlightRules.entries(rows) : []
        let signature = entries.map { $0.identifier + $0.title + $0.detail }.joined(separator: "|")
        guard signature != lastSignature else { return }
        lastSignature = signature
        let items = entries.map { e -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = e.title
            attrs.contentDescription = e.detail
            attrs.keywords = e.keywords
            return CSSearchableItem(uniqueIdentifier: e.identifier, domainIdentifier: domain, attributeSet: attrs)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            if !items.isEmpty { index.indexSearchableItems(items) { _ in } }
        }
    }

    /// Spotlight 里点了某个 Bot
    @MainActor
    static func open(identifier: String?) {
        guard let identifier, let bot = CloudSpotlightRules.botId(from: identifier) else { return }
        CloudBotEntry.open(bot: bot, text: nil, send: false)
    }
}
