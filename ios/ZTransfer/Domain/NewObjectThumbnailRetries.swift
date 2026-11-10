import Foundation

/// Android NewObjectThumbnailRetries.kt. Owned by the session's thumbnail
/// actor; only newly announced objects receive this finite delay budget.
struct NewObjectThumbnailRetries: Sendable {
    private struct Entry: Sendable { var failures = 0; var retryAt: Int64? }
    private var entries: [UInt32: Entry] = [:]
    private static let delays: [Int64] = [300, 900, 1_800]

    mutating func register(_ handle: UInt32) {
        if entries[handle] == nil { entries[handle] = Entry() }
    }
    func isRetry(_ handle: UInt32) -> Bool { (entries[handle]?.failures ?? 0) > 0 }
    func canAttempt(_ handle: UInt32, now: Int64) -> Bool { entries[handle]?.retryAt.map { now >= $0 } ?? true }
    func blockedHandles(now: Int64) -> Set<UInt32> {
        Set(entries.compactMap { $0.value.retryAt.map { $0 > now } == true ? $0.key : nil })
    }
    mutating func failed(_ handle: UInt32, now: Int64) -> Int64? {
        guard var entry = entries[handle] else { return nil }
        if let deadline = entry.retryAt, deadline > now { return deadline }
        guard entry.failures < Self.delays.count else { entries[handle] = nil; return nil }
        entry.retryAt = now + Self.delays[entry.failures]
        entry.failures += 1
        entries[handle] = entry
        return entry.retryAt
    }
    var nextRetryAt: Int64? { entries.values.compactMap(\.retryAt).min() }
    mutating func takeDue(now: Int64) -> Set<UInt32> {
        let due = Set(entries.compactMap { $0.value.retryAt.map { $0 <= now } == true ? $0.key : nil })
        for id in due { entries[id]?.retryAt = nil }
        return due
    }
    @discardableResult mutating func remove(_ handle: UInt32) -> Bool { entries.removeValue(forKey: handle)?.retryAt != nil }
    mutating func retainOnly(_ handles: Set<UInt32>) { entries = entries.filter { handles.contains($0.key) } }
    mutating func clear() { entries.removeAll() }
}
