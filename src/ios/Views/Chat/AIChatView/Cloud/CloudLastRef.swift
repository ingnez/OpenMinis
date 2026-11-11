import Foundation

/// 「刚才那个」：用户说起上一张图或上一个文件时，在本机定位最近一条附件并标进正文，模型不用猜。
enum CloudLastRef {
    struct Hit: Equatable {
        let filename: String
        let path: String
        let isImage: Bool
        var chip: String { isImage ? "引用刚才那张图：\(filename)" : "引用刚才那个文件：\(filename)" }
    }

    static let phrases = [
        "刚才那个", "刚才那张", "刚才那份", "刚才的图", "刚才的照片", "刚才的文件",
        "上一张图", "上一张照片", "上一个文件", "那张图", "那个文件",
    ]

    static var e2eForced: Bool { ProcessInfo.processInfo.environment["OPENMINIS_E2E_LAST_REF"] == "1" }

    static func triggered(by text: String) -> Bool {
        phrases.contains(where: { text.contains($0) })
    }

    static func last(in messages: [[String: Any]]) -> Hit? {
        if e2eForced {
            return Hit(filename: "排班表.jpg", path: "attachments/e2e_demo.jpg", isImage: true)
        }
        for msg in messages.reversed() {
            if let item = CloudAttachmentLines.split(contentString(msg["content"])).items.last {
                return Hit(filename: item.filename, path: item.path, isImage: item.isImage)
            }
        }
        return nil
    }

    static func hit(for text: String, messages: [[String: Any]]) -> Hit? {
        triggered(by: text) ? last(in: messages) : nil
    }

    static func annotate(_ text: String, hit: Hit) -> String {
        if text.contains("（自动引用") { return text }
        let kind = hit.isImage ? "上一张图" : "上一个文件"
        return text + "\n（自动引用\(kind)：工作区 \(hit.path)，原名 \(hit.filename)）"
    }

    /// 消息 content 可能是纯文字，也可能是看图用的 JSON parts。
    static func contentString(_ raw: Any?) -> String {
        if let s = raw as? String {
            if s.hasPrefix("["), let data = s.data(using: .utf8),
               let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            }
            return s
        }
        return ""
    }
}
