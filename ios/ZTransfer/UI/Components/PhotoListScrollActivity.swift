import SwiftUI
import UIKit

/// FileListScreen's back-to-top visibility policy. Offsets are physical pixels,
/// and indices include date headers and collection entries, not just photos.
struct PhotoListBackTopState {
    private(set) var isVisible = false
    private(set) var isReturning = false
    private(set) var hideDeadline: TimeInterval?
    private var lastIndex: Int?
    private var lastOffset = 0

    mutating func update(index: Int, offsetPixels: Int, scrolling: Bool, now: TimeInterval) {
        if let lastIndex {
            let towardTop = index < lastIndex || (index == lastIndex && offsetPixels < lastOffset - 4)
            let towardBottom = index > lastIndex || (index == lastIndex && offsetPixels > lastOffset + 4)
            if towardTop && index >= 30 && !isReturning { isVisible = true }
            else if towardBottom || index < 30 { isVisible = false }
        }
        lastIndex = index
        lastOffset = offsetPixels
        if scrolling || !isVisible { hideDeadline = nil }
        else if hideDeadline == nil { hideDeadline = now + 1.8 }
    }

    mutating func expire(now: TimeInterval) {
        guard let hideDeadline, now >= hideDeadline else { return }
        isVisible = false
        self.hideDeadline = nil
    }

    mutating func beginReturn() {
        isReturning = true
        isVisible = false
        hideDeadline = nil
    }

    mutating func finishReturn() { isReturning = false }
}

/// Owns the visibility deadline; layout measurements only describe composed items.
@MainActor
final class PhotoListBackTopController: ObservableObject {
    @Published private(set) var isVisible = false
    private var state = PhotoListBackTopState()
    private var position: (index: Int, offset: Int)?
    private var scrolling = false
    private var hideTask: Task<Void, Never>?

    func update(frames: [String: CGRect], indices: [String: Int], viewport: CGRect, scale: CGFloat) {
        guard !indices.isEmpty else { reset(); return }
        guard let next = Self.firstVisible(frames: frames, indices: indices, viewport: viewport, scale: scale) else { return }
        position = next
        updateState()
    }

    static func firstVisible(frames: [String: CGRect], indices: [String: Int], viewport: CGRect,
                             scale: CGFloat) -> (index: Int, offset: Int)? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        var first: (index: Int, frame: CGRect)?
        for (id, frame) in frames {
            guard let index = indices[id], frame.maxY > viewport.minY, frame.minY < viewport.maxY else { continue }
            if first == nil || index < first!.index { first = (index, frame) }
        }
        return first.map { ($0.index, max(0, Int(((viewport.minY - $0.frame.minY) * max(scale, 1)).rounded()))) }
    }

    func setScrolling(_ value: Bool) {
        scrolling = value
        // A user gesture can interrupt a programmatic return.
        if value { state.finishReturn() }
        updateState()
    }

    func beginReturn() {
        state.beginReturn()
        synchronize(previousDeadline: nil)
    }

    func finishReturn() { state.finishReturn() }

    func reset() {
        hideTask?.cancel()
        hideTask = nil
        state = PhotoListBackTopState()
        position = nil
        scrolling = false
        isVisible = false
    }

    private func updateState() {
        guard let position else { return }
        let deadline = state.hideDeadline
        state.update(index: position.index, offsetPixels: position.offset,
                     scrolling: scrolling, now: ProcessInfo.processInfo.systemUptime)
        synchronize(previousDeadline: deadline)
    }

    private func synchronize(previousDeadline: TimeInterval?) {
        if isVisible != state.isVisible { isVisible = state.isVisible }
        guard previousDeadline != state.hideDeadline || state.hideDeadline == nil else { return }
        hideTask?.cancel()
        hideTask = nil
        guard let deadline = state.hideDeadline else { return }
        hideTask = Task { @MainActor [weak self] in
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.state.expire(now: ProcessInfo.processInfo.systemUptime)
            self.isVisible = self.state.isVisible
            self.hideTask = nil
        }
    }
}

/// Distinguishes actual dragging/deceleration from geometry changes caused by
/// thumbnail layout or returning to the list. Does not replace the scroll delegate.
struct PhotoListScrollActivity: UIViewRepresentable {
    let onScroll: (_ atTop: Bool) -> Void
    var onActivityChanged: (Bool) -> Void = { _ in }

    // LazyGridState.firstVisibleItemScrollOffset is integer pixels, not dp.
    static func isAtTop(offset: CGFloat, scale: CGFloat) -> Bool {
        (offset * max(scale, 1)).rounded() < 8
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.onScroll = onScroll
        view.onActivityChanged = onActivityChanged
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onScroll = onScroll
        view.onActivityChanged = onActivityChanged
    }

    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: UIView {
        var onScroll: ((Bool) -> Void)?
        var onActivityChanged: ((Bool) -> Void)?
        private weak var scroll: UIScrollView?
        private var offsetObservation: NSKeyValueObservation?
        private var activityTask: Task<Void, Never>?
        private var scrolling = false

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
            if !scrolling {
                scrolling = true
                onActivityChanged?(true)
            }
            if activityTask == nil {
                // Observe only during an actual gesture/deceleration. UIKit's
                // final offset notification can precede isDecelerating=false;
                // waiting for that flag avoids guessing stop from quiet offsets.
                activityTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(16))
                        guard !Task.isCancelled, let self else { return }
                        guard let scroll = self.scroll,
                              scroll.isDragging || scroll.isDecelerating else {
                            self.activityTask = nil
                            self.scrolling = false
                            self.onActivityChanged?(false)
                            return
                        }
                    }
                }
            }
            // Read the offset that caused this event, not SwiftUI's previous
            // preference pass. One drag event can cross the entire 8px boundary.
            onScroll?(PhotoListScrollActivity.isAtTop(
                offset: scroll.contentOffset.y + scroll.adjustedContentInset.top,
                scale: scroll.window?.screen.scale ?? UIScreen.main.scale))
        }

        func detach() {
            activityTask?.cancel()
            activityTask = nil
            scrolling = false
            scroll?.panGestureRecognizer.removeTarget(self, action: #selector(didPan))
            offsetObservation = nil
            scroll = nil
        }
    }
}
