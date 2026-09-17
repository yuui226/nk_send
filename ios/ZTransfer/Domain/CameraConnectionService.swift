import Foundation

enum CameraConnectionServiceError: Error, Equatable, Sendable {
    case timeout
    case noDevice
}

/// Owns one selected USB camera from discovery through the first catalog request.
/// Keeping this lifecycle outside the view model prevents UI state from accidentally
/// issuing a second session or racing a disconnect.
actor CameraConnectionService {
    private let transport: ImageCaptureUSBTransport
    private var activeDeviceID: String?
    private var activeSessionToken: UUID?
    private var repository: CameraRepository?
    private var connectTask: Task<CameraRepository, Error>?
    private var connectToken: UUID?

    init(transport: ImageCaptureUSBTransport) { self.transport = transport }

    func connect(deviceID: String) async throws -> CameraRepository {
        if let activeDeviceID {
            guard activeDeviceID == deviceID, let repository else {
                throw CameraConnectionServiceError.noDevice
            }
            // A camera UUID may remain stable across a physical replug.  Do
            // not reuse the old repository unless ImageCaptureCore confirms
            // that its opened object is still the object currently published
            // by discovery.
            if let activeSessionToken,
               transport.openedSessionToken(for: deviceID) == activeSessionToken {
                return repository
            }
            await closeWithDeadline(deviceID: deviceID, sessionToken: activeSessionToken)
            self.activeDeviceID = nil
            self.activeSessionToken = nil
            self.repository = nil
        }
        if let connectTask {
            // There is one physical PTP channel. A second caller joins the same
            // handshake instead of opening a competing ImageCaptureCore session.
            return try await withTaskCancellationHandler {
                try await connectTask.value
            } onCancel: {
                connectTask.cancel()
            }
        }
        let token = UUID()
        let task = Task { [weak self] () throws -> CameraRepository in
            guard let self else { throw CameraConnectionServiceError.noDevice }
            return try await self.performConnect(deviceID: deviceID)
        }
        connectTask = task
        connectToken = token
        defer {
            if self.connectToken == token {
                self.connectTask = nil
                self.connectToken = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performConnect(deviceID: String) async throws -> CameraRepository {
        var openedToken: UUID?
        do {
            let transport = self.transport
            try await AsyncDeadline.run(
                nanoseconds: 5_000_000_000,
                timeoutError: CameraConnectionServiceError.timeout
            ) {
                try await transport.openSession(for: deviceID)
            }
            try Task.checkCancellation()
            guard let sessionToken = transport.openedSessionToken(for: deviceID) else {
                throw CameraTransportError.disconnected
            }
            openedToken = sessionToken
            // Android uses a 5 s USB handshake timeout, then restores the
            // normal 60 s command timeout after DeviceInfo. Keep the longer
            // timeout for photo/catalog/remote commands on this session.
            let session = PTPSession(transport: SelectedUSBPTPTransport(transport: transport, deviceID: deviceID,
                                                                       sessionToken: sessionToken),
                                     defaultTimeoutNanoseconds: 60_000_000_000)
            let info = try await session.executeResponse(operation: PTPConstants.getDeviceInfo,
                                                         timeoutNanoseconds: 5_000_000_000)
            guard info.code == PTPConstants.responseOK else {
                throw PTPSessionError.responseCode(info.code)
            }
            // Android accepts an OK response with missing/unparseable info;
            // model metadata is optional, while the PTP handshake is valid.
            let identity = USBSessionIdentity(token: sessionToken)
            let repository = CameraRepository(session: session, isUSBConnection: true,
                                               deviceInfo: PTPDatasetParser.parseDeviceInfo(info.data),
                                               usbTransport: transport, usbDeviceID: deviceID,
                                               usbSessionIdentity: identity)
            try Task.checkCancellation()
            activeDeviceID = deviceID
            activeSessionToken = sessionToken
            self.repository = repository
            return repository
        } catch {
            await closeWithDeadline(deviceID: deviceID, sessionToken: openedToken)
            throw error
        }
    }

    func disconnect() async {
        if let task = connectTask {
            task.cancel()
            _ = try? await task.value
            connectTask = nil
            connectToken = nil
        }
        guard let id = activeDeviceID else { return }
        await closeWithDeadline(deviceID: id, sessionToken: activeSessionToken)
        activeDeviceID = nil
        activeSessionToken = nil
        repository = nil
    }

    private func closeWithDeadline(deviceID: String, sessionToken: UUID? = nil) async {
        let transport = self.transport
        // Cancellation of the connect owner must not cancel cleanup. Android
        // closes NikonCamera in NonCancellable; a detached cleanup task gives
        // ImageCaptureCore the same guarantee on iOS.
        let cleanup = Task.detached { () -> Void in
            _ = try? await AsyncDeadline.run(
                nanoseconds: 2_000_000_000,
                timeoutError: CameraConnectionServiceError.timeout
            ) {
                await transport.closeSession(for: deviceID, expectedSessionToken: sessionToken)
            }
        }
        await cleanup.value
    }
}
