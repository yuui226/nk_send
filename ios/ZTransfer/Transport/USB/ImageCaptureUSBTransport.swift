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
    private var cameraIDsByObject: [ObjectIdentifier: String] = [:]
    /// The object that owns the currently opened session.  ImageCaptureCore can
    /// report a remove/add pair with the same UUID while an old close callback is
    /// still in flight, so closing by UUID alone can close the replacement.
    private var openedCameras: [String: ICCameraDevice] = [:]
    /// Keep a reference while requestOpenSession is in flight.  A cancelled
    /// open can still complete later; retaining it lets the non-cancellable
    /// cleanup issue requestCloseSession just like Android closes NikonCamera
    /// after a stale OpenSession result.
    private var openingCameras: [String: ICCameraDevice] = [:]
    private var continuation: AsyncStream<USBTransportEvent>.Continuation?
    private var stream: AsyncStream<USBTransportEvent>?
    private var thumbnailWaiters: [String: [UUID: CheckedContinuation<Data, Error>]] = [:]
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
        // Stopping the browser does not close an ImageCaptureCore session.
        // Issue close requests before releasing our strong references so a
        // subsequent attach cannot inherit a stale PTP session.
        lock.lock()
        var sessions = openedCameras
        for (id, camera) in openingCameras where sessions[id] == nil { sessions[id] = camera }
        lock.unlock()
        for (id, camera) in sessions {
            camera.requestCloseSession(options: nil) { [weak self] _ in
                self?.removeSession(camera, for: id)
            }
        }
        lock.lock()
        cameras.removeAll()
        cameraIDsByObject.removeAll()
        openedCameras.removeAll()
        openingCameras.removeAll()
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
        markOpening(camera, for: id)
        let box = ThrowingContinuationBox<Void>()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.install(continuation)
                camera.requestOpenSession(options: nil) { [weak self] error in
                    if let error {
                        self?.removeOpening(camera, for: id)
                        self?.emit(.failed(id: id, message: error.localizedDescription))
                        _ = box.finish(.failure(error))
                    } else if box.finish(.success(())) {
                        self?.markOpened(camera, for: id)
                        self?.emit(.sessionOpened(id: id))
                    } else {
                        // Open completed after its caller was cancelled. The
                        // late success must be closed before another attempt.
                        self?.removeOpening(camera, for: id)
                        camera.requestCloseSession(options: nil) { [weak self] _ in
                            self?.removeSession(camera, for: id)
                        }
                    }
                }
            }
        }, onCancel: { box.cancel() })
    }

    func closeSession(for id: String) async {
        let camera = openedCamera(for: id)
        guard let camera else { return }
        let box = ThrowingContinuationBox<Void>()
        _ = try? await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.install(continuation)
                camera.requestCloseSession(options: nil) { [weak self] _ in
                    self?.removeSession(camera, for: id)
                    self?.emit(.sessionClosed(id: id))
                    _ = box.finish(.success(()))
                }
            }
        }, onCancel: { box.cancel() })
        // AsyncDeadline may cancel before the framework callback arrives.
        // Remove ownership now; the late callback remains idempotent.
        removeSession(camera, for: id)
    }

    func sendPTP(command: Data, data: Data? = nil, to id: String) async throws -> (response: Data, payload: Data) {
        guard let camera = camera(for: id) else { throw CameraTransportError.disconnected }
        let box = ThrowingContinuationBox<(Data, Data)>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Data), Error>) in
                box.install(continuation)
                camera.requestSendPTPCommand(command, outData: data) { response, payload, error in
                    if let error { _ = box.finish(.failure(Self.map(error))) }
                    else { _ = box.finish(.success((response, payload))) }
                }
            }
        }, onCancel: { box.cancel() })
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
        let waiterKey = "\(deviceID)\u{0}\(handle)"
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                thumbnailLock.lock()
                if Task.isCancelled {
                    thumbnailLock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    thumbnailWaiters[waiterKey, default: [:]][requestID] = continuation
                    thumbnailLock.unlock()
                    file.requestThumbnail()
                }
            }
        }, onCancel: { [weak self] in self?.cancelThumbnail(key: waiterKey, requestID: requestID) })
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
        return openedCameras[id] ?? openingCameras[id] ?? cameras[id]
    }

    private func markOpening(_ camera: ICCameraDevice, for id: String) {
        lock.lock(); openingCameras[id] = camera; lock.unlock()
    }

    private func removeOpening(_ camera: ICCameraDevice, for id: String) {
        lock.lock(); defer { lock.unlock() }
        if openingCameras[id] === camera { openingCameras.removeValue(forKey: id) }
    }

    private func markOpened(_ camera: ICCameraDevice, for id: String) {
        lock.lock(); defer { lock.unlock() }
        if openingCameras[id] === camera { openingCameras.removeValue(forKey: id) }
        openedCameras[id] = camera
    }

    private func removeSession(_ camera: ICCameraDevice, for id: String) {
        lock.lock(); defer { lock.unlock() }
        if openedCameras[id] === camera { openedCameras.removeValue(forKey: id) }
        if openingCameras[id] === camera { openingCameras.removeValue(forKey: id) }
    }

    private func isKnownCamera(_ camera: ICCameraDevice) -> Bool {
        let id = stableID(for: camera)
        lock.lock(); defer { lock.unlock() }
        return cameras[id] === camera
    }

    private func finishThumbnailWaiters(for deviceID: String? = nil, with error: Error) {
        thumbnailLock.lock()
        let keys: [String]
        if let deviceID {
            let prefix = deviceID + "\u{0}"
            keys = thumbnailWaiters.keys.filter { $0.hasPrefix(prefix) }
        } else {
            keys = Array(thumbnailWaiters.keys)
        }
        var pending: [CheckedContinuation<Data, Error>] = []
        for key in keys {
            if let values = thumbnailWaiters.removeValue(forKey: key) {
                pending.append(contentsOf: values.values)
            }
        }
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
        let id = stableID(for: camera)
        return USBDeviceDescriptor(id: id, name: camera.name ?? "", productKind: camera.productKind, transportType: camera.transportType)
    }

    /// UUID is preferred because it survives an unplug/replug.  A few camera
    /// drivers omit it, so retain a process-stable object identity instead of
    /// generating a fresh random UUID on every callback (which would make
    /// didRemove unable to invalidate the selected device).
    private func stableID(for camera: ICCameraDevice) -> String {
        let objectID = ObjectIdentifier(camera)
        lock.lock()
        let existing = cameraIDsByObject[objectID]
        let id = camera.uuidString.flatMap { $0.isEmpty ? nil : $0 }
            ?? camera.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? existing
            ?? "usb-\(String(UInt(bitPattern: Unmanaged.passUnretained(camera).toOpaque()), radix: 16))"
        cameraIDsByObject[objectID] = id
        lock.unlock()
        return id
    }

    private func deviceID(for device: ICDevice) -> String {
        if let camera = device as? ICCameraDevice { return stableID(for: camera) }
        if let uuid = device.uuidString, !uuid.isEmpty { return uuid }
        if let name = device.name, !name.isEmpty { return name }
        return "usb-device"
    }
}

extension ImageCaptureUSBTransport: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let descriptor = descriptor(for: camera)
        var replaced: ICCameraDevice?
        lock.lock()
        replaced = cameras[descriptor.id]
        cameras[descriptor.id] = camera
        lock.unlock()
        camera.delegate = self
        if let replaced, replaced !== camera {
            // A replug can arrive as add-before-remove with the same UUID.
            // Invalidate the old session before exposing the replacement.
            replaced.requestCloseSession(options: nil) { [weak self] _ in
                self?.removeSession(replaced, for: descriptor.id)
            }
            finishThumbnailWaiters(for: descriptor.id, with: CameraTransportError.disconnected)
            emit(.deviceRemoved(id: descriptor.id))
        }
        emit(.deviceAdded(descriptor))
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let id = stableID(for: camera)
        lock.lock()
        cameras.removeValue(forKey: id)
        cameraIDsByObject.removeValue(forKey: ObjectIdentifier(camera))
        lock.unlock()
        finishThumbnailWaiters(for: id, with: CameraTransportError.disconnected)
        emit(.deviceRemoved(id: id))
    }
}

extension ImageCaptureUSBTransport: ICDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func didRemove(_ device: ICDevice) {}
    func deviceDidBecomeReady(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice, isKnownCamera(camera) else { return }
        emit(.ready(id: stableID(for: camera)))
    }
    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus : Any]) {}
    func device(_ device: ICDevice, didEncounterError error: Error?) {
        emit(.failed(id: deviceID(for: device), message: error?.localizedDescription ?? ""))
    }
    func device(_ device: ICDevice, didEjectWithError error: Error?) {}
}

extension ImageCaptureUSBTransport: ICCameraDeviceDelegate {
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        let handle = item.ptpObjectHandle
        let deviceID = stableID(for: camera)
        let waiterKey = "\(deviceID)\u{0}\(handle)"
        thumbnailLock.lock()
        let continuations: [CheckedContinuation<Data, Error>]
        if let values = thumbnailWaiters.removeValue(forKey: waiterKey)?.values { continuations = Array(values) } else { continuations = [] }
        thumbnailLock.unlock()
        if let error {
            continuations.forEach { $0.resume(throwing: Self.map(error)) }
        } else if let thumbnail, let data = Self.pngData(thumbnail) {
            Task { await thumbnailCache.insert(data, for: "\(deviceID)\u{0}\(handle)") }
            continuations.forEach { $0.resume(returning: data) }
        } else {
            continuations.forEach { $0.resume(throwing: CameraTransportError.protocolError("Camera returned no thumbnail")) }
        }
    }

    private func cancelThumbnail(key: String, requestID: UUID) {
        thumbnailLock.lock()
        let continuation = thumbnailWaiters[key]?.removeValue(forKey: requestID)
        if thumbnailWaiters[key]?.isEmpty == true { thumbnailWaiters.removeValue(forKey: key) }
        thumbnailLock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable : Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard isKnownCamera(device) else { return }
        emit(.ready(id: stableID(for: device)))
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
