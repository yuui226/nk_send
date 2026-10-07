import Foundation

/// GlassButton.kt PressInteraction consumer, independent of frame scheduling.
/// Timestamps use a monotonic millisecond clock. This state never delays clicks;
/// it only tells the rendering owner whether press feedback is still active.
struct ZTransferButtonPressState {
    private(set) var enabled = true
    private(set) var visualPressed = false
    private(set) var releaseDeadline: Int64?
    private var presses: Set<UInt64> = []
    private var pressedAt: Int64 = 0

    mutating func press(_ id: UInt64, at now: Int64) {
        guard enabled else { return }
        releaseDeadline = nil
        if presses.isEmpty { pressedAt = now }
        presses.insert(id)
        visualPressed = true
    }

    mutating func release(_ id: UInt64, at now: Int64) {
        guard presses.remove(id) != nil, presses.isEmpty else { return }
        let remaining = max(90 - (now - pressedAt), 0)
        releaseDeadline = remaining > 0 ? now + remaining : nil
        visualPressed = remaining > 0
    }

    mutating func cancel(_ id: UInt64) {
        presses.remove(id)
        if presses.isEmpty {
            releaseDeadline = nil
            visualPressed = false
        }
    }

    mutating func advance(to now: Int64) {
        guard presses.isEmpty, let deadline = releaseDeadline, now >= deadline else { return }
        releaseDeadline = nil
        visualPressed = false
    }

    mutating func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        reset()
        enabled = value
    }

    mutating func reset() {
        presses.removeAll(keepingCapacity: true)
        releaseDeadline = nil
        visualPressed = false
        pressedAt = 0
    }
}
