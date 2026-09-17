import Foundation

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
) -> Bool {
    partialObjectSupported != false &&
        effectiveSize > 0 && effectiveSize != UInt64(UInt32.max) &&
        (forcePartial || !(isUSBConnection || preferHighThroughput) ||
         resumeOffset > 0 || effectiveSize > transferHighThroughputThreshold)
}

func transferDownloadChunkSize(
    effectiveSize: UInt64,
    isUSBConnection: Bool = false,
    preferHighThroughput: Bool = false,
) -> UInt64 {
    if isUSBConnection || preferHighThroughput { return transferHighThroughputChunkSize }
    return effectiveSize > transferLargeFileThreshold ? transferLargeFileChunkSize : transferChunkSize
}

func transferResumeOffset(existingSize: UInt64, totalSize: UInt64, reportedSize: UInt64) -> UInt64? {
    let known = reportedSize > 0 && reportedSize != UInt64(UInt32.max)
    if known && existingSize == totalSize { return totalSize }
    guard existingSize >= transferResumeChunkSize else { return nil }
    guard !known || existingSize < totalSize else { return nil }
    return (existingSize / transferResumeChunkSize) * transferResumeChunkSize
}

func transferUniqueOutputURL(directory: URL, fileName: String) -> URL {
    let safeName = URL(fileURLWithPath: fileName).lastPathComponent
    let base = directory.appendingPathComponent(safeName, isDirectory: false)
    guard FileManager.default.fileExists(atPath: base.path) else { return base }
    let dot = safeName.lastIndex(of: ".")
    let stem = dot.map { String(safeName[..<$0]) } ?? safeName
    let ext = dot.map { String(safeName[$0...]) } ?? ""
    for n in 1...99 {
        let candidate = directory.appendingPathComponent("\(stem) (\(n))\(ext)", isDirectory: false)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return base
}

/// Finalizes an identity-tagged temporary transfer file using the same
/// rename-first/copy-on-provider-refusal sequence as Android's SAF path.
func finalizeTransferTemporary(temporary: URL, directory: URL, fileName: String,
                               allowCopy: Bool = true, operations: TransferFileOperations = .system) throws -> URL {
    let name = URL(fileURLWithPath: fileName).lastPathComponent
    let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
    let stem = dot.map { String(name[..<$0]) } ?? name
    let ext = dot.map { String(name[$0...]) } ?? ""
    var firstAvailable: URL?
    for n in 0...99 {
        let candidate = directory.appendingPathComponent(n == 0 ? name : "\(stem) (\(n))\(ext)")
        guard !operations.exists(candidate) else { continue }
        if firstAvailable == nil { firstAvailable = candidate }
        do {
            try operations.move(temporary, candidate)
            return candidate
        } catch { /* Android tries available suffixes before copy fallback. */ }
    }
    guard allowCopy, let destination = firstAvailable else { throw CocoaError(.fileWriteUnknown) }
    let expected = try operations.size(temporary)
    do {
        try operations.copy(temporary, destination)
        let copied = try operations.size(destination)
        guard copied == expected else { throw CameraDownloadError.copyIncomplete(received: copied, expected: expected) }
    } catch {
        try? operations.remove(destination)
        throw error
    }
    try? operations.remove(temporary)
    return destination
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
}

/// Resumable handle enumeration state. Android keeps this snapshot when a
/// foreground preview interrupts metadata reads; only handles already
/// accepted by the list are marked processed.
struct PhotoScanSnapshot: Sendable {
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
    private let isUSBConnection: Bool
    nonisolated let usbSessionIdentity: USBSessionIdentity?
    private let usbTransport: ImageCaptureUSBTransport?
    private let usbDeviceID: String?
    private var remoteControlModeSet = false
    private var movieApplicationPropertySet = false
    private var movieApplicationOperationSet = false
    /// Android learns this capability once and remembers an unsupported
    /// partial-object operation for the rest of the session.
    private var partialObjectSupported: Bool?
    private var subjectTrackingActive = false
    private var subjectTrackingSupported: Bool?
    private let focusGate = CameraIOGate()
    private var cachedDeviceInfo: PTPDeviceInfo?
    private var liveViewImageOperation: UInt16?
    private var liveViewEnhancedFailures = 0
    private let staAlbum: STAAlbumAccess?
    private let directReader: STAObjectReader?
    private var prefetchedStorageIDs: [UInt32]?
    private var prefetchedHandles: (storageID: UInt32, handles: [UInt32])?
    private var activeForegroundReads = 0
    private var remoteActive = false
    private var fhdActive = false
    private var transfersBusy = false
    private var preferHighThroughputTransfers = false
    private var effectPreviewActive = false
    private var activeCatalogScans = 0
    private var catalogLoading: Bool { activeCatalogScans > 0 }
    private var catalogFiles: [UInt32: CameraFile] = [:]
    private var indexedCatalogFiles: [UInt32: CameraFile] = [:]
    private var catalogOrder: [UInt32] = []
    private var catalogStorageIDs: [UInt32] = []
    private var knownHandles = Set<UInt32>()
    private var catalogReady = false
    private var lastCatalogCheck = ContinuousClock.now
    private var catalogSyncRequested = false
    private var scanSnapshot: PhotoScanSnapshot?
    private var pendingObjects: [UInt32: (attempts: Int, ready: ContinuousClock.Instant)] = [:]
    private var eventResolveTask: Task<Void, Never>?
    private var catalogContinuations: [UUID: AsyncStream<[CameraFile]>.Continuation] = [:]

    init(session: PTPSession, staAlbum: STAAlbumAccess? = nil, isUSBConnection: Bool = false,
         deviceInfo: PTPDeviceInfo? = nil, usbTransport: ImageCaptureUSBTransport? = nil,
         usbDeviceID: String? = nil, usbSessionIdentity: USBSessionIdentity? = nil) {
        self.session = session
        #if DEBUG
        self.debugData = nil
        #endif
        self.staAlbum = staAlbum; self.isUSBConnection = isUSBConnection
        self.usbTransport = usbTransport; self.usbDeviceID = usbDeviceID
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
        self.usbTransport = nil; self.usbDeviceID = nil; self.usbSessionIdentity = nil
        self.prefetchedStorageIDs = [0x00010001, 0x00020001]
        self.prefetchedHandles = nil; self.directReader = nil
    }
    #endif

    deinit { eventResolveTask?.cancel() }

    func keepalive() async -> Bool {
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
        try await focusGate.withCommand { [self] in
            try await tapFocusLocked(trackingX: trackingX, trackingY: trackingY, focusX: focusX, focusY: focusY)
        }
    }

    private func tapFocusLocked(trackingX: UInt32, trackingY: UInt32,
                                focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult {
        let deadline = ContinuousClock.now + .seconds(6)
        let initial = try await session.withCommandSequence { [self] commands in
            try await beginTapFocus(commands, deadline: deadline, trackingX: trackingX, trackingY: trackingY,
                                    focusX: focusX, focusY: focusY)
        }
        guard initial.responseCode == PTPConstants.responseOK, !initial.timedOut else { return initial }
        var result = try await waitForAutofocus(deadline: deadline, tracking: initial.trackingStarted)
        result.trackingResponseCode = initial.trackingResponseCode
        return result
    }

    private func beginTapFocus(_ commands: PTPCommandSequence, deadline: ContinuousClock.Instant,
                                trackingX: UInt32, trackingY: UInt32,
                                focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult {
        let end = try await endTrackingLocked(commands, deadline: deadline)
        if subjectTrackingActive {
            return .init(trackingStarted: false, polls: 0, timedOut: false,
                         responseCode: end ?? PTPConstants.deviceBusy)
        }
        var trackingCode: UInt16?
        if subjectTrackingSupported != false {
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
        if !subjectTrackingActive {
            let moved = try await focusCommand(commands, operation: PTPConstants.changeAFArea,
                parameters: [focusX, focusY], deadline: deadline)?.code
            if moved != PTPConstants.responseOK {
                return .init(trackingStarted: false, polls: 0, timedOut: moved == nil,
                             responseCode: moved ?? PTPConstants.deviceBusy, trackingResponseCode: trackingCode)
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        let af = try await focusCommand(commands, operation: PTPConstants.afDrive, deadline: deadline)?.code
        return .init(trackingStarted: subjectTrackingActive, polls: 0, timedOut: af == nil,
                     responseCode: af ?? PTPConstants.deviceBusy, trackingResponseCode: trackingCode)
    }

    func halfPressFocus() async throws -> RemoteFocusResult {
        try await focusGate.withCommand { [self] in try await halfPressFocusLocked() }
    }

    private func halfPressFocusLocked() async throws -> RemoteFocusResult {
        let deadline = ContinuousClock.now + .seconds(6)
        let end = try await session.withCommandSequence { [self] commands in
            try await endTrackingLocked(commands, deadline: deadline)
        }
        if subjectTrackingActive {
            return .init(trackingStarted: false, polls: 0, timedOut: false,
                         responseCode: end ?? PTPConstants.deviceBusy)
        }
        let af = try await session.withCommandSequence { [self] commands in
            try await focusCommand(commands, operation: PTPConstants.afDrive, deadline: deadline)?.code
        }
        guard af == PTPConstants.responseOK else {
            return .init(trackingStarted: false, polls: 0, timedOut: af == nil,
                         responseCode: af ?? PTPConstants.deviceBusy)
        }
        return try await waitForAutofocus(deadline: deadline, tracking: false)
    }

    func endSubjectTracking() async throws {
        try await focusGate.withCommand { [self] in
            let deadline = ContinuousClock.now + .seconds(6)
            _ = try await session.withCommandSequence { [self] commands in
                try await endTrackingLocked(commands, deadline: deadline)
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
            let ready = try await session.withCommandSequence { [self] commands in
                try await focusCommand(commands, operation: PTPConstants.deviceReady, deadline: deadline)?.code
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
        let response = try await session.execute(operation: PTPConstants.getDevicePropDesc,
                                                 parameters: [property.rawValue])
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
        _ = try await session.execute(operation: PTPConstants.setDevicePropValue,
                                      parameters: [descriptor.property.rawValue], data: encoded)
    }

    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) async throws -> RemotePropertyDescriptor? {
        let response = try await session.execute(operation: PTPConstants.getDevicePropValue,
                                                 parameters: [descriptor.property.rawValue])
        guard let value = RemotePropertyCodec.parseValue(response.data, dataType: descriptor.dataType) else { return nil }
        var updated = descriptor
        updated.current = UInt64(bitPattern: value)
        return updated
    }

    func remoteFocusMode() async throws -> RemotePropertyDescriptor? {
        for property in [RemoteProperty.focusMode, .nikonAFMode] {
            let response = try await session.executeResponse(operation: PTPConstants.getDevicePropValue,
                                                             parameters: [property.rawValue])
            guard response.code == PTPConstants.responseOK, [1, 2, 4, 8].contains(response.data.count) else { continue }
            let value = response.data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
            let known = property == .focusMode ? [1, 2, 3, 0x8010, 0x8011, 0x8012, 0x8013].contains(value)
                : [0, 1, 2].contains(value)
            if known { return .init(property: property, writable: false, current: value, values: []) }
        }
        return nil
    }

    func remoteMovieMode() async throws -> Bool? {
        let response = try await session.executeResponse(operation: PTPConstants.getDevicePropValue,
                                                         parameters: [RemoteProperty.liveViewSelector.rawValue])
        guard response.code == PTPConstants.responseOK, let value = response.data.first else { return nil }
        return value != 0
    }

    func remoteEvents() async throws -> [STAEvent] {
        if staAlbum != nil {
            let response = try await session.executeResponse(operation: PTPConstants.nikonCompatibilityInit)
            if response.code == PTPConstants.responseOK { return STAEvent.polled(response.data, extended: true) ?? [] }
            if response.code != PTPConstants.operationNotSupported { return [] }
        }
        let response = try await session.executeResponse(operation: 0x90C7)
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
                _ = try await session.execute(operation: PTPConstants.startLiveView)
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
                _ = try await session.execute(operation: PTPConstants.deviceReady,
                                              timeoutNanoseconds: 1_000_000_000)
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
            try await session.withCommandSequence { [self] commands in
                _ = try await endTrackingLocked(commands, deadline: deadline)
                await clearSubjectTrackingState()
                _ = try await focusCommand(commands, operation: PTPConstants.endLiveView, deadline: deadline)
            }
        } catch { subjectTrackingActive = false }
    }

    private func clearSubjectTrackingState() { subjectTrackingActive = false }

    /// RemoteLab.labGrabFrame: advertised operation, sticky downgrade, and SOI
    /// validation. Busy/not-in-LV do not count as enhanced capability failures.
    func liveViewFrame() async throws -> RemoteLiveViewPacket {
        try await session.withCommandSequence { [self] commands in
            try await receiveLiveViewFrame(commands)
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
        let response = try await RemoteMovieCommandRetry.execute {
            try await session.executeResponse(operation: PTPConstants.captureInMedia,
                                               parameters: [.max, 0]).code
        }
        guard response == PTPConstants.responseOK else { throw PTPSessionError.responseCode(response) }
    }

    /// Nikon USB movie control requires a genuinely fresh ImageCapture/PTP
    /// session. DeviceInfo stays cached; the new session only drains stale
    /// Nikon events before entering control mode, matching Android.
    func refreshUSBRemoteSession() async throws -> String {
        guard isUSBConnection, let transport = usbTransport, let deviceID = usbDeviceID,
              let identity = usbSessionIdentity else { throw CameraRepositoryError.invalidDataset }
        let oldSession = session
        let oldToken = identity.snapshot().token
        identity.beginRotation()
        do {
            let (newSession, newToken, drainCode) = try await oldSession.withCommandSequence { _ in
                await transport.closeSession(for: deviceID, expectedSessionToken: oldToken)
                try await Task.sleep(for: .milliseconds(100))
                var finalError: Error = CameraTransportError.disconnected
                for attempt in 0..<2 {
                    do {
                        try await AsyncDeadline.run(nanoseconds: 5_000_000_000,
                                                    timeoutError: CameraTransportError.timeout) {
                            try await transport.openSession(for: deviceID)
                        }
                        guard let token = transport.openedSessionToken(for: deviceID) else {
                            throw CameraTransportError.disconnected
                        }
                        let next = PTPSession(transport: SelectedUSBPTPTransport(transport: transport,
                                                                                 deviceID: deviceID,
                                                                                 sessionToken: token),
                                              defaultTimeoutNanoseconds: 60_000_000_000)
                        let drain = try await next.executeResponse(operation: PTPConstants.nikonCompatibilityInit)
                        return (next, token, drain.code)
                    } catch {
                        finalError = error
                        if attempt == 0 { try await Task.sleep(for: .milliseconds(100)) }
                    }
                }
                throw finalError
            }
            session = newSession
            identity.finishRotation(token: newToken)
            subjectTrackingActive = false
            remoteControlModeSet = false
            movieApplicationPropertySet = false
            movieApplicationOperationSet = false
            liveViewEnhancedFailures = 0
            liveViewImageOperation = cachedDeviceInfo?.operations.contains(PTPConstants.getLiveViewImageEx) == true
                ? PTPConstants.getLiveViewImageEx : PTPConstants.getLiveViewImage
            return String(format: "session=0x%04X drain=0x%04X info=cached settle=100ms",
                          PTPConstants.responseOK, drainCode)
        } catch {
            identity.cancelRotation()
            throw error
        }
    }

    func setRemoteControlMode(_ enabled: Bool) async throws -> UInt16 {
        if enabled == remoteControlModeSet { return PTPConstants.responseOK }
        let response = try await movieCommandWithBusyRetry(PTPConstants.setControlMode,
                                                            parameters: [enabled ? 1 : 0])
        if response == PTPConstants.responseOK { remoteControlModeSet = enabled }
        return response
    }

    func hasRemoteControlMode() -> Bool { remoteControlModeSet }
    func hasMovieApplicationMode() -> Bool {
        movieApplicationPropertySet || movieApplicationOperationSet
    }

    func ensureMovieApplicationMode() async throws {
        if !movieApplicationPropertySet {
            let response = try await session.executeResponse(operation: PTPConstants.setDevicePropValue,
                                                             parameters: [RemoteProperty.applicationMode.rawValue],
                                                             data: Data([1])).code
            if response == PTPConstants.responseOK { movieApplicationPropertySet = true }
        }
        if !movieApplicationOperationSet {
            let response = try await session.executeResponse(operation: PTPConstants.nikonChangeApplicationMode,
                                                             parameters: [1]).code
            if response == PTPConstants.responseOK { movieApplicationOperationSet = true }
        }
    }

    func clearMovieApplicationMode(force: Bool = false) async {
        if isUSBConnection && remoteControlModeSet && !force { return }
        if movieApplicationOperationSet {
            let response = try? await session.executeResponse(operation: PTPConstants.nikonChangeApplicationMode,
                                                              parameters: [0]).code
            if response == PTPConstants.responseOK { movieApplicationOperationSet = false }
        }
        if movieApplicationPropertySet {
            let response = try? await session.executeResponse(operation: PTPConstants.setDevicePropValue,
                                                              parameters: [RemoteProperty.applicationMode.rawValue],
                                                              data: Data([0])).code
            if response == PTPConstants.responseOK { movieApplicationPropertySet = false }
        }
    }

    /// USB preflight/application/start is one uninterrupted command sequence.
    func startPreparedUSBMovieRecording() async throws -> RemoteMovieStartResult {
        let operationWasSet = movieApplicationOperationSet
        let propertyWasSet = movieApplicationPropertySet
        let completed = try await session.withCommandSequence { commands in
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
                if response == PTPConstants.responseOK { operationSet = true }
                if response == PTPConstants.operationNotSupported {
                    let property = try await commands.executeResponse(operation: PTPConstants.setDevicePropValue,
                                                                     parameters: [RemoteProperty.applicationMode.rawValue],
                                                                     data: Data([1])).code
                    appProperty = property
                    if property == PTPConstants.responseOK {
                        propertySet = true
                        _ = try await readProhibit()
                    }
                }
            }
            let ready = !needsApplication || operationSet || propertySet
            let start = ready
                ? try await commands.executeResponse(operation: PTPConstants.startMovieRecording).code
                : (appProperty ?? appOperation ?? 0x200F)
            let finalProhibit = start == PTPConstants.responseOK ? nil : (try await readProhibit() ?? preflight)
            return (RemoteMovieStartResult(responseCode: start, prohibitCondition: finalProhibit,
                                           prohibitExtendedResponse: extended,
                                           applicationModeResponse: appOperation,
                                           applicationModePropertyResponse: appProperty,
                                           startCommandResponse: ready ? start : nil),
                    operationSet, propertySet)
        }
        movieApplicationOperationSet = completed.1
        movieApplicationPropertySet = completed.2
        return completed.0
    }

    func startMovieRecording() async throws -> RemoteMovieStartResult {
        let response = try await movieCommandWithBusyRetry(PTPConstants.startMovieRecording)
        var prohibitCondition: UInt32?
        if response != PTPConstants.responseOK {
            do {
                // RemoteLab.PROP_NK_MOV_PROHIBIT: read only after a failed start,
                // including bit 10 when the camera is already recording.
                let data = try await session.execute(operation: PTPConstants.getDevicePropValue,
                                                     parameters: [0xD0A4]).data
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
            do { return try await session.execute(operation: operation, parameters: parameters).code }
            catch PTPSessionError.responseCode(let response) { return response }
        }
    }

    func loadDeviceInfo() async throws -> PTPDeviceInfo {
        if let info = cachedDeviceInfo { return info }
        let result = try await session.execute(operation: PTPConstants.getDeviceInfo)
        guard let info = PTPDatasetParser.parseDeviceInfo(result.data) else { throw CameraRepositoryError.invalidDataset }
        cachedDeviceInfo = info
        return info
    }

    /// Stable per-body cache identity. A network session without an announced
    /// serial deliberately returns nil rather than mixing thumbnails between
    /// cameras, matching Android's camera-scoped cache invariant.
    func thumbnailCacheIdentity() -> String? {
        guard let info = staAlbum?.deviceInfo,
              !info.serialNumber.isEmpty else { return nil }
        return "\(info.manufacturer)\u{0}\(info.model)\u{0}\(info.serialNumber)"
    }

    func usesDirectThumbnailRead() -> Bool { directReader != nil }
    /// The Android list keeps this handle snapshot when FHD/monitoring cancels
    /// a scan before the first metadata batch is visible.  The owner must be
    /// able to pass that exact snapshot back instead of inferring resumability
    /// from the number of published rows.
    func scanSnapshotForResume() -> PhotoScanSnapshot? { scanSnapshot }
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
    /// Effects preview blocks only background thumbnail filling; metadata
    /// enumeration itself continues, matching Android's separate gate.
    func setEffectPreviewActive(_ active: Bool) { effectPreviewActive = active }

    /// Foreground FHD preview has priority over catalog metadata reads.  The
    /// scan keeps its handle snapshot and resumes at the same cursor when the
    /// preview releases the channel.
    func setFHDActive(_ active: Bool) { fhdActive = active }
    /// Remote page owns the foreground channel from the moment it appears,
    /// before parameter loading or Live View startup begins.
    func setRemoteActive(_ active: Bool) {
        remoteActive = active
        if !active { scheduleObjectResolver() }
    }

    private func waitForForegroundPreview() async throws {
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
        guard let file = PTPDatasetParser.parseObjectInfo(handle: handle, result.data) else { throw CameraRepositoryError.invalidDataset }
        return file
    }

    /// Reads one Android-sized metadata batch while holding the ordinary
    /// catalog mutex. The caller performs dual-card ordering and publication
    /// after this method returns, so callbacks never run under the camera lock.
    private func readCatalogMetadataBatch(
        _ requests: [(groupIndex: Int, handle: UInt32, storage: UInt32)]
    ) async throws -> [CatalogMetadataResult] {
        let session = self.session
        let directReader = self.directReader
        return try await ioGate.withCommand {
            var results: [CatalogMetadataResult] = []
            results.reserveCapacity(requests.count)
            for request in requests {
                // Finish a command already on the wire, but never start the
                // next ObjectInfo/header read after the remote page takes over.
                try await self.checkRemoteScanOwnership()
                do {
                    let file: CameraFile
                    if let directReader {
                        file = try await directReader.file(handle: request.handle, storage: request.storage)
                    } else {
                        let response = try await session.execute(
                            operation: PTPConstants.getObjectInfo,
                            parameters: [request.handle]
                        )
                        guard let parsed = PTPDatasetParser.parseObjectInfo(handle: request.handle, response.data) else {
                            results.append(CatalogMetadataResult(groupIndex: request.groupIndex,
                                                                 handle: request.handle,
                                                                 file: nil,
                                                                 successful: false))
                            continue
                        }
                        file = parsed
                    }
                    results.append(CatalogMetadataResult(groupIndex: request.groupIndex,
                                                         handle: request.handle,
                                                         file: file,
                                                         successful: true))
                } catch let error as PTPSessionError where error == .invalidated || error == .timeout {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    results.append(CatalogMetadataResult(groupIndex: request.groupIndex,
                                                         handle: request.handle,
                                                         file: nil,
                                                         successful: false))
                }
            }
            return results
        }
    }

    private func checkRemoteScanOwnership() throws {
        if remoteActive { throw CameraRepositoryError.foregroundPreempted }
    }

    func thumbnail(handle: UInt32) async throws -> Data {
        #if DEBUG
        if let debugData { return debugData.thumbnailData }
        #endif
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        return try await ioGate.withCommand {
            if let directReader { return try await directReader.thumbnail(handle: handle) }
            return try await session.execute(operation: PTPConstants.getThumb, parameters: [handle]).data
        }
    }

    /// Android's preview order: FHD picture first, then Nikon large thumb, then
    /// the standard thumbnail when the camera reports the operation unsupported.
    func preview(handle: UInt32) async throws -> Data {
        #if DEBUG
        if let debugData { return debugData.previewData }
        #endif
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        return try await ioGate.withInteractive {
            if let directReader { return try await directReader.preview(handle: handle) }
            var lastError: Error?
            for operation in [PTPConstants.getFHDPicture, PTPConstants.getLargeThumb, PTPConstants.getThumb] {
                do {
                    let data = try await session.execute(operation: operation, parameters: [handle]).data
                    if !data.isEmpty { return data }
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? CameraRepositoryError.invalidDataset
        }
    }

    func readPrefix(handle: UInt32, length: Int64) async throws -> Data {
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        return try await ioGate.withInteractive {
            let count = max(0, min(length, Int64(UInt32.max)))
            if let directReader {
                return try await directReader.exifHeader(handle: handle, length: Int(count))
            }
            let result = try await session.execute(
                operation: PTPConstants.getPartialObjectEx,
                parameters: [handle, 0, 0, UInt32(count & 0xFFFF_FFFF), UInt32(count >> 32)]
            )
            return result.data
        }
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
        try await ioGate.withDownloadActivity {
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
            let url = transferUniqueOutputURL(directory: directory, fileName: fileName)
            let bytes = UInt64(debugData.thumbnailData.count)
            for step in 1...20 {
                try await Task.sleep(for: .milliseconds(200))
                progress?(TransferDownloadProgress(fraction: Double(step) / 20.0,
                                                   downloaded: bytes * UInt64(step) / 20,
                                                   total: bytes,
                                                   bytesPerSecond: max(1, Int64(bytes / 4))))
            }
            try debugData.thumbnailData.write(to: url, options: .atomic)
            progress?(TransferDownloadProgress(fraction: 1,
                                               downloaded: UInt64(debugData.thumbnailData.count),
                                               total: UInt64(debugData.thumbnailData.count)))
            return CameraDownloadResult(url: url, bytes: UInt64(debugData.thumbnailData.count),
                                        transferredBytes: UInt64(debugData.thumbnailData.count),
                                        startedAt: startedAt, headerPrefix: debugData.thumbnailData)
        }
        #endif
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        let startedAt = ContinuousClock.now
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        let temporary = directory.appendingPathComponent(
            transferPartialFileName(size: size, captureDate: captureDate, fileName: safeName), isDirectory: false
        )
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
        let sizeKnown = effectiveSize > 0 && effectiveSize != UInt64(UInt32.max)
        let existingSize = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { UInt64(max(0, $0)) } ?? 0
        let resumeOffset = transferResumeOffset(existingSize: existingSize, totalSize: effectiveSize, reportedSize: size) ?? 0
        if resumeOffset == 0 { try? FileManager.default.removeItem(at: temporary) }
        if resumeOffset > 0 && resumeOffset < existingSize {
            let trim = try FileHandle(forWritingTo: temporary)
            try trim.truncate(atOffset: resumeOffset)
            try trim.close()
        }
        if size > 0, size != UInt64(UInt32.max), resumeOffset == effectiveSize {
            let destination = try finalizeDownloadedFile(temporary: temporary, directory: directory, fileName: safeName)
            return CameraDownloadResult(url: destination, bytes: effectiveSize, transferredBytes: 0,
                                        startedAt: startedAt, headerPrefix: nil)
        }
        // Snapshot after size resolution, immediately before the first file
        // data command. Page changes must not switch strategy midway through.
        let highThroughput = preferHighThroughputTransfers
        let usePartial = shouldUsePartialObjectDownload(
            partialObjectSupported: partialObjectSupported, effectiveSize: effectiveSize,
            resumeOffset: resumeOffset, isUSBConnection: isUSBConnection,
            preferHighThroughput: highThroughput, forcePartial: directReader != nil
        )
        if resumeOffset > 0 && !usePartial { throw CameraRepositoryError.resumeUnavailable }
        if !FileManager.default.fileExists(atPath: temporary.path) {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let output = try FileHandle(forWritingTo: temporary)
        try output.seek(toOffset: resumeOffset)
        let writer = CameraDownloadWriter(output: output, resumeOffset: resumeOffset,
                                           totalHint: sizeKnown ? effectiveSize : 0, captureHeader: captureHeader,
                                           startedAt: startedAt, onProgress: progress)
        defer { try? writer.close() }
        let chunkSize = transferDownloadChunkSize(effectiveSize: effectiveSize,
                                                  isUSBConnection: isUSBConnection, preferHighThroughput: highThroughput)
        var firstPartial = true
        var useFull = !usePartial
        while usePartial && writer.bytes < effectiveSize {
            try Task.checkCancellation()
            let offset = writer.bytes
            let request = min(chunkSize, effectiveSize - offset)
            let response = try await ioGate.withTransferSlice {
                try await session.executeReceiving(
                    operation: PTPConstants.getPartialObjectEx,
                    parameters: [handle, UInt32(truncatingIfNeeded: offset), UInt32(truncatingIfNeeded: offset >> 32),
                                  UInt32(truncatingIfNeeded: request), UInt32(truncatingIfNeeded: request >> 32)],
                    sink: writer.sink, timeoutNanoseconds: PTPConstants.cameraReadTimeoutNanoseconds
                )
            }
            guard response.code == PTPConstants.responseOK else {
                // A non-empty failed phase has already written bytes. Only an
                // unsupported first phase with zero received bytes may fall back.
                if firstPartial && response.receivedByteCount == 0 && resumeOffset == 0 &&
                    response.code == PTPConstants.operationNotSupported {
                    partialObjectSupported = false
                    useFull = true
                    break
                }
                throw CameraDownloadError.response(response.code)
            }
            partialObjectSupported = true
            if let expected = response.declaredByteCount, expected > 0, expected != response.receivedByteCount {
                throw CameraDownloadError.incomplete(received: response.receivedByteCount, expected: expected)
            }
            guard response.receivedByteCount > 0 else {
                throw CameraDownloadError.incomplete(received: writer.bytes, expected: effectiveSize)
            }
            // Like Android, advance by actual bytes. A shorter complete data
            // phase is valid; the following command reads the missing interval.
            firstPartial = false
        }
        if useFull {
            let response = try await ioGate.withTransferSlice {
                try await session.executeReceiving(operation: PTPConstants.getObject,
                                                   parameters: [handle], sink: writer.sink,
                                                   timeoutNanoseconds: PTPConstants.cameraReadTimeoutNanoseconds)
            }
            guard response.code == PTPConstants.responseOK else { throw CameraDownloadError.response(response.code) }
            if let expected = response.declaredByteCount, expected > 0, expected != UInt64(UInt32.max), writer.bytes != expected {
                throw CameraDownloadError.incomplete(received: writer.bytes, expected: expected)
            }
        } else if writer.bytes != effectiveSize {
            throw CameraDownloadError.incomplete(received: writer.bytes, expected: effectiveSize)
        }
        try writer.close()
        let destination = try finalizeDownloadedFile(temporary: temporary, directory: directory, fileName: safeName)
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
        onBatch: (@Sendable ([CameraFile]) async throws -> Void)? = nil
    ) async throws -> PhotoScanResult {
        activeCatalogScans += 1
        defer { activeCatalogScans -= 1; scheduleObjectResolver() }

        #if DEBUG
        if let debugData {
            let files = debugData.files
            if let onBatch, !preserveExisting {
                for start in stride(from: 0, to: files.count, by: 12) {
                    try Task.checkCancellation()
                    try await onBatch(Array(files[start..<min(start + 12, files.count)]))
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

        // A resume snapshot is valid only for this repository/session.  A fresh
        // scan invalidates old rows and cache state exactly like Android.
        let reusable = resumeSnapshot
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
                // Android's non-STA getStorageIds() maps a command/transport
                // failure to an empty result; the no-usable-storage branch
                // completes the scan without authorizing cache reconciliation.
                if staAlbum != nil { throw CameraRepositoryError.transportLost }
                raw = []
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
                // An empty/failed storage response is not authoritative. The
                // Android path removes only handles from an established
                // baseline; a first scan keeps any rows already published by
                // an earlier partial result.
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
            scanSnapshot = PhotoScanSnapshot(
                storageIDs: storageIDs,
                handleOrders: groups.map { ($0.storage, $0.handles) },
                processedHandles: Set(existingHandles),
                handleQueriesSucceeded: handleQueriesSucceeded,
                filterStorageIDs: filterStorageIDs,
                directStorageIDsByHandle: directStorageIDsByHandle
            )
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
        // STA direct metadata intentionally publishes the first frame as a
        // 1-item batch, then a 3-item warm-up batch, before settling at 12.
        // This is the same first-content latency strategy as
        // `streamStaDirectFileInfo`; ordinary ObjectInfo scans stay at 12.
        var directPublishedCount = 0
        var metadataComplete = true
        var cursors = Array(repeating: 0, count: groups.count)
        var heads = Array<CameraFile?>(repeating: nil, count: groups.count)
        var metadataBuffers = Array(repeating: [CatalogMetadataResult](), count: groups.count)
        let totalCatalogHandles = groups.reduce(0) { $0 + $1.handles.count }
        var completedHandles = 0
        // A handle becomes resumable only after the batch containing it was
        // accepted by the list owner.  Android marks the snapshot in the same
        // accepted section; marking it when ObjectInfo returns would skip rows
        // if the UI callback is cancelled or the session generation changes.
        var pendingProcessedHandles: [UInt32] = []
        while completedHandles < totalCatalogHandles {
            try Task.checkCancellation()
            try await waitForForegroundPreview()
            let batchLimit: Int = directReader == nil ? 12 :
                (directPublishedCount == 0 ? 1 : directPublishedCount < 4 ? 3 : 12)
            let requestBudget = directReader == nil
                ? batchLimit
                : max(groups.count, batchLimit + groups.count - 1)

            // Drain already fetched heads first. A single ordinary-lock batch
            // may contain more responses than the current publication; those
            // responses stay buffered for the next batch instead of reacquiring
            // the camera mutex one object at a time.
            func fillHead(_ index: Int) {
                guard heads[index] == nil else { return }
                while !metadataBuffers[index].isEmpty {
                    let result = metadataBuffers[index].removeFirst()
                    if !result.successful { metadataComplete = false }
                    if let file = result.file {
                        heads[index] = file
                        return
                    }
                    completedHandles += 1
                    pendingProcessedHandles.append(result.handle)
                }
            }
            for index in groups.indices { fillHead(index) }

            var requests: [(groupIndex: Int, handle: UInt32, storage: UInt32)] = []
            if heads.allSatisfy({ $0 != nil }) == false {
                // Request in storage order, matching Android's round-robin
                // head fill. The budget is the same as the Android call site:
                // ordinary ObjectInfo uses at most the publication batch;
                // direct STA reserves one head per card plus the batch.
                while requests.count < requestBudget {
                    var added = false
                    for index in groups.indices where requests.count < requestBudget {
                        guard cursors[index] < groups[index].handles.count else { continue }
                        let handle = groups[index].handles[cursors[index]]
                        cursors[index] += 1
                        requests.append((index, handle, groups[index].storage))
                        added = true
                    }
                    if !added { break }
                }
            }
            if !requests.isEmpty {
                let results: [CatalogMetadataResult]
                do {
                    results = try await readCatalogMetadataBatch(requests)
                } catch CameraRepositoryError.foregroundPreempted {
                    throw CameraRepositoryError.foregroundPreempted
                } catch {
                    if staAlbum != nil { throw CameraRepositoryError.transportLost }
                    throw error
                }
                for result in results { metadataBuffers[result.groupIndex].append(result) }
                for index in groups.indices { fillHead(index) }
            }

            var output: [CameraFile] = []
            while output.count < batchLimit {
                guard let selectedIndex = selectNewestPhotoHeadIndex(heads),
                      let file = heads[selectedIndex] else { break }
                heads[selectedIndex] = nil
                completedHandles += 1
                pendingProcessedHandles.append(file.id)
                output.append(file)
                fillHead(selectedIndex)
            }
            if output.isEmpty {
                if requests.isEmpty { break }
                continue
            }
            for rawFile in output {
                let file = replacingStorageIDs(rawFile, with: directStorageIDsByHandle[rawFile.id] ?? [])
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
            scanSnapshot?.processedHandles.formUnion(pendingProcessedHandles)
            directPublishedCount += pendingProcessedHandles.count
            batch.removeAll(keepingCapacity: true)
            pendingProcessedHandles.removeAll(keepingCapacity: true)
        }
        if !batch.isEmpty { try await onBatch?(batch) }
        // The final partial batch is accepted only after its callback returns;
        // duplicate logical rows may have no UI addition but still count as
        // consumed handles in the resumable Android snapshot.
        scanSnapshot?.processedHandles.formUnion(pendingProcessedHandles)
        try Task.checkCancellation()
        catalogFiles = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        indexedCatalogFiles = indexed
        catalogOrder = files.map(\.id)
        // Only a complete handle snapshot is authoritative. Android keeps the
        // previous baseline after a partial/non-STA response so the next scan
        // can still compute real additions/removals instead of diffing against
        // an incomplete list.
        if handleQueriesSucceeded {
            knownHandles = Set(groups.flatMap(\.handles)).union(Set(existingHandles))
            catalogStorageIDs = storageIDs
        }
        catalogReady = metadataComplete && handleQueriesSucceeded
        lastCatalogCheck = .now
        if catalogReady { scanSnapshot = nil }
        publishCatalog()
        return PhotoScanResult(files: files, removedHandles: removedHandles,
                               addedHandles: addedHandles,
                               handleQueriesSucceeded: handleQueriesSucceeded,
                               metadataComplete: metadataComplete,
                               filterStorageIDs: filterStorageIDs)
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
            if staAlbum != nil && response.code == PTPConstants.deviceBusy && attempts < 3 {
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
    private func receiveEvent(_ event: STAEvent) {
        switch event.code {
        case 0x4002:
            guard event.handle != 0, event.handle != .max,
                  !knownHandles.contains(event.handle), catalogFiles[event.handle] == nil else { return }
            if pendingObjects[event.handle] == nil { pendingObjects[event.handle] = (0, .now.advanced(by: .milliseconds(90))) }
            scheduleObjectResolver()
        case 0x4003:
            pendingObjects.removeValue(forKey: event.handle)
            if event.handle != 0 && event.handle != .max && catalogReady && !knownHandles.contains(event.handle) { return }
            catalogSyncRequested = true
        default: break
        }
    }
    private var backgroundReadsAllowed: Bool {
        catalogReady && !catalogLoading && activeForegroundReads == 0 &&
            !remoteActive && !fhdActive && !transfersBusy
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
            var result = try await ioGate.withCommand {
                try await session.executeResponse(operation: PTPConstants.nikonCompatibilityInit, timeoutNanoseconds: 60_000_000_000)
            }
            var extended = true
            if result.code == PTPConstants.operationNotSupported {
                extended = false
                result = try await ioGate.withCommand {
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
