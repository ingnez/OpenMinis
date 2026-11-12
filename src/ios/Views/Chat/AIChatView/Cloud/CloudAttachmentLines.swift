import Foundation

/// 发给 Agent 的附件说明行：「[附件] 照片 1.jpg → 工作区 attachments/up_c63fca2f_1.jpg」。
/// 模型要靠这行找到文件（照样发给服务器），用户看到的气泡、预览、搜索片段里把它换成缩略图 / 「[图片]」。
enum CloudAttachmentLines {
    struct Item: Equatable {
        let filename: String
        let path: String
        var serverName: String { (path as NSString).lastPathComponent }
        var isImage: Bool { CloudAttachmentLines.imageExts.contains((path as NSString).pathExtension.lowercased()) }
    }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "bmp"]
    /// 只发附件没写字时客户端补的那句
    static let placeholderText = "请查看附件。"

    static func parse<S: StringProtocol>(_ line: S) -> Item? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("[附件] "), let arrow = s.range(of: " → 工作区 ") else { return nil }
        let name = s[s.index(s.startIndex, offsetBy: 5)..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let path = s[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.contains(" ") || path.hasPrefix("attachments/") else { return nil }
        return Item(filename: name.isEmpty ? (path as NSString).lastPathComponent : name, path: path)
    }

    /// 去掉附件行，返回给人看的文字和附件列表
    static func split(_ text: String) -> (text: String, items: [Item]) {
        var kept: [Substring] = []
        var items: [Item] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let it = parse(line) { items.append(it) } else { kept.append(line) }
        }
        guard !items.isEmpty else { return (text, []) }
        var shown = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if shown == placeholderText { shown = "" }
        return (shown, items)
    }

    /// 一行预览（主页、搜索、通知）：「这是我的排班 记住它 [图片]」
    static func preview(_ text: String) -> String {
        let s = split(text)
        var marks = s.items.map { $0.isImage ? "[图片]" : "[文件] \($0.filename)" }
        if s.items.isEmpty { marks = [] }
        let body = s.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return ([body] + marks).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// 相册多选：异步加载完成的先后不定，按点选下标排回原顺序
enum CloudPickOrder {
    static func sorted<T>(_ slots: [(Int, T)]) -> [T] {
        slots.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
    }
}
