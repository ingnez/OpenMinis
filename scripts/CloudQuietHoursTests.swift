import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudQuietHoursTests {
    static func main() {
        let cfg = CloudQuietHoursConfig.parse(["enabled": true, "start": "08:00", "end": "18:00",
                                               "weekdays": [1, 2, 3, 4, 5], "timezone": "Asia/Shanghai"])
        check(CloudQuietHours.isActive(cfg, weekday: 3, hour: 10, minute: 0), "周三上午在窗内")
        check(!CloudQuietHours.isActive(cfg, weekday: 3, hour: 19, minute: 0), "周三晚上不在窗内")
        check(!CloudQuietHours.isActive(cfg, weekday: 7, hour: 10, minute: 0), "周日不在工作日")
        check(CloudQuietHours.shouldHold(cfg, event: "task_complete", weekday: 3, hour: 10, minute: 0), "完成通知要攒")
        check(!CloudQuietHours.shouldHold(cfg, event: "approval_required", weekday: 3, hour: 10, minute: 0), "审批不攒")
        check(!CloudQuietHours.shouldHold(cfg, event: "task_complete", weekday: 3, hour: 19, minute: 0), "下班后不攒")
        var off = cfg; off.enabled = false
        check(!CloudQuietHours.isActive(off, weekday: 3, hour: 10, minute: 0), "关掉就不静默")
        var night = cfg; night.start = "20:00"; night.end = "08:00"; night.weekdays = [1, 2, 3, 4, 5, 6, 7]
        check(CloudQuietHours.isActive(night, weekday: 3, hour: 22, minute: 0), "跨午夜夜里")
        check(CloudQuietHours.isActive(night, weekday: 4, hour: 7, minute: 0), "跨午夜凌晨")
        check(!CloudQuietHours.isActive(night, weekday: 4, hour: 12, minute: 0), "跨午夜中午不在")
        check(CloudQuietHours.summary(cfg).contains("08:00–18:00"), "摘要含时间")
        check(CloudQuietHours.summary(off) == "关", "关闭摘要")
        check(CloudQuietHours.minutes("08:00") == 480 && CloudQuietHours.minutes("25:00") == nil, "HH:MM 校验")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("静默时段测试全部通过")
    }
}
