import Foundation

/// 「回头提醒」：你发给 Bot 的话里有「30 分钟后复查血气」「1 小时后看尿量」这类说法时，
/// 手机自己定一个本地提醒（不经服务器、不依赖 Bot 记得），到点带上当时那句话。只依赖 Foundation，Linux 上单测。
enum CloudFollowUp {
    struct Plan: Equatable {
        let seconds: Int
        let what: String
    }

    static let minSeconds = 60, maxSeconds = 24 * 3600

    private static let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]

    /// 「30」「半」「一个半」「十五」「两」→ 数值（半 = 0.5）
    static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: "个", with: "")
        if let v = Double(t) { return v }
        if t == "半" { return 0.5 }
        if t.hasSuffix("半"), let v = number(String(t.dropLast())) { return v + 0.5 }
        if t == "十" { return 10 }
        if t.hasPrefix("十"), t.count == 2, let d = digits[t.last!] { return Double(10 + d) }
        if t.count == 2, t.hasSuffix("十"), let d = digits[t.first!] { return Double(d * 10) }
        if t.count == 3, Array(t)[1] == "十", let a = digits[Array(t)[0]], let b = digits[Array(t)[2]] { return Double(a * 10 + b) }
        if t.count == 1, let d = digits[t.first!] { return Double(d) }
        return nil
    }

    private static let pattern = #"(\d+(?:\.\d+)?|[零一二两三四五六七八九十]{1,3}个?半?|半)\s*(分钟|分|min|mins|minutes|小时|钟头|h|hr|hours?)\s*(?:后|之后|以后|later)"#

    static func parse(_ text: String) -> Plan? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard let n = number(ns.substring(with: m.range(at: 1))) else { return nil }
        let unit = ns.substring(with: m.range(at: 2)).lowercased()
        let isHour = unit.hasPrefix("小时") || unit == "钟头" || unit.hasPrefix("h")
        let secs = Int((n * (isHour ? 3600 : 60)).rounded())
        guard secs >= minSeconds, secs <= maxSeconds else { return nil }
        let after = ns.substring(from: m.range.location + m.range.length)
        let before = ns.substring(to: m.range.location)
        var what = clean(firstClause(after))
        if what.isEmpty { what = clean(lastClause(before)) }
        if what.isEmpty { what = clean(text) }
        return Plan(seconds: secs, what: String(what.prefix(60)))
    }

    private static let stops = CharacterSet(charactersIn: "，。！？；,.!?;\n")

    private static func firstClause(_ s: String) -> String { s.components(separatedBy: stops).first ?? "" }
    private static func lastClause(_ s: String) -> String {
        s.components(separatedBy: stops).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    }

    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["提醒我", "记得", "帮我", "叫我", "要", "再", "去", "我"] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func label(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return "\(seconds / 3600) 小时" }
        if seconds > 3600, seconds % 1800 == 0 { return String(format: "%.1f 小时", Double(seconds) / 3600) }
        return "\(seconds / 60) 分钟"
    }
}
