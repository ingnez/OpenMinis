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

/// 「依据：…｜把握度：高/中/低」行（服务器 cloud_runmodel.source_line 同口径）：从正文里取出来单独显示成标签
enum CloudSourceLine {
    static let prefix = "依据："
    static let sep = "｜把握度："

    struct Parsed: Equatable {
        let source: String
        let confidence: String?
        let rest: String      // 去掉这一行后的正文
        var lowConfidence: Bool { confidence == "低" || source.hasPrefix("无明确出处") }
    }

    static func parse(_ text: String) -> Parsed? {
        var lines = text.components(separatedBy: "\n")
        guard let i = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }) else { return nil }
        let body = lines[i].trimmingCharacters(in: .whitespaces).dropFirst(prefix.count)
        let parts = body.components(separatedBy: sep)
        let source = parts[0].trimmingCharacters(in: .whitespaces)
        let conf = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        lines.remove(at: i)
        return Parsed(source: source, confidence: conf.isEmpty ? nil : conf,
                      rest: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
