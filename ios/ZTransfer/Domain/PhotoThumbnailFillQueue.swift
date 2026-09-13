import Foundation

/// Priority queue used by the thumbnail fill pipeline.  It mirrors Android's
/// `ThumbnailFillQueue`: settled items survive a new scan, failed items are
/// kept out of the hot loop, and a retry only happens after an explicit wake.
actor PhotoThumbnailFillQueue {
    private var priority: [UInt32] = []
    private var regular: [UInt32] = []
    private var pending = Set<UInt32>()
    private var failed = Set<UInt32>()
    private var settled = Set<UInt32>()
    private var revision = 0
    // Android seeds the post-scan queue exactly once for each scan revision.
    // Keeping this guard is important because accepted metadata batches and
    // the final scan completion can both reach the fill pipeline.
    private var seededRevision = -1
    private var priorityRange: PhotoDateRange?

    func beginScan() {
        revision &+= 1
        priority.removeAll(keepingCapacity: true)
        regular.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        failed.removeAll(keepingCapacity: true)
        priorityRange = nil
    }

    func seed(_ files: [CameraFile], priorityRange: PhotoDateRange? = nil) {
        guard seededRevision != revision else { return }
        seededRevision = revision
        self.priorityRange = priorityRange
        let ordered = files.sorted { ($0.captureDate ?? "") > ($1.captureDate ?? "") }
        for file in ordered where !settled.contains(file.id) && !pending.contains(file.id) && !failed.contains(file.id) {
            enqueue(file.id, front: priorityRange?.contains(file.captureDate) == true)
        }
    }

    func enqueueNew(_ files: [CameraFile]) {
        for file in files where !settled.contains(file.id) { enqueue(file.id, front: true) }
    }

    func poll() -> UInt32? {
        if !priority.isEmpty { return removeFirst(&priority) }
        if !regular.isEmpty { return removeFirst(&regular) }
        return nil
    }

    func returnToFront(_ id: UInt32) {
        guard pending.contains(id) else { return }
        priority.removeAll { $0 == id }; regular.removeAll { $0 == id }
        priority.insert(id, at: 0)
    }

    func markSettled(_ id: UInt32) {
        pending.remove(id); failed.remove(id); priority.removeAll { $0 == id }; regular.removeAll { $0 == id }
        settled.insert(id)
    }

    func markFailed(_ id: UInt32) {
        pending.remove(id); priority.removeAll { $0 == id }; regular.removeAll { $0 == id }
        failed.insert(id)
    }

    func remove(_ ids: Set<UInt32>) {
        guard !ids.isEmpty else { return }
        priority.removeAll { ids.contains($0) }
        regular.removeAll { ids.contains($0) }
        pending.subtract(ids); failed.subtract(ids); settled.subtract(ids)
    }

    func retryFailed() {
        let ids = failed; failed.removeAll()
        for id in ids { enqueue(id, front: false) }
    }

    func updatePriorityRange(_ files: [CameraFile], range: PhotoDateRange?) {
        guard self.priorityRange != range else { return }
        self.priorityRange = range
        let ids = Set(files.filter { range?.contains($0.captureDate) == true }.map(\.id))
        let unfinished = priority + regular
        priority = unfinished.filter { ids.contains($0) }
        regular = unfinished.filter { !ids.contains($0) }
    }

    func state() -> (revision: Int, pending: Set<UInt32>, failed: Set<UInt32>, settled: Set<UInt32>) {
        (revision, pending, failed, settled)
    }

    private func enqueue(_ id: UInt32, front: Bool) {
        guard !pending.contains(id), !settled.contains(id) else { return }
        pending.insert(id)
        if front { priority.insert(id, at: 0) } else { regular.append(id) }
    }

    private func removeFirst(_ queue: inout [UInt32]) -> UInt32 {
        let id = queue.removeFirst()
        return id
    }
}
