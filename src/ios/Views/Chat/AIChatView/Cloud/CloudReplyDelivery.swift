import SwiftUI

/// 文字、附件和重发都从同一条队列出发。
final class CloudDeliveryBox: ObservableObject {
    struct Item {
        let content: String
        let nonce: String
        var body: [String: Any]
        var attachments: [CloudPendingAttachment] = []
        var providerInstanceId: String? = nil
        var createdAt: Double = Date().timeIntervalSince1970
    }
    struct Received {
        let taskId: String
        let item: Item
    }
    @Published var items: [Item] = []
    @Published var retrying: Set<String> = []
    @Published var waitingNonce: String?
    @Published var uploadingNonce: String?
    @Published var remoteQueue: [String: Received] = [:]
    var inFlightNonce: String?
    var cancelled: Set<String> = []
    var running = false
    var paused = false

    func canWithdraw(_ nonce: String) -> Bool {
        waitingNonce == nonce || items.contains { $0.nonce == nonce } || remoteQueue[nonce] != nil
    }
}

struct CloudLiveReply: Identifiable {
    let nonce: String?
    let message: ChatMessage
    var id: UUID { message.id }
}

/// 用户气泡旁：成功时什么都不画；失败才出红色重试；后台收下插话后标「已采纳」。
struct MessageSendStatusRow: View {
    var failed: Bool = false
    var adopted: Bool = false
    var pendingLabel: String? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        if failed || adopted || pendingLabel != nil {
            HStack(spacing: 6) {
                if failed {
                    Button(action: { onRetry?() }) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("replySendRetry")
                    .accessibilityLabel("发送失败，点一下重试")
                }
                if adopted {
                    Text("已采纳")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("replyAdopted")
                }
                if let pendingLabel {
                    Text(pendingLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
