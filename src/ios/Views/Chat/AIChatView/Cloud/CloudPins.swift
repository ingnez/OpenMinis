import Foundation

/// 「要点板」：长按 Bot 回复「钉到要点板」，每个 Bot 一块（剂量、医嘱要点、联系人以外的关键事实）。存在手机本地。
/// 智能快捷回复：最后一条回复下面给 3–4 个下一步按钮。都只依赖 Foundation，Linux 上单测。
enum CloudPins {
    static let key = "OpenMinisPins"
    static let maxPerBot = 30

    struct Pin: Codable, Equatable {
        let text: String
        let at: Double
    }

    static func list(_ botId: String, defaults: UserDefaults = .standard) -> [Pin] { all(defaults)[botId] ?? [] }

    @discardableResult
    static func add(_ botId: String, text: String, defaults: UserDefaults = .standard, now: Double = Date().timeIntervalSince1970) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        var map = all(defaults)
        var l = (map[botId] ?? []).filter { $0.text != t }
        l.insert(Pin(text: String(t.prefix(2000)), at: now), at: 0)
        map[botId] = Array(l.prefix(maxPerBot))
        defaults.set(try? JSONEncoder().encode(map), forKey: key)
        return true
    }

    static func remove(_ botId: String, text: String, defaults: UserDefaults = .standard) {
        var map = all(defaults)
        map[botId] = (map[botId] ?? []).filter { $0.text != text }
        defaults.set(try? JSONEncoder().encode(map), forKey: key)
    }

    private static func all(_ d: UserDefaults) -> [String: [Pin]] {
        guard let data = d.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: [Pin]].self, from: data)) ?? [:]
    }
}

enum CloudSmartReplies {
    /// 根据最后一条回复给下一步：问句给是/否；有「一句话：」给「展开说」；医学类给出处；最后总有「继续」
    static func suggest(_ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        var out: [String] = []
        let lastLine = t.components(separatedBy: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? t
        if lastLine.hasSuffix("？") || lastLine.hasSuffix("?") { out += ["是的", "不用"] }
        if t.hasPrefix("一句话：") { out.append("展开讲讲") } else if t.count > 300 { out.append("说简短点") }
        let medical = ["剂量", "mg", "μg", "指南", "诊断", "用药", "ml/h", "评分"].contains { t.contains($0) }
        if medical && !t.contains("依据：") { out.append("给出处") }
        out.append("继续")
        return Array(out.prefix(4))
    }
}
