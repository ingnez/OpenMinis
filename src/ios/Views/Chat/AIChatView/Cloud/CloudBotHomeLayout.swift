import SwiftUI

/// 首页布局：列表（默认，可左滑置顶 / 隐藏）、网格（三列小方块）、卡片（两列，带最新消息）
enum CloudHomeLayout: String, CaseIterable, Identifiable {
    case list, grid, card
    static let key = "OpenMinisCloud_homeLayout"
    var id: String { rawValue }
    var label: String { self == .list ? "列表" : self == .grid ? "网格" : "卡片" }
    var icon: String { self == .list ? "list.bullet" : self == .grid ? "square.grid.3x3" : "rectangle.grid.2x2" }
    var columns: Int { self == .grid ? 3 : 2 }
}

struct CloudBotHomeTile: View {
    let bot: CloudBot
    let unread: Bool
    let presence: CloudBotPresence
    let card: Bool

    var body: some View {
        let status = CloudBotStatus.of(bot)
        let row = CloudBotHomeRow(bot: bot, unread: unread, presence: presence)
        VStack(alignment: card ? .leading : .center, spacing: 6) {
            HStack(alignment: .top) {
                CloudBotWatchingAvatar(spec: CloudBotAvatarSpec.of(bot), size: card ? 40 : 52,
                                       mood: CloudBotMood.of(status, unread: unread, lastTaskStatus: bot.lastTaskStatus, lastAt: bot.lastAt))
                    .overlay(alignment: .bottomTrailing) { CloudPresenceBadge(presence: presence, size: 12) }
                if card {
                    Spacer(minLength: 0)
                    CloudUnreadMark(presence: presence)
                }
            }
            Text(bot.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            if card {
                Text(row.previewText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(CloudBotHome.timeText(bot.lastAt)).font(.caption2).foregroundStyle(.tertiary)
            } else if presence.unread > 0 || unread {
                CloudUnreadMark(presence: presence)
            }
        }
        .padding(card ? 12 : 8)
        .frame(maxWidth: .infinity, minHeight: card ? 120 : 96, alignment: card ? .topLeading : .center)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bot.name)，\(presence.accessibilityText)")
    }
}
