import Foundation
import Combine
import Network

@MainActor
final class ConnectionViewModel: ObservableObject {
    @Published private(set) var state = ConnectionState()
    private let usbTransport = ImageCaptureUSBTransport()
    private lazy var connectionService = CameraConnectionService(transport: usbTransport)
    private let wifiService = WiFiConnectionService()
    private let wifiDiscovery = PTPIPDiscoveryService()
    @Published private(set) var cameraRepository: CameraRepository?
    @Published private(set) var cameraSession: CameraSession?
    private var usbEventsTask: Task<Void, Never>?
    private var usbConnectTask: Task<Void, Never>?
    private var usbCleanupTask: Task<Void, Never>?
    private var usbKeepaliveTask: Task<Void, Never>?
    private var usbCatalogTask: Task<Void, Never>?
    private var wifiConnectTask: Task<Void, Never>?
    private var wifiRetryTask: Task<Void, Never>?
    private var wifiCleanupTask: Task<Void, Never>?
    private var wifiRetryAttempt = 0
    private var apFailedAttempts = 0
    private var connectionDiscoveryPaused = false
    private var staWorkspaceEstablished = false
    private var usbWorkspaceEstablished = false
    private var usbForegroundActive = true
    private var gpsConnectionPaused = UserDefaults(suiteName: GPSPreferences.suiteName)?
        .bool(forKey: GPSPreferences.enabled) ?? false
    private let wirelessPreferences = UserDefaults(suiteName: "sta_connection")!
    @Published private(set) var pairedCameraCount = 0
    @Published private(set) var pairedCameraModels: [String] = []
    private var wifiWatcherTask: Task<Void, Never>?
    private var wifiPathMonitor: NWPathMonitor?
    private let wifiMonitorQueue = DispatchQueue(label: "com.ztransfer.wifi.path")
    private var wifiPathAvailable = false
    private var wifiGeneration = 0
    /// Changes whenever discovery or the selected physical camera changes. A
    /// late ImageCaptureCore callback from an old camera must not publish into
    /// the replacement connection (the Android code checks deviceId for this).
    private var connectionGeneration = 0
    private var lastEstablishedUSBDeviceID: String?
    private let usbMaxAttempts = 3
    private let usbRetryDelayNanoseconds: UInt64 = 1_000_000_000

    init() {
        state.wirelessMode = wirelessPreferences.string(forKey: "wireless_mode") == "AP" ? .ap : .sta
        Task { [weak self] in await self?.refreshSTAProfiles() }
    }

    deinit {
        usbEventsTask?.cancel()
        usbConnectTask?.cancel()
        usbKeepaliveTask?.cancel()
        usbCatalogTask?.cancel()
        wifiConnectTask?.cancel()
        wifiWatcherTask?.cancel()
        wifiRetryTask?.cancel()
        wifiPathMonitor?.cancel()
        usbTransport.stop()
    }

    func startUSBDiscovery() {
        guard usbEventsTask == nil else { return }
        // Pair every start with a new generation so an earlier asynchronous
        // stop cannot tear down the listener that is being started now.
        connectionGeneration &+= 1
        let events = usbTransport.events()
        usbEventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
        usbTransport.start()
    }

    /// Camera authorization is app-scoped on iOS. Re-read it when the app
    /// becomes active so a grant changed in Settings takes effect without a
    /// force-quit or cable replug.
    func refreshUSBAuthorization() {
        guard usbEventsTask != nil else { return }
        apply(.authorization(usbTransport.currentAuthorization()))
        usbTransport.refreshAuthorization()
    }

    /// ImageCaptureCore suspends all device communication when iOS backgrounds
    /// the app. Keep the accepted session mounted, but stop periodic commands;
    /// they are restarted after the framework resumes in the foreground.
    func setUSBForegroundActive(_ active: Bool) {
        usbForegroundActive = active
        guard let session = cameraSession, session.isUSB,
              let deviceID = session.transportDeviceID else { return }
        // Do not cancel a loop merely because the scene backgrounds: it may be
        // awaiting an ImageCaptureCore command, which must drain its framework
        // callback because iOS has no per-command PTP Cancel API.
        guard active else { return }
        let generation = connectionGeneration
        if usbKeepaliveTask == nil {
            startUSBKeepalive(for: session, deviceID: deviceID, generation: generation)
        }
        if usbCatalogTask == nil {
            startUSBCatalogMonitoring(for: session, generation: generation)
        }
    }

    /// Starts the AP watcher used by Android: while the app is on Wi-Fi and AP
    /// mode is selected, periodically retry the fixed camera endpoint. NWPath
    /// only gates on Wi-Fi; the 192.168.1.x subnet check and PTP handshake keep
    /// ordinary Wi-Fi from being treated as a camera connection.
    func startWiFiDiscovery() {
        guard wifiPathMonitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        wifiPathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.updateWiFiPath(available)
            }
        }
        monitor.start(queue: wifiMonitorQueue)
    }

    func stopWiFiDiscovery() {
        wifiWatcherTask?.cancel()
        wifiWatcherTask = nil
        cancelWiFiConnection()
        wifiPathMonitor?.cancel()
        wifiPathMonitor = nil
        wifiPathAvailable = false
    }

    private func updateWiFiPath(_ available: Bool) {
        wifiPathAvailable = available
        guard available else {
            // Match Android's watcher: leaving the candidate network ends only
            // the in-flight discovery; an established session is left to its
            // transport/keepalive failure path instead of being force-closed.
            if cameraSession == nil && state.wirelessMode == .ap {
                apFailedAttempts = 0
                cancelWiFiConnection()
            }
            wifiWatcherTask?.cancel()
            wifiWatcherTask = nil
            return
        }
        startAPWatcherIfNeeded()
    }

    private func startAPWatcherIfNeeded() {
        guard !connectionDiscoveryPaused, !gpsConnectionPaused,
              !usbWorkspaceEstablished, state.selectedDeviceID == nil,
              wifiPathAvailable, state.wirelessMode == .ap, cameraSession == nil,
              wifiWatcherTask == nil else { return }
        wifiWatcherTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard !self.connectionDiscoveryPaused, !self.usbWorkspaceEstablished,
                      self.state.selectedDeviceID == nil,
                      self.wifiPathAvailable, self.state.wirelessMode == .ap,
                      !self.gpsConnectionPaused, self.cameraSession == nil else { break }
                // Android checks the DHCP gateway before starting a handshake.
                // iOS has no public gateway API; this subnet gate is the closest
                // available equivalent and the PTP handshake remains authoritative.
                if self.wifiDiscovery.isOnCameraHotspot() {
                    if self.wifiConnectTask == nil {
                        await self.connectSelectedWiFi(reconnect: self.state.wifiPhase == .reconnecting)
                    }
                } else if self.apFailedAttempts != 0 ||
                            self.wifiConnectTask != nil || self.state.wifiPhase != .idle {
                    // A Wi-Fi-to-Wi-Fi switch does not make NWPath unsatisfied.
                    // Android clears a vanished camera candidate on the next
                    // watcher pass instead of carrying its failed retry state
                    // into an ordinary network or the next hotspot visit.
                    self.apFailedAttempts = 0
                    self.cancelWiFiConnection()
                }
                let delay: UInt64 = {
                    if case .failed = self.state.wifiPhase,
                       self.apFailedAttempts > 1 { return 3_000_000_000 }
                    return 1_000_000_000
                }()
                do { try await Task.sleep(nanoseconds: delay) } catch { break }
            }
            if !Task.isCancelled { self.wifiWatcherTask = nil }
        }
    }

    var staBusy: Bool {
        state.wirelessMode == .sta && [.discovering, .pairing, .connecting].contains(state.wifiPhase)
    }

    func connectSelectedWiFi(reconnect: Bool = false) async {
        // Android's connection action is disabled by an active STA discovery;
        // a repeated tap is a no-op and never cancels the current scan.
        if staBusy { return }
        wifiRetryAttempt = 0
        wifiRetryTask?.cancel(); wifiRetryTask = nil
        await beginWiFiConnection(reconnect: reconnect)
    }

    #if DEBUG
    /// Starts the in-process catalog without requiring a camera or Wi-Fi.
    func connectDebugSimulator() {
        guard cameraSession == nil else { return }
        let repository = CameraRepository(debugData: .shared)
        cameraRepository = repository
        cameraSession = CameraSession(repository: repository, wirelessMode: .ap)
        state.wirelessMode = .ap
        state.wifiPhase = .connected
    }
    #endif

    func cancelWiFiConnection() {
        guard state.wifiPhase != .connected else { return }
        wifiGeneration &+= 1
        let cancelledConnection = wifiConnectTask
        cancelledConnection?.cancel(); wifiConnectTask = nil
        wifiRetryTask?.cancel(); wifiRetryTask = nil
        state.wifiPhase = .idle
        state.wifiFailureKind = nil
        state.staProgressIP = nil
        let service = wifiService
        let previousCleanup = wifiCleanupTask
        wifiCleanupTask = Task {
            await previousCleanup?.value
            await cancelledConnection?.value
            await service.disconnect()
        }
    }

    func resetSTAPairing() async {
        guard cameraSession == nil else { return }
        cancelWiFiConnection()
        wifiRetryAttempt = 0
        await wifiCleanupTask?.value
        let profiles = wifiService.profiles
        profiles.resetPairing()
        await refreshSTAProfiles()
    }

    func refreshSTAProfiles() async {
        let profiles = wifiService.profiles
        pairedCameraCount = profiles.pairedCameraCount
        pairedCameraModels = profiles.pairedCameraModels
    }

    private func beginWiFiConnection(reconnect: Bool) async {
        guard !connectionDiscoveryPaused, !usbWorkspaceEstablished,
              state.selectedDeviceID == nil,
              wifiConnectTask == nil, cameraSession == nil,
              state.usbPhase != .connecting else { return }
        let mode = state.wirelessMode
        guard mode != .ap || !gpsConnectionPaused else { return }
        wifiGeneration &+= 1
        let generation = wifiGeneration
        state.wifiPhase = mode == .sta ? .discovering : (reconnect ? .reconnecting : .connecting)
        state.wifiFailureKind = nil
        state.staProgressIP = nil
        let pendingCleanup = wifiCleanupTask
        wifiConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                await pendingCleanup?.value
                try Task.checkCancellation()
                guard self.wifiGeneration == generation,
                      mode != .ap || !self.gpsConnectionPaused else {
                    if self.wifiGeneration == generation { self.wifiConnectTask = nil }
                    return
                }
                let repository: CameraRepository
                if mode == .sta {
                    repository = try await self.wifiService.connectSTA(discovery: self.wifiDiscovery) { [weak self] stage in
                        await self?.publishSTAStage(stage, generation: generation)
                    }
                } else {
                    repository = try await self.wifiService.connectAP(host: "192.168.1.1")
                }
                try Task.checkCancellation()
                guard self.wifiGeneration == generation, self.state.wirelessMode == mode,
                      self.cameraSession == nil, self.state.usbPhase != .connecting,
                      mode != .ap || !self.gpsConnectionPaused else {
                    if self.wifiGeneration == generation { await self.wifiService.disconnect() }
                    return
                }
                self.cameraRepository = repository
                self.cameraSession = CameraSession(repository: repository, wirelessMode: mode)
                if mode == .sta { self.staWorkspaceEstablished = true }
                self.state.wifiPhase = .connected
                self.state.staProgressIP = nil
                self.wifiConnectTask = nil
                self.wifiWatcherTask?.cancel(); self.wifiWatcherTask = nil
                self.wifiRetryAttempt = 0
                if mode == .ap { self.apFailedAttempts = 0 }
                await self.refreshSTAProfiles()
                await self.wifiService.startKeepalive(for: repository) { [weak self] in
                    await self?.wifiTransportLost(generation: generation, mode: mode)
                }
            } catch {
                guard self.wifiGeneration == generation else { return }
                self.wifiConnectTask = nil
                if Task.isCancelled || error is CancellationError { self.state.wifiPhase = .idle; return }
                let preserveReconnect = mode == .ap && reconnect && self.state.wifiPhase == .reconnecting
                if mode == .ap { self.apFailedAttempts += 1 }
                if !preserveReconnect {
                    self.state.wifiPhase = .failed(self.wifiErrorMessage(error))
                    if mode == .ap {
                        self.state.wifiFailureKind = Self.wifiFailureKind(for: error)
                    }
                }
                self.state.staProgressIP = nil
                await self.refreshSTAProfiles()
                if mode == .sta {
                    let profiles = self.wifiService.profiles
                    if reconnect || profiles.hasReusableProfile {
                        self.scheduleSTARetry(generation: generation)
                    }
                }
            }
        }
        await wifiConnectTask?.value
    }

    private func publishSTAStage(_ stage: STAConnectionStage, generation: Int) {
        guard generation == wifiGeneration, state.wirelessMode == .sta,
              cameraSession == nil, !Task.isCancelled else { return }
        switch stage {
        case .discovering(let ip): state.wifiPhase = .discovering; state.staProgressIP = ip
        case .pairing: state.wifiPhase = .pairing
        case .connecting: state.wifiPhase = .connecting
        }
    }

    private func scheduleSTARetry(generation: Int) {
        let delay = STAConnectionCoordinator.reconnectDelay(attempt: wifiRetryAttempt)
        wifiRetryAttempt += 1
        wifiRetryTask?.cancel()
        wifiRetryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.wifiGeneration == generation, self.state.wirelessMode == .sta,
                  self.cameraSession == nil, !Task.isCancelled else { return }
            await self.beginWiFiConnection(reconnect: true)
        }
    }

    /// The disconnected STA signal pill requests an immediate retry. An
    /// already-running discovery keeps ownership of its sockets; the tap only
    /// replaces the scheduled backoff when no discovery is active.
    func retrySTAConnection() {
        guard !connectionDiscoveryPaused, staWorkspaceEstablished,
              !usbWorkspaceEstablished, state.selectedDeviceID == nil,
              cameraSession == nil, state.wirelessMode == .sta,
              state.usbPhase != .connecting else { return }
        guard wifiConnectTask == nil else { return }
        wifiRetryTask?.cancel()
        wifiRetryTask = nil
        wifiRetryAttempt = 0
        Task { [weak self] in await self?.beginWiFiConnection(reconnect: true) }
    }

    private func wifiTransportLost(generation: Int, mode: WirelessMode) async {
        guard wifiGeneration == generation, state.wifiPhase == .connected else { return }
        cameraSession = nil; cameraRepository = nil
        state.wifiPhase = .reconnecting
        state.wifiFailureKind = nil
        // Serialize socket teardown with an immediate signal-pill retry. The
        // new discovery waits for this cleanup rather than racing Close/stop
        // of the failed repository with its own accepted connection.
        let previousCleanup = wifiCleanupTask
        let service = wifiService
        wifiCleanupTask = Task {
            await previousCleanup?.value
            await service.disconnect()
        }
        await wifiCleanupTask?.value
        guard wifiGeneration == generation, cameraSession == nil else { return }
        if mode == .sta {
            if wifiConnectTask == nil { scheduleSTARetry(generation: generation) }
        } else { startAPWatcherIfNeeded() }
    }

    /// Remote operations share the same PTP channel as catalog and transfer
    /// work. If one of them proves that the channel is gone, use the normal
    /// transport recovery path immediately instead of letting the next screen
    /// operation discover a stale session and replaying the entry animation.
    func handleTransportLost(_ failedSession: CameraSession) async {
        guard cameraSession === failedSession else { return }
        if failedSession.isUSB {
            guard let deviceID = failedSession.transportDeviceID else { return }
            await usbTransportLost(failedSession, deviceID: deviceID, generation: connectionGeneration)
        } else {
            await wifiTransportLost(generation: wifiGeneration,
                                    mode: failedSession.wirelessMode ?? state.wirelessMode)
        }
    }

    private func wifiErrorMessage(_ error: Error) -> String {
        let failure = error as? STAConnectionFailure
        let cause = failure?.cause ?? error
        switch cause {
        case STAConnectionError.cameraRefused:
            return AppLocalized.resource(failure?.knownCamera == true ? "sta_camera_refused_retrying" : "sta_camera_refused_repair")
        case STAConnectionError.pairingRequired: return AppLocalized.resource("sta_camera_refused_repair")
        case STAConnectionError.noMedia: return AppLocalized.resource("sta_camera_no_media")
        case STAConnectionError.notFound: return AppLocalized.resource("sta_camera_not_found")
        case STAConnectionError.pairingCompleted: return "Nikon pairing completed; reconnect required"
        case STAConnectionError.albumUnavailable(let response):
            return String(format: "STA album access unavailable (0x%04X)", response)
        case STAConnectionError.initializationFailed(let response):
            return "Nikon STA initialization failed: 0x" + String(response, radix: 16)
        case STAConnectionError.pairingQueryFailed(let response):
            return "Nikon pairing query failed: 0x" + String(response, radix: 16)
        case STAConnectionError.pairingResultFailed(let response):
            return "Nikon pairing result failed: 0x" + String(response, radix: 16)
        default: return cause.localizedDescription
        }
    }

    /// Mirrors CameraViewModel.classifyWifiConnectionFailure exactly for AP:
    /// refusal is only the camera's explicit PTP/IP init-fail; socket reachability
    /// failures are presented as "camera not found"; all other protocol errors
    /// use the generic connection-failed copy.
    static func wifiFailureKind(for error: Error) -> WiFiFailureKind {
        let cause = (error as? STAConnectionFailure)?.cause ?? error
        switch cause {
        case STAConnectionError.cameraRefused:
            return .refused
        case PTPSessionError.timeout:
            return .notFound
        case NWError.posix(let code)
            where code == .ECONNREFUSED || code == .ENETUNREACH ||
                  code == .EHOSTUNREACH || code == .ETIMEDOUT:
            return .notFound
        case let url as URLError
            where url.code == .timedOut || url.code == .cannotConnectToHost ||
                  url.code == .networkConnectionLost:
            return .notFound
        default:
            return .failed
        }
    }

    func connectSelectedUSB() async {
        let generation = connectionGeneration
        guard let id = state.selectedDeviceID else { return }
        await usbCleanupTask?.value
        guard !connectionDiscoveryPaused, generation == connectionGeneration,
              state.selectedDeviceID == id else { return }
        await connectSelectedUSB(id: id, generation: generation, attempt: 1)
    }

    private func connectSelectedUSB(id: String, generation: Int, attempt: Int) async {
        guard generation == connectionGeneration,
              state.selectedDeviceID == id,
              state.discoveredDevices.contains(where: { $0.id == id }) else {
            usbConnectTask = nil
            return
        }
        guard cameraSession == nil else { usbConnectTask = nil; return }
        cancelWiFiConnection()
        await wifiCleanupTask?.value
        state.usbPhase = .connecting
        state.errorMessage = nil
        do {
            let repository = try await connectionService.connect(deviceID: id)
            guard generation == connectionGeneration,
                  state.selectedDeviceID == id,
                  state.discoveredDevices.contains(where: { $0.id == id }) else {
                await connectionService.reset()
                usbConnectTask = nil
                return
            }
            cameraRepository = repository
            if let cameraRepository, let sessionToken = usbTransport.openedSessionToken(for: id) {
                cameraSession = CameraSession(repository: cameraRepository, transport: usbTransport,
                                              deviceID: id, sessionToken: sessionToken)
                lastEstablishedUSBDeviceID = id
                usbWorkspaceEstablished = true
                if let cameraSession {
                    startUSBKeepalive(for: cameraSession, deviceID: id, generation: generation)
                    startUSBCatalogMonitoring(for: cameraSession, generation: generation)
                }
            }
            guard cameraSession != nil else {
                cameraRepository = nil
                await connectionService.reset()
                usbConnectTask = nil
                return
            }
            state.usbPhase = .connected
        } catch is CancellationError {
            // CameraConnectionService may have completed OpenSession just
            // before cancellation was observed. The open callback is drained
            // before app-side ownership is reset;
            // cancellation never asks ImageCaptureCore to close the camera.
            await connectionService.reset()
            usbConnectTask = nil
            return
        } catch {
            // The cable can disappear while open/session-info is in flight.
            // Keep the reducer's waiting state; Android never replaces it with
            // a stale error from the removed device.
            guard generation == connectionGeneration,
                  state.selectedDeviceID == id,
                  state.discoveredDevices.contains(where: { $0.id == id }) else {
                usbConnectTask = nil
                return
            }
            if attempt < usbMaxAttempts,
               state.discoveredDevices.contains(where: { $0.id == id }) {
                state.usbPhase = .connecting
                do { try await Task.sleep(nanoseconds: usbRetryDelayNanoseconds) }
                catch { usbConnectTask = nil; return }
                guard !Task.isCancelled, generation == connectionGeneration else { usbConnectTask = nil; return }
                await connectSelectedUSB(id: id, generation: generation, attempt: attempt + 1)
                return
            }
            let message = usbErrorMessage(error)
            state.usbPhase = .failed(message)
            state.errorMessage = message
        }
        usbConnectTask = nil
    }

    /// Android probes both active transport kinds every ten seconds. A probe
    /// skipped because a download owns the PTP channel counts as alive.
    private func startUSBKeepalive(for expectedSession: CameraSession, deviceID: String, generation: Int) {
        usbKeepaliveTask?.cancel()
        guard usbForegroundActive else { usbKeepaliveTask = nil; return }
        usbKeepaliveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard !Task.isCancelled, self.connectionGeneration == generation,
                      self.cameraSession === expectedSession else { return }
                guard self.usbForegroundActive else { continue }
                if !(await expectedSession.keepalive()) {
                    guard !Task.isCancelled else { return }
                    await self.usbTransportLost(expectedSession, deviceID: deviceID, generation: generation)
                    return
                }
            }
        }
    }

    private func startUSBCatalogMonitoring(for expectedSession: CameraSession, generation: Int) {
        usbCatalogTask?.cancel()
        guard usbForegroundActive else { usbCatalogTask = nil; return }
        usbCatalogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard !Task.isCancelled, self.connectionGeneration == generation,
                      self.cameraSession === expectedSession else { return }
                guard self.usbForegroundActive else { continue }
                await expectedSession.maintainCatalogIfIdle()
            }
        }
    }

    private func usbTransportLost(_ failedSession: CameraSession, deviceID: String, generation: Int) async {
        guard connectionGeneration == generation, cameraSession === failedSession else { return }
        connectionGeneration &+= 1
        let reconnectGeneration = connectionGeneration
        usbKeepaliveTask?.cancel()
        usbKeepaliveTask = nil
        usbCatalogTask?.cancel()
        usbCatalogTask = nil
        cameraSession = nil
        cameraRepository = nil
        state.usbPhase = .waitingForCamera
        // Reuse only the currently attached and authorized camera. A late
        // failure from a removed/replaced device cannot start another session.
        guard state.selectedDeviceID == deviceID,
              state.usbAuthorization == .authorized,
              state.discoveredDevices.contains(where: { $0.id == deviceID }) else {
            await connectionService.reset()
            return
        }
        state.usbPhase = .connecting
        usbConnectTask = Task { [weak self] in
            guard let self else { return }
            await self.connectionService.reset()
            guard self.connectionGeneration == reconnectGeneration, !Task.isCancelled else {
                self.usbConnectTask = nil
                return
            }
            await self.connectSelectedUSB(id: deviceID, generation: reconnectGeneration, attempt: 1)
        }
    }

    func selectDevice(id: String) {
        guard state.discoveredDevices.contains(where: { $0.id == id }) else { return }
        guard cameraSession == nil, state.usbPhase != .connecting else { return }
        guard state.selectedDeviceID != id else { return }
        connectionGeneration &+= 1
        usbConnectTask?.cancel()
        usbConnectTask = nil
        usbKeepaliveTask?.cancel()
        usbKeepaliveTask = nil
        usbCatalogTask?.cancel()
        usbCatalogTask = nil
        Task { [weak self] in await self?.connectionService.reset() }
        state.selectedDeviceID = id
        lastEstablishedUSBDeviceID = nil
        state.usbPhase = .waitingForCamera
    }

    func select(mode: CameraConnectionMode) {
        state.selectedMode = mode
    }

    func select(wirelessMode: WirelessMode) {
        guard state.wirelessMode != wirelessMode else { return }
        guard cameraSession == nil, !usbWorkspaceEstablished,
              state.selectedDeviceID == nil else { return }
        cancelWiFiConnection()
        state.wirelessMode = wirelessMode
        state.wifiFailureKind = nil
        wirelessPreferences.set(wirelessMode == .sta ? "STA" : "AP", forKey: "wireless_mode")
        if wirelessMode == .ap { startAPWatcherIfNeeded() } else {
            wifiWatcherTask?.cancel()
            wifiWatcherTask = nil
        }
    }

    /// Android pauses automatic connection discovery while the local workspace
    /// owns the page. An accepted camera session stays alive; only pending
    /// discovery, permission, and handshake work is canceled.
    func setConnectionDiscoveryPaused(_ paused: Bool) {
        guard connectionDiscoveryPaused != paused else { return }
        connectionDiscoveryPaused = paused
        if paused {
            wifiWatcherTask?.cancel(); wifiWatcherTask = nil
            cancelWiFiConnection()
            if cameraSession == nil {
                let cancelledUSB = usbConnectTask
                cancelledUSB?.cancel(); usbConnectTask = nil
                let previousCleanup = usbCleanupTask
                let service = connectionService
                usbCleanupTask = Task {
                    await previousCleanup?.value
                    await cancelledUSB?.value
                    await service.reset()
                }
                // Pausing an in-flight open does not consume a retry; a
                // three-attempt failure stays paused until a real reattach.
                if state.usbPhase == .connecting { state.usbPhase = .waitingForCamera }
            }
            return
        }
        guard cameraSession == nil else { return }
        apply(.authorization(usbTransport.currentAuthorization()))
        usbTransport.refreshAuthorization()
        for device in usbTransport.attachedDevices() {
            if !state.discoveredDevices.contains(where: { $0.id == device.id }) {
                apply(.deviceAdded(device))
            }
        }
        if state.selectedDeviceID == nil, !usbWorkspaceEstablished {
            if state.wirelessMode == .ap { startAPWatcherIfNeeded() }
            else if state.wirelessMode == .sta && staWorkspaceEstablished {
                Task { [weak self] in await self?.beginWiFiConnection(reconnect: true) }
            }
        }
    }

    /// Android pauses AP auto-discovery while Nikon BLE/GPS owns the phone's
    /// radio. An already accepted camera is left to its transport lifecycle.
    func setGPSConnectionPaused(_ paused: Bool) {
        guard gpsConnectionPaused != paused else { return }
        gpsConnectionPaused = paused
        guard state.wirelessMode == .ap else { return }
        if paused {
            wifiWatcherTask?.cancel()
            wifiWatcherTask = nil
            if cameraSession == nil {
                cancelWiFiConnection()
            }
        } else if cameraSession == nil { startAPWatcherIfNeeded() }
    }

    private func apply(_ event: USBTransportEvent) {
        // Android ignores USB attach/detach while an accepted Wi-Fi session
        // owns the workspace. ImageCaptureCore can still enumerate devices,
        // but those callbacks must not select USB or start a second session.
        if let cameraSession, !cameraSession.isUSB {
            switch event {
            case .deviceAdded, .deviceRemoved, .ready, .sessionOpened, .sessionClosed, .failed:
                return
            case .authorization:
                break
            }
        }
        if connectionDiscoveryPaused {
            switch event {
            case .authorization, .deviceAdded, .ready, .sessionOpened:
                return
            case .deviceRemoved:
                break
            case .sessionClosed, .failed:
                if cameraSession == nil { return }
                break
            }
        }
        switch event {
        case .sessionOpened where cameraSession?.isUSB == true:
            // An event queued just before DeviceInfo completed cannot move an
            // already accepted session back to the connecting card.
            return
        case let .sessionClosed(id, token):
            if let cameraSession, cameraSession.usbSessionToken != token { return }
            if let current = usbTransport.openedSessionToken(for: id), current != token { return }
        default:
            break
        }
        let previous = state
        state = state.applying(event)
        switch event {
        case let .authorization(status):
            guard status == .authorized,
                  state.usbAuthorization == .authorized,
                  state.usbPhase == .waitingForCamera,
                  state.selectedDeviceID != nil,
                  usbConnectTask == nil else { break }
            usbConnectTask = Task { [weak self] in await self?.connectSelectedUSB() }
        case .deviceAdded:
            // Android suspends AP watching and any STA scan as soon as a PTP
            // USB device is recognized, including its permission wait.
            if cameraSession == nil {
                wifiWatcherTask?.cancel(); wifiWatcherTask = nil
                cancelWiFiConnection()
            }
            if state.usbAuthorization == .authorized,
               state.usbPhase == .waitingForCamera,
               (previous.usbPhase == .waitingForCamera ||
                previous.usbPhase == .failed(AppLocalized.resource("usb_permission_required")) ||
                previous.selectedDeviceID != state.selectedDeviceID),
               usbConnectTask == nil {
                state.usbPhase = .connecting
                usbConnectTask = Task { [weak self] in await self?.connectSelectedUSB() }
            }
        case let .deviceRemoved(id):
            if previous.selectedDeviceID == id {
                let wasEstablished = lastEstablishedUSBDeviceID == id
                lastEstablishedUSBDeviceID = nil
                connectionGeneration &+= 1
                usbKeepaliveTask?.cancel(); usbKeepaliveTask = nil
                usbCatalogTask?.cancel(); usbCatalogTask = nil
                usbConnectTask?.cancel(); usbConnectTask = nil
                // A removed camera invalidates the PTP channel. Tear down the
                // session immediately; the queue remains owned by RootView and
                // can resume waiting work after the next successful connection.
                cameraRepository = nil
                cameraSession = nil
                Task { [weak self] in
                    guard let self else { return }
                    await connectionService.reset()
                }
                // A cable removed before the first accepted USB session only
                // borrowed the connection slot. Restore AP automatic discovery
                // as Android does; an established USB workspace stays mounted.
                if !wasEstablished { startAPWatcherIfNeeded() }
            }
            break
        case let .ready(id):
            // Some ImageCaptureCore camera drivers emit ready without a
            // second didAdd callback.  Android starts USB connection as soon
            // as the attached device is usable, so use ready as an equivalent
            // trigger when authorization and selection are already settled.
            if state.usbAuthorization == .authorized,
               state.selectedDeviceID == id,
               state.usbPhase == .waitingForCamera,
               usbConnectTask == nil {
                state.usbPhase = .connecting
                usbConnectTask = Task { [weak self] in await self?.connectSelectedUSB() }
            }
        case .sessionOpened:
            break
        case let .sessionClosed(id, token):
            if let failedSession = cameraSession,
               (id == previous.selectedDeviceID || id == failedSession.transportDeviceID),
               failedSession.usbSessionToken == token,
               let deviceID = failedSession.transportDeviceID {
                let generation = connectionGeneration
                Task { [weak self] in
                    await self?.usbTransportLost(failedSession, deviceID: deviceID, generation: generation)
                }
            }
        case let .failed(id, message):
            // ImageCaptureCore can report the same broken channel before the
            // next heartbeat. Route it through the same stale-session guard
            // and reconnect path that handles a failed idle probe.
            if let failedSession = cameraSession,
               (id == nil || id == previous.selectedDeviceID),
               let deviceID = failedSession.transportDeviceID {
                let generation = connectionGeneration
                Task { [weak self] in
                    await self?.usbTransportLost(failedSession, deviceID: deviceID, generation: generation)
                }
            } else if id == nil || id == previous.selectedDeviceID {
                state.usbPhase = .failed(message)
            }
        }
    }

    private func usbErrorMessage(_ error: Error) -> String {
        switch error {
        case CameraTransportError.timeout, PTPSessionError.timeout:
            return "连接超时，请检查相机电源和 USB 数据线"
        case CameraTransportError.permissionDenied:
            return AppLocalized.resource("usb_permission_required")
        case CameraTransportError.disconnected, CameraTransportError.unavailable:
            return AppLocalized.resource("usb_connection_lost")
        case PTPSessionError.invalidated:
            return AppLocalized.resource("usb_connection_lost")
        default:
            return error.localizedDescription
        }
    }
}
