import Foundation

protocol WiFiConnectionServicing: Sendable {
    var profiles: STAProfileStore { get }
    func connectAP(host: String) async throws -> CameraRepository
    func connectSTA(discovery: PTPIPDiscoveryService,
                    onStage: @escaping @Sendable (STAConnectionStage) async -> Void) async throws -> CameraRepository
    func startKeepalive(for repository: CameraRepository, onLost: @escaping @Sendable () async -> Void) async
    func disconnect() async
}

/// One owner for accepted Wi-Fi sessions. Discovery attempts own their sockets
/// until accepted, so cancellation cannot close a later replacement session.
actor WiFiConnectionService: WiFiConnectionServicing {
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
        // NikonCamera.connect puts the command socket on the camera Wi-Fi
        // network, sets TCP_NODELAY and a 4 MiB receive buffer before connect,
        // then reads and writes that socket on one blocking loop. Binding the
        // 192.168.1.x address is the iOS equivalent of Android's Wi-Fi
        // socketFactory: an unbound socket can leave 192.168.1.1 on another
        // interface when the hotspot has no internet route.
        let localAddress = PTPIPDiscoveryService().cameraHotspotLocalAddress()
        let socket = try await PTPIPSocketTransport.open(
            host: host, localAddress: localAddress, backend: .bsdSocket)
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
            acceptConnection(repo) {
                await PTPIPSocketTransport.retireOpenedSession(session, socket: socket, opened: true)
            }
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
        let diagnostic = STAConnectionDiagnostics.begin()
        #if DEBUG
        var outcome = "cancelled"
        defer { STAConnectionDiagnostics.finish(diagnostic, outcome) }
        #endif
        STAConnectionDiagnostics.note(diagnostic, "discovery start")
        let coordinator = STAConnectionCoordinator(profiles: profiles, diagnosticSession: diagnostic, connect: { candidate, identity, expected, verify, allowInlineRecovery, stage in
            try await STAConnectionCoordinator.open(candidate: candidate, identity: identity,
                expectedGUID: expected, profiles: profiles, pairingConfirmation: verify,
                allowInlineRecovery: allowInlineRecovery, diagnosticSession: diagnostic, onStage: stage)
        }, onStage: onStage)
        let selection = STACandidateSelection(coordinator: coordinator, expectedGUID: profiles.mostRecentGUID)
        do {
            let camera = try await selection.connect { tryCandidate in
                try await discovery.discover(lastIP: profiles.lastUsedIP,
                    onProgress: { await onStage(.discovering($0)) }, tryCandidate: tryCandidate)
            }
            guard !Task.isCancelled, generation == request else { await camera.close(); throw CancellationError() }
            let repo = CameraRepository(session: camera.session, staAlbum: camera.album,
                                        transportCameraIdentifier: camera.guid)
            camera.startEvents { await repo.receiveEvent($0) }
            acceptConnection(repo, close: camera.close)
            #if DEBUG
            outcome = "connected"
            #endif
            STAConnectionDiagnostics.note(diagnostic, "album activation complete")
            return repo
        } catch {
            #if DEBUG
            if !(error is CancellationError) && !Task.isCancelled { outcome = "failed:\(error)" }
            #endif
            throw error
        }
    }

    /// Both transports publish ownership only after their handshake succeeds.
    /// Pre-publication cleanup stays with the attempt that opened the socket.
    func acceptConnection(_ repository: CameraRepository,
                          close: @escaping @Sendable () async -> Void) {
        let retire: @Sendable () async -> Void = { await repository.retireConnection(close) }
        closeConnection = retire
        closeSocket = { Task { await retire() } }
        self.repository = repository
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
            await WiFiKeepaliveLoop.run(probe: { await repository.keepalive() }, onLost: onLost)
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
