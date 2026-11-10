import Foundation

/// Bot 对话分页：先拿最近 `pageSize` 条，顶上「更早的消息」再往前翻；刷新时把已经翻出来的旧消息留住。
enum CloudHistoryPager {
    static let pageSize = 200

    static func firstPath(_ sessionId: String) -> String { "/v1/sessions/\(sessionId)?limit=\(pageSize)" }

    static func olderPath(_ sessionId: String, before id: Int) -> String {
        "/v1/sessions/\(sessionId)?limit=\(pageSize)&before_id=\(id)"
    }

    static func id(_ m: [String: Any]) -> Int? { (m["id"] as? Int) ?? (m["id"] as? NSNumber)?.intValue }

    /// 最早一条的 id（往前翻的起点）
    static func oldestId(_ messages: [[String: Any]]) -> Int? { messages.compactMap(id).min() }

    /// 刷新回来的是最近一页：比它更早、之前已经翻出来的消息接在前面，不丢
    static func merge(current: [[String: Any]], fresh: [[String: Any]]) -> [[String: Any]] {
        guard let freshFirst = oldestId(fresh) else { return fresh }
        let older = current.filter { (id($0) ?? Int.max) < freshFirst }
        return older + fresh
    }

    /// 往前翻的一页接在最前面（去掉重复的 id）
    static func prepend(_ page: [[String: Any]], to current: [[String: Any]]) -> [[String: Any]] {
        let have = Set(current.compactMap(id))
        return page.filter { id($0).map { !have.contains($0) } ?? true } + current
    }
}
