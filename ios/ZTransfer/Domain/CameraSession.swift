import Foundation

/// A connected camera's single owner. USB uses ImageCaptureCore for media;
/// PTP/IP sessions use the same repository commands, while both expose one
/// cancellation-safe API to lists, previews and the transfer queue.
actor CameraSession {
    let repository: CameraRepository
    private let usbTransport: ImageCaptureUSBTransport?
    private let deviceID: String?
    /// The connection pill uses the transport kind just like Android's
    /// SignalPill (USB icon for wired sessions, Wi‑Fi icon otherwise).
    nonisolated let isUSB: Bool
    /// Keep the selected wireless route with the session so the photo-list
    /// signal pill can render Android's STA-specific state instead of
    /// collapsing every PTP/IP connection into a generic Wi‑Fi glyph.
    nonisolated let wirelessMode: WirelessMode?
    private let thumbnailStore = PhotoThumbnailStore()
    private let exifStore = PhotoExifStore()

    init(repository: CameraRepository, transport: ImageCaptureUSBTransport, deviceID: String) {
        self.repository = repository; self.usbTransport = transport; self.deviceID = deviceID; self.isUSB = true; self.wirelessMode = nil
    }

    /// Creates a network-backed session. The repository's PTPSession is the
    /// serialized command channel for thumbnails, reads and downloads.
    init(repository: CameraRepository, wirelessMode: WirelessMode = .ap) {
        self.repository = repository; self.usbTransport = nil; self.deviceID = nil; self.isUSB = false; self.wirelessMode = wirelessMode
    }

    func catalog() async throws -> [CameraFile] { try await repository.loadCatalog() }

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
        if let usbTransport, let deviceID {
            return try await usbTransport.thumbnail(for: handle, deviceID: deviceID)
        }
        return try await repository.thumbnail(handle: handle)
    }

    /// Metadata-aware path used by the photo grid. It follows Android's
    /// memory → negative → disk → shared request → camera read order.
    func thumbnail(file: CameraFile) async throws -> Data? {
        let identity: String?
        if let deviceID { identity = deviceID }
        else { identity = await repository.thumbnailCacheIdentity() }
        guard let identity else { return try await thumbnail(handle: file.id) }
        let direct = await repository.usesDirectThumbnailRead()
        return try await thumbnailStore.load(file: file, identity: identity, directSTA: direct, allowRemote: true) {
            try await self.thumbnail(handle: file.id)
        }
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
        return try await thumbnailStore.prefetch(file: file, identity: identity, directSTA: direct) {
            try await self.thumbnail(handle: file.id)
        }
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
        return try await thumbnailStore.load(file: file, identity: identity,
                                             directSTA: direct, allowRemote: false) { Data() }
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

    func setFHDActive(_ active: Bool) async { await repository.setFHDActive(active) }
    func setTransfersBusy(_ busy: Bool) async { await repository.setTransfersBusy(busy) }
    func setEffectPreviewActive(_ active: Bool) async { await repository.setEffectPreviewActive(active) }
    func backgroundThumbnailFillAllowed() async -> Bool {
        await repository.backgroundThumbnailFillAllowed()
    }

    func preview(handle: UInt32) async throws -> Data {
        if let usbTransport, let deviceID {
            // ImageCaptureCore exposes the same camera-generated preview as its
            // best available thumbnail; the PTP fallback remains for Wi-Fi.
            return try await usbTransport.thumbnail(for: handle, deviceID: deviceID)
        }
        return try await repository.preview(handle: handle)
    }

    func readPrefix(file: CameraFile, length: Int64) async throws -> Data {
        if let usbTransport, let deviceID {
            guard let cameraFile = usbTransport.cameraFiles(for: deviceID).first(where: { $0.ptpObjectHandle == file.id }) else {
                throw CameraTransportError.protocolError("Camera file not found")
            }
            return try await usbTransport.read(file: cameraFile, offset: 0, length: min(length, cameraFile.fileSize))
        }
        return try await repository.readPrefix(handle: file.id, length: length)
    }

    func exif(file: CameraFile) async throws -> PhotoExif? {
        try await exifStore.load(file: file) { [self] length in
            try await self.readPrefix(file: file, length: length)
        }
    }

    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let usbTransport, let deviceID {
            guard let cameraFile = usbTransport.cameraFiles(for: deviceID).first(where: { $0.ptpObjectHandle == file.id }) else {
                throw CameraTransportError.protocolError("Camera file not found")
            }
            return try await usbTransport.download(file: cameraFile, to: directory, saveAs: file.fileName, progress: progress)
        }
        return try await repository.download(handle: file.id, size: file.size, fileName: file.fileName, to: directory, progress: progress)
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

    func liveViewFrame(preferEnhanced: Bool = true) async throws -> Data {
        return try await repository.liveViewFrame(preferEnhanced: preferEnhanced)
    }

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

    func endSubjectTracking() async throws { try await repository.endSubjectTracking() }
    func startMovieRecording() async throws -> RemoteMovieStartResult {
        try await repository.startMovieRecording()
    }
    func endMovieRecording() async throws -> UInt16 { try await repository.endMovieRecording() }
}

protocol RemoteCameraControlling: Sendable {
    func startLiveView() async throws
    func endLiveView() async
    func liveViewFrame(preferEnhanced: Bool) async throws -> Data
    func capturePhoto() async throws
    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor?
    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws
    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult
    func endSubjectTracking() async throws
    func startMovieRecording() async throws -> RemoteMovieStartResult
    func endMovieRecording() async throws -> UInt16
}

extension CameraSession: RemoteCameraControlling {}
