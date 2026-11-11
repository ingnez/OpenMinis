import SwiftUI

/// 秒回连发：气泡先上屏，网络发送在后台按顺序排队。
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

/// 用户气泡下的发送勾和「已采纳」。
struct MessageSendStatusRow: View {
    let tick: MessageSendTick?
    var adopted: Bool = false

    var body: some View {
        if tick != nil || adopted {
            HStack(spacing: 6) {
                if let tick {
                    Image(systemName: tick == .sending ? "ellipsis" : "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("replySendTick")
                        .accessibilityValue(tick.rawValue)
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
