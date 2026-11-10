import Foundation

/// 夜班模式：值班中且在夜里（默认 20:00–08:00），或手动「常开」时生效——深色 + 暖色滤镜、去掉震动、字号放大；下夜班（值班结束）自动恢复。
/// 只依赖 Foundation，Linux 上单测。
enum CloudNightMode {
    static let key = "OpenMinisNightMode"   // auto / on / off
    static let nightStart = 20, nightEnd = 8

    /// 震动由这里统一关（CloudHaptics 每次先看它）
    static var hapticsMuted = false

    static var setting: String {
        get { UserDefaults.standard.string(forKey: key) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func isNightHour(_ hour: Int) -> Bool { hour >= nightStart || hour < nightEnd }

    static func active(setting: String, dutyUntil: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch setting {
        case "on": return true
        case "off": return false
        default:
            guard let until = dutyUntil, until > now else { return false }
            return isNightHour(calendar.component(.hour, from: now))
        }
    }
}
