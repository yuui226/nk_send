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

    deinit {
        usbEventsTask?.cancel()
        usbConnectTask?.cancel()
        wifiConnectTask?.cancel()
        wifiWatcherTask?.cancel()
        wifiPathMonitor?.cancel()
        usbTransport.stop()
    }

    func startUSBDiscovery() {
        guard usbEventsTask == nil else { return }
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
        wifiConnectTask?.cancel()
        wifiConnectTask = nil
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
        usbEventsTask?.cancel()
        usbEventsTask = nil
        usbConnectTask?.cancel()
        usbConnectTask = nil
        usbTransport.stop()
    }

    func disconnectCamera() async {
        connectionGeneration &+= 1
        usbConnectTask?.cancel()
        usbConnectTask = nil
        wifiConnectTask?.cancel()
        wifiConnectTask = nil
        wifiGeneration &+= 1
        await connectionService.disconnect()
        await wifiService.disconnect()
        cameraRepository = nil
        cameraSession = nil
        state.usbPhase = .waitingForCamera
        state.selectedDeviceID = nil
        state.wifiPhase = .idle
        // Returning from the photo list keeps Android's AP watcher alive;
        // restart it after the explicit session teardown when Wi‑Fi is still
        // on the camera candidate network.
        startAPWatcherIfNeeded()
    }

    /// AP uses Nikon's fixed camera-hotspot address. STA discovery is kept as
    /// a separate task until the interface scan can provide a proven candidate.
    func connectSelectedWiFi() async {
        guard wifiConnectTask == nil, cameraSession == nil else { return }
        let mode = state.wirelessMode
        let generation = wifiGeneration &+ 1
        wifiGeneration = generation
        state.wifiPhase = mode == .sta ? .discovering : .connecting
        wifiConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidate: PTPIPCandidate
                if mode == .ap {
                    candidate = PTPIPCandidate(ip: "192.168.1.1", localAddress: nil)
                } else {
                    guard let found = await self.wifiDiscovery.discover() else { throw PTPIPDiscoveryError.notFound }
                    candidate = found
                }
                await MainActor.run { self.state.wifiPhase = .connecting }
                let repository = try await self.wifiService.connect(host: candidate.ip)
                guard !Task.isCancelled else {
                    await self.wifiService.disconnect()
                    await MainActor.run { self.wifiConnectTask = nil; self.state.wifiPhase = .idle }
                    return
                }
                guard self.wifiGeneration == generation, self.state.wirelessMode == mode else {
                    await self.wifiService.disconnect()
                    await MainActor.run { self.wifiConnectTask = nil }
                    return
                }
                await MainActor.run {
                    self.cameraRepository = repository
                    self.cameraSession = CameraSession(repository: repository)
                    self.state.wifiPhase = .connected
                    self.wifiConnectTask = nil
                    self.wifiWatcherTask?.cancel()
                    self.wifiWatcherTask = nil
                }
            } catch is CancellationError {
                await MainActor.run { self.wifiConnectTask = nil; self.state.wifiPhase = .idle }
            } catch {
                await MainActor.run { self.wifiConnectTask = nil; self.state.wifiPhase = .failed(self.wifiErrorMessage(error)) }
            }
        }
        await wifiConnectTask?.value
    }

    private func wifiErrorMessage(_ error: Error) -> String {
        switch error {
        case PTPIPDiscoveryError.notFound: return "未找到相机"
        case PTPSessionError.timeout: return "连接超时，请检查相机电源和 Wi-Fi 连接"
        case PTPSessionError.invalidated: return "Wi-Fi 连接已断开"
        default: return error.localizedDescription
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
        wifiGeneration &+= 1
        wifiConnectTask?.cancel()
        wifiConnectTask = nil
        Task { await wifiService.disconnect() }
        state.wifiPhase = .idle
        state.wirelessMode = wirelessMode
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
               previous.usbPhase == .waitingForCamera,
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
        case .ready:
            break
        case .sessionOpened:
            break
        case .sessionClosed:
            break
        case .failed:
            break
        }
    }

    private func usbErrorMessage(_ error: Error) -> String {
        switch error {
        case CameraConnectionServiceError.timeout, CameraTransportError.timeout, PTPSessionError.timeout:
            return "连接超时，请检查相机电源和 USB 数据线"
        case CameraTransportError.permissionDenied:
            return "未获得 USB 权限，请重新插线并允许访问"
        case CameraTransportError.disconnected:
            return "有线连接已断开"
        case PTPSessionError.invalidated:
            return "有线连接已断开"
        default:
            return error.localizedDescription
        }
    }
}
