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
    case sessionOpened(id: String, token: UUID)
    case sessionClosed(id: String, token: UUID)
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
    private var openedSessionTokens: [String: UUID] = [:]
    /// Keep a reference while requestOpenSession is in flight. A cancelled UI
    /// owner does not actively close the camera; a late success remains the
    /// reusable app-wide wired session.
    private var openingCameras: [String: ICCameraDevice] = [:]
    private var openingGenerations: [String: UInt64] = [:]
    private var replacementTokens: [String: UUID] = [:]
    /// requestOpenSession completion precedes ImageCaptureCore's readiness
    /// callback. A pass-through command is legal only after the latter.
    private var readyCameraObjects: Set<ObjectIdentifier> = []
    private var readinessWaiters: [ObjectIdentifier: [UUID: ThrowingContinuationBox<Void>]] = [:]
    private var operationsSuspended = false
    private var resumeWaiters: [UUID: ThrowingContinuationBox<Void>] = [:]
    private var continuation: AsyncStream<USBTransportEvent>.Continuation?
    private var stream: AsyncStream<USBTransportEvent>?
    private var thumbnailWaiters: [String: [UUID: CheckedContinuation<Data, Error>]] = [:]
    private let thumbnailLock = NSLock()
    private let thumbnailCache = ThumbnailCache()
    private let lock = NSLock()
    /// Guards late ImageCaptureCore callbacks after stop/restart.  A stopped
    /// browser must never repopulate openedCameras for the next attach.
    private var lifecycleGeneration: UInt64 = 0
    private var authorizationRequestGeneration: UInt64?
    private var stopped = true

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        )!
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
        lock.lock()
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        stopped = false
        operationsSuspended = browser.isSuspended
        lock.unlock()
        // ImageCaptureCore splits external-camera access into two permissions:
        // contents covers catalog/file access, while control covers opening a
        // controllable camera and sending pass-through PTP commands. ZTransfer
        // needs both, so never expose a partially-authorized state as usable.
        browser.start()
        refreshAuthorization(generation: generation)
    }

    /// Re-evaluates app-scoped camera permissions after returning from Settings
    /// and requests whichever half of the grant is still undetermined.
    func refreshAuthorization() {
        refreshAuthorization(generation: currentGeneration())
    }

    /// The browser keeps its device objects while local-workspace discovery is
    /// paused. Android rescans attached USB devices on resume; replay this
    /// authoritative snapshot because callbacks emitted during pause are ignored.
    func attachedDevices() -> [USBDeviceDescriptor] {
        lock.lock()
        let snapshot = cameras.filter { replacementTokens[$0.key] == nil }
        lock.unlock()
        return snapshot.map { id, camera in
            USBDeviceDescriptor(id: id, name: camera.name ?? "",
                                productKind: camera.productKind,
                                transportType: camera.transportType)
        }
    }

    func currentAuthorization() -> USBAuthorizationState {
        Self.combinedAuthorization(
            contents: browser.contentsAuthorizationStatus,
            control: browser.controlAuthorizationStatus
        )
    }

    private func refreshAuthorization(generation: UInt64) {
        guard isCurrentGeneration(generation) else { return }
        emit(.authorization(currentAuthorization()))
        requestAuthorizationIfNeeded(generation: generation)
    }

    func stop() {
        lock.lock()
        stopped = true
        lifecycleGeneration &+= 1
        lock.unlock()
        browser.stop()
        // Browser teardown only releases app-side discovery state. ZTransfer
        // has no proactive disconnect action and never asks the camera to close
        // an accepted ImageCaptureCore session.
        lock.lock()
        cameras.removeAll()
        cameraIDsByObject.removeAll()
        openedCameras.removeAll()
        openedSessionTokens.removeAll()
        openingCameras.removeAll()
        openingGenerations.removeAll()
        replacementTokens.removeAll()
        readyCameraObjects.removeAll()
        let readiness = readinessWaiters.values.flatMap(\.values)
        readinessWaiters.removeAll()
        let resume = Array(resumeWaiters.values)
        resumeWaiters.removeAll()
        operationsSuspended = false
        authorizationRequestGeneration = nil
        lock.unlock()
        readiness.forEach { _ = $0.finish(.failure(CameraTransportError.disconnected)) }
        resume.forEach { _ = $0.finish(.failure(CameraTransportError.disconnected)) }
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
        try await waitUntilOperationsResume()
        guard currentAuthorization() == .authorized else {
            throw CameraTransportError.permissionDenied
        }
        guard let camera = camera(for: id) else { throw CameraTransportError.disconnected }
        let generation = currentGeneration()
        if openedCamera(for: id) === camera {
            try await waitUntilReady(camera, for: id, generation: generation)
            return
        }
        markOpening(camera, for: id, generation: generation)
        let box = ThrowingContinuationBox<Void>()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.install(continuation)
            camera.requestOpenSession(options: nil) { [weak self] error in
                guard let self, self.isCurrentGeneration(generation) else {
                    _ = box.finish(.failure(CameraTransportError.disconnected))
                    return
                }
                if let error {
                    let mapped = Self.map(error)
                    self.removeOpening(camera, for: id)
                    if self.isKnownCamera(camera) {
                        // The connection view maps the typed error to the
                        // Android resource key; this event remains only a
                        // lifecycle notification for an already-open UI.
                        self.emit(.failed(id: id, message: error.localizedDescription))
                    }
                    _ = box.finish(.failure(mapped))
                } else {
                    if self.markOpened(camera, for: id, generation: generation) {
                        if box.finish(.success(())) {
                            if let token = self.ownedSessionToken(for: id, camera: camera) {
                                self.emit(.sessionOpened(id: id, token: token))
                            }
                        }
                    } else {
                        _ = box.finish(.failure(CameraTransportError.disconnected))
                        self.removeOpening(camera, for: id)
                    }
                }
            }
        }
        // Apple completes OpenSession before it declares the device ready to
        // receive requests. Waiting here prevents GetDeviceInfo from racing
        // ImageCaptureCore's own post-open preparation/content enumeration.
        try await waitUntilReady(camera, for: id, generation: generation)
    }

    func sendPTP(command: Data, data: Data? = nil, to id: String,
                 expectedSessionToken: UUID) async throws -> (response: Data, payload: Data) {
        try await waitUntilOperationsResume()
        guard currentAuthorization() == .authorized else {
            throw CameraTransportError.permissionDenied
        }
        guard let camera = openedCamera(for: id, token: expectedSessionToken) else {
            throw CameraTransportError.disconnected
        }
        guard camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) else {
            throw CameraTransportError.unavailable
        }
        let box = ThrowingContinuationBox<(Data, Data)>()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Data), Error>) in
            box.install(continuation)
            // Apple's delegate form defines this callback order as
            // inData first, then the PTP response container. The block
            // overload preserves that order even though both are `Data`.
            // Returning them reversed makes GetDeviceInfo decode camera
            // metadata as if it were a PTP response header.
            camera.requestSendPTPCommand(command, outData: data) { payload, response, error in
                if let error { _ = box.finish(.failure(Self.map(error))) }
                else { _ = box.finish(.success(Self.ptpResult(inData: payload, response: response))) }
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

    /// Returns true only while the opened ImageCaptureCore session belongs to
    /// the camera object currently published by discovery.  UUIDs can survive
    /// an unplug/replug, so comparing the identifier alone would let a stale
    /// repository leak into the replacement camera's connection attempt.
    func hasCurrentOpenedSession(for id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let camera = cameras[id], let opened = openedCameras[id] else { return false }
        return camera === opened
    }

    func openedSessionToken(for id: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard let camera = cameras[id], openedCameras[id] === camera else { return nil }
        return openedSessionTokens[id]
    }

    private func openedCamera(for id: String, token: UUID) -> ICCameraDevice? {
        lock.lock(); defer { lock.unlock() }
        guard openedSessionTokens[id] == token,
              let camera = cameras[id], openedCameras[id] === camera else { return nil }
        return camera
    }

    private func ownedSessionToken(for id: String, camera: ICCameraDevice) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard openedCameras[id] === camera else { return nil }
        return openedSessionTokens[id]
    }

    private func markOpening(_ camera: ICCameraDevice, for id: String, generation: UInt64) {
        lock.lock()
        readyCameraObjects.remove(ObjectIdentifier(camera))
        openingCameras[id] = camera
        openingGenerations[id] = generation
        lock.unlock()
    }

    private func removeOpening(_ camera: ICCameraDevice, for id: String) {
        lock.lock(); defer { lock.unlock() }
        if openingCameras[id] === camera {
            openingCameras.removeValue(forKey: id)
            openingGenerations.removeValue(forKey: id)
        }
    }

    @discardableResult
    private func markOpened(_ camera: ICCameraDevice, for id: String, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, lifecycleGeneration == generation,
              cameras[id] === camera,
              openingCameras[id] === camera,
              openingGenerations[id] == generation else {
            if openingCameras[id] === camera { openingCameras.removeValue(forKey: id) }
            if openingGenerations[id] == generation { openingGenerations.removeValue(forKey: id) }
            return false
        }
        if openingCameras[id] === camera { openingCameras.removeValue(forKey: id) }
        openingGenerations.removeValue(forKey: id)
        openedCameras[id] = camera
        openedSessionTokens[id] = UUID()
        return true
    }

    @discardableResult
    private func removeSession(_ camera: ICCameraDevice, for id: String) -> Bool {
        let objectID = ObjectIdentifier(camera)
        lock.lock()
        let wasOpened = openedCameras[id] === camera
        if openedCameras[id] === camera {
            openedCameras.removeValue(forKey: id)
            openedSessionTokens.removeValue(forKey: id)
        }
        if openingCameras[id] === camera {
            openingCameras.removeValue(forKey: id)
            openingGenerations.removeValue(forKey: id)
        }
        readyCameraObjects.remove(objectID)
        let waiters = readinessWaiters.removeValue(forKey: objectID).map { Array($0.values) } ?? []
        lock.unlock()
        waiters.forEach { _ = $0.finish(.failure(CameraTransportError.disconnected)) }
        return wasOpened
    }

    private func currentGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return lifecycleGeneration
    }

    private func cameraIDIfKnown(for camera: ICCameraDevice) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cameraIDsByObject[ObjectIdentifier(camera)]
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && lifecycleGeneration == generation
    }

    private func publishReplacement(
        _ camera: ICCameraDevice,
        id: String,
        descriptor: USBDeviceDescriptor,
        token: UUID,
    ) {
        lock.lock()
        let shouldPublish = replacementTokens[id] == token && cameras[id] === camera && !stopped
        if shouldPublish { replacementTokens.removeValue(forKey: id) }
        lock.unlock()
        guard shouldPublish else { return }
        emit(.deviceAdded(descriptor))
    }

    private func isKnownCamera(_ camera: ICCameraDevice) -> Bool {
        let id = stableID(for: camera)
        lock.lock(); defer { lock.unlock() }
        return !stopped && cameras[id] === camera
    }

    private func waitUntilReady(_ camera: ICCameraDevice, for id: String,
                                generation: UInt64) async throws {
        let objectID = ObjectIdentifier(camera)
        let requestID = UUID()
        let box = ThrowingContinuationBox<Void>()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.install(continuation)
                lock.lock()
                let ready = !stopped && lifecycleGeneration == generation &&
                    cameras[id] === camera && openedCameras[id] === camera &&
                    readyCameraObjects.contains(objectID)
                if !ready { readinessWaiters[objectID, default: [:]][requestID] = box }
                lock.unlock()
                if ready { _ = box.finish(.success(())) }
            }
        }, onCancel: { [weak self] in
            self?.removeReadinessWaiter(objectID: objectID, requestID: requestID)
            box.cancel()
        })
    }

    private func markReady(_ camera: ICCameraDevice) -> Bool {
        let id = stableID(for: camera)
        let objectID = ObjectIdentifier(camera)
        lock.lock()
        guard !stopped, cameras[id] === camera,
              openedCameras[id] === camera || openingCameras[id] === camera else {
            lock.unlock()
            return false
        }
        readyCameraObjects.insert(objectID)
        let waiters = readinessWaiters.removeValue(forKey: objectID).map { Array($0.values) } ?? []
        lock.unlock()
        waiters.forEach { _ = $0.finish(.success(())) }
        return true
    }

    private func removeReadinessWaiter(objectID: ObjectIdentifier, requestID: UUID) {
        lock.lock()
        readinessWaiters[objectID]?.removeValue(forKey: requestID)
        if readinessWaiters[objectID]?.isEmpty == true { readinessWaiters.removeValue(forKey: objectID) }
        lock.unlock()
    }

    private func waitUntilOperationsResume() async throws {
        let requestID = UUID()
        let box = ThrowingContinuationBox<Void>()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.install(continuation)
                lock.lock()
                let stopped = self.stopped
                // Delegate transitions are authoritative after start. Reading
                // browser.isSuspended again here can observe its old value just
                // after didResume and strand a waiter with no later callback.
                let suspended = operationsSuspended
                if !stopped && suspended { resumeWaiters[requestID] = box }
                lock.unlock()
                if stopped { _ = box.finish(.failure(CameraTransportError.disconnected)) }
                else if !suspended { _ = box.finish(.success(())) }
            }
        }, onCancel: { [weak self] in
            self?.removeResumeWaiter(requestID)
            box.cancel()
        })
    }

    private func setOperationsSuspended(_ suspended: Bool) {
        lock.lock()
        operationsSuspended = suspended
        let waiters = suspended ? [] : Array(resumeWaiters.values)
        if !suspended { resumeWaiters.removeAll() }
        lock.unlock()
        waiters.forEach { _ = $0.finish(.success(())) }
    }

    private func removeResumeWaiter(_ requestID: UUID) {
        lock.lock()
        resumeWaiters.removeValue(forKey: requestID)
        lock.unlock()
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
        // ImageCaptureCore's C error constants are not imported by Swift on
        // every SDK; keep the values from ImageCaptureConstants.h here so the
        // Android error categories remain stable across SDK versions.
        let code = nsError.code
        switch nsError.code {
        case NSURLErrorTimedOut, -9923: // ICReturnCommunicationTimedOut
            return .timeout
        case NSUserCancelledError, -20098, // ICReturnThumbnailCanceled
             -9937, // ICReturnDownloadCanceled
             -21350, -21349, -21348, -21347, // driver/closed/ejected/already open
             -21345, -21344, // failed to open connection/device
             -21250, // failed to send PTP command
             -9900, -9901, -9902, -9914, // communication/not found/not open/already open
             -9921, -9927, -9928, // invalid/open/close session failures
             -9936, -9956, -9957, -9958: // pass-through/transfer/send/session failure
            return .disconnected
        case -21343, -21249: // not authorized to open/send PTP
            return .permissionDenied
        default:
            return .protocolError("ImageCaptureCore (\(code)): \(nsError.localizedDescription)")
        }
    }

    private static func ptpResult(inData: Data, response: Data) -> (response: Data, payload: Data) {
        (response, inData)
    }

    #if DEBUG
    static func mapForTesting(_ error: Error) -> CameraTransportError { map(error) }
    static func ptpResultForTesting(inData: Data, response: Data) -> (response: Data, payload: Data) {
        ptpResult(inData: inData, response: response)
    }
    #endif

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Requests the two ImageCaptureCore permissions in sequence. Presenting
    /// simultaneous system prompts is unreliable, and a denied contents grant
    /// already makes ZTransfer's browse/transfer workflow unusable.
    private func requestAuthorizationIfNeeded(generation: UInt64) {
        guard beginAuthorizationRequest(generation: generation) else { return }
        let contents = browser.contentsAuthorizationStatus
        if contents == .notDetermined {
            browser.requestContentsAuthorization { [weak self] status in
                guard let self, self.isCurrentGeneration(generation) else { return }
                let state = Self.combinedAuthorization(
                    contents: status,
                    control: self.browser.controlAuthorizationStatus
                )
                self.emit(.authorization(state))
                guard status == .authorized else {
                    self.endAuthorizationRequest(generation: generation)
                    return
                }
                self.requestControlAuthorizationIfNeeded(
                    generation: generation,
                    contentsStatus: status
                )
            }
            return
        }
        requestControlAuthorizationIfNeeded(generation: generation, contentsStatus: contents)
    }

    private func requestControlAuthorizationIfNeeded(
        generation: UInt64,
        contentsStatus: ICAuthorizationStatus
    ) {
        guard isCurrentGeneration(generation) else { return }
        let control = browser.controlAuthorizationStatus
        guard contentsStatus == .authorized else {
            emit(.authorization(Self.combinedAuthorization(contents: contentsStatus, control: control)))
            endAuthorizationRequest(generation: generation)
            return
        }
        if control == .notDetermined {
            browser.requestControlAuthorization { [weak self] status in
                guard let self, self.isCurrentGeneration(generation) else { return }
                self.endAuthorizationRequest(generation: generation)
                self.emit(.authorization(Self.combinedAuthorization(
                    contents: contentsStatus,
                    control: status
                )))
            }
        } else {
            endAuthorizationRequest(generation: generation)
            emit(.authorization(Self.combinedAuthorization(contents: contentsStatus, control: control)))
        }
    }

    private func beginAuthorizationRequest(generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, lifecycleGeneration == generation,
              authorizationRequestGeneration != generation else { return false }
        authorizationRequestGeneration = generation
        return true
    }

    private func endAuthorizationRequest(generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if authorizationRequestGeneration == generation {
            authorizationRequestGeneration = nil
        }
    }

    private static func combinedAuthorization(
        contents: ICAuthorizationStatus,
        control: ICAuthorizationStatus
    ) -> USBAuthorizationState {
        let states = [status(from: contents), status(from: control)]
        if states.contains(.denied) { return .denied }
        if states.contains(.restricted) { return .restricted }
        if states.allSatisfy({ $0 == .authorized }) { return .authorized }
        return .notDetermined
    }

    private static func status(from status: ICAuthorizationStatus) -> USBAuthorizationState {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }

    #if DEBUG
    static func combinedAuthorizationForTesting(
        contents: ICAuthorizationStatus,
        control: ICAuthorizationStatus
    ) -> USBAuthorizationState {
        combinedAuthorization(contents: contents, control: control)
    }
    #endif

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
    func deviceBrowserWillSuspendOperations(_ browser: ICDeviceBrowser) {
        setOperationsSuspended(true)
    }

    func deviceBrowserDidSuspendOperations(_ browser: ICDeviceBrowser) {
        setOperationsSuspended(true)
    }

    func deviceBrowserDidCancelSuspendOperations(_ browser: ICDeviceBrowser) {
        setOperationsSuspended(false)
    }

    func deviceBrowserDidResumeOperations(_ browser: ICDeviceBrowser) {
        setOperationsSuspended(false)
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let descriptor = descriptor(for: camera)
        var replaced: ICCameraDevice?
        lock.lock()
        replaced = cameras[descriptor.id]
        cameras[descriptor.id] = camera
        lock.unlock()
        camera.delegate = self
        // Some iOS releases leave authorization undetermined until an actual
        // camera is attached. Retry the missing grant at that boundary; the
        // in-flight guard prevents duplicate system prompts.
        if currentAuthorization() != .authorized {
            refreshAuthorization()
        }
        // A repeated browser callback for the same framework object is not
        // a cable reattach and must not clear the three-failure retry pause.
        if replaced === camera { return }
        if let replaced, replaced !== camera {
            // A replug can arrive as add-before-remove with the same UUID.
            // Publish removal first and discard only app-side ownership of the
            // physically replaced object. Never turn replacement discovery into
            // an active disconnect request.
            finishThumbnailWaiters(for: descriptor.id, with: CameraTransportError.disconnected)
            emit(.deviceRemoved(id: descriptor.id))
            let token = UUID()
            lock.lock()
            replacementTokens[descriptor.id] = token
            lock.unlock()
            removeSession(replaced, for: descriptor.id)
            publishReplacement(camera, id: descriptor.id, descriptor: descriptor, token: token)
            return
        }
        emit(.deviceAdded(descriptor))
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let id = stableID(for: camera)
        lock.lock()
        let isCurrent = cameras[id] === camera
        if isCurrent { cameras.removeValue(forKey: id) }
        cameraIDsByObject.removeValue(forKey: ObjectIdentifier(camera))
        readyCameraObjects.remove(ObjectIdentifier(camera))
        let readyWaiters = readinessWaiters.removeValue(forKey: ObjectIdentifier(camera))
            .map { Array($0.values) } ?? []
        if isCurrent { replacementTokens.removeValue(forKey: id) }
        lock.unlock()
        readyWaiters.forEach { _ = $0.finish(.failure(CameraTransportError.disconnected)) }
        guard isCurrent else { return }
        finishThumbnailWaiters(for: id, with: CameraTransportError.disconnected)
        emit(.deviceRemoved(id: id))
    }
}

extension ImageCaptureUSBTransport: ICDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard let camera = device as? ICCameraDevice,
              let id = cameraIDIfKnown(for: camera),
              let token = ownedSessionToken(for: id, camera: camera),
              removeSession(camera, for: id) else { return }
        emit(.sessionClosed(id: id, token: token))
    }
    func didRemove(_ device: ICDevice) {}
    func deviceDidBecomeReady(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice, markReady(camera) else { return }
        emit(.ready(id: stableID(for: camera)))
    }
    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus : Any]) {}
    func device(_ device: ICDevice, didEncounterError error: Error?) {
        if let camera = device as? ICCameraDevice, !isKnownCamera(camera) { return }
        emit(.failed(id: deviceID(for: device), message: error?.localizedDescription ?? ""))
    }
    func device(_ device: ICDevice, didEjectWithError error: Error?) {}
}

extension ImageCaptureUSBTransport: ICCameraDeviceDelegate {
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        guard isKnownCamera(camera) else { return }
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
        guard markReady(device) else { return }
        emit(.ready(id: stableID(for: device)))
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
