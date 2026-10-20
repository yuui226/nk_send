import SwiftUI
import UIKit

/// Read the pager in its own UIScrollView coordinates. SwiftUI's visual frame
/// preferences include opening/throw transforms and can falsely report a page
/// change while the scroll view is stationary (PhotoPreview.kt pager state).
@MainActor
final class PhotoPreviewPagerObservation {
    private final class WeakPage {
        weak var view: PhotoPreviewPageObserver.Marker?
        init(_ view: PhotoPreviewPageObserver.Marker) { self.view = view }
    }
    private var pages: [ObjectIdentifier: WeakPage] = [:]
    private var scheduled = false
    private var lastPage: (index: Int, offset: CGFloat)?
    private weak var lockedScroll: UIScrollView?
    private var panWasEnabled = false

    /// PageTabView does not reliably inherit scrollDisabled. Cancel only its
    /// native horizontal pan; the overlay's upward drag must keep its touches.
    /// PhotoPreview.kt consumes every pointer change once UPWARD has won.
    func lockPaging(to index: Int) {
        guard lockedScroll == nil,
              let page = pages.values.compactMap(\.view).first(where: { $0.index == index && $0.window != nil }),
              let scroll = page.scroll else { return }
        lockedScroll = scroll
        panWasEnabled = scroll.panGestureRecognizer.isEnabled
        scroll.panGestureRecognizer.isEnabled = false
        let rect = page.convert(page.bounds, to: scroll)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x + rect.midX - scroll.bounds.midX,
                                       y: scroll.contentOffset.y), animated: false)
    }

    func unlockPaging() {
        lockedScroll?.panGestureRecognizer.isEnabled = panWasEnabled
        lockedScroll = nil
    }

    func add(_ view: PhotoPreviewPageObserver.Marker) {
        pages[ObjectIdentifier(view)] = WeakPage(view)
        schedule()
    }
    func remove(_ view: PhotoPreviewPageObserver.Marker) {
        pages[ObjectIdentifier(view)] = nil
        if let lockedScroll, !pages.values.contains(where: { $0.view?.scroll === lockedScroll }) {
            unlockPaging()
        }
        if pages.isEmpty { lastPage = nil }
    }

    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            let mounted = self.pages.values.compactMap(\.view).filter { $0.window != nil }
            var offsets: [Int: CGFloat] = [:]
            for page in mounted {
                guard let scroll = page.scroll, page.bounds.width > 0 else { continue }
                let rect = page.convert(page.bounds, to: scroll)
                guard rect.width > 0 else { continue }
                let offset = (rect.midX - scroll.bounds.midX) / rect.width
                offsets[page.index] = abs(offset) < 0.0001 ? 0 : offset
            }
            guard let nearest = nearestPreviewPage(offsets: offsets) else { return }
            guard self.lastPage?.index != nearest.index || self.lastPage?.offset != nearest.offset else { return }
            self.lastPage = nearest
            mounted.first?.onPage?(nearest.index, nearest.offset)
        }
    }
}

struct PhotoPreviewPageObserver: UIViewRepresentable {
    let observation: PhotoPreviewPagerObservation
    let index: Int
    let onPage: (Int, CGFloat) -> Void

    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ view: Marker, context: Context) {
        view.index = index; view.onPage = onPage
        view.observation = observation
        view.attach()
        observation.schedule()
    }
    static func dismantleUIView(_ view: Marker, coordinator: ()) {
        view.detach(); view.onPage = nil; view.observation = nil
    }

    final class Marker: UIView {
        var index = 0
        var onPage: ((Int, CGFloat) -> Void)?
        var observation: PhotoPreviewPagerObservation?
        private(set) weak var scroll: UIScrollView?
        private var offsetObservation: NSKeyValueObservation?
        private var measuredFrame = CGRect.null
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }
        override func layoutSubviews() {
            super.layoutSubviews(); attach()
            // Visual lifting/scaling does not change the page's local layout.
            // Do not measure every mounted page again for that kind of layout pass.
            if measuredFrame != frame {
                measuredFrame = frame
                observation?.schedule()
            }
        }
        func attach() {
            guard window != nil, scroll == nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let pager = view as? UIScrollView {
                    scroll = pager
                    offsetObservation = pager.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.observation?.schedule() }
                    }
                    observation?.add(self)
                    return
                }
                ancestor = view.superview
            }
        }
        func detach() {
            observation?.remove(self)
            offsetObservation = nil; scroll = nil; measuredFrame = .null
        }
    }
}
