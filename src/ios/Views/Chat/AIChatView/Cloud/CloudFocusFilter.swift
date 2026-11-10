import Foundation

/// 专注模式过滤（iOS 16 的 SetFocusFilterIntent 写入）：值班专注打开时首页只显示医疗相关的 Bot。
/// 「医疗 Bot」按名字 / 简介 / 指令里的关键词判断；主助手和置顶的 Bot 不受影响，搜索时也显示全部。
enum CloudFocusFilter {
    static let key = "OpenMinisFocusMedicalOnly"

    static let keywords = ["医", "药", "病", "临床", "护理", "急诊", "icu", "重症", "诊", "检验", "影像", "手术", "麻醉",
                           "指南", "用药", "剂量", "评分", "sofa", "apache", "medical", "clinical", "drug", "nurse", "doctor", "patient"]

    static var active: Bool { UserDefaults.standard.bool(forKey: key) }

    static func isMedical(name: String, summary: String, instructions: String) -> Bool {
        let text = (name + " " + summary + " " + String(instructions.prefix(600))).lowercased()
        return keywords.contains { text.contains($0) }
    }

    static func allows(name: String, summary: String, instructions: String, pinned: Bool, searching: Bool, on: Bool) -> Bool {
        !on || pinned || searching || isMedical(name: name, summary: summary, instructions: instructions)
    }
}

extension Notification.Name {
    static let cloudFocusFilterChanged = Notification.Name("OpenMinisCloudFocusFilterChanged")
}
