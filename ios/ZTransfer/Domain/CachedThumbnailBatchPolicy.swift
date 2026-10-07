import Foundation

/// Per scan, owned by the list's MainActor accumulator. Android
/// CachedThumbnailBatchPolicy counts additions after dual-card deduplication.
struct CachedThumbnailBatchPolicy {
    private(set) var size = 12
    mutating func complete(count: Int, allCached: Bool) {
        size = allCached && count >= size ? min(size * 2, 48) : 12
    }
}
