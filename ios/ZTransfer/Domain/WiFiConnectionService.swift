import Foundation

/// One owner for accepted Wi-Fi sessions. Discovery attempts own their sockets
/// until accepted, so cancellation cannot close a later replacement session.
actor WiFiConnectionService {
    let profiles = STAProfileStore()
    private var closeConnection: (@Sendable () async -> Void)?
    private var closeSocket: (@Sendable () -> Void)?
    private var repository: CameraRepository?
    private var catalogTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var generation = 0

    deinit { keepaliveTask?.cancel(); catalogTask?.cancel(); closeSocket?() }

    func connectAP(host: String) async throws -> CameraRepository {
        generation &+= 1
        let request = generation
        let socket = try await PTPIPSocketTransport.open(host: host)
        let session = PTPSession(transport: socket, defaultTimeoutNanoseconds: 60_000_000_000)
        var opened = false
        do {
            // NikonCamera.connect switches its sockets to the shared 60 s
            // response timeout. A 15 s default can retire a healthy AP
            // session during a slow metadata or live-view command.
            let result = try await session.executeResponse(operation: PTPConstants.openSession, parameters: [socket.connectionNumber])
            guard result.code == PTPConstants.responseOK || result.code == PTPConstants.sessionAlreadyOpen else {
                throw PTPSessionError.responseCode(result.code)
            }
            opened = true
            let repo = CameraRepository(session: session,
                                        transportCameraIdentifier: socket.responderGUID)
            _ = try? await repo.loadDeviceInfo()
            // A complete negative DeviceInfo response is optional on Android.
            // A timed-out or malformed transaction poisons iOS's command
            // stream, so it cannot be published as a successful connection.
            guard !(await session.isInvalidated) else { throw PTPSessionError.invalidated }
            try Task.checkCancellation()
            guard request == generation else { throw CancellationError() }
            socket.startEvents()
            closeConnection = { await PTPIPSocketTransport.retireOpenedSession(session, socket: socket, opened: true) }
            closeSocket = { socket.close() }
            repository = repo
            return repo
        } catch {
            await PTPIPSocketTransport.retireOpenedSession(session, socket: socket, opened: opened)
            throw error
        }
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
        guard !Task.isCancelled, generation == request else { await camera.close(); throw CancellationError() }
        let repo = CameraRepository(session: camera.session, staAlbum: camera.album,
                                    transportCameraIdentifier: camera.guid)
        camera.startEvents { await repo.receiveEvent($0) }
        closeConnection = camera.close
        closeSocket = { Task { await camera.close() } }
        repository = repo
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
        let close = closeConnection
        closeConnection = nil
        closeSocket = nil
        let previous = repository
        repository = nil
        await previous?.stopMonitoring()
        await close?()
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
