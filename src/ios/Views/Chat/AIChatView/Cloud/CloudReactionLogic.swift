import Foundation

/// 表情回应的规则（Grok Bot 式 tapback）：点同一个表情 = 取消，点别的 = 换成新的；每条消息每方最多一个。
enum CloudReactionLogic {
    /// 用户点了 picked（nil = 「取消回应」）后，这条消息应有的回应
    static func next(current: String?, picked: String?) -> String? {
        guard let picked, !picked.isEmpty else { return nil }
        return picked == current ? nil : picked
    }

    /// 服务器 reactions 数组 → (Bot 的, 用户的)
    static func split(_ rs: [[String: Any]]) -> (bot: String?, user: String?) {
        (rs.first { $0["actor"] as? String == "bot" }?["emoji"] as? String,
         rs.first { $0["actor"] as? String == "user" }?["emoji"] as? String)
    }
}
