import Foundation

/// Priority queue used by the thumbnail fill pipeline.  It mirrors Android's
/// `ThumbnailFillQueue`: settled items survive a new scan, failed items are
/// kept out of the hot loop, and a retry only happens after an explicit wake.
actor PhotoThumbnailFillQueue {
    private var priority: [UInt32] = []
    private var regular: [UInt32] = []
    private var pending = Set<UInt32>()
    private var failed = Set<UInt32>()
    private var failedOrder: [UInt32] = []
    private var settled = Set<UInt32>()
    private var filesByID: [UInt32: CameraFile] = [:]
    private var revision = 0
    // Android seeds the post-scan queue exactly once for each scan revision.
    // Keeping this guard is important because accepted metadata batches and
    // the final scan completion can both reach the fill pipeline.
    private var seededRevision = -1
    private var priorityRange: PhotoDateRange?
    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    init() {
        var continuation: AsyncStream<Void>.Continuation?
        wakeStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { streamContinuation in
            continuation = streamContinuation
        }
        wakeContinuation = continuation!
    }

    /// Mirrors Android's conflated `thumbnailFillWake` channel.  A worker
    /// waits here when the queue is empty instead of exiting, so a later
    /// object event, filter change, or foreground-owner release resumes the
    /// same fill lifecycle.
    func wake() {
        wakeContinuation.yield(())
    }

    func waitForWake() async {
        var iterator = wakeStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func beginScan() {
        revision &+= 1
        priority.removeAll(keepingCapacity: true)
        regular.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        failed.removeAll(keepingCapacity: true)
        failedOrder.removeAll(keepingCapacity: true)
        priorityRange = nil
    }

    func seed(_ files: [CameraFile], priorityRange: PhotoDateRange? = nil) {
        guard seededRevision != revision else { return }
        seededRevision = revision
        for file in files { filesByID[file.id] = file }
        self.priorityRange = priorityRange
        let ordered = stableNewestFirst(files)
        for file in ordered where !settled.contains(file.id) && !pending.contains(file.id) && !failed.contains(file.id) {
            enqueue(file.id, priority: priorityRange?.contains(file.captureDate) == true, front: false)
        }
    }

    func enqueueNew(_ files: [CameraFile]) {
        for file in files { filesByID[file.id] = file }
        for file in files where !settled.contains(file.id) {
            enqueue(file.id, priority: priorityRange?.contains(file.captureDate) == true, front: true)
        }
    }

    func poll() -> UInt32? {
        let id: UInt32?
        if !priority.isEmpty { id = removeFirst(&priority) }
        else if !regular.isEmpty { id = removeFirst(&regular) }
        else { id = nil }
        if let id { pending.remove(id) }
        return id
    }

    func returnToFront(_ id: UInt32) {
        guard !settled.contains(id), !failed.contains(id) else { return }
        priority.removeAll { $0 == id }; regular.removeAll { $0 == id }
        pending.insert(id)
        if priorityRange?.contains(filesByID[id]?.captureDate) == true {
            priority.insert(id, at: 0)
        } else {
            regular.insert(id, at: 0)
        }
    }

    func markSettled(_ id: UInt32) {
        pending.remove(id); failed.remove(id); priority.removeAll { $0 == id }; regular.removeAll { $0 == id }
        failedOrder.removeAll { $0 == id }
        settled.insert(id)
    }

    func markFailed(_ id: UInt32) {
        pending.remove(id); priority.removeAll { $0 == id }; regular.removeAll { $0 == id }
        if failed.insert(id).inserted { failedOrder.append(id) }
    }

    func remove(_ ids: Set<UInt32>) {
        guard !ids.isEmpty else { return }
        priority.removeAll { ids.contains($0) }
        regular.removeAll { ids.contains($0) }
        pending.subtract(ids); failed.subtract(ids); settled.subtract(ids)
        failedOrder.removeAll { ids.contains($0) }
        ids.forEach { filesByID.removeValue(forKey: $0) }
    }

    func retryFailed() {
        // Android keeps the failure insertion order for equal capture times;
        // Swift's standard sort is not stable, so preserve the explicit order.
        let files = stableNewestFirst(failedOrder.compactMap { filesByID[$0] })
        failed.removeAll(); failedOrder.removeAll()
        for file in files {
            enqueue(file.id, priority: priorityRange?.contains(file.captureDate) == true, front: false)
        }
    }

    func updatePriorityRange(_ files: [CameraFile], range: PhotoDateRange?) {
        guard self.priorityRange != range else { return }
        for file in files { filesByID[file.id] = file }
        self.priorityRange = range
        let unfinished = stableNewestFirst((priority + regular).compactMap { filesByID[$0] })
        priority = unfinished.filter { range?.contains($0.captureDate) == true }.map(\.id)
        regular = unfinished.filter { range?.contains($0.captureDate) != true }.map(\.id)
        pending = Set(unfinished.map(\.id))
    }

    func state() -> (revision: Int, pending: Set<UInt32>, failed: Set<UInt32>, settled: Set<UInt32>) {
        (revision, pending, failed, settled)
    }

    private func enqueue(_ id: UInt32, priority: Bool, front: Bool) {
        guard !pending.contains(id), !settled.contains(id) else { return }
        pending.insert(id)
        if priority {
            if front { self.priority.insert(id, at: 0) } else { self.priority.append(id) }
        } else {
            if front { regular.insert(id, at: 0) } else { regular.append(id) }
        }
    }

    private func removeFirst(_ queue: inout [UInt32]) -> UInt32 {
        let id = queue.removeFirst()
        return id
    }

    /// Android's `prioritizedThumbnailFiles` uses a stable newest-first sort.
    /// The original array order is meaningful for same-time JPG/RAW pairs and
    /// must survive the sort on platforms whose standard sort is unstable.
    private func stableNewestFirst(_ files: [CameraFile]) -> [CameraFile] {
        files.enumerated().sorted { lhs, rhs in
            let left = lhs.element.captureDate ?? ""
            let right = rhs.element.captureDate ?? ""
            if left != right { return left > right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
