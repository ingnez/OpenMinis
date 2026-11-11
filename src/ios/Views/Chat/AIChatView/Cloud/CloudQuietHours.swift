import Foundation

/// 静默时段（上班时间）：时段内只应答主动提问，完成通知攒到窗口结束后再推。纯逻辑，Linux 上可单测。
struct CloudQuietHoursConfig: Equatable {
    var enabled: Bool
    var start: String   // "HH:MM"
    var end: String
    var weekdays: [Int] // ISO 周一=1 … 周日=7
    var timezone: String

    static let defaultConfig = CloudQuietHoursConfig(enabled: false, start: "08:00", end: "18:00",
                                                     weekdays: [1, 2, 3, 4, 5], timezone: "Asia/Shanghai")

    static func parse(_ d: [String: Any]) -> CloudQuietHoursConfig {
        var c = defaultConfig
        if let v = d["enabled"] as? Bool { c.enabled = v }
        if let v = d["start"] as? String, CloudQuietHours.minutes(v) != nil { c.start = v }
        if let v = d["end"] as? String, CloudQuietHours.minutes(v) != nil { c.end = v }
        if let v = d["weekdays"] as? [Int], v.allSatisfy({ (1...7).contains($0) }), !v.isEmpty { c.weekdays = v.sorted() }
        if let v = d["timezone"] as? String, !v.isEmpty { c.timezone = v }
        return c
    }

    var body: [String: Any] {
        ["enabled": enabled, "start": start, "end": end, "weekdays": weekdays, "timezone": timezone]
    }
}

enum CloudQuietHours {
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// `now` 为该时区日历下的 (weekday ISO, hour, minute)
    static func isActive(_ cfg: CloudQuietHoursConfig, weekday: Int, hour: Int, minute: Int) -> Bool {
        guard cfg.enabled, cfg.weekdays.contains(weekday) else { return false }
        guard let start = minutes(cfg.start), let end = minutes(cfg.end) else { return false }
        let cur = hour * 60 + minute
        if start == end { return true }
        if start < end { return cur >= start && cur < end }
        return cur >= start || cur < end
    }

    static let holdEvents: Set<String> = ["task_complete", "task_completed", "task_failed", "routine",
                                          "routine_complete", "relay_watch", "notify", "proactive",
                                          "worker_complete", "delegation_complete"]
    static let passEvents: Set<String> = ["approval_required", "duty_digest", "quiet_digest"]

    static func shouldHold(_ cfg: CloudQuietHoursConfig, event: String, weekday: Int, hour: Int, minute: Int) -> Bool {
        if passEvents.contains(event) { return false }
        guard isActive(cfg, weekday: weekday, hour: hour, minute: minute) else { return false }
        return holdEvents.contains(event)
    }

    static func weekdayTitle(_ day: Int) -> String {
        ["", "一", "二", "三", "四", "五", "六", "日"][max(0, min(day, 7))]
    }

    static func summary(_ cfg: CloudQuietHoursConfig) -> String {
        guard cfg.enabled else { return "关" }
        let days = cfg.weekdays.map { "周" + weekdayTitle($0) }.joined(separator: "、")
        return "\(cfg.start)–\(cfg.end) · \(days)"
    }
}
