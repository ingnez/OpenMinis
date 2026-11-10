import SwiftUI

/// 「N 条待发送 · 网络回来自动发」（而不是红字报错）；长按可放弃
struct CloudOutboxBanner: View {
    let count: Int
    let onDiscard: () -> Void

    var body: some View {
        if count > 0 {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("\(count) 条待发送 · 网络回来自动发").font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 6)
            .contextMenu {
                Button(role: .destructive, action: onDiscard) { Label("放弃待发送的消息", systemImage: "trash") }
            }
            .transition(.opacity)
        }
    }
}
