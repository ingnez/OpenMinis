import Foundation

/// 口述转结构化：把一段交班或病例口述填进固定模板（交班单 / 病例摘要）。纯本地规则，不上传。
enum CloudOralStruct {
    enum Kind: String, Equatable, CaseIterable {
        case handover = "交班单"
        case caseSummary = "病例摘要"
    }

    struct Field: Equatable {
        let name: String
        let value: String
    }

    struct Result: Equatable {
        let kind: Kind
        let fields: [Field]
        let leftover: String

        var formatted: String {
            var lines = ["【\(kind.rawValue)】"]
            for f in fields {
                lines.append("- \(f.name)：\(f.value)")
            }
            let extra = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
            if !extra.isEmpty { lines.append("- 其他：\(extra)") }
            return lines.joined(separator: "\n")
        }
    }

    static func detect(_ text: String) -> Kind {
        if text.contains("主诉") || text.contains("现病史") || text.contains("病例摘要") || text.contains("病例：") {
            return .caseSummary
        }
        return .handover
    }

    static func parse(_ text: String, kind: Kind? = nil) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kind ?? detect(trimmed)
        let specs: [(String, String)] = k == .handover
            ? [
                ("床号", #"(\d{1,3}\s*床)"#),
                ("诊断", #"(?:诊断|考虑)(?:是|为|：|:)?\s*([^，,。；;\n]+)"#),
                ("目前病情", #"(?:目前|病情)(?:是|为|：|:)?\s*([^，,。；;\n]+)"#),
                ("生命体征", #"(?:血压\s*\d{2,3}\s*/\s*\d{2,3}|心率\s*\d{2,3}|血氧\s*\d{2,3}%?)(?:[，,、]\s*(?:血压\s*\d{2,3}\s*/\s*\d{2,3}|心率\s*\d{2,3}|血氧\s*\d{2,3}%?))*"#),
                ("已做处理", #"(?:已(?:经)?(?:用|做|给|处理)|处理)\s*[:：]?\s*([^。；;\n]+)"#),
                ("需关注", #"(?:需关注|关注|交班事项|今晚关注)\s*[:：]?\s*([^。；;\n]+)"#),
            ]
            : [
                ("主诉", #"(?:主诉)\s*[:：]?\s*([^。；;\n]+)"#),
                ("现病史", #"(?:现病史)\s*[:：]?\s*([^。；;\n]+)"#),
                ("既往史", #"(?:既往史|既往)\s*[:：]?\s*([^。；;\n]+)"#),
                ("查体", #"(?:查体|体检)\s*[:：]?\s*([^。；;\n]+)"#),
                ("检查", #"(?:检查|辅助检查)\s*[:：]?\s*([^。；;\n]+)"#),
                ("诊断", #"(?:诊断|考虑)(?:是|为|：|:)?\s*([^，,。；;\n]+)"#),
                ("处理", #"(?:处理|已处理|治疗)\s*[:：]?\s*([^。；;\n]+)"#),
            ]
        var fields: [Field] = []
        let ns = trimmed as NSString
        let full = NSRange(location: 0, length: ns.length)
        for (name, pattern) in specs {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            guard let m = re.firstMatch(in: trimmed, range: full) else { continue }
            let g = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range
            let value = ns.substring(with: g).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            fields.append(Field(name: name, value: value))
        }
        // leftover: drop matched ranges by replacing with space via regex again
        var leftover = trimmed
        for (_, pattern) in specs {
            if let re = try? NSRegularExpression(pattern: pattern) {
                leftover = re.stringByReplacingMatches(in: leftover, range: NSRange(location: 0, length: (leftover as NSString).length), withTemplate: " ")
            }
        }
        leftover = leftover.replacingOccurrences(of: "交班单", with: " ")
        leftover = leftover.replacingOccurrences(of: "交班：", with: " ")
        leftover = leftover.replacingOccurrences(of: "交班:", with: " ")
        leftover = leftover.replacingOccurrences(of: "病例摘要", with: " ")
        leftover = leftover.replacingOccurrences(of: #"^[交班病例：:\s，,。；;]+"#, with: "", options: .regularExpression)
        leftover = leftover.replacingOccurrences(of: #"[\s，,。；;]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(kind: k, fields: fields, leftover: leftover)
    }
}
