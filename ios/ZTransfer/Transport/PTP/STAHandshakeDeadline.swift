import Foundation

/// One monotonic budget across every fragment/PING of a handshake response.
/// Applies only before STA activation; normal transfers retain idle timeouts.
struct STAHandshakeDeadline: Sendable {
    private let deadline: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant

    init(nanoseconds: UInt64, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
        deadline = now().advanced(by: .nanoseconds(Int64(clamping: nanoseconds)))
    }

    func remainingNanoseconds(idleLimit: UInt64 = 5_000_000_000) throws -> UInt64 {
        let remaining = now().duration(to: deadline)
        guard remaining > .zero else { throw PTPSessionError.timeout }
        let parts = remaining.components
        let nanos = UInt64(parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
        return min(idleLimit, max(1, nanos))
    }
}
