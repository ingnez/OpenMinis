//
//  CloudBotsWidget.swift
//  AgentWidget - 主屏幕小组件：点一下打开云端 Bot 的对话（minis://bot/<id>）。
//  Bot 列表由 App 写进 App Group（group.com.openminis.app）；侧载重签后读不到 App Group 时，仍显示「主 Bot」入口。
//

import SwiftUI
import WidgetKit

struct CloudBotsEntry: TimelineEntry {
    struct Bot: Hashable { let id: String; let name: String; let emoji: String }
    let date: Date
    let bots: [Bot]
}

struct CloudBotsProvider: TimelineProvider {
    static let key = "OpenMinisCloud_widgetBots"

    static func load() -> [CloudBotsEntry.Bot] {
        let raw = UserDefaults(suiteName: "group.com.openminis.app")?.array(forKey: key) as? [[String: String]] ?? []
        return raw.compactMap { d in
            guard let id = d["id"], let name = d["name"], !name.isEmpty,
                  id.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else { return nil }
            return CloudBotsEntry.Bot(id: id, name: name, emoji: d["emoji"] ?? "")
        }
    }

    func placeholder(in context: Context) -> CloudBotsEntry {
        CloudBotsEntry(date: Date(), bots: [.init(id: "", name: "主 Bot", emoji: "🤖")])
    }

    func getSnapshot(in context: Context, completion: @escaping (CloudBotsEntry) -> Void) {
        completion(CloudBotsEntry(date: Date(), bots: Self.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CloudBotsEntry>) -> Void) {
        // App 每次刷新 Bot 列表会主动刷新小组件；再加 6 小时兜底，防止那次刷新没送达
        completion(Timeline(entries: [CloudBotsEntry(date: Date(), bots: Self.load())], policy: .after(Date().addingTimeInterval(6 * 3600))))
    }
}

struct CloudBotsWidgetView: View {
    let entry: CloudBotsEntry
    @Environment(\.widgetFamily) private var family

    private func url(_ bot: CloudBotsEntry.Bot?) -> URL {
        URL(string: "minis://bot/" + (bot?.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))!
    }

    private func badge(_ bot: CloudBotsEntry.Bot, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            Text(bot.emoji.isEmpty ? String(bot.name.prefix(1)) : bot.emoji)
                .font(.system(size: size * 0.5, weight: .semibold))
        }
        .frame(width: size, height: size)
    }

    var body: some View {
        let bots = entry.bots.isEmpty ? [CloudBotsEntry.Bot(id: "", name: "主 Bot", emoji: "🤖")] : entry.bots
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Text(bots[0].emoji.isEmpty ? String(bots[0].name.prefix(1)) : bots[0].emoji).font(.title2)
            }
            .widgetURL(url(bots[0]))
            .accessibilityLabel("打开 \(bots[0].name)")
        } else if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                Text((bots[0].emoji.isEmpty ? "" : bots[0].emoji + " ") + bots[0].name).font(.headline).lineLimit(1)
                Text(entry.bots.isEmpty ? "打开 App 一次即可同步" : "点一下开始对话").font(.caption).lineLimit(1)
                if bots.count > 1 { Text(bots.dropFirst().prefix(3).map(\.name).joined(separator: " · ")).font(.caption2).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(url(bots[0]))
        } else if family == .accessoryInline {
            Text((bots[0].emoji.isEmpty ? "🤖" : bots[0].emoji) + " " + bots[0].name).widgetURL(url(bots[0]))
        } else if family == .systemSmall {
            VStack(alignment: .leading, spacing: 8) {
                badge(bots[0], size: 44)
                Spacer(minLength: 0)
                Text(bots[0].name).font(.headline).lineLimit(1)
                Text(entry.bots.isEmpty ? "打开 App 一次即可同步 Bot" : "点一下开始对话").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
            .widgetURL(url(bots[0]))
        } else {
            HStack(spacing: 10) {
                if entry.bots.isEmpty {
                    Link(destination: url(nil)) {
                        HStack(spacing: 12) {
                            badge(bots[0], size: 46)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("主 Bot").font(.headline)
                                Text("打开 App 一次即可同步 Bot 列表").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                ForEach(Array(entry.bots.prefix(4)), id: \.self) { b in
                    Link(destination: url(b)) {
                        VStack(spacing: 6) {
                            badge(b, size: 46)
                            Text(b.name).font(.caption).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding()
        }
    }
}

struct CloudBotsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CloudBotsWidget", provider: CloudBotsProvider()) { entry in
            if #available(iOS 17.0, *) {
                CloudBotsWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
            } else {
                CloudBotsWidgetView(entry: entry)
            }
        }
        .configurationDisplayName("云端 Bot")
        .description("一键打开你的云端 Bot 对话。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - 「今日」小组件：最近的例行任务 / 主动消息结果

/// App 每次刷新首页时把「今日」写进 App Group（上锁 Bot 的条目不写）；小组件本身连不上云电脑，只显示 App 最近一次带回的内容。
struct CloudTodayEntry: TimelineEntry {
    struct Item: Hashable { let title: String; let text: String; let at: Date; let botId: String }
    let date: Date
    let items: [Item]
    let synced: Bool
}

struct CloudTodayProvider: TimelineProvider {
    static let key = "OpenMinisCloud_widgetFeed"

    static func load() -> (items: [CloudTodayEntry.Item], synced: Bool) {
        guard let raw = UserDefaults(suiteName: "group.com.openminis.app")?.array(forKey: key) as? [[String: Any]] else { return ([], false) }
        let items: [CloudTodayEntry.Item] = raw.compactMap { d in
            guard let title = d["title"] as? String, let text = d["text"] as? String, !text.isEmpty else { return nil }
            let bot = d["bot_id"] as? String ?? ""
            let safeBot = bot.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil ? bot : ""
            return CloudTodayEntry.Item(title: String(title.prefix(40)), text: String(text.prefix(200)),
                                        at: Date(timeIntervalSince1970: d["at"] as? Double ?? 0), botId: safeBot)
        }
        return (items, true)
    }

    func placeholder(in context: Context) -> CloudTodayEntry {
        CloudTodayEntry(date: Date(), items: [.init(title: "每日简报", text: "今天的要点会显示在这里", at: Date(), botId: "")], synced: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (CloudTodayEntry) -> Void) {
        let l = Self.load()
        completion(CloudTodayEntry(date: Date(), items: l.items, synced: l.synced))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CloudTodayEntry>) -> Void) {
        let l = Self.load()
        completion(Timeline(entries: [CloudTodayEntry(date: Date(), items: l.items, synced: l.synced)],
                            policy: .after(Date().addingTimeInterval(3 * 3600))))
    }
}

struct CloudTodayWidgetView: View {
    let entry: CloudTodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let limit = family == .systemLarge ? 5 : 2
        if family == .accessoryRectangular || family == .accessoryInline {
            lockScreen
        } else {
            homeScreen(limit: limit)
        }
    }

    /// 锁屏：只显示最新一条（标题 + 两行内容）。手机锁着也能看到，所以写入端已经去掉上锁 Bot 的内容（见 CloudBotHomeModel.publishFeedToWidget）
    @ViewBuilder private var lockScreen: some View {
        let item = entry.items.first
        if family == .accessoryInline {
            Text(item.map { "✨ " + $0.title } ?? "✨ 今日暂无新消息")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(item?.title ?? "今日").font(.headline).lineLimit(1)
                Text(item?.text ?? (entry.synced ? "最近 24 小时没有新结果" : "打开 App 一次即可同步")).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(URL(string: "minis://bot/" + (item?.botId ?? ""))!)
        }
    }

    private func homeScreen(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("今日").font(.headline)
                Spacer()
                Image(systemName: "sparkles").foregroundStyle(.secondary)
            }
            if entry.items.isEmpty {
                Spacer(minLength: 0)
                Text(entry.synced ? "最近 24 小时还没有例行任务或主动消息" : "打开 App 一次即可同步").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(entry.items.prefix(limit)), id: \.self) { item in
                    Link(destination: URL(string: "minis://bot/" + item.botId)!) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(item.at, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(family == .systemLarge ? 3 : 2)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding()
    }
}

struct CloudTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CloudTodayWidget", provider: CloudTodayProvider()) { entry in
            if #available(iOS 17.0, *) {
                CloudTodayWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
            } else {
                CloudTodayWidgetView(entry: entry)
            }
        }
        .configurationDisplayName("云端 Bot · 今日")
        .description("最近的例行任务结果和 Bot 主动找你的消息。")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}
