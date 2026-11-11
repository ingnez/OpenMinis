import SwiftUI

/// 夜班滤镜：深色 + 轻微暖色（压蓝光）+ 字号至少大一档 + 不震动。每分钟重新判断，到早上 / 值班结束 / 时间表结束自动恢复
struct CloudNightModeModifier: ViewModifier {
    let dutyUntil: Date?
    @AppStorage(CloudNightMode.key) private var setting = "auto"
    @AppStorage(CloudNightMode.startKey) private var startHour = CloudNightMode.nightStart
    @AppStorage(CloudNightMode.endKey) private var endHour = CloudNightMode.nightEnd
    @State private var now = Date()
    @Environment(\.dynamicTypeSize) private var typeSize

    private var active: Bool {
        CloudNightMode.active(setting: setting, dutyUntil: dutyUntil, now: now,
                              startHour: startHour, endHour: endHour)
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(active ? .dark : nil)
            .dynamicTypeSize(active ? max(typeSize, .xLarge) : typeSize)
            .overlay {
                if active {
                    Color(red: 1.0, green: 0.55, blue: 0.15).opacity(0.10)
                        .blendMode(.multiply)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                Text(active ? "夜间护眼已开" : "夜间护眼已关")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("nightEyeCareBadge")
                    .accessibilityValue(active ? "on" : "off")
                    .accessibilityLabel(active ? "夜间护眼已开" : "夜间护眼已关")
                    .padding(.top, 2)
            }
            .onAppear {
                CloudNightMode.hapticsMuted = active
                CloudDataSaverMonitor.start()
                #if canImport(MediaPlayer)
                CloudPocketHeadset.shared.apply()
                #endif
            }
            .onChange(of: active) { CloudNightMode.hapticsMuted = $0 }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    now = Date()
                }
            }
    }
}

/// 值班菜单里的「夜班模式」四档
struct CloudNightModeMenu: View {
    @AppStorage(CloudNightMode.key) private var setting = "auto"

    var body: some View {
        Picker(selection: $setting) {
            Text("值班的夜里自动").tag("auto")
            Text("每天按时间表").tag("schedule")
            Text("常开").tag("on")
            Text("关闭").tag("off")
        } label: {
            Label("夜间护眼（暗色暖光、大字、不震动、通知静音）", systemImage: "moon.stars")
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("nightEyeCareMenu")
    }
}

/// 完整设置页：四档 + 时间表起止小时
struct CloudNightModePage: View {
    @AppStorage(CloudNightMode.key) private var setting = "auto"
    @AppStorage(CloudNightMode.startKey) private var startHour = CloudNightMode.nightStart
    @AppStorage(CloudNightMode.endKey) private var endHour = CloudNightMode.nightEnd

    var body: some View {
        List {
            Section {
                Picker(selection: $setting) {
                    Text("值班的夜里自动").tag("auto")
                    Text("每天按时间表").tag("schedule")
                    Text("常开").tag("on")
                    Text("关闭").tag("off")
                } label: { Text("夜间护眼") }
                .pickerStyle(.inline)
                .accessibilityIdentifier("nightEyeCarePicker")
            } footer: {
                Text("生效时切到更深、更暖的配色，字号至少大一档，本机通知静音、不震动。也可以随时手动打开或关闭。")
            }
            Section {
                Picker("开始", selection: $startHour) {
                    ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                }
                .accessibilityIdentifier("nightEyeCareStart")
                Picker("结束", selection: $endHour) {
                    ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                }
                .accessibilityIdentifier("nightEyeCareEnd")
            } header: {
                Text("时间表")
            } footer: {
                Text("默认 20:00 到次日 08:00。选择「每天按时间表」时按这个时段自动切换；选「值班的夜里自动」时还要正在值班才会生效。")
            }
        }
        .navigationTitle("夜间护眼")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 值班菜单里的「病区语音」两个开关（默认都关）
struct CloudWardVoiceMenu: View {
    @AppStorage(CloudWardVoice.denoiseKey) private var denoise = false
    @AppStorage(CloudWardVoice.doubleTapKey) private var doubleTap = false

    var body: some View {
        Toggle(isOn: $denoise) { Label("嘈杂环境降噪（系统通话降噪）", systemImage: "waveform.badge.minus") }
        Toggle(isOn: $doubleTap) { Label("双击消息区开语音", systemImage: "hand.tap") }
    }
}
