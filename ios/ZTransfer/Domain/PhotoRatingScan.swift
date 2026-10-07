import Foundation
import Combine

private final class PhotoRatingDiagnosticsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var enabled = false
    private let maxEntries = 48
    private let maxCharacters = 8_000

    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = value
        if !value { entries.removeAll(keepingCapacity: true) }
    }

    func note(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        let normalized = message.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .prefix(260)
        entries.append(String(normalized))
        while entries.count > maxEntries || entries.reduce(0, { $0 + $1.count + 1 }) > maxCharacters {
            guard !entries.isEmpty else { break }
            entries.removeFirst()
        }
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !entries.isEmpty else { return "评级筛选：暂无诊断记录" }
        return "ZTransfer 评级筛选诊断\n" + entries.joined(separator: "\n")
    }
}

enum PhotoRatingDiagnostics {
    private static let store = PhotoRatingDiagnosticsStore()
    static func setEnabled(_ enabled: Bool) { store.setEnabled(enabled) }
    static func note(_ message: String) { store.note(message) }
    static func snapshot() -> String { store.snapshot() }
}

/// A completed rating keeps the distinction between a confirmed value and an
/// inspected file whose rating is unknown.  Swift dictionaries cannot store a
/// nil value as a present entry, so the explicit case preserves Android's
/// `Map<Int, Int?>` semantics for progress and filtering.
enum PhotoRatingValue: Equatable, Sendable {
    case known(Int)
    case unknown
}

struct PhotoRatingScan: Equatable, Sendable {
    var values: [UInt32: PhotoRatingValue] = [:]
    var loading = false
    var completed = 0
    var total = 0
    var complete = false
    var waitingForRange = false
}

struct PhotoRatingCacheEntry: Equatable, Sendable {
    let value: Int
    let origin: String
}

/// Connection-scoped decoded-value cache.  The explicit order array keeps the
/// eviction policy FIFO even if Dictionary's storage implementation changes.
struct PhotoRatingCache: Sendable {
    private(set) var generation = 0
    private var values: [UInt32: PhotoRatingCacheEntry] = [:]
    private var order: [UInt32] = []

    var count: Int { values.count }

    mutating func invalidate() -> Int {
        values.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        generation &+= 1
        return generation
    }

    func value(for handle: UInt32) -> PhotoRatingCacheEntry? { values[handle] }

    mutating func remember(handle: UInt32, value: Int, origin: String, generation: Int) {
        guard generation == self.generation else { return }
        if values[handle] == nil { order.append(handle) }
        values[handle] = PhotoRatingCacheEntry(value: value, origin: origin)
        while order.count > 8192 {
            let oldest = order.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }
}

/// The small, connection-scoped seam used by the lifecycle controller.  The
/// production initializer below maps every operation to CameraSession; tests
/// can replay Android's scan lifecycle without a live PTP transport.
struct PhotoRatingScanIO: Sendable {
    let generation: @Sendable () async -> Int
    let invalidate: @Sendable () async -> Int
    let cached: @Sendable (UInt32) async -> PhotoRatingCacheEntry?
    let beginPhase: @Sendable () async -> Void
    let endPhase: @Sendable () async -> Void
    let read: @Sendable (CameraFile, Bool) async throws -> Int?

    init(
        generation: @escaping @Sendable () async -> Int,
        invalidate: @escaping @Sendable () async -> Int,
        cached: @escaping @Sendable (UInt32) async -> PhotoRatingCacheEntry?,
        beginPhase: @escaping @Sendable () async -> Void,
        endPhase: @escaping @Sendable () async -> Void,
        read: @escaping @Sendable (CameraFile, Bool) async throws -> Int?
    ) {
        self.generation = generation
        self.invalidate = invalidate
        self.cached = cached
        self.beginPhase = beginPhase
        self.endPhase = endPhase
        self.read = read
    }
}

extension PhotoRatingScanIO {
    static let noop = PhotoRatingScanIO(
        generation: { 0 },
        invalidate: { 0 },
        cached: { _ in nil },
        beginPhase: {},
        endPhase: {},
        read: { _, _ in nil }
    )

    init(session: CameraSession) {
        self.init(
            generation: { await session.photoRatingGeneration() },
            invalidate: { await session.invalidatePhotoRatings() },
            cached: { handle in
                guard let value = await session.cachedPhotoRating(handle) else { return nil }
                return PhotoRatingCacheEntry(
                    value: value,
                    origin: await session.cachedPhotoRatingOrigin(handle) ?? "unknown"
                )
            },
            beginPhase: { await session.beginRatingPhase() },
            endPhase: { await session.endRatingPhase() },
            read: { file, useObject in
                if useObject { return try await session.readObjectOrRawHeaderRating(file: file) }
                switch file.fileExtension {
                case ".jpg", ".jpeg", ".nef", ".nrw":
                    return try await session.readPhotoRatingHeader(file: file)
                default:
                    return try await session.readVideoRating(file: file)
                }
            }
        )
    }
}

struct PhotoRatingScanInput: Sendable, Equatable {
    let files: [CameraFile]
    let paused: Bool
    let useObjectRating: Bool
    let staConnection: Bool
    let listLoading: Bool
    let recentThumbnailReadyDays: Int
    let ratingDays: Int
    let photoLoadingDays: Int

    init(files: [CameraFile], paused: Bool, useObjectRating: Bool,
         staConnection: Bool, listLoading: Bool, recentThumbnailReadyDays: Int,
         ratingDays: Int, photoLoadingDays: Int) {
        self.files = files
        self.paused = paused
        self.useObjectRating = useObjectRating
        self.staConnection = staConnection
        self.listLoading = listLoading
        self.recentThumbnailReadyDays = recentThumbnailReadyDays
        self.ratingDays = ratingDays
        self.photoLoadingDays = photoLoadingDays
    }
}

enum PhotoRatingScanPolicy {
    static let fileExtensions: Set<String> = [".jpg", ".jpeg", ".nef", ".nrw", ".mov", ".mp4"]
    static let stillExtensions: Set<String> = [".jpg", ".jpeg", ".nef", ".nrw"]

    static func effectiveDays(ratingDays: Int, photoLoadingDays: Int) -> Int {
        switch (ratingDays, photoLoadingDays) {
        case (0, let photo) where photo > 0: return photo
        case (let rating, 0) where rating > 0: return rating
        case (0, 0): return 0
        default: return min(ratingDays, photoLoadingDays)
        }
    }

    /// Android deliberately uses the catalog's first eight characters here,
    /// without validating a calendar date. Invalid dates therefore retain the
    /// same scan boundary behavior as the source implementation.
    static func dates(_ files: [CameraFile], limit: Int = 0) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for file in files {
            guard let raw = file.captureDate, raw.count >= 8 else { continue }
            let day = String(raw.prefix(8))
            guard seen.insert(day).inserted else { continue }
            result.append(day)
            if limit > 0, result.count == limit { break }
        }
        return result
    }

    static func ratingFiles(_ files: [CameraFile]) -> [CameraFile] {
        files.filter { fileExtensions.contains($0.fileExtension) }
    }

    static func eligibleFiles(_ files: [CameraFile], staConnection: Bool,
                              effectiveDays: Int, sessionHandles: Set<UInt32>,
                              sessionInitialized: Bool) -> [CameraFile] {
        let photos = ratingFiles(files).filter { !sessionInitialized || sessionHandles.contains($0.id) }
        guard staConnection else { return photos }
        let selectedDays = dates(photos, limit: effectiveDays)
        guard let cutoff = selectedDays.last else { return [] }
        return photos.filter { file in
            guard let captureDate = file.captureDate, captureDate.count >= 8 else { return false }
            return String(captureDate.prefix(8)) >= cutoff
        }
    }

    static func rangeReady(_ input: PhotoRatingScanInput, effectiveDays: Int) -> Bool {
        guard input.staConnection else { return true }
        let knownDates = dates(input.files).count
        if effectiveDays == 0 {
            return !input.listLoading && (knownDates == 0 || input.recentThumbnailReadyDays >= knownDates)
        }
        return input.recentThumbnailReadyDays >= effectiveDays ||
            (!input.listLoading && knownDates < effectiveDays)
    }
}

/// Android's `rememberPhotoRatings` lifecycle expressed as a reusable model.
/// It owns one connection snapshot, reads one unique JPEG/RAW source at a
/// time, publishes after every file, and never lets a cancelled generation
/// write into the next scan.
@MainActor
final class PhotoRatingScanController: ObservableObject {
    @Published private(set) var state = PhotoRatingScan()

    private let io: PhotoRatingScanIO
    private var latestInput: PhotoRatingScanInput?
    private var enabled = false
    private var previousEnabled = false
    private var generation = -1
    private var generationReady = false
    private var clearedGeneration: Int?
    private var sessionHandles = Set<UInt32>()
    private var sessionInitialized = false
    private var scanStarted = false
    private var localRatings = [UInt32: PhotoRatingValue]()
    private var evaluationTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var phaseStarted = false
    private var revision = 0

    init(io: PhotoRatingScanIO) { self.io = io }

    deinit {
        evaluationTask?.cancel()
        scanTask?.cancel()
    }

    /// Called by the photo-list owner whenever catalog, loading, pause or
    /// range state changes. Once the date snapshot is locked and reads begin,
    /// later thumbnail/catalog emissions are intentionally ignored.
    func update(_ input: PhotoRatingScanInput, enabled: Bool) {
        latestInput = input
        if !enabled {
            disable()
            return
        }
        PhotoRatingDiagnostics.setEnabled(true)
        self.enabled = true
        if !previousEnabled {
            previousEnabled = true
            beginFreshGeneration()
        }
        guard !scanStarted else { return }
        scheduleEvaluation()
    }

    func cancel() {
        revision &+= 1
        enabled = false
        previousEnabled = false
        generationReady = false
        scanStarted = false
        evaluationTask?.cancel(); evaluationTask = nil
        scanTask?.cancel(); scanTask = nil
        sessionHandles.removeAll()
        sessionInitialized = false
        localRatings.removeAll()
        phaseStarted = false
        state = PhotoRatingScan()
    }

    private func disable() {
        revision &+= 1
        enabled = false
        previousEnabled = false
        generationReady = false
        evaluationTask?.cancel(); evaluationTask = nil
        scanTask?.cancel(); scanTask = nil
        phaseStarted = false
        sessionHandles.removeAll()
        sessionInitialized = false
        scanStarted = false
        localRatings.removeAll()
        state = PhotoRatingScan()
        PhotoRatingDiagnostics.setEnabled(false)
        let expected = generation
        guard clearedGeneration != expected else { return }
        clearedGeneration = expected
        Task { [io] in _ = await io.invalidate() }
    }

    private func beginFreshGeneration() {
        revision &+= 1
        evaluationTask?.cancel(); evaluationTask = nil
        scanTask?.cancel(); scanTask = nil
        phaseStarted = false
        sessionHandles.removeAll()
        sessionInitialized = false
        scanStarted = false
        generationReady = false
        localRatings.removeAll()
        state = PhotoRatingScan(loading: true, waitingForRange: latestInput?.staConnection == true)
        PhotoRatingDiagnostics.note("scan generation pending source=\(latestInput?.useObjectRating == true ? "object" : "header")")
        let token = revision
        evaluationTask = Task { [weak self, io] in
            let generation = await io.invalidate()
            guard let self, self.revision == token, self.enabled else { return }
            self.generation = generation
            self.generationReady = true
            self.clearedGeneration = nil
            self.evaluationTask = nil
            self.scheduleEvaluation()
        }
    }

    private func scheduleEvaluation() {
        guard evaluationTask == nil, !scanStarted, enabled, generationReady else { return }
        let token = revision
        evaluationTask = Task { [weak self] in
            guard let self else { return }
            await self.evaluate(token: token)
        }
    }

    private func evaluate(token: Int) async {
        defer { evaluationTask = nil }
        guard token == revision, enabled, generationReady, !scanStarted, let input = latestInput else { return }
        let effectiveDays = PhotoRatingScanPolicy.effectiveDays(
            ratingDays: input.ratingDays, photoLoadingDays: input.photoLoadingDays
        )
        guard PhotoRatingScanPolicy.rangeReady(input, effectiveDays: effectiveDays) else {
            state = PhotoRatingScan(loading: true,
                                    total: PhotoRatingScanPolicy.ratingFiles(input.files).count,
                                    waitingForRange: true)
            return
        }
        if input.files.isEmpty {
            sessionHandles.removeAll(); sessionInitialized = false; localRatings.removeAll()
        } else if !sessionInitialized && !input.paused {
            sessionHandles.formUnion(input.files.map(\.id))
            let dateCount = PhotoRatingScanPolicy.dates(input.files).count
            sessionInitialized = effectiveDays == 0 || dateCount >= effectiveDays || !input.listLoading
        }
        let eligible = PhotoRatingScanPolicy.eligibleFiles(
            input.files, staConnection: input.staConnection,
            effectiveDays: effectiveDays, sessionHandles: sessionHandles,
            sessionInitialized: sessionInitialized
        )
        if input.staConnection && effectiveDays > 0 &&
            PhotoRatingScanPolicy.dates(eligible).count < effectiveDays && input.listLoading {
            state = PhotoRatingScan(loading: true,
                                    total: PhotoRatingScanPolicy.ratingFiles(eligible).count,
                                    waitingForRange: true)
            return
        }
        let sources = photoRatingSources(eligible)
        var seenSources = Set<UInt32>()
        let uniqueSources = sources.values.filter { file in
            seenSources.insert(file.id).inserted
        }
        localRatings = localRatings.filter { entry in
            sources.values.contains(where: { $0.id == entry.key })
        }
        for file in uniqueSources where localRatings[file.id] == nil {
            if let cached = await io.cached(file.id) {
                localRatings[file.id] = .known(cached.value)
            }
        }
        guard token == revision, enabled, !scanStarted else { return }
        publish(sources: sources, eligible: eligible, loading: !uniqueSources.isEmpty,
                complete: uniqueSources.isEmpty ? false : uniqueSources.allSatisfy { localRatings[$0.id] != nil })
        let pending = uniqueSources.filter { localRatings[$0.id] == nil }
        PhotoRatingDiagnostics.note("scan generation=\(generation) files=\(eligible.count) sources=\(uniqueSources.count) pending=\(pending.count)")
        if pending.isEmpty {
            scanStarted = true
            publish(sources: sources, eligible: eligible, loading: false, complete: !uniqueSources.isEmpty)
            return
        }
        guard !input.paused else { return }
        scanStarted = true
        startReading(pending: pending, sources: sources, eligible: eligible,
                    input: input, token: token)
    }

    private func publish(sources: [UInt32: CameraFile], eligible: [CameraFile],
                         loading: Bool, complete: Bool) {
        var visible: [UInt32: PhotoRatingValue] = [:]
        for (handle, source) in sources where localRatings[source.id] != nil {
            visible[handle] = localRatings[source.id]
        }
        state = PhotoRatingScan(
            values: visible,
            loading: loading,
            completed: sources.values.reduce(0) { $0 + (localRatings[$1.id] == nil ? 0 : 1) },
            total: PhotoRatingScanPolicy.ratingFiles(eligible).count,
            complete: complete,
            waitingForRange: false
        )
    }

    private func startReading(pending: [CameraFile], sources: [UInt32: CameraFile],
                              eligible: [CameraFile], input: PhotoRatingScanInput,
                              token: Int) {
        scanTask = Task { [weak self, io] in
            guard let self else { return }
            var cancelled = false
            var didBeginPhase = false
            do {
                await io.beginPhase()
                didBeginPhase = true
                await MainActor.run { self.phaseStarted = true }
                for file in pending {
                    try Task.checkCancellation()
                    let value = try await io.read(file, input.useObjectRating)
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard self.revision == token, self.enabled else { return }
                        self.localRatings[file.id] = value.map(PhotoRatingValue.known) ?? .unknown
                        self.publish(sources: sources, eligible: eligible, loading: true, complete: false)
                        PhotoRatingDiagnostics.note("progress=\(self.state.completed)/\(self.state.total) active=\(file.fileName)")
                    }
                }
            } catch is CancellationError {
                cancelled = true
            } catch {
                // A transport error stops this pass without taking down the
                // list, matching Android's exception boundary.
            }
            if didBeginPhase { await io.endPhase() }
            await MainActor.run {
                self.phaseStarted = false
                self.scanTask = nil
                guard !cancelled, self.revision == token, self.enabled else { return }
                let complete = self.localRatings.count >= sources.values.count && !sources.isEmpty
                self.publish(sources: sources, eligible: eligible, loading: false, complete: complete)
                PhotoRatingDiagnostics.note("complete=\(self.state.completed)/\(self.state.total)")
            }
        }
    }
}
