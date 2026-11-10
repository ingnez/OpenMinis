import SwiftUI

/// 最后一条回复下面的快捷回复按钮
struct CloudSmartReplyBar: View {
    let text: String
    let accent: Color
    let onPick: (String) -> Void

    var body: some View {
        let items = CloudSmartReplies.suggest(text)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { s in
                    Button { onPick(s) } label: {
                        Text(s).font(.footnote.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().stroke(accent.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// 要点板：这个 Bot 钉住的回复（本机保存）；左滑取消钉，点一下复制
struct CloudPinsSheet: View {
    let botId: String
    let botName: String
    @Environment(\.dismiss) private var dismiss
    @State private var pins: [CloudPins.Pin] = []

    var body: some View {
        NavigationStack {
            List {
                if pins.isEmpty {
                    Text("长按 Bot 的回复，选「钉到要点板」").foregroundStyle(.secondary)
                }
                ForEach(pins, id: \.text) { p in
                    Button { UIPasteboard.general.string = p.text; CloudHaptics.success() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.text).font(.subheadline).lineLimit(6)
                            Text(Date(timeIntervalSince1970: p.at), style: .date).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
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
        }
    }
}
