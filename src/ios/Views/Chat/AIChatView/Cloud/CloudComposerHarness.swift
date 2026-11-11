import SwiftUI

/// 只给 XCUITest 用（启动参数 -OpenMinisComposerHarness）：真的 CloudMorphButton + 输入框 + 对话页同样的浮层，
/// 不需要云电脑。测：键盘开着 / 关着点声波都有反应；按住说话之后下一次点按不会被吞。
struct CloudComposerHarness: View {
    static let launchArgument = "-OpenMinisComposerHarness"
    @State private var text = ""
    @State private var taps = 0
    @State private var holds = 0
    @State private var notice: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("taps: \(taps)").accessibilityIdentifier("harnessTapCount")
            Text("holds: \(holds)").accessibilityIdentifier("harnessHoldCount")
            Button("收起键盘") { focused = false }.accessibilityIdentifier("harnessDismissKeyboard")
            Spacer()
            HStack(spacing: 8) {
                TextField("和 Bot 说点什么", text: $text, axis: .vertical)
                    .focused($focused)
                    .padding(.vertical, 10).padding(.leading, 14)
                    .background(Capsule().fill(Color(.systemGray6)))
                    .accessibilityIdentifier("harnessInput")
                CloudMorphButton(action: CloudBotComposerAction.of(hasDraft: !text.isEmpty, working: false, submitting: false, steerInterrupt: true),
                                 tint: .black, inCall: false,
                                 onTap: { taps += 1; CloudHaptics.tap() },
                                 onPushToTalk: { on in if on { holds += 1 } })
                    .accessibilityIdentifier("composerVoiceButton")
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        // 和对话页一样的浮层（撤回、提醒、滚动按钮所在的位置），确认它们不挡按钮
        .overlay(alignment: .bottom) { CloudFollowUpToast(text: $notice) }
        .overlay(alignment: .bottomTrailing) {
            CloudScrollButtons(onTop: {}, onBottom: {}).padding(.bottom, 70)
        }
    }
}
