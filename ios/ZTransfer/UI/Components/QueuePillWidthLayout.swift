import SwiftUI

/// TransferInfoPill's animateContentSize(tween(140)). Compose IntSize exposes
/// rounded pixels, and an interruption starts at that displayed integer.
struct QueuePillWidthMotion {
    private var animation: ZTransferScalarAnimation?
    private var density: CGFloat = 1
    var width: CGFloat? { animation.map { CGFloat(floor($0.value + 0.5)) / density } }
    var isRunning: Bool { animation?.isRunning ?? false }

    mutating func measure(_ width: CGFloat, scale: CGFloat) {
        guard width.isFinite, width >= 0, scale.isFinite, scale > 0 else { return }
        let pixels = Float(floor(width * scale + 0.5))
        if animation == nil || density != scale {
            animation = .init(value: pixels)
        } else {
            let displayedPixels = floor(animation!.value + 0.5)
            animation?.retarget(pixels, using: .tween(milliseconds: 140),
                                fromDisplayedValue: displayedPixels)
        }
        density = scale
    }

    mutating func advance(_ nanos: Int64) { animation?.advance(frameNanos: nanos) }
}

/// Measure the child against the parent's proposal, never against our animated
/// width. This keeps a growing label's target stable and preserves truncation at
/// the available row width. Only the reported occupancy changes each frame.
struct QueuePillWidthLayout: Layout {
    var displayedWidth: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let target = child.sizeThatFits(proposal)
        // HStack's min/max flexibility probes must see the content's intrinsic
        // constraints, not a frozen width from an earlier layout pass.
        guard let displayedWidth, proposal.width != 0, proposal.width != .infinity else { return target }
        return CGSize(width: min(displayedWidth, proposal.width ?? displayedWidth), height: target.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let target = child.sizeThatFits(proposal)
        // animateContentSize defaults to TopStart. The child itself centers its
        // text/icon within the padded target size; the animated viewport clips it.
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(target))
    }
}
