import Foundation
#if canImport(CoreGraphics)
import CoreGraphics  // macOS 上 CGSize/CGPoint 的 .zero 和 Equatable 在这里
#endif

// 图片叠卡的几何、看图页页码、发图压缩规则。纯逻辑，Linux 上跑。
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

@main struct ImageStackLayoutTests {
    static func main() {
        // 张数 → 画几张卡、写不写说明
        check(ImageStackLayout.cards(count: 0).isEmpty, "0 张不画")
        let one = ImageStackLayout.cards(count: 1)
        check(one.count == 1 && one[0].rotation == 0 && one[0].offset == .zero, "一张：一张不转的卡")
        check(ImageStackLayout.caption(1) == nil && !ImageStackLayout.isStack(1), "一张没有「N 张图片」")
        check(ImageStackLayout.cards(count: 2).count == 2 && ImageStackLayout.caption(2) == "2 张图片", "两张叠两张")
        let nine = ImageStackLayout.cards(count: 9)
        check(nine.count == 3 && ImageStackLayout.caption(9) == "9 张图片", "九张只画 3 张，说明写 9 张")
        check(nine.last?.index == 0 && nine.last?.rotation == 0, "最上面是第一张，摆正")
        check(nine.map(\.index) == [2, 1, 0], "从后往前画")
        check(Set(nine.map(\.zIndex)).count == 3 && nine.last!.zIndex > nine.first!.zIndex, "层级不重复，第一张在最上")
        check(nine.dropLast().allSatisfy { $0.rotation != 0 }, "后面的卡略微旋转")

        // 长按铺开
        let fan = ImageStackLayout.cards(count: 9, fanned: true)
        check(fan.count == 9, "长按铺开全部 9 张")
        let xs = fan.sorted { $0.index < $1.index }.map(\.offset.width)
        check(zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 }, "铺开后从左到右是第 1…9 张")
        check(abs(xs.first! + xs.last!) < 0.001, "铺开左右对称")
        check(ImageStackLayout.cards(count: 1, fanned: true).count == 1, "一张不铺开")

        // 尺寸和行高（估算行高读的就是这个）
        check(ImageStackLayout.height(count: 0) == 0, "没图高度 0")
        check(ImageStackLayout.height(count: 1) == ImageStackLayout.singleSize.height, "一张只有卡高")
        let h3 = ImageStackLayout.height(count: 3)
        check(h3 == ImageStackLayout.cardSize.height + 2 * ImageStackLayout.stackInset.height + ImageStackLayout.captionSpacing + ImageStackLayout.captionHeight, "多张 = 卡 + 余量 + 说明")
        check(ImageStackLayout.height(count: 2) == ImageStackLayout.height(count: 20), "张数多高度不变")
        check(ImageStackLayout.stackSize(count: 4).width >= ImageStackLayout.cardSize.width + 28, "旋转余量算进宽度")

        // 铺开后点在哪张上（叠放时永远第一张）
        let box = ImageStackLayout.stackSize(count: 3)
        check(ImageStackLayout.hitIndex(at: CGPoint(x: box.width / 2, y: box.height / 2), count: 3, fanned: false) == 0, "叠放时点哪都是第一张")
        let fan3 = ImageStackLayout.cards(count: 3, fanned: true)
        let cx: CGFloat = box.width / 2
        let cy: CGFloat = box.height / 2
        let topCard = fan3.max { $0.zIndex < $1.zIndex }!
        let topPoint = CGPoint(x: cx + topCard.offset.width, y: cy + topCard.offset.height)
        check(ImageStackLayout.hitIndex(at: topPoint, count: 3, fanned: true) == topCard.index, "铺开后点最上面那张的中心")
        let left = fan3.min { $0.offset.width < $1.offset.width }!
        let half: CGFloat = ImageStackLayout.cardSize.width / 2
        let leftEdge = CGPoint(x: cx + left.offset.width - half + 4, y: cy + left.offset.height)
        check(ImageStackLayout.hitIndex(at: leftEdge, count: 3, fanned: true) == left.index, "点最左边露出来的那张")
        check(ImageStackLayout.hitIndex(at: CGPoint(x: -500, y: -500), count: 3, fanned: true) == 0, "点空白算第一张")

        // 长按滑动：跟手选中、松手是否打开
        let midX = box.width / 2
        check(ImageStackLayout.focusedIndex(atX: midX, count: 3) == 1, "三张铺开时手指在中间是第 2 张")
        let leftX = midX - ImageStackLayout.fanSpacing
        let rightX = midX + ImageStackLayout.fanSpacing
        check(ImageStackLayout.focusedIndex(atX: leftX, count: 3) == 0, "手指在左边是第 1 张")
        check(ImageStackLayout.focusedIndex(atX: rightX, count: 3) == 2, "手指在右边是第 3 张")
        check(ImageStackLayout.focusedIndex(atX: midX, count: 1) == 0, "一张总是第 1 张")
        check(ImageStackLayout.scale(index: 2, focused: 2, fanned: true) == ImageStackLayout.highlightScale, "选中的卡放大")
        check(ImageStackLayout.scale(index: 0, focused: 2, fanned: true) == ImageStackLayout.restScale, "没选中的略缩小")
        check(ImageStackLayout.scale(index: 2, focused: 2, fanned: false) == 1, "没展开不放大")
        let boundary = midX + ImageStackLayout.fanSpacing / 2
        check(ImageStackLayout.focusedIndex(atX: boundary + 2, count: 3, keeping: 1) == 1, "分界附近抖动仍选第 2 张")
        check(ImageStackLayout.focusedIndex(atX: boundary + 6, count: 3, keeping: 1) == 2, "明显滑过分界后选第 3 张")
        check(ImageStackLayout.focusedIndex(atX: boundary - 2, count: 3, keeping: 2) == 2, "反向抖动不会马上跳回第 2 张")
        check(ImageStackLayout.shouldOpenOnRelease(horizontal: ImageStackLayout.scrubThreshold, vertical: 0), "刚好达到横向阈值就打开")
        check(ImageStackLayout.shouldOpenOnRelease(horizontal: -40, vertical: 3), "反向横滑同样打开")
        check(!ImageStackLayout.shouldOpenOnRelease(horizontal: 4, vertical: 1), "几乎没滑不打开")
        check(!ImageStackLayout.shouldOpenOnRelease(horizontal: 4, vertical: -40), "竖滑不打开")
        check(!ImageStackLayout.shouldOpenOnRelease(horizontal: 16, vertical: 16), "方向不明确不打开")

        for count in [6, 7, 9, 20] {
            let cards = ImageStackLayout.cards(count: count, fanned: true, fansLeft: true)
            let width = ImageStackLayout.stackSize(count: count).width
            for card in cards {
                let x = width / 2 + card.offset.width
                check(x > 0 && x < width, "每张图的中心都在手指可达范围")
                check(ImageStackLayout.focusedIndex(atX: x, count: count, fansLeft: true) == card.index,
                      "左滑可以选中第 \(card.index + 1) / \(count) 张")
            }
            check(ImageStackLayout.focusedIndex(atX: 0, count: count, fansLeft: true) == count - 1, "滑到左边选择最后一张")
        }

        // 看图页页码
        check(ImageViewerIndex.clamp(5, count: 3) == 2 && ImageViewerIndex.clamp(-1, count: 3) == 0 && ImageViewerIndex.clamp(2, count: 0) == 0, "起始页夹在范围内")
        check(!ImageViewerIndex.showsStrip(1) && ImageViewerIndex.showsStrip(2), "两张以上才有缩略图条")

        // 发图压缩
        let big = CGSize(width: 4032, height: 3024)
        check(ImageSendPolicy.targetSize(for: big, keepOriginal: false) == CGSize(width: 1600, height: 1200), "大图压到长边 1600")
        check(ImageSendPolicy.targetSize(for: big, keepOriginal: true) == big, "保留原图不缩")
        check(ImageSendPolicy.targetSize(for: CGSize(width: 800, height: 600), keepOriginal: false) == CGSize(width: 800, height: 600), "小图不放大")
        print("PASS：叠卡张数 / 旋转 / 层级 / 铺开、行高、跟手选择、看图页码 / 缩略图条、发图压缩")
    }
}
