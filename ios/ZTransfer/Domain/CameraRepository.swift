import Foundation
import CryptoKit

private final class ProtectionHeaderProbeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt32: Data] = [:]

    func value(for handle: UInt32) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[handle]
    }

    func save(_ data: Data, for handle: UInt32) {
        lock.lock(); defer { lock.unlock() }
        values[handle] = data
    }
}

func keepsPartialOnCancellation(fileName: String) -> Bool {
    ["mov", "mp4", "nev", "avi"].contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
}

/// Android's resumable video set; still images intentionally use one-shot
/// transfer semantics unless a transport explicitly forces partial reads.
func supportsVideoResume(fileName: String) -> Bool {
    keepsPartialOnCancellation(fileName: fileName)
}

/// Android rejects placeholder serials before selecting the physical
/// transport identity. Keep the same rule so cameras that report an empty or
/// synthetic DeviceInfo serial still share their own thumbnail cache.
func normalizedCameraIdentifier(_ value: String?) -> String? {
    guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !normalized.isEmpty else { return nil }
    switch normalized.lowercased() {
    case "unknown", "none", "null", "n/a": return nil
    default: break
    }
    let hasIdentityCharacter = normalized.unicodeScalars.contains { scalar in
        scalar.properties.isAlphabetic ||
            // Android compares the character to the ASCII literal '0'; retain
            // that exact placeholder rule rather than normalizing digit value.
            (scalar.properties.numericType == .decimal && scalar.value != 0x30)
    }
    return hasIdentityCharacter ? normalized : nil
}

func cameraThumbnailCacheIdentity(deviceInfo: PTPDeviceInfo?, transportIdentifier: String?) -> String {
    let manufacturer = deviceInfo?.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let model = deviceInfo?.model.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let physicalID = normalizedCameraIdentifier(deviceInfo?.serialNumber)
        ?? normalizedCameraIdentifier(transportIdentifier)
        ?? "unknown-device"
    return "\(manufacturer)\u{0}\(model)\u{0}\(physicalID)"
}

#if DEBUG
private struct DebugNullTransport: PTPCommandTransport {
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) { (Data(), Data()) }
}
#endif

let transferResumeChunkSize: UInt64 = 4 * 1024 * 1024

func transferPartialFileName(size: UInt64, captureDate: String?, fileName: String) -> String {
    let token = "\(size).\(captureDate ?? "0")"
        .replacingOccurrences(of: "[^A-Za-z0-9.]", with: "", options: .regularExpression)
    let safeName = URL(fileURLWithPath: fileName).lastPathComponent
    return ".nkpart_\(token)_\(safeName)"
}

let transferChunkSize: UInt64 = 4 * 1024 * 1024
let transferLargeFileThreshold: UInt64 = 512 * 1024 * 1024
let transferHighThroughputThreshold: UInt64 = 128 * 1024 * 1024
let transferHighThroughputChunkSize: UInt64 = 64 * 1024 * 1024
let transferLargeFileChunkSize: UInt64 = 32 * 1024 * 1024

/// Direct Swift equivalent of Android's shouldUsePartialObjectDownload.
func shouldUsePartialObjectDownload(
    partialObjectSupported: Bool?,
    effectiveSize: UInt64,
    resumeOffset: UInt64 = 0,
    isUSBConnection: Bool = false,
    preferHighThroughput: Bool = false,
    forcePartial: Bool = false,
    videoTransfer: Bool = true,
) -> Bool {
    partialObjectSupported != false &&
        effectiveSize > 0 && effectiveSize != UInt64(UInt32.max) &&
        (forcePartial || (videoTransfer && (!(isUSBConnection || preferHighThroughput) ||
         resumeOffset > 0 || effectiveSize > transferHighThroughputThreshold)))
}

func transferDownloadChunkSize(
    effectiveSize: UInt64,
    isUSBConnection: Bool = false,
    preferHighThroughput: Bool = false,
    videoTransfer: Bool = true,
) -> UInt64 {
    // ImageCaptureCore's PTP pass-through callback materializes the complete
    // data phase as one Data value; unlike Android's raw bulk endpoint it
    // cannot stream a 64 MiB request directly into the destination file.
    // Keep USB chunks bounded to avoid a callback-sized memory spike.
    if isUSBConnection { return transferChunkSize }
    // Android requests a still image in one transaction, even on STA's
    // forced-partial route. Page throughput only changes video chunking.
    if !videoTransfer { return effectiveSize }
    if preferHighThroughput { return transferHighThroughputChunkSize }
    return effectiveSize > transferLargeFileThreshold ? transferLargeFileChunkSize : transferChunkSize
}

func transferResumeOffset(existingSize: UInt64, totalSize: UInt64, reportedSize: UInt64) -> UInt64? {
    let known = reportedSize > 0 && reportedSize != UInt64(UInt32.max)
    if known && existingSize == totalSize { return totalSize }
    guard existingSize >= transferResumeChunkSize else { return nil }
    guard !known || existingSize < totalSize else { return nil }
    return (existingSize / transferResumeChunkSize) * transferResumeChunkSize
}

/// Android reserves the first free case-insensitive name, then attempts one
/// rename and a checked copy fallback under that same reservation.
func finalizeTransferTemporary(temporary: URL, directory: URL, fileName: String,
                               allowCopy: Bool = true, operations: TransferFileOperations = .system) throws -> URL {
    let preferred = directory.appendingPathComponent(URL(fileURLWithPath: fileName).lastPathComponent)
    return try OutputFileNameReservations.shared.withReservedName(preferred, policy: .original) { destination in
        do {
            try operations.move(temporary, destination)
            return destination
        } catch {
            guard allowCopy else { throw error }
        }
        // A provider or another process may create a file after reservation.
        // Never delete its file when a no-overwrite copy refuses the collision.
        guard !operations.exists(destination) else { throw CocoaError(.fileWriteFileExists) }
        let expected = try operations.size(temporary)
        do {
            try operations.copy(temporary, destination)
            let copied = try operations.size(destination)
            guard copied == expected else { throw CameraDownloadError.copyIncomplete(received: copied, expected: expected) }
        } catch {
            let cocoa = error as NSError
            if cocoa.domain != NSCocoaErrorDomain || cocoa.code != NSFileWriteFileExistsError {
                try? operations.remove(destination)
            }
            throw error
        }
        try? operations.remove(temporary)
        return destination
    }
}

enum CameraRepositoryError: Error, Equatable, Sendable {
    case invalidDataset
    /// The connected STA session failed during its catalog handshake. Android
    /// rebuilds the session instead of leaving a half-readable camera alive.
    case transportLost
    /// A resumed object must continue through the partial-object operation.
    /// Android refuses to fill a seeked stream with GET_OBJECT because that
    /// would duplicate bytes and corrupt the destination.
    case resumeUnavailable
    /// Remote monitor owns the channel; the list must abandon its old handle
    /// snapshot and enumerate again after monitor dismissal.
    case foregroundPreempted
    /// The camera returned DeviceBusy while the rating pass was between files.
    /// The scan may yield and retry without treating this as a capability miss.
    case ratingReadDeferred
}

/// Resumable handle enumeration state. Android keeps this snapshot when a
/// foreground preview interrupts metadata reads; only handles already
/// accepted by the list are marked processed.
struct PhotoScanSnapshot: Sendable {
    var catalogRevision: UInt64 = 0
    let storageIDs: [UInt32]
    let handleOrders: [(storageID: UInt32, handles: [UInt32])]
    var processedHandles: Set<UInt32>
    let handleQueriesSucceeded: Bool
    var filterStorageIDs: [UInt32] = []
    var directStorageIDsByHandle: [UInt32: Set<UInt32>] = [:]

    var remainingHandles: [(storageID: UInt32, handles: [UInt32])] {
        handleOrders.map { ($0.storageID, $0.handles.filter { !processedHandles.contains($0) }) }
    }
}

struct PhotoScanResult: Sendable {
    let files: [CameraFile]
    let removedHandles: Set<UInt32>
    let addedHandles: Set<UInt32>
    let handleQueriesSucceeded: Bool
    let metadataComplete: Bool
    var filterStorageIDs: [UInt32] = []
    /// The handle snapshot is intentionally retained when a bounded photo
    /// scan reaches an older shooting day. The next wider scope resumes it.
    var stoppedAtLoadingRange: Bool = false
    var loadingRangeAtStop: PhotoLoadingRange? = nil
}

/// Data-only recovery state. Protocol tasks, ratings and scan cursors belong
/// to one connection and must never cross this boundary.
struct STACatalogRecovery: Sendable {
    fileprivate let responderGUID: String
    fileprivate let files: [UInt32: CameraFile]
    fileprivate let indexedFiles: [UInt32: CameraFile]
    fileprivate let order: [UInt32]
    fileprivate let storageIDs: [UInt32]
    fileprivate let knownHandles: Set<UInt32>
}

struct STADirectStorageLayout: Equatable, Sendable {
    let storageIDsByHandle: [UInt32: Set<UInt32>]
    let filterStorageIDs: [UInt32]
    let crossSlotOverlapCount: Int
}

func analyzeSTADirectStorageLayout(_ groups: [(storageID: UInt32, handles: [UInt32])]) -> STADirectStorageLayout {
    let storageIDs = Array(Set(groups.map(\.storageID))).sorted()
    let slots = photoStorageIDsBySlot(storageIDs)
    let slotByStorageID = slots.reduce(into: [UInt32: UInt32]()) { result, entry in
        for storageID in entry.value { result[storageID] = entry.key }
    }
    var observed: [UInt32: Set<UInt32>] = [:]
    for group in groups {
        for handle in group.handles { observed[handle, default: []].insert(group.storageID) }
    }
    let overlaps = observed.values.filter { memberships in
        Set(memberships.compactMap { slotByStorageID[$0] }).count > 1
    }.count
    let reliable = overlaps == 0
    return STADirectStorageLayout(storageIDsByHandle: reliable ? observed : [:],
                                  filterStorageIDs: reliable ? storageIDs : [],
                                  crossSlotOverlapCount: overlaps)
}

private func replacingStorageIDs(_ file: CameraFile, with storageIDs: Set<UInt32>) -> CameraFile {
    guard !storageIDs.isEmpty, storageIDs != file.storageIDs else { return file }
    return CameraFile(id: file.id, storageID: file.storageID, format: file.format,
                      size: file.size, fileName: file.fileName,
                      captureDate: file.captureDate, isProtected: file.isProtected,
                      storageIDs: storageIDs)
}

private func catalogLogicalIdentity(_ file: CameraFile) -> String {
    "\(file.fileName)|\(file.size)|\(file.captureDate ?? "")"
}

/// Keep a published logical row when one half of a dual-card backup disappears.
/// If its primary handle vanished, switch the row to a surviving alias while
/// preserving display order and combining all surviving card memberships.
func reconcilePublishedCameraFiles(_ published: [CameraFile], currentHandles: Set<UInt32>,
                                   indexedByHandle: [UInt32: CameraFile]) -> [CameraFile] {
    var aliases: [String: [CameraFile]] = [:]
    for (handle, file) in indexedByHandle where currentHandles.contains(handle) {
        aliases[catalogLogicalIdentity(file), default: []].append(file)
    }
    return published.compactMap { existing in
        guard let candidates = aliases[catalogLogicalIdentity(existing)], !candidates.isEmpty else {
            return currentHandles.contains(existing.id) ? existing : nil
        }
        let primary = candidates.first(where: { $0.id == existing.id }) ?? candidates[0]
        let memberships = candidates.reduce(into: Set<UInt32>()) { $0.formUnion($1.storageIDs) }
        return replacingStorageIDs(primary, with: memberships)
    }
}

private struct CatalogMetadataResult: Sendable {
    let groupIndex: Int
    let handle: UInt32
    let file: CameraFile?
    let successful: Bool
}

/// Android's dual-card merge chooses by capture date only. Missing dates are
/// emitted before dated heads, and equal dates keep storage order; opaque
/// handle values never participate in the tie-break.
func selectNewestPhotoHeadIndex(_ heads: [CameraFile?]) -> Int? {
    var selected: Int?
    for (index, candidate) in heads.enumerated() {
        guard let candidate else { continue }
        guard let selectedIndex = selected, let current = heads[selectedIndex] else {
            selected = index
            continue
        }
        let candidateIsNewer: Bool
        switch (candidate.captureDate, current.captureDate) {
        case (nil, .some):
            candidateIsNewer = true
        case (.some, nil), (nil, nil):
            candidateIsNewer = false
        case let (.some(candidateDate), .some(currentDate)):
            candidateIsNewer = candidateDate > currentDate
        }
        if candidateIsNewer { selected = index }
    }
    return selected
}

/// Protocol-level camera catalog. It deliberately exposes only operations already used by
/// the Android NikonCamera path; UI state and transfer policy stay in higher layers.
actor CameraRepository {
    private var session: PTPSession
    #if DEBUG
    private let debugData: DebugCameraData?
    #endif
    /// Android's CameraIoGate sits above the serialized command session. It
    /// lets an interactive preview reserve the next transaction between
    /// download chunks and suppresses idle probes for the whole download.
    private let ioGate = CameraIOGate()
    private var retirementTask: Task<Void, Never>?
    private let isUSBConnection: Bool
    nonisolated let usbSessionIdentity: USBSessionIdentity?
    private var remoteControlModeSet = false
    private var movieApplicationCleanupTask: Task<Void, Never>?
    /// Android keeps diagnostic PC-control ownership separate from the USB movie
    /// owner so a movie cleanup cannot release a mode the user still holds.
    private var remoteDiagnosticControlModeSet = false
    private var movieApplicationPropertySet = false
    private var movieApplicationOperationSet = false
    /// Android learns this capability once and remembers an unsupported
    /// partial-object operation for the rest of the session.
    private var partialObjectSupported: Bool?
    /// Rating capabilities are connection-scoped. A negative response for one
    /// operation/extension must not be retried for every subsequent file, while
    /// transient busy/denied/object errors remain retryable.
    private var ratingUnsupportedExtensions = Set<String>()
    private var ratingOperationUnsupported = false
    private var ratingNikonHeaderUnsupported = false
    private var ratingStandardHeaderUnsupported = false
    /// Bounded, connection-scoped baselines used only by the explicit STA
    /// protection experiment. They never populate CameraFile.isProtected.
    private nonisolated let protectionHeaderProbeBaselines = ProtectionHeaderProbeStore()
    /// Decoded ratings are scoped to this repository/connection.  A scan
    /// generation makes an old read unable to publish after invalidation or
    /// reconnect; PhotoRatingCache keeps the Android FIFO bound.
    private var photoRatingCache = PhotoRatingCache()
    private var ratingGenerationListeners: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var subjectTrackingActive = false
    private var subjectTrackingSupported: Bool?
    private let focusGate = CameraIOGate()
    private let metadataSessionIdentity = UUID().uuidString
    private var cachedDeviceInfo: PTPDeviceInfo?
    private var pictureControlProtocol: NikonPictureControlProtocol?
    private var liveViewImageOperation: UInt16?
    private var liveViewEnhancedFailures = 0
    private let staAlbum: STAAlbumAccess?
    /// PTP/IP InitCommandAck responder GUID. Android uses it when DeviceInfo
    /// omits a usable serial, for both AP and STA sessions.
    private let transportCameraIdentifier: String?
    private let directReader: STAObjectReader?
    private var prefetchedStorageIDs: [UInt32]?
    private var prefetchedHandles: (storageID: UInt32, handles: [UInt32])?
    private var activeForegroundReads = 0
    private var remotePageActive = false
    private var remoteSessionOwners = 0
    private var remoteActive: Bool { remotePageActive || remoteSessionOwners > 0 }
    private var fhdActive = false
    private var fhdSupported: Bool?
    private var transfersBusy = false
    private var preferHighThroughputTransfers = false
    private var effectPreviewActive = false
    private var activeCatalogScans = 0
    var catalogLoading: Bool { activeCatalogScans > 0 }
    private var catalogFiles: [UInt32: CameraFile] = [:]
    private var indexedCatalogFiles: [UInt32: CameraFile] = [:]
    private var catalogOrder: [UInt32] = []
    private var catalogStorageIDs: [UInt32] = []
    private var knownHandles = Set<UInt32>()
    private var catalogReady = false
    private var lastCatalogCheck = ContinuousClock.now
    private var catalogSyncRequested = false
    private var scanCatalogRevision: UInt64 = 0
    private var scanSnapshot: PhotoScanSnapshot?
    private var pendingObjects: [UInt32: (attempts: Int, ready: ContinuousClock.Instant)] = [:]
    private var eventResolveTask: Task<Void, Never>?
    private var catalogContinuations: [UUID: AsyncStream<[CameraFile]>.Continuation] = [:]

    init(session: PTPSession, staAlbum: STAAlbumAccess? = nil, isUSBConnection: Bool = false,
         deviceInfo: PTPDeviceInfo? = nil, usbSessionIdentity: USBSessionIdentity? = nil,
         transportCameraIdentifier: String? = nil) {
        self.session = session
        #if DEBUG
        self.debugData = nil
        #endif
        self.staAlbum = staAlbum; self.isUSBConnection = isUSBConnection
        self.transportCameraIdentifier = transportCameraIdentifier
        self.usbSessionIdentity = usbSessionIdentity
        self.cachedDeviceInfo = deviceInfo ?? staAlbum?.deviceInfo
        self.prefetchedStorageIDs = staAlbum?.storageIDs
        self.prefetchedHandles = staAlbum?.prefetchedHandles
        self.directReader = staAlbum?.directObjectRead == true ? STAObjectReader(session: session, operations: staAlbum?.deviceInfo?.operations ?? []) : nil
    }

    #if DEBUG
    init(debugData: DebugCameraData = .shared) {
        self.session = PTPSession(transport: DebugNullTransport())
        self.debugData = debugData
        self.staAlbum = nil; self.isUSBConnection = false
        self.transportCameraIdentifier = nil
        self.usbSessionIdentity = nil
        self.prefetchedStorageIDs = [0x00010001, 0x00020001]
        self.prefetchedHandles = nil; self.directReader = nil
    }
    #endif

    deinit { eventResolveTask?.cancel() }

    /// Closes the runtime scheduler boundary before the owning connection is
    /// discarded. Transport teardown may follow asynchronously, but no new
    /// business request is allowed to enter this session after this point.
    func beginShutdown(reason: String = "camera session closed") async {
        eventResolveTask?.cancel(); eventResolveTask = nil
        pictureControlProtocol = nil
        await ioGate.beginShutdown(reason)
        catalogContinuations.values.forEach { $0.finish() }
        catalogContinuations.removeAll()
    }

    /// Retire an accepted connection only after its active multi-command
    /// transaction completes. A caller's cancellation must not abandon cleanup.
    func retireConnection(_ close: @escaping @Sendable () async -> Void) async {
        if let retirementTask { await retirementTask.value; return }
        let gate = ioGate
        let task = Task.detached {
            await self.beginShutdown()
            try? await gate.withCameraTransaction(.interactive, owner: "CLOSE_SESSION",
                                                  allowDuringShutdown: true) {
                await close()
            }
        }
        retirementTask = task
        await task.value
    }

    func cameraSchedulerSnapshot() async -> CameraSchedulerSnapshot {
        await ioGate.snapshot()
    }

    func beginRatingPhase() async { await ioGate.beginRatingPhase() }
    func endRatingPhase() async { await ioGate.endRatingPhase() }

    func photoRatingGeneration() -> Int { photoRatingCache.generation }
    func photoRatingGenerationUpdates() -> AsyncStream<Int> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            ratingGenerationListeners[id] = continuation
            continuation.yield(photoRatingCache.generation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeRatingGenerationListener(id) }
            }
        }
    }
    private func removeRatingGenerationListener(_ id: UUID) { ratingGenerationListeners.removeValue(forKey: id) }
    func cachedPhotoRating(_ handle: UInt32) -> Int? { photoRatingCache.value(for: handle)?.value }
    func cachedPhotoRatingOrigin(_ handle: UInt32) -> String? { photoRatingCache.value(for: handle)?.origin }

    /// Starts a fresh camera snapshot.  The generation is advanced before the
    /// caller begins reading so an in-flight old task can only return unknown.
    @discardableResult
    func invalidatePhotoRatings() -> Int {
        photoRatingCache.invalidate()
        for listener in ratingGenerationListeners.values { listener.yield(photoRatingCache.generation) }
        return photoRatingCache.generation
    }

    private func rememberPhotoRating(_ handle: UInt32, _ rating: Int,
                                    generation: Int, origin: String) {
        photoRatingCache.remember(handle: handle, value: rating, origin: origin, generation: generation)
    }

    private func capturePhotoRating(_ handle: UInt32, _ data: Data, origin: String,
                                    generation: Int? = nil) {
        let bounded = data.prefix(262_144)
        guard bounded.count >= 8 else { return }
        guard let rating = parsePhotoRating(Data(bounded)) ??
                parseNikonVideoRating(Data(bounded)) else { return }
        rememberPhotoRating(handle, rating, generation: generation ?? photoRatingCache.generation, origin: origin)
    }

    func keepalive() async -> Bool {
        guard !(await session.isInvalidated) else { return false }
        if activeForegroundReads > 0 { return true }
        return (try? await ioGate.withIdleCommand(skippedValue: true) {
            await session.keepaliveIfIdle()
        }) ?? false
    }

    /// RemoteLab.rcFocusAt: serialize whole AF lifetimes, retaining the PTP
    /// mutex only for end-tracking -> target -> 80 ms -> AF-start. Frame/event
    /// commands may run between subsequent DeviceReady polls.
    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult {
        try await focusAt(trackingX: trackingX, trackingY: trackingY,
                          focusX: focusX, focusY: focusY, tapPath: nil)
    }

    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32,
                 tapPath: RcTapFocusPath?) async throws -> RemoteFocusResult {
        try await focusGate.withCommand { [self] in
            try await tapFocusLocked(trackingX: trackingX, trackingY: trackingY,
                                     focusX: focusX, focusY: focusY, tapPath: tapPath)
        }
    }

    private func tapFocusLocked(trackingX: UInt32, trackingY: UInt32,
                                focusX: UInt32, focusY: UInt32,
                                tapPath: RcTapFocusPath?) async throws -> RemoteFocusResult {
        let deadline = ContinuousClock.now + .seconds(6)
        let initial = try await ioGate.withInteractive {
            try await session.withCommandSequence { [self] commands in
                try await beginTapFocus(commands, deadline: deadline, trackingX: trackingX, trackingY: trackingY,
                                        focusX: focusX, focusY: focusY, tapPath: tapPath)
            }
        }
        guard initial.responseCode == PTPConstants.responseOK, !initial.timedOut else { return initial }
        var result = try await waitForAutofocus(deadline: deadline, tracking: initial.trackingStarted)
        result.endTrackingResponseCode = initial.endTrackingResponseCode
        result.trackingResponseCode = initial.trackingResponseCode
        result.moveResponseCode = initial.moveResponseCode
        result.afStartResponseCode = initial.afStartResponseCode
        return result
    }

    private func beginTapFocus(_ commands: PTPCommandSequence, deadline: ContinuousClock.Instant,
                                trackingX: UInt32, trackingY: UInt32,
                                focusX: UInt32, focusY: UInt32,
                                tapPath: RcTapFocusPath?) async throws -> RemoteFocusResult {
        let end = try await endTrackingLocked(commands, deadline: deadline)
        if subjectTrackingActive {
            return .init(trackingStarted: false, polls: 0, timedOut: false,
                         responseCode: end ?? PTPConstants.deviceBusy,
                         endTrackingResponseCode: end)
        }
        let useTracking = tapPath.map { $0 == .tracking } ?? (subjectTrackingSupported != false)
        var trackingCode: UInt16?
        if useTracking {
            trackingCode = try await focusCommand(commands, operation: PTPConstants.startTracking,
                parameters: [trackingX, trackingY], deadline: deadline)?.code
            if trackingCode == PTPConstants.responseOK {
                subjectTrackingSupported = true
                subjectTrackingActive = true
            } else if trackingCode == PTPConstants.operationNotSupported {
                subjectTrackingSupported = false
            } else {
                return .init(trackingStarted: false, polls: 0, timedOut: trackingCode == nil,
                             responseCode: trackingCode ?? PTPConstants.deviceBusy, trackingResponseCode: trackingCode)
            }
        }
        let trackingResponse = useTracking ? trackingCode : nil
        var moveCode: UInt16?
        if !subjectTrackingActive {
            let moved = try await focusCommand(commands, operation: PTPConstants.changeAFArea,
                parameters: [focusX, focusY], deadline: deadline)?.code
            moveCode = moved
            if moved != PTPConstants.responseOK {
                return .init(trackingStarted: false, polls: 0, timedOut: moved == nil,
                             responseCode: moved ?? PTPConstants.deviceBusy, trackingResponseCode: trackingResponse,
                             moveResponseCode: moved)
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        let af = try await focusCommand(commands, operation: PTPConstants.afDrive, deadline: deadline)?.code
        return .init(trackingStarted: subjectTrackingActive, polls: 0, timedOut: af == nil,
                     responseCode: af ?? PTPConstants.deviceBusy, trackingResponseCode: trackingResponse,
                     moveResponseCode: moveCode, afStartResponseCode: af)
    }

    func halfPressFocus() async throws -> RemoteFocusResult {
        try await focusGate.withCommand { [self] in
            try await halfPressFocusLocked()
        }
    }

    private func halfPressFocusLocked() async throws -> RemoteFocusResult {
        let deadline = ContinuousClock.now + .seconds(6)
        let end = try await ioGate.withInteractive {
            try await session.withCommandSequence { [self] commands in
                try await endTrackingLocked(commands, deadline: deadline)
            }
        }
        if subjectTrackingActive {
            return .init(trackingStarted: false, polls: 0, timedOut: false,
                         responseCode: end ?? PTPConstants.deviceBusy)
        }
        let af = try await ioGate.withInteractive {
            try await session.withCommandSequence { [self] commands in
                try await focusCommand(commands, operation: PTPConstants.afDrive, deadline: deadline)?.code
            }
        }
        guard af == PTPConstants.responseOK else {
            return .init(trackingStarted: false, polls: 0, timedOut: af == nil,
                         responseCode: af ?? PTPConstants.deviceBusy)
        }
        return try await waitForAutofocus(deadline: deadline, tracking: false)
    }

    func endSubjectTracking() async throws {
        _ = try await endSubjectTrackingForTool()
    }

    func endSubjectTrackingForTool() async throws -> UInt16? {
        try await focusGate.withCommand { [self] in
            try await ioGate.withInteractive {
                let deadline = ContinuousClock.now + .seconds(6)
                return try await session.withCommandSequence { [self] commands in
                    try await endTrackingLocked(commands, deadline: deadline)
                }
            }
        }
    }

    private func endTrackingLocked(_ commands: PTPCommandSequence, deadline: ContinuousClock.Instant) async throws -> UInt16? {
        guard subjectTrackingActive else { return nil }
        let code = try await focusCommand(commands, operation: PTPConstants.endTracking, deadline: deadline)?.code
        if let code, [PTPConstants.responseOK, PTPConstants.operationNotSupported, 0xA004].contains(code) {
            subjectTrackingActive = false
        }
        return code
    }

    private func focusCommand(_ commands: PTPCommandSequence, operation: UInt16, parameters: [UInt32] = [],
                              deadline: ContinuousClock.Instant) async throws -> PTPResponse? {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return nil }
        let nanoseconds = UInt64(remaining.components.seconds) * 1_000_000_000 +
            UInt64(remaining.components.attoseconds / 1_000_000_000)
        return try await commands.executeResponse(operation: operation, parameters: parameters,
                                                   timeoutNanoseconds: nanoseconds)
    }

    private func waitForAutofocus(deadline: ContinuousClock.Instant, tracking: Bool) async throws -> RemoteFocusResult {
        var polls = 0
        while ContinuousClock.now < deadline {
            let ready = try await ioGate.withInteractive {
                try await session.withCommandSequence { [self] commands in
                    try await focusCommand(commands, operation: PTPConstants.deviceReady, deadline: deadline)?.code
                }
            }
            guard let ready else { break }
            polls += 1
            if ready != PTPConstants.deviceBusy {
                return .init(trackingStarted: tracking, polls: polls, timedOut: false, responseCode: ready)
            }
            if ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(150)) }
        }
        return .init(trackingStarted: tracking, polls: polls, timedOut: true, responseCode: PTPConstants.deviceBusy)
    }

    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor? {
        let response = try await ioGate.withInteractive {
            try await session.execute(operation: PTPConstants.getDevicePropDesc,
                                      parameters: [property.rawValue])
        }
        guard let parsed = RemotePropertyCodec.parseDescription(response.data) else { return nil }
        return RemotePropertyDescriptor(property: property, dataType: parsed.dataType,
                                        writable: parsed.writable,
                                        current: UInt64(bitPattern: parsed.current),
                                        values: parsed.values.map { UInt64(bitPattern: $0) })
    }

    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws {
        guard let encoded = RemotePropertyCodec.encode(Int64(bitPattern: value), dataType: descriptor.dataType) else {
            throw CameraRepositoryError.invalidDataset
        }
        _ = try await ioGate.withInteractive {
            try await session.execute(operation: PTPConstants.setDevicePropValue,
                                      parameters: [descriptor.property.rawValue], data: encoded)
        }
    }

    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) async throws -> RemotePropertyDescriptor? {
        let response = try await ioGate.withInteractive {
            try await session.execute(operation: PTPConstants.getDevicePropValue,
                                      parameters: [descriptor.property.rawValue])
        }
        let parsed: Int64?
        if descriptor.property == .nikonLightMeter || descriptor.property == .nikonExposureIndicate {
            parsed = RemoteExposureMeter.decode(property: descriptor.property.rawValue,
                dataType: descriptor.dataType, writable: descriptor.writable,
                responseOK: true, data: response.data)
        } else {
            parsed = RemotePropertyCodec.parseValue(response.data, dataType: descriptor.dataType)
        }
        guard let value = parsed else { return nil }
        var updated = descriptor
        updated.current = UInt64(bitPattern: value)
        return updated
    }

    func remoteFocusMode() async throws -> RemotePropertyDescriptor? {
        for property in RemoteFocusMode.properties {
            let response = try await ioGate.withInteractive {
                try await session.executeResponse(operation: PTPConstants.getDevicePropValue,
                                                  parameters: [property.rawValue])
            }
            guard response.code == PTPConstants.responseOK, [1, 2, 4, 8].contains(response.data.count) else { continue }
            let value = response.data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
            guard RemoteFocusMode.label(property: property, value: value) != nil else { continue }
            let dataType: UInt16 = property == .focusMode ? 0x0004 : 0x0002
            return .init(property: property, dataType: dataType, writable: false, current: value, values: [])
        }
        return nil
    }

    func remoteMovieMode() async throws -> Bool? {
        let response = try await ioGate.withInteractive {
            try await session.executeResponse(operation: PTPConstants.getDevicePropValue,
                                              parameters: [RemoteProperty.liveViewSelector.rawValue])
        }
        guard response.code == PTPConstants.responseOK, let value = response.data.first else { return nil }
        return value != 0
    }

    func remoteEvents() async throws -> [STAEvent] {
        if staAlbum != nil {
            let response = try await ioGate.withEventPoll(background: false) {
                try await session.executeResponse(operation: PTPConstants.nikonCompatibilityInit)
            }
            if response.code == PTPConstants.responseOK { return STAEvent.polled(response.data, extended: true) ?? [] }
            if response.code != PTPConstants.operationNotSupported { return [] }
        }
        let response = try await ioGate.withEventPoll(background: false) {
            try await session.executeResponse(operation: 0x90C7)
        }
        return response.code == PTPConstants.responseOK ? STAEvent.polled(response.data, extended: false) ?? [] : []
    }

    /// Starts Nikon Live View using the same bounded busy retry and DeviceReady
    /// poll as Android RemoteLab. A successful call means the camera is ready
    /// to accept frame requests; callers still wait for the first frame.
    func startLiveView() async throws {
        if liveViewImageOperation == nil {
            liveViewImageOperation = cachedDeviceInfo?.operations.contains(PTPConstants.getLiveViewImageEx) == true
                ? PTPConstants.getLiveViewImageEx : PTPConstants.getLiveViewImage
        }
        var attempts = 0
        while true {
            do {
                _ = try await ioGate.withInteractive {
                    try await session.execute(operation: PTPConstants.startLiveView)
                }
                break
            } catch PTPSessionError.responseCode(let code)
                where (code == PTPConstants.deviceBusy || code == 0xA004) && attempts < 5 {
                attempts += 1
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            do {
                _ = try await ioGate.withInteractive {
                    try await session.execute(operation: PTPConstants.deviceReady,
                                              timeoutNanoseconds: 1_000_000_000)
                }
                return
            } catch PTPSessionError.responseCode(let code) {
                if code != PTPConstants.deviceBusy { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        // Android logs a four-second DeviceBusy warm-up but still attempts
        // frames; this response is not a transport timeout/disconnection.
    }

    func endLiveView() async {
        try? await focusGate.withCommand { [self] in await endLiveViewLocked() }
    }

    private func endLiveViewLocked() async {
        let deadline = ContinuousClock.now + .seconds(6)
        do {
            try await ioGate.withInteractive {
                try await session.withCommandSequence { [self] commands in
                    _ = try await endTrackingLocked(commands, deadline: deadline)
                    await clearSubjectTrackingState()
                    _ = try await focusCommand(commands, operation: PTPConstants.endLiveView, deadline: deadline)
                }
            }
        } catch { subjectTrackingActive = false }
    }

    private func clearSubjectTrackingState() { subjectTrackingActive = false }

    /// RemoteLab.labGrabFrame: advertised operation, sticky downgrade, and SOI
    /// validation. Busy/not-in-LV do not count as enhanced capability failures.
    func liveViewFrame() async throws -> RemoteLiveViewPacket {
        try await ioGate.withInteractive {
            try await session.withCommandSequence { [self] commands in
                try await receiveLiveViewFrame(commands)
            }
        }
    }

    private func receiveLiveViewFrame(_ commands: PTPCommandSequence) async throws -> RemoteLiveViewPacket {
        var operation = liveViewImageOperation ?? PTPConstants.getLiveViewImage
        liveViewImageOperation = operation
        var response = try await commands.executeResponse(operation: operation)
        var offset = RemoteFrameParser.jpegStart(in: response.data)
        if operation == PTPConstants.getLiveViewImageEx {
            let enhancedFailure = (response.code != PTPConstants.responseOK &&
                response.code != PTPConstants.deviceBusy && response.code != 0xA00B) ||
                (response.code == PTPConstants.responseOK && offset == nil)
            if response.code == PTPConstants.responseOK && offset != nil { liveViewEnhancedFailures = 0 }
            else if enhancedFailure {
                liveViewEnhancedFailures = response.code == PTPConstants.operationNotSupported ? 2 : liveViewEnhancedFailures + 1
            }
            if enhancedFailure && liveViewEnhancedFailures >= 2 {
                operation = PTPConstants.getLiveViewImage
                liveViewImageOperation = operation
                liveViewEnhancedFailures = 0
                response = try await commands.executeResponse(operation: operation)
                offset = RemoteFrameParser.jpegStart(in: response.data)
            }
        }
        guard response.code == PTPConstants.responseOK else { throw PTPSessionError.responseCode(response.code) }
        guard let offset else { throw CameraRepositoryError.invalidDataset }
        return .init(bytes: response.data, jpegOffset: offset, operation: operation)
    }

    func capturePhoto() async throws {
        let session = self.session
        let response = try await ioGate.withInteractive {
            return try await RemoteMovieCommandRetry.execute {
                try await session.executeResponse(operation: PTPConstants.captureInMedia,
                                                   parameters: [.max, 0]).code
            }
        }
        guard response == PTPConstants.responseOK else { throw PTPSessionError.responseCode(response) }
    }

    /// Prepare USB movie control without cycling the ImageCaptureCore session.
    /// Android can reopen its raw USB handle, but ZTransfer has no proactive
    /// disconnect action on iOS; draining Nikon's compatibility event on the
    /// existing serialized channel preserves both protocol order and the
    /// accepted wired connection.
    func refreshUSBRemoteSession() async throws -> String {
        guard isUSBConnection else { throw CameraRepositoryError.invalidDataset }
        let drain = try await ioGate.withInteractive {
            try await session.executeResponse(operation: PTPConstants.nikonCompatibilityInit)
        }
        subjectTrackingActive = false
        remoteControlModeSet = false
        remoteDiagnosticControlModeSet = false
        movieApplicationPropertySet = false
        movieApplicationOperationSet = false
        liveViewEnhancedFailures = 0
        liveViewImageOperation = cachedDeviceInfo?.operations.contains(PTPConstants.getLiveViewImageEx) == true
            ? PTPConstants.getLiveViewImageEx : PTPConstants.getLiveViewImage
        return String(format: "session=kept drain=0x%04X info=cached settle=ImageCaptureCore", drain.code)
    }

    func setRemoteControlMode(_ enabled: Bool) async throws -> UInt16 {
        // RemoteLab.rcSetControlMode: the physical command also releases the
        // manual owner on success. Movie standby decides whether release is due.
        if enabled == remoteControlModeSet {
            if !enabled { remoteDiagnosticControlModeSet = false }
            return PTPConstants.responseOK
        }
        let response = try await movieCommandWithBusyRetry(PTPConstants.setControlMode,
                                                            parameters: [enabled ? 1 : 0])
        if response == PTPConstants.responseOK {
            remoteControlModeSet = enabled
            if !enabled { remoteDiagnosticControlModeSet = false }
        }
        return response
    }

    func hasRemoteControlMode() -> Bool { remoteControlModeSet }
    func setRemoteDiagnosticControlMode(_ enabled: Bool) async throws -> UInt16 {
        let response = try await setRemoteControlMode(enabled)
        if response == PTPConstants.responseOK { remoteDiagnosticControlModeSet = enabled }
        return response
    }
    func hasRemoteDiagnosticControlMode() -> Bool { remoteDiagnosticControlModeSet }
    func hasMovieApplicationMode() -> Bool {
        movieApplicationPropertySet || movieApplicationOperationSet
    }

    func ensureMovieApplicationMode() async throws {
        if !movieApplicationPropertySet {
            let response = try await ioGate.withInteractive {
                try await session.executeResponse(operation: PTPConstants.setDevicePropValue,
                                                  parameters: [RemoteProperty.applicationMode.rawValue],
                                                  data: Data([1])).code
            }
            if response == PTPConstants.responseOK { movieApplicationPropertySet = true }
        }
        if !movieApplicationOperationSet {
            let response = try await ioGate.withInteractive {
                try await session.executeResponse(operation: PTPConstants.nikonChangeApplicationMode,
                                                  parameters: [1]).code
            }
            if response == PTPConstants.responseOK { movieApplicationOperationSet = true }
        }
    }

    func clearMovieApplicationMode(force: Bool = false) async {
        if let cleanup = movieApplicationCleanupTask { await cleanup.value; return }
        if isUSBConnection && (remoteControlModeSet || remoteDiagnosticControlModeSet) && !force { return }
        // Connection-owned, non-cancelled cleanup shared by concurrent stop/exit callers.
        let cleanup = Task { await self.releaseMovieApplicationFlags() }
        movieApplicationCleanupTask = cleanup
        await cleanup.value
        movieApplicationCleanupTask = nil
    }

    private func releaseMovieApplicationFlags() async {
        if movieApplicationOperationSet {
            let response = await clearMovieFlag(operation: PTPConstants.nikonChangeApplicationMode,
                                               parameters: [0], data: nil)
            if response == PTPConstants.responseOK { movieApplicationOperationSet = false }
        }
        if movieApplicationPropertySet {
            let response = await clearMovieFlag(operation: PTPConstants.setDevicePropValue,
                parameters: [RemoteProperty.applicationMode.rawValue], data: Data([0]))
            if response == PTPConstants.responseOK { movieApplicationPropertySet = false }
        }
    }

    private func clearMovieFlag(operation: UInt16, parameters: [UInt32], data: Data?) async -> UInt16? {
        var response: UInt16?
        for attempt in 0..<3 {
            if attempt > 0 {
                guard response == PTPConstants.deviceBusy else { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            response = try? await ioGate.withInteractive {
                try await session.executeResponse(operation: operation, parameters: parameters, data: data).code
            }
            if response != PTPConstants.deviceBusy { break }
        }
        return response
    }

    /// USB preflight/application/start is one uninterrupted command sequence.
    func startPreparedUSBMovieRecording() async throws -> RemoteMovieStartResult {
        let operationWasSet = movieApplicationOperationSet
        let propertyWasSet = movieApplicationPropertySet
        return try await ioGate.withInteractive {
            try await session.withCommandSequence { commands in
            var operationSet = operationWasSet
            var propertySet = propertyWasSet
            let extended = try await commands.executeResponse(operation: PTPConstants.getDevicePropValueEx,
                                                              parameters: [0xD0A4]).code
            func readProhibit() async throws -> UInt32? {
                let response = try await commands.executeResponse(operation: PTPConstants.getDevicePropValue,
                                                                 parameters: [0xD0A4])
                guard response.code == PTPConstants.responseOK, response.data.count >= 4 else { return nil }
                return response.data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            }
            let preflight = try await readProhibit()
            let needsApplication = preflight.map { $0 & (1 << 14) != 0 } ?? false
            var appOperation: UInt16?
            var appProperty: UInt16?
            if needsApplication && !operationSet && !propertySet {
                let response = try await commands.executeResponse(operation: PTPConstants.nikonChangeApplicationMode,
                                                                 parameters: [1]).code
                appOperation = response
                if response == PTPConstants.responseOK {
                    operationSet = true
                    await recordMovieApplicationMode(property: false)
                }
                if response == PTPConstants.operationNotSupported {
                    let property = try await commands.executeResponse(operation: PTPConstants.setDevicePropValue,
                                                                     parameters: [RemoteProperty.applicationMode.rawValue],
                                                                     data: Data([1])).code
                    appProperty = property
                    if property == PTPConstants.responseOK {
                        propertySet = true
                        await recordMovieApplicationMode(property: true)
                        _ = try await readProhibit()
                    }
                }
            }
            let ready = !needsApplication || operationSet || propertySet
            let start = ready
                ? try await commands.executeResponse(operation: PTPConstants.startMovieRecording).code
                : (appProperty ?? appOperation ?? 0x200F)
            let finalProhibit = start == PTPConstants.responseOK ? nil : (try await readProhibit() ?? preflight)
            return RemoteMovieStartResult(responseCode: start, prohibitCondition: finalProhibit,
                                           prohibitExtendedResponse: extended,
                                           applicationModeResponse: appOperation,
                                           applicationModePropertyResponse: appProperty,
                                           startCommandResponse: ready ? start : nil)
            }
        }
    }

    /// Commit each acknowledged side effect before the next fallible command.
    /// The command-sequence gate remains held while recording actor ownership.
    private func recordMovieApplicationMode(property: Bool) {
        if property { movieApplicationPropertySet = true }
        else { movieApplicationOperationSet = true }
    }

    func startMovieRecording() async throws -> RemoteMovieStartResult {
        let response = try await movieCommandWithBusyRetry(PTPConstants.startMovieRecording)
        var prohibitCondition: UInt32?
        if response != PTPConstants.responseOK {
            do {
                // RemoteLab.PROP_NK_MOV_PROHIBIT: read only after a failed start,
                // including bit 10 when the camera is already recording.
                let data = try await ioGate.withInteractive {
                    try await session.execute(operation: PTPConstants.getDevicePropValue,
                                              parameters: [0xD0A4]).data
                }
                if data.count >= 4 {
                    prohibitCondition = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
                }
            } catch PTPSessionError.responseCode(_) {
                // Android keeps the start response when the optional property
                // returns a negative response. Transport errors still propagate.
            }
        }
        try Task.checkCancellation()
        return RemoteMovieStartResult(responseCode: response, prohibitCondition: prohibitCondition)
    }

    func endMovieRecording() async throws -> UInt16 {
        try await movieCommandWithBusyRetry(PTPConstants.endMovieRecording)
    }

    private func movieCommandWithBusyRetry(_ operation: UInt16, parameters: [UInt32] = []) async throws -> UInt16 {
        let session = self.session
        return try await RemoteMovieCommandRetry.execute {
            do {
                return try await self.ioGate.withInteractive {
                    try await session.execute(operation: operation, parameters: parameters).code
                }
            }
            catch PTPSessionError.responseCode(let response) { return response }
        }
    }

    func remoteDeviceModel() -> String? { cachedDeviceInfo?.model }

    private func pictureControlAccess(slot: Int, movie: Bool,
        exchange: @escaping NikonPictureControlAccess.Exchange,
        isCurrent: @escaping @Sendable () async -> Bool,
        log: (@Sendable (String) -> Void)?) async throws -> NikonPictureControlAccess {
        guard let info = cachedDeviceInfo else { throw NikonPictureControlError.invalid("Camera information unavailable") }
        guard info.manufacturer.localizedCaseInsensitiveContains("Nikon") else {
            throw NikonPictureControlError.invalid("Not a Nikon camera")
        }
        let identity = thumbnailCacheIdentity()
        guard identity.components(separatedBy: "\0").last != "unknown-device" else {
            throw NikonPictureControlError.invalid("A stable camera identity is required for slot backups")
        }
        let session = session
        let check: @Sendable () async -> Bool = {
            guard await isCurrent() else { return false }
            return !(await session.isInvalidated)
        }
        log?("camera=\(info.model) firmware=\(info.version) transport=\(isUSBConnection ? "USB" : "PTP/IP") movie=\(movie) target=C\(slot - 200)")
        for (name, codes) in [("DeviceInfo.operations", info.operations), ("DeviceInfo.properties", info.properties)] {
            log?(name + "=" + codes.sorted().map { String(format: "0x%04X", $0) }.joined(separator: ", "))
        }
        let resolved: NikonPictureControlProtocol
        if let cached = pictureControlProtocol { resolved = cached }
        else {
            resolved = try await discoverPictureControlProtocol(operations: Set(info.operations), properties: Set(info.properties),
                exchange: exchange, sessionCheck: check, movie: movie, log: log)
            guard await check() else { throw NikonPictureControlError.invalid("Camera session changed during protocol discovery") }
            if resolved.cacheable { pictureControlProtocol = resolved }
        }
        log?("protocol=\(resolved.format.rawValue) movieSupported=\(resolved.supportsMovie)")
        try resolved.requireMode(movie)
        let bankIdentity = identity + "\0picture-control-" + (resolved.format.movieBank(movie) ? "movie" : "photo")
        return try NikonPictureControlAccess(cameraIdentity: bankIdentity, slot: slot, movie: movie,
            operations: Set(info.operations), sessionCheck: check, exchange: exchange, log: log, format: resolved.format)
    }

    func readPictureControlOverview(movie: Bool, backupDirectory: URL,
                                    isCurrent: @escaping @Sendable () async -> Bool,
                                    log: (@Sendable (String) -> Void)? = nil) async throws -> PictureControlOverview {
        let session = session, ioGate = ioGate
        return try await focusGate.withCommand {
            let exchange: NikonPictureControlAccess.Exchange = { code, parameters, data in
                try Task.checkCancellation()
                let response = try await ioGate.withInteractive {
                    // Read-only enumeration yields only after complete responses.
                    try await Task {
                        try await session.executeResponse(operation: code, parameters: parameters, data: data,
                                                          timeoutNanoseconds: 5_000_000_000)
                    }.value
                }
                try Task.checkCancellation()
                return response
            }
            let access = try await self.pictureControlAccess(slot: 201, movie: movie,
                exchange: exchange, isCurrent: isCurrent, log: log)
            return try await access.overview(backup: PictureControlBackupStore(directory: backupDirectory))
        }
    }

    func changePictureControl(slot: Int, change: PictureControlChange, movie: Bool, backupDirectory: URL,
                              isCurrent: @escaping @Sendable () async -> Bool,
                              log: (@Sendable (String) -> Void)? = nil) async throws {
        let session = session, ioGate = ioGate
        try await focusGate.withCommand {
            try await ioGate.withInteractive {
                try await session.withCommandSequence { commands in
                    let exchange: NikonPictureControlAccess.Exchange = { code, parameters, data in
                        try Task.checkCancellation()
                        let response = try await Task {
                            try await commands.executeResponse(operation: code, parameters: parameters, data: data,
                                                               timeoutNanoseconds: 5_000_000_000)
                        }.value
                        try Task.checkCancellation()
                        return response
                    }
                    let access = try await self.pictureControlAccess(slot: slot, movie: movie,
                        exchange: exchange, isCurrent: isCurrent, log: log)
                    let replacement = PictureControlReplacement(backup: PictureControlBackupStore(directory: backupDirectory))
                    switch change {
                    case .write(let file):
                        let dataset = try file.encodePictureControl(format: access.format)
                        try await access.prepare(dataset: dataset)
                        try await replacement.apply(access, dataset: NikonPictureControlSlotState(slot: slot, dataset: dataset, format: access.format).data)
                    case .activate:
                        try await access.prepareSelection()
                        try await replacement.activate(access)
                    case .clear:
                        try await access.prepare()
                        try await replacement.clear(access)
                    case .restore:
                        try await access.prepare()
                        try await replacement.restoreOriginal(access)
                    }
                    log?("SUCCESS: C\(slot - 200) operation and active selection verified")
                }
            }
        }
    }

    func loadDeviceInfo() async throws -> PTPDeviceInfo {
        if let info = cachedDeviceInfo { return info }
        let result = try await ioGate.withInteractive {
            try await session.execute(operation: PTPConstants.getDeviceInfo)
        }
        guard let info = PTPDatasetParser.parseDeviceInfo(result.data) else { throw CameraRepositoryError.invalidDataset }
        pictureControlProtocol = nil
        cachedDeviceInfo = info
        return info
    }

    /// Stable per-body cache identity, matching Android's serial -> transport
    /// GUID -> model-scoped fallback. It must never disable the thumbnail
    /// store merely because DeviceInfo omitted a serial number.
    func thumbnailCacheIdentity() -> String {
        cameraThumbnailCacheIdentity(deviceInfo: cachedDeviceInfo,
                                     transportIdentifier: transportCameraIdentifier)
    }

    func photoMetadataIdentity() -> PhotoMetadataCameraIdentity {
        PhotoMetadataCameraIdentity(cacheIdentity: thumbnailCacheIdentity(), session: metadataSessionIdentity)
    }

    /// Identity verification and header read share one transaction slot, so a
    /// reused handle can never be validated after its EXIF has been consumed.
    func frameMetadataHeader(file: CameraFile, expectedSource: PhotoMetadataCameraIdentity?,
                             maxBytes: Int = cameraExifHeaderCaptureBytes) async throws -> Data? {
        let limit = min(max(1, maxBytes), 2 * 1024 * 1024)
        let current = photoMetadataIdentity()
        if let expectedSource, expectedSource.camera != current.camera { return nil }
        let verifyFile = expectedSource.map { $0.session != current.session } ?? false
        return try await ioGate.withBackgroundThumbnail {
            if verifyFile {
                let actual: CameraFile?
                if let cached = await self.directReader?.cachedFile(handle: file.id) {
                    actual = cached
                } else {
                    let response = try await self.session.executeResponse(operation: PTPConstants.getObjectInfo, parameters: [file.id])
                    let parsed = PTPDatasetParser.parseObjectInfoResult(
                        handle: file.id, response.data, protectionAvailable: staAlbum == nil
                    )
                    actual = response.code == PTPConstants.responseOK && parsed.successful ? parsed.file : nil
                }
                guard samePhotoMetadataSource(file, actual) else { return nil }
            }
            if let cached = await self.directReader?.cachedMetadataHeader(handle: file.id, length: limit) {
                return cached
            }
            let result = try await self.session.executeResponse(operation: PTPConstants.getPartialObjectEx,
                parameters: [file.id, 0, 0, UInt32(limit), 0])
            return result.code == PTPConstants.responseOK && !result.data.isEmpty ? result.data : nil
        }
    }

    func usesDirectThumbnailRead() -> Bool { directReader != nil }
    /// True only for the paired STA album route. Debug protection probes are
    /// deliberately unavailable to AP and USB sessions.
    func isSTASession() -> Bool { staAlbum != nil }

    private static let protectionProbeExtensions: Set<String> =
        [".jpg", ".jpeg", ".nef", ".nrw", ".mov", ".mp4"]

    /// Read a bounded file prefix for the STA protection experiment. The
    /// normal browsing prefix cache is bypassed so a second probe observes
    /// bytes after the user changes protection on the camera.
    private func readProtectionProbeHeader(_ file: CameraFile, length: Int) async throws -> Data {
        if let directReader {
            return try await directReader.protectionHeader(handle: file.id, length: length)
        }
        let response = try await session.executeResponse(
            operation: PTPConstants.getPartialObjectEx,
            parameters: [file.id, 0, 0, UInt32(length), 0],
            timeoutNanoseconds: 60_000_000_000
        )
        guard response.code == PTPConstants.responseOK else {
            throw PTPSessionError.responseCode(response.code)
        }
        return response.data
    }

    /// Android's bounded read-only STA header probe. A changed byte is only a
    /// candidate: this method never writes protection state or updates the
    /// normal rating/protection caches.
    func probeProtectionHeaders(files: [CameraFile]) async {
        guard staAlbum != nil else {
            PhotoRatingDiagnostics.note("protection header probe unavailable=non-sta")
            return
        }
        PhotoRatingDiagnostics.note("protection header probe mode=STA files=\(min(files.count, 4)) cap=262144B objectProtection=not-read")
        guard directReader != nil else {
            PhotoRatingDiagnostics.note("protection header probe unavailable=sta-direct-not-validated")
            return
        }
        var seen = Set<UInt32>()
        let candidates = files.filter {
            Self.protectionProbeExtensions.contains($0.fileExtension) && seen.insert($0.id).inserted
        }.prefix(4)
        guard !candidates.isEmpty else {
            PhotoRatingDiagnostics.note("protection header probe no-supported-files")
            return
        }
        do { try await ioGate.withRatingTransaction(owner: "RATING") { [self] in
            for file in candidates {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let elapsedMS: () -> UInt64 = {
                    (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                }
                let requested = Int(min(max(file.size, 1), 256 * 1024))
                do {
                    let bytes = try await readProtectionProbeHeader(file, length: requested)
                    guard !bytes.isEmpty else {
                        PhotoRatingDiagnostics.note("protection file=\(file.fileName) handle=0x\(String(format: "%08X", file.id)) bytes=0 result=read-failed elapsed=\(elapsedMS())ms")
                        continue
                    }
                    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    let rating = parsePhotoRating(bytes) ?? parseNikonVideoRating(bytes, fileSize: file.size)
                    let prefix = "protection file=\(file.fileName) handle=0x\(String(format: "%08X", file.id)) bytes=\(bytes.count) sha256=\(digest) "
                    if let previous = protectionHeaderProbeBaselines.value(for: file.id) {
                        let common = min(previous.count, bytes.count)
                        var changes: [String] = []
                        var changedCount = previous.count == bytes.count ? 0 : 1
                        if common > 0 {
                            for index in 0..<common where previous[index] != bytes[index] {
                                changedCount += 1
                                if changes.count < 12 {
                                    changes.append("@\(index):\(String(format: "%02X", previous[index]))->\(String(format: "%02X", bytes[index]))")
                                }
                            }
                        }
                        PhotoRatingDiagnostics.note(prefix + "rating=\(rating.map { String($0) } ?? "unknown") " + (changedCount == 0
                            ? "diff=none"
                            : "diffCount=\(changedCount) candidates=\(changes.joined(separator: ",")) candidateOnly=true") +
                            " elapsed=\(elapsedMS())ms")
                    } else {
                        protectionHeaderProbeBaselines.save(bytes, for: file.id)
                        PhotoRatingDiagnostics.note(prefix + "rating=\(rating.map { String($0) } ?? "unknown") baseline=saved elapsed=\(elapsedMS())ms")
                    }
                } catch {
                    PhotoRatingDiagnostics.note("protection file=\(file.fileName) handle=0x\(String(format: "%08X", file.id)) error=\(String(describing: error)) elapsed=\(elapsedMS())ms")
                    PhotoRatingDiagnostics.note("protection file=\(file.fileName) handle=0x\(String(format: "%08X", file.id)) bytes=0 result=read-failed elapsed=\(elapsedMS())ms")
                }
            }
        } } catch { PhotoRatingDiagnostics.note("protection header probe error=\(String(describing: error))") }
        PhotoRatingDiagnostics.note("protection header probe complete; differences are candidates only, repeat after changing the camera protection state")
    }

    /// One-shot read-only MTP ProtectionStatus probe (0xDC03). The response
    /// code and raw payload are logged without touching FileInfo.isProtected.
    func probeProtectionProperties(files: [CameraFile]) async {
        guard staAlbum != nil else {
            PhotoRatingDiagnostics.note("protection property probe unavailable=non-sta")
            return
        }
        let candidateCount = min(files.count, 4)
        var seen = Set<UInt32>()
        let candidates = files.filter {
            Self.protectionProbeExtensions.contains($0.fileExtension) && seen.insert($0.id).inserted
        }.prefix(4)
        let advertised = cachedDeviceInfo?.operations.contains(PTPConstants.getObjectPropValue) == true
        PhotoRatingDiagnostics.note("protection property probe mode=STA prop=0xDC03 op=0x9803 advertised=\(advertised) files=\(candidateCount)")
        guard !candidates.isEmpty else {
            PhotoRatingDiagnostics.note("protection property probe no-supported-files")
            return
        }
        do { try await ioGate.withRatingTransaction(owner: "RATING") { [self] in
            for file in candidates {
                do {
                    let response = try await session.executeResponse(
                        operation: PTPConstants.getObjectPropValue,
                        parameters: [file.id, PTPConstants.objectPropProtectionStatus],
                        timeoutNanoseconds: 60_000_000_000
                    )
                    let raw = response.data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
                    let value = response.data.count >= 2
                        ? String(UInt16(response.data[0]) | (UInt16(response.data[1]) << 8))
                        : "unknown"
                    PhotoRatingDiagnostics.note("protection property file=\(file.fileName) handle=0x\(String(format: "%08X", file.id)) resp=0x\(String(format: "%04X", response.code)) bytes=\(response.data.count) value=\(value) raw=\(raw.isEmpty ? "none" : raw)")
                } catch {
                    PhotoRatingDiagnostics.note("protection property file=\(file.fileName) handle=0x\(String(format: "%08X", file.id)) error=\(String(describing: error))")
                }
            }
        } } catch { PhotoRatingDiagnostics.note("protection property probe error=\(String(describing: error))") }
        PhotoRatingDiagnostics.note("protection property probe complete")
    }
    /// The Android list keeps this handle snapshot when FHD/monitoring cancels
    /// a scan before the first metadata batch is visible.  The owner must be
    /// able to pass that exact snapshot back instead of inferring resumability
    /// from the number of published rows.
    func scanSnapshotForResume() -> PhotoScanSnapshot? { scanSnapshot }

    func staCatalogRecovery() -> STACatalogRecovery? {
        guard staAlbum != nil,
              let guid = STAProfileStore.normalizeGUID(transportCameraIdentifier),
              !catalogOrder.isEmpty || catalogReady else { return nil }
        return STACatalogRecovery(responderGUID: guid, files: catalogFiles,
            indexedFiles: indexedCatalogFiles, order: catalogOrder,
            storageIDs: catalogStorageIDs, knownHandles: knownHandles)
    }

    /// Install only before a new same-body STA session begins scanning.
    /// The next scan must re-enumerate handles, not reuse handshake results.
    @discardableResult
    func restoreSTACatalog(_ recovery: STACatalogRecovery) -> Bool {
        guard staAlbum != nil, activeCatalogScans == 0, catalogOrder.isEmpty,
              knownHandles.isEmpty, !catalogReady,
              STAProfileStore.normalizeGUID(transportCameraIdentifier) == recovery.responderGUID else { return false }
        catalogFiles = recovery.files
        indexedCatalogFiles = recovery.indexedFiles
        catalogOrder = recovery.order
        catalogStorageIDs = recovery.storageIDs
        knownHandles = recovery.knownHandles
        prefetchedStorageIDs = nil
        prefetchedHandles = nil
        scanSnapshot = nil
        invalidatePhotoRatings()
        resetRatingCapabilityState()
        return true
    }
    func backgroundThumbnailFillAllowed() -> Bool {
        activeForegroundReads == 0 && !remoteActive && !fhdActive && !transfersBusy && !effectPreviewActive
    }

    func setTransfersBusy(_ busy: Bool) { transfersBusy = busy }
    func setPreferHighThroughputTransfers(_ enabled: Bool) { preferHighThroughputTransfers = enabled }
    /// Holds Android's preview reservation across the FHD/EXIF pair. Callers
    /// use this around the complete foreground load, while the individual
    /// commands still take short interactive locks inside the reservation.
    func withInteractivePreviewPriority<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await ioGate.withInteractivePriority(operation)
    }
    /// Android starts the connected-settings effects sample only after every
    /// foreground camera owner is idle. Claim the effects slot atomically, then
    /// keep one interactive reservation across the FHD and EXIF commands.
    func withEffectPreviewPriority<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        while transfersBusy || remoteActive || fhdActive || effectPreviewActive {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        effectPreviewActive = true
        defer {
            effectPreviewActive = false
            scheduleObjectResolver()
        }
        return try await ioGate.withInteractivePriority(operation)
    }
    /// Foreground FHD preview has priority over catalog metadata reads.  The
    /// scan keeps its handle snapshot and resumes at the same cursor when the
    /// preview releases the channel.
    func setFHDActive(_ active: Bool) { fhdActive = active }
    /// Remote page owns the foreground channel from the moment it appears,
    /// before parameter loading or Live View startup begins.
    func setRemoteActive(_ active: Bool) {
        remotePageActive = active
        if !remoteActive { scheduleObjectResolver() }
    }

    func setRemoteSessionActive(_ active: Bool) {
        remoteSessionOwners = active ? remoteSessionOwners + 1 : max(0, remoteSessionOwners - 1)
        if !remoteActive { scheduleObjectResolver() }
    }

    private func waitForForegroundPreview() async throws {
        if staAlbum != nil {
            // STA scan belongs to the session, not a screen. Never restart its
            // snapshot when a foreground owner temporarily needs the channel.
            while remoteActive || fhdActive || transfersBusy || effectPreviewActive {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            return
        }
        // Android cancels a list scan when remote monitor takes ownership. The
        // monitor may capture new media, so its next list load must enumerate
        // fresh handles instead of resuming the old snapshot.
        if remoteActive {
            throw CameraRepositoryError.foregroundPreempted
        }
        // Interactive FHD is a short same-session pause and resumes at the
        // existing cursor after the preview releases the channel.
        while fhdActive {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func loadStorageIDs() async throws -> [UInt32] {
        if let ids = prefetchedStorageIDs { prefetchedStorageIDs = nil; return ids }
        let result = try await catalogCommand(PTPConstants.getStorageIDs)
        guard let ids = PTPDatasetParser.readStorageIDs(result.data) else { throw CameraRepositoryError.invalidDataset }
        return ids
    }

    /// Monitor-only storage discovery reuses the catalog's known physical IDs
    /// when available, and otherwise performs one ordinary GetStorageIDs.
    func monitorStorageIDs() async throws -> [UInt32] {
        let ids = catalogStorageIDs.isEmpty ? try await loadStorageIDs() : catalogStorageIDs
        // Android's usableStorageIds helper removes placeholders, excludes
        // aggregate stores for AP/USB (low 16 bits == 0), de-duplicates, then
        // sorts before assigning visible slots. STA keeps its wildcard mapping.
        let usable = ids.filter { id in
            if staAlbum != nil { return id != 0 && id != .max }
            return (id & 0xFFFF) != 0
        }
        return Array(Set(usable)).sorted()
    }

    /// MonitorStorage uses an ordinary P6 ticket, unlike a skippable heartbeat.
    /// Recheck the page's current polling condition after obtaining the channel.
    func monitorFreeBytes(storageID: UInt32, allowed: @escaping @Sendable () async -> Bool) async throws -> Int64? {
        try await ioGate.withCameraTransaction(.idle, owner: "MONITOR_STORAGE") {
            guard await allowed() else { return nil }
            let response = try await session.executeResponse(operation: PTPConstants.getStorageInfo,
                                                              parameters: [storageID])
            guard response.code == PTPConstants.responseOK else {
                throw PTPSessionError.responseCode(response.code)
            }
            return RemoteMonitorTelemetry.parseMonitorFreeBytes(response.data)
        }
    }

    /// Android LiveViewVideoDiagnostic: current and legacy headers, no mode writes.
    func probeLegacyVideoTime() async throws -> String {
        let current = liveViewImageOperation ?? PTPConstants.getLiveViewImage
        let model = cachedDeviceInfo?.model
        let transport = isUSBConnection ? "USB" : (staAlbum == nil ? "AP" : "STA")
        var lines = ["camera=\(model ?? "unknown") transport=\(transport) pc=\(remoteControlModeSet) currentOp=\(String(current, radix: 16))"]
        let operations = current == PTPConstants.getLiveViewImage
            ? [current] : [current, PTPConstants.getLiveViewImage]
        for operation in operations {
            try Task.checkCancellation()
            let response = try await ioGate.withInteractive {
                try await session.executeResponse(operation: operation)
            }
            lines.append(RemoteVideoDiagnostic.report(operation: operation, response: response.code,
                                                       payload: response.data, model: model))
        }
        return lines.joined(separator: "\n")
    }

    /// Read-only D0A0/D0A7 property diagnostic. The raw response is retained
    /// so unsupported layouts remain useful without guessing a value.
    func probeMovieFormat() async throws -> String {
        try await ioGate.withInteractive {
            try await session.withCommandSequence { commands in
                var lines = ["Movie-format probe (read-only)"]
                for property in [UInt32(0xD0A0), UInt32(0xD0A7)] {
                    let description = try await commands.executeResponse(operation: PTPConstants.getDevicePropDesc,
                                                                          parameters: [property])
                    lines.append("0x\(String(format: "%04X", property)) desc=0x\(String(format: "%04X", description.code)) hex=\(description.data.prefix(64).map { String(format: "%02X", $0) }.joined())")
                    if let parsed = RemotePropertyCodec.parseDescription(description.data) {
                        lines.append("  type=0x\(String(format: "%04X", parsed.dataType)) current=\(parsed.current) writable=\(parsed.writable) values=\(parsed.values.prefix(16))")
                    }
                    let value = try await commands.executeResponse(operation: PTPConstants.getDevicePropValue,
                                                                     parameters: [property])
                    lines.append("0x\(String(format: "%04X", property)) value=0x\(String(format: "%04X", value.code)) hex=\(value.data.prefix(64).map { String(format: "%02X", $0) }.joined())")
                }
                lines.append("mapping is informational; no property writes were issued")
                return lines.joined(separator: "\n")
            }
        }
    }

    /// Android openRemoteReviewCatalog: fresh frozen handles, independent of list filters.
    func openRemoteReviewCatalog() async throws -> RemoteReviewCatalog {
        let response = try await reviewCommand(PTPConstants.getStorageIDs)
        guard let raw = PTPDatasetParser.readStorageIDs(response.data) else {
            throw CameraRepositoryError.invalidDataset
        }
        let stores = Array(Set(raw.filter { staAlbum != nil ? $0 != 0 && $0 != .max : $0 & 0xFFFF != 0 })).sorted()
        var groups: [[UInt32]] = []
        var storageByHandle: [UInt32: UInt32] = [:]
        var seen = Set<UInt32>()
        for store in stores {
            let response = try await reviewCommand(PTPConstants.getObjectHandles, [queryStorageID(store), .max, 0])
            guard let ids = PTPDatasetParser.readObjectHandles(response.data) else {
                throw CameraRepositoryError.invalidDataset
            }
            groups.append(ids.reversed().filter { seen.insert($0).inserted })
            for id in ids where storageByHandle[id] == nil { storageByHandle[id] = store }
        }
        let memberships = storageByHandle
        let cached = catalogFiles
        return RemoteReviewCatalog(handlesByStorage: groups) { [self] handle in
            if let file = cached[handle] { return file }
            return try await readReviewFile(handle, storage: memberships[handle] ?? .max)
        }
    }

    private func reviewCommand(_ operation: UInt16, _ parameters: [UInt32] = []) async throws -> PTPResponse {
        for attempt in 0..<3 {
            let response = try await ioGate.withInteractive {
                try await session.executeResponse(operation: operation, parameters: parameters)
            }
            if response.code == PTPConstants.responseOK { return response }
            if response.code != PTPConstants.deviceBusy || attempt == 2 {
                throw PTPSessionError.responseCode(response.code)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CameraRepositoryError.invalidDataset
    }

    private func readReviewFile(_ handle: UInt32, storage: UInt32) async throws -> CameraFile? {
        for attempt in 0..<3 {
            do {
                return try await ioGate.withInteractive {
                    if let directReader { return try await directReader.file(handle: handle, storage: storage) }
                    let response = try await session.execute(operation: PTPConstants.getObjectInfo, parameters: [handle])
                    let parsed = PTPDatasetParser.parseObjectInfoResult(handle: handle, response.data,
                                                                       protectionAvailable: staAlbum == nil)
                    guard parsed.successful else { throw CameraRepositoryError.invalidDataset }
                    return parsed.file
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if attempt == 2 { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        return nil
    }

    func loadObjectHandles(storageID: UInt32 = 0xFFFFFFFF) async throws -> [UInt32] {
        if let prefetch = prefetchedHandles, prefetch.storageID == storageID {
            prefetchedHandles = nil; return prefetch.handles
        }
        let result = try await catalogCommand(PTPConstants.getObjectHandles, [storageID, .max, 0])
        guard let handles = PTPDatasetParser.readObjectHandles(result.data) else { throw CameraRepositoryError.invalidDataset }
        return handles
    }

    private struct ObjectHandlesStatus: Sendable {
        let handles: [UInt32]
        let successful: Bool
        let responseCode: UInt16?
    }

    /// Status-preserving query used by the list scan. Android treats a
    /// non-STA response-level failure as an incomplete scan (retaining rows),
    /// while STA retries DeviceBusy and reconnects after the third failure.
    private func loadObjectHandlesWithStatus(storageID: UInt32) async throws -> ObjectHandlesStatus {
        if let prefetch = prefetchedHandles, prefetch.storageID == storageID {
            prefetchedHandles = nil
            return ObjectHandlesStatus(handles: prefetch.handles, successful: true,
                                       responseCode: PTPConstants.responseOK)
        }
        do {
            let response = try await ioGate.withCommand {
                try await session.executeResponse(
                    operation: PTPConstants.getObjectHandles,
                    parameters: [storageID, .max, 0],
                    timeoutNanoseconds: 60_000_000_000
                )
            }
            guard response.code == PTPConstants.responseOK,
                  let handles = PTPDatasetParser.readObjectHandles(response.data) else {
                return ObjectHandlesStatus(handles: [], successful: false, responseCode: response.code)
            }
            return ObjectHandlesStatus(handles: handles, successful: true, responseCode: response.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ObjectHandlesStatus(handles: [], successful: false, responseCode: nil)
        }
    }

    func loadObjectInfo(handle: UInt32) async throws -> CameraFile {
        let result = try await ioGate.withCommand {
            try await session.execute(operation: PTPConstants.getObjectInfo, parameters: [handle])
        }
        guard let file = PTPDatasetParser.parseObjectInfo(
            handle: handle, result.data, protectionAvailable: staAlbum == nil
        ) else { throw CameraRepositoryError.invalidDataset }
        return file
    }

    /// Caller owns ioGate. Preserve parser completeness independently from
    /// whether a fallback display row can be recovered from the dataset.
    private func readCatalogMetadataCommand(group: Int, handle: UInt32, storage: UInt32) async throws -> CatalogMetadataResult {
        try Task.checkCancellation()
        try checkRemoteScanOwnership()
        do {
            if let directReader {
                let file = try await directReader.file(handle: handle, storage: storage)
                return CatalogMetadataResult(groupIndex: group, handle: handle, file: file, successful: true)
            }
            let response = try await session.execute(operation: PTPConstants.getObjectInfo, parameters: [handle])
            let parsed = PTPDatasetParser.parseObjectInfoResult(
                handle: handle, response.data, protectionAvailable: staAlbum == nil
            )
            return CatalogMetadataResult(groupIndex: group, handle: handle,
                                         file: parsed.file, successful: parsed.successful)
        } catch let error as PTPSessionError where error == .invalidated || error == .timeout {
            throw error
        } catch is CancellationError { throw CancellationError() }
        catch {
            return CatalogMetadataResult(groupIndex: group, handle: handle, file: nil, successful: false)
        }
    }

    private struct CatalogMergeState: Sendable {
        var cursors: [Int]
        var heads: [CameraFile?]
        var completed = 0
    }

    private struct CatalogMergeBatch: Sendable {
        var state: CatalogMergeState
        var files: [CameraFile] = []
        var processed: [UInt32] = []
        var successful = true
        var requests = 0
    }

    /// Android streamMergedFileInfo/streamStaDirectMergedFileInfo: retain one
    /// head per card and only request the card whose head has been consumed.
    /// AP scans hold the gate for the whole batch. STA and ICC USB yield at
    /// complete command boundaries while retaining the same merge cursor and
    /// publication batch. An ICC batch must not hold up a newly queued photo
    /// through dozens of separate framework callbacks.
    private func readMergedCatalogBatch(
        groups: [(storage: UInt32, handles: [UInt32])], state: CatalogMergeState,
        limit: Int, budget: Int, total: Int, pauseBetweenCommands: Bool
    ) async throws -> CatalogMergeBatch {
        var batch = CatalogMergeBatch(state: state)
        while batch.files.count < limit && batch.state.completed < total {
            for group in groups.indices where batch.state.heads[group] == nil {
                while batch.state.cursors[group] < groups[group].handles.count && batch.requests < budget {
                    try Task.checkCancellation()
                    let handle = groups[group].handles[batch.state.cursors[group]]
                    batch.state.cursors[group] += 1
                    batch.requests += 1
                    let result: CatalogMetadataResult
                    if pauseBetweenCommands {
                        try await waitForForegroundPreview()
                        let storage = groups[group].storage
                        result = try await ioGate.withCommand {
                            try await self.readCatalogMetadataCommand(group: group, handle: handle, storage: storage)
                        }
                    } else {
                        result = try await readCatalogMetadataCommand(group: group, handle: handle, storage: groups[group].storage)
                    }
                    batch.successful = batch.successful && result.successful
                    if let file = result.file {
                        batch.state.heads[group] = file
                        break
                    }
                    batch.state.completed += 1
                    batch.processed.append(handle)
                }
            }
            let unresolved = groups.indices.contains {
                batch.state.heads[$0] == nil && batch.state.cursors[$0] < groups[$0].handles.count
            }
            if unresolved { break }
            guard let selected = selectNewestPhotoHeadIndex(batch.state.heads),
                  let file = batch.state.heads[selected] else { break }
            batch.files.append(file)
            batch.processed.append(file.id)
            batch.state.heads[selected] = nil
            batch.state.completed += 1
        }
        return batch
    }

    private func checkRemoteScanOwnership() throws {
        if staAlbum == nil && remoteActive { throw CameraRepositoryError.foregroundPreempted }
    }

    func discardRejectedThumbnail(handle: UInt32) async {
        await directReader?.discardThumbnail(handle: handle)
    }

    func thumbnail(handle: UInt32, priority: CameraRequestKind = .visibleThumbnail) async throws -> Data {
        #if DEBUG
        if let debugData { return debugData.thumbnailData }
        #endif
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        return try await ioGate.withCameraTransaction(priority, owner: priority == .visibleThumbnail ? "VISIBLE_THUMBNAIL" : "BACKGROUND_THUMBNAIL") {
            if let directReader { return try await directReader.thumbnail(handle: handle) }
            let response = try await session.executeResponse(operation: PTPConstants.getThumb, parameters: [handle])
            switch response.code {
            case PTPConstants.responseOK: return response.data
            case PTPConstants.noThumbnailPresent, PTPConstants.invalidObjectHandle: return Data()
            default: throw PTPSessionError.responseCode(response.code)
            }
        }
    }

    /// Ordinary AP/USB only requests FHD here. The current preview page owns
    /// the thumbnail fallback after EXIF; paired STA has its independent path.
    func preview(handle: UInt32) async throws -> Data {
        #if DEBUG
        if let debugData { return debugData.previewData }
        #endif
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        return try await ioGate.withPreviewTransaction(owner: "PREVIEW") {
            if let directReader { return try await directReader.preview(handle: handle) }
            return try await self.readFHDPreview(handle: handle)
        }
    }

    private func readFHDPreview(handle: UInt32) async throws -> Data {
        try Task.checkCancellation()
        guard fhdSupported != false else { return Data() }
        for attempt in 0...2 {
            let response = try await session.executeResponse(operation: PTPConstants.getFHDPicture,
                                                             parameters: [handle])
            if response.code == PTPConstants.responseOK, !response.data.isEmpty {
                fhdSupported = true
                return response.data
            }
            if response.code == PTPConstants.operationNotSupported {
                if fhdSupported != true { fhdSupported = false }
                return Data()
            }
            guard response.code == PTPConstants.deviceBusy, attempt < 2 else { return Data() }
            try await Task.sleep(for: .milliseconds(160))
        }
        return Data()
    }

    func readPrefix(handle: UInt32, length: Int64, retryDeviceBusy: Bool = false) async throws -> Data {
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        let generation = photoRatingCache.generation
        return try await ioGate.withPreviewTransaction(owner: "PREVIEW_EXIF") { [self] in
            let count = max(0, min(length, Int64(UInt32.max)))
            // Android readExifHeader keeps the PREVIEW_EXIF transaction while
            // retrying DeviceBusy twice, with a cancellable 160 ms delay.
            var retries = retryDeviceBusy ? 2 : 0
            while true {
                try Task.checkCancellation()
                do {
                    if let directReader {
                        let data = try await directReader.exifHeader(handle: handle, length: Int(count))
                        await self.capturePhotoRating(handle, data, origin: "header", generation: generation)
                        return data
                    }
                    let result = try await session.execute(
                        operation: PTPConstants.getPartialObjectEx,
                        parameters: [handle, 0, 0, UInt32(count & 0xFFFF_FFFF), UInt32(count >> 32)]
                    )
                    await self.capturePhotoRating(handle, result.data, origin: "header", generation: generation)
                    return result.data
                } catch PTPSessionError.responseCode(let code)
                    where code == PTPConstants.deviceBusy && retries > 0 {
                    retries -= 1
                    try await Task.sleep(for: .milliseconds(160))
                }
            }
        }
    }

    // MARK: - Nikon photo/video ratings

    /// Reads Nikon's 0xDC8A object property. The operation is deliberately
    /// kept separate from header parsing: AP/USB bodies expose this property
    /// for JPEGs and some RAWs even when it is absent from DeviceInfo.
    func readObjectRating(file: CameraFile) async throws -> Int? {
        try await ioGate.withRatingTransaction(owner: "RATING") { [self] in
            try await readObjectRatingCommand(file: file)
        }
    }

    private func readObjectRatingCommand(file: CameraFile) async throws -> Int? {
        if ratingOperationUnsupported || ratingUnsupportedExtensions.contains(file.fileExtension) {
            return nil
        }
        let generation = photoRatingCache.generation
        let response = try await session.executeResponse(
            operation: PTPConstants.getObjectPropValue,
            parameters: [file.id, PTPConstants.objectPropRating]
        )
        switch response.code {
        case PTPConstants.responseOK:
            guard generation == photoRatingCache.generation else { return nil }
            guard let rating = parseNikonObjectRating(response.data) else { return nil }
            rememberPhotoRating(file.id, rating, generation: generation, origin: "object-read")
            return rating
        case PTPConstants.operationNotSupported:
            ratingOperationUnsupported = true
            return nil
        case 0xA80A, 0xA801:
            ratingUnsupportedExtensions.insert(file.fileExtension)
            return nil
        case PTPConstants.deviceBusy:
            throw CameraRepositoryError.ratingReadDeferred
        default:
            // Permission/object errors do not prove persistent lack of
            // support; the next file may still expose the property.
            return nil
        }
    }

    /// AP/USB list path: JPEG uses the object property; a RAW property miss
    /// latches that extension and immediately falls back to its verified
    /// embedded header. Subsequent RAWs skip the doomed property probe.
    func readObjectOrRawHeaderRating(file: CameraFile) async throws -> Int? {
        let isRaw = file.fileExtension == ".nef" || file.fileExtension == ".nrw"
        guard isRaw else { return try await readObjectRating(file: file) }
        if ratingUnsupportedExtensions.contains(file.fileExtension) {
            return try await readPhotoRatingHeader(file: file)
        }
        let objectValue = try await readObjectRating(file: file)
        if objectValue != nil { return objectValue }
        ratingUnsupportedExtensions.insert(file.fileExtension)
        return try await readPhotoRatingHeader(file: file)
    }

    /// Reads at most 100 KiB first, then contiguous 8 KiB extensions up to
    /// 256 KiB. Each extension is appended to the retained prefix so a rating
    /// field split at a boundary is parsed without downloading the first block
    /// a second time. Nikon's 0x9431 is preferred, with standard 0x101B as the
    /// connection-scoped fallback when the camera explicitly rejects it.
    func readPhotoRatingHeader(file: CameraFile) async throws -> Int? {
        let waiting = ContinuousClock.now
        return try await ioGate.withRatingTransaction(owner: "RATING") { [self] in
            try await readPhotoRatingHeaderCommand(file: file,
                gateWaitMS: PTPTransferDiagnostics.milliseconds(since: waiting))
        }
    }

    private func readPhotoRatingHeaderCommand(file: CameraFile, gateWaitMS: Double) async throws -> Int? {
        let started = ContinuousClock.now
        var commandMS = 0.0
        var parseMS = 0.0
        var chunks = 0
        func parse(_ data: Data) -> Int? {
            let start = ContinuousClock.now
            defer { parseMS += PTPTransferDiagnostics.milliseconds(since: start) }
            return parsePhotoRating(data)
        }
        let firstLimit = 100 * 1024
        let extensionSize = 8 * 1024
        let maximum = 256 * 1024
        let generation = photoRatingCache.generation
        let first = try await readTimedRatingChunk(file: file, offset: 0, count: firstLimit)
        var bytes = first.data
        commandMS += first.commandMS; chunks += first.chunks
        guard bytes.count <= firstLimit else { return nil }
        var rating = parse(bytes)
        while rating == nil && bytes.count < maximum {
            let count = min(extensionSize, maximum - bytes.count)
            let next = try await readTimedRatingChunk(file: file, offset: UInt64(bytes.count), count: count)
            commandMS += next.commandMS; chunks += next.chunks
            let tail = next.data
            guard !tail.isEmpty, tail.count <= count else { break }
            bytes.append(tail)
            rating = parse(bytes)
        }
        let otherMS = max(0, PTPTransferDiagnostics.milliseconds(since: started) - commandMS - parseMS)
        PhotoRatingDiagnostics.detail("read file=\(file.fileName) bytes=\(bytes.count) chunks=\(chunks) gate=\(Int(gateWaitMS))ms command=\(Int(commandMS))ms parse=\(Int(parseMS))ms other=\(Int(otherMS))ms result=\(rating.map(String.init) ?? "unknown")")
        guard generation == photoRatingCache.generation else { return nil }
        if let rating { rememberPhotoRating(file.id, rating, generation: generation, origin: "rating-header") }
        return rating
    }

    /// The NCTG field may live in a small atom near the front or in a tail
    /// `moov`; the structural reader requests only the missing 8 KiB windows
    /// and caps the total remote windows at 32.
    func readVideoRating(file: CameraFile) async throws -> Int? {
        let generation = photoRatingCache.generation
        let rating = try await readNikonVideoRatingThrowing(fileSize: file.size) { [self] offset, count in
            try await ioGate.withRatingTransaction(owner: "RATING") {
                try await readRatingChunk(file: file, offset: offset, count: count)
            }
        }
        guard generation == photoRatingCache.generation else { return nil }
        if let rating { rememberPhotoRating(file.id, rating, generation: generation, origin: "rating-video") }
        return rating
    }

    /// Clears connection-scoped rating capability latches. Connections are
    /// normally represented by a fresh repository, but reconnect paths may
    /// explicitly reuse one while rebuilding its PTP session.
    func resetRatingCapabilityState() {
        ratingUnsupportedExtensions.removeAll()
        ratingOperationUnsupported = false
        ratingNikonHeaderUnsupported = false
        ratingStandardHeaderUnsupported = false
    }

    /// Must be called while the rating gate is held. The response code is
    /// preserved so capability state distinguishes unsupported from transient
    /// busy/error responses exactly as the Android path does.
    private func readRatingChunk(file: CameraFile, offset: UInt64, count: Int) async throws -> Data {
        try await readRatingChunkResult(file: file, offset: offset, count: count).data
    }

    private func readTimedRatingChunk(file: CameraFile, offset: UInt64, count: Int) async throws
        -> (data: Data, commandMS: Double, chunks: Int) {
        let start = ContinuousClock.now
        let result = try await readRatingChunkResult(file: file, offset: offset, count: count)
        return (result.data, result.successful ? PTPTransferDiagnostics.milliseconds(since: start) : 0,
                result.successful ? 1 : 0)
    }

    private func readRatingChunkResult(file: CameraFile, offset: UInt64, count: Int) async throws -> (data: Data, successful: Bool) {
        guard count > 0, count <= Int(UInt32.max), offset <= UInt64.max - UInt64(count) else { return (Data(), false) }
        if !ratingNikonHeaderUnsupported {
            let response = try await session.executeResponse(
                operation: PTPConstants.getPartialObjectEx,
                parameters: [file.id, UInt32(truncatingIfNeeded: offset),
                              UInt32(truncatingIfNeeded: offset >> 32), UInt32(count), 0]
            )
            if response.code == PTPConstants.responseOK {
                return (response.data, true)
            }
            if response.code == PTPConstants.deviceBusy {
                throw CameraRepositoryError.ratingReadDeferred
            }
            if response.code != PTPConstants.operationNotSupported {
                return (Data(), false)
            }
            ratingNikonHeaderUnsupported = true
        }
        guard !ratingStandardHeaderUnsupported, offset <= UInt64(UInt32.max) else { return (Data(), false) }
        let response = try await session.executeResponse(
            operation: PTPConstants.getPartialObject,
            parameters: [file.id, UInt32(offset), UInt32(count)]
        )
        if response.code == PTPConstants.deviceBusy {
            throw CameraRepositoryError.ratingReadDeferred
        }
        if response.code == PTPConstants.operationNotSupported {
            ratingStandardHeaderUnsupported = true
            return (Data(), false)
        }
        return response.code == PTPConstants.responseOK ? (response.data, true) : (Data(), false)
    }

    func download(handle: UInt32, size: UInt64, fileName: String,
                  captureDate: String? = nil, to directory: URL,
                  progress: (@Sendable (Double) -> Void)? = nil,
                  progressBytes: (@Sendable (UInt64, UInt64) -> Void)? = nil) async throws -> URL {
        try await downloadResult(handle: handle, size: size, fileName: fileName,
                                 captureDate: captureDate, to: directory) { value in
            progress?(value.fraction)
            progressBytes?(value.downloaded, value.total)
        }.url
    }

    /// NikonCamera.downloadToFile: the activity reservation spans size lookup,
    /// every data chunk and final save. Individual PTP transactions below use
    /// transfer slices so a reserved interactive preview can run between them.
    func downloadResult(handle: UInt32, size: UInt64, fileName: String,
                        captureDate: String? = nil, to directory: URL, captureHeader: Bool = false,
                        progress: (@Sendable (TransferDownloadProgress) -> Void)? = nil) async throws -> CameraDownloadResult {
        try await ioGate.withDownloadActivity(prioritizePhoto: isUSBConnection && !supportsVideoResume(fileName: fileName)) {
            try await self.downloadResultImpl(handle: handle, size: size, fileName: fileName,
                                              captureDate: captureDate, to: directory,
                                              captureHeader: captureHeader, progress: progress)
        }
    }

    private func downloadResultImpl(handle: UInt32, size: UInt64, fileName: String,
                                    captureDate: String? = nil, to directory: URL,
                                    captureHeader: Bool = false,
                                    progress: (@Sendable (TransferDownloadProgress) -> Void)? = nil) async throws -> CameraDownloadResult {
        #if DEBUG
        if let debugData {
            let startedAt = ContinuousClock.now
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bytes = UInt64(debugData.thumbnailData.count)
            for step in 1...20 {
                try await Task.sleep(for: .milliseconds(200))
                progress?(TransferDownloadProgress(fraction: Double(step) / 20.0,
                                                   downloaded: bytes * UInt64(step) / 20,
                                                   total: bytes,
                                                   bytesPerSecond: max(1, Int64(bytes / 4))))
            }
            let preferred = directory.appendingPathComponent(URL(fileURLWithPath: fileName).lastPathComponent)
            let url = try OutputFileNameReservations.shared.withReservedName(preferred, policy: .original) { output in
                try debugData.thumbnailData.write(to: output, options: .withoutOverwriting)
                return output
            }
            progress?(TransferDownloadProgress(fraction: 1,
                                               downloaded: UInt64(debugData.thumbnailData.count),
                                               total: UInt64(debugData.thumbnailData.count)))
            return CameraDownloadResult(url: url, bytes: UInt64(debugData.thumbnailData.count),
                                        transferredBytes: UInt64(debugData.thumbnailData.count),
                                        startedAt: startedAt, headerPrefix: debugData.thumbnailData)
        }
        #endif
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        let videoTransfer = supportsVideoResume(fileName: safeName)
        let temporary = directory.appendingPathComponent(
            transferPartialFileName(size: size, captureDate: captureDate, fileName: safeName), isDirectory: false
        )
        defer {
            // TransferViewModel removes still-image parts on every failure,
            // including a complete data phase followed by an error response.
            // This runs after the writer closes; successful publication has
            // already moved the part. Only videos retain resumable bytes.
            if !videoTransfer {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        // Android only resumes video-family objects. A stale still-image part
        // must never turn the next photo into a resumed transfer.
        if !videoTransfer { try? FileManager.default.removeItem(at: temporary) }
        let existingSize = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { UInt64(max(0, $0)) } ?? 0
        let resumeOffset = transferResumeOffset(existingSize: existingSize, totalSize: size, reportedSize: size) ?? 0
        if resumeOffset == 0 { try? FileManager.default.removeItem(at: temporary) }
        if resumeOffset > 0 && resumeOffset < existingSize {
            let trim = try FileHandle(forWritingTo: temporary)
            try trim.truncate(atOffset: resumeOffset)
            try trim.close()
        }
        if size > 0, size != UInt64(UInt32.max), resumeOffset == size {
            let startedAt = ContinuousClock.now
            let destination = try finalizeDownloadedFile(temporary: temporary, directory: directory, fileName: safeName)
            return CameraDownloadResult(url: destination, bytes: size, transferredBytes: 0,
                                        startedAt: startedAt, headerPrefix: nil)
        }
        if !FileManager.default.fileExists(atPath: temporary.path) {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let output = try FileHandle(forWritingTo: temporary)
        // Also close if size lookup or policy validation fails before the
        // writer takes ownership. Closing an already-closed handle is harmless.
        defer { try? output.close() }
        try output.seek(toOffset: resumeOffset)
        // TransferViewModel prepares/seeks the output before downloadToFile's
        // clock begins. Size lookup, camera waits, writes and final save remain
        // in the same end-to-end duration; never report recv-only throughput.
        let startedAt = ContinuousClock.now
        #if DEBUG
        // Android's normal download loop has no per-recv diagnostic counters.
        // Enable explicitly from a development launch, never merely by Debug.
        let diagnostics = ((staAlbum != nil && PTPTransferDiagnostics.isEnabledForDevelopmentLaunch) ||
                           (isUSBConnection && PTPTransferDiagnostics.isEnabledForUSBLaunch))
            ? PTPTransferDiagnostics() : nil
        #else
        let diagnostics: PTPTransferDiagnostics? = nil
        #endif
        diagnostics?.beginFile(size: size)
        var diagnosticSuccess = false
        var diagnosticFinalizeMS: Double = 0
        defer { diagnostics?.finish(success: diagnosticSuccess, finalizeMS: diagnosticFinalizeMS) }
        var effectiveSize = size
        if size == UInt64(UInt32.max) || size == 0 {
            let response = try await ioGate.withTransferSlice {
                try await session.executeReceivingBuffered(operation: PTPConstants.getObjectSize, parameters: [handle],
                                                           timeoutNanoseconds: PTPConstants.cameraReadTimeoutNanoseconds)
            }
            // Android treats a complete negative/empty size reply as unknown,
            // then uses GET_OBJECT for a fresh file. Transport errors propagate.
            if response.code == PTPConstants.responseOK, response.data.count >= 8 {
                let resolved = response.data.readUInt64LE(at: 0)
                if resolved > 0, resolved <= UInt64(Int64.max) { effectiveSize = resolved }
            }
        }
        var sizeKnown = effectiveSize > 0 && effectiveSize != UInt64(UInt32.max)
        // Snapshot after size resolution, immediately before the first file
        // data command. Page changes must not switch strategy midway through.
        let highThroughput = preferHighThroughputTransfers
        let requiresBoundedUSBRead = isUSBConnection && (!sizeKnown || effectiveSize > transferChunkSize)
        // A previous unsupported response must not make the next large USB
        // object enter ImageCaptureCore's whole-object Data callback either.
        guard !requiresBoundedUSBRead || partialObjectSupported != false else {
            throw CameraRepositoryError.resumeUnavailable
        }
        let boundedUnknownUSB = requiresBoundedUSBRead && !sizeKnown
        let usePartial = boundedUnknownUSB || shouldUsePartialObjectDownload(
            partialObjectSupported: partialObjectSupported, effectiveSize: effectiveSize,
            resumeOffset: resumeOffset, isUSBConnection: isUSBConnection,
            preferHighThroughput: highThroughput,
            // Android raw USB can stream GetObject directly. ImageCaptureCore
            // returns the entire pass-through data phase in memory, so iOS USB
            // switches to bounded partial requests above one callback chunk.
            forcePartial: directReader != nil || (isUSBConnection && effectiveSize > transferChunkSize),
            // The transport may force bounded reads for stills (for example
            // ImageCaptureCore); the policy gate must preserve that path.
            videoTransfer: videoTransfer
        )
        if resumeOffset > 0 && !usePartial { throw CameraRepositoryError.resumeUnavailable }
        let singleRequestPhoto = !videoTransfer && !isUSBConnection
        if usePartial && singleRequestPhoto && effectiveSize > UInt64(Int32.max) {
            throw CameraDownloadError.photoExceedsSingleRequestLimit
        }
        let writer = CameraDownloadWriter(output: output, resumeOffset: resumeOffset,
                                           totalHint: sizeKnown ? effectiveSize : 0, captureHeader: captureHeader,
                                           startedAt: startedAt, onProgress: progress, diagnostics: diagnostics)
        defer { try? writer.close() }
        let chunkSize = transferDownloadChunkSize(effectiveSize: effectiveSize,
                                                  isUSBConnection: isUSBConnection, preferHighThroughput: highThroughput,
                                                  videoTransfer: videoTransfer)
        var firstPartial = true
        var useFull = !usePartial
        while usePartial && (!sizeKnown || writer.bytes < effectiveSize) {
            try Task.checkCancellation()
            let offset = writer.bytes
            let request = sizeKnown ? min(chunkSize, effectiveSize - offset) : chunkSize
            diagnostics?.beginChunk(offset: offset, requested: request)
            let response = try await ioGate.withTransferSlice {
                diagnostics?.gateAcquired()
                var responseCode: UInt16?
                defer { diagnostics?.endChunk(code: responseCode) }
                let response = try await session.executeReceiving(
                    operation: PTPConstants.getPartialObjectEx,
                    parameters: [handle, UInt32(truncatingIfNeeded: offset), UInt32(truncatingIfNeeded: offset >> 32),
                                  UInt32(truncatingIfNeeded: request), UInt32(truncatingIfNeeded: request >> 32)],
                    sink: writer.sink, timeoutNanoseconds: PTPConstants.cameraReadTimeoutNanoseconds
                )
                responseCode = response.code
                return response
            }
            guard response.code == PTPConstants.responseOK else {
                // A non-empty failed phase has already written bytes. Only an
                // unsupported first phase with zero received bytes may fall back.
                if firstPartial && response.receivedByteCount == 0 && resumeOffset == 0 &&
                    response.code == PTPConstants.operationNotSupported {
                    partialObjectSupported = false
                    // ImageCaptureCore cannot stream GetObject into the file;
                    // refuse that unbounded fallback for unknown objects and
                    // known objects larger than its callback budget alike.
                    if requiresBoundedUSBRead {
                        throw CameraRepositoryError.resumeUnavailable
                    }
                    useFull = true
                    break
                }
                throw CameraDownloadError.response(response.code)
            }
            partialObjectSupported = true
            if let expected = response.declaredByteCount,
               let mismatch = mismatchedFullObjectSize(received: response.receivedByteCount,
                                                       declared: expected, known: 0) {
                throw CameraDownloadError.incomplete(received: response.receivedByteCount, expected: mismatch)
            }
            if !sizeKnown && response.receivedByteCount == 0 {
                effectiveSize = writer.bytes
                sizeKnown = true
                break
            }
            guard response.receivedByteCount > 0 else {
                throw CameraDownloadError.incomplete(received: writer.bytes, expected: effectiveSize)
            }
            if singleRequestPhoto && writer.bytes != effectiveSize {
                throw CameraDownloadError.incomplete(received: writer.bytes, expected: effectiveSize)
            }
            if !sizeKnown && response.receivedByteCount < request {
                effectiveSize = writer.bytes
                sizeKnown = true
                break
            }
            // Like Android, advance by actual bytes. A shorter complete data
            // phase is valid; the following command reads the missing interval.
            firstPartial = false
        }
        if useFull {
            diagnostics?.beginChunk(offset: writer.bytes, requested: sizeKnown ? effectiveSize : 0)
            let response = try await ioGate.withTransferSlice {
                diagnostics?.gateAcquired()
                var responseCode: UInt16?
                defer { diagnostics?.endChunk(code: responseCode) }
                let response = try await session.executeReceiving(operation: PTPConstants.getObject,
                                                   parameters: [handle], sink: writer.sink,
                                                   timeoutNanoseconds: PTPConstants.cameraReadTimeoutNanoseconds)
                responseCode = response.code
                return response
            }
            guard response.code == PTPConstants.responseOK else { throw CameraDownloadError.response(response.code) }
            // A truncated data phase can declare its own short length. Android
            // checks both that declaration and ObjectInfo/GetObjectSize before
            // publishing, even when the declaration is internally consistent.
            if let mismatch = mismatchedFullObjectSize(
                received: writer.bytes, declared: response.declaredByteCount ?? 0,
                known: sizeKnown ? effectiveSize : 0
            ) {
                throw CameraDownloadError.incomplete(received: writer.bytes, expected: mismatch)
            }
        } else if sizeKnown && writer.bytes != effectiveSize {
            throw CameraDownloadError.incomplete(received: writer.bytes, expected: effectiveSize)
        }
        let finalizeStarted = ContinuousClock.now
        defer { diagnosticFinalizeMS = PTPTransferDiagnostics.milliseconds(since: finalizeStarted) }
        try writer.close()
        let destination = try finalizeDownloadedFile(temporary: temporary, directory: directory, fileName: safeName)
        diagnosticSuccess = true
        return writer.result(url: destination)
    }

    /// Android first attempts the provider rename, then copies the completed
    /// temporary document when rename is refused. Keep both paths behind one
    /// helper so complete-size resume and a fresh download have identical
    /// collision handling and never overwrite an existing original.
    private func finalizeDownloadedFile(
        temporary: URL,
        directory: URL,
        fileName: String,
    ) throws -> URL {
        do { return try finalizeTransferTemporary(temporary: temporary, directory: directory, fileName: fileName) }
        catch {
            // Both save paths failed. Android removes this completed temporary
            // file: resuming cannot fix a provider rename/copy failure.
            try? FileManager.default.removeItem(at: temporary)
            let missing = (error as NSError).domain == NSCocoaErrorDomain &&
                [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains((error as NSError).code)
            throw CameraDownloadError.save(missing ? AppLocalized.resource("error_dir_invalid") : error.localizedDescription)
        }
    }

    func scanCatalog(
        preserveExisting: Bool = false,
        resumeSnapshot: PhotoScanSnapshot? = nil,
        detectNewHandles: Bool = false,
        loadingRange: PhotoLoadingRange = .all,
        currentLoadingRange: (@Sendable () async -> PhotoLoadingRange)? = nil,
        nextBatchSize: @escaping @Sendable () async -> Int = { 12 },
        onBatch: (@Sendable ([CameraFile]) async throws -> Void)? = nil
    ) async throws -> PhotoScanResult {
        activeCatalogScans += 1
        defer { activeCatalogScans -= 1; scheduleObjectResolver() }

        // A new non-resume enumeration is Android's connection snapshot
        // boundary. Do this before the debug catalog early return as well, so
        // simulator fixtures cannot accidentally retain a previous session's
        // ratings.
        var reusable = resumeSnapshot.flatMap { $0.catalogRevision == scanCatalogRevision ? $0 : nil }
        if !preserveExisting && reusable == nil {
            invalidatePhotoRatings()
            resetRatingCapabilityState()
        }

        #if DEBUG
        if let debugData {
            let files = debugData.files
            if let onBatch, !preserveExisting {
                var start = 0
                while start < files.count {
                    try Task.checkCancellation()
                    let count = fileScanBatchSize(processed: start, requested: await nextBatchSize(), fastFirstBatch: true)
                    let end = min(start + count, files.count)
                    try await onBatch(Array(files[start..<end]))
                    start = end
                }
            }
            return PhotoScanResult(files: files, removedHandles: [],
                                   addedHandles: Set(files.map(\.id)),
                                   handleQueriesSucceeded: true, metadataComplete: true,
                                   filterStorageIDs: Array(Set(files.flatMap(\.storageIDs))).sorted())
        }
        #endif

        // CameraViewModel.loadFiles returns before issuing StorageIDs when
        // remote monitoring owns the channel, and the iOS list must not race
        // that foreground owner with its first catalog command. FHD pauses
        // are held until the preview releases the same session.
        try await waitForForegroundPreview()
        // Do not interpret temporary application-mode no-card responses as deletion.
        guard !remoteControlModeSet, !movieApplicationOperationSet,
              !movieApplicationPropertySet else { throw CameraRepositoryError.foregroundPreempted }
        // A deletion can arrive while foreground preview holds this scan.
        // Revalidate the caller's captured value after that suspension too.
        reusable = resumeSnapshot.flatMap { $0.catalogRevision == scanCatalogRevision ? $0 : nil }

        // A resume snapshot is valid only for this repository/session.  A fresh
        // scan invalidates old rows and cache state exactly like Android.
        if reusable == nil { scanSnapshot = nil }
        if !preserveExisting && reusable == nil {
            catalogFiles.removeAll(keepingCapacity: true)
            indexedCatalogFiles.removeAll(keepingCapacity: true)
            catalogOrder.removeAll(keepingCapacity: true)
            knownHandles.removeAll(keepingCapacity: true)
            catalogStorageIDs.removeAll(keepingCapacity: true)
            scanSnapshot = nil
        }
        var existingFiles = preserveExisting
            ? catalogOrder.compactMap { catalogFiles[$0] }
            : []
        var existingHandles = Set(existingFiles.map(\.id))
        var addedHandles = Set<UInt32>()
        var removedHandles = Set<UInt32>()

        let enumerationRevision = scanCatalogRevision
        let storageIDs: [UInt32]
        var groups: [(storage: UInt32, handles: [UInt32])]
        var filterStorageIDs: [UInt32]
        var directStorageIDsByHandle: [UInt32: Set<UInt32>] = [:]
        var handleQueriesSucceeded = true
        if let reusable {
            storageIDs = reusable.storageIDs
            groups = reusable.remainingHandles.map { ($0.storageID, $0.handles) }
            handleQueriesSucceeded = reusable.handleQueriesSucceeded
            filterStorageIDs = reusable.filterStorageIDs
            directStorageIDsByHandle = reusable.directStorageIDsByHandle
            scanSnapshot = reusable
        } else {
            let raw: [UInt32]
            do {
                raw = try await loadStorageIDs()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Android 1.97: only a successful empty response proves no card.
                // Preserve the existing album on rejected/truncated queries.
                if staAlbum != nil { throw CameraRepositoryError.transportLost }
                throw error
            }
            // Android ignores sentinel/invalid stores and, for non-STA
            // transports, stores whose low 16 bits are zero. STA also drops
            // only the sentinel values because its wildcard mapping is
            // handled by queryStorageID below.
            storageIDs = Array(Set(raw.filter { id in
                if staAlbum != nil { return id != 0 && id != .max }
                // Keep the Android predicate literally: non-STA uses only
                // the low-16-bit no-card marker, without an extra sentinel
                // rule that could change a camera's reported store list.
                return (id & 0xFFFF) != 0
            })).sorted()
            if storageIDs.isEmpty {
                // A validated empty response removes only the established
                // baseline. Failed/malformed responses have already thrown.
                let hasKnownBaseline = !knownHandles.isEmpty
                removedHandles = hasKnownBaseline ? knownHandles.intersection(existingHandles) : []
                for handle in removedHandles {
                    catalogFiles.removeValue(forKey: handle)
                    indexedCatalogFiles.removeValue(forKey: handle)
                }
                catalogOrder.removeAll { removedHandles.contains($0) }
                if hasKnownBaseline {
                    existingFiles.removeAll { removedHandles.contains($0.id) }
                    existingHandles.subtract(removedHandles)
                }
                knownHandles.removeAll()
                catalogStorageIDs.removeAll()
                scanSnapshot = nil
                catalogReady = true
                lastCatalogCheck = .now
                publishCatalog()
                return PhotoScanResult(files: existingFiles, removedHandles: removedHandles,
                                       addedHandles: [], handleQueriesSucceeded: false,
                                       metadataComplete: true, filterStorageIDs: [])
            }
            let queries = storageIDs
            var rawGroups: [(storage: UInt32, handles: [UInt32])] = []
            for storage in queries {
                let query = queryStorageID(storage)
                var attempts = 1
                var result = try await loadObjectHandlesWithStatus(storageID: query)
                while staAlbum != nil && !result.successful,
                      result.responseCode == PTPConstants.deviceBusy && attempts < 3 {
                    try await Task.sleep(nanoseconds: 750_000_000)
                    attempts += 1
                    result = try await loadObjectHandlesWithStatus(storageID: query)
                }
                guard result.successful else {
                    handleQueriesSucceeded = false
                    if staAlbum != nil { throw CameraRepositoryError.transportLost }
                    // Android keeps the partial list for a non-STA response
                    // failure and skips authoritative cache reconciliation.
                    rawGroups.append((storage, []))
                    continue
                }
                // Nikon returns handles old→new; Android reverses every
                // storage (USB, STA and aggregate queries) to read newest first.
                // Android's merged catalog keeps the first occurrence of an identical handle;
                // direct STA derives all card memberships from raw groups.
                let ordered = Array(result.handles.reversed())
                rawGroups.append((storage, ordered))
            }
            if directReader != nil {
                let layout = analyzeSTADirectStorageLayout(rawGroups.map { ($0.storage, $0.handles) })
                directStorageIDsByHandle = layout.storageIDsByHandle
                filterStorageIDs = layout.filterStorageIDs
            } else {
                filterStorageIDs = storageIDs
            }
            var seenHandles = Set<UInt32>()
            groups = rawGroups.map { group in
                (group.storage, group.handles.filter { seenHandles.insert($0).inserted })
            }
            let currentHandles = Set(rawGroups.flatMap(\.handles))
            if handleQueriesSucceeded {
                if preserveExisting { removedHandles = knownHandles.subtracting(currentHandles) }
                if detectNewHandles { addedHandles = currentHandles.subtracting(knownHandles) }
                for handle in removedHandles { indexedCatalogFiles.removeValue(forKey: handle) }
                existingFiles = reconcilePublishedCameraFiles(existingFiles,
                                                               currentHandles: currentHandles,
                                                               indexedByHandle: indexedCatalogFiles)
                catalogFiles = Dictionary(existingFiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                catalogOrder = existingFiles.map(\.id)
                existingHandles = Set(existingFiles.map(\.id))
                knownHandles = currentHandles
                catalogStorageIDs = storageIDs
            }
            scanSnapshot = enumerationRevision == scanCatalogRevision ? PhotoScanSnapshot(
                catalogRevision: enumerationRevision,
                storageIDs: storageIDs,
                handleOrders: groups.map { ($0.storage, $0.handles) },
                processedHandles: Set(existingHandles),
                handleQueriesSucceeded: handleQueriesSucceeded,
                filterStorageIDs: filterStorageIDs,
                directStorageIDsByHandle: directStorageIDsByHandle
            ) : nil
            // Preserve the Android refresh contract: metadata is requested only
            // for handles not already published in this camera session.
            if preserveExisting {
                groups = groups.map { ($0.storage, $0.handles.filter { !existingHandles.contains($0) }) }
            }
        }
        try await waitForForegroundPreview()
        if let directReader {
            let preparationGroups = groups
            do {
                try await ioGate.withCommand { try await directReader.prepare(groups: preparationGroups) }
            } catch {
                if staAlbum != nil { throw CameraRepositoryError.transportLost }
                throw error
            }
        }

        var files = existingFiles
        var byIdentity = Dictionary(uniqueKeysWithValues: files.map { (logicalIdentity($0), $0) })
        var indexed = indexedCatalogFiles
        var batch: [CameraFile] = []
        var metadataComplete = true
        var mergeState = CatalogMergeState(cursors: Array(repeating: 0, count: groups.count),
                                           heads: Array(repeating: nil, count: groups.count))
        let totalCatalogHandles = groups.reduce(0) { $0 + $1.handles.count }
        // A handle becomes resumable only after the batch containing it was
        // accepted by the list owner.  Android marks the snapshot in the same
        // accepted section; marking it when ObjectInfo returns would skip rows
        // if the UI callback is cancelled or the session generation changes.
        var pendingProcessedHandles: [UInt32] = []
        var stoppedAtLoadingRange = false
        var loadingRangeAtStop: PhotoLoadingRange?
        while mergeState.completed < totalCatalogHandles {
            try Task.checkCancellation()
            try await waitForForegroundPreview()
            let requested = metadataComplete ? await nextBatchSize() : 12
            let batchLimit = directReader != nil && mergeState.completed > 0 && mergeState.completed < 4
                ? 3 : fileScanBatchSize(processed: mergeState.completed, requested: requested, fastFirstBatch: true)
            let requestBudget = directReader != nil || mergeState.completed < 4
                ? max(groups.count, batchLimit + groups.count - 1)
                : batchLimit

            let merged: CatalogMergeBatch
            do {
                if staAlbum != nil || isUSBConnection {
                    merged = try await readMergedCatalogBatch(groups: groups, state: mergeState,
                        limit: batchLimit, budget: requestBudget, total: totalCatalogHandles, pauseBetweenCommands: true)
                } else {
                    let scanGroups = groups, scanState = mergeState
                    merged = try await ioGate.withCommand {
                        try await self.readMergedCatalogBatch(groups: scanGroups, state: scanState,
                            limit: batchLimit, budget: requestBudget, total: totalCatalogHandles, pauseBetweenCommands: false)
                    }
                }
            } catch CameraRepositoryError.foregroundPreempted {
                throw CameraRepositoryError.foregroundPreempted
            } catch is CancellationError { throw CancellationError() }
            catch {
                if staAlbum != nil { throw CameraRepositoryError.transportLost }
                throw error
            }
            guard merged.state.completed > mergeState.completed || merged.requests > 0 else {
                throw CameraRepositoryError.invalidDataset
            }
            mergeState = merged.state
            metadataComplete = metadataComplete && merged.successful
            pendingProcessedHandles += merged.processed
            let output = merged.files
            if output.isEmpty { continue }
            let parsedOutput = output.map { rawFile in
                replacingStorageIDs(rawFile, with: directStorageIDsByHandle[rawFile.id] ?? [])
            }
            let rangeInput = files + parsedOutput
            let observedDays = Set(rangeInput.compactMap { validPhotoCaptureDay($0.captureDate) })
            let batchRange = await currentLoadingRange?() ?? loadingRange
            let boundaryReached = batchRange.days > 0 && observedDays.count > batchRange.days
            let allowedRange = newestCaptureDaysRange(rangeInput, days: batchRange.days)
            let acceptedOutput = boundaryReached && allowedRange != nil
                ? parsedOutput.filter { file in
                    file.captureDate == nil || allowedRange?.contains(file.captureDate) == true
                }
                : parsedOutput
            let acceptedIDs = Set(acceptedOutput.map(\.id))
            for file in acceptedOutput {
                let key = logicalIdentity(file)
                indexed[file.id] = file
                if let old = byIdentity[key] {
                    let merged = old.storageIDs == old.storageIDs.union(file.storageIDs)
                        ? old
                        : CameraFile(id: old.id, storageID: old.storageID, format: old.format,
                                     size: old.size, fileName: old.fileName,
                                     captureDate: old.captureDate, isProtected: old.isProtected,
                                     storageIDs: old.storageIDs.union(file.storageIDs))
                    if merged != old, let position = files.firstIndex(of: old) {
                        files[position] = merged
                        byIdentity[key] = merged
                        if let pendingIndex = batch.firstIndex(where: { $0.id == old.id }) {
                            batch[pendingIndex] = merged
                        } else {
                            // The primary row was published in an earlier
                            // batch. Deliver its membership replacement now.
                            batch.append(merged)
                        }
                    }
                } else {
                    byIdentity[key] = file
                    files.append(file)
                    batch.append(file)
                }
            }
            if !batch.isEmpty { try await onBatch?(batch) }
            // Only accepted rows survive a page pause. Without this checkpoint
            // returning from remote would reread every partial-scan ObjectInfo.
            catalogFiles = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            indexedCatalogFiles = indexed
            catalogOrder = files.map(\.id)
            if boundaryReached {
                // Preserve the first batch crossing the boundary for the
                // next wider scan. Accepted rows are committed; the tail is
                // deliberately left unprocessed in the snapshot.
                let acceptedProcessed = pendingProcessedHandles.filter { acceptedIDs.contains($0) }
                scanSnapshot?.processedHandles.formUnion(acceptedProcessed)
                stoppedAtLoadingRange = true
                loadingRangeAtStop = batchRange
                catalogFiles = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                indexedCatalogFiles = indexed
                catalogOrder = files.map(\.id)
                catalogReady = handleQueriesSucceeded
                lastCatalogCheck = .now
                publishCatalog()
                break
            }
            scanSnapshot?.processedHandles.formUnion(pendingProcessedHandles)
            batch.removeAll(keepingCapacity: true)
            pendingProcessedHandles.removeAll(keepingCapacity: true)
        }
        if !stoppedAtLoadingRange, !batch.isEmpty { try await onBatch?(batch) }
        // The final partial batch is accepted only after its callback returns;
        // duplicate logical rows may have no UI addition but still count as
        // consumed handles in the resumable Android snapshot.
        if !stoppedAtLoadingRange {
            scanSnapshot?.processedHandles.formUnion(pendingProcessedHandles)
        }
        try Task.checkCancellation()
        catalogFiles = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        indexedCatalogFiles = indexed
        catalogOrder = files.map(\.id)
        // Only a complete handle snapshot is authoritative. Android keeps the
        // previous baseline after a partial/non-STA response so the next scan
        // can still compute real additions/removals instead of diffing against
        // an incomplete list.
        if handleQueriesSucceeded {
            // The successful handle enumeration above owns this baseline.
            // Resume groups omit already consumed backup aliases; rebuilding
            // from them and visible rows would classify old aliases as new.
            catalogStorageIDs = storageIDs
        }
        // Incomplete ObjectInfo forbids authoritative cache pruning, but a
        // successful handle baseline can still process new/deleted objects.
        catalogReady = handleQueriesSucceeded
        lastCatalogCheck = .now
        if catalogReady && !stoppedAtLoadingRange { scanSnapshot = nil }
        publishCatalog()
        return PhotoScanResult(files: files, removedHandles: removedHandles,
                               addedHandles: addedHandles,
                               handleQueriesSucceeded: handleQueriesSucceeded,
                               metadataComplete: metadataComplete,
                               filterStorageIDs: filterStorageIDs,
                               stoppedAtLoadingRange: stoppedAtLoadingRange,
                               loadingRangeAtStop: loadingRangeAtStop)
    }

    private func logicalIdentity(_ file: CameraFile) -> String {
        "\(file.fileName)|\(file.size)|\(file.captureDate ?? "")"
    }

    /// Compatibility entry point used by non-list callers.
    func loadCatalog(onBatch: (@Sendable ([CameraFile]) async throws -> Void)? = nil) async throws -> [CameraFile] {
        try await scanCatalog(onBatch: onBatch).files
    }

    /// Metadata stream used by the photo list. The underlying scan remains
    /// serialized on this repository actor; each accepted 12-item batch is
    /// yielded at the same boundary as Android's pipeline.
    private func queryStorageID(_ storage: UInt32) -> UInt32 {
        staAlbum != nil && storage & 0xFFFF == 0 ? .max : storage
    }
    private func catalogCommand(_ operation: UInt16, _ parameters: [UInt32] = []) async throws -> PTPResponse {
        var attempts = 0
        while true {
            let response = try await ioGate.withCommand {
                try await session.executeResponse(operation: operation, parameters: parameters, timeoutNanoseconds: 60_000_000_000)
            }
            if response.code == PTPConstants.responseOK { return response }
            attempts += 1
            if (staAlbum != nil || operation == PTPConstants.getStorageIDs),
               response.code == PTPConstants.deviceBusy && attempts < 3 {
                try await Task.sleep(nanoseconds: 750_000_000)
            } else { throw PTPSessionError.responseCode(response.code) }
        }
    }

    func catalogUpdates() -> AsyncStream<[CameraFile]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            catalogContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeCatalogListener(id) } }
        }
    }
    private func removeCatalogListener(_ id: UUID) { catalogContinuations.removeValue(forKey: id) }
    private func publishCatalog() {
        let files = catalogOrder.compactMap { catalogFiles[$0] }
        for continuation in catalogContinuations.values { continuation.yield(files) }
    }
    func stopMonitoring() {
        eventResolveTask?.cancel(); eventResolveTask = nil
        catalogReady = false; pendingObjects.removeAll()
        catalogContinuations.values.forEach { $0.finish() }
        catalogContinuations.removeAll()
    }
    func receiveEvent(_ payload: Data) {
        if let event = STAEvent.socket(payload) { receiveEvent(event) }
    }
    func receiveEvent(_ event: STAEvent) {
        switch event.code {
        case 0x4002:
            guard event.handle != 0, event.handle != .max,
                  !knownHandles.contains(event.handle), catalogFiles[event.handle] == nil else { return }
            if pendingObjects[event.handle] == nil { pendingObjects[event.handle] = (0, .now.advanced(by: .milliseconds(90))) }
            scheduleObjectResolver()
        case 0x4003:
            pendingObjects.removeValue(forKey: event.handle)
            if event.handle != 0 && event.handle != .max && catalogReady && !knownHandles.contains(event.handle) { return }
            // Android requestHandleCatalogSync invalidates the paused/range-
            // limited cursor immediately, before idle reconciliation can run.
            scanCatalogRevision &+= 1
            scanSnapshot = nil
            catalogSyncRequested = true
        default: break
        }
    }
    private var backgroundReadsAllowed: Bool {
        catalogReady && !catalogLoading && activeForegroundReads == 0 &&
            !remoteActive && !fhdActive && !transfersBusy && !effectPreviewActive
    }
    /// Android's 2 s polling and 10 s handle-only reconciliation. Never turn a
    /// failed/DeviceBusy response into an authoritative empty card.
    func maintainCatalogIfIdle() async {
        // Android's event poller runs for USB and Wi-Fi. The transport only
        // changes how storage IDs are queried; the idle gate is shared.
        guard backgroundReadsAllowed, !(await session.hasPendingCommand) else { return }
        if catalogSyncRequested || lastCatalogCheck.duration(to: .now) >= .seconds(10) {
            catalogSyncRequested = false
            lastCatalogCheck = .now
            do { try await syncHandleCatalog() } catch { catalogSyncRequested = true }
        }
        guard backgroundReadsAllowed, !Task.isCancelled else { return }
        do {
            var result = try await ioGate.withEventPoll(background: true) {
                try await session.executeResponse(operation: PTPConstants.nikonCompatibilityInit, timeoutNanoseconds: 60_000_000_000)
            }
            var extended = true
            if result.code == PTPConstants.operationNotSupported {
                extended = false
                result = try await ioGate.withEventPoll(background: true) {
                    try await session.executeResponse(operation: 0x90C7, timeoutNanoseconds: 60_000_000_000)
                }
            }
            if result.code == PTPConstants.responseOK {
                for event in STAEvent.polled(result.data, extended: extended) ?? [] { receiveEvent(event) }
            }
        } catch {}
        scheduleObjectResolver()
    }
    private func syncHandleCatalog() async throws {
        var current = Set<UInt32>()
        for query in Set(catalogStorageIDs.map(queryStorageID)).sorted() {
            let reply = try await catalogCommand(PTPConstants.getObjectHandles,
                [query, .max, 0])
            guard let handles = PTPDatasetParser.readObjectHandles(reply.data) else { throw CameraRepositoryError.invalidDataset }
            current.formUnion(handles)
        }
        guard backgroundReadsAllowed, !Task.isCancelled else { catalogSyncRequested = true; return }
        let removed = knownHandles.subtracting(current)
        for handle in removed {
            indexedCatalogFiles.removeValue(forKey: handle)
            pendingObjects.removeValue(forKey: handle)
            await directReader?.invalidate(handle: handle)
        }
        if !removed.isEmpty {
            let published = catalogOrder.compactMap { catalogFiles[$0] }
            let reconciled = reconcilePublishedCameraFiles(published,
                                                           currentHandles: current,
                                                           indexedByHandle: indexedCatalogFiles)
            catalogFiles = Dictionary(reconciled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            catalogOrder = reconciled.map(\.id)
        }
        knownHandles.subtract(removed)
        if !removed.isEmpty { publishCatalog() }
        for handle in current.subtracting(knownHandles) { receiveEvent(STAEvent(code: 0x4002, handle: handle)) }
    }
    private func scheduleObjectResolver() {
        guard eventResolveTask == nil, backgroundReadsAllowed,
              let earliest = pendingObjects.values.map(\.ready).min() else { return }
        eventResolveTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: earliest) } catch { return }
            await self?.resolvePendingObjects()
        }
    }
    private func resolvePendingObjects() async {
        defer { eventResolveTask = nil; scheduleObjectResolver() }
        guard backgroundReadsAllowed, !Task.isCancelled else { return }
        let ready = Array(pendingObjects.filter { $0.value.ready <= .now }.keys.sorted().prefix(16))
        if let directReader, ready.contains(where: { pendingObjects[$0]?.attempts == 0 }) {
            // Metadata refresh is compact; missing data still falls back to headers.
            let storageIDs = catalogStorageIDs
            try? await ioGate.withCommand { try await directReader.refreshDates(storageIDs: storageIDs) }
        }
        for handle in ready {
            guard backgroundReadsAllowed, !Task.isCancelled else { return }
            if knownHandles.contains(handle) { pendingObjects.removeValue(forKey: handle); continue }
            do {
                let file: CameraFile
                if let directReader {
                    var membershipGroups: [(storageID: UInt32, handles: [UInt32])] = []
                    for id in catalogStorageIDs {
                        let handles = try await loadObjectHandles(storageID: queryStorageID(id))
                        membershipGroups.append((id, handles))
                    }
                    let memberships = analyzeSTADirectStorageLayout(membershipGroups)
                        .storageIDsByHandle[handle] ?? []
                    let storage = memberships.count == 1 ? memberships.first! : UInt32.max
                    let resolvedStorage = storage
                    let resolved = try await ioGate.withCommand {
                        try await directReader.file(handle: handle, storage: resolvedStorage)
                    }
                    file = replacingStorageIDs(resolved, with: memberships)
                } else { file = try await loadObjectInfo(handle: handle) }
                guard backgroundReadsAllowed, !Task.isCancelled else { return }
                if pendingObjects.removeValue(forKey: handle) != nil {
                    knownHandles.insert(handle)
                    indexedCatalogFiles[handle] = file
                    if let existingIndex = catalogOrder.firstIndex(where: {
                        guard let existing = catalogFiles[$0] else { return false }
                        return catalogLogicalIdentity(existing) == catalogLogicalIdentity(file)
                    }), let existing = catalogFiles[catalogOrder[existingIndex]] {
                        let memberships = existing.storageIDs.union(file.storageIDs)
                        catalogFiles[existing.id] = replacingStorageIDs(existing, with: memberships)
                    } else {
                        catalogFiles[handle] = file
                        // Android publishes new camera objects at the front.
                        catalogOrder.insert(handle, at: 0)
                    }
                    publishCatalog()
                }
            } catch {
                guard var pending = pendingObjects[handle] else { continue }
                pending.attempts += 1
                if pending.attempts >= 5 { pendingObjects.removeValue(forKey: handle) }
                else {
                    pending.ready = .now.advanced(by: .milliseconds([180, 360, 720, 1400][pending.attempts - 1]))
                    pendingObjects[handle] = pending
                }
            }
        }
    }

}

private extension Data {
    func readUInt64LE(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return UInt64(self[startIndex + offset]) |
            UInt64(self[startIndex + offset + 1]) << 8 |
            UInt64(self[startIndex + offset + 2]) << 16 |
            UInt64(self[startIndex + offset + 3]) << 24 |
            UInt64(self[startIndex + offset + 4]) << 32 |
            UInt64(self[startIndex + offset + 5]) << 40 |
            UInt64(self[startIndex + offset + 6]) << 48 |
            UInt64(self[startIndex + offset + 7]) << 56
    }
}
