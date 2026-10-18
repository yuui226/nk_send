import Foundation

/// Android RemoteReviewFrameGate: pause at transaction boundaries, keeping the
/// accepted packet alive. Cancelling a waiter must never cancel that packet.
@MainActor
final class RemoteReviewFrameGate {
    private var paused = false
    private var running = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func pause() { paused = true }
    func resume() { paused = false; notifyWaiters() }

    func awaitIdle() async throws {
        while running { try await waitForChange() }
        try Task.checkCancellation()
    }

    func withFrame<T>(_ operation: () async throws -> T) async throws -> T {
        while paused || running { try await waitForChange() }
        try Task.checkCancellation()
        running = true
        defer { running = false; notifyWaiters() }
        return try await operation()
    }

    private func waitForChange() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    private func notifyWaiters() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private let reviewJPEG: Set<String> = ["jpg", "jpeg"]
private let reviewRAW: Set<String> = ["nef", "nrw"]
private let reviewPhotosExtensions: Set<String> = ["jpg", "jpeg", "nef", "nrw", "tif", "tiff", "heif", "hif", "heic"]
private func reviewExtension(_ file: CameraFile) -> String {
    (file.fileName as NSString).pathExtension.lowercased()
}
private func reviewStem(_ file: CameraFile) -> String {
    (file.fileName as NSString).deletingPathExtension.lowercased()
}
private func reviewDate(_ file: CameraFile) -> String? {
    guard let date = file.captureDate?.trimmingCharacters(in: .whitespacesAndNewlines), !date.isEmpty else { return nil }
    return String(date.prefix(15))
}
private func reviewDatesCompatible(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return true }
    return a.hasPrefix(b) || b.hasPrefix(a)
}
private func reviewCompanions(_ a: CameraFile, _ b: CameraFile) -> Bool {
    guard reviewStem(a) == reviewStem(b), reviewDatesCompatible(reviewDate(a), reviewDate(b)) else { return false }
    return (reviewJPEG.contains(reviewExtension(a)) && reviewRAW.contains(reviewExtension(b))) ||
        (reviewRAW.contains(reviewExtension(a)) && reviewJPEG.contains(reviewExtension(b)))
}

/// Android RemoteReviewPhoto: stable first-handle identity, JPEG preferred for preview.
struct RemoteReviewPhoto: Identifiable, Equatable, Sendable {
    var files: [CameraFile]
    var id: UInt32 { files[0].id }
    var file: CameraFile { files.first { reviewJPEG.contains(reviewExtension($0)) } ?? files[0] }
    var pairedRawExtension: String? {
        guard reviewJPEG.contains(reviewExtension(file)) else { return nil }
        return files.first { reviewRAW.contains(reviewExtension($0)) }.map { "." + reviewExtension($0) }
    }
    var captureDate: String? { files.compactMap(reviewDate).max { $0.count < $1.count } }
    func canPair(_ file: CameraFile) -> Bool {
        guard reviewDatesCompatible(captureDate, reviewDate(file)) else { return false }
        let ext = reviewExtension(file)
        let family: Set<String>
        if reviewJPEG.contains(ext) { family = reviewJPEG }
        else if reviewRAW.contains(ext) { family = reviewRAW }
        else { return false }
        return !files.contains { family.contains(reviewExtension($0)) } &&
            files.contains { reviewCompanions($0, file) }
    }
}

private struct ReviewPhotos {
    var photos: [RemoteReviewPhoto] = []
    private var indicesByStem: [String: [Int]] = [:]
    private var handles: Set<UInt32> = []

    mutating func add(_ files: [CameraFile]) {
        for file in files {
            guard reviewPhotosExtensions.contains(reviewExtension(file)), handles.insert(file.id).inserted else { continue }
            let stem = reviewStem(file)
            let indices = indicesByStem[stem] ?? []
            let dated = reviewDate(file).map { date in indices.filter { photos[$0].captureDate == date } } ?? []
            let candidates = dated.isEmpty ? indices.filter { photos[$0].canPair(file) } : dated
            if candidates.count == 1 {
                photos[candidates[0]].files.append(file)
            } else {
                indicesByStem[stem, default: []].append(photos.count)
                photos.append(RemoteReviewPhoto(files: [file]))
            }
        }
    }
}
func reviewPhotos(_ files: [CameraFile]) -> [RemoteReviewPhoto] {
    var result = ReviewPhotos()
    result.add(files)
    return result.photos
}

/// Frozen per-card handle streams, lazy metadata, whole timestamp groups before publication.
/// Actor reentrancy is explicitly serialized across suspended camera reads.
actor RemoteReviewCatalog {
    private let handles: [[UInt32]]
    private let readFile: @Sendable (UInt32) async throws -> CameraFile?
    private var cursors: [Int]
    private var heads: [CameraFile?]
    private var published = ReviewPhotos()
    private var pending: [CameraFile] = []
    // A long burst can share one timestamp. Cache the pending group's date and
    // same-name candidates instead of rescanning the entire burst per handle.
    private var pendingDate: String?
    private var pendingByStem: [String: [CameraFile]] = [:]
    private(set) var hasMore = true
    private var loading = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(handlesByStorage: [[UInt32]], readFile: @escaping @Sendable (UInt32) async throws -> CameraFile?) {
        handles = handlesByStorage
        cursors = Array(repeating: 0, count: handlesByStorage.count)
        heads = Array(repeating: nil, count: handlesByStorage.count)
        self.readFile = readFile
    }
    private func companion(_ file: CameraFile) -> Bool {
        reviewDatesCompatible(pendingDate, reviewDate(file)) &&
            (pendingByStem[reviewStem(file)]?.contains { reviewCompanions($0, file) } ?? false)
    }
    private func peek() async throws -> (Int, CameraFile)? {
        for slot in handles.indices {
            while heads[slot] == nil && cursors[slot] < handles[slot].count {
                try Task.checkCancellation()
                let file = try await readFile(handles[slot][cursors[slot]])
                // Failed/cancelled reads leave the cursor retryable.
                cursors[slot] += 1
                heads[slot] = file
            }
        }
        let partner = heads.firstIndex { $0.map(companion) ?? false }
        guard let slot = partner ?? selectNewestPhotoHeadIndex(heads), let head = heads[slot] else { return nil }
        return (slot, head)
    }
    private func acquireRead() async throws {
        try Task.checkCancellation()
        if !loading { loading = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    func loadNextPage(pageSize: Int = 12) async throws -> [RemoteReviewPhoto] {
        precondition(pageSize > 0)
        try await acquireRead()
        defer {
            if waiters.isEmpty { loading = false }
            else { waiters.removeFirst().1.resume() }
        }
        try Task.checkCancellation()
        let target = published.photos.count + pageSize
        while hasMore && published.photos.count < target {
            while true {
                let next = try await peek()
                let date = pendingDate
                let same = next.map { pending.isEmpty || (date != nil && date == reviewDate($0.1)) || companion($0.1) } ?? false
                if !same {
                    published.add(pending)
                    pending.removeAll(keepingCapacity: true)
                    pendingDate = nil
                    pendingByStem.removeAll(keepingCapacity: true)
                    if next == nil { hasMore = false }
                    break
                }
                if let (slot, file) = next {
                    pending.append(file)
                    pendingByStem[reviewStem(file), default: []].append(file)
                    if let date = reviewDate(file), pendingDate == nil || date.count > pendingDate!.count {
                        pendingDate = date
                    }
                    heads[slot] = nil
                }
            }
        }
        return published.photos
    }
}
