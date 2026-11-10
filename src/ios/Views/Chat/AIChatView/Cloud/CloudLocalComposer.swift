import SwiftUI

/// 本地模式也用同一套新输入框：右侧变形圆按钮 + 顶部浮动通话胶囊。
/// 本地对话同时只开一通实时语音，所以控制器全局一个。
@MainActor
enum CloudLocalCall {
    static let controller = CloudBotCallController()
}

/// 本地输入框最右侧：没字且没在生成 = 声波圆按钮（开实时语音，长按按住说话）；
/// 有字 / 正在生成时交给原来的发送 / 排队按钮（插话、排队都在那里）。
struct LocalMorphTrailing<Fallback: View>: View {
    @ObservedObject var call: CloudBotCallController
    let showsCall: Bool
    let tint: Color
    /// 参数：是否按住说话模式
    let onCall: (Bool) async -> Void
    let fallback: Fallback
    @State private var held = false

    var body: some View {
        if showsCall {
            CloudMorphButton(action: .call, tint: tint, inCall: call.active,
                             onTap: { Task { await onCall(false) } },
                             onPushToTalk: { on in
                                 held = on
                                 if call.active {
                                     call.setTalking(on)
                                 } else if on {
                                     Task {
                                         await onCall(true)
                                         if held { call.setTalking(true) }
                                     }
                                 }
                             })
                .accessibilityIdentifier("realtimeVoiceButton")
        } else {
            fallback
        }
    }
}

/// 本地对话页顶部：通话中显示浮动胶囊和实时字幕（挂断后字幕存进对话）
struct LocalCallOverlay: View {
    @ObservedObject var call: CloudBotCallController
    let name: String
    let tint: Color

    var body: some View {
        if call.active {
            VStack(spacing: 6) {
                CloudCallCapsule(call: call, name: name, tint: tint,
                                 avatar: LocalCallAvatar(tint: tint, level: call.speakLevel))
                CloudCallLiveLines(lines: Array(call.lines.suffix(2)), tint: tint)
                    .padding(.horizontal, 12)
            }
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// 本地助手没有 Bot 头像：用本地主题色的圆，说话时跟着跳
struct LocalCallAvatar: View {
    let tint: Color
    let level: Float

    var body: some View {
        Circle().fill(tint)
            .overlay(Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(tint.cloudGlyph))
            .frame(width: 34, height: 34)
            .scaleEffect(1 + CGFloat(min(max(level, 0), 1)) * 0.18)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: level)
    }
}
