import Foundation

/// 一句话交班：长按 Bot 头像说的话，解析成一条定时例行任务（once / cron）。
enum CloudShiftSpeech {
    struct Plan: Equatable {
        var name: String
        var prompt: String
        var kind: String            // "once" | "cron"
        var at: Double?             // once
        var cron: String?           // "m h * * *"
        var timezone: String
        var summary: String
    }

    static let defaultZone = "Asia/Shanghai"

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current, timezone: TimeZone? = nil) -> Plan? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        // 只说「交班」不够建任务，交给交班卡
        if raw == "交班" || raw == "交班卡" { return nil }

        var cal = calendar
        if let timezone { cal.timeZone = timezone }
        let zone = timezone?.identifier ?? cal.timeZone.identifier
        let hourMin = parseClock(raw)
        let prompt = raw
        let name = "交班：" + String(raw.replacingOccurrences(of: "\n", with: " ").prefix(20))

        if raw.contains("每天") || raw.contains("每日") {
            let hm = hourMin ?? (8, 0)
            let cron = "\(hm.1) \(hm.0) * * *"
            return Plan(name: name, prompt: prompt, kind: "cron", at: nil, cron: cron, timezone: zone,
                        summary: "每天 \(pad(hm.0)):\(pad(hm.1)) 提醒")
        }
        if let weekday = weekday(in: raw) {
            let hm = hourMin ?? (8, 0)
            let cron = "\(hm.1) \(hm.0) * * \(weekday)"
            return Plan(name: name, prompt: prompt, kind: "cron", at: nil, cron: cron, timezone: zone,
                        summary: "每周\(weekdayName(weekday)) \(pad(hm.0)):\(pad(hm.1)) 提醒")
        }
        if let delta = delay(in: raw) {
            let at = now.addingTimeInterval(delta).timeIntervalSince1970
            return Plan(name: name, prompt: prompt, kind: "once", at: at, cron: nil, timezone: zone,
                        summary: "将在 \(clockString(Date(timeIntervalSince1970: at), calendar: cal)) 提醒")
        }
        var dayOffset = 0
        if raw.contains("后天") { dayOffset = 2 }
        else if raw.contains("明天") { dayOffset = 1 }
        else if raw.contains("今天") { dayOffset = 0 }
        else if hourMin != nil { dayOffset = 0 } // 只有钟点：过了就明天
        else {
            // 没有时间：默认明天 8:00
            dayOffset = 1
        }
        let hm = hourMin ?? (8, 0)
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hm.0
        comps.minute = hm.1
        comps.second = 0
        guard var date = cal.date(from: comps) else { return nil }
        date = cal.date(byAdding: .day, value: dayOffset, to: date) ?? date
        if dayOffset == 0, date <= now {
            date = cal.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return Plan(name: name, prompt: prompt, kind: "once", at: date.timeIntervalSince1970, cron: nil, timezone: zone,
                    summary: "将在 \(clockString(date, calendar: cal)) 提醒")
    }

    static func schedule(of plan: Plan) -> [String: Any] {
        if plan.kind == "cron", let cron = plan.cron {
            return ["kind": "cron", "expr": cron, "timezone": plan.timezone]
        }
        return ["kind": "once", "at": plan.at ?? 0]
    }

    // MARK: - helpers

    static func parseClock(_ text: String) -> (Int, Int)? {
        var t = text
        let digits = ["零":"0","一":"1","二":"2","两":"2","三":"3","四":"4","五":"5","六":"6","七":"7","八":"8","九":"9","十":"10"]
        for (k, v) in digits { t = t.replacingOccurrences(of: k, with: v) }
        let afternoon = t.contains("下午") || t.contains("晚上") || t.contains("傍晚")
        let morning = t.contains("上午") || t.contains("早上") || t.contains("早晨")
        // 8点半 / 8:30 / 8点30分 / 八点半
        let mapped = t.replacingOccurrences(of: "点半", with: "点30分")
            .replacingOccurrences(of: "：", with: ":")
        if let r = mapped.range(of: #"(\d{1,2})\s*[:点]\s*(\d{1,2})"#, options: .regularExpression) {
            let parts = mapped[r].split { $0 == ":" || $0 == "点" }.map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            if parts.count >= 2 { return normalize(parts[0], parts[1], afternoon: afternoon, morning: morning) }
        }
        if let r = mapped.range(of: #"(\d{1,2})\s*点"#, options: .regularExpression) {
            let n = Int(mapped[r].filter { $0.isNumber }) ?? 0
            return normalize(n, 0, afternoon: afternoon, morning: morning)
        }
        return nil
    }

    private static func normalize(_ h: Int, _ m: Int, afternoon: Bool, morning: Bool) -> (Int, Int)? {
        var hour = h
        let min = max(0, min(59, m))
        if afternoon, hour > 0, hour < 12 { hour += 12 }
        if morning, hour == 12 { hour = 0 }
        guard hour >= 0, hour <= 23 else { return nil }
        return (hour, min)
    }

    private static func delay(in text: String) -> TimeInterval? {
        if let r = text.range(of: #"(\d+)\s*小时"#, options: .regularExpression),
           let n = Int(text[r].filter { $0.isNumber }), n > 0, n < 72 {
            return TimeInterval(n * 3600)
        }
        if let r = text.range(of: #"(\d+)\s*分钟"#, options: .regularExpression),
           let n = Int(text[r].filter { $0.isNumber }), n > 0, n < 24 * 60 {
            return TimeInterval(n * 60)
        }
        return nil
    }

    private static func weekday(in text: String) -> Int? {
        // cron: 0/7 周日 … 6 周六
        let map: [(String, Int)] = [("周日", 0), ("星期日", 0), ("周天", 0),
                                    ("周一", 1), ("星期一", 1),
                                    ("周二", 2), ("星期二", 2),
                                    ("周三", 3), ("星期三", 3),
                                    ("周四", 4), ("星期四", 4),
                                    ("周五", 5), ("星期五", 5),
                                    ("周六", 6), ("星期六", 6)]
        if !(text.contains("每周") || text.contains("每星期")) { return nil }
        return map.first { text.contains($0.0) }?.1
    }

    private static func weekdayName(_ n: Int) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][max(0, min(6, n))]
    }

    private static func pad(_ n: Int) -> String { String(format: "%02d", n) }

    private static func clockString(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}
