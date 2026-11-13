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
    private weak var replyRow: CloudTranscriptHitView?
    private var armed = false
    private var hideTimes: Task<Void, Never>?
    private var reduceMotion = false
    var onReply: ((Int, String, String) -> Void)?
    var isInteracting: Bool { direction != nil }

    func attach(to scroll: UIScrollView?, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        guard scrollView !== scroll else { return }
        scrollView?.removeGestureRecognizer(pan)
        scrollView = scroll
        scroll?.addGestureRecognizer(pan)
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
        start = touch.location(in: scrollView)
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other === scrollView?.panGestureRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let scrollView else { return false }
        let shift = pan.translation(in: scrollView)
        let velocity = pan.velocity(in: scrollView)
        let axis = abs(shift.x) + abs(shift.y) > 1 ? shift : velocity
        guard abs(axis.x) > 1.35 * abs(axis.y) else { return false }
        if axis.x > 0 {
            direction = .timestamps
            return true
        }
        replyRow = rows.allObjects.first { row in
            row.targetID != nil && row.window === scrollView.window &&
                row.isDescendant(of: scrollView) && row.bounds.contains(row.convert(start, from: scrollView))
        }
        guard replyRow != nil else { return false }
        direction = .reply
        return true
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let scrollView, let direction else { return }
        let distance = pan.translation(in: scrollView).x
        switch pan.state {
        case .began, .changed:
            switch direction {
            case .timestamps:
                hideTimes?.cancel()
                if !times.visible { times.visible = true }
                let x = -min(Self.timeWidth, max(0, distance))
                if timeOffset.x != x { timeOffset.x = x }
                #if DEBUG
                if x == -Self.timeWidth, CloudE2E.token != nil, !times.didReveal {
                    times.didReveal = true
                }
                #endif
            case .reply:
                let left = max(0, -distance)
                if pan.state == .began { replyRow?.offset.showingReply = true }
                if let offset = replyRow?.offset {
                    let excess = max(0, left - Self.replyThreshold)
                    let resistance = min(Self.replyOvershoot, 2 * excess.squareRoot())
                    let x = -(min(left, Self.replyThreshold) + resistance)
                    if offset.x != x { offset.x = x }
                }
                let reached = left >= Self.replyThreshold
                if reached && !armed { CloudHaptics.selection() }
                armed = reached
            }
        case .ended, .cancelled, .failed:
            let row = replyRow
            let reply = direction == .reply && pan.state == .ended && -distance >= Self.replyThreshold
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
            }
        default:
            break
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
        if times.didReveal {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("时间栏已滑出")
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
            connect()
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
            let progress = min(1, max(0, (-offset.x - start) / span))
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(Double(progress))
                .scaleEffect(0.5 + 0.5 * progress)
                .padding(.trailing, 10)
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
                            .accessibilityHidden(true)
                    }
                }
                .modifier(CloudTranscriptShift(offset: offset))
                .overlay(alignment: .trailing) {
                    if let date { CloudTranscriptTimeLabel(times: swipe.times, date: date).allowsHitTesting(false) }
                    if replyID != nil { CloudTranscriptReplyCue(offset: offset) }
                }
        } else {
            content
        }
    }
}
