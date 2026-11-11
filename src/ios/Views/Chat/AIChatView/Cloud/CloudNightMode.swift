import Foundation

/// 夜班模式：值班中且在夜里（默认 20:00–08:00），或手动「常开」时生效——深色 + 暖色滤镜、去掉震动、字号放大、本机通知静音；下夜班（值班结束）自动恢复。
/// 只依赖 Foundation，Linux 上单测。
/// 手表可达时完成提醒改成轻触（见 WatchTap）；不可达时不补震、只出静音横幅，不改回有声。
/// App 被杀掉时，Bark / 系统推送若由服务器自带声音，本 App 改不了，请在系统专注模式里静音。
enum CloudNightMode {
    static let key = "OpenMinisNightMode"   // auto / schedule / on / off
    static let startKey = "OpenMinisNightModeStart"
    static let endKey = "OpenMinisNightModeEnd"
    static let nightStart = 20, nightEnd = 8

    /// 震动由这里统一关（CloudHaptics 每次先看它）；夜班生效时也为 true，本机通知用它判断是否静音
    static var hapticsMuted = false

    static var setting: String {
        get { UserDefaults.standard.string(forKey: key) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func startHour(_ defaults: UserDefaults = .standard) -> Int {
        let v = defaults.object(forKey: startKey) as? Int ?? nightStart
        return ((v % 24) + 24) % 24
    }

    static func endHour(_ defaults: UserDefaults = .standard) -> Int {
        let v = defaults.object(forKey: endKey) as? Int ?? nightEnd
        return ((v % 24) + 24) % 24
    }

    static func isNightHour(_ hour: Int) -> Bool { isNightHour(hour, start: nightStart, end: nightEnd) }

    /// start == end 表示全天（按时间表常开）。跨午夜（20–8）走「大于等于开始或小于结束」。
    static func isNightHour(_ hour: Int, start: Int, end: Int) -> Bool {
        let s = ((start % 24) + 24) % 24
        let e = ((end % 24) + 24) % 24
        if s == e { return true }
        if s < e { return hour >= s && hour < e }
        return hour >= s || hour < e
    }

    static func active(setting: String, dutyUntil: Date?, now: Date = Date(), calendar: Calendar = .current,
                       startHour: Int = nightStart, endHour: Int = nightEnd) -> Bool {
        switch setting {
        case "on": return true
        case "off": return false
        case "schedule":
            return isNightHour(calendar.component(.hour, from: now), start: startHour, end: endHour)
        default:
            guard let until = dutyUntil, until > now else { return false }
            return isNightHour(calendar.component(.hour, from: now), start: startHour, end: endHour)
        }
    }

    /// 夜班生效时本机通知不响、不用 timeSensitive 打断；关闭时恢复默认声音。
    struct NotifyStyle: Equatable {
        var sound: Bool
        /// true = 可用 timeSensitive；false = 改为 passive，减少锁屏吵醒
        var interrupt: Bool
    }

    static func notifyStyle(muted: Bool = hapticsMuted) -> NotifyStyle {
        muted ? NotifyStyle(sound: false, interrupt: false) : NotifyStyle(sound: true, interrupt: true)
    }
}
