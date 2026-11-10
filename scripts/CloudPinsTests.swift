import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudPinsTests {
    static func main() {
        let suite = "pins-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        check(CloudPins.add("b1", text: "示例：去甲起始 0.05", defaults: d, now: 1), "钉上")
        CloudPins.add("b1", text: "示例：第二条", defaults: d, now: 2)
        CloudPins.add("b1", text: "示例：去甲起始 0.05", defaults: d, now: 3)
        check(CloudPins.list("b1", defaults: d).map(\.text) == ["示例：去甲起始 0.05", "示例：第二条"], "重复的提到最前")
        check(CloudPins.list("b2", defaults: d).isEmpty && !CloudPins.add("b2", text: "  ", defaults: d), "按 Bot 分开，空的不钉")
        CloudPins.remove("b1", text: "示例：第二条", defaults: d)
        check(CloudPins.list("b1", defaults: d).count == 1, "取消钉")
        for i in 0..<40 { CloudPins.add("b3", text: "x\(i)", defaults: d) }
        check(CloudPins.list("b3", defaults: d).count == 30, "每个 Bot 最多 30 条")
        check(CloudSmartReplies.suggest("要我把它整理成表格吗？") == ["是的", "不用", "继续"], "问句")
        check(CloudSmartReplies.suggest("一句话：去甲 0.1 μg/kg/min\n\n细节").contains("给出处"), "医学没出处")
        check(!CloudSmartReplies.suggest("一句话：x mg\n依据：示例｜把握度：中").contains("给出处"), "有出处不再要")
        check(CloudSmartReplies.suggest("").isEmpty && CloudSmartReplies.suggest("好的").last == "继续", "空 / 一般")
        check(CloudTips.shouldShow("t1", defaults: d), "新提示要显示")
        CloudTips.markUsed("t1", defaults: d); CloudTips.markUsed("t1", defaults: d)
        check(!CloudTips.shouldShow("t1", defaults: d) && CloudTips.shouldShow("t2", defaults: d), "用过就不再显示")
        d.removePersistentDomain(forName: suite)
        print("PASS：要点板、智能快捷回复、新手提示")
    }
}
