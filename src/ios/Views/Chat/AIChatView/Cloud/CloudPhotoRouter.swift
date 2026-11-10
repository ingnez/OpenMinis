import Foundation

/// 拍照识别分给对应的 Bot：按识别类型的关键词去匹配各 Bot 的名字、简介、指令和技能，
/// 最匹配的不是当前 Bot 时，输入框上方出现「交给 X」。没有明显更合适的就不提示。
enum CloudPhotoRouter {
    struct Candidate: Equatable {
        let id: String
        let name: String
        let text: String   // 简介 + 指令开头 + 技能名
    }

    static let keywords: [String: [String]] = [
        "识别药品": ["药", "药学", "药师", "用药", "剂量", "说明书", "pharm", "drug"],
        "读化验单": ["化验", "检验", "实验室", "lab", "ICU", "重症", "内科", "医生", "临床", "病例"],
        "看心电图": ["心电", "ECG", "EKG", "心内", "心脏", "ICU", "重症", "急诊"],
        "提取文字": ["OCR", "文字", "文档", "整理", "笔记", "秘书", "办公"],
    ]

    static func score(_ c: Candidate, kind: String) -> Int {
        let hay = (c.name + " " + c.text).lowercased()
        var s = 0
        for (i, k) in (keywords[kind] ?? []).enumerated() where hay.contains(k.lowercased()) {
            s += c.name.lowercased().contains(k.lowercased()) ? 6 : 3
            if i == 0 { s += 1 }
        }
        return s
    }

    /// current：当前对话的 Bot id。返回更合适的另一个 Bot（得分至少 3 且比当前 Bot 高）
    static func best(kind: String, current: String, bots: [Candidate]) -> Candidate? {
        var cur = 0
        if let c = bots.first(where: { $0.id == current }) { cur = score(c, kind: kind) }
        var best: Candidate?
        var bestScore = max(2, cur)
        for b in bots where b.id != current {
            let s: Int = score(b, kind: kind)
            if s > bestScore || (s == bestScore && best != nil && b.name < best!.name) {
                best = b
                bestScore = s
            }
        }
        return best
    }
}
