import Foundation
#if canImport(CoreGraphics)
import CoreGraphics  // macOS 上 CGPoint / CGSize 的 Equatable 在这里（Linux 的 Foundation 自带）
#endif

// 云电脑接管的纯逻辑（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudDesktopInputTests {
    static func main() {
        // 触控板：慢移 1.2 倍，快划加速，越放大越细；不出屏幕
        var t = CloudTrackpad()
        check(t.cursor == CGPoint(x: 640, y: 400), "光标从屏幕中间开始")
        t.move(by: CGSize(width: 10, height: 0), speed: 50)
        check(t.cursor.x == 652, "慢移 1.2x")
        check(CloudTrackpad.gain(speed: 1200, zoom: 1) == 3, "快划最多 3x")
        check(CloudTrackpad.gain(speed: 50, zoom: 2) == 0.6, "放大 2 倍时更细")
        t.move(by: CGSize(width: -5000, height: 9000), speed: 2000)
        check(t.cursor == CGPoint(x: 0, y: 799), "夹在屏幕内")
        t.resize(CGSize(width: 1920, height: 1080))
        check(t.cursor.y == 1079 && t.screen.width == 1920, "换分辨率按比例保持位置")

        // 双指滚动：累积到一格才滚，手指上推 = 向下滚
        var s = CloudScrollAccumulator()
        check(s.feed(CGSize(width: 0, height: -10)) == (0, 0), "不到一格不滚")
        check(s.feed(CGSize(width: 0, height: -10)) == (1, 0), "累积 20 点滚 1 格向下")
        check(s.feed(CGSize(width: 0, height: 40)) == (-2, 0), "下拉向上滚")
        check(s.feed(CGSize(width: -40, height: 0)).1 == 2, "横向")

        // 缩放：手指下的点不动；不超出边界；光标靠边自动跟随
        let vp = CGSize(width: 400, height: 250)
        var z = CloudZoom()
        z.pinch(by: 2, around: CGPoint(x: 200, y: 125), viewport: vp)
        check(z.scale == 2 && z.offset == CGSize(width: -200, height: -125), "围绕中心放大")
        z.pinch(by: 10, around: .zero, viewport: vp)
        check(z.scale == CloudZoom.maxScale, "最大 4 倍")
        z.pan(by: CGSize(width: 9999, height: 9999), viewport: vp)
        check(z.offset == .zero, "平移不露出黑边")
        var f = CloudZoom()
        f.pinch(by: 2, around: .zero, viewport: vp)
        check(f.follow(CGPoint(x: 195, y: 10), viewport: vp), "光标到右边缘时跟随")
        check(195 * 2 + f.offset.width <= 400 * 0.85 + 0.001, "跟随后光标回到可见区域内侧")
        var one = CloudZoom()
        check(!one.follow(CGPoint(x: 399, y: 1), viewport: vp), "没放大不跟随")

        // letterbox 映射
        let fit = CloudScreenFit(screen: CGSize(width: 1280, height: 800), viewport: CGSize(width: 390, height: 600))
        let v = fit.toView(CGPoint(x: 640, y: 400))
        check(abs(v.x - 195) < 0.01 && abs(v.y - 300) < 0.01, "中心对中心")
        let back = fit.toScreen(v)
        check(abs(back.x - 640) < 0.01 && abs(back.y - 400) < 0.01, "来回映射一致")

        // 按键与组合键
        check(CloudKey.keysym(for: "a") == 0x61 && CloudKey.keysym(for: "\n") == 0xff0d && CloudKey.keysym(for: "中") == nil, "ASCII keysym")
        check(CloudCombo.copy.events.map { $0.1 } == [true, true, false, false] && CloudCombo.copy.events.last!.0 == 0xffe3, "组合键先按后反向松开")
        var m = CloudModifiers()
        m.tap(.ctrl)
        let seq = m.wrap(0x63)
        check(seq.map { $0.0 } == [0xffe3, 0x63, 0x63, 0xffe3], "Ctrl 粘住后 + C")
        check(m.active.isEmpty, "用完自动松开")
        m.lock(.shift)
        check(m.wrap(0x61).map { $0.0 } == [0xffe1, 0x41, 0x41, 0xffe1], "Shift + a 发大写 A 的 keysym（x11vnc 不会自己转）")
        check(CloudModifiers.shifted(0x31) == 0x21 && CloudModifiers.shifted(0x2f) == 0x3f && CloudModifiers.shifted(0x5c) == 0x7c && CloudModifiers.shifted(0xff0d) == 0xff0d, "上档符号")
        check(m.active.map(\.id) == ["shift"], "锁定的不松开")
        m.tap(.shift)
        check(m.active.isEmpty, "再点解锁")

        // 输入法：组字中不发，上屏只发新增文字；删除发退格；中文走服务器
        let z0 = CloudIMECommit.sentinel
        check(CloudIMECommit.events(old: z0, new: z0 + "ni", composing: true).isEmpty, "拼音组字中不发")
        check(CloudIMECommit.events(old: z0, new: z0 + "你好", composing: false) == [.text("你好")], "上屏发汉字")
        check(CloudIMECommit.events(old: z0, new: "", composing: false) == [.backspace(1)], "空框退格")
        check(CloudIMECommit.events(old: z0 + "ab", new: z0 + "ac", composing: false) == [.backspace(1), .text("c")], "自动更正替换")
        check(CloudIMECommit.viaServer("你好") && !CloudIMECommit.viaServer("hello 1!"), "中文走服务器，ASCII 直接按键")

        // 画质：首帧低清，按延迟自适应，抖一下不切
        check(CloudStreamQuality.firstFrame.quality < CloudStreamQuality.high.quality, "首帧更省")
        check(CloudStreamQuality.adaptive(rttMs: 60) == CloudStreamQuality.high && CloudStreamQuality.adaptive(rttMs: 500) == CloudStreamQuality.saver, "按延迟选档")
        let h = CloudStreamQuality.high, sv = CloudStreamQuality.saver
        check(CloudStreamQuality.shouldSwitch(current: h, history: [h, sv]) == nil, "只差一次不切")
        check(CloudStreamQuality.shouldSwitch(current: h, history: [sv, sv]) == sv, "连续两次才切")
        check(CloudLatency.level(80) == .good && CloudLatency.level(200) == .fair && CloudLatency.level(900) == .poor, "延迟颜色")
        check(CloudLatency.text(85.4) == "85 ms" && CloudLatency.text(1500) == "1.5 s", "延迟文字")

        // 重连
        check(CloudReconnect.delay(attempt: 5, networkChanged: true) == 0, "网络切换立刻重连")
        check(CloudReconnect.delay(attempt: 0, networkChanged: false) == 0.3 && CloudReconnect.delay(attempt: 10, networkChanged: false) == 8, "退避上限 8 秒")

        // 连接计时（假时间）
        let t0 = Date(timeIntervalSince1970: 1_000)
        var tl = CloudConnectTimeline(start: t0)
        check(tl.summary == "连接中…", "未完成")
        tl.checked = t0.addingTimeInterval(0.12); tl.loaded = t0.addingTimeInterval(0.42); tl.connected = t0.addingTimeInterval(0.9)
        check(tl.totalMs == 900 && tl.summary == "连接 900 ms（检测 120 · 页面 300 · 画面 480）", "分段计时: \(tl.summary)")
        let d = UserDefaults(suiteName: "desk-test-\(UUID().uuidString)")!
        for _ in 0..<12 { CloudConnectTimeline.record(tl, defaults: d) }
        check(CloudConnectTimeline.recent(d).count == 10, "只留最近 10 次")
        var reused = CloudConnectTimeline(start: t0); reused.reused = true; reused.connected = t0.addingTimeInterval(0.03)
        check(reused.summary == "复用已连接的画面 · 30 ms", "复用")
        check(CloudDesktopReuse.fresh(t0, now: t0.addingTimeInterval(30)) && !CloudDesktopReuse.fresh(t0, now: t0.addingTimeInterval(61)) && !CloudDesktopReuse.fresh(nil), "体检结果 60 秒内复用")
        check(CloudControlLease.heartbeat * 3 == CloudControlLease.serverLease, "续租间隔是租期的 1/3")
        print("CloudDesktopInputTests OK")
    }
}
