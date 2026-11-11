import Foundation
#if canImport(CoreGraphics)
import CoreGraphics  // macOS 上 CGSize/CGPoint 的 .zero 和 Equatable 在这里
#endif

/// 用户消息里的图片：一张是一张圆角卡；多张叠成一摞、略微错开旋转，下面写「N 张图片」。
/// 只有几何，没有视图，所以行高估算和界面读同一组数字（Linux 单测也能跑）。
enum ImageStackLayout {
    struct Card: Equatable {
        /// 第几张图（0 = 最上面那张，也就是第一张）
        let index: Int
        let rotation: Double   // 角度
        let offset: CGSize
        let zIndex: Double
    }

    static let singleSize = CGSize(width: 210, height: 210)
    static let cardSize = CGSize(width: 168, height: 210)
    static let cornerRadius: CGFloat = 18
    /// 叠放时露出的卡片数（再多也只画 3 张，其余看计数）
    static let maxStacked = 3
    /// 长按展开时最多铺开的张数
    static let maxFanned = 5
    static let captionHeight: CGFloat = 18
    static let captionSpacing: CGFloat = 6
    /// 旋转和错开需要的余量，算进容器尺寸，免得卡片角压到别的行
    static let stackInset = CGSize(width: 28, height: 8)
    /// 铺开后相邻两张中心的水平间距
    static let fanSpacing: CGFloat = 46
    /// 跟手滑动超过这个距离，松手就打开当前高亮的那张；否则只保持展开/收回
    static let scrubThreshold: CGFloat = 12
    /// 当前选中的卡放大，其余略缩小（长按滑动时）
    static let highlightScale: CGFloat = 1.14
    static let restScale: CGFloat = 0.94

    static func isStack(_ count: Int) -> Bool { count > 1 }

    /// 「◫ N 张图片」；一张图不写
    static func caption(_ count: Int) -> String? { count > 1 ? "\(count) 张图片" : nil }

    /// 卡片区域（不含说明文字）
    static func stackSize(count: Int) -> CGSize {
        guard count > 0 else { return .zero }
        if count == 1 { return singleSize }
        return CGSize(width: cardSize.width + stackInset.width * 2, height: cardSize.height + stackInset.height * 2)
    }

    /// 整块高度：卡片 + 说明
    static func height(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return stackSize(count: count).height + (count > 1 ? captionSpacing + captionHeight : 0)
    }

    /// 从后往前画的卡片（数组最后一个在最上面）
    static func cards(count: Int, fanned: Bool = false) -> [Card] {
        guard count > 0 else { return [] }
        if count == 1 { return [Card(index: 0, rotation: 0, offset: .zero, zIndex: 0)] }
        if fanned {
            let n = min(count, maxFanned)
            let mid = Double(n - 1) / 2
            return (0..<n).reversed().map { i in
                let d = Double(i) - mid
                return Card(index: i, rotation: d * 8, offset: CGSize(width: d * fanSpacing, height: abs(d) * 6), zIndex: Double(n - i))
            }
        }
        let n = min(count, maxStacked)
        let rotations: [Double] = [0, 7, -6]
        let offsets: [CGSize] = [.zero, CGSize(width: 14, height: 2), CGSize(width: -14, height: 4)]
        return (0..<n).reversed().map { i in Card(index: i, rotation: rotations[i], offset: offsets[i], zIndex: Double(n - i)) }
    }
}

extension ImageStackLayout {
    /// 点在卡片区域（左上角为原点）的哪一张上：从最上面那张往下找；没点中任何一张算第一张。
    /// 叠放时永远是第一张；旋转忽略（角度很小，按未旋转的矩形算）
    static func hitIndex(at p: CGPoint, count: Int, fanned: Bool) -> Int {
        guard fanned, count > 1 else { return 0 }
        let box = stackSize(count: count)
        for card in cards(count: count, fanned: true).sorted(by: { $0.zIndex > $1.zIndex }) {
            let cx = box.width / 2 + card.offset.width, cy = box.height / 2 + card.offset.height
            if abs(p.x - cx) <= cardSize.width / 2, abs(p.y - cy) <= cardSize.height / 2 { return card.index }
        }
        return 0
    }
}

/// 全屏看图的页码规则

extension ImageStackLayout {
    /// 手指在铺开容器里的 x（左上为原点）对应哪一张（只在可见的铺开张数里，最近中心）
    static func focusedIndex(atX x: CGFloat, count: Int) -> Int {
        let n = min(max(count, 1), maxFanned)
        guard n > 1 else { return 0 }
        let mid = stackSize(count: count).width / 2
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 0..<n {
            let d = CGFloat(i) - CGFloat(n - 1) / 2
            let cx = mid + d * fanSpacing
            let dist = abs(x - cx)
            if dist < bestDist { bestDist = dist; best = i }
        }
        return best
    }

    static func scale(index: Int, focused: Int, fanned: Bool) -> CGFloat {
        guard fanned else { return 1 }
        return index == focused ? highlightScale : restScale
    }

    /// 松手是否打开当前高亮的那张（滑动超过阈值）
    static func shouldOpenOnRelease(translation: CGFloat) -> Bool {
        abs(translation) >= scrubThreshold
    }
}

/// 输入框附图：上方大号缩略图条，输入框整体是圆角大卡片，文字区不被挤扁
enum ComposerAttachLayout {
    static let thumbSize = CGSize(width: 140, height: 140)
    static let thumbCorner: CGFloat = 18
    static let composerCorner: CGFloat = 22
    static let thumbSpacing: CGFloat = 10
    /// × 超出缩略图上沿的空间
    static let closeOverhang: CGFloat = 10
    static let textMinHeight: CGFloat = 44
    static var stripHeight: CGFloat { thumbSize.height + closeOverhang }
    /// 附图时整块最小高度：大缩略图在文字上方，文字区至少 textMinHeight
    static func composerMinHeight(attachmentCount: Int) -> CGFloat {
        guard attachmentCount > 0 else { return textMinHeight }
        return stripHeight + 8 + textMinHeight
    }
    /// 给定整块高度时，文字区还能剩多少（不会低于最小值）
    static func textHeight(composerHeight: CGFloat, attachmentCount: Int) -> CGFloat {
        guard attachmentCount > 0 else { return max(textMinHeight, composerHeight) }
        return max(textMinHeight, composerHeight - stripHeight - 8)
    }
}

enum ImageViewerIndex {
    static func clamp(_ index: Int, count: Int) -> Int { max(0, min(index, max(count - 1, 0))) }
    /// 底部缩略图条：两张以上才显示
    static func showsStrip(_ count: Int) -> Bool { count > 1 }
}

/// 发图前的压缩规则：默认长边 1600、JPEG；HEIC 也转成 JPEG（模型和网页都认）；「保留原图」时只转格式不缩小
enum ImageSendPolicy {
    static let keepOriginalKey = "imageSend.keepOriginal"
    static let maxSide: CGFloat = 1600
    static var keepOriginal: Bool {
        get { UserDefaults.standard.bool(forKey: keepOriginalKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepOriginalKey) }
    }

    /// 缩放后的尺寸（像素）
    static func targetSize(for size: CGSize, keepOriginal: Bool) -> CGSize {
        guard !keepOriginal, size.width > 0, size.height > 0 else { return size }
        let scale = min(1, maxSide / max(size.width, size.height))
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
