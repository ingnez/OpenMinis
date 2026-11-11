import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudBotComposerTests {
    static func main() {
        typealias A = CloudBotComposerAction
        check(A.of(hasDraft: false, working: false, submitting: false, steerInterrupt: true) == .call, "没字 = 声波")
        check(A.of(hasDraft: true, working: false, submitting: false, steerInterrupt: true) == .send, "有字 = 发送")
        check(A.of(hasDraft: false, working: true, submitting: false, steerInterrupt: true) == .call, "干活中没字仍是声波，不变停止键")
        check(A.of(hasDraft: true, working: true, submitting: false, steerInterrupt: true) == .steer(interrupt: true), "干活 + 草稿 = 插话")
        check(A.of(hasDraft: true, working: true, submitting: false, steerInterrupt: false) == .steer(interrupt: false), "排队")
        check(A.of(hasDraft: true, working: true, submitting: true, steerInterrupt: false) == .busy, "提交中优先")
        check(A.send.enabled(inCall: true) && !A.busy.enabled(inCall: false) && !A.call.enabled(inCall: true) && A.call.enabled(inCall: false), "可点状态")
        check(A.call.symbol == "waveform" && A.send.symbol == "arrow.up", "图标")
        check(![A.call, .send, .steer(interrupt: true), .steer(interrupt: false), .busy].contains { $0.symbol.contains("stop") }, "任何状态都没有停止方块")
        check(A.call.supportsPushToTalk && !A.send.supportsPushToTalk, "只有声波支持按住说话")
        check(Set([A.call, .send, .steer(interrupt: true), .steer(interrupt: false), .busy].map(\.morphKey)).count == 5, "每种状态有不同的变形标识")
        var seq: [A] = []
        for draft in [false, true, true, false] { seq.append(A.of(hasDraft: draft, working: false, submitting: false, steerInterrupt: true)) }
        check(seq == [.call, .send, .send, .call], "打字 / 清空来回变形")
        // 两种模式：同一套状态机，只有占位文字不同
        check(A.placeholder(botName: "小厨", localHint: true) == "向 小厨 提问", "Bot 模式占位")
        check(A.placeholder(botName: nil, localHint: true) == "发消息，@ 交给 Bot" && A.placeholder(botName: "", localHint: false) == "发消息", "本地模式占位保留交给 Bot 提示")
        var local: [A] = []
        for (d, w) in [(false, false), (true, false), (false, true), (true, true)] { local.append(A.of(hasDraft: d, working: w, submitting: false, steerInterrupt: false)) }
        check(local == [.call, .send, .call, .steer(interrupt: false)], "本地模式：生成中也能排队发送")
        check(CloudBotCallText.divider(seconds: 75) == "♪ 语音聊天 · 01:15", "挂断分隔线")
        check(CloudBotCallText.clock(-3) == "00:00", "时长不为负")
        check(CloudBotCallText.typingStatus(taskStatus: "running", tool: nil) == "正在输入…", "正在输入")
        check(CloudBotCallText.typingStatus(taskStatus: "running", tool: "shell_exec") == "编写代码中", "编写代码中")
        check(CloudBotCallText.typingStatus(taskStatus: "running", tool: "browser_action") == "查资料中", "查资料中")
        check(CloudBotCallText.typingStatus(taskStatus: "queued", tool: nil) == "排队中…", "排队中")
        check(CloudBotCallText.typingStatus(taskStatus: "completed", tool: "shell") == nil && CloudBotCallText.typingStatus(taskStatus: nil, tool: nil) == nil, "完成后不显示")
        var m = RealtimeLevelMeter()
        var loud = Data(); for i in 0..<480 { let v = Int16(i % 2 == 0 ? 12000 : -12000); loud.append(UInt8(truncatingIfNeeded: v)); loud.append(UInt8(truncatingIfNeeded: v >> 8)) }
        let quiet = Data(count: 960)
        check(RealtimeLevelMeter.level(pcm16: quiet) == 0 && RealtimeLevelMeter.level(pcm16: Data()) == 0, "静音电平为 0")
        let lv = RealtimeLevelMeter.level(pcm16: loud)
        check(lv > 0.5 && lv <= 1, "说话电平")
        let up = m.feed(lv)
        let down = m.feed(0)
        check(up > 0 && down < up && down > 0, "上升快、下降慢")
        for _ in 0..<80 { _ = m.decay() }
        check(m.value == 0, "最终落回 0")
        check(CloudTintContrast.prefersDarkGlyph(r: 1, g: 0.85, b: 0.2), "黄色底用深色图标")
        check(!CloudTintContrast.prefersDarkGlyph(r: 0.1, g: 0.1, b: 0.12), "黑色底用白色图标")
        check(!CloudTintContrast.prefersDarkGlyph(r: 0.2, g: 0.4, b: 0.9), "蓝色底用白色图标")
        check(CloudTintContrast.prefersDarkGlyph(r: 0.95, g: 0.95, b: 0.95), "白色底用深色图标")
        let ud = UserDefaults(suiteName: "cbc-test-\(UUID().uuidString)")!
        CloudCallDivider.add("s1", start: Date(timeIntervalSince1970: 150), seconds: 75, defaults: ud)
        CloudCallDivider.add("s1", start: Date(timeIntervalSince1970: 10), seconds: 0, defaults: ud)
        let dv = CloudCallDivider.load("s1", defaults: ud)
        check(dv.count == 1 && dv[0].seconds == 75, "分隔线按会话保存，0 秒不存")
        check(CloudCallDivider.anchor(dv[0], timestamps: [100, 140, 160]) == 1 && CloudCallDivider.anchor(dv[0], timestamps: [200]) == -1, "分隔线位置")
        check(CloudCallDivider.load("s2", defaults: ud).isEmpty, "别的会话没有")
        // 声波按钮：按住说话结束后 0.4 秒内的点按吞掉，之后的点按是新的一次（以前永久标记会吞掉下一次真正的点按）
        let t0 = Date(timeIntervalSince1970: 1000)
        check(!CloudMorphTap.swallow(holdEndedAt: nil, now: t0), "没按住过不吞")
        check(CloudMorphTap.swallow(holdEndedAt: t0, now: t0.addingTimeInterval(0.1)), "松手紧跟的点按吞掉")
        check(!CloudMorphTap.swallow(holdEndedAt: t0, now: t0.addingTimeInterval(2)), "隔久了的点按不吞")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("Bot 输入框按钮状态机测试全部通过")
    }
}
