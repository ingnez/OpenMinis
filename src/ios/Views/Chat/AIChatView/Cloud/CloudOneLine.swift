import Foundation

/// 「一句话版本」：回复以「一句话：」开头时拆成结论 + 细节（服务器 cloud_runmodel.split_one_line 同口径）。只依赖 Foundation
enum CloudOneLine {
    static let prefix = "一句话："

    static func split(_ text: String) -> (head: String, detail: String)? {
        let t = text.drop { $0.isWhitespace || $0.isNewline }
        guard t.hasPrefix(prefix) else { return nil }
        let lines = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let head = lines[0].dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return nil }
        let detail = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (head, detail)
    }
}
