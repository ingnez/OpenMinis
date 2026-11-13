import Foundation
#if canImport(CoreGraphics)
import CoreGraphics  // macOS 上 CGPoint / CGSize 的 Equatable 在这里（Linux 的 Foundation 自带）
#endif

// 云电脑接管的纯逻辑：触控板、滚动、缩放跟随、按键、输入法上屏、画质、重连、连接计时。
// 只依赖 Foundation：scripts/CloudDesktopInputTests.swift 在 Linux 上直接编译测试。

/// 触控板模式：手指相对移动光标（带加速），坐标是远端屏幕像素
struct CloudTrackpad: Equatable {
    var screen: CGSize
    var cursor: CGPoint

    init(screen: CGSize = CGSize(width: 1280, height: 800)) {
        self.screen = screen
        cursor = CGPoint(x: screen.width / 2, y: screen.height / 2)
    }

    /// 手指移动 delta（屏幕点）→ 光标移动：慢移精确（1.2x），快划加速（最多 3x）；zoom 越大移动越细
    static func gain(speed: CGFloat, zoom: CGFloat) -> CGFloat {
        let base: CGFloat = speed < 200 ? 1.2 : min(3, 1.2 + (speed - 200) / 500)
        return base / max(1, zoom)
    }

    mutating func move(by delta: CGSize, speed: CGFloat, zoom: CGFloat = 1, pointsToPixels: CGFloat = 1) {
        let g = Self.gain(speed: speed, zoom: zoom) * pointsToPixels
        cursor = clamp(CGPoint(x: cursor.x + delta.width * g, y: cursor.y + delta.height * g))
    }

    mutating func place(at p: CGPoint) { cursor = clamp(p) }

    mutating func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != screen else { return }
        let fx = cursor.x / max(1, screen.width), fy = cursor.y / max(1, screen.height)
        screen = size
        cursor = clamp(CGPoint(x: fx * size.width, y: fy * size.height))
    }

    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x.rounded()), max(0, screen.width - 1)), y: min(max(0, p.y.rounded()), max(0, screen.height - 1)))
    }
}

/// RFB 指针按键掩码
enum CloudPointer {
    static let left = 1, middle = 2, right = 4, wheelUp = 8, wheelDown = 16, wheelLeft = 32, wheelRight = 64
}

/// 双指拖动 → 滚轮格数：累积到 step 点才滚一格，方向自然（手指上推 = 内容上移 = 滚轮向下）
struct CloudScrollAccumulator: Equatable {
    static let step: CGFloat = 18
    var pending: CGFloat = 0
    var pendingX: CGFloat = 0

    /// 返回 (竖向格数, 横向格数)；正数 = 向下 / 向右
    mutating func feed(_ delta: CGSize) -> (Int, Int) {
        pending -= delta.height
        pendingX -= delta.width
        let v = Int(pending / Self.step), h = Int(pendingX / Self.step)
        pending -= CGFloat(v) * Self.step
        pendingX -= CGFloat(h) * Self.step
        return (v, h)
    }
}

/// 捏合策略（与 UIKit 手势识别器解耦，方便 Linux 单测）。
/// XCUITest 合成的 pinch 经常 numberOfTouches == 0，且可能只有 began/ended、没有 changed；
/// 不能因此丢掉缩放。真机抬起一根手指时中心会跳，那种情况只缩放、不跟锚点平移。
enum CloudPinchPolicy {
    static func followAnchor(numberOfTouches: Int) -> Bool { numberOfTouches >= 2 }
    static func shouldFlushScaleOnEnd(_ scale: CGFloat) -> Bool { scale != 1 }
}

/// 远端画面的缩放与平移（作用在网页里的画面层上）；放大后光标靠近边缘时自动跟随
struct CloudZoom: Equatable {
    static let minScale: CGFloat = 1, maxScale: CGFloat = 4
    var scale: CGFloat = 1
    /// 画面层平移（视图点）
    var offset: CGSize = .zero

    mutating func pinch(by factor: CGFloat, around anchor: CGPoint, viewport: CGSize) {
        let s = min(Self.maxScale, max(Self.minScale, scale * factor))
        let k = s / scale
        // 保持手指下的那一点不动
        offset = CGSize(width: anchor.x - (anchor.x - offset.width) * k, height: anchor.y - (anchor.y - offset.height) * k)
        scale = s
        clampOffset(viewport)
    }

    mutating func pan(by d: CGSize, viewport: CGSize) {
        offset = CGSize(width: offset.width + d.width, height: offset.height + d.height)
        clampOffset(viewport)
    }

    mutating func reset() { scale = 1; offset = .zero }

    var isZoomed: Bool { scale > 1.01 }

    /// 视口里看到的点（手指位置）→ 未缩放的画面坐标（再交给 CloudScreenFit / 画布换算成远端像素）
    func toContent(_ v: CGPoint) -> CGPoint {
        CGPoint(x: (v.x - offset.width) / max(0.0001, scale), y: (v.y - offset.height) / max(0.0001, scale))
    }

    /// 未缩放的画面坐标 → 视口里实际显示的位置
    func toViewport(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.width, y: p.y * scale + offset.height)
    }

    /// 捏合的一帧：两指中心从 previous 移到 anchor（画面跟着平移），同时以 anchor 为中心缩放 factor 倍。
    /// 不碰边界时，手指下的那一点始终留在手指下；最后统一夹一次边界（先夹再缩会让画面跳一下）
    mutating func pinch(by factor: CGFloat, around anchor: CGPoint, from previous: CGPoint, viewport: CGSize) {
        let s = min(Self.maxScale, max(Self.minScale, scale * factor))
        let k = s / scale
        let ox = offset.width + anchor.x - previous.x, oy = offset.height + anchor.y - previous.y
        offset = CGSize(width: anchor.x - (anchor.x - ox) * k, height: anchor.y - (anchor.y - oy) * k)
        scale = s
        clampOffset(viewport)
    }

    /// 松手：几乎没放大（< 1.05 倍）就吸回原始大小，免得留一个看不出来的 1.02 倍
    mutating func settle() { if scale < 1.05 { reset() } }

    static let doubleTapScale: CGFloat = 2.5

    /// 双击：放大了就恢复原始大小；没放大就以点到的位置为中心放大到 2.5 倍
    mutating func toggle(at p: CGPoint, viewport: CGSize) {
        if isZoomed { reset() } else { pinch(by: Self.doubleTapScale, around: p, viewport: viewport) }
    }

    mutating func clampOffset(_ viewport: CGSize) {
        let minX = viewport.width - viewport.width * scale, minY = viewport.height - viewport.height * scale
        offset = CGSize(width: min(0, max(minX, offset.width)), height: min(0, max(minY, offset.height)))
    }

    /// 光标（视图坐标，未缩放时的位置）离可见区域边缘不到 margin 时平移，让光标留在中间 70%
    mutating func follow(_ p: CGPoint, viewport: CGSize, margin: CGFloat = 0.15) -> Bool {
        guard scale > 1.01 else { return false }
        let v = toViewport(p)
        let sx = v.x, sy = v.y
        let mx = viewport.width * margin, my = viewport.height * margin
        var d = CGSize.zero
        if sx < mx { d.width = mx - sx } else if sx > viewport.width - mx { d.width = viewport.width - mx - sx }
        if sy < my { d.height = my - sy } else if sy > viewport.height - my { d.height = viewport.height - my - sy }
        guard d != .zero else { return false }
        let before = offset
        pan(by: d, viewport: viewport)
        return offset != before
    }
}

/// 画面在视图里按比例居中（letterbox）后的映射：远端像素 ↔ 视图点
struct CloudScreenFit: Equatable {
    var screen: CGSize
    var viewport: CGSize

    var ratio: CGFloat { min(viewport.width / max(1, screen.width), viewport.height / max(1, screen.height)) }
    var origin: CGPoint {
        CGPoint(x: (viewport.width - screen.width * ratio) / 2, y: (viewport.height - screen.height * ratio) / 2)
    }
    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * ratio, y: origin.y + p.y * ratio) }
    /// 视图点（已去掉缩放平移）→ 远端像素
    func toScreen(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - origin.x) / max(0.0001, ratio), y: (v.y - origin.y) / max(0.0001, ratio)) }
}

/// 远端像素 ↔ 视口点的完整映射：画布在视图里的位置和比例（noVNC 报的画布矩形，或按比例居中估算）再叠上缩放平移。
/// 触控板光标、点按、「指给 Bot 看」都走这一条，任何放大倍数下手指点到哪、远端就收到哪
struct CloudViewMapping: Equatable {
    /// 画布左上角（未缩放的视图坐标）
    var origin: CGPoint
    /// 1 个远端像素 = ratio 个视图点（未缩放）
    var ratio: CGFloat
    var zoom: CloudZoom

    init(origin: CGPoint, ratio: CGFloat, zoom: CloudZoom) {
        self.origin = origin
        self.ratio = max(0.0001, ratio)
        self.zoom = zoom
    }

    init(fit: CloudScreenFit, zoom: CloudZoom) { self.init(origin: fit.origin, ratio: fit.ratio, zoom: zoom) }

    /// noVNC 画布矩形（未缩放的视图坐标）+ 远端分辨率
    init(canvas: CGRect, screen: CGSize, zoom: CloudZoom) {
        self.init(origin: canvas.origin, ratio: canvas.width / max(1, screen.width), zoom: zoom)
    }

    /// 远端像素 → 未缩放的视图点
    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * ratio, y: origin.y + p.y * ratio) }
    /// 远端像素 → 视口里实际显示的位置（放大平移之后）
    func toViewport(_ p: CGPoint) -> CGPoint { zoom.toViewport(toView(p)) }
    /// 视口里手指的位置 → 远端像素（未夹边界）
    func toRemote(_ v: CGPoint) -> CGPoint {
        let c = zoom.toContent(v)
        return CGPoint(x: (c.x - origin.x) / ratio, y: (c.y - origin.y) / ratio)
    }
    /// 未缩放时 1 个视图点是几个远端像素（触控板移动用；放大后的细调由 CloudTrackpad.gain 除以 zoom）
    var pixelsPerPoint: CGFloat { 1 / ratio }
}

/// 额外按键行：X11 keysym（noVNC rfb.sendKey 直接发），修饰键可以「按住」
struct CloudKey: Identifiable, Equatable {
    let id: String
    let label: String
    let keysym: Int
    var isModifier = false

    static let esc = CloudKey(id: "esc", label: "Esc", keysym: 0xff1b)
    static let tab = CloudKey(id: "tab", label: "Tab", keysym: 0xff09)
    static let ctrl = CloudKey(id: "ctrl", label: "Ctrl", keysym: 0xffe3, isModifier: true)
    static let alt = CloudKey(id: "alt", label: "Alt", keysym: 0xffe9, isModifier: true)
    static let shift = CloudKey(id: "shift", label: "Shift", keysym: 0xffe1, isModifier: true)
    static let superKey = CloudKey(id: "super", label: "⌘/Win", keysym: 0xffeb, isModifier: true)
    static let left = CloudKey(id: "left", label: "←", keysym: 0xff51)
    static let up = CloudKey(id: "up", label: "↑", keysym: 0xff52)
    static let right = CloudKey(id: "right", label: "→", keysym: 0xff53)
    static let down = CloudKey(id: "down", label: "↓", keysym: 0xff54)
    static let enter = CloudKey(id: "enter", label: "⏎", keysym: 0xff0d)
    static let backspace = CloudKey(id: "bs", label: "⌫", keysym: 0xff08)
    static let delete = CloudKey(id: "del", label: "Del", keysym: 0xffff)
    static let home = CloudKey(id: "home", label: "Home", keysym: 0xff50)
    static let end = CloudKey(id: "end", label: "End", keysym: 0xff57)
    static let pageUp = CloudKey(id: "pgup", label: "PgUp", keysym: 0xff55)
    static let pageDown = CloudKey(id: "pgdn", label: "PgDn", keysym: 0xff56)

    static let row: [CloudKey] = [esc, tab, ctrl, alt, shift, superKey, left, up, down, right, enter, backspace, delete, home, end, pageUp, pageDown]

    /// 可打印 ASCII 字符的 keysym 就是它的码位（X11 Latin-1 区）
    static func keysym(for ch: Character) -> Int? {
        guard let a = ch.asciiValue else { return nil }
        if a == 10 || a == 13 { return enter.keysym }
        if a == 9 { return tab.keysym }
        return (32...126).contains(a) ? Int(a) : nil
    }
}

/// 常用组合键（Linux 桌面上的写法）
struct CloudCombo: Identifiable, Equatable {
    let id: String
    let label: String
    let keysyms: [Int]

    static let copy = CloudCombo(id: "copy", label: "复制", keysyms: [CloudKey.ctrl.keysym, 0x63])
    static let paste = CloudCombo(id: "paste", label: "粘贴", keysyms: [CloudKey.ctrl.keysym, 0x76])
    static let cut = CloudCombo(id: "cut", label: "剪切", keysyms: [CloudKey.ctrl.keysym, 0x78])
    static let selectAll = CloudCombo(id: "all", label: "全选", keysyms: [CloudKey.ctrl.keysym, 0x61])
    static let undo = CloudCombo(id: "undo", label: "撤销", keysyms: [CloudKey.ctrl.keysym, 0x7a])
    static let find = CloudCombo(id: "find", label: "查找", keysyms: [CloudKey.ctrl.keysym, 0x66])
    static let newTab = CloudCombo(id: "tab", label: "新标签", keysyms: [CloudKey.ctrl.keysym, 0x74])
    static let closeTab = CloudCombo(id: "close", label: "关标签", keysyms: [CloudKey.ctrl.keysym, 0x77])
    static let refresh = CloudCombo(id: "f5", label: "刷新", keysyms: [0xffc2])
    static let switchApp = CloudCombo(id: "alttab", label: "切换窗口", keysyms: [CloudKey.alt.keysym, CloudKey.tab.keysym])

    static let all: [CloudCombo] = [copy, paste, cut, selectAll, undo, find, newTab, closeTab, refresh, switchApp]

    // 手势快捷键：三指左右滑 = 下/上一个标签，三指上滑 = 切换窗口，左边缘右滑 = 后退
    static let nextTab = CloudCombo(id: "nexttab", label: "下一个标签", keysyms: [CloudKey.ctrl.keysym, CloudKey.tab.keysym])
    static let prevTab = CloudCombo(id: "prevtab", label: "上一个标签", keysyms: [CloudKey.ctrl.keysym, CloudKey.shift.keysym, CloudKey.tab.keysym])
    static let back = CloudCombo(id: "back", label: "后退", keysyms: [CloudKey.alt.keysym, 0xff51])

    enum Gesture { case threeLeft, threeRight, threeUp, edgeBack }

    static func forGesture(_ g: Gesture) -> CloudCombo {
        switch g {
        case .threeLeft: return nextTab
        case .threeRight: return prevTab
        case .threeUp: return switchApp
        case .edgeBack: return back
        }
    }

    /// 按下顺序 + 反向松开
    var events: [(Int, Bool)] { keysyms.map { ($0, true) } + keysyms.reversed().map { ($0, false) } }
}

/// 粘住的修饰键：点一下 Ctrl 再点 C = Ctrl+C，用完自动松开（长按 = 锁定）
struct CloudModifiers: Equatable {
    var armed: Set<String> = []
    var locked: Set<String> = []

    mutating func tap(_ key: CloudKey) {
        if locked.contains(key.id) { locked.remove(key.id); armed.remove(key.id) }
        else if armed.contains(key.id) { armed.remove(key.id) }
        else { armed.insert(key.id) }
    }

    mutating func lock(_ key: CloudKey) { locked.insert(key.id); armed.insert(key.id) }

    var active: [CloudKey] { CloudKey.row.filter { $0.isModifier && armed.contains($0.id) } }

    /// 一个普通键带上当前修饰键的完整事件序列，发完清掉未锁定的修饰键
    mutating func wrap(_ keysym: Int) -> [(Int, Bool)] {
        let mods = active.map(\.keysym)
        // x11vnc 按 keysym 原样输入：Shift + 小写 b 仍是 b（端到端测试发现），所以 Shift 时换成大写 / 上档符号的 keysym
        let k = mods.contains(CloudKey.shift.keysym) ? Self.shifted(keysym) : keysym
        armed = locked
        return mods.map { ($0, true) } + [(k, true), (k, false)] + mods.reversed().map { ($0, false) }
    }

    /// 美式键盘的上档：a→A，1→!，-→_ …
    static func shifted(_ keysym: Int) -> Int {
        if (0x61...0x7a).contains(keysym) { return keysym - 0x20 }
        let lower = Array("1234567890-=[]\\;',./`"), upper = Array("!@#$%^&*()_+{}|:\"<>?~")
        guard let scalar = Unicode.Scalar(keysym), let i = lower.firstIndex(of: Character(scalar)) else { return keysym }
        return Int(upper[i].asciiValue ?? UInt8(keysym))
    }
}

/// 系统键盘（含中文输入法）上屏处理：组字中（有 markedText）不发；上屏后只发新增的字，删除发退格
enum CloudIMECommit {
    enum Event: Equatable { case text(String), backspace(Int) }

    /// sentinel：输入框里永远留一个零宽字符，这样空框里按退格也能收到删除
    static let sentinel = "\u{200B}"

    static func events(old: String, new: String, composing: Bool) -> [Event] {
        guard !composing, old != new else { return [] }
        let o = Array(old), n = Array(new)
        var i = 0
        while i < o.count, i < n.count, o[i] == n[i] { i += 1 }
        var out: [Event] = []
        let removed = o.count - i
        if removed > 0 { out.append(.backspace(removed)) }
        let added = String(n[i...]).replacingOccurrences(of: sentinel, with: "")
        if !added.isEmpty { out.append(.text(added)) }
        return out
    }

    /// 含中文、全角标点等（没有 X11 Latin-1 keysym）必须走服务器；纯 ASCII 在 VNC 可用时才能直接按键
    static func viaServer(_ text: String) -> Bool { text.contains { CloudKey.keysym(for: $0) == nil } }

    /// 已经按 `sent` 发出去之后：输入框若又多了字（打字/上屏和清回 sentinel 撞车），
    /// 不要用 sentinel 把新字抹掉，应带着 `sent` 再冲一次。
    static func shouldFlushAgain(sent: String, fieldNow: String) -> Bool { fieldNow != sent }
}

/// 输入法上屏的发送顺序：中文等走服务器（HTTP 剪贴板粘贴 / 逐字）。
/// ASCII、空格、换行、退格本来走 VNC（几乎零延迟），但触控板模式会把 noVNC 设成 viewOnly，
/// 真机上 rfb.sendKey 常常根本没发出去。VNC 按键未经确认可用时，这些键也改走服务器；
/// 服务器那边还有没送完的字时，后面的字和退格也排进同一队列，否则「中a」会变成「a中」。
struct CloudTypeOrder: Equatable {
    enum Route: Equatable { case vnc, server }
    private(set) var inFlight = 0

    func route(_ e: CloudIMECommit.Event, vncConfirmed: Bool = false) -> Route {
        if inFlight > 0 { return .server }
        if !vncConfirmed { return .server }
        if case .text(let t) = e, CloudIMECommit.viaServer(t) { return .server }
        return .vnc
    }

    mutating func sent() { inFlight += 1 }
    mutating func finished() { inFlight = max(0, inFlight - 1) }

    /// 走服务器时的请求体：文字用 type（UTF-8 粘贴 / 逐字），退格用 BackSpace，换行映射为 Return
    static func serverPayload(_ e: CloudIMECommit.Event) -> [String: Any] {
        serverPayloads(e).first ?? ["action": "type", "text": ""]
    }

    static func serverPayloads(_ e: CloudIMECommit.Event) -> [[String: Any]] {
        switch e {
        case .backspace(let n):
            return [["action": "key", "key": "BackSpace", "repeat": min(max(1, n), 50)]]
        case .text(let raw):
            var out: [[String: Any]] = []
            var buf = ""
            var skipNL = false
            func flush() {
                if !buf.isEmpty { out.append(["action": "type", "text": buf]); buf = "" }
            }
            // 按 Unicode scalar 走：CRLF 在 Swift 里是一个 Character，和 "\r" / "\n" 比较对不上
            var n = 0
            for scalar in raw.unicodeScalars {
                n += 1
                if n > 10000 { break }
                if skipNL { skipNL = false; if scalar == "\n" { continue } }
                if scalar == "\r" || scalar == "\n" {
                    flush()
                    out.append(["action": "key", "key": "Return"])
                    skipNL = scalar == "\r"
                } else {
                    buf.unicodeScalars.append(scalar)
                }
            }
            flush()
            return out
        }
    }
}

/// 画质：先低清快速出第一帧，连上后升级；之后按往返延迟自适应
enum CloudStreamQuality {
    struct Level: Equatable { let quality: Int; let compression: Int; let label: String }

    static let firstFrame = Level(quality: 2, compression: 9, label: "快速")
    static let high = Level(quality: 7, compression: 4, label: "高清")
    static let balanced = Level(quality: 5, compression: 6, label: "均衡")
    static let saver = Level(quality: 3, compression: 9, label: "省流")

    static func adaptive(rttMs: Double?) -> Level {
        guard let rtt = rttMs else { return balanced }
        if rtt < 120 { return high }
        if rtt < 300 { return balanced }
        return saver
    }

    /// 只有档位真的变了、且新档位连续出现 2 次才切换，避免一抖就来回切
    static func shouldSwitch(current: Level, history: [Level]) -> Level? {
        guard let last = history.last, last != current, history.suffix(2).allSatisfy({ $0 == last }), history.count >= 2 else { return nil }
        return last
    }
}

/// 延迟指示：绿 / 黄 / 红
enum CloudDesktopLatency {
    enum Level: Equatable { case good, fair, poor }
    static func level(_ ms: Double) -> Level { ms < 120 ? .good : (ms < 300 ? .fair : .poor) }
    static func text(_ ms: Double) -> String { ms >= 1000 ? String(format: "%.1f s", ms / 1000) : "\(Int(ms.rounded())) ms" }
}

/// 断线重连节奏：网络切换立刻重连，其余指数退避（上限 8 秒）
enum CloudReconnect {
    static func delay(attempt: Int, networkChanged: Bool) -> Double {
        if networkChanged { return 0 }
        return min(8, 0.3 * pow(2, Double(max(0, attempt))))
    }
}

/// 一次连接的真实计时（App 里显示，也存最近 10 次给你看）
struct CloudConnectTimeline: Equatable, Codable {
    var start: Date
    var checked: Date?
    var loaded: Date?
    var connected: Date?
    var reused = false

    static let key = "OpenMinisDesktopConnectTimes"

    func ms(_ a: Date?, _ b: Date?) -> Int? {
        guard let a, let b else { return nil }
        return max(0, Int((b.timeIntervalSince(a) * 1000).rounded()))
    }

    var totalMs: Int? { ms(start, connected) }

    var summary: String {
        guard let total = totalMs else { return "连接中…" }
        if reused { return "复用已连接的画面 · \(total) ms" }
        var parts: [String] = []
        if let v = ms(start, checked) { parts.append("检测 \(v)") }
        if let v = ms(checked, loaded) { parts.append("页面 \(v)") }
        if let v = ms(loaded ?? checked, connected) { parts.append("画面 \(v)") }
        return "连接 \(total) ms" + (parts.isEmpty ? "" : "（" + parts.joined(separator: " · ") + "）")
    }

    static func record(_ t: CloudConnectTimeline, defaults: UserDefaults = .standard) {
        guard t.totalMs != nil else { return }
        var list = recent(defaults)
        list.insert(t, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(10))) { defaults.set(data, forKey: key) }
    }

    static func recent(_ defaults: UserDefaults = .standard) -> [CloudConnectTimeline] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CloudConnectTimeline].self, from: data)) ?? []
    }
}

/// 接管租约：服务器 45 秒过期，手机每 15 秒续一次
enum CloudControlLease {
    static let heartbeat: Double = 15
    static let serverLease: Double = 45
}

/// 预热 / 复用：桌面体检结果和已连上的画面保留一段时间，再打开就不用从头连
enum CloudDesktopReuse {
    static let checkTTL: Double = 60
    static let parkSeconds: Double = 60

    static func fresh(_ at: Date?, now: Date = Date(), ttl: Double = checkTTL) -> Bool {
        guard let at else { return false }
        let age = now.timeIntervalSince(at)
        return age >= 0 && age < ttl
    }
}

/// 省流量模式：蜂窝 / 低数据模式下自动用最省画质（auto），或常开 / 关闭；外加本次连接的真实流量计数（页面里统计 WebSocket 收到的字节）
enum CloudLowBandwidth {
    static let key = "OpenMinisDesktopLowData"   // auto / on / off

    static func active(setting: String, expensive: Bool) -> Bool {
        switch setting {
        case "on": return true
        case "off": return false
        default: return expensive
        }
    }

    static func level(_ adaptive: CloudStreamQuality.Level, lowBandwidth: Bool) -> CloudStreamQuality.Level {
        lowBandwidth ? CloudStreamQuality.saver : adaptive
    }

    static func shouldDefer(bytes: Int, setting: String, expensive: Bool, threshold: Int = 512 * 1024) -> Bool {
        bytes >= threshold && active(setting: setting, expensive: expensive)
    }

    static func bytesText(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }
}

/// 「指给 Bot 看」：看 Bot 干活时点一下屏幕某处，再说 / 打一句要求，Bot 收到坐标（远端像素）和要求，先截图再操作
enum CloudPointAndTell {
    static func clamp(_ p: CGPoint, screen: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, p.x), max(0, screen.width - 1)).rounded(), y: min(max(0, p.y), max(0, screen.height - 1)).rounded())
    }

    static func message(point: CGPoint, screen: CGSize, instruction: String) -> String {
        let p = clamp(point, screen: screen)
        let ask = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[指给你看] 我在云电脑屏幕上点了这个位置：x=\(Int(p.x)), y=\(Int(p.y))（屏幕 \(Int(screen.width))×\(Int(screen.height)) 像素）。"
            + (ask.isEmpty ? "看看这里是什么。" : "要求：\(ask)")
            + "\n请先截图确认这个位置是什么，再按要求操作。"
    }
}

/// 宏录制：接管时（触控板模式）记下点击位置、按键、组合键、输入了几个字，存成 Bot 可照做的技能。
/// 输入的文字默认不记原文（可能是密码），只记「这里输入了 N 个字」，回放时 Bot 按任务自己填。
struct CloudMacro: Equatable {
    enum Step: Equatable {
        case click(x: Int, y: Int, right: Bool, double: Bool)
        case typed(count: Int)
        case key(String)
        case combo(String)
        case scroll(down: Bool)
    }

    private(set) var steps: [Step] = []
    static let maxSteps = 200

    mutating func add(_ s: Step) {
        guard steps.count < Self.maxSteps else { return }
        // 连续打字合并成一步；连续同向滚动合并
        if case .typed(let n) = s, case .typed(let m)? = steps.last { steps[steps.count - 1] = .typed(count: m + n); return }
        if case .scroll(let d) = s, case .scroll(let e)? = steps.last, d == e { return }
        steps.append(s)
    }

    static func line(_ s: Step) -> String {
        switch s {
        case let .click(x, y, right, double): return "\(double ? "双击" : (right ? "右键点击" : "点击")) 屏幕坐标 (\(x), \(y))"
        case .typed(let n): return "在当前输入框输入文字（录制时输入了 \(n) 个字，原文未记录，按任务需要填写）"
        case .key(let k): return "按 \(k) 键"
        case .combo(let c): return "按组合键「\(c)」"
        case .scroll(let down): return down ? "向下滚动" : "向上滚动"
        }
    }

    func skill(name: String, screen: CGSize) -> String {
        var out = "# \(name)\n\n录制的云电脑操作（屏幕 \(Int(screen.width))×\(Int(screen.height))）。照做时每一步前先截图确认画面和录制时一致，不一致就停下说明。\n\n"
        for (i, s) in steps.enumerated() { out += "\(i + 1). \(Self.line(s))\n" }
        return out
    }
}
