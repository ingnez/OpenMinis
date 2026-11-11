import SwiftUI

/// 把当前这条结果交给另一个 Bot 继续：选 Bot → POST /v1/relay → 打开对方对话。
struct CloudBotRelaySheet: View {
    let fromBot: String?
    let fromSession: String?
    let result: String
    let context: String
    var goal: String = ""
    let excludeId: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var home = CloudBotHomeModel.shared
    @State private var sending: String?
    @State private var error: String?
    @State private var receipt: CloudBotRelay.Receipt?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(CloudBotRelay.clip(result, 240)).font(.footnote).foregroundStyle(.secondary)
                } header: { Text("要交给对方的结果") }
                Section {
                    ForEach(home.bots.filter { $0.id != excludeId }) { bot in
                        Button { Task { await relay(to: bot) } } label: {
                            HStack {
                                Text(bot.name)
                                Spacer()
                                if sending == bot.id { ProgressView() }
                            }
                        }
                        .disabled(sending != nil)
                        .accessibilityIdentifier("relayBot-\(bot.id)")
                    }
                } header: { Text("交给谁") }
                if let receipt {
                    Section {
                        Button(receipt.title) {
                            dismiss()
                            CloudBotEntry.open(bot: receipt.botId, text: nil, send: false)
                        }
                        .accessibilityIdentifier("relayReceipt")
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("交给其他 Bot")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { if home.bots.isEmpty { await home.refresh() } }
        }
        .accessibilityIdentifier("relayBotPicker")
    }

    @MainActor
    private func relay(to bot: CloudBot) async {
        sending = bot.id
        error = nil
        do {
            try await CloudConnection.shared.ensureConnected()
            let pkg = CloudBotRelay.Package(toBot: bot.id, fromBot: fromBot, fromSession: fromSession,
                                            result: result, context: context, goal: goal, nonce: UUID().uuidString)
            let res = try await CloudConnection.shared.request(method: "POST", path: "/v1/relay", body: pkg.body)
            guard let r = CloudBotRelay.Receipt.parse(res) else { error = res["error"] as? String ?? "接力失败"; sending = nil; return }
            receipt = r
            CloudHaptics.success()
        } catch {
            self.error = "没发出去：\(error.localizedDescription)"
        }
        sending = nil
    }
}

/// 任务结束后出现在最后一条回复下面：回放、交给其他 Bot。拆成小视图，避免对话页 body 变长。
struct CloudTaskActionBar: View {
    let taskId: String?
    let hasReplay: Bool
    let result: String
    let fromBot: String?
    let fromSession: String?
    let accent: Color
    @Binding var showReplay: Bool
    @Binding var showRelay: Bool

    var body: some View {
        HStack(spacing: 12) {
            if hasReplay, taskId != nil {
                Button { showReplay = true } label: { Label("回放", systemImage: "play.rectangle") }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("taskReplayButton")
            }
            Button { showRelay = true } label: { Label("交给其他 Bot", systemImage: "arrow.triangle.branch") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("relayToOtherBot")
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}
