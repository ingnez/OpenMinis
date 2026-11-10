import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudNightModeTests {
    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let at = { (h: Int) in cal.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: h, minute: 30))! }
        let later = at(23).addingTimeInterval(12 * 3600)
        check(CloudNightMode.active(setting: "auto", dutyUntil: later, now: at(23), calendar: cal), "值班 + 深夜")
        check(CloudNightMode.active(setting: "auto", dutyUntil: later, now: at(3), calendar: cal), "值班 + 凌晨")
        check(!CloudNightMode.active(setting: "auto", dutyUntil: later, now: at(14), calendar: cal), "值班但白天")
        check(!CloudNightMode.active(setting: "auto", dutyUntil: nil, now: at(23), calendar: cal), "没值班")
        check(!CloudNightMode.active(setting: "auto", dutyUntil: at(22), now: at(23), calendar: cal), "值班已结束自动恢复")
        check(CloudNightMode.active(setting: "on", dutyUntil: nil, now: at(14), calendar: cal), "常开")
        check(!CloudNightMode.active(setting: "off", dutyUntil: later, now: at(23), calendar: cal), "关闭")
        check(CloudNightMode.isNightHour(20) && CloudNightMode.isNightHour(7) && !CloudNightMode.isNightHour(8), "边界")
        print("PASS：夜班模式生效规则")
    }
}
