@preconcurrency import CoreBluetooth
import Combine
import Foundation
import ExternalAccessory
import UIKit

@MainActor
protocol GPSBluetoothTransport: AnyObject {
    var state: NikonGPSBluetoothState { get }
    var statePublisher: AnyPublisher<NikonGPSBluetoothState, Never> { get }
    var hasSavedPairing: Bool { get }
    var hasPairingIdentity: Bool { get }
    var isRunning: Bool { get }
    func start()
    func stop()
    func clearPairing()
    func writeGeo(_ data: Data, completion: @escaping (Bool) -> Void)
}

extension GPSBluetoothTransport {
    var hasPairingIdentity: Bool { hasSavedPairing }
}

enum NikonGPSBluetoothState: Equatable, Sendable {
    case unauthorized
    case unavailable
    case scanning
    case connecting(String)
    case pairing
    case cameraConfirm
    case verifyingPairing(String)
    case ready(String)
    case disconnected
    case failed(String)
}

enum NikonGPSSystemPairingResult: Equatable, Sendable {
    case paired, alreadyConnected, cancelled, notFound, failed, timedOut

    init(error: Error?) {
        guard let underlyingError = error else { self = .paired; return }
        let error = underlyingError as NSError
        guard error.domain == EABluetoothAccessoryPickerErrorDomain else { self = .failed; return }
        switch EABluetoothAccessoryPickerError.Code(rawValue: error.code) {
        case .alreadyConnected: self = .alreadyConnected
        case .resultCancelled: self = .cancelled
        case .resultNotFound: self = .notFound
        default: self = .failed
        }
    }

    var failureMessage: String {
        "请确认蓝牙配对"
    }

    // On the real Z50_2, the camera confirmed bonding while the iAP picker
    // returned notFound. That result is not Nikon's identity/GPS verdict.
    // Keep a provisional identity and verify over BLE. Code 2 can also mean
    // the picker closed after a Classic connection failure (real Z50_2 trace:
    // BT_ERROR_INVALID_LINK_KEY); do not describe it as a user cancellation.
    // Stop that attempt and explain recovery without claiming a successful bond.
    var canVerifyCamera: Bool { self != .cancelled && self != .timedOut }
}

@MainActor
protocol NikonGPSSystemPairing: AnyObject {
    func pair(cameraName: String, completion: @escaping @MainActor (NikonGPSSystemPairingResult) -> Void)
    func cancel()
}

/// iOS public counterpart of Android's Classic discovery/createBond phase.
/// The OS owns the picker and passkey confirmation; cancellation invalidates our
/// request, never dismisses unrelated UI or accepts a late system result.
@MainActor
final class NikonGPSAccessoryPairing: NikonGPSSystemPairing {
    typealias PresentPicker = @MainActor (NSPredicate, @escaping @MainActor (NikonGPSSystemPairingResult) -> Void) -> Void
    private let applicationIsActive: @MainActor () -> Bool
    private let presentPicker: PresentPicker
    private var generation = 0
    private var visiblePickerGeneration: Int?
    private var pending: (String, @MainActor (NikonGPSSystemPairingResult) -> Void)?
    private var foregroundObservation: AnyCancellable?

    init(applicationIsActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         presentPicker: @escaping PresentPicker = { filter, completion in
             EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: filter) { error in
                 if let error = error as NSError? {
                     GPSDiagnostics.record("system picker callback error=\(error.domain)/\(error.code)")
                 }
                 let result = NikonGPSSystemPairingResult(error: error)
                 Task { @MainActor in completion(result) }
             }
         }) {
        self.applicationIsActive = applicationIsActive
        self.presentPicker = presentPicker
    }

    static func nameFilter(_ name: String) -> NSPredicate {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty || target.caseInsensitiveCompare("Nikon") == .orderedSame {
            return NSPredicate(format: "SELF CONTAINS[c] %@", "Nikon")
        }
        // NikonGpsBleClient.namesMatch: equal, or a >=4-character prefix on
        // either side. Use serializable predicates supported by Apple's picker.
        return NSPredicate(format: "SELF ==[c] %@ OR (SELF BEGINSWITH[c] %@ AND %@ >= 4) OR (%@ BEGINSWITH[c] SELF AND length >= 4)",
                           target, target, NSNumber(value: target.count), target)
    }

    func pair(cameraName: String, completion: @escaping @MainActor (NikonGPSSystemPairingResult) -> Void) {
        guard visiblePickerGeneration == nil, pending == nil else { completion(.failed); return }
        generation &+= 1
        pending = (cameraName, completion)
        foregroundObservation = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.presentIfActive() } }
        presentIfActive()
    }

    private func presentIfActive() {
        guard applicationIsActive(),
              visiblePickerGeneration == nil, let (name, _) = pending else { return }
        visiblePickerGeneration = generation
        foregroundObservation = nil
        let token = generation
        GPSDiagnostics.record("system Bluetooth pairing picker opened")
        presentPicker(Self.nameFilter(name)) { [weak self] result in
            guard let self, self.visiblePickerGeneration == token else { return }
            self.visiblePickerGeneration = nil
            guard self.generation == token, let (_, completion) = self.pending else { return }
            self.pending = nil
            completion(result)
        }
    }

    func cancel() {
        generation &+= 1
        pending = nil
        foregroundObservation = nil
    }
}

/// CoreBluetooth may reuse a peripheral object across connections. Keep discovery
/// object identity as well, so callbacks from an old service cannot advance setup.
@MainActor
final class NikonGPSDiscoveryOwnership {
    private var service: CBService?
    private var notifications: [CBCharacteristic] = []

    func begin(_ service: CBService) {
        self.service = service
        notifications.removeAll()
    }
    func accepts(_ service: CBService) -> Bool { self.service === service }
    func registerNotifications(_ characteristics: [CBCharacteristic], for service: CBService) {
        guard accepts(service) else { return }
        notifications = characteristics
    }
    func acceptsNotification(_ characteristic: CBCharacteristic) -> Bool {
        notifications.contains { $0 === characteristic }
    }
    func clear() {
        service = nil
        notifications.removeAll()
    }
}

@MainActor
final class NikonGPSDeferredAction {
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.sleep = sleep
    }

    @discardableResult
    func schedule(after delay: UInt64, action: @escaping @MainActor () -> Void) -> Bool {
        guard task == nil else { return false }
        let token = generation, sleep = sleep
        task = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.task = nil
            action()
        }
        return true
    }

    var isScheduled: Bool { task != nil }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

/// A cancel request is asynchronous. Do not reuse its peripheral until the
/// terminal central callback; CoreBluetooth then guarantees no old delegate calls.
@MainActor
final class NikonGPSConnectionRetirement {
    private var owner: AnyObject?
    private var pending: (@MainActor () -> Void)?

    var isRetiring: Bool { owner != nil }
    func begin(_ owner: AnyObject) { self.owner = owner }
    func contains(_ owner: AnyObject) -> Bool { self.owner === owner }
    func deferIfNeeded(_ action: @escaping @MainActor () -> Void) -> Bool {
        guard owner != nil else { return false }
        pending = action
        return true
    }
    func cancelPending() { pending = nil }
    @discardableResult
    func finish(_ owner: AnyObject) -> Bool {
        guard contains(owner) else { return false }
        let action = pending
        self.owner = nil
        pending = nil
        action?()
        return true
    }
    func invalidate() { owner = nil; pending = nil }
}

/// One serialized GATT write stream. Both peripheral and characteristic
/// identities must match an outstanding write before an ACK may consume it.
@MainActor
final class NikonGPSWriteQueue<Characteristic: AnyObject> {
    struct Entry {
        let owner: AnyObject
        let characteristic: Characteristic
        let data: Data
        let completion: ((Bool) -> Void)?
    }
    private var entries: [Entry] = []
    private var inFlight = false

    func enqueue(owner: AnyObject, characteristic: Characteristic, data: Data,
                 completion: ((Bool) -> Void)? = nil) {
        entries.append(Entry(owner: owner, characteristic: characteristic, data: data, completion: completion))
    }

    func next(owner: AnyObject) -> Entry? {
        guard !inFlight, let entry = entries.first, entry.owner === owner else { return nil }
        inFlight = true
        return entry
    }

    func acknowledge(owner: AnyObject, characteristic: Characteristic) -> Entry? {
        guard inFlight, let entry = entries.first,
              entry.owner === owner, entry.characteristic === characteristic else { return nil }
        inFlight = false
        return entries.removeFirst()
    }

    func isPending(owner: AnyObject, characteristic: Characteristic) -> Bool {
        inFlight && entries.first?.owner === owner && entries.first?.characteristic === characteristic
    }

    func cancelAll() {
        let abandoned = entries
        entries.removeAll()
        inFlight = false
        abandoned.forEach { $0.completion?(false) }
    }
}

/// CoreBluetooth counterpart of Android's NikonGpsBleClient.  All GATT writes
/// are serialized through CoreBluetooth's callback order; no parallel writes
/// are issued to the camera characteristics.
@MainActor
final class NikonGPSBluetoothClient: NSObject, ObservableObject, GPSBluetoothTransport {
    private let stateEvents = CurrentValueSubject<NikonGPSBluetoothState, Never>(.disconnected)
    var statePublisher: AnyPublisher<NikonGPSBluetoothState, Never> { stateEvents.eraseToAnyPublisher() }
    // Lifecycle subscribers can synchronously stop/retry. Notify them after
    // assignment, otherwise @Published's willSet can overwrite that newer state.
    @Published private(set) var state: NikonGPSBluetoothState = .disconnected {
        didSet { stateEvents.send(state) }
    }
    @Published private(set) var peripheralIdentifier: UUID?

    private let connectionRetirement = NikonGPSConnectionRetirement()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var pairCharacteristic: CBCharacteristic?
    private var idCharacteristic: CBCharacteristic?
    private var geoCharacteristic: CBCharacteristic?
    private var stage1: NikonGPSPairingPacket?
    private var stage3Sent = false
    private var idQueued = false
    private var savedDevice: UInt32?
    private var savedNonce: UInt32?
    private var savedPeripheralIdentifier: UUID?
    private var savedCameraName: String?
    private var identityNeedsVerification = false
    private var controllerName = "ZTransfer"
    private let writeQueue = NikonGPSWriteQueue<CBCharacteristic>()
    private var notificationsReady = Set<CBUUID>()
    private let discoveryOwnership = NikonGPSDiscoveryOwnership()
    private let systemPairing: any NikonGPSSystemPairing
    private let systemPairingDeadline: NikonGPSDeferredAction
    private var systemPairingGeneration = 0
    private var systemPairingInProgress = false
    private let pairingDeadline: NikonGPSDeferredAction
    private let directReconnectDeadline: NikonGPSDeferredAction
    private let controllerIDFallback = NikonGPSDeferredAction()
    private let scanDeadline: NikonGPSDeferredAction
    private let idWriteDeadline: NikonGPSDeferredAction
    private let setupDeadline: NikonGPSDeferredAction
    private var connectionGeneration: UInt64 = 0
    private var shouldRun = false
    private var freshPairingAttempt = false
    private let defaults: UserDefaults
    private let centralFactory: @MainActor (CBCentralManagerDelegate, [String: Any]?) -> CBCentralManager

    init(controllerName: String = "ZTransfer", savedDevice: UInt32? = nil, savedNonce: UInt32? = nil, defaults: UserDefaults? = nil,
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         centralFactory: @escaping @MainActor (CBCentralManagerDelegate, [String: Any]?) -> CBCentralManager = {
             CBCentralManager(delegate: $0, queue: .main, options: $1)
         }, systemPairing: (any NikonGPSSystemPairing)? = nil) {
        self.systemPairing = systemPairing ?? NikonGPSAccessoryPairing()
        systemPairingDeadline = NikonGPSDeferredAction(sleep: sleep)
        pairingDeadline = NikonGPSDeferredAction(sleep: sleep)
        directReconnectDeadline = NikonGPSDeferredAction(sleep: sleep)
        scanDeadline = NikonGPSDeferredAction(sleep: sleep)
        idWriteDeadline = NikonGPSDeferredAction(sleep: sleep)
        setupDeadline = NikonGPSDeferredAction(sleep: sleep)
        self.controllerName = controllerName
        self.centralFactory = centralFactory
        let storage = defaults ?? UserDefaults(suiteName: GPSPreferences.suiteName)!
        self.defaults = storage
        let storedDevice = (storage.object(forKey: GPSPreferences.deviceID) as? NSNumber).map { $0.uint32Value }
        let storedNonce = (storage.object(forKey: GPSPreferences.nonce) as? NSNumber).map { $0.uint32Value }
        let completeIdentity = storedDevice != nil && storedNonce != nil
        let confirmed = storage.bool(forKey: GPSPreferences.pairingConfirmed) && completeIdentity
        let pendingVerification = storage.bool(forKey: GPSPreferences.pairingVerificationPending) && completeIdentity
        if !confirmed && !pendingVerification {
            // Earlier iOS builds saved stage 1 before any system bond existed.
            // Such records cannot bypass first pairing in the corrected flow.
            storage.removeObject(forKey: GPSPreferences.deviceID)
            storage.removeObject(forKey: GPSPreferences.nonce)
            storage.removeObject(forKey: GPSPreferences.bleAddress)
            storage.removeObject(forKey: GPSPreferences.pairingConfirmed)
            storage.removeObject(forKey: GPSPreferences.pairingVerificationPending)
            storage.removeObject(forKey: GPSPreferences.cameraName)
        }
        if let savedDevice, let savedNonce {
            self.savedDevice = savedDevice; self.savedNonce = savedNonce
        } else if confirmed || pendingVerification {
            self.savedDevice = storedDevice; self.savedNonce = storedNonce
            self.identityNeedsVerification = !confirmed
        }
        self.savedCameraName = storage.string(forKey: GPSPreferences.cameraName)
        self.savedPeripheralIdentifier = storage.string(forKey: GPSPreferences.bleAddress)
            .flatMap(UUID.init(uuidString:))
        super.init()
    }

    /// Create Bluetooth only after explicit GPS enable and location authorization.
    /// GPS is session-only: do not register for relaunch/state restoration. The
    /// same initializer runs on Simulator and device, avoiding a device-only path.
    private func ensureCentral() -> CBCentralManager {
        if let central { return central }
        let manager = centralFactory(self, nil)
        central = manager
        return manager
    }

    func start() {
        guard !systemPairingInProgress else { return }
        shouldRun = true
        GPSDiagnostics.record("BLE start savedIdentity=\(savedDevice != nil && savedNonce != nil)")
        if connectionRetirement.deferIfNeeded({ [weak self] in self?.start() }) {
            GPSDiagnostics.record("BLE awaiting prior connection retirement")
            return
        }
        let central = ensureCentral()
        if central.state == .unknown || central.state == .resetting { return }
        guard central.state == .poweredOn else {
            GPSDiagnostics.record("Bluetooth adapter unavailable")
            state = central.state == .unauthorized ? .unauthorized : .unavailable
            return
        }
        guard peripheral == nil, !central.isScanning else { return }
        if identityNeedsVerification {
            state = .verifyingPairing(savedCameraName ?? "Nikon")
            guard shouldRun else { return }
        }
        directReconnectDeadline.cancel()
        // Android's service first attempts the saved BLE address, then falls
        // back to a filtered scan when the camera is unavailable. CoreBluetooth
        // exposes the equivalent through a persisted peripheral UUID.
        let connected = hasPairingIdentity ? central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]) : []
        let connectedID = Self.connectedPeripheralID(connected.map { ($0.identifier, $0.name) },
                                                     savedID: savedPeripheralIdentifier, cameraName: savedCameraName)
        if let remembered = connected.first(where: { $0.identifier == connectedID }) {
            GPSDiagnostics.record("BLE reusing system-connected camera")
            connectRemembered(remembered, central: central)
        } else if hasPairingIdentity,
           let savedPeripheralIdentifier,
           let remembered = central.retrievePeripherals(withIdentifiers: [savedPeripheralIdentifier]).first {
            GPSDiagnostics.record("BLE reconnecting known camera")
            connectRemembered(remembered, central: central)
        } else {
            beginScan()
        }
    }

    /// Apple recommends retrieving known/system-connected peripherals before
    /// scanning: an already connected camera may no longer advertise.
    static func connectedPeripheralID(_ candidates: [(id: UUID, name: String?)],
                                      savedID: UUID?, cameraName: String?) -> UUID? {
        if let savedID, candidates.contains(where: { $0.id == savedID }) { return savedID }
        guard let cameraName, !cameraName.isEmpty, cameraName.caseInsensitiveCompare("Nikon") != .orderedSame else { return nil }
        let exact = candidates.filter { $0.name?.caseInsensitiveCompare(cameraName) == .orderedSame }
        if exact.count == 1 { return exact[0].id }
        let filter = NikonGPSAccessoryPairing.nameFilter(cameraName)
        let matches = candidates.filter { $0.name.map { filter.evaluate(with: $0) } ?? false }
        return matches.count == 1 ? matches[0].id : nil
    }

    private func connectRemembered(_ remembered: CBPeripheral, central: CBCentralManager) {
        peripheral = remembered
        remembered.delegate = self
        central.connect(remembered)
        beginDirectReconnectDeadline { [weak self, weak remembered] in
            guard let self, let remembered, self.acceptsCallback(from: remembered),
                  self.state == .connecting(remembered.name ?? "Nikon") else { return }
            self.retireConnection(remembered)
            self.clearConnectionState()
            self.beginScan()
        }
        publishConnecting(remembered)
    }

    private func publishConnecting(_ peripheral: CBPeripheral) {
        guard acceptsCallback(from: peripheral) else { return }
        peripheralIdentifier = peripheral.identifier
        // @Published observers can synchronously stop the client.
        guard acceptsCallback(from: peripheral) else { return }
        state = .connecting(peripheral.name ?? "Nikon")
    }

    func beginDirectReconnectDeadline(fallback: @escaping @MainActor () -> Void) {
        directReconnectDeadline.cancel()
        // NikonGpsBleClient.DIRECT_CONNECT_TIMEOUT_MS; connected cancels this
        // deadline before service discovery and subsequent handshake deadlines.
        directReconnectDeadline.schedule(after: 4_500_000_000, action: fallback)
    }

    private func beginScan() {
        guard shouldRun, let central, central.state == .poweredOn else { return }
        if connectionRetirement.deferIfNeeded({ [weak self] in self?.beginScan() }) { return }
        directReconnectDeadline.cancel()
        GPSDiagnostics.record("BLE scan started")
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        beginScanDeadline { [weak central] in central?.stopScan() }
    }

    func stop() {
        shouldRun = false
        cancelSystemPairing()
        connectionRetirement.cancelPending()
        GPSDiagnostics.record("BLE stopped")
        directReconnectDeadline.cancel()
        pairingDeadline.cancel()
        if central?.isScanning == true { central?.stopScan() }
        if let peripheral { retireConnection(peripheral) }
        clearConnectionState()
        state = .disconnected
    }

    private func retireConnection(_ peripheral: CBPeripheral) {
        // The peripheral state may change before its queued terminal callback.
        // Fence the requested connection even if it already reports disconnected.
        if central?.state == .poweredOn { connectionRetirement.begin(peripheral) }
        central?.cancelPeripheralConnection(peripheral)
    }

    func beginScanDeadline(stopScan: @escaping @MainActor () -> Void) {
        scanDeadline.cancel()
        scanDeadline.schedule(after: 15_000_000_000) { [weak self] in
            guard let self, self.state == .scanning, self.peripheral == nil else { return }
            stopScan()
            self.state = .failed(self.identityNeedsVerification ? "GPS connection confirmation timeout" : "Camera not found")
        }
        state = .scanning
    }

    func beginIDWriteDeadline(isPending: @escaping @MainActor () -> Bool) {
        guard hasPairingIdentity, !freshPairingAttempt else { return }
        idWriteDeadline.cancel()
        idWriteDeadline.schedule(after: 3_000_000_000) { [weak self] in
            guard let self, isPending() else { return }
            if case .ready = self.state { return }
            self.writeQueue.cancelAll()
            self.state = .failed("GPS connection confirmation timeout")
        }
    }

    /// Android RECONNECT_SETUP_TIMEOUT_MS covers service discovery and both
    /// notification subscriptions. First-time pairing keeps its existing rules.
    func beginSetupDeadline(isCurrent: @escaping @MainActor () -> Bool,
                            closeConnection: @escaping @MainActor () -> Void) {
        setupDeadline.cancel()
        guard hasPairingIdentity else { return }
        setupDeadline.schedule(after: 15_000_000_000) { [weak self] in
            guard let self, isCurrent() else { return }
            closeConnection()
            self.state = .failed("Bluetooth setup timeout")
        }
    }

    private func discoverServices(_ peripheral: CBPeripheral) {
        beginSetupDeadline(isCurrent: { [weak self, weak peripheral] in
            guard let self, let peripheral else { return false }
            return self.acceptsCallback(from: peripheral)
        }, closeConnection: { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            // Retire before notifying the coordinator: late setup callbacks
            // cannot authenticate while the five-second retry is pending.
            self.retireConnection(peripheral)
            self.clearConnectionState()
        })
        peripheral.discoverServices([Self.serviceUUID])
    }

    func writeGeo(_ data: Data, completion: @escaping (Bool) -> Void) {
        guard let peripheral, let characteristic = geoCharacteristic,
              case .ready = state else {
            completion(false)
            return
        }
        enqueueWrite(peripheral: peripheral, characteristic: characteristic,
                     data: data, completion: completion)
    }

    var hasPairingIdentity: Bool { savedDevice != nil && savedNonce != nil }
    var hasSavedPairing: Bool { hasPairingIdentity && !identityNeedsVerification }
    var isRunning: Bool { systemPairingInProgress || peripheral != nil || central?.isScanning == true }

    func clearPairing() {
        GPSDiagnostics.record("cached pairing identity cleared")
        defaults.removeObject(forKey: GPSPreferences.pairingConfirmed)
        defaults.removeObject(forKey: GPSPreferences.pairingVerificationPending)
        defaults.removeObject(forKey: GPSPreferences.cameraName)
        defaults.removeObject(forKey: GPSPreferences.deviceID)
        defaults.removeObject(forKey: GPSPreferences.nonce)
        defaults.removeObject(forKey: GPSPreferences.bleAddress)
        UserDefaults.standard.removeObject(forKey: "gps.pairing.device")
        UserDefaults.standard.removeObject(forKey: "gps.pairing.nonce")
        savedDevice = nil
        savedNonce = nil
        savedPeripheralIdentifier = nil
        savedCameraName = nil
        identityNeedsVerification = false
        peripheralIdentifier = nil
        stop()
    }

    func invalidateAdapterConnection() {
        cancelSystemPairing()
        // Adapter loss invalidates the connection even before its terminal
        // peripheral callback. Retain pairing credentials, not live work.
        connectionRetirement.invalidate()
        clearConnectionState()
    }

    private func clearConnectionState() {
        directReconnectDeadline.cancel()
        scanDeadline.cancel()
        idWriteDeadline.cancel()
        setupDeadline.cancel()
        connectionGeneration &+= 1
        controllerIDFallback.cancel()
        pairingDeadline.cancel()
        peripheral = nil; pairCharacteristic = nil; idCharacteristic = nil; geoCharacteristic = nil
        stage1 = nil; stage3Sent = false; idQueued = false
        freshPairingAttempt = false
        notificationsReady.removeAll()
        discoveryOwnership.clear()
        // Completion handlers may synchronously start a replacement session.
        // Finish all old discovery cleanup before invoking external code.
        writeQueue.cancelAll()
    }

    private func acceptsCallback(from candidate: CBPeripheral) -> Bool {
        shouldRun && peripheral === candidate
    }

    private func enqueueWrite(peripheral: CBPeripheral, characteristic: CBCharacteristic,
                              data: Data, completion: ((Bool) -> Void)? = nil) {
        guard acceptsCallback(from: peripheral) else { completion?(false); return }
        writeQueue.enqueue(owner: peripheral, characteristic: characteristic, data: data, completion: completion)
        drainWrites(peripheral)
    }

    private func drainWrites(_ peripheral: CBPeripheral) {
        guard acceptsCallback(from: peripheral), let next = writeQueue.next(owner: peripheral) else { return }
        peripheral.writeValue(next.data, for: next.characteristic, type: .withResponse)
        if next.characteristic.uuid == Self.idUUID {
            let characteristic = next.characteristic
            beginIDWriteDeadline { [weak self, weak peripheral] in
                guard let self, let peripheral, self.acceptsCallback(from: peripheral) else { return false }
                return self.writeQueue.isPending(owner: peripheral, characteristic: characteristic)
            }
        }
    }

    func preparePairingIdentity() -> NikonGPSPairingPacket {
        freshPairingAttempt = !hasPairingIdentity
        let packet = NikonGPSPairingProtocol().newStage1(deviceOverride: savedDevice, nonceOverride: savedNonce)
        stage1 = packet
        // Stage 1 alone is only a proposal. After the system picker, iOS may
        // retain it explicitly as pending; only a GEO ACK confirms that record.
        return packet
    }

    /// ID ACK on the *fresh* LE handshake only opens the system pairing phase.
    /// Android onCharacteristicWrite(ID) does not emit onReady here either.
    func controllerIDDidWrite(cameraName: String, closeBLE: () -> Void) {
        guard shouldRun, idQueued, let proposed = stage1, !systemPairingInProgress else { return }
        pairingDeadline.cancel()
        idWriteDeadline.cancel()
        guard freshPairingAttempt else { state = .ready(cameraName); return }
        systemPairingGeneration &+= 1
        let token = systemPairingGeneration
        systemPairingInProgress = true
        state = .cameraConfirm
        guard shouldRun, systemPairingInProgress, token == systemPairingGeneration else { return }
        closeBLE()
        guard shouldRun, systemPairingInProgress, token == systemPairingGeneration else { return }
        GPSDiagnostics.record("ID acknowledged; awaiting system Bluetooth pairing")
        systemPairingDeadline.schedule(after: 30_000_000_000) { [weak self] in
            self?.finishSystemPairing(.timedOut, identity: proposed, cameraName: cameraName, token: token)
        }
        systemPairing.pair(cameraName: cameraName) { [weak self] result in
            self?.finishSystemPairing(result, identity: proposed, cameraName: cameraName, token: token)
        }
    }

    private func cancelSystemPairing() {
        systemPairingGeneration &+= 1
        systemPairingInProgress = false
        systemPairingDeadline.cancel()
        systemPairing.cancel()
    }

    private func finishSystemPairing(_ result: NikonGPSSystemPairingResult,
                                     identity: NikonGPSPairingPacket, cameraName: String, token: Int) {
        guard shouldRun, systemPairingInProgress, systemPairingGeneration == token else { return }
        cancelSystemPairing()
        let completedGeneration = systemPairingGeneration
        GPSDiagnostics.record("system Bluetooth pairing result=\(result)")
        guard result.canVerifyCamera else { state = .failed(result.failureMessage); return }
        savedDevice = identity.device; savedNonce = identity.nonce
        identityNeedsVerification = true
        savedCameraName = cameraName
        defaults.set(identity.device, forKey: GPSPreferences.deviceID)
        defaults.set(identity.nonce, forKey: GPSPreferences.nonce)
        defaults.set(false, forKey: GPSPreferences.pairingConfirmed)
        defaults.set(true, forKey: GPSPreferences.pairingVerificationPending)
        defaults.set(cameraName, forKey: GPSPreferences.cameraName)
        if let savedPeripheralIdentifier {
            defaults.set(savedPeripheralIdentifier.uuidString, forKey: GPSPreferences.bleAddress)
        }
        GPSDiagnostics.record("provisional identity retained; verifying camera over BLE")
        state = .verifyingPairing(cameraName)
        guard shouldRun, systemPairingGeneration == completedGeneration else { return }
        state = .disconnected
    }

    /// Called only after the current connection's acknowledged GEO write.
    /// A system-picker result alone must never display the paired badge.
    func confirmIdentityAfterGeoWrite() {
        guard shouldRun, identityNeedsVerification, hasPairingIdentity, case .ready = state else { return }
        identityNeedsVerification = false
        defaults.set(true, forKey: GPSPreferences.pairingConfirmed)
        defaults.removeObject(forKey: GPSPreferences.pairingVerificationPending)
        GPSDiagnostics.record("camera accepted GEO; pairing identity confirmed")
    }

    // Both Android handshake stages wait seven seconds. Only the initial
    // saved-identity stage reports expiration; stage 4 reports handshake timeout.
    func beginPairingDeadline(restoringIdentity: Bool) {
        pairingDeadline.cancel()
        pairingDeadline.schedule(after: 7_000_000_000) { [weak self] in
            guard let self, !self.idQueued else { return }
            self.state = .failed(self.identityNeedsVerification ? "GPS connection confirmation timeout" :
                                (restoringIdentity ? "Camera pairing identity expired" : "Camera pairing handshake timeout"))
        }
    }

    private func beginPairing(_ peripheral: CBPeripheral) {
        guard let pairCharacteristic else { return }
        setupDeadline.cancel()
        let restoringIdentity = hasPairingIdentity
        let packet = preparePairingIdentity()
        stage3Sent = false; idQueued = false
        GPSDiagnostics.record("BLE pairing handshake")
        beginPairingDeadline(restoringIdentity: restoringIdentity)
        enqueueWrite(peripheral: peripheral, characteristic: pairCharacteristic, data: packet.encode())
        if !restoringIdentity, acceptsCallback(from: peripheral) { state = .pairing }
    }

    private func handlePairingValue(_ value: Data, peripheral: CBPeripheral) {
        guard let packet = NikonGPSPairingPacket.decode(value), let first = stage1 else { return }
        if packet.stage == 2 && !stage3Sent {
            guard let response = NikonGPSPairingProtocol().stage3(for: first, stage2: packet), let pairCharacteristic else {
                state = .failed("Camera pairing rejected"); return
            }
            pairingDeadline.cancel(); stage3Sent = true
            GPSDiagnostics.record("pairing stage3 sent")
            enqueueWrite(peripheral: peripheral, characteristic: pairCharacteristic, data: response.encode())
            guard acceptsCallback(from: peripheral) else { return }
            beginPairingDeadline(restoringIdentity: false)
        } else if packet.stage == 4 {
            guard !idQueued else { return }
            pairingDeadline.cancel()
            // Repeated stage4 packets must not postpone the first fallback.
            let generation = connectionGeneration
            controllerIDFallback.schedule(after: 1_500_000_000) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      generation == self.connectionGeneration,
                      self.acceptsCallback(from: peripheral) else { return }
                self.queueControllerID(peripheral)
            }
        }
    }

    private func queueControllerID(_ peripheral: CBPeripheral) {
        guard acceptsCallback(from: peripheral), let idCharacteristic,
              let data = takeControllerIDPayload() else { return }
        enqueueWrite(peripheral: peripheral, characteristic: idCharacteristic, data: data)
    }

    /// Both NOT1 confirmation and the delayed PAIR stage4 fallback enter
    /// this gate on the main actor, so they cannot enqueue duplicate IDs.
    func takeControllerIDPayload() -> Data? {
        guard !idQueued else { return nil }
        controllerIDFallback.cancel()
        idQueued = true; pairingDeadline.cancel()
        GPSDiagnostics.record("ID queued")
        // Android uses US_ASCII (unmappable scalars become '?'), then copyOf(32).
        // UTF-8 or Foundation's lossy transliteration changes the wire identity.
        var data = Data(controllerName.unicodeScalars.prefix(32).map {
            $0.value < 128 ? UInt8($0.value) : UInt8(0x3F)
        })
        data.append(contentsOf: repeatElement(0, count: 32 - data.count))
        return data
    }

    enum NotificationRoute: Equatable { case controllerConfirmation, pairing, ignored }
    static func notificationRoute(uuid: CBUUID, value: Data) -> NotificationRoute {
        if uuid == not1UUID && value == Data([0x01, 0x00]) { return .controllerConfirmation }
        return uuid == pairUUID ? .pairing : .ignored
    }

    static func supportsGPSCharacteristics(_ uuids: Set<CBUUID>) -> Bool {
        Set([pairUUID, not1UUID, idUUID, geoUUID]).isSubset(of: uuids)
    }

    private static let serviceUUID = CBUUID(string: "0000DE00-3DD4-4255-8D62-6DC7B9BD5561")
    private static let pairUUID = CBUUID(string: "00002000-3DD4-4255-8D62-6DC7B9BD5561")
    private static let not1UUID = CBUUID(string: "00002008-3DD4-4255-8D62-6DC7B9BD5561")
    private static let idUUID = CBUUID(string: "00002002-3DD4-4255-8D62-6DC7B9BD5561")
    private static let geoUUID = CBUUID(string: "00002007-3DD4-4255-8D62-6DC7B9BD5561")
}

extension NikonGPSBluetoothClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { [weak self] in
            // Adapter state has the same ownership requirement as connection
            // callbacks; an unrelated manager must never restart this client.
            guard let self, self.central === central else { return }
            if central.state != .poweredOn {
                // SDK: lower adapter states disconnect all peripherals; below
                // poweredOff the peripheral objects themselves are invalid.
                self.invalidateAdapterConnection()
            }
            guard self.shouldRun else {
                self.state = .disconnected
                return
            }
            if central.state == .poweredOn {
                self.start()
            } else if central.state == .unknown || central.state == .resetting {
                self.state = .disconnected
            } else if central.state == .unauthorized {
                self.state = .unauthorized
            } else {
                self.state = .unavailable
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.shouldRun, self.central === central,
                  central.isScanning,
                  !self.connectionRetirement.isRetiring,
                  self.peripheral == nil else { return }
            let name = advertisedName ?? peripheral.name
            if self.hasPairingIdentity, let target = self.savedCameraName,
               peripheral.identifier != self.savedPeripheralIdentifier {
                guard let name, NikonGPSAccessoryPairing.nameFilter(target).evaluate(with: name) else { return }
            }
            GPSDiagnostics.record("BLE found name=\(name ?? "?")")
            self.scanDeadline.cancel()
            central.stopScan(); self.peripheral = peripheral
            self.savedPeripheralIdentifier = peripheral.identifier
            if self.hasPairingIdentity {
                self.defaults.set(peripheral.identifier.uuidString, forKey: GPSPreferences.bleAddress)
            }
            peripheral.delegate = self; central.connect(peripheral)
            self.publishConnecting(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard self.central === central else { return }
            if self.connectionRetirement.contains(peripheral) {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            guard self.acceptsCallback(from: peripheral) else { return }
            self.directReconnectDeadline.cancel()
            self.discoverServices(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.central === central else { return }
            if self.connectionRetirement.finish(peripheral) { return }
            guard self.acceptsCallback(from: peripheral) else { return }
            let wasDirect = self.directReconnectDeadline.isScheduled
            self.directReconnectDeadline.cancel()
            self.clearConnectionState()
            if wasDirect { self.beginScan() }
            else { self.state = .failed("Bluetooth connection failed") }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.central === central else { return }
            if self.connectionRetirement.finish(peripheral) { return }
            guard self.acceptsCallback(from: peripheral) else { return }
            let wasDirectReconnect = self.directReconnectDeadline.isScheduled
            if let error { GPSDiagnostics.record("BLE disconnected error=\(error.localizedDescription)") }
            self.clearConnectionState()
            if wasDirectReconnect {
                self.beginScan()
                return
            }
            self.state = .disconnected
        }
    }
}

extension NikonGPSBluetoothClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.acceptsCallback(from: peripheral) else { return }
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { self.state = .failed("Camera GPS service unavailable"); return }
            self.discoveryOwnership.begin(service)
            peripheral.discoverCharacteristics([Self.pairUUID, Self.not1UUID, Self.idUUID, Self.geoUUID], for: service)
            self.state = .connecting(peripheral.name ?? "Nikon")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.acceptsCallback(from: peripheral),
                  self.discoveryOwnership.accepts(service) else { return }
            guard error == nil else { self.state = .failed("Camera GPS service unavailable"); return }
            guard Self.supportsGPSCharacteristics(Set((service.characteristics ?? []).map(\.uuid))) else {
                self.state = .failed("Camera GPS service unavailable")
                return
            }
            self.discoveryOwnership.registerNotifications(
                (service.characteristics ?? []).filter { $0.uuid == Self.pairUUID || $0.uuid == Self.not1UUID },
                for: service)
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case Self.pairUUID: self.pairCharacteristic = characteristic; peripheral.setNotifyValue(true, for: characteristic)
                case Self.not1UUID: peripheral.setNotifyValue(true, for: characteristic)
                case Self.idUUID: self.idCharacteristic = characteristic
                case Self.geoUUID: self.geoCharacteristic = characteristic
                default: break
                }
            }
            self.beginPairingWhenReady(peripheral)
        }
    }

    private func beginPairingWhenReady(_ peripheral: CBPeripheral) {
        guard notificationsReady.contains(Self.pairUUID), notificationsReady.contains(Self.not1UUID),
              pairCharacteristic != nil, idCharacteristic != nil, geoCharacteristic != nil,
              stage1 == nil else { return }
        beginPairing(peripheral)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.acceptsCallback(from: peripheral),
                  self.discoveryOwnership.acceptsNotification(characteristic) else { return }
            guard error == nil, characteristic.isNotifying else {
                self.state = .failed("Camera GPS notification unavailable")
                return
            }
            self.notificationsReady.insert(characteristic.uuid)
            self.beginPairingWhenReady(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.acceptsCallback(from: peripheral),
                  self.discoveryOwnership.acceptsNotification(characteristic),
                  error == nil, let value = characteristic.value else { return }
            switch Self.notificationRoute(uuid: characteristic.uuid, value: value) {
            case .controllerConfirmation: self.queueControllerID(peripheral)
            case .pairing: self.handlePairingValue(value, peripheral: peripheral)
            case .ignored: break
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.acceptsCallback(from: peripheral),
                  let finished = self.writeQueue.acknowledge(owner: peripheral, characteristic: characteristic) else { return }
            if characteristic.uuid == Self.idUUID { self.idWriteDeadline.cancel() }
            if let error {
                let detail = error as NSError
                GPSDiagnostics.record("GATT write uuid=\(characteristic.uuid) error=\(detail.domain)/\(detail.code)")
            } else {
                GPSDiagnostics.record("GATT write uuid=\(characteristic.uuid) acknowledged")
            }
            if characteristic.uuid == Self.geoUUID, error == nil { self.confirmIdentityAfterGeoWrite() }
            finished.completion?(error == nil)
            guard self.acceptsCallback(from: peripheral) else { return }
            if let error {
                // Android reports a rejected GEO write through onGeoWritten(false)
                // without tearing down an otherwise ready BLE session. Pairing and
                // controller-ID failures still invalidate the connection attempt.
                if characteristic.uuid != Self.geoUUID {
                    self.state = .failed(error.localizedDescription)
                    return
                }
                self.drainWrites(peripheral)
                return
            }
            if characteristic.uuid == Self.idUUID {
                self.controllerIDDidWrite(cameraName: peripheral.name ?? "Nikon") {
                    self.retireConnection(peripheral)
                    self.clearConnectionState()
                }
            }
            if self.acceptsCallback(from: peripheral) { self.drainWrites(peripheral) }
        }
    }
}
