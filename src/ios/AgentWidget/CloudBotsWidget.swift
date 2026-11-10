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
        if family == .systemSmall {
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
