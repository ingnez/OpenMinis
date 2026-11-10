import Foundation

/// 每日用量图的数据：补齐没有用量的日子（记 0），按 Bot 分段，超过 4 个 Bot 的合并成「其他」
struct CloudUsagePoint: Identifiable, Equatable {
    let day: String     // yyyy-MM-dd
    let series: String  // Bot 名
    let tokens: Int
    var id: String { day + "|" + series }
}

enum CloudUsageSeries {
    static func days(endingAt today: String, count: Int) -> [String] {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let end = f.date(from: today) else { return [] }
        return (0..<max(1, count)).reversed().compactMap { Calendar(identifier: .gregorian).date(byAdding: .day, value: -$0, to: end) }.map { f.string(from: $0) }
    }

    /// items：服务器 usage summary 的 items（day, bot_id, total_tokens）
    static func points(items: [[String: Any]], today: String, count: Int, names: [String: String], maxSeries: Int = 4) -> [CloudUsagePoint] {
        func name(_ id: String) -> String { id.isEmpty ? "主助手" : (names[id] ?? id) }
        var perBot: [String: Int] = [:]
        var cell: [String: [String: Int]] = [:]
        for it in items {
            let day = it["day"] as? String ?? ""
            let bot = it["bot_id"] as? String ?? ""
            let t = (it["total_tokens"] as? Int) ?? Int((it["total_tokens"] as? Double) ?? 0)
            perBot[bot, default: 0] += t
            cell[day, default: [:]][bot, default: 0] += t
        }
        let ranked = perBot.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let top = Array(ranked.prefix(ranked.count > maxSeries ? maxSeries - 1 : maxSeries))
        let series = top.map(name) + (ranked.count > top.count ? ["其他"] : [])
        var out: [CloudUsagePoint] = []
        for day in days(endingAt: today, count: count) {
            var row: [String: Int] = [:]
            for (bot, t) in cell[day] ?? [:] { row[top.contains(bot) ? name(bot) : "其他", default: 0] += t }
            if series.isEmpty { out.append(CloudUsagePoint(day: day, series: "合计", tokens: 0)) }
            for s in series { out.append(CloudUsagePoint(day: day, series: s, tokens: row[s] ?? 0)) }
        }
        return out
    }
}
