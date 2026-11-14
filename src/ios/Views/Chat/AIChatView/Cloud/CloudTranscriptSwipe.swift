import SwiftUI
import UIKit

private struct CloudTranscriptSwipeKey: EnvironmentKey {
    static let defaultValue: CloudTranscriptSwipe? = nil
}

extension EnvironmentValues {
    var cloudTranscriptSwipe: CloudTranscriptSwipe? {
        get { self[CloudTranscriptSwipeKey.self] }
        set { self[CloudTranscriptSwipeKey.self] = newValue }
    }
}

@MainActor
final class CloudTranscriptOffset: ObservableObject {
    @Published var x: CGFloat = 0
    @Published var showingReply = false
}

@MainActor
final class CloudTranscriptTimes: ObservableObject {
    @Published var visible = false
    #if DEBUG
    @Published var didReveal = false
    @Published var revealedOffset: CGFloat = 0
    @Published var replyDiagnostic = "not attempted"
    #endif
}

/// One recognizer per transcript. A drag changes either the transcript transform
/// or one message transform. It never changes a message's layout or content.
@MainActor
final class CloudTranscriptSwipe: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    static let timeWidth: CGFloat = 68
    fileprivate static let replyThreshold: CGFloat = 34
    fileprivate static let replyCueStart: CGFloat = 6
    private static let replyOvershoot: CGFloat = 20

    let timeOffset = CloudTranscriptOffset()
    let times = CloudTranscriptTimes()
    private weak var scrollView: UIScrollView?
    var attachedScrollView: UIScrollView? { scrollView }
    private let rows = NSHashTable<CloudTranscriptHitView>.weakObjects()
    private lazy var pan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = self
        return recognizer
    }()
    private enum Direction { case timestamps, reply }
    private var direction: Direction?
    private var start = CGPoint.zero
    private weak var menuScrollView: UIScrollView?
    private var menuContentOrigin: CGPoint?
    private weak var replyRow: CloudTranscriptHitView?
    private var armed = false
    private var hideTimes: Task<Void, Never>?
    private var reduceMotion = false
    private var frameLink: CADisplayLink?
    private var pendingOffset: CGFloat?
    var onReply: ((Int, String, String) -> Void)?
    var onScrollSettled: ((Bool) -> Void)?
    private var scrollSettleTask: Task<Void, Never>?
    var isInteracting: Bool { direction != nil }
    var isVerticallyScrolling: Bool {
        guard let scrollView else { return false }
        return ChatScrollInteraction.blocksAutomaticScroll(in: scrollView) || scrollSettleTask != nil
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(saveMenuViewport), name: CloudMessageMenu.willPresent, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreMenuViewport(_:)), name: CloudMessageMenu.restoreViewport, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func saveMenuViewport() {
        guard let scroll = scrollView, let window = scroll.window else { return }
        menuScrollView = scroll
        menuContentOrigin = scroll.convert(CGPoint.zero, to: window)
    }

    @objc func restoreMenuViewport(_ notification: Notification) {
        defer {
            if notification.object as? Bool == true { menuContentOrigin = nil; menuScrollView = nil }
        }
        guard let origin = menuContentOrigin, let scroll = menuScrollView ?? scrollView,
              let window = scroll.window, !isInteracting,
              !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { return }
        let current = scroll.convert(CGPoint.zero, to: window)
        let delta = current.y - origin.y
        if abs(delta) > 0.5 {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: scroll.contentOffset.y + delta), animated: false)
        }
    }

    func attach(to scroll: UIScrollView?, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        guard scrollView !== scroll else { return }
        scrollView?.removeGestureRecognizer(pan)
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(trackVerticalPan(_:)))
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        stopFrameUpdates()
        hideTimes?.cancel()
        if timeOffset.x != 0 { timeOffset.x = 0 }
        if times.visible { times.visible = false }
        if let offset = replyRow?.offset {
            if offset.x != 0 { offset.x = 0 }
            if offset.showingReply { offset.showingReply = false }
        }
        direction = nil
        replyRow = nil
        armed = false
        scrollView = scroll
        scroll?.addGestureRecognizer(pan)
        if #unavailable(iOS 18) {
            scroll?.panGestureRecognizer.addTarget(self, action: #selector(trackVerticalPan(_:)))
        }
    }

    // SwiftUI exposes scroll phases starting in iOS 18. On older versions,
    // watch the existing pan recognizer and wait for UIKit's momentum to end.
    @objc private func trackVerticalPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            scrollSettleTask?.cancel()
            scrollSettleTask = nil
        case .ended, .cancelled:
            scrollSettleTask?.cancel()
            scrollSettleTask = Task { @MainActor [weak self] in
                repeat {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, let self, let scroll = self.scrollView else { return }
                    if !ChatScrollInteraction.isMoving(scroll) {
                        self.scrollSettleTask = nil
                        self.onScrollSettled?(ChatScrollInteraction.distanceFromBottom(of: scroll) <= 4)
                        return
                    }
                } while !Task.isCancelled
            }
        default:
            break
        }
    }

    fileprivate func register(_ row: CloudTranscriptHitView) { rows.add(row) }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let scrollView, let window = scrollView.window,
              touch.location(in: window).x > window.bounds.minX + 24 else { return false }
        var view = touch.view
        while let candidate = view, candidate !== scrollView {
            // Preserve sliders, links with controls, and horizontal code/table scrolling.
            if candidate is UIControl { return false }
            if let text = candidate as? UITextView, text.selectedRange.length > 0 { return false }
            if let nested = candidate as? UIScrollView,
               nested.isScrollEnabled, nested.contentSize.width > nested.bounds.width + 1 { return false }
            view = candidate.superview
        }
        start = touch.location(in: window)
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        if other === scrollView?.panGestureRecognizer { return true }
        if other is UIPanGestureRecognizer, let view = other.view, let scrollView, view.isDescendant(of: scrollView) {
            return true
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if other === scrollView?.panGestureRecognizer { return false }
        if other is UIPanGestureRecognizer { return false }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let scrollView else { return false }
        // Use the physical screen direction, independent of transcript offsets
        // or any transformed ancestor of the message text.
        let shift = pan.translation(in: scrollView.window)
        let velocity = pan.velocity(in: scrollView.window)
        let axis = abs(shift.x) + abs(shift.y) > 1 ? shift : velocity
        guard abs(axis.x) > 1.35 * abs(axis.y) else { return false }
        if axis.x < 0 {
            // Finger left: reveal times on the right and move with the finger.
            direction = .timestamps
            return true
        }
        let candidates = rows.allObjects.filter { row in
            row.targetID != nil && row.window === scrollView.window && row.isDescendant(of: scrollView)
        }
        replyRow = candidates.first { row in
            let pt = row.convert(start, from: scrollView.window)
            if row.bounds.width > 1 && row.bounds.height > 1 {
                return row.bounds.insetBy(dx: -8, dy: -4).contains(pt)
            }
            if let host = row.superview, host.bounds.width > 1 && host.bounds.height > 1 {
                let hpt = host.convert(start, from: scrollView.window)
                return host.bounds.insetBy(dx: -8, dy: -4).contains(hpt)
            }
            return false
        }
        #if DEBUG
        if CloudE2E.token != nil {
            let rects = candidates.map { r in
                let f = r.convert(r.bounds, to: scrollView.window)
                return "\(r.targetID ?? -1):\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))"
            }.joined(separator: ";")
            times.replyDiagnostic = "rows=\(rows.allObjects.count), start=\(Int(start.x)),\(Int(start.y)), hit=\(replyRow?.targetID.map(String.init) ?? "none"), callback=\(onReply != nil), rects=[\(rects)]"
        }
        #endif
        guard replyRow != nil else { return false }
        direction = .reply
        return true
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let scrollView, let direction else { return }
        let distance = pan.translation(in: scrollView.window).x
        switch pan.state {
        case .began, .changed:
            if pan.state == .began { startFrameUpdates(in: scrollView) }
            switch direction {
            case .timestamps:
                hideTimes?.cancel()
                if !times.visible { times.visible = true }
                let x = -min(Self.timeWidth, max(0, -distance))
                pendingOffset = x
            case .reply:
                let right = max(0, distance)
                if pan.state == .began { replyRow?.offset.showingReply = true }
                let excess = max(0, right - Self.replyThreshold)
                let resistance = min(Self.replyOvershoot, 2 * excess.squareRoot())
                pendingOffset = min(right, Self.replyThreshold) + resistance
                let reached = right >= Self.replyThreshold
                if reached && !armed { CloudHaptics.selection() }
                armed = reached
            }
            if pan.state == .began { applyPendingOffset() }
        case .ended, .cancelled, .failed:
            let row = replyRow
            let reply = direction == .reply && pan.state == .ended && distance >= Self.replyThreshold
            stopFrameUpdates()
            self.direction = nil
            replyRow = nil
            armed = false
            let animation: Animation? = reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.88)
            switch direction {
            case .timestamps:
                withAnimation(animation) { timeOffset.x = 0 }
                hideTimes = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 320_000_000)
                    guard !Task.isCancelled else { return }
                    self?.times.visible = false
                }
            case .reply:
                withAnimation(animation) {
                    row?.offset.x = 0
                    row?.offset.showingReply = false
                }
                if reply, let row, let id = row.targetID { onReply?(id, row.excerpt, row.role) }
                #if DEBUG
                if CloudE2E.token != nil { times.replyDiagnostic += ", ended=\(pan.state == .ended), distance=\(Int(distance)), fired=\(reply && row?.targetID != nil && onReply != nil)" }
                #endif
            }
        default:
            break
        }
    }

    private func startFrameUpdates(in scrollView: UIScrollView) {
        stopFrameUpdates()
        let target = FrameTarget(swipe: self)
        let link = CADisplayLink(target: target, selector: #selector(FrameTarget.tick(_:)))
        let maximum = Float(scrollView.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    private func stopFrameUpdates() {
        frameLink?.invalidate()
        frameLink = nil
        pendingOffset = nil
    }

    // Only the latest transform is published each display frame. Recognition,
    // haptics and the final reply decision still use the original touch events.
    private func applyPendingOffset() {
        guard let pendingOffset, let direction else { return }
        self.pendingOffset = nil
        let offset = direction == .timestamps ? timeOffset : replyRow?.offset
        if let offset, offset.x != pendingOffset { offset.x = pendingOffset }
        #if DEBUG
        if direction == .timestamps, pendingOffset == -Self.timeWidth, CloudE2E.token != nil, !times.didReveal {
            times.revealedOffset = pendingOffset
            times.didReveal = true
        }
        #endif
    }

    @MainActor
    private final class FrameTarget: NSObject {
        weak var swipe: CloudTranscriptSwipe?

        init(swipe: CloudTranscriptSwipe) { self.swipe = swipe }

        @objc func tick(_ link: CADisplayLink) {
            guard let swipe, swipe.scrollView?.window != nil else { link.invalidate(); return }
            swipe.applyPendingOffset()
        }
    }
}

struct CloudTranscriptShift: ViewModifier {
    @ObservedObject var offset: CloudTranscriptOffset
    func body(content: Content) -> some View { content.offset(x: offset.x) }
}

#if DEBUG
struct CloudTranscriptTimeTestStatus: View {
    @ObservedObject var times: CloudTranscriptTimes

    var body: some View {
        Text(times.replyDiagnostic)
            .font(.system(size: 1)).opacity(0.01)
            .accessibilityIdentifier("botReplySwipeDiagnostic")
            .allowsHitTesting(false)
        if times.didReveal {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("时间栏已滑出")
                .accessibilityValue(String(Int(times.revealedOffset)))
                .accessibilityIdentifier("botMessageTimesRevealed")
                .allowsHitTesting(false)
        }
    }
}
#endif

struct CloudTranscriptGestureBridge: UIViewRepresentable {
    let swipe: CloudTranscriptSwipe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.swipe = swipe
        view.reduceMotion = reduceMotion
        view.connect()
    }

    final class Probe: UIView {
        weak var swipe: CloudTranscriptSwipe?
        var reduceMotion = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { connect() }
            else { swipe?.attach(to: nil, reduceMotion: reduceMotion) }
        }

        func connect() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    swipe?.attach(to: scroll, reduceMotion: reduceMotion)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

final class CloudTranscriptHitView: UIView {
    let offset: CloudTranscriptOffset
    var targetID: Int?
    var excerpt = ""
    var role = "assistant"

    init(offset: CloudTranscriptOffset) {
        self.offset = offset
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }
}

private struct CloudTranscriptHitRegion: UIViewRepresentable {
    let swipe: CloudTranscriptSwipe
    let offset: CloudTranscriptOffset
    let id: Int?
    let excerpt: String
    let role: String

    func makeUIView(context: Context) -> CloudTranscriptHitView {
        let view = CloudTranscriptHitView(offset: offset)
        swipe.register(view)
        return view
    }

    func updateUIView(_ view: CloudTranscriptHitView, context: Context) {
        // SwiftUI can reuse a mounted region when its environment changes.
        swipe.register(view)
        view.targetID = id
        view.excerpt = excerpt
        view.role = role
    }
}

private struct CloudTranscriptReplyCue: View {
    @ObservedObject var offset: CloudTranscriptOffset

    var body: some View {
        if offset.showingReply {
            let start = CloudTranscriptSwipe.replyCueStart
            let span = CloudTranscriptSwipe.replyThreshold - start
            let progress = min(1, max(0, (offset.x - start) / span))
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(Double(progress))
                .scaleEffect(0.5 + 0.5 * progress)
                .padding(.leading, 10)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

private struct CloudTranscriptTimeLabel: View {
    @ObservedObject var times: CloudTranscriptTimes
    let date: Date

    var body: some View {
        if times.visible {
            Text(date, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: CloudTranscriptSwipe.timeWidth, alignment: .trailing)
                .offset(x: CloudTranscriptSwipe.timeWidth)
                .accessibilityIdentifier("botMessageTime")
        }
    }
}

struct CloudTranscriptMessage: ViewModifier {
    let date: Date?
    var replyID: Int? = nil
    var excerpt = ""
    var replyRole = "assistant"
    @Environment(\.cloudTranscriptSwipe) private var swipe
    @StateObject private var offset = CloudTranscriptOffset()

    func body(content: Content) -> some View {
        if let swipe {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if replyID != nil {
                        CloudTranscriptHitRegion(swipe: swipe, offset: offset, id: replyID, excerpt: excerpt, role: replyRole)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityHidden(true)
                    }
                }
                .modifier(CloudTranscriptShift(offset: offset))
                .overlay(alignment: .trailing) {
                    if let date { CloudTranscriptTimeLabel(times: swipe.times, date: date).allowsHitTesting(false) }
                }
                .overlay(alignment: .leading) {
                    if replyID != nil { CloudTranscriptReplyCue(offset: offset) }
                }
        } else {
            content
        }
    }
}
