import SwiftUI
import UIKit

/// TransferScreen.animateContentSize(tween(250, FastOutSlowInEasing)).
/// Both IntSize channels restart together from their displayed integer pixels.
struct QueueCardContentSizeMotion {
    private var width: ZTransferScalarAnimation?
    private var height: ZTransferScalarAnimation?
    private var density: CGFloat = 1
    private var frame: Int64?
    var isRunning: Bool { (width?.isRunning ?? false) || (height?.isRunning ?? false) }
    var size: CGSize? {
        guard let width, let height else { return nil }
        return CGSize(width: CGFloat(floor(width.value + 0.5)) / density,
                      height: CGFloat(floor(height.value + 0.5)) / density)
    }

    mutating func measure(_ size: CGSize, scale: CGFloat) {
        guard size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0,
              scale.isFinite, scale > 0 else { return }
        let x = Float(floor(size.width * scale + 0.5))
        let y = Float(floor(size.height * scale + 0.5))
        guard width != nil, height != nil, density == scale else {
            width = .init(value: x); height = .init(value: y)
            density = scale; frame = nil
            return
        }
        guard width!.target != x || height!.target != y else { return }
        let displayedX = floor(width!.value + 0.5)
        let displayedY = floor(height!.value + 0.5)
        width?.retarget(x, using: .tween(milliseconds: 250), fromDisplayedValue: displayedX,
                        force: true, atFrameNanos: frame)
        height?.retarget(y, using: .tween(milliseconds: 250), fromDisplayedValue: displayedY,
                         force: true, atFrameNanos: frame)
    }

    /// Compose cancels the detached node coroutine but retains its IntSize value.
    /// A retained node restarts from that value when measured after reattachment.
    mutating func suspend() {
        if let width { self.width = .init(value: floor(width.value + 0.5)) }
        if let height { self.height = .init(value: floor(height.value + 0.5)) }
        frame = nil
    }

    mutating func advance(_ nanos: Int64) {
        width?.advance(frameNanos: nanos)
        height?.advance(frameNanos: nanos)
        frame = isRunning ? nanos : nil
    }
}

@MainActor
private final class QueueCardContentSizeClock: ObservableObject {
    @Published private(set) var motion = QueueCardContentSizeMotion()
    private var link: CADisplayLink?
    private var isVisible = false
    @MainActor
    private final class Target: NSObject {
        weak var owner: QueueCardContentSizeClock?
        init(_ owner: QueueCardContentSizeClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.motion.advance(Int64(link.timestamp * 1_000_000_000))
            if !owner.motion.isRunning { owner.stop() }
        }
    }
    func measure(_ size: CGSize, scale: CGFloat) {
        guard isVisible else { return }
        motion.measure(size, scale: scale)
        guard motion.isRunning, link == nil else { return }
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    func appear() { isVisible = true }
    func disappear() {
        isVisible = false
        stop()
        motion.suspend()
    }
}

private struct QueueCardContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize? = nil
    static func reduce(value: inout CGSize?, nextValue: () -> CGSize?) {
        if let next = nextValue() { value = next }
    }
}

/// Always measure the natural child height. Feeding the animated height back
/// to the child would repeatedly retarget the tween instead of reaching its end.
private struct QueueCardContentSizeLayout: Layout {
    let size: CGSize?
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(.init(width: proposal.width, height: nil))
        guard let size, proposal.width != 0, proposal.width != .infinity else { return natural }
        return size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let natural = child.sizeThatFits(.init(width: proposal.width, height: nil))
        child.place(at: bounds.origin, anchor: .topLeading, proposal: .init(natural))
    }
}

struct QueueCardContentSize: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    @StateObject private var clock = QueueCardContentSizeClock()
    @State private var naturalSize: CGSize?
    func body(content: Content) -> some View {
        QueueCardContentSizeLayout(size: clock.motion.size) {
            content.background {
                GeometryReader { proxy in
                    Color.clear.preference(key: QueueCardContentSizeKey.self, value: proxy.size)
                }
            }
        }
        .clipped()
        .transaction { $0.animation = nil }
        .onPreferenceChange(QueueCardContentSizeKey.self) { size in
            guard let size else { return }
            naturalSize = size
            clock.measure(size, scale: displayScale)
        }
        .onChange(of: displayScale) { scale in
            if let naturalSize { clock.measure(naturalSize, scale: scale) }
        }
        .onAppear {
            clock.appear()
            if let naturalSize { clock.measure(naturalSize, scale: displayScale) }
        }
        .onDisappear { clock.disappear() }
    }
}
