import Foundation

/// One owner for accepted Wi-Fi sessions. Discovery attempts own their sockets
/// until accepted, so cancellation cannot close a later replacement session.
actor WiFiConnectionService {
    let profiles = STAProfileStore()
    private var closeConnection: (@Sendable () -> Void)?
    private var repository: CameraRepository?
    private var catalogTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var generation = 0

    deinit { keepaliveTask?.cancel(); catalogTask?.cancel(); closeConnection?() }

    func connectAP(host: String) async throws -> CameraRepository {
        generation &+= 1
        let request = generation
        let socket = try await PTPIPSocketTransport.open(host: host)
        do {
            let session = PTPSession(transport: socket)
            let result = try await session.executeResponse(operation: PTPConstants.openSession, parameters: [socket.connectionNumber])
            guard result.code == PTPConstants.responseOK || result.code == PTPConstants.sessionAlreadyOpen else {
                throw PTPSessionError.responseCode(result.code)
            }
            let repo = CameraRepository(session: session)
            _ = try? await repo.loadDeviceInfo()
            try Task.checkCancellation()
            guard request == generation else { throw CancellationError() }
            socket.startEvents()
            closeConnection = { socket.close() }; repository = repo
            return repo
        } catch { socket.close(); throw error }
    }

    func connectSTA(discovery: PTPIPDiscoveryService,
                    onStage: @escaping @Sendable (STAConnectionStage) async -> Void) async throws -> CameraRepository {
        generation &+= 1
        let request = generation
        let profiles = self.profiles
        let coordinator = STAConnectionCoordinator(profiles: profiles, connect: { candidate, identity, expected, stage in
            try await STAConnectionCoordinator.open(candidate: candidate, identity: identity,
                expectedGUID: expected, profiles: profiles, onStage: stage)
        }, onStage: onStage)
        let selection = STACandidateSelection(coordinator: coordinator, expectedGUID: profiles.mostRecentGUID)
        let found = try await discovery.discover(lastIP: profiles.lastUsedIP,
            onProgress: { await onStage(.discovering($0)) },
            tryCandidate: { try await selection.tryCandidate($0) })
        // Android defers the first other body until all expected-body candidates fail.
        let camera: STAConnectedCamera
        if let found { camera = found }
        else if let deferred = try await selection.tryDeferred() { camera = deferred }
        else { throw await coordinator.lastFailure ?? STAConnectionFailure(cause: STAConnectionError.notFound, knownCamera: false) }
        guard !Task.isCancelled, generation == request else { camera.close(); throw CancellationError() }
        let repo = CameraRepository(session: camera.session, staAlbum: camera.album)
        camera.startEvents { await repo.receiveEvent($0) }
        closeConnection = camera.close; repository = repo
        return repo
    }

    func startKeepalive(for expectedRepository: CameraRepository, onLost: @escaping @Sendable () async -> Void) {
        guard let repository, repository === expectedRepository else { return }
        keepaliveTask?.cancel()
        catalogTask?.cancel()
        catalogTask = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                await repository.maintainCatalogIfIdle()
            }
        }
        keepaliveTask = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                if !(await repository.keepalive()) {
                    guard !Task.isCancelled else { return }
                    await onLost()
                    return
                }
            }
        }
    }

    func disconnect() async {
        generation &+= 1
        keepaliveTask?.cancel(); keepaliveTask = nil
        catalogTask?.cancel(); catalogTask = nil
        closeConnection?(); closeConnection = nil
        let previous = repository
        repository = nil
        await previous?.stopMonitoring()
    }
}

private actor STACandidateSelection {
    let coordinator: STAConnectionCoordinator
    let expectedGUID: String?
    private var deferred: PTPIPCandidate?
    init(coordinator: STAConnectionCoordinator, expectedGUID: String?) {
        self.coordinator = coordinator; self.expectedGUID = expectedGUID
    }
    func tryCandidate(_ candidate: PTPIPCandidate) async throws -> STAConnectedCamera? {
        switch try await coordinator.tryCandidate(candidate, expectedGUID: expectedGUID) {
        case .connected(let camera): return camera
        case .unexpectedCamera: if deferred == nil { deferred = candidate }; return nil
        case .rejected: return nil
        }
    }
    func tryDeferred() async throws -> STAConnectedCamera? {
        guard let deferred else { return nil }
        if case .connected(let camera) = try await coordinator.tryCandidate(deferred, expectedGUID: nil) { return camera }
        return nil
    }
}
