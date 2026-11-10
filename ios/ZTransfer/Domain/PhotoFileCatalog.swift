import Foundation

/// FileListScreen.buildThumbnailGridItems: preserve filtered catalog order
/// while grouping directly, without per-file tuples and intermediate arrays.
/// Lists and previews reuse only this projection, never their expansion state.
func visiblePhotoBurstMembers(files: [CameraFile], burstIDs: [UInt32: String]) -> [String: [CameraFile]] {
    guard !files.isEmpty, !burstIDs.isEmpty else { return [:] }
    var result: [String: [CameraFile]] = [:]
    for file in files {
        guard let id = burstIDs[file.id] else { continue }
        result[id, default: []].append(file)
    }
    return result
}

/// Ordered published catalog with a current-handle lookup. Android's fill
/// queue carries indexed FileInfo; iOS resolves the current row so a removal
/// or handle reuse cannot leave background work reading a stale snapshot.
struct PhotoFileCatalog: Sendable {
    private(set) var files: [CameraFile] = []
    private var positions: [UInt32: Int] = [:]
    private var loadingRangeCache: (days: Int, value: PhotoDateRange?)?
    #if DEBUG
    private(set) var loadingRangeBuildCount = 0
    #endif

    /// A thumbnail batch checks admission after every suspension. Reuse the
    /// date projection until either input changes, instead of sorting the full
    /// catalog once per image. A cached nil is also a completed computation.
    mutating func loadingRange(days: Int) -> PhotoDateRange? {
        guard days > 0 else { return nil }
        if let cached = loadingRangeCache, cached.days == days { return cached.value }
        let value = newestCaptureDaysRange(files, days: days)
        loadingRangeCache = (days, value)
        #if DEBUG
        loadingRangeBuildCount += 1
        #endif
        return value
    }

    func file(for handle: UInt32) -> CameraFile? {
        positions[handle].map { files[$0] }
    }

    mutating func replaceAll(_ files: [CameraFile]) {
        loadingRangeCache = nil
        self.files = files
        positions.removeAll(keepingCapacity: true)
        positions.reserveCapacity(files.count)
        for (index, file) in files.enumerated() where positions[file.id] == nil {
            positions[file.id] = index
        }
    }

    mutating func upsert(_ file: CameraFile) {
        if let position = positions[file.id] {
            if files[position] != file {
                if files[position].captureDate != file.captureDate { loadingRangeCache = nil }
                files[position] = file
            }
        } else {
            loadingRangeCache = nil
            positions[file.id] = files.count
            files.append(file)
        }
    }

    mutating func clear() {
        loadingRangeCache = nil
        files.removeAll(keepingCapacity: true)
        positions.removeAll(keepingCapacity: true)
    }
}
