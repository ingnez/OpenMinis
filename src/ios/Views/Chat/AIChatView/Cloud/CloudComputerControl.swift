//
//  CloudComputerControl.swift
//  Minis - 云电脑接管：触控板 / 直接触控、缩放跟随、按键、输入法、画质与延迟
//

import SwiftUI
import UIKit
import WebKit
import Network

@MainActor
final class CloudDesktopController: ObservableObject {
    enum Mode: String { case trackpad, direct }

    static let modeKey = "OpenMinisDesktopInputMode"

    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: CloudDesktopController.modeKey) ?? "") ?? .trackpad {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if mode == .direct { zoom.reset(); applyView() }
            syncPage()
        }
    }
    /// 你在操作（false = 看 Bot 干活，画面只读）
    @Published var controlling = false {
        didSet {
            // 直接触控时 noVNC 按未缩放的画布算点击位置：看着时放大了、接管时又是直接触控，先恢复原始大小再交给 noVNC
            if controlling && mode == .direct && zoom.isZoomed { zoom.reset(); applyView() }
            syncPage()
        }
    }
    @Published private(set) var trackpad = CloudTrackpad()
    @Published private(set) var zoom = CloudZoom()
    @Published var modifiers = CloudModifiers()
    @Published private(set) var latencyMs: Double?
    @Published private(set) var quality = CloudStreamQuality.firstFrame
    /// nil = 按延迟自动
    @Published var pinnedQuality: CloudStreamQuality.Level? { didSet { if let pinnedQuality { setQuality(pinnedQuality) } } }
    @Published private(set) var recording = false
    @Published private(set) var pointerUnsupported = false
    /// 本次连接收到的画面字节数（页面里统计 WebSocket 消息，真实值）
    @Published private(set) var bytesReceived = 0
    /// 宏录制中（nil = 没在录）
    @Published var macro: CloudMacro?
    /// 「文件」面板（手机 ⇄ 云电脑）
    @Published var showFiles = false
    /// 浏览器快照面板
    @Published var showSnapshots = false
    /// 蜂窝 / 低数据模式（auto 时据此压画质）
    @Published private(set) var expensiveNetwork = false
    var lowBandwidth: Bool {
        CloudLowBandwidth.active(setting: UserDefaults.standard.string(forKey: CloudLowBandwidth.key) ?? "auto", expensive: expensiveNetwork)
    }

    weak var web: WKWebView? { didSet { if let web { directGestures.attach(to: web) } } }
    private(set) lazy var directGestures = CloudDirectGestures(controller: self)
    var viewport: CGSize = .zero
    var onClipboard: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onNetworkChange: (() -> Void)?

    private var canvas: CGRect?
    /// 端到端探针：假画面回报的最后一次指针 / 点击（远端像素）
    @Published private(set) var lastRemotePointer: (x: Int, y: Int, mask: Int) = (-1, -1, 0)
    @Published private(set) var lastRemoteClick: (x: Int, y: Int) = (-1, -1)
    private var typeOrder = CloudTypeOrder()
    /// 输入法默认走服务器，直到确认 VNC sendKey 真的发出去（本页不自动置位）
    private(set) var vncKeysReady = false
    private var buttons = 0
    private var history: [CloudStreamQuality.Level] = []
    private var latencyTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var lastPath: String?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    // MARK: 页面

    func js(_ code: String) { web?.evaluateJavaScript(code, completionHandler: nil) }

    func connected() {
        setQuality(pinnedQuality ?? CloudLowBandwidth.level(CloudStreamQuality.adaptive(rttMs: latencyMs), lowBandwidth: lowBandwidth))
        syncPage()
        js("window.om&&om.fb()")
    }

    private func syncPage() {
        js("window.om&&(om.viewOnly(\(controlling && mode == .direct ? "false" : "true")),om.cursor(\(controlling && mode == .trackpad ? "true" : "false")))")
    }

    func handle(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "fb":
            let w = ev["w"] as? Double ?? 0, h = ev["h"] as? Double ?? 0
            trackpad.resize(CGSize(width: w, height: h))
            canvas = CGRect(x: ev["x"] as? Double ?? 0, y: ev["y"] as? Double ?? 0, width: ev["cw"] as? Double ?? 0, height: ev["ch"] as? Double ?? 0)
        case "clipboard":
            if let t = ev["text"] as? String, !t.isEmpty { onClipboard?(t) }
        case "nopointer":
            if !pointerUnsupported {
                pointerUnsupported = true
                mode = .direct
                onNotice?("这台服务器的 noVNC 不支持触控板模式，已换成直接触控")
            }
        case "bytes":
            bytesReceived += ev["n"] as? Int ?? 0
        case "fakeptr":
            // 只有模拟器端到端的假画面会发：远端真正收到的指针（像素、按键掩码）
            lastRemotePointer = (Int(ev["x"] as? Double ?? 0), Int(ev["y"] as? Double ?? 0), ev["mask"] as? Int ?? 0)
            if lastRemotePointer.mask != 0 { lastRemoteClick = (lastRemotePointer.x, lastRemotePointer.y) }
        case "shot":
            saveShot(ev)
        case "rec":
            handleRecording(ev)
        default:
            break
        }
    }

    // MARK: 触控板

    /// 当前的完整映射（画布位置 + 缩放平移）；noVNC 还没报画布时按比例居中估算
    var mapping: CloudViewMapping {
        if let c = canvas, c.width > 0, trackpad.screen.width > 0 {
            return CloudViewMapping(canvas: c, screen: trackpad.screen, zoom: zoom)
        }
        return CloudViewMapping(fit: CloudScreenFit(screen: trackpad.screen, viewport: viewport), zoom: zoom)
    }

    /// 视口里的点 → 远端像素（「指给 Bot 看」用；任何放大倍数下都对）
    func remotePoint(fromView v: CGPoint) -> CGPoint {
        CloudPointAndTell.clamp(mapping.toRemote(v), screen: trackpad.screen)
    }

    /// 光标此刻在视口里的位置（放大平移之后）
    var cursorOnScreen: CGPoint { mapping.toViewport(trackpad.cursor) }

    /// 远端像素 → 视图点（未缩放）
    private func toView(_ p: CGPoint) -> CGPoint { mapping.toView(p) }

    private var pixelsPerPoint: CGFloat { mapping.pixelsPerPoint }

    private func sendPointer() {
        js("window.om&&om.ptr(\(Int(trackpad.cursor.x)),\(Int(trackpad.cursor.y)),\(buttons))")
    }

    func move(by delta: CGSize, speed: CGFloat) {
        guard controlling else { return }
        trackpad.move(by: delta, speed: speed, zoom: zoom.scale, pointsToPixels: pixelsPerPoint)
        sendPointer()
        if zoom.follow(toView(trackpad.cursor), viewport: viewport) { applyView() }
    }

    func click(_ button: Int, double: Bool = false) {
        guard controlling else { return }
        haptic.impactOccurred()
        macro?.add(.click(x: Int(trackpad.cursor.x), y: Int(trackpad.cursor.y), right: button != CloudPointer.left, double: double))
        for _ in 0..<(double ? 2 : 1) {
            buttons |= button; sendPointer()
            buttons &= ~button; sendPointer()
        }
    }

    func drag(_ began: Bool) {
        guard controlling else { return }
        if began { haptic.impactOccurred(intensity: 0.8) }
        buttons = began ? (buttons | CloudPointer.left) : (buttons & ~CloudPointer.left)
        sendPointer()
    }

    private var scroll = CloudScrollAccumulator()
    func scroll(by delta: CGSize) {
        guard controlling else { return }
        let (v, h) = scroll.feed(delta)
        guard v != 0 || h != 0 else { return }
        if v != 0 { macro?.add(.scroll(down: v > 0)) }
        js("window.om&&om.wheel(\(Int(trackpad.cursor.x)),\(Int(trackpad.cursor.y)),\(v),\(h),\(buttons))")
    }

    /// 捏合一帧：缩放 + 两指中心移动带着画面走（放大后两指一边捏一边挪就能平移）。
    /// 接管 + 直接触控时不缩放（noVNC 按未缩放画布算点击位置），由 CloudDirectGestures 先切到触控板
    func pinch(by factor: CGFloat, around anchor: CGPoint, from previous: CGPoint? = nil) {
        guard mode == .trackpad || !controlling else { return }
        zoom.pinch(by: factor, around: anchor, from: previous ?? anchor, viewport: viewport)
        applyView()
    }

    func pinchEnded() {
        let before = zoom
        zoom.settle()
        if zoom != before { applyView() }
    }

    /// 双击（看着时单指双击、接管触控板时双指双击）：放大了就恢复原始大小，没放大就放大到点的位置
    func toggleZoom(at p: CGPoint) {
        guard mode == .trackpad || !controlling else { return }
        zoom.toggle(at: p, viewport: viewport)
        haptic.impactOccurred(intensity: 0.6)
        applyView()
    }

    func pan(by d: CGSize) {
        zoom.pan(by: d, viewport: viewport)
        applyView()
    }

    func resetZoom() {
        guard zoom.isZoomed || zoom.offset != .zero else { return }
        zoom.reset()
        applyView()
    }

    private func applyView() {
        js("window.om&&om.view(\(zoom.scale),\(zoom.offset.width),\(zoom.offset.height))")
    }

    // MARK: 键盘

    func sendKeys(_ events: [(Int, Bool)]) {
        guard controlling, !events.isEmpty else { return }
        js("window.om&&om.keys([" + events.map { "[\($0.0),\($0.1 ? 1 : 0)]" }.joined(separator: ",") + "])")
    }

    func key(_ k: CloudKey) {
        if k.isModifier { modifiers.tap(k); return }
        haptic.impactOccurred(intensity: 0.5)
        macro?.add(.key(k.label))
        sendKeys(modifiers.wrap(k.keysym))
    }

    func combo(_ c: CloudCombo) {
        haptic.impactOccurred(intensity: 0.5)
        macro?.add(.combo(c.label))
        sendKeys(c.events)
    }

    /// 输入法上屏的文字。VNC 按键未确认可用时（触控板模式下 noVNC 常为 viewOnly，真机 sendKey 会丢掉），
    /// ASCII / 空格 / 换行 / 退格也走服务器，顺序仍由 CloudTypeOrder 保证；viaServer 送完必须调 done。
    /// 额外按键行仍走 VNC（om.keys 会临时关掉 viewOnly）。
    func type(_ events: [CloudIMECommit.Event], viaServer: (CloudIMECommit.Event, @escaping () -> Void) -> Void) {
        for e in events {
            if case .text(let t) = e { macro?.add(.typed(count: t.count)) }
            switch typeOrder.route(e, vncConfirmed: vncKeysReady) {
            case .server:
                typeOrder.sent()
                viaServer(e) { [weak self] in self?.typeOrder.finished() }
            case .vnc:
                switch e {
                case .backspace(let n):
                    sendKeys(Array(repeating: [(CloudKey.backspace.keysym, true), (CloudKey.backspace.keysym, false)], count: min(n, 50)).flatMap { $0 })
                case .text(let t):
                    sendKeys(t.compactMap(CloudKey.keysym(for:)).flatMap { modifiers.wrap($0) })
                }
            }
        }
    }

    func pasteToRemoteClipboard(_ text: String) {
        guard let data = try? JSONEncoder().encode(text), let lit = String(data: data, encoding: .utf8) else { return }
        js("window.om&&om.clip(\(lit))")
    }

    // MARK: 画质、延迟、网络

    func setQuality(_ level: CloudStreamQuality.Level) {
        quality = level
        js("window.om&&om.quality(\(level.quality),\(level.compression))")
    }

    func startMonitoring(probe: @escaping () async -> Double?) {
        latencyTask?.cancel()
        latencyTask = Task { [weak self] in
            while !Task.isCancelled {
                let ms = await probe()
                guard let self else { return }
                self.latencyMs = ms
                if self.pinnedQuality == nil {
                    let lvl = CloudLowBandwidth.level(CloudStreamQuality.adaptive(rttMs: ms), lowBandwidth: self.lowBandwidth)
                    self.history = Array((self.history + [lvl]).suffix(4))
                    if let next = CloudStreamQuality.shouldSwitch(current: self.quality, history: self.history) { self.setQuality(next) }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let sig = path.status == .satisfied ? path.availableInterfaces.map(\.name).joined(separator: ",") : "offline"
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPath = sig }
                if self.expensiveNetwork != expensive {
                    self.expensiveNetwork = expensive
                    CloudDataSaver.expensiveNetwork = expensive
                    if self.pinnedQuality == nil, self.lowBandwidth { self.setQuality(CloudStreamQuality.saver) }
                }
                // 只在换网（Wi-Fi ↔ 蜂窝、断网恢复）时立刻重连，第一次回调不算
                if let old = self.lastPath, old != sig, path.status == .satisfied { self.onNetworkChange?() }
            }
        }
        m.start(queue: DispatchQueue(label: "openminis.desktop.path"))
        monitor = m
    }

    func stopMonitoring() {
        latencyTask?.cancel()
        latencyTask = nil
        monitor?.cancel()
        monitor = nil
    }

    // MARK: 截图、录屏

    func screenshot() { js("window.om&&om.shot()") }

    func toggleRecording() { js("window.om&&om.rec(\(recording ? "false" : "true"))") }

    private static func decodeDataURL(_ s: String) -> Data? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(s[s.index(after: comma)...]))
    }

    private func saveShot(_ ev: [String: Any]) {
        guard let s = ev["data"] as? String, let data = Self.decodeDataURL(s), let img = UIImage(data: data) else {
            onNotice?("截图失败")
            return
        }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        onNotice?("截图已存到相册")
    }

    private func handleRecording(_ ev: [String: Any]) {
        if ev["error"] != nil {
            recording = false
            onNotice?("这台设备的网页画面不支持录屏（需要 MediaRecorder）")
            return
        }
        if ev["started"] as? Bool == true { recording = true; onNotice?("开始录屏"); return }
        recording = false
        guard let s = ev["data"] as? String, let data = Self.decodeDataURL(s) else { onNotice?("录屏没有内容"); return }
        let mime = ev["mime"] as? String ?? ""
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-desktop-\(Int(Date().timeIntervalSince1970)).\(mime.contains("webm") ? "webm" : "mp4")")
        do { try data.write(to: url) } catch { onNotice?("录屏保存失败"); return }
        if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) {
            UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
            onNotice?("录屏已存到相册")
        } else {
            onNotice?("录屏格式（\(mime)）相册不支持，已放在临时文件")
        }
    }
}

// MARK: - 触控板手势层

/// 盖在画面上的手势层（触控板模式 + 你在操作时才有）：
/// 单指拖 = 移动光标，点 = 左键，双击 = 双击，双指点 = 右键，双指拖 = 滚动，长按后拖 = 按住左键拖选，捏合 = 缩放，三指拖 = 平移画面
struct CloudTrackpadSurface: UIViewRepresentable {
    let controller: CloudDesktopController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeUIView(context: Context) -> SurfaceView {
        let v = SurfaceView()
        v.backgroundColor = .clear
        v.onLayout = { [weak controller] size in controller?.viewport = size }
        let c = context.coordinator
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let move = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.panView(_:)))
        move.minimumNumberOfTouches = 3
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        let right = UITapGestureRecognizer(target: c, action: #selector(Coordinator.rightTap(_:)))
        right.numberOfTouchesRequired = 2
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.longPress(_:)))
        long.minimumPressDuration = 0.35
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        // 双指双击 = 恢复原始大小（单指双击留给远端的双击）；右键要等它判定失败
        let resetZoom = UITapGestureRecognizer(target: c, action: #selector(Coordinator.twoFingerDoubleTap(_:)))
        resetZoom.numberOfTouchesRequired = 2
        resetZoom.numberOfTapsRequired = 2
        right.require(toFail: resetZoom)
        v.isAccessibilityElement = true
        v.accessibilityIdentifier = "ccTrackpadSurface"
        v.accessibilityLabel = "云电脑触控板"
        for g in [pan, scroll, move, tap, double, right, long, pinch, resetZoom] as [UIGestureRecognizer] {
            g.delegate = c
            v.addGestureRecognizer(g)
        }
        // 手势快捷键：三指快速左 / 右 / 上滑、左边缘右滑（三指拖动画面要等快速滑动判定失败）
        for (dir, sel) in [(UISwipeGestureRecognizer.Direction.left, #selector(Coordinator.swipeLeft)),
                           (.right, #selector(Coordinator.swipeRight)), (.up, #selector(Coordinator.swipeUp))] {
            let sw = UISwipeGestureRecognizer(target: c, action: sel)
            sw.direction = dir
            sw.numberOfTouchesRequired = 3
            v.addGestureRecognizer(sw)
            move.require(toFail: sw)
        }
        let edge = UIScreenEdgePanGestureRecognizer(target: c, action: #selector(Coordinator.edgeBack(_:)))
        edge.edges = .left
        v.addGestureRecognizer(edge)
        pan.require(toFail: edge)
        pan.require(toFail: long)
        return v
    }

    func updateUIView(_ uiView: SurfaceView, context: Context) {}

    final class SurfaceView: UIView {
        var onLayout: ((CGSize) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(bounds.size)
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: CloudDesktopController
        private var lastLong: CGPoint = .zero
        init(_ c: CloudDesktopController) { controller = c }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (other is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
        }

        private func delta(_ g: UIPanGestureRecognizer) -> CGSize {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            return CGSize(width: t.x, height: t.y)
        }

        @objc func swipeLeft() { controller.combo(.forGesture(.threeLeft)) }
        @objc func swipeRight() { controller.combo(.forGesture(.threeRight)) }
        @objc func swipeUp() { controller.combo(.forGesture(.threeUp)) }
        @objc func edgeBack(_ g: UIScreenEdgePanGestureRecognizer) {
            if g.state == .ended { controller.combo(.forGesture(.edgeBack)) }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let v = g.velocity(in: g.view)
            controller.move(by: delta(g), speed: hypot(v.x, v.y))
        }

        /// 捏合进行中双指的移动属于平移画面，不能再当滚轮发给远端（以前一边捏一边把远端页面滚走）
        @objc func scroll(_ g: UIPanGestureRecognizer) {
            let d = delta(g)
            guard pinchAnchor == nil else { return }
            controller.scroll(by: d)
        }
        @objc func panView(_ g: UIPanGestureRecognizer) { controller.pan(by: delta(g)) }
        @objc func tap(_ g: UITapGestureRecognizer) { controller.click(CloudPointer.left) }
        @objc func doubleTap(_ g: UITapGestureRecognizer) { controller.click(CloudPointer.left, double: true) }
        @objc func rightTap(_ g: UITapGestureRecognizer) { controller.click(CloudPointer.right) }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: g.view)
            switch g.state {
            case .began:
                lastLong = p
                controller.drag(true)
            case .changed:
                controller.move(by: CGSize(width: p.x - lastLong.x, height: p.y - lastLong.y), speed: 100)
                lastLong = p
            default:
                controller.drag(false)
            }
        }

        private var pinchAnchor: CGPoint?
        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            pinchAnchor = CloudPinchTracker.handle(g, anchor: pinchAnchor, controller: controller)
        }

        @objc func twoFingerDoubleTap(_ g: UITapGestureRecognizer) {
            controller.toggleZoom(at: g.location(in: g.view))
        }
    }
}

/// 捏合手势的共同处理（触控板层和观看层共用）：两指中心的移动带着画面走；抬起一根手指时中心会跳，只缩放不平移。
/// 不在 began 清掉 scale，并在 ended 补一次：XCUITest 合成捏合常常 numberOfTouches == 0，有时还没有 changed。
@MainActor
enum CloudPinchTracker {
    /// 返回新的锚点（手势结束返回 nil）
    static func handle(_ g: UIPinchGestureRecognizer, anchor: CGPoint?, controller: CloudDesktopController) -> CGPoint? {
        let p = g.location(in: g.view)
        switch g.state {
        case .began:
            return p
        case .changed:
            let follow = CloudPinchPolicy.followAnchor(numberOfTouches: g.numberOfTouches)
            let around = follow ? p : (anchor ?? p)
            let from = follow ? (anchor ?? p) : around
            controller.pinch(by: g.scale, around: around, from: from)
            g.scale = 1
            return follow ? p : (anchor ?? p)
        default:
            if CloudPinchPolicy.shouldFlushScaleOnEnd(g.scale) {
                let around = anchor ?? p
                controller.pinch(by: g.scale, around: around, from: around)
            }
            controller.pinchEnded()
            return nil
        }
    }
}

// MARK: - 看着时的缩放层

/// 看 Bot 干活（没接管）时盖在画面上：捏合缩放（两指挪动平移）、放大后单指拖动平移、双击放大 / 恢复。
/// 画面本来就是只读的，这一层不会把触摸漏给远端
struct CloudZoomSurface: UIViewRepresentable {
    let controller: CloudDesktopController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeUIView(context: Context) -> CloudTrackpadSurface.SurfaceView {
        let v = CloudTrackpadSurface.SurfaceView()
        v.backgroundColor = .clear
        v.onLayout = { [weak controller] size in controller?.viewport = size }
        v.isAccessibilityElement = true
        v.accessibilityIdentifier = "ccZoomSurface"
        v.accessibilityLabel = "云电脑画面（双指缩放，双击放大或恢复）"
        let c = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        for g in [pinch, pan, double] as [UIGestureRecognizer] {
            g.delegate = c
            v.addGestureRecognizer(g)
        }
        return v
    }

    func updateUIView(_ uiView: CloudTrackpadSurface.SurfaceView, context: Context) {}

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: CloudDesktopController
        private var anchor: CGPoint?
        init(_ c: CloudDesktopController) { controller = c }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            // 没放大时单指拖动没有可平移的，让给系统（例如边缘返回）
            if g is UIPanGestureRecognizer { return controller.zoom.isZoomed }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            anchor = CloudPinchTracker.handle(g, anchor: anchor, controller: controller)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            controller.pan(by: CGSize(width: t.x, height: t.y))
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) { controller.toggleZoom(at: g.location(in: g.view)) }
    }
}

// MARK: - 系统键盘（含中文输入法）

/// 隐藏的输入框：弹出 iOS 系统键盘。拼音组字时（markedText）不发，上屏后只发新增的字；空框退格也能收到
struct CloudIMEField: UIViewRepresentable {
    @Binding var focused: Bool
    let onEvents: ([CloudIMECommit.Event]) -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.text = CloudIMECommit.sentinel
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.smartQuotesType = .no
        f.smartDashesType = .no
        f.smartInsertDeleteType = .no
        f.returnKeyType = .default
        f.alpha = 0.02
        f.tintColor = .clear
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return f
    }

    func updateUIView(_ f: UITextField, context: Context) {
        context.coordinator.parent = self
        if focused, !f.isFirstResponder { DispatchQueue.main.async { f.becomeFirstResponder() } }
        if !focused, f.isFirstResponder { DispatchQueue.main.async { f.resignFirstResponder() } }
    }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CloudIMEField
        private var last = CloudIMECommit.sentinel
        init(_ p: CloudIMEField) { parent = p }

        private var flushWork: DispatchWorkItem?

        @objc func changed(_ f: UITextField) {
            // 组字中不发。部分输入法（搜狗九键）会先把 marked 文本当成已上屏再标回组字，
            // 若立刻发送，云电脑上会留下一串「？」「“：」之类的残留。
            flushWork?.cancel()
            guard f.markedTextRange == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.flush(f) }
            flushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        private func flush(_ f: UITextField, depth: Int = 0) {
            guard f.markedTextRange == nil else { return }
            let now = f.text ?? ""
            let events = CloudIMECommit.events(old: last, new: now, composing: false)
            if !events.isEmpty { parent.onEvents(events) }
            last = now
            // 50ms 去抖期间或清空 sentinel 时又打进了新字：再冲一次，别把「a1 」收成只剩「a」
            let latest = f.text ?? ""
            if depth < 8, CloudIMECommit.shouldFlushAgain(sent: now, fieldNow: latest) {
                flush(f, depth: depth + 1)
                return
            }
            f.text = CloudIMECommit.sentinel
            last = CloudIMECommit.sentinel
        }

        func textField(_ f: UITextField, shouldChangeCharactersIn range: NSRange, replacementText text: String) -> Bool {
            if f.markedTextRange != nil { return true }
            // 空框（只剩 sentinel）按退格：有的输入法不会再触发 editingChanged
            if text.isEmpty {
                let current = f.text ?? ""
                let all = (current as NSString)
                if current.isEmpty || current == CloudIMECommit.sentinel || range.length >= all.length {
                    flushWork?.cancel()
                    parent.onEvents([.backspace(1)])
                    f.text = CloudIMECommit.sentinel
                    last = CloudIMECommit.sentinel
                    return false
                }
            }
            return true
        }

        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            flushWork?.cancel()
            parent.onReturn()
            return false
        }

        func textFieldDidEndEditing(_ f: UITextField) {
            DispatchQueue.main.async { if self.parent.focused { self.parent.focused = false } }
        }
    }
}

/// 直接触控模式也能用手势快捷键：三指左 / 右 / 上滑、左边缘右滑。挂在网页视图上，只在「接管 + 直接触控」时生效
/// （触控板模式由 CloudTrackpadSurface 自己处理；没接管时只看不动）。单指点按和拖动照常交给 noVNC。
@MainActor
final class CloudDirectGestures: NSObject, UIGestureRecognizerDelegate {
    weak var controller: CloudDesktopController?
    private static let tag = "om-direct-gesture"

    init(controller: CloudDesktopController) { self.controller = controller }

    func attach(to view: UIView) {
        guard !(view.gestureRecognizers ?? []).contains(where: { $0.name == Self.tag }) else { return }
        for (dir, sel) in [(UISwipeGestureRecognizer.Direction.left, #selector(left)), (.right, #selector(right)), (.up, #selector(up))] {
            let sw = UISwipeGestureRecognizer(target: self, action: sel)
            sw.direction = dir
            sw.numberOfTouchesRequired = 3
            sw.name = Self.tag
            sw.delegate = self
            view.addGestureRecognizer(sw)
        }
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edge(_:)))
        edge.edges = .left
        edge.name = Self.tag
        edge.delegate = self
        view.addGestureRecognizer(edge)
        // 直接触控时 noVNC 按未缩放的画布算点击位置，画面不能就地放大；双指捏合就切到触控板模式接着放大
        // （按钮图标随之变成触控板，点一下可切回），不再毫无反应
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        pinch.name = Self.tag
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
    }

    private var pinchSwitched = false
    private var pinchAnchor: CGPoint?
    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        guard let c = controller else { return }
        switch g.state {
        case .began:
            if c.mode == .direct {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                c.mode = .trackpad
                pinchSwitched = true
                pinchAnchor = g.location(in: g.view)
            }
        case .changed:
            if pinchSwitched {
                let p = g.location(in: g.view)
                if g.numberOfTouches >= 2 { c.pinch(by: g.scale, around: p, from: pinchAnchor ?? p) }
                pinchAnchor = g.numberOfTouches >= 2 ? p : nil
                g.scale = 1
            }
        default:
            if pinchSwitched { c.pinchEnded() }
            pinchSwitched = false
            pinchAnchor = nil
        }
    }

    private var active: Bool { controller.map { $0.controlling && $0.mode == .direct } ?? false }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { active }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func left() { controller?.combo(.forGesture(.threeLeft)) }
    @objc private func right() { controller?.combo(.forGesture(.threeRight)) }
    @objc private func up() { controller?.combo(.forGesture(.threeUp)) }
    @objc private func edge(_ g: UIScreenEdgePanGestureRecognizer) { if g.state == .ended { controller?.combo(.forGesture(.edgeBack)) } }
}
