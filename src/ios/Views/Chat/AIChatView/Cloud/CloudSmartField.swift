import Foundation

/// 云电脑智能键盘：轮询 /v1/desktop/focus（只有类型，没有内容），焦点刚进输入框就弹手机键盘，进密码框就提示从保管库填。
enum CloudSmartField {
    static let key = "OpenMinisDesktopSmartKeyboard"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    struct Focus: Equatable {
        var editable = false
        var password = false
        var available = false

        init(editable: Bool = false, password: Bool = false, available: Bool = false) {
            self.editable = editable; self.password = password; self.available = available
        }

        init(_ json: [String: Any]) {
            editable = json["editable"] as? Bool ?? false
            password = json["password"] as? Bool ?? false
            available = json["available"] as? Bool ?? false
        }
    }

    enum Action: Equatable { case none, showKeyboard, offerVault }

    /// 只在「刚进入」时动作一次：一直停在同一个框里不会反复弹；离开输入框也不强行收键盘（可能在别的程序里打字）
    static func decide(previous: Focus, now: Focus, keyboardUp: Bool) -> Action {
        guard now.available, now.editable else { return .none }
        if now.password && !(previous.editable && previous.password) { return .offerVault }
        if !now.password && !previous.editable && !keyboardUp { return .showKeyboard }
        return .none
    }
}

