import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// 本地模式选图后的编码（和 Bot 模式同一个「保留原图 / 自动压缩」开关，见 ImageSendPolicy）：
/// 默认 HEIC / JPEG 缩到长边 1600 重压 JPEG；保留原图时只把 HEIC 转成同尺寸 JPEG。
/// PNG / GIF / WebP 原样保留（透明、动图不丢）。处理不了时返回 nil，调用方照旧存原字节。
enum ImageSendEncoder {
    static func prepare(_ data: Data, ext: String, keepOriginal: Bool = ImageSendPolicy.keepOriginal) -> (data: Data, ext: String)? {
        let e = ext.lowercased()
        let isHEIC = e == "heic" || e == "heif"
        guard isHEIC || e == "jpg" || e == "jpeg" else { return nil }
        if keepOriginal && !isHEIC { return nil }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let longSide = max(w, h)
        let target = keepOriginal ? longSide : min(longSide, Int(ImageSendPolicy.maxSide))
        // 已经够小的 JPEG 不重压
        if !isHEIC && target >= longSide { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 按 EXIF 方向转正
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: keepOriginal ? 0.92 : 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, "jpg")
    }
}

/// 本地和云端的发图设置使用同一个开关和偏好。
struct ImageKeepOriginalToggle: View {
    @AppStorage(ImageSendPolicy.keepOriginalKey) private var keepOriginal = false

    var body: some View {
        HStack {
            Toggle(isOn: $keepOriginal) {
                Text(keepOriginal ? "保留原图（之后选的图不缩小，HEIC 仍转 JPEG）" : "自动压缩大图（长边 1600，HEIC 转 JPEG）").font(.caption)
            }
            .toggleStyle(.button).buttonStyle(.borderless).font(.caption)
            .accessibilityIdentifier("keepOriginalToggle")
            Spacer()
        }
        .padding(.horizontal, 14)
    }
}
