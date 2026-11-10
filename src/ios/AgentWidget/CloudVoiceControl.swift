import AppIntents
import SwiftUI
import WidgetKit

/// 控制中心 / 锁屏 / 操作按钮控件（iOS 18+）：一按打开 Minis 直接和主 Bot 语音。
/// 走深链 minis://bot/?voice=1，App 里沿用「和云端 Bot 语音」快捷指令的同一条路径。iOS 16–17 没有这种控件，用快捷指令代替。
@available(iOSApplicationExtension 18.0, *)
struct CloudVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "CloudVoiceControl") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "minis://bot/?voice=1")!)) {
                Label("和 Bot 语音", systemImage: "waveform")
            }
        }
        .displayName("和 Bot 语音")
        .description("打开 Minis，直接和主 Bot 通话")
    }
}
