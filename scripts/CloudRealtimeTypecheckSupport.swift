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
