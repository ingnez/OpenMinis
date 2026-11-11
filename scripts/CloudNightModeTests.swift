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
        check(CloudNightMode.notifyStyle(muted: true) == CloudNightMode.NotifyStyle(sound: false, interrupt: false), "夜班通知静音")
        check(CloudNightMode.notifyStyle(muted: false) == CloudNightMode.NotifyStyle(sound: true, interrupt: true), "白天通知有声")
        check(CloudNightMode.active(setting: "schedule", dutyUntil: nil, now: at(23), calendar: cal), "按时间表：深夜")
        check(!CloudNightMode.active(setting: "schedule", dutyUntil: nil, now: at(14), calendar: cal), "按时间表：白天")
        check(CloudNightMode.active(setting: "schedule", dutyUntil: nil, now: at(22), calendar: cal, startHour: 22, endHour: 6), "自定义开始")
        check(!CloudNightMode.active(setting: "schedule", dutyUntil: nil, now: at(21), calendar: cal, startHour: 22, endHour: 6), "自定义开始前")
        check(CloudNightMode.isNightHour(10, start: 8, end: 18) && !CloudNightMode.isNightHour(19, start: 8, end: 18), "同一天窗口")
        check(CloudNightMode.isNightHour(12, start: 7, end: 7), "起止相同=全天")
        check(CloudNightMode.active(setting: "auto", dutyUntil: later, now: at(21), calendar: cal, startHour: 22, endHour: 6) == false, "值班但还没到自定义时段")
        print("PASS：夜班模式生效规则")
    }
}
