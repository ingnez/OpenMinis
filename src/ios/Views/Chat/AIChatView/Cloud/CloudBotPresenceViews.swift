import SwiftUI

extension CloudBotPresence.State {
    /// 圆点颜色：系统色在浅色 / 深色下都清楚
    var color: Color {
        switch self {
        case .offline: return Color(.systemGray)
        case .needsYou: return .orange
        case .error: return .red
        case .working: return .green
        case .unread: return .blue
        case .idle: return .clear
        }
    }
}

/// 头像右下角的状态圆点（工作中轻轻呼吸）；外圈是背景色，叠在任何头像上都分得开
struct CloudPresenceBadge: View {
    let presence: CloudBotPresence
    var size: CGFloat = 12
    @State private var breathe = false

    var body: some View {
        if presence.hasBadge {
            Circle().fill(presence.state.color)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: max(2, size * 0.18)))
                .scaleEffect(presence.pulses && breathe ? 1.15 : 1)
                .opacity(presence.pulses && breathe ? 0.8 : 1)
                .animation(presence.pulses ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: breathe)
                .onAppear { breathe = presence.pulses }
                .onChange(of: presence.pulses) { p in breathe = p }
                .accessibilityHidden(true)
        }
    }
}

/// 行尾 / 大头像名字旁的未读标记：1 条蓝点，多条蓝底数字
struct CloudUnreadMark: View {
    let presence: CloudBotPresence

    var body: some View {
        if let text = presence.unreadBadgeText {
            Text(text).font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Color.blue))
                .accessibilityHidden(true)
        } else if presence.unread > 0 {
            Circle().fill(Color.blue).frame(width: 9, height: 9).accessibilityHidden(true)
        }
    }
}

/// 名字后面的附加标记：例行任务（时钟）、静音（铃铛划线）
struct CloudPresenceFlags: View {
    let presence: CloudBotPresence

    var body: some View {
        HStack(spacing: 4) {
            if presence.routine != .none {
                Image(systemName: presence.routine == .running ? "clock.fill" : "clock")
                    .foregroundStyle(presence.routine == .running ? Color.green : Color.secondary)
            }
            if presence.muted { Image(systemName: "bell.slash").foregroundStyle(.secondary) }
        }
        .font(.caption)
        .accessibilityHidden(true)
    }
}
