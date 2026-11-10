import Foundation

/// Cancellation of a queued shutter must remain visible after an actor/queue
/// hop. Once dispatched, the response is drained without consulting this flag.
final class PTPCommandPermission: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool { lock.withLock { current } }
    func invalidate() { lock.withLock { current = false } }
    func check() throws { if !isCurrent { throw PTPCommandNotSent() } }
}

struct PTPCommandNotSent: Error {}

enum PTPCommandContext {
    @TaskLocal static var permission: PTPCommandPermission?
    static func check() throws { try permission?.check() }
}
