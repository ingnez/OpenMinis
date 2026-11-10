import Foundation

/// Bot 头像的 12 种颜色（RGB 0…1）。深色模式下「黑色」（主 Bot 默认）换成看得见的石墨灰，
/// 否则身体融进黑色背景、只剩一双白眼睛。其余颜色在两种外观下相同。
enum CloudAvatarPalette {
    typealias RGB = (r: Double, g: Double, b: Double)

    static let light: [RGB] = [
        (0, 0, 0),              // 黑
        (0.55, 0.38, 0.24),     // 棕
        (0.93, 0.26, 0.27),     // 红
        (0.95, 0.45, 0.16),     // 橙
        (0.92, 0.58, 0.14),     // 琥珀（略深一点，浅色背景上也分得开）
        (0.36, 0.78, 0.45),     // 绿
        (0.33, 0.73, 0.65),     // 青
        (0.24, 0.52, 0.96),     // 蓝
        (0.55, 0.36, 0.96),     // 紫
        (0.92, 0.29, 0.60),     // 粉
        (0.39, 0.40, 0.95),     // 靛
        (0.47, 0.47, 0.49),     // 灰
    ]
    /// 深色模式下黑色的替代：石墨灰（对纯黑背景约 3.9:1，白眼睛对它约 5:1）
    static let darkInk: RGB = (0.42, 0.42, 0.44)

    static var count: Int { light.count }

    static func rgb(_ index: Int, dark: Bool) -> RGB {
        let i = min(max(index, 0), light.count - 1)
        return dark && i == 0 ? darkInk : light[i]
    }

    /// WCAG 相对亮度与对比度
    static func luminance(_ c: RGB) -> Double {
        func ch(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
