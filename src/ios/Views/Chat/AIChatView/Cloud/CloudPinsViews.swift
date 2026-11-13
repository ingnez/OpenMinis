import SwiftUI

/// 要点板：这个 Bot 钉住的回复（本机保存）；左滑取消钉，点一下复制
struct CloudPinsSheet: View {
    let botId: String
    let botName: String
    @Environment(\.dismiss) private var dismiss
    @State private var pins: [CloudPins.Pin] = []
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                if pins.isEmpty {
                    Text("长按 Bot 的回复，选「钉到要点板」。右滑一条可写进 Bot 记忆。").foregroundStyle(.secondary)
                }
                ForEach(pins, id: \.text) { p in
                    Button { UIPasteboard.general.string = p.text; CloudHaptics.success() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.text).font(.subheadline).lineLimit(6)
                            Text(Date(timeIntervalSince1970: p.at), style: .date).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button { Task { await remember(p.text) } } label: { Label("记进 Bot 记忆", systemImage: "brain") }.tint(.purple)
                    }
                }
                .onDelete { idx in
                    for i in idx { CloudPins.remove(botId, text: pins[i].text) }
                    pins = CloudPins.list(botId)
                }
            }
            .navigationTitle("\(botName) 的要点板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .onAppear { pins = CloudPins.list(botId) }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好") {} }
        }
    }

    /// 要点板默认只在这台手机上；右滑一条可以写进这个 Bot 的长期记忆，以后的对话它会记得（服务器 /v1/memory）
    private func remember(_ text: String) async {
        do {
            _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/memory",
                                                         body: ["content": String(text.prefix(2000)), "category": "note", "bot_id": botId])
            CloudHaptics.success()
            notice = "已写进 \(botName) 的记忆"
        } catch { notice = error.localizedDescription }
    }
}
