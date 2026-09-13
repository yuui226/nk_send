import Foundation

/// A connected camera's single owner. USB uses ImageCaptureCore for media;
/// PTP/IP sessions use the same repository commands, while both expose one
/// cancellation-safe API to lists, previews and the transfer queue.
actor CameraSession {
    let repository: CameraRepository
    private let usbTransport: ImageCaptureUSBTransport?
    private let deviceID: String?

    init(repository: CameraRepository, transport: ImageCaptureUSBTransport, deviceID: String) {
        self.repository = repository; self.usbTransport = transport; self.deviceID = deviceID
    }

    /// Creates a network-backed session. The repository's PTPSession is the
    /// serialized command channel for thumbnails, reads and downloads.
    init(repository: CameraRepository) {
        self.repository = repository; self.usbTransport = nil; self.deviceID = nil
    }

    func catalog() async throws -> [CameraFile] { try await repository.loadCatalog() }

    func thumbnail(handle: UInt32) async throws -> Data {
        if let usbTransport, let deviceID {
            return try await usbTransport.thumbnail(for: handle, deviceID: deviceID)
        }
        return try await repository.thumbnail(handle: handle)
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
        let prefix = try await readPrefix(file: file, length: 512 * 1024)
        return PhotoExifParser.parse(prefix)
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
