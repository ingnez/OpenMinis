import Foundation

/// 口述病例脱敏：在手机上先把姓名、证件号、电话、住院号 / 床号、具体日期、医院、地址换成占位符，再发给 Bot。
/// 年龄、性别、病程（「入院第 3 天」）这类复盘需要的信息保留。规则是保守的正则，不保证 100%，所以发送前会给用户看一遍。
enum CloudCaseRedactor {
    struct Result: Equatable {
        let text: String
        /// 每类隐去了几处，例如 ["电话": 1, "姓名": 2]
        let counts: [String: Int]
        var total: Int { counts.values.reduce(0, +) }
    }

    private static let rules: [(label: String, pattern: String, template: String)] = [
        ("身份证", #"(?<!\d)\d{17}[\dXx](?!\d)"#, "[身份证]"),
        ("电话", #"(?<!\d)1[3-9]\d{9}(?!\d)"#, "[电话]"),
        ("电话", #"(?<!\d)0\d{2,3}-?\d{7,8}(?!\d)"#, "[电话]"),
        ("病历号", #"(住院号|病案号|门诊号|病历号|登记号|ID)\s*[:：]?\s*[A-Za-z0-9-]{3,}"#, "$1[已隐去]"),
        ("床号", #"\d{1,3}\s*(床|号床)"#, "[床号]"),
        ("姓名", #"(姓名|患者|病人|家属|患儿)\s*[:：]?\s*[\x{4e00}-\x{9fa5}]{1}(?:某某|某)"#, "$1[姓名]"),
        ("姓名", #"(姓名)\s*[:：]?\s*[\x{4e00}-\x{9fa5}]{2,3}"#, "$1[姓名]"),
        ("姓名", #"(患者|病人|家属|患儿)\s*[:：]?\s*([\x{4e00}-\x{9fa5}]{2,3})(?=[，,。\s]|男|女|\d)"#, "$1[姓名]"),
        ("日期", #"\d{4}\s*[年\-/.]\s*\d{1,2}\s*[月\-/.]\s*\d{1,2}\s*日?"#, "[日期]"),
        ("日期", #"(?<!第)\d{1,2}\s*月\s*\d{1,2}\s*[日号]"#, "[日期]"),
        ("医院", #"[[\x{4e00}-\x{9fa5}]--[因入到在去转于住送诊至从和与及来回经]]{2,14}(?:医院|卫生院|医学中心|诊所)"#, "[医院]"),
        ("地址", #"[[\x{4e00}-\x{9fa5}]--[因入到在去转于住送诊至从和与及来回经]]{2,8}(?:省|市|区|县)[\x{4e00}-\x{9fa5}\d]{0,16}(?:路|街|巷|村|小区|号)"#, "[地址]"),
    ]

    /// 名字规则误伤的常见词（「患者神志」「病人家属」之类）
    private static let notNames: Set<String> = ["神志", "家属", "意识", "血压", "心率", "体温", "自述", "诉", "入院", "既往", "目前", "今日", "昨日",
                                                "男性", "女性", "男", "女", "一般", "病情", "术后", "主诉", "精神"]

    static func redact(_ input: String) -> Result {
        var text = input
        var counts: [String: Int] = [:]
        for rule in rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            var hits = 0
            var out = ""
            var last = text.startIndex
            for m in re.matches(in: text, range: range) {
                guard let r = Range(m.range, in: text) else { continue }
                if rule.label == "姓名", m.numberOfRanges > 2, let nr = Range(m.range(at: 2), in: text),
                   notNames.contains(where: { text[nr].hasPrefix($0) }) {
                    continue
                }
                out += text[last..<r.lowerBound]
                out += re.replacementString(for: m, in: text, offset: 0, template: rule.template)
                last = r.upperBound
                hits += 1
            }
            if hits > 0 {
                out += text[last...]
                text = out
                counts[rule.label, default: 0] += hits
            }
        }
        return Result(text: text, counts: counts)
    }

    /// 发给 Bot 的复盘提示：结构化模板 + 已脱敏的口述
    static func reviewPrompt(_ redacted: String) -> String {
        """
        下面是我口述的一个病例（已在手机上脱敏，占位符如 [姓名]、[日期] 不要猜原值）。请帮我做病例复盘：
        1. 病例摘要（主诉、现病史要点、关键查体和检查）
        2. 诊断思路：主要诊断与依据、需要鉴别的诊断
        3. 处理过程回顾：做得好的、可以更早或更好的地方
        4. 相关指南要点（只引用你确定存在的指南，写清名称和年份，不确定就说不确定）
        5. 可提炼的考点 / 教学要点
        如果发现还有可能识别患者身份的信息，先提醒我。

        口述内容：
        \(redacted)
        """
    }

    static func summary(_ r: Result) -> String {
        guard r.total > 0 else { return "没有找到需要隐去的信息，发送前请自己再看一遍" }
        let order = ["姓名", "身份证", "电话", "病历号", "床号", "日期", "医院", "地址"]
        return "已隐去 " + order.compactMap { k in r.counts[k].map { "\(k) \($0) 处" } }.joined(separator: "、")
    }
}
