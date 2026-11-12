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

/// 本地对话的通话条和实时字幕，由顶部安全区为它们留出空间。
struct LocalCallOverlay: View {
    @ObservedObject var call: CloudBotCallController
    let name: String
    let tint: Color

    var body: some View {
        if call.active {
            VStack(spacing: 4) {
                CloudCallCapsule(call: call, name: name)
                CloudCallLiveLines(lines: Array(call.lines.suffix(1)), tint: tint)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
            .padding(.vertical, 4)
            .transition(.opacity)
        }
    }
}
