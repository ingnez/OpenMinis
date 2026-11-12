import SwiftUI

/// 秒回连发：气泡先上屏，网络发送在后台按顺序排队（队列本身不画出来）。
final class CloudDeliveryBox: ObservableObject {
    struct Item {
        let content: String
        let nonce: String
        let body: [String: Any]
        let alreadyShown: Bool
    }
    var items: [Item] = []
    var running = false
}

/// 用户气泡旁：成功时什么都不画；失败才出红色重试；后台收下插话后标「已采纳」。
struct MessageSendStatusRow: View {
    var failed: Bool = false
    var adopted: Bool = false
    var onRetry: (() -> Void)? = nil

    var body: some View {
        if failed || adopted {
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
            }
        }
    }
}
