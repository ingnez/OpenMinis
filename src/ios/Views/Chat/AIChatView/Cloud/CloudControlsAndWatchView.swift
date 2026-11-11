import SwiftUI

/// 控制中心 / 锁屏按钮选 Bot、快捷指令兜底，以及手表抬腕说话的说明。控制中心控件本身只能在真机系统界面里添加。
struct CloudControlsAndWatchView: View {
    var onPreview: (String?) -> Void
    @ObservedObject private var model = CloudBotHomeModel.shared

    var body: some View {
        List {
            Section {
                Text("iOS 18 及以上：在控制中心或锁屏加上「和 Bot 语音」按钮后，可以选要打开的 Bot；不选就是主 Bot。")
                Text("iOS 16、17 没有这种控件，请到「快捷指令」里用「和云端 Bot 语音」，把要开的 Bot 填上，再放到锁屏、操作按钮或主屏幕。")
            } header: {
                Text("控制中心与快捷指令")
            } footer: {
                Text("按钮走 minis://bot/<id>?voice=1，和快捷指令是同一条路径。")
            }

            Section {
                if model.bots.isEmpty {
                    Text("打开一次首页同步 Bot 列表后，这里会出现可预览的入口。").foregroundStyle(.secondary)
                } else {
                    ForEach(model.bots.filter { !$0.hidden }) { bot in
                        Button {
                            CloudHaptics.selection()
                            onPreview(bot.id)
                        } label: {
                            HStack(spacing: 12) {
                                CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bot.name).foregroundStyle(.primary)
                                    Text("预览：像控制中心那样打开语音").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if bot.isPrimary { Text("主 Bot").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        .accessibilityIdentifier("previewControlVoice-\(bot.id)")
                        .accessibilityLabel("预览：像控制中心那样打开\(bot.name)的语音")
                    }
                }
            } header: {
                Text("预览语音入口")
            }

            Section {
                Text("手表没有公开的「抬腕」接口。如果手表上已经打开了 Minis，放下手腕后再抬起来，系统会唤醒 App，这时会弹出系统听写；说完的文字经过和手机相同的脱敏，发给当前 Bot。")
                Text("刚打开手表 App 的那一次不会自动听写。可在手表上关掉「抬腕听写」，或点「说话」手动开始。点「在手机上通话」会打开当前 Bot 的语音通话。")
            } header: {
                Text("手表抬腕说话")
            } footer: {
                Text("抬腕动作本身无法在模拟器里测，需要配对手表的真机。")
            }

            Section {
                Text("夜班模式生效时，本机通知静音、不震动；配对手表可达时，完成提醒改成按头像颜色区分的轻触。手表 App 不可达时不补震、不改回有声。")
                Text("App 被杀掉时，Bark 或其他服务器推送若自己带了声音，本 App 改不了，请在系统专注模式里静音。")
            } header: {
                Text("夜班通知")
            }
        }
        .navigationTitle("控制中心与手表")
        .navigationBarTitleDisplayMode(.inline)
    }
}
