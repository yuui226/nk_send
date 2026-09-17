import Foundation

enum CameraConnectionServiceError: Error, Equatable, Sendable {
    case noDevice
}

/// Owns one selected USB camera from discovery through the first catalog request.
/// Keeping this lifecycle outside the view model prevents UI state from accidentally
/// issuing a second session. The app has no proactive wired-disconnect action;
/// accepted ImageCaptureCore sessions end only when the device/framework does.
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
            let repositoryToken = repository.usbSessionIdentity?.snapshot() ?? activeSessionToken
            if let repositoryToken,
               transport.openedSessionToken(for: deviceID) == repositoryToken {
                return repository
            }
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
        let transport = self.transport
        // ImageCaptureCore, unlike Android raw USB, completes OpenSession
        // before a separate device-ready callback. The transport waits for
        // that callback and reports its own communication timeout/error;
        // imposing Android's 5 s wire deadline would reject valid catalog
        // preparation on cameras containing many objects.
        try await transport.openSession(for: deviceID)
        try Task.checkCancellation()
        guard let sessionToken = transport.openedSessionToken(for: deviceID) else {
            throw CameraTransportError.disconnected
        }
        // ImageCaptureCore owns PTP communication timeouts. The session's
        // nominal timeout remains relevant to raw socket transports but is
        // intentionally not imposed on suspended framework requests.
        let session = PTPSession(transport: SelectedUSBPTPTransport(transport: transport, deviceID: deviceID,
                                                                   sessionToken: sessionToken),
                                 defaultTimeoutNanoseconds: 60_000_000_000)
        let info = try await session.executeResponse(operation: PTPConstants.getDeviceInfo)
        guard info.code == PTPConstants.responseOK else {
            throw PTPSessionError.responseCode(info.code)
        }
        // Android accepts an OK response with missing/unparseable info;
        // model metadata is optional, while the PTP handshake is valid.
        let identity = USBSessionIdentity(token: sessionToken)
        let repository = CameraRepository(session: session, isUSBConnection: true,
                                           deviceInfo: PTPDatasetParser.parseDeviceInfo(info.data),
                                           usbSessionIdentity: identity)
        try Task.checkCancellation()
        activeDeviceID = deviceID
        activeSessionToken = sessionToken
        self.repository = repository
        return repository
    }

    /// Forgets app-side ownership after physical loss or an abandoned handshake.
    /// It deliberately does not call any ImageCaptureCore session-close API.
    func reset() async {
        if let task = connectTask {
            task.cancel()
            _ = try? await task.value
            connectTask = nil
            connectToken = nil
        }
        activeDeviceID = nil
        activeSessionToken = nil
        repository = nil
    }
}
