import SwiftUI

/// 口袋模式说明与开关。音量键系统不开放，设置里如实写限制。
struct CloudPocketModePage: View {
    @AppStorage(CloudPocketMode.key) private var enabled = false
    @AppStorage(CloudPocketMode.replyKey) private var reply = CloudPocketMode.ReplyRoute.both.rawValue

    var body: some View {
        List {
            Section {
                Toggle(isOn: $enabled) {
                    Label("口袋模式", systemImage: "headphones")
                }
                .accessibilityIdentifier("pocketModeToggle")
                Picker("回复怎么送回来", selection: $reply) {
                    ForEach(CloudPocketMode.ReplyRoute.allCases, id: \.rawValue) { r in
                        Text(r.label).tag(r.rawValue)
                    }
                }
                .disabled(!enabled)
                .accessibilityIdentifier("pocketReplyPicker")
            } footer: {
                Text(enabled ? "已打开。用耳机键、操作按钮或快捷指令开始说话。" : "打开后，不掏手机也能问 Bot。")
            }
            Section {
                Text(CloudPocketMode.limitsText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("pocketModeLimits")
            } header: { Text("能用的触发方式和限制") }
            Section {
                Text("快捷指令或操作按钮请用「口袋里问 Bot」，或打开这条深链：minis://bot/?pocket=1。")
                    .font(.footnote)
            } header: { Text("快捷指令") }
        }
        .navigationTitle("口袋模式")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { applyHeadset() }
        .onChange(of: enabled) { _ in applyHeadset() }
    }

    private func applyHeadset() {
        #if canImport(MediaPlayer)
        CloudPocketHeadset.shared.apply(enabled: enabled)
        #endif
    }
}
