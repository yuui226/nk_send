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
    private var wifiConnectTask: Task<Void, Never>?
    private var wifiRetryTask: Task<Void, Never>?
    private var wifiCleanupTask: Task<Void, Never>?
    private var wifiRetryAttempt = 0
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
    private let usbMaxAttempts = 3
    private let usbRetryDelayNanoseconds: UInt64 = 1_000_000_000

    init() {
        state.wirelessMode = wirelessPreferences.string(forKey: "wireless_mode") == "AP" ? .ap : .sta
        Task { [weak self] in await self?.refreshSTAProfiles() }
    }

    deinit {
        usbEventsTask?.cancel()
        usbConnectTask?.cancel()
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
                wifiGeneration &+= 1
                wifiConnectTask?.cancel()
                wifiConnectTask = nil
                if state.wifiPhase != .idle { state.wifiPhase = .idle }
            }
            wifiWatcherTask?.cancel()
            wifiWatcherTask = nil
            return
        }
        startAPWatcherIfNeeded()
    }

    private func startAPWatcherIfNeeded() {
        guard wifiPathAvailable, state.wirelessMode == .ap, cameraSession == nil,
              wifiWatcherTask == nil else { return }
        wifiWatcherTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.wifiPathAvailable, self.state.wirelessMode == .ap,
                      self.cameraSession == nil else { break }
                // Android checks the DHCP gateway before starting a handshake.
                // iOS has no public gateway API; this subnet gate is the closest
                // available equivalent and the PTP handshake remains authoritative.
                if self.wifiDiscovery.isOnCameraHotspot(), self.wifiConnectTask == nil {
                    await self.connectSelectedWiFi()
                }
                let delay: UInt64 = {
                    if case .failed = self.state.wifiPhase { return 3_000_000_000 }
                    return 1_000_000_000
                }()
                do { try await Task.sleep(nanoseconds: delay) } catch { break }
            }
            if !Task.isCancelled { self.wifiWatcherTask = nil }
        }
    }

    func stopUSBDiscovery() {
        connectionGeneration &+= 1
        let stopGeneration = connectionGeneration
        usbEventsTask?.cancel()
        usbEventsTask = nil
        usbConnectTask?.cancel()
        usbConnectTask = nil
        // stop() can race an OpenSession callback.  Close the service first and
        // only then stop ImageCaptureCore, so it still owns the camera reference
        // while the non-cancellable close request is in flight.  Android keeps
        // the same ordering when its USB monitor is torn down.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.connectionService.disconnect()
            guard self.connectionGeneration == stopGeneration else { return }
            self.usbTransport.stop()
        }
    }

    func disconnectCamera() async {
        connectionGeneration &+= 1
        usbConnectTask?.cancel()
        usbConnectTask = nil
        cancelWiFiConnection()
        await wifiCleanupTask?.value
        wifiGeneration &+= 1
        await wifiService.disconnect()
        await connectionService.disconnect()
        cameraRepository = nil
        cameraSession = nil
        state.usbPhase = .waitingForCamera
        state.selectedDeviceID = nil
        state.wifiPhase = .idle
        state.wifiFailureKind = nil
        // Returning from the photo list keeps Android's AP watcher alive;
        // restart it after the explicit session teardown when Wi‑Fi is still
        // on the camera candidate network.
        startAPWatcherIfNeeded()
    }

    var staBusy: Bool {
        state.wirelessMode == .sta && [.discovering, .pairing, .connecting].contains(state.wifiPhase)
    }

    func connectSelectedWiFi() async {
        if staBusy { cancelWiFiConnection(); return }
        wifiRetryAttempt = 0
        wifiRetryTask?.cancel(); wifiRetryTask = nil
        await beginWiFiConnection(reconnect: false)
    }

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
        guard wifiConnectTask == nil, cameraSession == nil, state.usbPhase != .connecting else { return }
        let mode = state.wirelessMode
        wifiGeneration &+= 1
        let generation = wifiGeneration
        state.wifiPhase = mode == .sta ? .discovering : .connecting
        state.wifiFailureKind = nil
        state.staProgressIP = nil
        let pendingCleanup = wifiCleanupTask
        wifiConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                await pendingCleanup?.value
                try Task.checkCancellation()
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
                      self.cameraSession == nil, self.state.usbPhase != .connecting else {
                    if self.wifiGeneration == generation { await self.wifiService.disconnect() }
                    return
                }
                self.cameraRepository = repository
                self.cameraSession = CameraSession(repository: repository, wirelessMode: mode)
                self.state.wifiPhase = .connected
                self.state.staProgressIP = nil
                self.wifiConnectTask = nil
                self.wifiWatcherTask?.cancel(); self.wifiWatcherTask = nil
                self.wifiRetryAttempt = 0
                await self.refreshSTAProfiles()
                await self.wifiService.startKeepalive(for: repository) { [weak self] in
                    await self?.wifiTransportLost(generation: generation, mode: mode)
                }
            } catch {
                guard self.wifiGeneration == generation else { return }
                self.wifiConnectTask = nil
                if Task.isCancelled || error is CancellationError { self.state.wifiPhase = .idle; return }
                self.state.wifiPhase = .failed(self.wifiErrorMessage(error))
                if mode == .ap { self.state.wifiFailureKind = Self.wifiFailureKind(for: error) }
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

    private func wifiTransportLost(generation: Int, mode: WirelessMode) async {
        guard wifiGeneration == generation, state.wifiPhase == .connected else { return }
        cameraSession = nil; cameraRepository = nil
        state.wifiPhase = .idle
        await wifiService.disconnect()
        if mode == .sta { scheduleSTARetry(generation: generation) }
        else { startAPWatcherIfNeeded() }
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
                await connectionService.disconnect()
                usbConnectTask = nil
                return
            }
            cameraRepository = repository
            if let cameraRepository {
                cameraSession = CameraSession(repository: cameraRepository, transport: usbTransport, deviceID: id)
            }
            state.usbPhase = .connected
        } catch is CancellationError {
            // CameraConnectionService may have completed OpenSession just
            // before cancellation was observed.  Always run its non-cancel-
            // lable close path so a cancelled USB connect cannot retain PTP.
            await connectionService.disconnect()
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

    func selectDevice(id: String) {
        guard state.discoveredDevices.contains(where: { $0.id == id }) else { return }
        guard state.selectedDeviceID != id else { return }
        connectionGeneration &+= 1
        usbConnectTask?.cancel()
        usbConnectTask = nil
        Task { [weak self] in await self?.connectionService.disconnect() }
        state.selectedDeviceID = id
        state.usbPhase = .waitingForCamera
    }

    func select(mode: CameraConnectionMode) {
        state.selectedMode = mode
    }

    func select(wirelessMode: WirelessMode) {
        guard state.wirelessMode != wirelessMode else { return }
        guard cameraSession == nil else { return }
        cancelWiFiConnection()
        state.wirelessMode = wirelessMode
        state.wifiFailureKind = nil
        wirelessPreferences.set(wirelessMode == .sta ? "STA" : "AP", forKey: "wireless_mode")
        if wirelessMode == .ap { startAPWatcherIfNeeded() } else {
            wifiWatcherTask?.cancel()
            wifiWatcherTask = nil
        }
    }

    private func apply(_ event: USBTransportEvent) {
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
                connectionGeneration &+= 1
                usbConnectTask?.cancel(); usbConnectTask = nil
                // A removed camera invalidates the PTP channel. Tear down the
                // session immediately; the queue remains owned by RootView and
                // can resume waiting work after the next successful connection.
                cameraRepository = nil
                cameraSession = nil
                Task { [weak self] in
                    guard let self else { return }
                    await connectionService.disconnect()
                }
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
        case .sessionClosed:
            break
        case let .failed(id, message):
            // A transport error after a successful handshake invalidates the
            // session immediately.  Leaving cameraSession alive would keep
            // the photo list visible while every subsequent command fails;
            // Android returns to its disconnected USB state instead.
            if let id, id == previous.selectedDeviceID, cameraSession != nil {
                connectionGeneration &+= 1
                cameraRepository = nil
                cameraSession = nil
                usbConnectTask?.cancel()
                usbConnectTask = nil
                Task { [weak self] in await self?.connectionService.disconnect() }
                state.usbPhase = .failed(message)
            }
        }
    }

    private func usbErrorMessage(_ error: Error) -> String {
        switch error {
        case CameraConnectionServiceError.timeout, CameraTransportError.timeout, PTPSessionError.timeout:
            return "连接超时，请检查相机电源和 USB 数据线"
        case CameraTransportError.permissionDenied:
            return AppLocalized.resource("usb_permission_required")
        case CameraTransportError.disconnected:
            return AppLocalized.resource("usb_connection_lost")
        case PTPSessionError.invalidated:
            return AppLocalized.resource("usb_connection_lost")
        default:
            return error.localizedDescription
        }
    }
}
