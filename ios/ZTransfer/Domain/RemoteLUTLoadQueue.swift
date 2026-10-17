import Foundation

actor RemoteLUTLoadQueue {
    private var generation: UInt64 = 0
    private var task: Task<CubeLUT?, Never>?

    func load(data: Data, parser: @escaping @Sendable (Data) -> CubeLUT?) async -> CubeLUT? {
        generation &+= 1
        let current = generation
        task?.cancel()
        let next = Task { parser(data) }
        task = next
        let result = await next.value
        guard current == generation, !Task.isCancelled else { return nil }
        return result
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}

/// Shared photo/monitor parsed-table budget; it never shares selection state.
final class ParsedLUTCache: @unchecked Sendable {
    static let shared = ParsedLUTCache()
    struct Stamp: Equatable { let size: Int64?; let modified: Date? }
    private struct Entry { let stamp: Stamp; let table: CubeLUT }
    private let lock = NSLock()
    private let budget: Int
    private let maxEntries: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var bytes = 0

    init(budget: Int = 8 * 1024 * 1024, maxEntries: Int = 16) {
        self.budget = budget
        self.maxEntries = maxEntries
    }
    func get(_ key: String, stamp: Stamp) -> CubeLUT? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard stamp.size != nil, stamp.modified != nil, entry.stamp == stamp else {
            removeLocked(key)
            return nil
        }
        order.removeAll { $0 == key }; order.append(key)
        return entry.table
    }
    func put(_ key: String, stamp: Stamp, table: CubeLUT) {
        lock.lock(); defer { lock.unlock() }
        removeLocked(key)
        guard let size = stamp.size, size > 0, let modified = stamp.modified,
              modified.timeIntervalSince1970 > 0, maxEntries > 0 else { return }
        let weight = table.rgb.count * MemoryLayout<Float>.stride
        guard weight <= budget else { return }
        while bytes + weight > budget || entries.count >= maxEntries {
            guard let oldest = order.first else { break }
            removeLocked(oldest)
        }
        entries[key] = Entry(stamp: stamp, table: table)
        order.append(key)
        bytes += weight
    }
    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        removeLocked(key)
    }
    private func removeLocked(_ key: String) {
        if let old = entries.removeValue(forKey: key) { bytes -= old.table.rgb.count * MemoryLayout<Float>.stride }
        order.removeAll { $0 == key }
    }
}
