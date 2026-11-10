import SwiftUI

/// 夜班滤镜：深色 + 轻微暖色（压蓝光）+ 字号至少大一档 + 不震动。每分钟重新判断，到早上 / 值班结束自动恢复
struct CloudNightModeModifier: ViewModifier {
    let dutyUntil: Date?
    @AppStorage(CloudNightMode.key) private var setting = "auto"
    @State private var now = Date()
    @Environment(\.dynamicTypeSize) private var typeSize

    private var active: Bool { CloudNightMode.active(setting: setting, dutyUntil: dutyUntil, now: now) }

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
            .onAppear { CloudNightMode.hapticsMuted = active }
            .onChange(of: active) { CloudNightMode.hapticsMuted = $0 }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    now = Date()
                }
            }
    }
}

/// 值班菜单里的「夜班模式」三档
struct CloudNightModeMenu: View {
    @AppStorage(CloudNightMode.key) private var setting = "auto"

    var body: some View {
        Picker(selection: $setting) {
            Text("值班的夜里自动").tag("auto")
            Text("常开").tag("on")
            Text("关闭").tag("off")
        } label: {
            Label("夜班模式（暗色暖光、大字、不震动）", systemImage: "moon.stars")
        }
        .pickerStyle(.menu)
    }
}
