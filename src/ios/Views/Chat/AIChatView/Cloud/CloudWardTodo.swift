import Foundation

/// 查房待办箱条目。标题和床号只保留短文本，测试用假数据。
struct CloudWardTodo: Equatable, Identifiable, Codable {
    var todoId: String
    var title: String
    var detail: String
    var bed: String
    var done: Bool
    var createdAt: Double
    var id: String { todoId }

    static func parse(_ d: [String: Any]) -> CloudWardTodo? {
        guard let id = d["todo_id"] as? String, let title = d["title"] as? String, !title.isEmpty else { return nil }
        return CloudWardTodo(todoId: id, title: String(title.prefix(80)),
                             detail: String((d["detail"] as? String ?? "").prefix(200)),
                             bed: String((d["bed"] as? String ?? "").prefix(20)),
                             done: d["done"] as? Bool ?? ((d["done"] as? NSNumber)?.intValue == 1),
                             createdAt: (d["created_at"] as? NSNumber)?.doubleValue ?? 0)
    }

    static func list(_ d: [String: Any]) -> [CloudWardTodo] {
        (d["todos"] as? [[String: Any]] ?? []).compactMap(parse)
    }

    static func totals(_ items: [CloudWardTodo]) -> (open: Int, done: Int) {
        let done = items.filter(\.done).count
        return (items.count - done, done)
    }

    static func boxTitle(open: Int) -> String {
        open <= 0 ? "查房待办箱（已全部完成）" : "查房待办箱（还有 \(open) 项）"
    }

    static var e2eForced: Bool { ProcessInfo.processInfo.environment["OPENMINIS_E2E_WARD_TODO"] == "1" }

    static func e2eItems() -> [CloudWardTodo] {
        [
            CloudWardTodo(todoId: "todo_e2e000000001", title: "复查血气（假数据）", detail: "", bed: "床 A", done: false, createdAt: 1),
            CloudWardTodo(todoId: "todo_e2e000000002", title: "核对输液（假数据）", detail: "", bed: "床 B", done: true, createdAt: 2),
        ]
    }
}
