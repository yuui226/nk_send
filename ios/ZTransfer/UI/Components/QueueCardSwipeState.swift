import Foundation

/// Android QueueCardSwipe.kt: consumed horizontal deltas (after touch slop),
/// bounded drag, 33% distance threshold and 180ms FastOutSlowIn settling.
/// Coordinates share the caller's units; supply 48dp in those units as margin.
/// The gesture host owns pointer/scroll arbitration. No fling velocity is used.
struct QueueCardSwipeState {
    struct Configuration: Equatable {
        var enabled: Bool
        var removing: Bool
    }

    private(set) var configuration: Configuration
    private(set) var flying = false
    private var removalPending = false
    private var animation = ZTransferScalarAnimation(value: 0)

    init(enabled: Bool, removing: Bool = false) {
        configuration = .init(enabled: enabled, removing: removing)
    }

    var offset: Float { animation.value }
    var isAnimating: Bool { animation.isRunning }

    /// TransferScreen's swipe/VoiceOver eligibility, including the cleanup
    /// window after clear-all when a newly finished card must stay disabled.
    static func isEnabled(item: TransferQueueItem, removing: Bool, clearing: Bool) -> Bool {
        !removing && !clearing && item.status != .transferring && !item.isGeneratingFrame
    }

    mutating func configure(enabled: Bool, removing: Bool) {
        let next = Configuration(enabled: enabled, removing: removing)
        guard next != configuration else { return }
        configuration = next
        // LaunchedEffect(enabled, removing) restores only outside removal.
        if !removing {
            flying = false
            restore()
        }
    }

    mutating func beginDrag() {
        guard configuration.enabled, !flying else { return }
        removalPending = false
        animation.reset(to: offset)
    }

    mutating func drag(by amount: Float, width: Float) {
        guard configuration.enabled, !flying, amount.isFinite, width.isFinite, width > 0 else { return }
        animation.reset(to: min(max(offset + amount, -width), width))
    }

    mutating func cancelDrag() {
        if !flying { restore() }
    }

    mutating func endDrag(width: Float, exitMargin: Float) {
        guard configuration.enabled, !flying else { return }
        guard width.isFinite, width > 0, exitMargin.isFinite, exitMargin >= 0,
              abs(offset) >= width * 0.33 else { restore(); return }
        flying = true
        removalPending = true
        animation.retarget((width + exitMargin) * (offset < 0 ? -1 : 1),
                           using: .tween(milliseconds: 180), force: true)
    }

    /// True requests the existing withdraw/collapse/remove chain exactly once.
    /// It does not delete data, and the queue must still recheck eligibility.
    mutating func advance(_ frameNanos: Int64) -> Bool {
        animation.advance(frameNanos: frameNanos)
        guard removalPending, !animation.isRunning else { return false }
        removalPending = false
        if configuration.enabled { return true }
        flying = false
        restore()
        return false
    }

    private mutating func restore() {
        removalPending = false
        // Cancel the previous coroutine before starting animate(offset, 0).
        animation.reset(to: offset)
        if offset != 0 { animation.retarget(0, using: .tween(milliseconds: 180)) }
    }
}
