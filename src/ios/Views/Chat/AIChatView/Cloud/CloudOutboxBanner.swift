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

/// 对话页的附加层（回头提醒提示、待发送横幅、隐私提醒）合成一个修饰器，主视图类型检查轻一些
struct CloudSessionExtras: ViewModifier {
    @Binding var followUp: String?
    let outboxCount: Int
    @Binding var privacyHits: [CloudPrivacyScan.Hit]
    let onDiscard: () -> Void
    let onRedact: () -> Void
    let onSend: () -> Void
    let onAppear: () -> Void
    let onDisappear: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) { CloudFollowUpToast(text: $followUp) }
            .overlay(alignment: .top) { CloudOutboxBanner(count: outboxCount, onDiscard: onDiscard) }
            .modifier(CloudPrivacyDialog(hits: $privacyHits, onRedact: onRedact, onSend: onSend))
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
    }
}

/// 草稿：进对话时恢复，打字时保存（发出去后输入框清空 = 草稿删除）
struct CloudDraftKeeper: ViewModifier {
    let sessionId: String
    @Binding var text: String

    func body(content: Content) -> some View {
        content
            .onAppear { if text.isEmpty, let d = CloudDrafts.load(sessionId) { text = d } }
            .onChange(of: text) { CloudDrafts.save(sessionId, text: $0) }
    }
}

/// 刚发出的一条：5 秒内可撤回
struct CloudRetract: Equatable {
    let taskId: String
    let content: String
    let nonce: String
}

struct CloudRetractToast: ViewModifier {
    @Binding var item: CloudRetract?
    let onUndo: (CloudRetract) -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if let r = item {
                Button { item = nil; onUndo(r) } label: {
                    Label("撤回", systemImage: "arrow.uturn.backward").font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16).padding(.bottom, 92)
                .task(id: r.taskId) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if item == r { item = nil }
                }
            }
        }
    }
}
