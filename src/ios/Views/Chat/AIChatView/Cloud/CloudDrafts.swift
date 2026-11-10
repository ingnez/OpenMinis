import Foundation

/// 每个对话的草稿自动保存（被电话 / 病人打断、App 被杀，回来输入框还在）。只依赖 Foundation，Linux 上单测
enum CloudDrafts {
    static let key = "OpenMinisDrafts"
    static let maxDrafts = 50
    static let maxAge: Double = 7 * 24 * 3600

    private struct Draft: Codable { let text: String; let at: Double }

    static func load(_ sessionId: String, defaults: UserDefaults = .standard, now: Double = Date().timeIntervalSince1970) -> String? {
        guard let d = all(defaults)[sessionId], now - d.at < maxAge, !d.text.isEmpty else { return nil }
        return d.text
    }

    static func save(_ sessionId: String, text: String, defaults: UserDefaults = .standard, now: Double = Date().timeIntervalSince1970) {
        var map = all(defaults)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { map[sessionId] = nil } else { map[sessionId] = Draft(text: text, at: now) }
        if map.count > maxDrafts {
            for k in map.sorted(by: { $0.value.at < $1.value.at }).prefix(map.count - maxDrafts).map(\.key) { map[k] = nil }
        }
        defaults.set(try? JSONEncoder().encode(map), forKey: key)
    }

    private static func all(_ defaults: UserDefaults) -> [String: Draft] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Draft].self, from: data)) ?? [:]
    }
}
