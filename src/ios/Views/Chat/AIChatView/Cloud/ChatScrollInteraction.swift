import SwiftUI
import UIKit

@MainActor
enum ChatScrollInteraction {
    private static let nestedScrolls = NSHashTable<UIScrollView>.weakObjects()

    static func isMoving(_ scroll: UIScrollView) -> Bool {
        scroll.isTracking || scroll.isDragging || scroll.isDecelerating
            || scroll.panGestureRecognizer.state == .began
            || scroll.panGestureRecognizer.state == .changed
    }

    static func blocksAutomaticScroll(in transcript: UIScrollView) -> Bool {
        isMoving(transcript) || hasMovingChild(in: transcript)
    }

    static func hasMovingChild(in transcript: UIScrollView) -> Bool {
        nestedScrolls.allObjects.contains { scroll in
            guard scroll !== transcript, scroll.isScrollEnabled, isMoving(scroll),
                  scroll.isDescendant(of: transcript) else { return false }
            let inset = scroll.adjustedContentInset
            return scroll.contentSize.height + inset.top + inset.bottom > scroll.bounds.height + 0.5
        }
    }

    static func registerNestedScroll(_ scroll: UIScrollView, attached: Bool) {
        if attached {
            nestedScrolls.add(scroll)
        } else {
            nestedScrolls.remove(scroll)
        }
    }

    static func distanceFromBottom(of scroll: UIScrollView) -> CGFloat {
        let insets = scroll.adjustedContentInset
        let bottom = max(-insets.top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
        return bottom - scroll.contentOffset.y
    }
}

/// Register a SwiftUI nested scroller without changing its delegate or gestures.
struct NestedChatScrollProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.connect()
    }

    final class Probe: UIView {
        private weak var scroll: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                connect()
            } else if let scroll {
                ChatScrollInteraction.registerNestedScroll(scroll, attached: false)
                self.scroll = nil
            }
        }

        func connect() {
            guard window != nil, scroll == nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    self.scroll = scroll
                    ChatScrollInteraction.registerNestedScroll(scroll, attached: true)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
