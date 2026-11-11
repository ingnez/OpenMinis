import SwiftUI
import WatchConnectivity
import WatchKit
#if canImport(WidgetKit)
import WidgetKit
#endif

@main
struct MinisWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene {
        WindowGroup { WatchHomeView(model: model) }
    }
}

/// 收手机发来的 Bot 列表；手表自己不连云电脑。抬腕唤醒已打开的 App 时开始系统听写（没有公开的抬腕 API）。
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var rows: [WatchBotRow] = []
    @Published private(set) var sentAt: Date?
    /// 最近一次「干完了」的 Bot 名字（列表顶上显示几秒）
    @Published private(set) var doneName: String?
    @Published private(set) var currentId: String?
    @Published var raiseEnabled = true
    @Published var status: String?
    @Published private(set) var hasBecomeActiveOnce = false

    private var previousPhase: WatchScenePhase = .background
    private var cooldownUntil: Date?
    private static let raiseKey = "OpenMinisWatch_raiseToSpeak"

    var currentName: String {
        if let currentId, let row = rows.first(where: { $0.id == currentId }) { return row.name }
        return rows.first?.name ?? "当前 Bot"
    }

    override init() {
        super.init()
        if UserDefaults.standard.object(forKey: Self.raiseKey) != nil {
            raiseEnabled = UserDefaults.standard.bool(forKey: Self.raiseKey)
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func setRaiseEnabled(_ on: Bool) {
        raiseEnabled = on
        UserDefaults.standard.set(on, forKey: Self.raiseKey)
    }

    private func apply(_ context: [String: Any]) {
        let rows = WatchBotRow.decode(context)
        let sent = (context[WatchBotRow.sentKey] as? Double).map { Date(timeIntervalSince1970: $0) }
        let current = WatchBotRow.currentId(from: context)
        DispatchQueue.main.async {
            self.rows = rows
            self.sentAt = sent
            self.currentId = current
            let snap = WatchWidgetStore.snapshot(rows: rows, currentId: current)
            if let defaults = UserDefaults(suiteName: WatchWidgetStore.suite) {
                WatchWidgetStore.save(snap, defaults: defaults)
            }
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }

    func handleScene(now: WatchScenePhase) {
        let prev = previousPhase
        if WatchRaiseToSpeak.shouldStartListening(
            previous: prev, current: now, enabled: raiseEnabled,
            hasBecomeActiveOnce: hasBecomeActiveOnce, cooldownUntil: cooldownUntil, now: Date()
        ) {
            startDictation()
        }
        if now == .active { hasBecomeActiveOnce = true }
        previousPhase = now
    }

    func startDictation() {
        guard let ctl = Self.visibleController() else {
            flash("现在无法开始听写")
            return
        }
        ctl.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { [weak self] result in
            let text = (result as? [String])?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            DispatchQueue.main.async {
                self?.cooldownUntil = Date().addingTimeInterval(WatchRaiseToSpeak.cooldown)
                guard let text, !text.isEmpty else { return }
                self?.send(WatchSpeakRequest(text: text, botId: self?.currentId).dict, ok: "已发给 \(self?.currentName ?? "Bot")")
            }
        }
    }

    func startPhoneVoice() {
        send(WatchVoiceRequest(botId: currentId).dict, ok: "正在手机上打开通话")
    }

    func sendControl(_ action: WatchControlRequest.Action, row: WatchBotRow) {
        let ok: String
        switch action {
        case .pause: ok = "已请手机暂停"
        case .approve: ok = "已请手机批准"
        case .deny: ok = "已请手机拒绝"
        }
        send(WatchControlRequest(action: action, botId: row.id, taskId: row.taskId, approvalId: row.approvalId).dict, ok: ok)
    }

    private func send(_ message: [String: Any], ok: String) {
        let s = WCSession.default
        guard s.activationState == .activated else {
            flash("还没连上 iPhone")
            return
        }
        if s.isReachable {
            s.sendMessage(message, replyHandler: { [weak self] _ in
                DispatchQueue.main.async { self?.flash(ok) }
            }, errorHandler: { [weak self] _ in
                s.transferUserInfo(message)
                DispatchQueue.main.async { self?.flash(ok) }
            })
        } else {
            s.transferUserInfo(message)
            flash(ok + "（等手机连上再发）")
        }
    }

    private func flash(_ text: String) {
        status = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self.status == text { self.status = nil } }
    }

    private static func visibleController() -> WKInterfaceController? {
        if #available(watchOS 10.0, *) {
            return WKApplication.shared().visibleInterfaceController
        }
        return WKExtension.shared().visibleInterfaceController
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
        let beats = WatchTap.beats(botId: tap.botId, color: tap.color)
        for (i, t) in WatchTap.schedule(beats: beats, light: tap.light).enumerated() {
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedFromComplication = false

    var body: some View {
        NavigationStack {
            List {
                if let done = model.doneName {
                    Label("\(done.isEmpty ? "Bot" : done) 干完了", systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                }
                if let status = model.status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button { model.startDictation() } label: {
                        Label("对 \(model.currentName) 说话", systemImage: "mic")
                    }
                    Button { model.startPhoneVoice() } label: {
                        Label("在手机上开始通话", systemImage: "waveform")
                    }
                    Toggle("抬腕听写", isOn: Binding(
                        get: { model.raiseEnabled },
                        set: { model.setRaiseEnabled($0) }
                    ))
                    Text("没有单独的抬腕接口：已打开本 App 时，放下手腕再抬起来会开始系统听写。第一次打开不会自动听写。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if model.rows.isEmpty {
                    Text("打开 iPhone 上的 Minis 多 Bot 首页后，这里会显示你的 Bot").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    NavigationLink {
                        WatchStatusView(row: row, onControl: { model.sendControl($0, row: row) })
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if row.working != nil { Circle().fill(Color.green).frame(width: 7, height: 7) }
                                Text(row.name).font(.headline).lineLimit(1)
                                if row.id == model.currentId { Text("当前").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text(row.working ?? row.preview).font(.caption2)
                                .foregroundStyle(row.working != nil ? Color.green : Color.secondary).lineLimit(2)
                            if row.working != nil || row.stepsLeft > 0 || row.waitingApprovals > 0 {
                                Text(WatchComplicationText.stepsLine(stepsLeft: row.stepsLeft, working: row.working != nil))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let sent = model.sentAt {
                    Text("更新于 \(sent.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .navigationTitle(workingTitle)
            .navigationDestination(isPresented: $openedFromComplication) {
                if let row = model.rows.first(where: { $0.id == model.currentId }) ?? model.rows.first {
                    WatchStatusView(row: row, onControl: { model.sendControl($0, row: row) })
                }
            }
            .onOpenURL { url in
                if url.scheme == "miniswatch" { openedFromComplication = true }
            }
            .onChange(of: scenePhase) { phase in
                model.handleScene(now: Self.map(phase))
            }
            .onAppear { model.handleScene(now: Self.map(scenePhase)) }
        }
    }

    private var workingTitle: String {
        let n = model.rows.filter { $0.working != nil }.count
        return n > 0 ? "\(n) 个在干活" : "Minis"
    }

    private static func map(_ phase: ScenePhase) -> WatchScenePhase {
        switch phase {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .inactive
        }
    }
}
