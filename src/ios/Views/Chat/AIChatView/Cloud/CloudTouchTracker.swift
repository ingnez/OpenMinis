//
//  CloudTouchTracker.swift
//  Minis - 让 Bot 头像的眼睛跟着屏幕上任意位置的手指看：
//  在窗口上挂一个永不识别成功的手势识别器（不拦截、不延迟任何触摸），只记录手指位置。
//

import SwiftUI
import UIKit

@MainActor
final class CloudTouchTracker: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    static let shared = CloudTouchTracker()

    /// 手指在窗口坐标中的位置；松手后约 1.2 秒清空，眼睛回到自己张望
    @Published private(set) var point: CGPoint?
    private weak var installedWindow: UIWindow?
    private var lastPublish = Date.distantPast
    private var clearTask: Task<Void, Never>?

    func install() {
        guard installedWindow == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let window else { return }
        let watcher = CloudTouchWatcher { [weak self] p, ended in self?.report(p, ended: ended) }
        watcher.cancelsTouchesInView = false
        watcher.delaysTouchesBegan = false
        watcher.delaysTouchesEnded = false
        watcher.delegate = self
        window.addGestureRecognizer(watcher)
        installedWindow = window
    }

    private func report(_ p: CGPoint, ended: Bool) {
        clearTask?.cancel()
        if ended {
            clearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                self?.point = nil
            }
            return
        }
        // 约 30 次/秒就够了，避免每个触摸事件都让头像重算
        guard Date().timeIntervalSince(lastPublish) > 1.0 / 30 else { return }
        lastPublish = Date()
        point = p
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// 只观察、永不识别的手势
final class CloudTouchWatcher: UIGestureRecognizer {
    private let onTouch: (CGPoint, Bool) -> Void

    init(onTouch: @escaping (CGPoint, Bool) -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { onTouch(t.location(in: nil), false) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { onTouch(t.location(in: nil), false) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { onTouch(t.location(in: nil), true) }
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { onTouch(t.location(in: nil), true) }
        state = .failed
    }
}

/// 让头像的 gaze 跟着手指：量出头像在屏幕上的位置，手指在哪就往哪看
struct CloudFollowTouch: ViewModifier {
    @Binding var gaze: CGSize
    var enabled: Bool = true
    @ObservedObject private var tracker = CloudTouchTracker.shared
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { frame = $0 }
            })
            .onChange(of: tracker.point) { p in
                guard enabled, frame.width > 0 else { return }
                guard let p else {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { gaze = .zero }
                    return
                }
                let dx = p.x - frame.midX, dy = p.y - frame.midY
                let dist = max(1, (dx * dx + dy * dy).squareRoot())
                // 离得越远看得越「到边」；手指就在头像上时按相对位置看
                let reach = min(1, dist / max(frame.width, 60))
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    gaze = CGSize(width: dx / dist * reach, height: dy / dist * reach)
                }
            }
    }
}

/// 对话里每段回复上方的小头像：眨眼 + 眼睛跟着手指
struct CloudBotWatchingAvatar: View {
    let spec: CloudBotAvatarSpec
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gaze: CGSize = .zero
    @State private var eyeOpen: CGFloat = 1

    var body: some View {
        CloudBotAvatarView(spec: spec, size: size, gaze: gaze, eyeOpen: eyeOpen)
            .modifier(CloudFollowTouch(gaze: $gaze, enabled: !reduceMotion))
            .task(id: reduceMotion) {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 500_000_000...4_000_000_000))
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.07)) { eyeOpen = 0.1 }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    withAnimation(.easeInOut(duration: 0.1)) { eyeOpen = 1 }
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 2_500_000_000...6_000_000_000))
                }
            }
            .accessibilityHidden(true)
    }
}
