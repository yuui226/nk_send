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
    private var repository: CameraRepository?
    private var connectTask: Task<CameraRepository, Error>?
    private var connectToken: UUID?

    init(transport: ImageCaptureUSBTransport) { self.transport = transport }

    func connect(deviceID: String) async throws -> CameraRepository {
        if let activeDeviceID {
            guard activeDeviceID == deviceID, let repository else {
                throw CameraConnectionServiceError.noDevice
            }
            return repository
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
        do {
            let transport = self.transport
            try await AsyncDeadline.run(
                nanoseconds: 5_000_000_000,
                timeoutError: CameraConnectionServiceError.timeout
            ) {
                try await transport.openSession(for: deviceID)
            }
            try Task.checkCancellation()
            let session = PTPSession(transport: SelectedUSBPTPTransport(transport: transport, deviceID: deviceID))
            let repository = CameraRepository(session: session)
            _ = try await repository.loadDeviceInfo()
            try Task.checkCancellation()
            activeDeviceID = deviceID
            self.repository = repository
            return repository
        } catch {
            await closeWithDeadline(deviceID: deviceID)
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
        await closeWithDeadline(deviceID: id)
        activeDeviceID = nil
        repository = nil
    }

    private func closeWithDeadline(deviceID: String) async {
        let transport = self.transport
        // Cancellation of the connect owner must not cancel cleanup. Android
        // closes NikonCamera in NonCancellable; a detached cleanup task gives
        // ImageCaptureCore the same guarantee on iOS.
        let cleanup = Task.detached { () -> Void in
            _ = try? await AsyncDeadline.run(
                nanoseconds: 2_000_000_000,
                timeoutError: CameraConnectionServiceError.timeout
            ) {
                await transport.closeSession(for: deviceID)
            }
        }
        await cleanup.value
    }
}
