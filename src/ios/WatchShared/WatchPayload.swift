import Foundation

/// 手机 → 手表的数据（WatchConnectivity applicationContext）。只含首页能看到的东西：名字、在干什么、最后一句的预览。
/// 上锁的 Bot 手机端不发预览。只依赖 Foundation：Linux 快速检查里和手机端的编码一起测。
struct WatchBotRow: Equatable, Identifiable {
    var id: String
    var name: String
    /// 正在干活时的阶段文字（「正在回复：…」）；nil = 闲着
    var working: String?
    var preview: String
    var at: Double

    static let key = "bots"
    static let sentKey = "sent_at"

    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "name": name, "preview": preview, "at": at]
        if let working { d["working"] = working }
        return d
    }

    init(id: String, name: String, working: String?, preview: String, at: Double) {
        self.id = id; self.name = name; self.working = working; self.preview = preview; self.at = at
    }

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        self.init(id: id, name: name, working: d["working"] as? String, preview: d["preview"] as? String ?? "",
                  at: (d["at"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// 手表上的顺序：在干活的在前，再按时间新到旧
    static func decode(_ context: [String: Any]) -> [WatchBotRow] {
        let rows = (context[key] as? [[String: Any]] ?? []).compactMap(WatchBotRow.init)
        return rows.sorted { ($0.working != nil) != ($1.working != nil) ? $0.working != nil : $0.at > $1.at }
    }

    static func encode(_ rows: [WatchBotRow], sentAt: Date = Date(), limit: Int = 30) -> [String: Any] {
        // applicationContext 有大小上限（约 64KB）：最多 30 个，预览截到 80 字
        let trimmed = rows.prefix(limit).map { r -> [String: Any] in
            var r = r
            r.preview = String(r.preview.prefix(80))
            return r.dict
        }
        return [key: trimmed, sentKey: sentAt.timeIntervalSince1970]
    }
}
