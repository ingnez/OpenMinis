import Foundation

// 头像对比度：深色 / 浅色两种外观下，身体都要和背景分得开，白眼睛也要和身体分得开（WCAG 对比度）
var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudAvatarPaletteTests {
    static func main() {
        let white: CloudAvatarPalette.RGB = (1, 1, 1)
        let darkBGs: [CloudAvatarPalette.RGB] = [(0, 0, 0), (0.11, 0.11, 0.12)]          // 纯黑 / systemBackground(深)·分组
        let lightBGs: [CloudAvatarPalette.RGB] = [(1, 1, 1), (0.95, 0.95, 0.97)]
        for i in 0..<CloudAvatarPalette.count {
            let d = CloudAvatarPalette.rgb(i, dark: true), l = CloudAvatarPalette.rgb(i, dark: false)
            for bg in darkBGs {
                let c = CloudAvatarPalette.contrast(d, bg)
                check(c >= 3.0, "深色：颜色 \(i) 对背景 \(String(format: "%.2f", c)) ≥ 3")
            }
            for bg in lightBGs {
                let c = CloudAvatarPalette.contrast(l, bg)
                check(c >= 1.9, "浅色：颜色 \(i) 对背景 \(String(format: "%.2f", c)) ≥ 1.9（另有描边）")
            }
            check(CloudAvatarPalette.contrast(d, white) >= 2.0, "深色：颜色 \(i) 上的白眼睛看得见")
            check(CloudAvatarPalette.contrast(l, white) >= 2.0, "浅色：颜色 \(i) 上的白眼睛看得见")
        }
        // 回归：主 Bot 默认黑色在深色模式下不再是黑色（之前只剩一双眼睛）
        let primaryDark = CloudAvatarPalette.rgb(0, dark: true)
        check(CloudAvatarPalette.contrast(primaryDark, (0, 0, 0)) > 3, "主 Bot 黑色头像在深色模式下换成石墨灰")
        check(CloudAvatarPalette.rgb(0, dark: false) == (0, 0, 0), "浅色模式仍是黑色")
        check(CloudAvatarPalette.rgb(99, dark: false) == CloudAvatarPalette.light.last!, "越界取最后一个")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("头像对比度测试全部通过")
    }
}
