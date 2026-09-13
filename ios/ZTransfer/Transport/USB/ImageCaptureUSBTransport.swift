import Foundation
@preconcurrency import ImageCaptureCore
import ImageIO

enum USBAuthorizationState: String, Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized
}

struct USBDeviceDescriptor: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let productKind: String?
    let transportType: String?
}

enum USBTransportEvent: Sendable, Equatable {
    case authorization(USBAuthorizationState)
    case deviceAdded(USBDeviceDescriptor)
    case deviceRemoved(id: String)
    case ready(id: String)
    case sessionOpened(id: String)
    case sessionClosed(id: String)
    case failed(id: String?, message: String)
}

private final class DownloadOperationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: Progress?
    private var progressTask: Task<Void, Never>?
    private var cancellationRequested = false
    var value: Progress? {
        get { lock.lock(); defer { lock.unlock() }; return operation }
        set {
            lock.lock()
            operation = newValue
            let shouldCancel = cancellationRequested
            lock.unlock()
            if shouldCancel { newValue?.cancel() }
        }
    }

    func attachProgressTask(_ task: Task<Void, Never>) {
        lock.lock(); progressTask = task; let shouldCancel = cancellationRequested; lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let operation = operation
        let progressTask = progressTask
        lock.unlock()
        operation?.cancel()
        progressTask?.cancel()
    }
}

/// Bridges ImageCaptureCore callbacks to Swift concurrency while making caller
/// cancellation deterministic.  The framework has no cancellation callback for
/// reads/open requests; the late framework callback is therefore ignored after
/// this box has resumed the caller with CancellationError.
private final class ThrowingContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelled = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

/// ImageCaptureCore is Apple's iOS PTP camera bridge. It owns discovery and session
/// lifecycle; PTP commands are sent only after `sessionOpened` and are serialized by
/// the higher-level camera actor.
final class ImageCaptureUSBTransport: NSObject, CameraTransport, @unchecked Sendable {
    private let browser = ICDeviceBrowser()
    private var cameras: [String: ICCameraDevice] = [:]
    /// The object that owns the currently opened session.  ImageCaptureCore can
    /// report a remove/add pair with the same UUID while an old close callback is
    /// still in flight, so closing by UUID alone can close the replacement.
    private var openedCameras: [String: ICCameraDevice] = [:]
    private var continuation: AsyncStream<USBTransportEvent>.Continuation?
    private var stream: AsyncStream<USBTransportEvent>?
    private var thumbnailWaiters: [UInt32: [UUID: CheckedContinuation<Data, Error>]] = [:]
    private let thumbnailLock = NSLock()
    private let thumbnailCache = ThumbnailCache()
    private let lock = NSLock()

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x0101)!
    }

    func events() -> AsyncStream<USBTransportEvent> {
        lock.lock()
        if let stream { lock.unlock(); return stream }
        lock.unlock()
        let stream = AsyncStream<USBTransportEvent> { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
        lock.lock()
        self.stream = stream
        lock.unlock()
        return stream
    }

    func start() {
        emit(.authorization(status(from: browser.contentsAuthorizationStatus)))
        if browser.contentsAuthorizationStatus == .notDetermined {
            browser.requestContentsAuthorization { [weak self] status in self?.emit(.authorization(self?.status(from: status) ?? .notDetermined)) }
        }
        browser.start()
    }

    func stop() {
        browser.stop()
        lock.lock()
        cameras.removeAll()
        openedCameras.removeAll()
        lock.unlock()
        finishThumbnailWaiters(with: CameraTransportError.disconnected)
        // Finish outside the lock: AsyncStream invokes onTermination synchronously
        // on some OS releases, and that callback calls stop() again.
        lock.lock()
        let current = continuation
        continuation = nil
        stream = nil
        lock.unlock()
        current?.finish()
    }

    func openSession(for id: String) async throws {
        guard let camera = camera(for: id) else { throw CameraTransportError.disconnected }
        let box = ThrowingContinuationBox<Void>()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.install(continuation)
                camera.requestOpenSession(options: nil) { [weak self] error in
                    if let error {
                        self?.emit(.failed(id: id, message: error.localizedDescription))
                        _ = box.finish(.failure(error))
                    } else if box.finish(.success(())) {
                        self?.lock.lock()
                        self?.openedCameras[id] = camera
                        self?.lock.unlock()
                        self?.emit(.sessionOpened(id: id))
                    }
                }
            }
        }, onCancel: { box.cancel() })
    }

    func closeSession(for id: String) async {
        let camera = openedCamera(for: id)
        guard let camera else { return }
        await withCheckedContinuation { continuation in
            camera.requestCloseSession(options: nil) { [weak self] _ in
                self?.lock.lock()
                if self?.openedCameras[id] === camera { self?.openedCameras.removeValue(forKey: id) }
                self?.lock.unlock()
                self?.emit(.sessionClosed(id: id))
                continuation.resume()
            }
        }
    }

    func sendPTP(command: Data, data: Data? = nil, to id: String) async throws -> (response: Data, payload: Data) {
        guard let camera = camera(for: id) else { throw CameraTransportError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            camera.requestSendPTPCommand(command, outData: data) { response, payload, error in
                if let error { continuation.resume(throwing: Self.map(error)) }
                else { continuation.resume(returning: (response, payload)) }
            }
        }
    }

    func cameraFiles(for id: String) -> [ICCameraFile] {
        guard let camera = camera(for: id) else { return [] }
        return (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
    }

    func thumbnail(for handle: UInt32, deviceID: String) async throws -> Data {
        let cacheKey = "\(deviceID)\u{0}\(handle)"
        if let cached = await thumbnailCache.value(for: cacheKey) { return cached }
        guard let file = cameraFiles(for: deviceID).first(where: { $0.ptpObjectHandle == handle }) else {
            throw CameraTransportError.protocolError("Camera file not found")
        }
        if let image = file.thumbnail, let data = Self.pngData(image) { await thumbnailCache.insert(data, for: cacheKey); return data }
        let requestID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                thumbnailLock.lock()
                if Task.isCancelled {
                    thumbnailLock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    thumbnailWaiters[handle, default: [:]][requestID] = continuation
                    thumbnailLock.unlock()
                    file.requestThumbnail()
                }
            }
        }, onCancel: { [weak self] in self?.cancelThumbnail(handle: handle, requestID: requestID) })
    }

    func read(file: ICCameraFile, offset: Int64, length: Int64) async throws -> Data {
        let box = ThrowingContinuationBox<Data>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                box.install(continuation)
                file.requestReadData(atOffset: offset, length: length) { data, error in
                    if let error { _ = box.finish(.failure(Self.map(error))) }
                    else if let data { _ = box.finish(.success(data)) }
                    else { _ = box.finish(.failure(CameraTransportError.protocolError("Camera returned no data"))) }
                }
            }
        }, onCancel: { box.cancel() })
    }

    func download(file: ICCameraFile, to directory: URL, saveAs name: String? = nil,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        var options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directory,
            .overwrite: false,
        ]
        if let name { options[.saveAsFilename] = name }
        let operationBox = DownloadOperationBox()
        let continuationBox = ThrowingContinuationBox<URL>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                continuationBox.install(continuation)
                guard let operation = file.requestDownload(options: options, completion: { filename, error in
                    if let error { _ = continuationBox.finish(.failure(Self.map(error))); return }
                    guard let filename else { _ = continuationBox.finish(.failure(CameraTransportError.protocolError("Download returned no filename"))); return }
                    _ = continuationBox.finish(.success(URL(fileURLWithPath: filename)))
                }) else {
                    _ = continuationBox.finish(.failure(CameraTransportError.disconnected))
                    return
                }
                operationBox.value = operation
                if let progress {
                    let progressTask = Task.detached {
                        while !operation.isFinished {
                            if Task.isCancelled { operation.cancel(); return }
                            progress(operation.fractionCompleted)
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                        progress(operation.fractionCompleted)
                    }
                    operationBox.attachProgressTask(progressTask)
                }
            }
        }, onCancel: {
            // ImageCaptureCore exposes cancellation through the returned NSProgress.
            // The completion continuation still receives the terminal error.
            continuationBox.cancel()
            operationBox.cancel()
        })
    }

    private func emit(_ event: USBTransportEvent) {
        lock.lock(); let continuation = continuation; lock.unlock()
        continuation?.yield(event)
    }

    private func camera(for id: String) -> ICCameraDevice? {
        lock.lock(); defer { lock.unlock() }
        return cameras[id]
    }

    /// Keep NSLock usage in a synchronous helper; Swift 6 forbids calling the
    /// blocking lock API directly from an async function.
    private func openedCamera(for id: String) -> ICCameraDevice? {
        lock.lock(); defer { lock.unlock() }
        return openedCameras[id] ?? cameras[id]
    }

    private func finishThumbnailWaiters(with error: Error) {
        thumbnailLock.lock()
        let pending = thumbnailWaiters.values.flatMap { $0.values }
        thumbnailWaiters.removeAll()
        thumbnailLock.unlock()
        pending.forEach { $0.resume(throwing: error) }
    }

    private static func map(_ error: Error) -> CameraTransportError {
        let nsError = error as NSError
        if nsError.code == NSURLErrorTimedOut { return .timeout }
        if nsError.code == NSUserCancelledError { return .disconnected }
        return .protocolError(nsError.localizedDescription)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func status(from status: ICAuthorizationStatus) -> USBAuthorizationState {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }

    private func descriptor(for camera: ICCameraDevice) -> USBDeviceDescriptor {
        let id = camera.uuidString ?? camera.name ?? UUID().uuidString
        return USBDeviceDescriptor(id: id, name: camera.name ?? "", productKind: camera.productKind, transportType: camera.transportType)
    }
}

extension ImageCaptureUSBTransport: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let descriptor = descriptor(for: camera)
        lock.lock()
        cameras[descriptor.id] = camera
        lock.unlock()
        camera.delegate = self
        emit(.deviceAdded(descriptor))
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let id = device.uuidString ?? device.name ?? UUID().uuidString
        lock.lock()
        cameras.removeValue(forKey: id)
        lock.unlock()
        finishThumbnailWaiters(with: CameraTransportError.disconnected)
        emit(.deviceRemoved(id: id))
    }
}

extension ImageCaptureUSBTransport: ICDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func didRemove(_ device: ICDevice) {}
    func deviceDidBecomeReady(_ device: ICDevice) { emit(.ready(id: device.uuidString ?? device.name ?? "")) }
    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus : Any]) {}
    func device(_ device: ICDevice, didEncounterError error: Error?) { emit(.failed(id: device.uuidString, message: error?.localizedDescription ?? "")) }
    func device(_ device: ICDevice, didEjectWithError error: Error?) {}
}

extension ImageCaptureUSBTransport: ICCameraDeviceDelegate {
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        let handle = item.ptpObjectHandle
        thumbnailLock.lock()
        let continuations: [CheckedContinuation<Data, Error>]
        if let values = thumbnailWaiters.removeValue(forKey: handle)?.values { continuations = Array(values) } else { continuations = [] }
        thumbnailLock.unlock()
        if let error {
            continuations.forEach { $0.resume(throwing: Self.map(error)) }
        } else if let thumbnail, let data = Self.pngData(thumbnail) {
            let deviceID = camera.uuidString ?? camera.name ?? ""
            Task { await thumbnailCache.insert(data, for: "\(deviceID)\u{0}\(handle)") }
            continuations.forEach { $0.resume(returning: data) }
        } else {
            continuations.forEach { $0.resume(throwing: CameraTransportError.protocolError("Camera returned no thumbnail")) }
        }
    }

    private func cancelThumbnail(handle: UInt32, requestID: UUID) {
        thumbnailLock.lock()
        let continuation = thumbnailWaiters[handle]?.removeValue(forKey: requestID)
        if thumbnailWaiters[handle]?.isEmpty == true { thumbnailWaiters.removeValue(forKey: handle) }
        thumbnailLock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable : Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) { emit(.ready(id: device.uuidString ?? device.name ?? "")) }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
