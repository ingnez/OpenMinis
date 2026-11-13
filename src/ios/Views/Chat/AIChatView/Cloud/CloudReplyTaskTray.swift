import SwiftUI

/// 秒回底部任务托盘：原来的状态行 + 暂停 / 继续 / 停止 / 重试。发送键保持发送，不会变成停止。
struct CloudReplyTaskTray: View {
    let worker: CloudReplyWorker
    let count: Int
    let fetchedAt: Date
    let theme: CloudBotChatTheme
    var onExpand: () -> Void
    var onStop: () -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    var onRetry: () -> Void
    var onInterject: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            CloudReplyStatusRow(worker: worker, count: count, fetchedAt: fetchedAt, theme: theme,
                                onExpand: onExpand, onStop: onStop, onInterject: onInterject)
            CloudReplyTrayActions(worker: worker, onPause: onPause, onResume: onResume,
                                  onStop: onStop, onRetry: onRetry)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replyTaskTray")
    }
}

/// 托盘上的动作按钮单独成视图，避免状态行文件再变长、拖慢类型检查。
struct CloudReplyTrayActions: View {
    let worker: CloudReplyWorker
    var onPause: () -> Void
    var onResume: () -> Void
    var onStop: () -> Void
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if worker.canPause {
                btn("暂停", id: "replyTrayPause", action: onPause)
            }
            if worker.canResume {
                btn("继续", id: "replyTrayResume", action: onResume)
            }
            if worker.active || worker.status == "paused" {
                btn("停止", id: "replyTrayStop", action: onStop)
            }
            if worker.canRetry {
                btn("重试", id: "replyTrayRetry", action: onRetry)
            }
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 4)
    }

    private func btn(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier(id)
    }
}
