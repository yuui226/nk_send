import Foundation

actor ThumbnailCache {
    private let maxEntries: Int
    private let maxBytes: Int
    private var values: [String: Data] = [:]
    private var order: [String] = []
    private var totalBytes = 0

    init(maxEntries: Int = 80, maxBytes: Int = 20 * 1024 * 1024) {
        self.maxEntries = maxEntries; self.maxBytes = maxBytes
    }

    func value(for key: String) -> Data? {
        guard let value = values[key] else { return nil }
        touch(key); return value
    }

    func insert(_ value: Data, for key: String) {
        if let old = values.updateValue(value, forKey: key) { totalBytes -= old.count }
        totalBytes += value.count; touch(key)
        while values.count > maxEntries || totalBytes > maxBytes {
            guard let oldest = order.first, let removed = values.removeValue(forKey: oldest) else { break }
            order.removeFirst(); totalBytes -= removed.count
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }; order.append(key)
    }
}
