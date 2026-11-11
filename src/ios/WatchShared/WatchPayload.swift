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
    /// 头像颜色下标 0–11（见 CloudAvatarPalette）；没有就按 Bot id 散列节奏
    var color: Int?

    static let key = "bots"
    static let sentKey = "sent_at"
    static let currentKey = "current_id"

    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "name": name, "preview": preview, "at": at]
        if let working { d["working"] = working }
        if let color { d["color"] = color }
        return d
    }

    init(id: String, name: String, working: String?, preview: String, at: Double, color: Int? = nil) {
        self.id = id; self.name = name; self.working = working; self.preview = preview; self.at = at; self.color = color
    }

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        self.init(id: id, name: name, working: d["working"] as? String, preview: d["preview"] as? String ?? "",
                  at: (d["at"] as? NSNumber)?.doubleValue ?? 0,
                  color: (d["color"] as? NSNumber)?.intValue)
    }

    /// 手表上的顺序：在干活的在前，再按时间新到旧
    static func decode(_ context: [String: Any]) -> [WatchBotRow] {
        let rows = (context[key] as? [[String: Any]] ?? []).compactMap(WatchBotRow.init)
        return rows.sorted { ($0.working != nil) != ($1.working != nil) ? $0.working != nil : $0.at > $1.at }
    }

    static func currentId(from context: [String: Any]) -> String? {
        guard let id = context[currentKey] as? String else { return nil }
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func encode(_ rows: [WatchBotRow], sentAt: Date = Date(), limit: Int = 30, currentId: String? = nil) -> [String: Any] {
        // applicationContext 有大小上限（约 64KB）：最多 30 个，预览截到 80 字
        let trimmed = rows.prefix(limit).map { r -> [String: Any] in
            var r = r
            r.preview = String(r.preview.prefix(80))
            return r.dict
        }
        var d: [String: Any] = [key: trimmed, sentKey: sentAt.timeIntervalSince1970]
        if let currentId, !currentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            d[currentKey] = currentId
        }
        return d
    }
}

/// 手机 → 手表的「某个 Bot 干完了」轻触（WatchConnectivity sendMessage，只在手表 App 可达时发）。
/// 节奏优先按头像颜色（12 色分成 1–3 下），没有颜色时退回按 id 散列；夜班模式下只轻点、不响提示音式的重震。
/// 手表 App 不可达时不发、不排队（过时的震动没意义）；本机通知在夜班时静音，见 CloudNightMode.notifyStyle。
struct WatchTap: Equatable {
    var botId: String
    var name: String
    /// 夜班模式：只用最轻的 click
    var light: Bool
    var color: Int?

    static let kind = "bot_done"
    static let colorCount = 12

    var dict: [String: Any] {
        var d: [String: Any] = ["kind": Self.kind, "id": botId, "name": name, "light": light]
        if let color { d["color"] = color }
        return d
    }

    init(botId: String, name: String, light: Bool, color: Int? = nil) {
        self.botId = botId; self.name = name; self.light = light; self.color = color
    }

    init?(_ d: [String: Any]) {
        guard d["kind"] as? String == Self.kind, let id = d["id"] as? String, !id.isEmpty else { return nil }
        self.init(botId: id, name: d["name"] as? String ?? "", light: d["light"] as? Bool ?? false,
                  color: (d["color"] as? NSNumber)?.intValue)
    }

    /// 1–3 下：按 id 的 UTF-8 做 djb2 散列（跨进程、跨设备稳定，不能用 hashValue）
    static func beats(for botId: String) -> Int {
        var h: UInt32 = 5381
        for b in botId.utf8 { h = (h &<< 5) &+ h &+ UInt32(b) }
        return Int(h % 3) + 1
    }

    /// 按头像颜色：12 色稳定映射到 1–3 下（相邻颜色节奏不同）
    static func beats(forColor color: Int) -> Int {
        let i = ((color % colorCount) + colorCount) % colorCount
        return (i % 3) + 1
    }

    /// 有颜色用颜色，否则退回按 id
    static func beats(botId: String, color: Int?) -> Int {
        if let color { return beats(forColor: color) }
        return beats(for: botId)
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

/// 手表场景阶段（不依赖 SwiftUI，Linux 上可测）
enum WatchScenePhase: Equatable {
    case background, inactive, active
}

/// 抬腕说话：手表没有公开的「抬腕」API。已打开的 App 在手腕放下后进入 inactive/background，抬腕唤醒会回到 active——这是最接近的系统行为。
/// 第一次进入前台（刚打开 App）不自动听写，避免一打开就被系统听写打断。
enum WatchRaiseToSpeak {
    static let cooldown: TimeInterval = 2

    static func shouldStartListening(
        previous: WatchScenePhase,
        current: WatchScenePhase,
        enabled: Bool,
        hasBecomeActiveOnce: Bool,
        cooldownUntil: Date?,
        now: Date
    ) -> Bool {
        guard enabled, current == .active, hasBecomeActiveOnce else { return false }
        guard previous == .inactive || previous == .background else { return false }
        if let until = cooldownUntil, now < until { return false }
        return true
    }
}

/// 手表 → 手机：听写得到的文字，发给当前（或指定）Bot。手机端走同一套脱敏后再发送。
struct WatchSpeakRequest: Equatable {
    var text: String
    var botId: String?
    static let kind = "watch_speak"

    var dict: [String: Any] {
        var d: [String: Any] = ["kind": Self.kind, "text": text]
        if let botId, !botId.isEmpty { d["id"] = botId }
        return d
    }

    init(text: String, botId: String?) { self.text = text; self.botId = botId }

    init?(_ d: [String: Any]) {
        guard d["kind"] as? String == Self.kind, let text = d["text"] as? String else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let id = (d["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(text: t, botId: (id?.isEmpty == false) ? id : nil)
    }
}

/// 手表 → 手机：在手机上打开指定（或当前）Bot 的语音通话
struct WatchVoiceRequest: Equatable {
    var botId: String?
    static let kind = "watch_voice"

    var dict: [String: Any] {
        var d: [String: Any] = ["kind": Self.kind]
        if let botId, !botId.isEmpty { d["id"] = botId }
        return d
    }

    init(botId: String?) { self.botId = botId }

    init?(_ d: [String: Any]) {
        guard d["kind"] as? String == Self.kind else { return nil }
        let id = (d["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(botId: (id?.isEmpty == false) ? id : nil)
    }
}

/// 控制中心 / 快捷指令 / 小组件打开语音用的深链：`minis://bot/<id>?voice=1`；没有 id 就是主 Bot。
enum CloudVoiceDeepLink {
    static func url(botId: String?) -> URL {
        let id = (botId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return URL(string: "minis://bot/?voice=1")! }
        let enc = id.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? id
        return URL(string: "minis://bot/\(enc)?voice=1")!
    }

    /// 从深链取出 Bot id（空 = 主 Bot）
    static func botId(from url: URL) -> String? {
        guard url.scheme == "minis", let host = url.host, host == "bot" || host == "bots" else { return nil }
        let key = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func isVoice(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "voice" && $0.value == "1" }
    }
}
