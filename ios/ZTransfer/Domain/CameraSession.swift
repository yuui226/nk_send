import Foundation
import UIKit

/// Android keeps decoded thumbnails in a byte-costed LRU. NSCache is the
/// native thread-safe equivalent and lets SwiftUI recover a reused cell's
/// image synchronously instead of decoding the same JPEG on every appearance.
private final class PhotoDecodedThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.totalCostLimit = max(4 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 8))
    }

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func insert(_ image: UIImage, for key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func remove(_ key: String) { cache.removeObject(forKey: key as NSString) }
    func clear() { cache.removeAllObjects() }
}

/// Stable ImageCaptureCore session identity shared across actor boundaries.
/// USB remote control keeps this accepted session instead of cycling it.
final class USBSessionIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID

    init(token: UUID) { self.token = token }
    func snapshot() -> UUID {
        lock.lock(); defer { lock.unlock() }
        return token
    }
}

/// A connected camera's single owner. USB uses ImageCaptureCore for media;
/// PTP/IP sessions use the same repository commands, while both expose one
/// cancellation-safe API to lists, previews and the transfer queue.
actor CameraSession {
    let repository: CameraRepository
    private let usbTransport: ImageCaptureUSBTransport?
    /// Stable identity exposed to connection recovery without crossing actor
    /// isolation. It is immutable for the lifetime of a camera session.
    nonisolated let transportDeviceID: String?
    private nonisolated let usbIdentity: USBSessionIdentity?
    nonisolated var usbSessionToken: UUID? { usbIdentity?.snapshot() }
    /// The connection pill uses the transport kind just like Android's
    /// SignalPill (USB icon for wired sessions, Wi‑Fi icon otherwise).
    nonisolated let isUSB: Bool
    /// iOS suspends ImageCaptureCore device communication after backgrounding;
    /// a UIKit background assertion cannot turn USB into Android's foreground
    /// service. The transfer queue therefore only extends wireless work.
    nonisolated var allowsBackgroundTransferContinuation: Bool { !isUSB }
    /// Keep the selected wireless route with the session so the photo-list
    /// signal pill can render Android's STA-specific state instead of
    /// collapsing every PTP/IP connection into a generic Wi‑Fi glyph.
    nonisolated let wirelessMode: WirelessMode?
    nonisolated let recoveredFromSessionID: ObjectIdentifier?
    private let thumbnailStore: PhotoThumbnailStore
    private nonisolated let decodedThumbnailCache = PhotoDecodedThumbnailCache()
    private let exifStore = PhotoExifStore()

    init(repository: CameraRepository, transport: ImageCaptureUSBTransport, deviceID: String, sessionToken: UUID,
         thumbnailStore: PhotoThumbnailStore = PhotoThumbnailStore()) {
        self.thumbnailStore = thumbnailStore
        self.repository = repository; self.usbTransport = transport; self.transportDeviceID = deviceID
        self.usbIdentity = repository.usbSessionIdentity ?? USBSessionIdentity(token: sessionToken)
        self.isUSB = true; self.wirelessMode = nil
        self.recoveredFromSessionID = nil
    }

    /// Creates a network-backed session. The repository's PTPSession is the
    /// serialized command channel for thumbnails, reads and downloads.
    init(repository: CameraRepository, wirelessMode: WirelessMode = .ap,
         recoveredFromSessionID: ObjectIdentifier? = nil,
         thumbnailStore: PhotoThumbnailStore = PhotoThumbnailStore()) {
        self.thumbnailStore = thumbnailStore
        self.recoveredFromSessionID = recoveredFromSessionID
        self.repository = repository; self.usbTransport = nil; self.transportDeviceID = nil; self.usbIdentity = nil; self.isUSB = false; self.wirelessMode = wirelessMode
    }

    func catalog() async throws -> [CameraFile] { try await repository.loadCatalog() }

    /// Debug-only STA protection experiments. The repository keeps these
    /// methods read-only and rejects AP/USB sessions internally.
    func isSTASession() async -> Bool { await repository.isSTASession() }
    func probeProtectionHeaders(files: [CameraFile]) async {
        await repository.probeProtectionHeaders(files: files)
    }
    func probeProtectionProperties(files: [CameraFile]) async {
        await repository.probeProtectionProperties(files: files)
    }

    func scanSnapshotForResume() async -> PhotoScanSnapshot? {
        await repository.scanSnapshotForResume()
    }

    func scanCatalog(onBatch: @escaping @Sendable ([CameraFile]) async throws -> Void) async throws {
        try await prepareUSBCatalogMetadata()
        _ = try await repository.scanCatalog(onBatch: onBatch)
    }

    func scanCatalog(
        preserveExisting: Bool,
        resumeSnapshot: PhotoScanSnapshot? = nil,
        detectNewHandles: Bool = false,
        loadingRange: PhotoLoadingRange = .all,
        currentLoadingRange: (@Sendable () async -> PhotoLoadingRange)? = nil,
        nextBatchSize: @escaping @Sendable () async -> Int = { 12 },
        onBatch: @escaping @Sendable ([CameraFile]) async throws -> Void
    ) async throws -> PhotoScanResult {
        try await prepareUSBCatalogMetadata()
        if !preserveExisting {
            decodedThumbnailCache.clear()
            let identity = await thumbnailCacheIdentity()
            await thumbnailStore.resetForScan(identity: identity)
            await exifStore.reset()
        }
        return try await repository.scanCatalog(preserveExisting: preserveExisting,
                                          resumeSnapshot: resumeSnapshot,
                                          detectNewHandles: detectNewHandles,
                                          loadingRange: loadingRange,
                                          currentLoadingRange: currentLoadingRange,
                                          nextBatchSize: nextBatchSize,
                                          onBatch: onBatch)
    }

    private func prepareUSBCatalogMetadata() async throws {
        guard isUSB else { return }
        // Load after workspace admission, but before choosing cache identity or
        // publishing files. An unparseable optional DeviceInfo remains tolerated
        // just as it was during the former connection handshake.
        do { _ = try await repository.loadDeviceInfo() }
        catch CameraRepositoryError.invalidDataset { }
        try Task.checkCancellation()
    }

    func thumbnail(handle: UInt32, priority: CameraRequestKind = .visibleThumbnail) async throws -> Data {
        return try await repository.thumbnail(handle: handle, priority: priority)
    }

    /// Metadata-aware path used by the photo grid. It follows Android's
    /// memory → negative → disk → shared request → camera read order.
    func thumbnail(file: CameraFile, allowRemote: Bool = true) async throws -> Data? {
        let identity = await thumbnailCacheIdentity()
        let direct = await repository.usesDirectThumbnailRead()
        return try await thumbnailStore.load(
            file: file,
            identity: identity,
            directSTA: direct,
            allowRemote: allowRemote,
            transform: { data in
                self.processAndCacheThumbnail(data, file: file)
            },
            validate: { !$0.isEmpty },
            fetch: { try await self.thumbnail(handle: file.id, priority: .visibleThumbnail) }
        )
    }

    /// Decoded bitmap path used by the grid. Android returns its in-memory
    /// ImageBitmap directly; keep the same one-decode-per-cache-entry boundary.
    func thumbnailImage(file: CameraFile, allowRemote: Bool = true) async throws -> UIImage? {
        let key = Self.decodedThumbnailKey(file)
        if let image = decodedThumbnailCache.image(for: key) { return image }
        guard let data = try await thumbnail(file: file, allowRemote: allowRemote) else { return nil }
        // A disk/remote miss was decoded by the processor above. Reuse that
        // exact image just as Android returns its freshly decoded ImageBitmap.
        if let image = decodedThumbnailCache.image(for: key) { return image }
        guard let image = UIImage(data: data) else { return nil }
        decodedThumbnailCache.insert(image, for: key)
        return image
    }

    /// Synchronous cache lookup used to initialize SwiftUI cell state before
    /// its first frame. NSCache is thread-safe and this does not cross actor data.
    nonisolated func memoryThumbnailImage(file: CameraFile) -> UIImage? {
        decodedThumbnailCache.image(for: Self.decodedThumbnailKey(file))
    }

    private nonisolated static func decodedThumbnailKey(_ file: CameraFile) -> String {
        "\(file.id)\u{0}\(file.fileName)\u{0}\(file.size)\u{0}\(file.captureDate ?? "")"
    }

    private nonisolated func processAndCacheThumbnail(_ data: Data, file: CameraFile) -> Data {
        guard let result = AndroidThumbnailProcessor.processCameraThumbnailResult(
            data,
            fileExtension: file.fileExtension
        ) else { return Data() }
        decodedThumbnailCache.insert(result.image, for: Self.decodedThumbnailKey(file))
        return result.data
    }

    /// Android prefers the PTP body serial across USB and Wi-Fi; the
    /// repository uses the connection's physical identifier only as fallback.
    func thumbnailCacheIdentity() async -> String {
        return await repository.thumbnailCacheIdentity()
    }

    func thumbnailDiskWritesBlocked() async -> Bool { await thumbnailStore.diskWritesBlocked }

    func prefetchThumbnail(file: CameraFile) async throws -> Bool {
        try await prefetchThumbnailOutcome(file: file).isSettled
    }

    func prefetchThumbnailOutcome(file: CameraFile) async throws -> ThumbnailPrefetchOutcome {
        let direct = await repository.usesDirectThumbnailRead()
        let identity = await thumbnailCacheIdentity()
        let sequential = wirelessMode == .sta
        // STA fills every format. Validate before accepting a disk/camera hit,
        // without retaining every decoded image in the visible-cell LRU.
        let validator: (@Sendable (Data) -> Bool)? = sequential ? { @Sendable data in
            autoreleasepool { UIImage(data: data)?.cgImage != nil }
        } : nil
        let outcome = try await thumbnailStore.prefetchOutcome(
            file: file,
            identity: identity,
            directSTA: direct,
            validate: validator,
            fetch: { try await self.thumbnail(handle: file.id, priority: .backgroundThumbnail) }
        )
        if outcome.isSettled { await thumbnailStore.publish(handle: file.id) }
        else if sequential { await repository.discardRejectedThumbnail(handle: file.id) }
        return outcome
    }

    func thumbnailUpdates(handle: UInt32) async -> AsyncStream<Void> {
        await thumbnailStore.updates(handle: handle)
    }

    /// Cache-only lookup used when the effects editor opens. Android first
    /// publishes an already cached thumbnail and never starts a new GetThumb
    /// just to populate the editor placeholder.
    func cachedThumbnail(file: CameraFile) async throws -> Data? {
        let identity = await thumbnailCacheIdentity()
        let direct = await repository.usesDirectThumbnailRead()
        return try await thumbnailStore.load(
            file: file,
            identity: identity,
            directSTA: direct,
            allowRemote: false,
            transform: { data in
                self.processAndCacheThumbnail(data, file: file)
            },
            validate: { !$0.isEmpty },
            fetch: { Data() }
        )
    }

    func reconcileThumbnailCache(files: [CameraFile], authoritative: Bool) async {
        guard authoritative else { return }
        let identity = await thumbnailCacheIdentity()
        let direct = await repository.usesDirectThumbnailRead()
        await thumbnailStore.reconcile(files: files, identity: identity, directSTA: direct)
    }

    func invalidateThumbnailState(files: [CameraFile]) async {
        guard !files.isEmpty else { return }
        for file in files { decodedThumbnailCache.remove(Self.decodedThumbnailKey(file)) }
        let identity = await thumbnailCacheIdentity()
        let direct = await repository.usesDirectThumbnailRead()
        await thumbnailStore.invalidate(files: files, identity: identity, directSTA: direct)
    }

    func openRemoteReviewCatalog() async throws -> RemoteReviewCatalog {
        try await repository.openRemoteReviewCatalog()
    }
    func readPictureControlOverview(movie: Bool, backupDirectory: URL,
                                    isCurrent: @escaping @Sendable () async -> Bool,
                                    log: (@Sendable (String) -> Void)? = nil) async throws -> PictureControlOverview {
        try await repository.readPictureControlOverview(movie: movie, backupDirectory: backupDirectory, isCurrent: isCurrent, log: log)
    }
    func changePictureControl(slot: Int, change: PictureControlChange, movie: Bool, backupDirectory: URL,
                              isCurrent: @escaping @Sendable () async -> Bool,
                              log: (@Sendable (String) -> Void)? = nil) async throws {
        try await repository.changePictureControl(slot: slot, change: change, movie: movie,
            backupDirectory: backupDirectory, isCurrent: isCurrent, log: log)
    }

    func setFHDActive(_ active: Bool) async { await repository.setFHDActive(active) }
    func setRemoteActive(_ active: Bool) async { await repository.setRemoteActive(active) }
    func setRemoteSessionActive(_ active: Bool) async { await repository.setRemoteSessionActive(active) }
    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) async throws -> RemotePropertyDescriptor? {
        try await repository.refreshRemoteProperty(descriptor)
    }
    func remoteFocusMode() async throws -> RemotePropertyDescriptor? { try await repository.remoteFocusMode() }
    func remoteEvents() async throws -> [STAEvent] { try await repository.remoteEvents() }
    func setTransfersBusy(_ busy: Bool) async { await repository.setTransfersBusy(busy) }

    /// Starts scheduler shutdown before the connection owner releases this
    /// session. Active PTP work may finish its own protocol cleanup; queued
    /// work receives cancellation and cannot leak into a replacement session.
    func beginShutdown(reason: String = "camera session closed") async {
        await repository.beginShutdown(reason: reason)
    }

    func cameraSchedulerSnapshot() async -> CameraSchedulerSnapshot {
        await repository.cameraSchedulerSnapshot()
    }

    func beginRatingPhase() async { await repository.beginRatingPhase() }
    func endRatingPhase() async { await repository.endRatingPhase() }
    func photoRatingGeneration() async -> Int { await repository.photoRatingGeneration() }
    func photoRatingGenerationUpdates() async -> AsyncStream<Int> { await repository.photoRatingGenerationUpdates() }
    func cachedPhotoRating(_ handle: UInt32) async -> Int? {
        await repository.cachedPhotoRating(handle)
    }
    func cachedPhotoRatingOrigin(_ handle: UInt32) async -> String? {
        await repository.cachedPhotoRatingOrigin(handle)
    }
    @discardableResult
    func invalidatePhotoRatings() async -> Int {
        await repository.invalidatePhotoRatings()
    }
    func readObjectRating(file: CameraFile) async throws -> Int? {
        try await repository.readObjectRating(file: file)
    }
    /// Android's explicit AP/USB RAW diagnostic reads the object property and
    /// the embedded header independently, so a property hit never suppresses
    /// the header observation in the report.
    func probeRawRating(file: CameraFile) async {
        PhotoRatingDiagnostics.note(
            "raw probe mode=\(isUSB ? "USB" : "WIFI") file=\(file.fileName) " +
                "handle=0x\(String(format: "%08X", file.id))"
        )
        let objectValue: Int?
        do {
            objectValue = try await readObjectRating(file: file)
        } catch {
            PhotoRatingDiagnostics.note("object error=\(String(describing: error))")
            objectValue = nil
        }
        PhotoRatingDiagnostics.note("object property=0xDC8A result=\(objectValue.map { String($0) } ?? "unsupported-or-unknown")")
        let headerValue: Int?
        do {
            headerValue = try await readPhotoRatingHeader(file: file)
        } catch {
            PhotoRatingDiagnostics.note("header error=\(String(describing: error))")
            headerValue = nil
        }
        PhotoRatingDiagnostics.note("header result=\(headerValue.map { String($0) } ?? "unknown")")
        PhotoRatingDiagnostics.note("raw probe complete")
    }
    func readObjectOrRawHeaderRating(file: CameraFile) async throws -> Int? {
        try await repository.readObjectOrRawHeaderRating(file: file)
    }
    func readPhotoRatingHeader(file: CameraFile) async throws -> Int? {
        try await repository.readPhotoRatingHeader(file: file)
    }
    func readVideoRating(file: CameraFile) async throws -> Int? {
        try await repository.readVideoRating(file: file)
    }

    /// The active transport is probed only when the command channel is idle.
    /// Both USB and Wi-Fi use the same Nikon GetStorageIDs liveness rule.
    func keepalive() async -> Bool { await repository.keepalive() }
    func remoteKeepalive() async { _ = await repository.keepalive() }
    /// Android polls camera events for USB as well as PTP/IP. Keep the same
    /// idle catalog maintenance path for both transports.
    func maintainCatalogIfIdle() async { await repository.maintainCatalogIfIdle() }
    func setPreferHighThroughputTransfers(_ enabled: Bool) async {
        await repository.setPreferHighThroughputTransfers(enabled)
    }
    func withInteractivePreviewPriority<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await repository.withInteractivePreviewPriority(operation)
    }
    func backgroundThumbnailFillAllowed() async -> Bool {
        await repository.backgroundThumbnailFillAllowed()
    }

    func preview(handle: UInt32) async throws -> Data {
        // AP/USB use FHD with session-scoped capability and busy retries.
        // The preview page defers remote GetThumb until EXIF has finished.
        return try await repository.preview(handle: handle)
    }

    /// Android keeps the current-page FHD request and its EXIF read inside one
    /// interactive-priority reservation (`PhotoPreview.kt:911`).  Keep the
    /// reservation across both operations so a download slice cannot be
    /// inserted between them.  A failed FHD request does not suppress the
    /// subsequent EXIF attempt.
    func previewAndExif(file: CameraFile, loadPreview: Bool = true, loadExif: Bool = true,
                        onPreviewLoaded: (@MainActor @Sendable (Data?) async -> Void)? = nil) async -> (Data?, PhotoExif?) {
        await (try? repository.withInteractivePreviewPriority {
            let image = loadPreview ? (try? await self.repository.preview(handle: file.id)) : nil
            if loadPreview, !Task.isCancelled { await onPreviewLoaded?(image) }
            guard !Task.isCancelled else { return (image, nil) }
            let metadata: PhotoExif?
            if loadExif {
                metadata = try? await self.exifStore.load(file: file) { length in
                    try await self.repository.readPrefix(handle: file.id, length: length)
                }
            } else {
                metadata = nil
            }
            return (image, metadata)
        }) ?? (nil, nil)
    }

    /// Connected-settings sample load. Unlike an interactive photo preview,
    /// this request waits for transfer/monitor/FHD owners before it starts and
    /// reads EXIF only after a decodable FHD image succeeds.
    func effectPreviewAndExif(file: CameraFile) async throws -> (Data?, PhotoExif?) {
        try await repository.withEffectPreviewPriority {
            let image = try await self.repository.preview(handle: file.id)
            guard UIImage(data: image) != nil else { return (nil, nil) }
            let metadata = try? await self.exifStore.load(file: file) { length in
                try await self.repository.readPrefix(handle: file.id, length: length)
            }
            return (image, metadata)
        }
    }

    func readPrefix(file: CameraFile, length: Int64, retryDeviceBusy: Bool = false) async throws -> Data {
        return try await repository.readPrefix(handle: file.id, length: length, retryDeviceBusy: retryDeviceBusy)
    }

    func exif(file: CameraFile) async throws -> PhotoExif? {
        try await exifStore.load(file: file) { [self] length in
            try await self.readPrefix(file: file, length: length)
        }
    }

    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        return try await repository.download(handle: file.id, size: file.size,
                                             fileName: file.fileName,
                                             captureDate: file.captureDate,
                                             to: directory, progress: progress)
    }

    func downloadWithMetrics(file: CameraFile, to directory: URL,
                             progress: (@Sendable (TransferDownloadProgress) -> Void)? = nil) async throws -> URL {
        try await downloadResult(file: file, to: directory, captureHeader: false, progress: progress).url
    }

    func downloadResult(file: CameraFile, to directory: URL, captureHeader: Bool,
                        progress: (@Sendable (TransferDownloadProgress) -> Void)?) async throws -> CameraDownloadResult {
        try await repository.downloadResult(handle: file.id, size: file.size, fileName: file.fileName,
                                             captureDate: file.captureDate, to: directory,
                                             captureHeader: captureHeader, progress: progress)
    }

    func photoMetadataIdentity() async -> PhotoMetadataCameraIdentity? {
        await repository.photoMetadataIdentity()
    }

    func frameMetadataHeader(file: CameraFile) async throws -> Data? {
        try await repository.frameMetadataHeader(file: file, expectedSource: nil)
    }

    func frameMetadataHeader(file: CameraFile, expectedSource: PhotoMetadataCameraIdentity?) async throws -> Data? {
        try await repository.frameMetadataHeader(file: file, expectedSource: expectedSource)
    }

    func frameMetadataHeader(file: CameraFile, expectedSource: PhotoMetadataCameraIdentity?, maxBytes: Int) async throws -> Data? {
        try await repository.frameMetadataHeader(file: file, expectedSource: expectedSource, maxBytes: maxBytes)
    }

    // Remote monitor operations share the same serialized PTP session as the
    // catalog. USB's repository is backed by SelectedUSBPTPTransport, while
    // Wi‑Fi's repository is backed by PTP/IP; both therefore use one command
    // path and one transaction owner.
    func startLiveView() async throws {
        try await repository.startLiveView()
    }

    func endLiveView() async {
        await repository.endLiveView()
    }

    func liveViewFrame() async throws -> RemoteLiveViewPacket {
        try await repository.liveViewFrame()
    }

    func remoteMovieMode() async throws -> Bool? { try await repository.remoteMovieMode() }

    func monitorStorageIDs() async throws -> [UInt32] {
        try await repository.monitorStorageIDs()
    }

    func monitorFreeBytes(storageID: UInt32, allowed: @escaping @Sendable () async -> Bool) async throws -> Int64? {
        try await repository.monitorFreeBytes(storageID: storageID, allowed: allowed)
    }

    func probeLegacyVideoTime() async throws -> String {
        try await repository.probeLegacyVideoTime()
    }

    func probeMovieFormat() async throws -> String {
        try await repository.probeMovieFormat()
    }

    func capturePhoto() async throws {
        try await repository.capturePhoto()
    }

    func remoteDeviceModel() async -> String? { await repository.remoteDeviceModel() }

    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor? {
        try await repository.remoteProperty(property)
    }

    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws {
        try await repository.setRemoteProperty(descriptor, value: value)
    }

    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult {
        try await repository.focusAt(trackingX: trackingX, trackingY: trackingY,
                                      focusX: focusX, focusY: focusY)
    }

    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32,
                 tapPath: RcTapFocusPath?) async throws -> RemoteFocusResult {
        try await repository.focusAt(trackingX: trackingX, trackingY: trackingY,
                                     focusX: focusX, focusY: focusY, tapPath: tapPath)
    }

    func halfPressFocus() async throws -> RemoteFocusResult {
        try await repository.halfPressFocus()
    }

    func endSubjectTracking() async throws { try await repository.endSubjectTracking() }
    func endSubjectTrackingForTool() async throws -> UInt16? { try await repository.endSubjectTrackingForTool() }
    func refreshUSBRemoteSession() async throws -> String { try await repository.refreshUSBRemoteSession() }
    func setRemoteControlMode(_ enabled: Bool) async throws -> UInt16 {
        try await repository.setRemoteControlMode(enabled)
    }
    func hasRemoteControlMode() async -> Bool { await repository.hasRemoteControlMode() }
    func setRemoteDiagnosticControlMode(_ enabled: Bool) async throws -> UInt16 {
        try await repository.setRemoteDiagnosticControlMode(enabled)
    }
    func hasRemoteDiagnosticControlMode() async -> Bool { await repository.hasRemoteDiagnosticControlMode() }
    func hasMovieApplicationMode() async -> Bool { await repository.hasMovieApplicationMode() }
    func ensureMovieApplicationMode() async throws { try await repository.ensureMovieApplicationMode() }
    func clearMovieApplicationMode(force: Bool) async { await repository.clearMovieApplicationMode(force: force) }
    func startPreparedUSBMovieRecording() async throws -> RemoteMovieStartResult {
        try await repository.startPreparedUSBMovieRecording()
    }
    func startMovieRecording() async throws -> RemoteMovieStartResult {
        try await repository.startMovieRecording()
    }
    func endMovieRecording() async throws -> UInt16 { try await repository.endMovieRecording() }
}

protocol RemoteCameraControlling: Sendable {
    func remoteKeepalive() async
    var isUSB: Bool { get }
    func remoteDeviceModel() async -> String?
    func setRemoteActive(_ active: Bool) async
    func setRemoteSessionActive(_ active: Bool) async
    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) async throws -> RemotePropertyDescriptor?
    func remoteFocusMode() async throws -> RemotePropertyDescriptor?
    func remoteEvents() async throws -> [STAEvent]
    func startLiveView() async throws
    func endLiveView() async
    func liveViewFrame() async throws -> RemoteLiveViewPacket
    func remoteMovieMode() async throws -> Bool?
    func monitorStorageIDs() async throws -> [UInt32]
    func monitorFreeBytes(storageID: UInt32, allowed: @escaping @Sendable () async -> Bool) async throws -> Int64?
    func probeLegacyVideoTime() async throws -> String
    func probeMovieFormat() async throws -> String
    func capturePhoto() async throws
    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor?
    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws
    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult
    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32,
                 tapPath: RcTapFocusPath?) async throws -> RemoteFocusResult
    func halfPressFocus() async throws -> RemoteFocusResult
    func endSubjectTracking() async throws
    func endSubjectTrackingForTool() async throws -> UInt16?
    func startMovieRecording() async throws -> RemoteMovieStartResult
    func endMovieRecording() async throws -> UInt16
    func refreshUSBRemoteSession() async throws -> String
    func setRemoteControlMode(_ enabled: Bool) async throws -> UInt16
    func hasRemoteControlMode() async -> Bool
    func setRemoteDiagnosticControlMode(_ enabled: Bool) async throws -> UInt16
    func hasRemoteDiagnosticControlMode() async -> Bool
    func hasMovieApplicationMode() async -> Bool
    func ensureMovieApplicationMode() async throws
    func clearMovieApplicationMode(force: Bool) async
    func startPreparedUSBMovieRecording() async throws -> RemoteMovieStartResult
}

extension RemoteCameraControlling {
    func remoteKeepalive() async { }
    func setRemoteSessionActive(_ active: Bool) async { await setRemoteActive(active) }

    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32,
                 tapPath: RcTapFocusPath?) async throws -> RemoteFocusResult {
        try await focusAt(trackingX: trackingX, trackingY: trackingY, focusX: focusX, focusY: focusY)
    }
    func remoteDeviceModel() async -> String? { nil }
    func monitorStorageIDs() async throws -> [UInt32] { [] }
    func monitorFreeBytes(storageID: UInt32, allowed: @escaping @Sendable () async -> Bool) async throws -> Int64? { nil }
    func probeLegacyVideoTime() async throws -> String { "unsupported" }
    func probeMovieFormat() async throws -> String { "unsupported" }
    func endSubjectTrackingForTool() async throws -> UInt16? {
        try await endSubjectTracking()
        return nil
    }
    func refreshUSBRemoteSession() async throws -> String { "" }
    func setRemoteControlMode(_ enabled: Bool) async throws -> UInt16 { PTPConstants.responseOK }
    func hasRemoteControlMode() async -> Bool { false }
    func setRemoteDiagnosticControlMode(_ enabled: Bool) async throws -> UInt16 { PTPConstants.responseOK }
    func hasRemoteDiagnosticControlMode() async -> Bool { false }
    func hasMovieApplicationMode() async -> Bool { false }
    func ensureMovieApplicationMode() async throws {}
    func clearMovieApplicationMode(force: Bool) async {}
    func startPreparedUSBMovieRecording() async throws -> RemoteMovieStartResult {
        try await startMovieRecording()
    }
}

extension CameraSession: RemoteCameraControlling {}
