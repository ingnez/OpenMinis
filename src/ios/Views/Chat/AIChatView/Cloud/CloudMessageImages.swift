import SwiftUI
import UIKit

/// 「问问这张图」：看图页把图交回 Bot 对话的输入框
private struct CloudAskImageKey: EnvironmentKey {
    static let defaultValue: ((UIImage) -> Void)? = nil
}

extension EnvironmentValues {
    var cloudAskImage: ((UIImage) -> Void)? {
        get { self[CloudAskImageKey.self] }
        set { self[CloudAskImageKey.self] = newValue }
    }
}

enum CloudMessageImageData {
    /// message_parts 里的图片地址（data: 或 https:），按顺序
    static func urls(_ content: String) -> [String] {
        guard content.hasPrefix("["), let data = content.data(using: .utf8),
              let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return parts.compactMap { p in
            guard p["type"] as? String == "image_url" else { return nil }
            return (p["image_url"] as? [String: Any])?["url"] as? String ?? p["image_url"] as? String
        }
    }

    static func load(_ url: String, maxPixel: CGFloat) async -> UIImage? {
        let key = "cloudimg\(Int(maxPixel)):\(url.count):\(url.suffix(48))"
        if let cached = NativeMediaImageCache.shared.image(for: key) { return cached }
        let data: Data?
        if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
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
    @State private var gallery: GalleryPresentation?

    var body: some View {
        let urls = CloudMessageImageData.urls(content)
        if !urls.isEmpty {
            ImageCardStack(sources: urls.enumerated().map { i, u in
                ImageStackSource(id: "\(i):\(u.count):\(u.suffix(32))", load: { await CloudMessageImageData.load(u, maxPixel: 640) })
            }, alignment: alignment, onOpen: { open(urls, at: $0) })
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
