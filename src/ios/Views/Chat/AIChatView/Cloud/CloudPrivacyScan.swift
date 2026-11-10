import Foundation

/// 病区隐私自查：发给云端前，在手机上找出疑似病人身份信息（身份证号、手机号、住院号/病案号、「患者+姓名」、床号+姓名），
/// 让你一键隐去或照原样发。纯本地正则，不上传；是提醒不是保证。只依赖 Foundation，Linux 上单测。
enum CloudPrivacyScan {
    static let enabledKey = "OpenMinisPrivacyScan"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    struct Hit: Equatable {
        let kind: String
        let text: String
    }

    private struct Rule {
        let kind: String
        let pattern: String
        let group: Int          // 要隐去的那一段
        let replacement: String
    }

    private static let rules: [Rule] = [
        Rule(kind: "身份证号", pattern: #"(?<!\d)(\d{17}[\dXx])(?!\d)"#, group: 1, replacement: "[身份证号]"),
        Rule(kind: "手机号", pattern: #"(?<!\d)(1[3-9]\d{9})(?!\d)"#, group: 1, replacement: "[手机号]"),
        Rule(kind: "住院号/病案号", pattern: #"(?:住院号|病案号|病历号|门诊号|登记号|MRN|ID号)\s*[:：]?\s*([A-Za-z0-9-]{4,})"#, group: 1, replacement: "[已隐去]"),
        Rule(kind: "姓名", pattern: #"(?:患者|病人|病患|姓名\s*[:：]?)\s*([\x{4e00}-\x{9fa5}]{2,3}?)(?=[，,。；;\s、]|男|女|先生|女士|$)"#, group: 1, replacement: "某某"),
        Rule(kind: "床号+姓名", pattern: #"\d{1,3}\s*床\s*([\x{4e00}-\x{9fa5}]{2,3}?)(?=[，,。；;\s、]|男|女|$)"#, group: 1, replacement: "某某"),
    ]

    static func hits(_ text: String) -> [Hit] {
        var out: [Hit] = []
        let ns = text as NSString
        for r in rules {
            guard let re = try? NSRegularExpression(pattern: r.pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let g = m.range(at: r.group)
                guard g.location != NSNotFound else { continue }
                let hit = Hit(kind: r.kind, text: ns.substring(with: g))
                if !Self.notNames.contains(hit.text), !out.contains(hit) { out.append(hit) }
            }
        }
        return out
    }

    /// 常见的非姓名词（「患者血压」「患者意识」之类别误报）
    private static let notNames: Set<String> = ["血压", "意识", "心率", "体温", "目前", "今日", "昨日", "入院", "出院", "家属", "既往",
                                                "病情", "神志", "自诉", "主诉", "呼吸", "尿量", "血氧", "近期", "术后", "无明显", "一般"]

    static func redact(_ text: String) -> String {
        var out = text
        for r in rules {
            guard let re = try? NSRegularExpression(pattern: r.pattern) else { continue }
            let ns = out as NSString
            // 从后往前替换，前面的位置不受影响
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let g = m.range(at: r.group)
                guard g.location != NSNotFound, !notNames.contains((out as NSString).substring(with: g)) else { continue }
                out = (out as NSString).replacingCharacters(in: g, with: r.replacement)
            }
        }
        return out
    }

    static func summary(_ hits: [Hit]) -> String {
        hits.prefix(4).map { "\($0.kind)「\($0.text)」" }.joined(separator: "、") + (hits.count > 4 ? " 等" : "")
    }
}
