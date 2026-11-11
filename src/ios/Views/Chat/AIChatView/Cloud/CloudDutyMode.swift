import Foundation

/// 值班模式补充规则（22:11 第 7 项）：值班期间仅震动、不外推；回答结论+单位；到点或手动结束后自动恢复。
/// 已有的 duty_until / 下班汇总仍由服务器和首页菜单负责。只依赖 Foundation，Linux 上单测。
enum CloudDutyMode {
    static var e2eForced: Bool { ProcessInfo.processInfo.environment["OPENMINIS_E2E_DUTY"] == "1" }

    static func isOn(dutyUntil: Date?, now: Date = Date()) -> Bool {
        if e2eForced { return true }
        guard let until = dutyUntil else { return false }
        return until > now
    }

    /// 横幅上展示的结束时间；E2E 没有真实 duty_until 时给一个 8 小时后的占位。
    static func until(dutyUntil: Date?, now: Date = Date()) -> Date? {
        if let u = dutyUntil, u > now { return u }
        if e2eForced { return now.addingTimeInterval(8 * 3600) }
        return nil
    }

    /// 值班中本机通知不响、不按 timeSensitive 打断；夜班滤镜静音时同样不响。
    static func allowSound(onDuty: Bool, nightSound: Bool) -> Bool {
        !onDuty && nightSound
    }

    /// 值班中用震动代替铃声；夜班滤镜关掉震动时遵守夜班（避免夜里吵醒同伴）。
    static func shouldVibrate(onDuty: Bool, nightHapticsMuted: Bool) -> Bool {
        onDuty && !nightHapticsMuted
    }

    static func bannerText(until: Date, calendar: Calendar = .current) -> String {
        let t = DateFormatter()
        t.calendar = calendar
        t.locale = Locale(identifier: "zh_CN")
        t.timeZone = calendar.timeZone
        t.dateFormat = "HH:mm"
        return "值班中 · 到 \(t.string(from: until))：仅震动、不推送，回答结论+单位；到点自动恢复"
    }
}
