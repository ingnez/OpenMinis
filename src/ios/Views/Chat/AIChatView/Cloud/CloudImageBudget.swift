import UIKit

/// 发给模型的图片大小预算：≤1.4 MB 的 JPEG（服务器 message_parts 上限 2 MB，base64 后约 1.87 MB）。
/// 太大就逐级缩小、降质量，直到放得下。
enum CloudImageBudget {
    static let maxBytes = 1_400_000
    static let steps: [(side: CGFloat, quality: CGFloat)] = [(1600, 0.8), (1600, 0.65), (1280, 0.6), (1024, 0.55), (800, 0.5)]
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tiff"]

    static func isImageName(_ name: String) -> Bool {
        imageExts.contains((name as NSString).pathExtension.lowercased())
    }

    static func fit(_ image: UIImage) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        for step in steps {
            let k = min(1, step.side / max(px.width, px.height, 1))
            let size = CGSize(width: max(1, (px.width * k).rounded()), height: max(1, (px.height * k).rounded()))
            let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let data = img.jpegData(compressionQuality: step.quality), data.count <= maxBytes { return data }
        }
        return nil
    }
}
