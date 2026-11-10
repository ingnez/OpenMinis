import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct MinisWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene {
        WindowGroup { WatchHomeView(model: model) }
    }
}

/// 收手机发来的 Bot 列表；手表自己不连云电脑
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var rows: [WatchBotRow] = []
    @Published private(set) var sentAt: Date?
    /// 最近一次「干完了」的 Bot 名字（列表顶上显示几秒）
    @Published private(set) var doneName: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func apply(_ context: [String: Any]) {
        let rows = WatchBotRow.decode(context)
        let sent = (context[WatchBotRow.sentKey] as? Double).map { Date(timeIntervalSince1970: $0) }
        DispatchQueue.main.async {
            self.rows = rows
            self.sentAt = sent
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        apply(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let tap = WatchTap(message) else { return }
        DispatchQueue.main.async { self.play(tap) }
    }

    private func play(_ tap: WatchTap) {
        let device = WKInterfaceDevice.current()
        for (i, t) in WatchTap.schedule(beats: WatchTap.beats(for: tap.botId), light: tap.light).enumerated() {
            let kind: WKHapticType = (!tap.light && i == 0) ? .notification : .click
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { device.play(kind) }
        }
        doneName = tap.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if self.doneName == tap.name { self.doneName = nil } }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }
}

struct WatchHomeView: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        NavigationStack {
            List {
                if let done = model.doneName {
                    Label("\(done.isEmpty ? "Bot" : done) 干完了", systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                }
                if model.rows.isEmpty {
                    Text("打开 iPhone 上的 Minis 多 Bot 首页后，这里会显示你的 Bot").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if row.working != nil { Circle().fill(Color.green).frame(width: 7, height: 7) }
                            Text(row.name).font(.headline).lineLimit(1)
                        }
                        Text(row.working ?? row.preview).font(.caption2)
                            .foregroundStyle(row.working != nil ? Color.green : Color.secondary).lineLimit(2)
                    }
                }
                if let sent = model.sentAt {
                    Text("更新于 \(sent.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .navigationTitle(workingTitle)
        }
    }

    private var workingTitle: String {
        let n = model.rows.filter { $0.working != nil }.count
        return n > 0 ? "\(n) 个在干活" : "Minis"
    }
}
