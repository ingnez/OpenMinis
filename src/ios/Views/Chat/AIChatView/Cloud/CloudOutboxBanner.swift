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

/// 发送前的隐私提醒对话框
struct CloudPrivacyDialog: ViewModifier {
    @Binding var hits: [CloudPrivacyScan.Hit]
    let onRedact: () -> Void
    let onSend: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("发现可能的病人身份信息", isPresented: Binding(get: { !hits.isEmpty }, set: { if !$0 { hits = [] } }),
                                   titleVisibility: .visible) {
            Button("隐去后发送", action: onRedact)
            Button("照原样发送", action: onSend)
            Button("取消", role: .cancel) { hits = [] }
        } message: {
            Text(CloudPrivacyScan.summary(hits) + "。只在手机上检查，不会上传。")
        }
    }
}
