import Foundation

/// 每个对话最近的消息和任务存在手机上（Caches 目录，文件保护：锁屏后加密）。
/// 打开对话时先画缓存（< 100ms），网络回来再静默替换；没有缓存时显示骨架气泡，不显示整页转圈。
/// 只存服务器本来就发给手机的对话内容；保管库机密从不进对话，所以也不会进缓存。无痕对话不缓存。
enum CloudChatCache {
    static let keepMessages = 120
    static let keepTasks = 8

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("OpenMinisChatCache", isDirectory: true)
    }

    static func isValidId(_ sid: String) -> Bool { sid.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }

    static func file(_ sid: String, in dir: URL) -> URL { dir.appendingPathComponent(sid + ".json") }

    /// 只留最近的消息；返回写入的条数（失败或无效 id 返回 nil）
    @discardableResult
    static func save(_ sid: String, messages: [[String: Any]], tasks: [[String: Any]], in dir: URL = directory, now: Date = Date()) -> Int? {
        guard isValidId(sid) else { return nil }
        let msgs = Array(messages.suffix(keepMessages)).map(clean)
        let body: [String: Any] = ["v": 1, "saved_at": now.timeIntervalSince1970, "messages": msgs, "tasks": Array(tasks.prefix(keepTasks)).map(clean)]
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        let opts: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
        #else
        let opts: Data.WritingOptions = [.atomic]
        #endif
        guard (try? data.write(to: file(sid, in: dir), options: opts)) != nil else { return nil }
        return msgs.count
    }

    static func load(_ sid: String, in dir: URL = directory) -> (messages: [[String: Any]], tasks: [[String: Any]], savedAt: Date)? {
        guard isValidId(sid), let data = try? Data(contentsOf: file(sid, in: dir)),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgs = d["messages"] as? [[String: Any]] else { return nil }
        return (msgs, d["tasks"] as? [[String: Any]] ?? [], Date(timeIntervalSince1970: (d["saved_at"] as? NSNumber)?.doubleValue ?? 0))
    }

    static func remove(_ sid: String, in dir: URL = directory) {
        guard isValidId(sid) else { return }
        try? FileManager.default.removeItem(at: file(sid, in: dir))
    }

    static func age(_ sid: String, in dir: URL = directory, now: Date = Date()) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file(sid, in: dir).path),
              let m = attrs[.modificationDate] as? Date else { return nil }
        return now.timeIntervalSince(m)
    }

    /// 网络结果和屏幕上的是否一样（一样就不重画，避免闪）
    static func sameContent(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool {
        guard a.count == b.count else { return false }
        func key(_ m: [String: Any]?) -> String {
            guard let m else { return "" }
            let id = (m["id"] as? NSNumber)?.stringValue ?? ""
            let r = (m["reactions"] as? [[String: Any]])?.compactMap { $0["emoji"] as? String }.joined() ?? ""
            return id + "|" + (m["content"] as? String ?? "").suffix(64) + "|" + r
        }
        return key(a.last) == key(b.last) && key(a.first) == key(b.first)
    }

    /// JSON 里放不下的值（Date 等）去掉
    private static func clean(_ d: [String: Any]) -> [String: Any] {
        d.filter { JSONSerialization.isValidJSONObject(["v": $0.value]) }
    }
}
