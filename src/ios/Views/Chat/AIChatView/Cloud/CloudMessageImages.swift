import SwiftUI
import UIKit

/// 「问问这张图」：看图页把图交回 Bot 对话的输入框
private struct CloudAskImageKey: EnvironmentKey {
    static let defaultValue: ((UIImage) -> Void)? = nil
}

/// 当前对话的会话 ID：只有附件行（没有内嵌图片）的消息靠它去云端取原图
private struct CloudAttachmentSessionKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var cloudAskImage: ((UIImage) -> Void)? {
        get { self[CloudAskImageKey.self] }
        set { self[CloudAskImageKey.self] = newValue }
    }
    var cloudAttachmentSession: String? {
        get { self[CloudAttachmentSessionKey.self] }
        set { self[CloudAttachmentSessionKey.self] = newValue }
    }
}

/// 上传过的图片在本机留一份（缓存目录，最多 300 个），气泡缩略图先用它，历史消息再从云端取
enum CloudAttachmentCache {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cloud-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func safe(_ name: String) -> String? {
        name.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil && !name.contains("..") ? name : nil
    }

    static func save(_ data: Data, name: String) {
        guard let n = safe(name) else { return }
        try? data.write(to: dir.appendingPathComponent(n), options: .atomic)
        prune()
    }

    static func data(_ name: String) -> Data? {
        guard let n = safe(name) else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(n))
    }

    private static func prune(keep: Int = 300) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > keep else { return }
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for f in sorted.prefix(files.count - keep) { try? fm.removeItem(at: f) }
    }
}

enum CloudMessageImageData {
    static let attachmentScheme = "openminis-attachment:"

    /// 消息里的图片地址，按顺序：message_parts 里的 data: / https:；没有内嵌图片时，用附件行
    /// 「[附件] … → 工作区 attachments/up_….jpg」生成 openminis-attachment:<会话>|<文件名>（本机缓存优先，再从云端取）
    static func urls(_ content: String, sessionId: String? = nil) -> [String] {
        var text = content
        if content.hasPrefix("["), let data = content.data(using: .utf8),
           let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let inline: [String] = parts.compactMap { p in
                guard p["type"] as? String == "image_url" else { return nil }
                return (p["image_url"] as? [String: Any])?["url"] as? String ?? p["image_url"] as? String
            }
            if !inline.isEmpty { return inline }
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return CloudAttachmentLines.split(text).items.filter(\.isImage).map { attachmentScheme + (sessionId ?? "") + "|" + $0.serverName }
    }

    /// 气泡里各张图的附件文件名，按显示顺序（E2E 核对顺序用）；内嵌图片没有文件名时写「图片 N」
    static func orderLabel(_ content: String) -> String {
        var text = content
        if content.hasPrefix("["), let data = content.data(using: .utf8),
           let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        let names = CloudAttachmentLines.split(text).items.filter(\.isImage).map(\.filename)
        return names.isEmpty ? urls(content).indices.map { "图片 \($0 + 1)" }.joined(separator: ",") : names.joined(separator: ",")
    }

    private static func attachmentData(_ url: String) async -> Data? {
        let rest = url.dropFirst(attachmentScheme.count)
        guard let bar = rest.firstIndex(of: "|") else { return nil }
        let sid = String(rest[..<bar]), name = String(rest[rest.index(after: bar)...])
        if let local = CloudAttachmentCache.data(name) { return local }
        guard !sid.isEmpty, let remote = try? await CloudConnection.shared.downloadAttachment(path: "/v1/sessions/\(sid)/attachments/\(name)") else { return nil }
        CloudAttachmentCache.save(remote, name: name)
        return remote
    }

    static func load(_ url: String, maxPixel: CGFloat) async -> UIImage? {
        let key = "cloudimg\(Int(maxPixel)):\(url.count):\(url.suffix(48))"
        if let cached = NativeMediaImageCache.shared.image(for: key) { return cached }
        let data: Data?
        if url.hasPrefix(attachmentScheme) {
            data = await attachmentData(url)
        } else if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
            let b64 = String(url[url.index(after: comma)...])
            data = await Task.detached { Data(base64Encoded: b64) }.value
        } else if let u = URL(string: url), u.scheme == "https" || u.scheme == "http" {
            data = try? await URLSession.shared.data(from: u).0
        } else {
            data = nil
        }
        guard let data else { return nil }
        let img = await Task.detached { downsampleImageData(data, maxPixelSize: maxPixel) }.value
        if let img { NativeMediaImageCache.shared.set(img, for: key) }
        return img
    }
}

/// Bot 对话里一条消息的图片：同一摞卡片 + 同一个全屏看图页（用户发的和 Bot 发的都一样）
struct CloudMessageImages: View {
    let content: String
    var alignment: HorizontalAlignment = .trailing
    @Environment(\.cloudAskImage) private var askImage
    @Environment(\.cloudAttachmentSession) private var sessionId
    @State private var gallery: GalleryPresentation?

    var body: some View {
        let urls = CloudMessageImageData.urls(content, sessionId: sessionId)
        if !urls.isEmpty {
            ImageCardStack(sources: urls.enumerated().map { i, u in
                ImageStackSource(id: "\(i):\(u.count):\(u.suffix(32))", load: { await CloudMessageImageData.load(u, maxPixel: 640) })
            }, alignment: alignment, onOpen: { open(urls, at: $0) })
            .background {
                // 只在模拟器 E2E 里：把气泡里图片的先后（附件文件名）给 XCUITest 核对顺序
                if CloudE2E.token != nil {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("messageImageOrder")
                        .accessibilityLabel(CloudMessageImageData.orderLabel(content))
                }
            }
            .fullScreenCover(item: $gallery) { p in
                MessageImageGallery(items: p.items, startIndex: p.startIndex,
                                    onAsk: askImage.map { ask in { img, _ in ask(img) } })
            }
        }
    }

    private func open(_ urls: [String], at index: Int) {
        let items = urls.enumerated().map { i, u in
            GalleryItem(id: "\(i):\(u.count):\(u.suffix(32))", title: "图片 \(i + 1)",
                        load: { await CloudMessageImageData.load(u, maxPixel: 2048) },
                        source: URL(string: u).flatMap { $0.scheme?.hasPrefix("http") == true ? .remote($0) : nil })
        }
        gallery = GalleryPresentation(items: items, startIndex: ImageViewerIndex.clamp(index, count: items.count))
    }
}
