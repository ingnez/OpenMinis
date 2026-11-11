#if canImport(WidgetKit)
import SwiftUI
import WidgetKit

/// 手表表盘小组件。要真正出现在表盘上，还需要把这个目录加进 watchOS Widget Extension 目标并在真机上添加。
/// 文案和进度与 WatchComplicationText / 手机预览页相同。
struct WatchStatusEntry: TimelineEntry {
    let date: Date
    let name: String
    let working: String?
    let stepsLeft: Int
    let approvals: Int
}

struct WatchStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchStatusEntry {
        WatchStatusEntry(date: Date(), name: "Bot", working: "正在处理", stepsLeft: 3, approvals: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchStatusEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStatusEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(5 * 60))))
    }

    private func load() -> WatchStatusEntry {
        let defaults = UserDefaults(suiteName: "group.com.openminis.app")
        let name = defaults?.string(forKey: "OpenMinisWatch_widgetName") ?? "Bot"
        let working = defaults?.string(forKey: "OpenMinisWatch_widgetWorking")
        let steps = defaults?.integer(forKey: "OpenMinisWatch_widgetSteps") ?? 0
        let approvals = defaults?.integer(forKey: "OpenMinisWatch_widgetApprovals") ?? 0
        return WatchStatusEntry(date: Date(), name: name, working: working, stepsLeft: steps, approvals: approvals)
    }
}

struct WatchStatusWidgetView: View {
    let entry: WatchStatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let working = entry.working != nil
        let status = WatchComplicationText.statusLine(name: entry.name, working: entry.working, stepsLeft: entry.stepsLeft, approvals: entry.approvals)
        let steps = WatchComplicationText.stepsLine(stepsLeft: entry.stepsLeft, working: working)
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Text(working ? "\(max(entry.stepsLeft, 1))" : "·")
                    .font(.headline.monospacedDigit())
            }
            .accessibilityLabel(status + "，" + steps)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(status).font(.headline).lineLimit(2)
                Text(steps).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityLabel(status + "，" + steps)
        }
    }
}

struct WatchStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchStatusWidget", provider: WatchStatusProvider()) { entry in
            WatchStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Bot 状态")
        .description("看当前 Bot 在干什么、还差几步。点一下可以暂停或批准。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
#endif
