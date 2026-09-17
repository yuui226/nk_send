import Foundation
import UIKit

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
    private let deviceID: String?
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
    private let thumbnailStore = PhotoThumbnailStore()
    private let exifStore = PhotoExifStore()

    init(repository: CameraRepository, transport: ImageCaptureUSBTransport, deviceID: String, sessionToken: UUID) {
        self.repository = repository; self.usbTransport = transport; self.deviceID = deviceID; self.transportDeviceID = deviceID
        self.usbIdentity = repository.usbSessionIdentity ?? USBSessionIdentity(token: sessionToken)
        self.isUSB = true; self.wirelessMode = nil
    }

    /// Creates a network-backed session. The repository's PTPSession is the
    /// serialized command channel for thumbnails, reads and downloads.
    init(repository: CameraRepository, wirelessMode: WirelessMode = .ap) {
        self.repository = repository; self.usbTransport = nil; self.deviceID = nil; self.transportDeviceID = nil; self.usbIdentity = nil; self.isUSB = false; self.wirelessMode = wirelessMode
    }

    func catalog() async throws -> [CameraFile] { try await repository.loadCatalog() }

    func scanSnapshotForResume() async -> PhotoScanSnapshot? {
        await repository.scanSnapshotForResume()
    }

    func scanCatalog(onBatch: @escaping @Sendable ([CameraFile]) async throws -> Void) async throws {
        _ = try await repository.scanCatalog(onBatch: onBatch)
    }

    func scanCatalog(
        preserveExisting: Bool,
        resumeSnapshot: PhotoScanSnapshot? = nil,
        detectNewHandles: Bool = false,
        onBatch: @escaping @Sendable ([CameraFile]) async throws -> Void
    ) async throws -> PhotoScanResult {
        if !preserveExisting {
            let identity: String?
            if let deviceID { identity = deviceID }
            else { identity = await repository.thumbnailCacheIdentity() }
            if let identity { await thumbnailStore.resetForScan(identity: identity) }
            await exifStore.reset()
        }
        return try await repository.scanCatalog(preserveExisting: preserveExisting,
                                          resumeSnapshot: resumeSnapshot,
                                          detectNewHandles: detectNewHandles,
                                          onBatch: onBatch)
    }

    func thumbnail(handle: UInt32) async throws -> Data {
        return try await repository.thumbnail(handle: handle)
    }

    /// Metadata-aware path used by the photo grid. It follows Android's
    /// memory → negative → disk → shared request → camera read order.
    func thumbnail(file: CameraFile, allowRemote: Bool = true) async throws -> Data? {
        let identity: String?
        if let deviceID { identity = deviceID }
        else { identity = await repository.thumbnailCacheIdentity() }
        guard let identity else {
            return allowRemote ? try await thumbnail(handle: file.id) : nil
        }
        let direct = await repository.usesDirectThumbnailRead()
        return try await thumbnailStore.load(
            file: file,
            identity: identity,
            directSTA: direct,
            allowRemote: allowRemote,
            transform: { data in
                AndroidThumbnailProcessor.process(data, fileExtension: file.fileExtension)
            },
            validate: { UIImage(data: $0) != nil },
            fetch: { try await self.thumbnail(handle: file.id) }
        )
    }

    func prefetchThumbnail(file: CameraFile) async throws -> Bool {
        // Android STA direct browsing leaves RAW/video previews lazy; these
        // formats are resolved only when visible or opened in preview.
        let direct = await repository.usesDirectThumbnailRead()
        if direct && [".nef", ".nrw", ".mov", ".mp4"].contains(file.fileExtension) { return true }
        let identity: String?
        if let deviceID { identity = deviceID }
        else { identity = await repository.thumbnailCacheIdentity() }
        guard let identity else { return false }
        return try await thumbnailStore.prefetch(
            file: file,
            identity: identity,
            directSTA: direct,
            fetch: { try await self.thumbnail(handle: file.id) }
        )
    }

    /// Cache-only lookup used when the effects editor opens. Android first
    /// publishes an already cached thumbnail and never starts a new GetThumb
    /// just to populate the editor placeholder.
    func cachedThumbnail(file: CameraFile) async throws -> Data? {
        let identity: String?
        if let deviceID { identity = deviceID }
        else { identity = await repository.thumbnailCacheIdentity() }
        guard let identity else { return nil }
        let direct = await repository.usesDirectThumbnailRead()
        return try await thumbnailStore.load(
            file: file,
            identity: identity,
            directSTA: direct,
            allowRemote: false,
            transform: { data in
                AndroidThumbnailProcessor.process(data, fileExtension: file.fileExtension)
            },
            validate: { UIImage(data: $0) != nil },
            fetch: { Data() }
        )
    }

    func reconcileThumbnailCache(files: [CameraFile], authoritative: Bool) async {
        guard authoritative else { return }
        let identity: String?
        if let deviceID { identity = deviceID }
        else { identity = await repository.thumbnailCacheIdentity() }
        guard let identity else { return }
        let direct = await repository.usesDirectThumbnailRead()
        await thumbnailStore.reconcile(files: files, identity: identity, directSTA: direct)
    }

    func invalidateThumbnailState(files: [CameraFile]) async {
        guard !files.isEmpty else { return }
        let identity: String?
        if let deviceID { identity = deviceID }
        else { identity = await repository.thumbnailCacheIdentity() }
        guard let identity else { return }
        let direct = await repository.usesDirectThumbnailRead()
        await thumbnailStore.invalidate(files: files, identity: identity, directSTA: direct)
    }

    func setFHDActive(_ active: Bool) async { await repository.setFHDActive(active) }
    func setRemoteActive(_ active: Bool) async { await repository.setRemoteActive(active) }
    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) async throws -> RemotePropertyDescriptor? {
        try await repository.refreshRemoteProperty(descriptor)
    }
    func remoteFocusMode() async throws -> RemotePropertyDescriptor? { try await repository.remoteFocusMode() }
    func remoteEvents() async throws -> [STAEvent] { try await repository.remoteEvents() }
    func setTransfersBusy(_ busy: Bool) async { await repository.setTransfersBusy(busy) }

    /// The active transport is probed only when the command channel is idle.
    /// Both USB and Wi-Fi use the same Nikon GetStorageIDs liveness rule.
    func keepalive() async -> Bool { await repository.keepalive() }
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
        // USB and Wi-Fi use the same Nikon PTP operation order. ImageCaptureCore
        // only owns discovery/session callbacks; it must not replace Android's
        // FHD → LargeThumb → standard-thumbnail preview fallback.
        return try await repository.preview(handle: handle)
    }

    /// Android keeps the current-page FHD request and its EXIF read inside one
    /// interactive-priority reservation (`PhotoPreview.kt:911`).  Keep the
    /// reservation across both operations so a download slice cannot be
    /// inserted between them.  A failed FHD request does not suppress the
    /// subsequent EXIF attempt.
    func previewAndExif(file: CameraFile, loadPreview: Bool = true) async -> (Data?, PhotoExif?) {
        await (try? repository.withInteractivePreviewPriority {
            let image = loadPreview ? (try? await self.repository.preview(handle: file.id)) : nil
            let metadata = try? await self.exifStore.load(file: file) { length in
                try await self.repository.readPrefix(handle: file.id, length: length)
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

    func readPrefix(file: CameraFile, length: Int64) async throws -> Data {
        return try await repository.readPrefix(handle: file.id, length: length)
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

    func frameMetadataHeader(file: CameraFile) async throws -> Data? {
        try await repository.readPrefix(handle: file.id, length: Int64(cameraExifHeaderCaptureBytes))
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

    func capturePhoto() async throws {
        try await repository.capturePhoto()
    }

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

    func halfPressFocus() async throws -> RemoteFocusResult {
        try await repository.halfPressFocus()
    }

    func endSubjectTracking() async throws { try await repository.endSubjectTracking() }
    func refreshUSBRemoteSession() async throws -> String { try await repository.refreshUSBRemoteSession() }
    func setRemoteControlMode(_ enabled: Bool) async throws -> UInt16 {
        try await repository.setRemoteControlMode(enabled)
    }
    func hasRemoteControlMode() async -> Bool { await repository.hasRemoteControlMode() }
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
    var isUSB: Bool { get }
    func setRemoteActive(_ active: Bool) async
    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) async throws -> RemotePropertyDescriptor?
    func remoteFocusMode() async throws -> RemotePropertyDescriptor?
    func remoteEvents() async throws -> [STAEvent]
    func startLiveView() async throws
    func endLiveView() async
    func liveViewFrame() async throws -> RemoteLiveViewPacket
    func remoteMovieMode() async throws -> Bool?
    func capturePhoto() async throws
    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor?
    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws
    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult
    func halfPressFocus() async throws -> RemoteFocusResult
    func endSubjectTracking() async throws
    func startMovieRecording() async throws -> RemoteMovieStartResult
    func endMovieRecording() async throws -> UInt16
    func refreshUSBRemoteSession() async throws -> String
    func setRemoteControlMode(_ enabled: Bool) async throws -> UInt16
    func hasRemoteControlMode() async -> Bool
    func hasMovieApplicationMode() async -> Bool
    func ensureMovieApplicationMode() async throws
    func clearMovieApplicationMode(force: Bool) async
    func startPreparedUSBMovieRecording() async throws -> RemoteMovieStartResult
}

extension RemoteCameraControlling {
    func refreshUSBRemoteSession() async throws -> String { "" }
    func setRemoteControlMode(_ enabled: Bool) async throws -> UInt16 { PTPConstants.responseOK }
    func hasRemoteControlMode() async -> Bool { false }
    func hasMovieApplicationMode() async -> Bool { false }
    func ensureMovieApplicationMode() async throws {}
    func clearMovieApplicationMode(force: Bool) async {}
    func startPreparedUSBMovieRecording() async throws -> RemoteMovieStartResult {
        try await startMovieRecording()
    }
}

extension CameraSession: RemoteCameraControlling {}
