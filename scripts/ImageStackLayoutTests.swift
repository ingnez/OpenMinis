import Foundation

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
        check(fan.count == ImageStackLayout.maxFanned, "铺开最多 5 张")
        let xs = fan.sorted { $0.index < $1.index }.map(\.offset.width)
        check(zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 }, "铺开后从左到右是第 1…5 张")
        check(abs(xs.first! + xs.last!) < 0.001, "铺开左右对称")
        check(ImageStackLayout.cards(count: 1, fanned: true).count == 1, "一张不铺开")

        // 尺寸和行高（估算行高读的就是这个）
        check(ImageStackLayout.height(count: 0) == 0, "没图高度 0")
        check(ImageStackLayout.height(count: 1) == ImageStackLayout.singleSize.height, "一张只有卡高")
        let h3 = ImageStackLayout.height(count: 3)
        check(h3 == ImageStackLayout.cardSize.height + 2 * ImageStackLayout.stackInset.height + ImageStackLayout.captionSpacing + ImageStackLayout.captionHeight, "多张 = 卡 + 余量 + 说明")
        check(ImageStackLayout.height(count: 2) == ImageStackLayout.height(count: 20), "张数多高度不变")
        check(ImageStackLayout.stackSize(count: 4).width >= ImageStackLayout.cardSize.width + 28, "旋转余量算进宽度")

        // 看图页页码
        check(ImageViewerIndex.clamp(5, count: 3) == 2 && ImageViewerIndex.clamp(-1, count: 3) == 0 && ImageViewerIndex.clamp(2, count: 0) == 0, "起始页夹在范围内")
        check(!ImageViewerIndex.showsStrip(1) && ImageViewerIndex.showsStrip(2), "两张以上才有缩略图条")

        // 发图压缩
        let big = CGSize(width: 4032, height: 3024)
        check(ImageSendPolicy.targetSize(for: big, keepOriginal: false) == CGSize(width: 1600, height: 1200), "大图压到长边 1600")
        check(ImageSendPolicy.targetSize(for: big, keepOriginal: true) == big, "保留原图不缩")
        check(ImageSendPolicy.targetSize(for: CGSize(width: 800, height: 600), keepOriginal: false) == CGSize(width: 800, height: 600), "小图不放大")
        print("PASS：叠卡张数 / 旋转 / 层级 / 铺开、行高、看图页码 / 缩略图条、发图压缩")
    }
}
