import SwiftUI
import UIKit

/// Distinguishes actual dragging/deceleration from geometry changes caused by
/// thumbnail layout or returning to the list. Does not replace the scroll delegate.
struct PhotoListScrollActivity: UIViewRepresentable {
    let onScroll: (_ atTop: Bool) -> Void

    // LazyGridState.firstVisibleItemScrollOffset is integer pixels, not dp.
    static func isAtTop(offset: CGFloat, scale: CGFloat) -> Bool {
        (offset * max(scale, 1)).rounded() < 8
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.onScroll = onScroll
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) { view.onScroll = onScroll }

    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: UIView {
        var onScroll: ((Bool) -> Void)?
        private weak var scroll: UIScrollView?
        private var offsetObservation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard window != nil else { return }
            var parent = superview
            while let candidate = parent {
                if let scroll = candidate as? UIScrollView {
                    self.scroll = scroll
                    scroll.panGestureRecognizer.addTarget(self, action: #selector(didPan))
                    offsetObservation = scroll.observe(\.contentOffset, options: [.old, .new]) { [weak self] view, change in
                        guard change.oldValue != change.newValue else { return }
                        MainActor.assumeIsolated {
                            if view.isDragging || view.isDecelerating { self?.report(view) }
                        }
                    }
                    break
                }
                parent = candidate.superview
            }
        }

        @objc private func didPan() {
            guard let state = scroll?.panGestureRecognizer.state,
                  state == .began || state == .changed else { return }
            if let scroll { report(scroll) }
        }

        private func report(_ scroll: UIScrollView) {
            // Read the offset that caused this event, not SwiftUI's previous
            // preference pass. One drag event can cross the entire 8px boundary.
            onScroll?(PhotoListScrollActivity.isAtTop(
                offset: scroll.contentOffset.y + scroll.adjustedContentInset.top,
                scale: scroll.window?.screen.scale ?? UIScreen.main.scale))
        }

        func detach() {
            scroll?.panGestureRecognizer.removeTarget(self, action: #selector(didPan))
            offsetObservation = nil
            scroll = nil
        }
    }
}
