import Foundation

/// 「交班 / 交班卡 / /交班」视为要出交班卡，不发给模型。
enum CloudShiftIntent {
    static let utterances: Set<String> = ["交班", "交班卡", "开始交班", "/交班"]

    static func isUtterance(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if utterances.contains(t) { return true }
        guard t.hasPrefix("交班") else { return false }
        let rest = t.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！？?，, ")).isEmpty
    }
}

/// 交班卡「下次打开先看到」：本机记一笔，打开首页时先弹出。
enum CloudShiftPin {
    static let key = "OpenMinisShiftCard_showOnOpen"

    static var shouldShow: Bool { UserDefaults.standard.bool(forKey: key) }

    static func mark(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: key) }

    static func consume(_ defaults: UserDefaults = .standard) { defaults.set(false, forKey: key) }

    static func shouldShow(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }
}
