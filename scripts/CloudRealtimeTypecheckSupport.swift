import SwiftUI
// 云端类型检查不编译 Realtime 文件夹：这里只放云端页面用到的两个入口。
// 声明必须与 Realtime/CloudBotRealtimeCall.swift 一字不差（scripts/check_typecheck_stubs.py 会核对）。
enum CloudBotRealtimeAvailability {
    @MainActor static var isConfigured: Bool { false }
}
struct CloudBotRealtimeCallView: View {
    @MainActor init(botName: String, persona: String, sessionId: String, history: [[String: String]], delegate: @escaping (String) async -> String?, onSaved: @escaping (String?) -> Void, onFallback: @escaping () -> Void) {}
    var body: some View { EmptyView() }
}
struct CloudBotCallLine: Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
}
@MainActor
final class CloudBotCallController: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var connected = false
    @Published private(set) var muted = false
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var speakLevel: Float = 0
    @Published private(set) var elapsed = 0
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var lines: [CloudBotCallLine] = []
    @Published private(set) var pushToTalk = false
    @Published private(set) var startedAt: Date?
    var onEnded: ((Date, Int) -> Void)?
    init() {}
    static var isConfigured: Bool { false }
    func startCloudBot(botName: String, persona: String, sessionId: String, history: [[String: String]],
                       delegate: @escaping (String) async -> String?, onSaved: @escaping (String?) -> Void, pushToTalk: Bool = false) async {}
    func toggleMute() {}
    func setTalking(_ on: Bool) {}
    func setPushToTalk(_ on: Bool) {}
    func interrupt() {}
    func hangUp() {}
}
struct CloudBotCallSettingsSheet: View {
    @ObservedObject var call: CloudBotCallController
    var body: some View { EmptyView() }
}
