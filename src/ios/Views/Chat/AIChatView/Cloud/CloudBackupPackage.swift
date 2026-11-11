import Foundation

/// 云端备份包的命名、计数、过期提示与自校验。不含密钥。Linux 可单测。
struct CloudBackupReadError: Error, Equatable {
    let message: String
}

enum CloudBackupPackage {
    static let ext = "minisbackup"
    static let format = "openminis-backup/1"
    static let staleDays = 7

    static func fileName(at date: Date, timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return "OpenMinis备份-\(stamp).\(ext)"
    }

    static func counts(_ backup: [String: Any]) -> [String: Int] {
        let sessions = backup["sessions"] as? [[String: Any]] ?? []
        let messages = sessions.reduce(0) { $0 + (($1["messages"] as? [Any])?.count ?? 0) }
        return [
            "bots": (backup["bots"] as? [Any])?.count ?? 0,
            "sessions": sessions.count,
            "messages": messages,
            "groups": (backup["groups"] as? [Any])?.count ?? 0,
            "memory": (backup["memory"] as? [Any])?.count ?? 0,
            "skills": (backup["skills"] as? [Any])?.count ?? 0,
        ]
    }

    static func validate(_ data: Data) -> Result<[String: Any], CloudBackupReadError> {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(CloudBackupReadError(message: "文件不是有效的备份（不是 JSON 对象）"))
        }
        guard obj["format"] as? String == format else {
            return .failure(CloudBackupReadError(message: "不是 OpenMinis 备份文件"))
        }
        return .success(obj)
    }

    static func selfCheck(data: Data, expected: [String: Int]) -> String? {
        switch validate(data) {
        case .failure(let e): return e.message
        case .success(let obj):
            let got = counts(obj)
            for k in ["bots", "sessions", "memory"] {
                if got[k] != expected[k] { return "自校验未通过：\(k) 对不上" }
            }
            return nil
        }
    }

    static func daysSince(_ date: Date, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86400))
    }

    static func lastBackupLine(days: Int?) -> (text: String, stale: Bool) {
        guard let days else { return ("还没有备份", true) }
        if days == 0 { return ("上次备份：今天", false) }
        return ("上次备份：\(days) 天前", days >= staleDays)
    }

    static func resultSummary(counts: [String: Int], bytes: Int, filename: String) -> String {
        "已生成 \(filename)（\(CloudBackupPackage.bytesText(bytes))）：Bot \(counts["bots"] ?? 0)、会话 \(counts["sessions"] ?? 0)、记忆 \(counts["memory"] ?? 0)"
    }

    static func previewLine(_ p: [String: Int]) -> String {
        "将新增：Bot \(p["bots"] ?? 0)、会话 \(p["sessions"] ?? 0)、记忆 \(p["memory"] ?? 0)，跳过已有 \(p["skipped"] ?? 0)"
    }

    static func bytesText(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }

    static var e2eForced: Bool { ProcessInfo.processInfo.environment["OPENMINIS_E2E_BACKUP"] == "1" }

    static func e2eBackup() -> [String: Any] {
        [
            "format": format,
            "created_at": 1,
            "bots": [["bot_id": "e2ebot", "bot": ["name": "E2E小助手"]]],
            "sessions": [["session_id": "sess_e2e000000001", "title": "假会话", "messages": [["role": "user", "content": "hi"]]]],
            "groups": [],
            "memory": [["content": "假记忆一条"]],
            "skills": [["name": "假技能", "content": "# 假"]],
        ]
    }
}

struct CloudBackupRecord: Codable, Equatable, Identifiable {
    var id: String
    var filename: String
    var bytes: Int
    var createdAt: Double
    var location: String
    var path: String
    var counts: [String: Int]

    var date: Date { Date(timeIntervalSince1970: createdAt) }
}

enum CloudBackupHistory {
    static let key = "OpenMinisBackupHistory"
    static let weeklyKey = "OpenMinisBackupWeekly"
    static let maxItems = 20

    static func load(from defaults: UserDefaults) -> [CloudBackupRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CloudBackupRecord].self, from: data)) ?? []
    }

    static func save(_ list: [CloudBackupRecord], to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(Array(list.prefix(maxItems))), forKey: key)
    }

    @discardableResult
    static func add(_ rec: CloudBackupRecord, defaults: UserDefaults) -> [CloudBackupRecord] {
        var list = load(from: defaults).filter { $0.id != rec.id }
        list.insert(rec, at: 0)
        let out = Array(list.prefix(maxItems))
        save(out, to: defaults)
        return out
    }

    static func remove(id: String, defaults: UserDefaults) {
        save(load(from: defaults).filter { $0.id != id }, to: defaults)
    }

    static func latest(from defaults: UserDefaults) -> CloudBackupRecord? {
        load(from: defaults).max(by: { $0.createdAt < $1.createdAt })
    }
}
