import Foundation

/// 口袋模式：不掏手机也能跟 Bot 说话。iOS 不给第三方 App 拦截音量键，
/// 可用的触发方式是耳机/AirPods 上的播放键、操作按钮（iOS 17+ 快捷指令）或快捷指令本身。
/// 只依赖 Foundation，Linux 上单测。
enum CloudPocketMode {
    static let key = "OpenMinisPocketMode"
    static let replyKey = "OpenMinisPocketReply"   // earbuds / watch / both

    enum ReplyRoute: String, CaseIterable {
        case earbuds, watch, both
        var label: String {
            switch self {
            case .earbuds: return "用耳机播放回复"
            case .watch: return "只上手表震动"
            case .both: return "耳机播放，同时手表震动"
            }
        }
    }

    static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key)
    }

    static func route(_ defaults: UserDefaults) -> ReplyRoute {
        ReplyRoute(rawValue: defaults.string(forKey: replyKey) ?? "") ?? .both
    }

    static func shouldPlayInEarbuds(enabled: Bool, route: ReplyRoute) -> Bool {
        enabled && (route == .earbuds || route == .both)
    }

    static func shouldTapWatch(enabled: Bool, route: ReplyRoute) -> Bool {
        enabled && (route == .watch || route == .both)
    }

    /// 如实说明系统限制，写在设置页上。
    static let limitsText = "iOS 不允许第三方 App 拦截音量键，所以口袋里没法靠按音量键开始说话。可以用：耳机或 AirPods 上的播放/暂停键（App 在后台且已打开口袋模式时）、iPhone 15 及以后的操作按钮（在「快捷指令」里指定「口袋里问 Bot」）、或把这条快捷指令放到锁屏或灵动岛。回复默认走耳机播放；没戴耳机时可以改成只上手表轻触。"

    static func isPocket(_ url: URL) -> Bool {
        guard url.scheme == "minis", let host = url.host, host == "bot" || host == "bots" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "pocket" && ($0.value == "1" || $0.value == "true") }
    }

    static func url(botId: String?) -> URL {
        let id = (botId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return URL(string: "minis://bot/?pocket=1")! }
        let enc = id.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? id
        return URL(string: "minis://bot/\(enc)?pocket=1")!
    }
}
