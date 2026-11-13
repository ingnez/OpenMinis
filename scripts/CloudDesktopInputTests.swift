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
        check(CloudIMECommit.events(old: z0, new: z0 + "123", composing: false) == [.text("123")], "数字上屏")
        check(CloudIMECommit.events(old: z0, new: z0 + " ", composing: false) == [.text(" ")], "空格上屏")
        check(CloudIMECommit.events(old: z0, new: z0 + "\n", composing: false) == [.text("\n")], "换行上屏")
        check(CloudIMECommit.events(old: z0, new: "", composing: false) == [.backspace(1)], "只剩 sentinel 时退格")
        check(CloudIMECommit.viaServer("你好") && !CloudIMECommit.viaServer("hello 1!") && CloudIMECommit.viaServer("中a1？") && !CloudIMECommit.viaServer(" "), "中文走服务器，ASCII / 空格可直接按键")
        check(!CloudIMECommit.shouldFlushAgain(sent: "a", fieldNow: "a"), "框里没多字就可以清回 sentinel")
        check(CloudIMECommit.shouldFlushAgain(sent: "a", fieldNow: "a1 "), "冲掉 a 时框里已是 a1 ，要再发，不能清掉")
        check(CloudIMECommit.shouldFlushAgain(sent: "云", fieldNow: "云电脑中文输入"), "中文后续字不能被 sentinel 抹掉")

        // 画质：首帧低清，按延迟自适应，抖一下不切
        check(CloudStreamQuality.firstFrame.quality < CloudStreamQuality.high.quality, "首帧更省")
        check(CloudStreamQuality.adaptive(rttMs: 60) == CloudStreamQuality.high && CloudStreamQuality.adaptive(rttMs: 500) == CloudStreamQuality.saver, "按延迟选档")
        let h = CloudStreamQuality.high, sv = CloudStreamQuality.saver
        check(CloudStreamQuality.shouldSwitch(current: h, history: [h, sv]) == nil, "只差一次不切")
        check(CloudStreamQuality.shouldSwitch(current: h, history: [sv, sv]) == sv, "连续两次才切")
        check(CloudDesktopLatency.level(80) == .good && CloudDesktopLatency.level(200) == .fair && CloudDesktopLatency.level(900) == .poor, "延迟颜色")
        check(CloudDesktopLatency.text(85.4) == "85 ms" && CloudDesktopLatency.text(1500) == "1.5 s", "延迟文字")

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
        check(CloudCombo.forGesture(.threeLeft) == .nextTab && CloudCombo.forGesture(.edgeBack).keysyms == [0xffe9, 0xff51], "手势快捷键")
        check(CloudCombo.prevTab.events.count == 6 && CloudCombo.prevTab.events.last! == (0xffe3, false), "上一个标签：按下再反向松开")
        check(CloudLowBandwidth.active(setting: "auto", expensive: true) && !CloudLowBandwidth.active(setting: "auto", expensive: false), "蜂窝自动省流")
        check(CloudLowBandwidth.active(setting: "on", expensive: false) && !CloudLowBandwidth.active(setting: "off", expensive: true), "常开 / 关闭")
        check(CloudLowBandwidth.level(CloudStreamQuality.high, lowBandwidth: true) == CloudStreamQuality.saver && CloudLowBandwidth.level(CloudStreamQuality.high, lowBandwidth: false) == CloudStreamQuality.high, "省流量压到最省画质")
        check(CloudLowBandwidth.bytesText(500) == "500 B" && CloudLowBandwidth.bytesText(2048) == "2 KB" && CloudLowBandwidth.bytesText(3 * 1024 * 1024) == "3.0 MB", "流量文字")
        let pt = CloudPointAndTell.message(point: CGPoint(x: 1500.4, y: 30.6), screen: CGSize(width: 1280, height: 800), instruction: " 点这个按钮 ")
        check(pt.contains("x=1279, y=31") && pt.contains("1280×800") && pt.contains("要求：点这个按钮") && pt.contains("先截图"), "指给 Bot 看：\(pt)")
        check(CloudPointAndTell.message(point: .zero, screen: CGSize(width: 1280, height: 800), instruction: "").contains("看看这里是什么"), "没说要求")
        var mac = CloudMacro()
        mac.add(.click(x: 10, y: 20, right: false, double: false))
        mac.add(.typed(count: 3)); mac.add(.typed(count: 4))
        mac.add(.scroll(down: true)); mac.add(.scroll(down: true))
        mac.add(.combo("复制"))
        check(mac.steps.count == 4 && mac.steps[1] == .typed(count: 7), "宏合并打字与滚动")
        let sk = mac.skill(name: "宏：示例", screen: CGSize(width: 1280, height: 800))
        check(sk.contains("1. 点击 屏幕坐标 (10, 20)") && sk.contains("输入了 7 个字，原文未记录") && sk.contains("4. 按组合键「复制」") && sk.contains("先截图"), "宏技能文本：\(sk)")
        zoomMappingTests()
        typeOrderTests()
        print("CloudDesktopInputTests OK")
    }
}

func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 0.01) -> Bool { abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }

/// 任意放大倍数下：手指点到画面哪里，远端就收到哪个像素；光标画在哪，就是远端光标所在
func zoomMappingTests() {
    let screen = CGSize(width: 1280, height: 800)
    // 竖屏手机：画面按比例居中（上下留黑边），视口 390×700
    let vp = CGSize(width: 390, height: 700)
    let fit = CloudScreenFit(screen: screen, viewport: vp)
    for s: CGFloat in [1, 1.5, 2, 2.5, 3.7, 4] {
        for anchor in [CGPoint(x: 195, y: 350), CGPoint(x: 20, y: 300), CGPoint(x: 380, y: 420)] {
            var z = CloudZoom()
            z.pinch(by: s, around: anchor, viewport: vp)
            let m = CloudViewMapping(fit: fit, zoom: z)
            // 往返一致：远端像素 → 屏幕 → 远端像素
            for p in [CGPoint(x: 0, y: 0), CGPoint(x: 640, y: 400), CGPoint(x: 1279, y: 799), CGPoint(x: 123, y: 456)] {
                check(near(m.toRemote(m.toViewport(p)), p), "放大 \(s) 倍往返一致 \(p)")
            }
            // 屏幕上的点 → 远端：按定义手算
            let v = CGPoint(x: 200, y: 360)
            let content = CGPoint(x: (v.x - z.offset.width) / z.scale, y: (v.y - z.offset.height) / z.scale)
            let want = CGPoint(x: (content.x - fit.origin.x) / fit.ratio, y: (content.y - fit.origin.y) / fit.ratio)
            check(near(m.toRemote(v), want), "放大 \(s) 倍点按映射 \(m.toRemote(v)) vs \(want)")
        }
    }
    // 具体数：390 宽的视口放 1280 宽的画面，ratio = 390/1280；居中时上下黑边 (700 - 800*ratio)/2
    let r: CGFloat = 390.0 / 1280.0
    check(abs(fit.ratio - r) < 0.0001 && abs(fit.origin.y - (700 - 800 * r) / 2) < 0.0001, "按比例居中")
    var z2 = CloudZoom()
    z2.pinch(by: 2, around: CGPoint(x: 195, y: 350), viewport: vp)
    let m2 = CloudViewMapping(fit: fit, zoom: z2)
    // 2 倍时视口中心看到的正是远端中心
    check(near(m2.toRemote(CGPoint(x: 195, y: 350)), CGPoint(x: 640, y: 400), 0.5), "2 倍放大视口中心 = 远端中心：\(m2.toRemote(CGPoint(x: 195, y: 350)))")
    // 2 倍时手指往右挪 10 点 = 远端往右 10 / 2 / ratio 像素
    let a = m2.toRemote(CGPoint(x: 195, y: 350)), b = m2.toRemote(CGPoint(x: 205, y: 350))
    check(abs((b.x - a.x) - 10 / 2 / r) < 0.01, "2 倍时 10 点 = \(b.x - a.x) 像素")

    // noVNC 报的画布矩形（未缩放坐标）：和按比例居中的估算一致时映射也一致
    let canvas = CGRect(x: fit.origin.x, y: fit.origin.y, width: screen.width * fit.ratio, height: screen.height * fit.ratio)
    let mc = CloudViewMapping(canvas: canvas, screen: screen, zoom: z2)
    check(near(mc.toRemote(CGPoint(x: 100, y: 300)), m2.toRemote(CGPoint(x: 100, y: 300))), "画布矩形与估算一致")
    check(abs(mc.pixelsPerPoint - 1 / r) < 0.0001, "未缩放时 1 点 = 1/ratio 像素")

    // 捏合时两指一起挪：手指下的那一点始终在手指下（不碰边界时）
    var z = CloudZoom()
    z.pinch(by: 2, around: CGPoint(x: 195, y: 350), viewport: vp)
    let under = z.toContent(CGPoint(x: 195, y: 350))
    z.pinch(by: 1.2, around: CGPoint(x: 180, y: 340), from: CGPoint(x: 195, y: 350), viewport: vp)
    check(near(z.toContent(CGPoint(x: 180, y: 340)), under, 0.001), "捏合 + 平移：手指下的点跟着手指 \(z.toContent(CGPoint(x: 180, y: 340))) vs \(under)")
    check(abs(z.scale - 2.4) < 0.0001, "倍数累乘")
    // 超出边界时夹住，不露黑边
    z.pinch(by: 1, around: CGPoint(x: 900, y: 900), from: CGPoint(x: 0, y: 0), viewport: vp)
    check(z.offset.width <= 0 && z.offset.height <= 0 && z.offset.width >= vp.width - vp.width * z.scale, "平移夹边界")
    // 缩到 1 以下夹回 1
    z.pinch(by: 0.01, around: .zero, from: .zero, viewport: vp)
    check(z.scale == 1 && z.offset == .zero, "最小 1 倍")

    // 松手吸附、双击放大 / 恢复
    var sn = CloudZoom()
    sn.pinch(by: 1.03, around: CGPoint(x: 100, y: 100), viewport: vp)
    sn.settle()
    check(sn == CloudZoom(), "几乎没放大松手吸回 1 倍")
    var dt = CloudZoom()
    dt.toggle(at: CGPoint(x: 100, y: 200), viewport: vp)
    check(dt.scale == CloudZoom.doubleTapScale && near(dt.toContent(CGPoint(x: 100, y: 200)), CGPoint(x: 100, y: 200)), "双击放大到点的位置")
    dt.toggle(at: CGPoint(x: 300, y: 10), viewport: vp)
    check(dt == CloudZoom(), "再双击恢复原始大小")

    // 光标跟随：放大后光标走到视口边上，画面跟着挪，光标回到可见区域
    var fz = CloudZoom()
    fz.pinch(by: 3, around: CGPoint(x: 0, y: 0), viewport: vp)
    let mf = CloudViewMapping(fit: fit, zoom: fz)
    let farCursor = CGPoint(x: 1200, y: 700)
    _ = fz.follow(mf.toView(farCursor), viewport: vp)
    let shown = CloudViewMapping(fit: fit, zoom: fz).toViewport(farCursor)
    check(shown.x >= 0 && shown.x <= vp.width && shown.y >= 0 && shown.y <= vp.height, "光标跟随后在视口里：\(shown)")
}

/// 输入法的发送顺序：服务器有字在路上时，后面的 ASCII 和退格也排进服务器
func typeOrderTests() {
    var o = CloudTypeOrder()
    check(o.route(.text("abc")) == .server && o.route(.backspace(1)) == .server, "VNC 未确认：ASCII / 退格走服务器")
    check(o.route(.text(" ")) == .server && o.route(.text("\n")) == .server && o.route(.text("123")) == .server, "VNC 未确认：空格、换行、数字走服务器")
    check(o.route(.text("abc"), vncConfirmed: true) == .vnc && o.route(.backspace(1), vncConfirmed: true) == .vnc, "VNC 可用时 ASCII / 退格走 VNC")
    check(o.route(.text("中")) == .server && o.route(.text("a中"), vncConfirmed: true) == .server, "含中文走服务器")
    o.sent()
    check(o.route(.text("a"), vncConfirmed: true) == .server && o.route(.backspace(2), vncConfirmed: true) == .server, "中文还在路上：ASCII、退格也排队")
    o.sent(); o.finished()
    check(o.route(.text("a"), vncConfirmed: true) == .server, "还有一个在路上")
    o.finished(); o.finished()
    check(o.inFlight == 0 && o.route(.text("a"), vncConfirmed: true) == .vnc, "都送完回到 VNC，计数不会变负")
    let p1 = CloudTypeOrder.serverPayload(.text("中文"))
    check(p1["action"] as? String == "type" && p1["text"] as? String == "中文", "文字请求")
    let p2 = CloudTypeOrder.serverPayload(.backspace(80))
    check(p2["action"] as? String == "key" && p2["key"] as? String == "BackSpace" && p2["repeat"] as? Int == 50, "退格连按最多 50")
    check(CloudTypeOrder.serverPayload(.backspace(0))["repeat"] as? Int == 1, "至少 1 次")
    let nl = CloudTypeOrder.serverPayload(.text("\n"))
    check(nl["action"] as? String == "key" && nl["key"] as? String == "Return", "换行映射为 Return")
    let mixed = CloudTypeOrder.serverPayloads(.text("ab 1\n中a1？"))
    check(mixed.count == 3 && mixed[0]["text"] as? String == "ab 1" && mixed[1]["key"] as? String == "Return" && mixed[2]["text"] as? String == "中a1？", "混合文字按换行拆成 type / Return")
    let crlf = CloudTypeOrder.serverPayloads(.text("a\r\nb"))
    check(crlf.count == 3 && crlf[1]["key"] as? String == "Return" && crlf[2]["text"] as? String == "b", "CRLF 只发一次 Return")
    // 输入法上屏事件
    check(CloudIMECommit.events(old: CloudIMECommit.sentinel, new: CloudIMECommit.sentinel + "你好", composing: false) == [.text("你好")], "上屏中文")
    check(CloudIMECommit.events(old: CloudIMECommit.sentinel, new: CloudIMECommit.sentinel + "ni", composing: true).isEmpty, "拼音组字中不发")
    check(CloudIMECommit.events(old: CloudIMECommit.sentinel, new: "", composing: false) == [.backspace(1)], "空框退格")
    check(CloudIMECommit.events(old: CloudIMECommit.sentinel, new: CloudIMECommit.sentinel + "7", composing: false) == [.text("7")], "数字")
    check(CloudIMECommit.events(old: CloudIMECommit.sentinel, new: CloudIMECommit.sentinel + " ", composing: false) == [.text(" ")], "空格")
    check(CloudIMECommit.events(old: CloudIMECommit.sentinel, new: CloudIMECommit.sentinel + "\n", composing: false) == [.text("\n")], "换行")
    check(CloudIMECommit.shouldFlushAgain(sent: "a", fieldNow: "a1 "), "打字撞上清 sentinel 时要再冲")
        // XCUITest 合成捏合：0 触点仍要缩放；结束时若 scale 还在就补一次
        check(!CloudPinchPolicy.followAnchor(numberOfTouches: 0), "合成捏合 0 触点不跟锚点平移")
        check(!CloudPinchPolicy.followAnchor(numberOfTouches: 1), "单指不跟锚点平移")
        check(CloudPinchPolicy.followAnchor(numberOfTouches: 2), "两指跟锚点平移")
        check(CloudPinchPolicy.shouldFlushScaleOnEnd(2.5), "ended 时还有未消耗的 scale 要补上")
        check(!CloudPinchPolicy.shouldFlushScaleOnEnd(1), "scale 已归 1 不用再补")
    let han = CloudTypeOrder.serverPayload(.text("你好，云电脑"))
    check(han["action"] as? String == "type" && han["text"] as? String == "你好，云电脑", "中文原文进 type，不拆成 Latin-1 键码")
    guard let data = try? JSONSerialization.data(withJSONObject: han, options: []),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        check(false, "中文请求能做 UTF-8 JSON")
        return
    }
    check(obj["text"] as? String == "你好，云电脑", "JSON 编解码后仍是汉字，不是乱码")
    check(CloudKey.keysym(for: "你") == nil && CloudKey.keysym(for: "好") == nil && CloudKey.keysym(for: "，") == nil, "汉字和中文标点没有 Latin-1 keysym")
}

