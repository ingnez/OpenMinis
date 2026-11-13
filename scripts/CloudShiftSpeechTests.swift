import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudShiftSpeechTests {
    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        // 2026-11-12 10:00 +08
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 12; c.hour = 10; c.minute = 0
        let now = cal.date(from: c)!

        check(CloudShiftSpeech.parse("交班", now: now, calendar: cal) == nil, "只说交班不建任务")
        check(CloudShiftSpeech.parse("   ", now: now, calendar: cal) == nil, "空话")

        let tmr = CloudShiftSpeech.parse("明天下午三点提醒我给病人换药", now: now, calendar: cal, timezone: cal.timeZone)!
        check(tmr.kind == "once", "明天是一次性")
        let tmrDate = Date(timeIntervalSince1970: tmr.at!)
        let tc = cal.dateComponents([.year, .month, .day, .hour, .minute], from: tmrDate)
        check(tc.day == 13 && tc.hour == 15 && tc.minute == 0, "明天 15:00：\(tc)")
        check(tmr.summary.contains("15:00"), "摘要含时间")
        check(CloudShiftSpeech.schedule(of: tmr)["kind"] as? String == "once", "schedule once")

        let daily = CloudShiftSpeech.parse("每天下午 5 点交班：核对输液", now: now, calendar: cal, timezone: cal.timeZone)!
        check(daily.kind == "cron" && daily.cron == "0 17 * * *", "每天 17:00 cron：\(daily.cron ?? "")")
        check((CloudShiftSpeech.schedule(of: daily)["expr"] as? String) == "0 17 * * *", "schedule cron")

        let week = CloudShiftSpeech.parse("每周一早上8点查房", now: now, calendar: cal, timezone: cal.timeZone)!
        check(week.kind == "cron" && week.cron == "0 8 * * 1", "每周一 8:00：\(week.cron ?? "")")

        let later = CloudShiftSpeech.parse("2小时后提醒我看化验单", now: now, calendar: cal, timezone: cal.timeZone)!
        check(later.kind == "once" && abs((later.at ?? 0) - now.addingTimeInterval(7200).timeIntervalSince1970) < 1, "两小时后")

        let todayPast = CloudShiftSpeech.parse("今天8点已经过了也要提醒换药", now: now, calendar: cal, timezone: cal.timeZone)!
        let p = cal.dateComponents([.day, .hour], from: Date(timeIntervalSince1970: todayPast.at!))
        check(p.day == 13 && p.hour == 8, "今天已过的钟点推到明天：\(p)")

        let half = CloudShiftSpeech.parse("明天8点半叫我", now: now, calendar: cal, timezone: cal.timeZone)!
        check(cal.component(.minute, from: Date(timeIntervalSince1970: half.at!)) == 30, "点半")

        print("PASS：一句话交班解析（明天/每天/每周/几小时后/已过钟点）")
    }
}
