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
    @Published var controlling = false { didSet { syncPage() } }
    @Published private(set) var trackpad = CloudTrackpad()
    @Published private(set) var zoom = CloudZoom()
    @Published var modifiers = CloudModifiers()
    @Published private(set) var latencyMs: Double?
    @Published private(set) var quality = CloudStreamQuality.firstFrame
    /// nil = 按延迟自动
    @Published var pinnedQuality: CloudStreamQuality.Level? { didSet { if let pinnedQuality { setQuality(pinnedQuality) } } }
    @Published private(set) var recording = false
    @Published private(set) var pointerUnsupported = false

    weak var web: WKWebView?
    var viewport: CGSize = .zero
    var onClipboard: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onNetworkChange: (() -> Void)?

    private var canvas: CGRect?
    private var buttons = 0
    private var history: [CloudStreamQuality.Level] = []
    private var latencyTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var lastPath: String?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    // MARK: 页面

    func js(_ code: String) { web?.evaluateJavaScript(code, completionHandler: nil) }

    func connected() {
        setQuality(pinnedQuality ?? CloudStreamQuality.adaptive(rttMs: latencyMs))
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
        case "shot":
            saveShot(ev)
        case "rec":
            handleRecording(ev)
        default:
            break
        }
    }

    // MARK: 触控板

    /// 远端像素 → 视图点（未缩放）
    private func toView(_ p: CGPoint) -> CGPoint {
        if let c = canvas, c.width > 0, trackpad.screen.width > 0 {
            let k = c.width / trackpad.screen.width
            return CGPoint(x: c.minX + p.x * k, y: c.minY + p.y * k)
        }
        return CloudScreenFit(screen: trackpad.screen, viewport: viewport).toView(p)
    }

    private var pixelsPerPoint: CGFloat {
        if let c = canvas, c.width > 0 { return trackpad.screen.width / c.width }
        return 1 / max(0.0001, CloudScreenFit(screen: trackpad.screen, viewport: viewport).ratio)
    }

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
        js("window.om&&om.wheel(\(Int(trackpad.cursor.x)),\(Int(trackpad.cursor.y)),\(v),\(h),\(buttons))")
    }

    func pinch(by factor: CGFloat, around anchor: CGPoint) {
        guard mode == .trackpad else { return }
        zoom.pinch(by: factor, around: anchor, viewport: viewport)
        applyView()
    }

    func pan(by d: CGSize) {
        zoom.pan(by: d, viewport: viewport)
        applyView()
    }

    func resetZoom() { zoom.reset(); applyView() }

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
        sendKeys(modifiers.wrap(k.keysym))
    }

    func combo(_ c: CloudCombo) {
        haptic.impactOccurred(intensity: 0.5)
        sendKeys(c.events)
    }

    /// 输入法上屏的文字：ASCII 直接按键（带上粘住的修饰键），中文等交给服务器剪贴板粘贴
    func type(_ events: [CloudIMECommit.Event], viaServer: (String) -> Void) {
        for e in events {
            switch e {
            case .backspace(let n):
                sendKeys(Array(repeating: [(CloudKey.backspace.keysym, true), (CloudKey.backspace.keysym, false)], count: min(n, 50)).flatMap { $0 })
            case .text(let t):
                if CloudIMECommit.viaServer(t) { viaServer(t); continue }
                sendKeys(t.compactMap(CloudKey.keysym(for:)).flatMap { modifiers.wrap($0) })
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
                    self.history = Array((self.history + [CloudStreamQuality.adaptive(rttMs: ms)]).suffix(4))
                    if let next = CloudStreamQuality.shouldSwitch(current: self.quality, history: self.history) { self.setQuality(next) }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let sig = path.status == .satisfied ? path.availableInterfaces.map(\.name).joined(separator: ",") : "offline"
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPath = sig }
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
        for g in [pan, scroll, move, tap, double, right, long, pinch] as [UIGestureRecognizer] {
            g.delegate = c
            v.addGestureRecognizer(g)
        }
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

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let v = g.velocity(in: g.view)
            controller.move(by: delta(g), speed: hypot(v.x, v.y))
        }

        @objc func scroll(_ g: UIPanGestureRecognizer) { controller.scroll(by: delta(g)) }
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

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            controller.pinch(by: g.scale, around: g.location(in: g.view))
            g.scale = 1
        }
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

        @objc func changed(_ f: UITextField) {
            let now = f.text ?? ""
            let events = CloudIMECommit.events(old: last, new: now, composing: f.markedTextRange != nil)
            guard f.markedTextRange == nil else { return }
            if !events.isEmpty { parent.onEvents(events) }
            f.text = CloudIMECommit.sentinel
            last = CloudIMECommit.sentinel
        }

        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            parent.onReturn()
            return false
        }

        func textFieldDidEndEditing(_ f: UITextField) {
            DispatchQueue.main.async { if self.parent.focused { self.parent.focused = false } }
        }
    }
}
