import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudDutyModeTests {
    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let at = { (h: Int, m: Int) in cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: h, minute: m))! }
        let until = at(8, 0)
        check(CloudDutyMode.isOn(dutyUntil: until, now: at(2, 0)), "值班中")
        check(!CloudDutyMode.isOn(dutyUntil: until, now: at(8, 0)), "到点自动恢复")
        check(!CloudDutyMode.isOn(dutyUntil: until, now: at(9, 0)), "下班后关闭")
        check(!CloudDutyMode.isOn(dutyUntil: nil, now: at(2, 0)), "没开值班")
        check(CloudDutyMode.until(dutyUntil: until, now: at(2, 0)) == until, "展示结束时间")
        check(CloudDutyMode.until(dutyUntil: until, now: at(9, 0)) == nil, "结束后没有横幅时间")
        check(!CloudDutyMode.allowSound(onDuty: true, nightSound: true), "值班中不响铃")
        check(!CloudDutyMode.allowSound(onDuty: true, nightSound: false), "值班+夜班不响铃")
        check(CloudDutyMode.allowSound(onDuty: false, nightSound: true), "下班恢复铃声")
        check(!CloudDutyMode.allowSound(onDuty: false, nightSound: false), "夜班仍可静音")
        check(CloudDutyMode.shouldVibrate(onDuty: true, nightHapticsMuted: false), "值班仅震动")
        check(!CloudDutyMode.shouldVibrate(onDuty: true, nightHapticsMuted: true), "夜班滤镜尊重复位震动")
        check(!CloudDutyMode.shouldVibrate(onDuty: false, nightHapticsMuted: false), "下班不用值班震动")
        let text = CloudDutyMode.bannerText(until: until, calendar: cal)
        check(text.contains("08:00") && text.contains("仅震动") && text.contains("不推送")
              && text.contains("结论") && text.contains("单位") && text.contains("自动恢复"), "横幅文案：\(text)")
        print("PASS：值班模式（仅震动、不推送、结论+单位、到点恢复）")
    }
}
