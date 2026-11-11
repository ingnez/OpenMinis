import SwiftUI
import WidgetKit

@main
struct WatchStatusWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchStatusWidget()
    }
}

struct WatchStatusEntry: TimelineEntry {
    let date: Date
    let snap: WatchWidgetStore.Snapshot
}

struct WatchStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchStatusEntry {
        WatchStatusEntry(date: Date(), snap: WatchWidgetStore.Snapshot(name: "Bot", working: "正在处理", stepsLeft: 3, approvals: 0))
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchStatusEntry) -> Void) {
        completion(WatchStatusEntry(date: Date(), snap: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStatusEntry>) -> Void) {
        completion(Timeline(entries: [WatchStatusEntry(date: Date(), snap: load())], policy: .after(Date().addingTimeInterval(5 * 60))))
    }

    private func load() -> WatchWidgetStore.Snapshot {
        let defaults = UserDefaults(suiteName: WatchWidgetStore.suite) ?? .standard
        return WatchWidgetStore.load(defaults: defaults)
    }
}

struct WatchStatusWidgetView: View {
    let entry: WatchStatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snap = entry.snap
        let working = snap.working != nil
        let status = WatchComplicationText.statusLine(name: snap.name, working: snap.working, stepsLeft: snap.stepsLeft, approvals: snap.approvals)
        let steps = WatchComplicationText.stepsLine(stepsLeft: snap.stepsLeft, working: working)
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Text(working ? "\(max(snap.stepsLeft, 1))" : "·")
                        .font(.headline.monospacedDigit())
                }
            } else if family == .accessoryInline {
                Text(status)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(status).font(.headline).lineLimit(2)
                    Text(steps).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(status + "，" + steps)
        .widgetURL(URL(string: "miniswatch://status")!)
    }
}

struct WatchStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchStatusWidget", provider: WatchStatusProvider()) { entry in
            if #available(watchOS 10.0, *) {
                WatchStatusWidgetView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                WatchStatusWidgetView(entry: entry)
            }
        }
        .configurationDisplayName("Bot 状态")
        .description("看当前 Bot 在干什么、还差几步。点一下可以暂停或批准。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
