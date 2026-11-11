import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudShiftSupportTests {
    static func main() {
        check(CloudShiftIntent.isUtterance("交班"), "交班")
        check(CloudShiftIntent.isUtterance("交班卡"), "交班卡")
        check(CloudShiftIntent.isUtterance("/交班"), "/交班")
        check(CloudShiftIntent.isUtterance("交班。"), "交班加句号")
        check(!CloudShiftIntent.isUtterance("交班要点怎么写"), "不是单独一句")
        check(!CloudShiftIntent.isUtterance(""), "空")
        let suite = "shift-pin-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        check(!CloudShiftPin.shouldShow(in: d), "默认不弹")
        CloudShiftPin.mark(d)
        check(CloudShiftPin.shouldShow(in: d), "标记后下次打开要弹")
        CloudShiftPin.consume(d)
        check(!CloudShiftPin.shouldShow(in: d), "看过之后清掉")
        d.removePersistentDomain(forName: suite)
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("交班意图和卡片钉住测试全部通过")
    }
}
