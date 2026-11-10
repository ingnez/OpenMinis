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

/// 手机 → 手表的「某个 Bot 干完了」轻触（WatchConnectivity sendMessage，只在手表 App 可达时发）。
/// 每个 Bot 固定一种节奏（1–3 下，按 id 稳定散列），不用抬手看就知道是谁；夜班模式下只轻点、不响提示音式的重震。
struct WatchTap: Equatable {
    var botId: String
    var name: String
    /// 夜班模式：只用最轻的 click
    var light: Bool

    static let kind = "bot_done"

    var dict: [String: Any] { ["kind": Self.kind, "id": botId, "name": name, "light": light] }

    init(botId: String, name: String, light: Bool) { self.botId = botId; self.name = name; self.light = light }

    init?(_ d: [String: Any]) {
        guard d["kind"] as? String == Self.kind, let id = d["id"] as? String, !id.isEmpty else { return nil }
        self.init(botId: id, name: d["name"] as? String ?? "", light: d["light"] as? Bool ?? false)
    }

    /// 1–3 下：按 id 的 UTF-8 做 djb2 散列（跨进程、跨设备稳定，不能用 hashValue）
    static func beats(for botId: String) -> Int {
        var h: UInt32 = 5381
        for b in botId.utf8 { h = (h &<< 5) &+ h &+ UInt32(b) }
        return Int(h % 3) + 1
    }

    /// 每一下相对开始的时间（秒）。非夜班先来一下「提示」再按节奏点；夜班只按节奏轻点
    static func schedule(beats: Int, light: Bool) -> [Double] {
        let n = max(1, min(beats, 3))
        let taps = (0..<n).map { Double($0) * 0.28 }
        return light ? taps : [0] + taps.map { $0 + 0.6 }
    }

    /// 上一轮在干活、这一轮闲下来的 Bot（只看两次都在列表里的；新出现 / 消失的不算）
    static func finished(previous: [WatchBotRow], current: [WatchBotRow]) -> [WatchBotRow] {
        let wasWorking = Set(previous.filter { $0.working != nil }.map(\.id))
        return current.filter { $0.working == nil && wasWorking.contains($0.id) }
    }
}
