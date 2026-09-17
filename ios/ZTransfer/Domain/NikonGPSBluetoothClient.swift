@preconcurrency import CoreBluetooth
import Combine
import Foundation

enum NikonGPSBluetoothState: Equatable, Sendable {
    case unauthorized
    case unavailable
    case scanning
    case connecting(String)
    case pairing
    case ready(String)
    case disconnected
    case failed(String)
}

private struct RestoredBluetoothPeripheral: @unchecked Sendable {
    let value: CBPeripheral?
}

/// CoreBluetooth counterpart of Android's NikonGpsBleClient.  All GATT writes
/// are serialized through CoreBluetooth's callback order; no parallel writes
/// are issued to the camera characteristics.
@MainActor
final class NikonGPSBluetoothClient: NSObject, ObservableObject {
    @Published private(set) var state: NikonGPSBluetoothState = .disconnected
    @Published private(set) var peripheralIdentifier: UUID?

    private var central: CBCentralManager!
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
    private var controllerName = "ZTransfer"
    private struct QueuedWrite {
        let characteristic: CBCharacteristic
        let data: Data
        let completion: ((Bool) -> Void)?
    }
    private var writeQueue: [QueuedWrite] = []
    private var writeInFlight = false
    private var notificationsReady = Set<CBUUID>()
    private var pairingTimeout: Task<Void, Never>?
    private var directReconnectTask: Task<Void, Never>?
    private var shouldRun = false
    private let defaults: UserDefaults

    init(controllerName: String = "ZTransfer", savedDevice: UInt32? = nil, savedNonce: UInt32? = nil, defaults: UserDefaults? = nil) {
        self.controllerName = controllerName
        let storage = defaults ?? UserDefaults(suiteName: GPSPreferences.suiteName)!
        self.defaults = storage
        // Migrate the short-lived pre-namespace keys once. New reads/writes
        // always use the Android-compatible nikon_gps keys.
        if storage.object(forKey: GPSPreferences.deviceID) == nil,
           let legacy = UserDefaults.standard.object(forKey: "gps.pairing.device") {
            storage.set(legacy, forKey: GPSPreferences.deviceID)
        }
        if storage.object(forKey: GPSPreferences.nonce) == nil,
           let legacy = UserDefaults.standard.object(forKey: "gps.pairing.nonce") {
            storage.set(legacy, forKey: GPSPreferences.nonce)
        }
        let storedDevice = (storage.object(forKey: GPSPreferences.deviceID) as? NSNumber).map { $0.uint32Value }
        let storedNonce = (storage.object(forKey: GPSPreferences.nonce) as? NSNumber).map { $0.uint32Value }
        if (storedDevice == nil) != (storedNonce == nil) {
            // Android discards an incomplete identity instead of attempting a
            // direct reconnect with only one half of the pairing tuple.
            storage.removeObject(forKey: GPSPreferences.deviceID)
            storage.removeObject(forKey: GPSPreferences.nonce)
            storage.removeObject(forKey: GPSPreferences.bleAddress)
        }
        self.savedDevice = savedDevice ?? ((storedDevice != nil && storedNonce != nil) ? storedDevice : nil)
        self.savedNonce = savedNonce ?? ((storedDevice != nil && storedNonce != nil) ? storedNonce : nil)
        self.savedPeripheralIdentifier = storage.string(forKey: GPSPreferences.bleAddress)
            .flatMap(UUID.init(uuidString:))
        super.init()
        #if targetEnvironment(simulator)
        // CoreBluetooth rejects restoration identifiers in the simulator.
        central = CBCentralManager(delegate: self, queue: .main)
        #else
        // CoreBluetooth validates the state-restoration delegate during
        // initialization, so the delegate must be supplied here rather than
        // assigned afterward.
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.ztransfer.nikon-gps"],
        )
        #endif
    }

    func start() {
        shouldRun = true
        GPSDiagnostics.record("BLE start savedIdentity=\(savedDevice != nil && savedNonce != nil)")
        directReconnectTask?.cancel()
        directReconnectTask = nil
        if central.state == .unknown || central.state == .resetting { return }
        guard central.state == .poweredOn else {
            GPSDiagnostics.record("Bluetooth adapter unavailable")
            state = central.state == .unauthorized ? .unauthorized : .unavailable
            return
        }
        guard peripheral == nil else { return }
        // Android's service first attempts the saved BLE address, then falls
        // back to a filtered scan when the camera is unavailable. CoreBluetooth
        // exposes the equivalent through a persisted peripheral UUID.
        if savedDevice != nil, savedNonce != nil,
           let savedPeripheralIdentifier,
           let remembered = central.retrievePeripherals(withIdentifiers: [savedPeripheralIdentifier]).first {
            peripheral = remembered
            peripheralIdentifier = remembered.identifier
            state = .connecting(remembered.name ?? "Nikon")
            remembered.delegate = self
            central.connect(remembered)
            let rememberedID = remembered.identifier
            directReconnectTask = Task { [weak self, weak remembered] in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard let self, let remembered, !Task.isCancelled,
                      self.peripheral?.identifier == rememberedID,
                      self.state == .connecting(remembered.name ?? "Nikon") else { return }
                self.central.cancelPeripheralConnection(remembered)
                self.clearConnectionState()
                self.beginScan()
            }
        } else {
            beginScan()
        }
    }

    private func beginScan() {
        directReconnectTask?.cancel()
        directReconnectTask = nil
        state = .scanning
        GPSDiagnostics.record("BLE scan started")
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stop() {
        shouldRun = false
        GPSDiagnostics.record("BLE stopped")
        directReconnectTask?.cancel()
        directReconnectTask = nil
        pairingTimeout?.cancel(); pairingTimeout = nil
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        clearConnectionState()
        state = .disconnected
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

    var hasSavedPairing: Bool { savedDevice != nil && savedNonce != nil }

    func clearPairing() {
        GPSDiagnostics.record("cached pairing identity cleared")
        defaults.removeObject(forKey: GPSPreferences.deviceID)
        defaults.removeObject(forKey: GPSPreferences.nonce)
        defaults.removeObject(forKey: GPSPreferences.bleAddress)
        UserDefaults.standard.removeObject(forKey: "gps.pairing.device")
        UserDefaults.standard.removeObject(forKey: "gps.pairing.nonce")
        savedDevice = nil
        savedNonce = nil
        stop()
    }

    private func clearConnectionState() {
        peripheral = nil; pairCharacteristic = nil; idCharacteristic = nil; geoCharacteristic = nil
        stage1 = nil; stage3Sent = false; idQueued = false
        let abandoned = writeQueue
        writeQueue.removeAll(); writeInFlight = false
        abandoned.forEach { $0.completion?(false) }
        notificationsReady.removeAll()
    }

    private func enqueueWrite(peripheral: CBPeripheral, characteristic: CBCharacteristic,
                              data: Data, completion: ((Bool) -> Void)? = nil) {
        writeQueue.append(.init(characteristic: characteristic, data: data, completion: completion))
        drainWrites(peripheral)
    }

    private func drainWrites(_ peripheral: CBPeripheral) {
        guard !writeInFlight, let next = writeQueue.first else { return }
        writeInFlight = true
        peripheral.writeValue(next.data, for: next.characteristic, type: .withResponse)
    }

    private func beginPairing(_ peripheral: CBPeripheral) {
        guard let pairCharacteristic else { return }
        let restoringIdentity = savedDevice != nil && savedNonce != nil
        stage1 = NikonGPSPairingProtocol().newStage1(deviceOverride: savedDevice, nonceOverride: savedNonce)
        if let stage1 {
            // A newly generated identity becomes the active identity in this
            // same handshake. Keeping it only in UserDefaults made the first
            // ID acknowledgement look unpaired until the app was restarted.
            savedDevice = stage1.device
            savedNonce = stage1.nonce
            defaults.set(stage1.device, forKey: GPSPreferences.deviceID)
            defaults.set(stage1.nonce, forKey: GPSPreferences.nonce)
        }
        stage3Sent = false; idQueued = false
        GPSDiagnostics.record("BLE pairing handshake")
        if !restoringIdentity { state = .pairing }
        pairingTimeout?.cancel()
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard let self, !Task.isCancelled, !self.idQueued else { return }
            self.state = .failed(restoringIdentity ? "Camera pairing identity expired" : "Camera pairing handshake timeout")
        }
        enqueueWrite(peripheral: peripheral, characteristic: pairCharacteristic, data: stage1!.encode())
    }

    private func handlePairingValue(_ value: Data, peripheral: CBPeripheral) {
        if value == Data([0x01, 0x00]) {
            GPSDiagnostics.record("pairing stage4 received")
            queueControllerID(peripheral); return
        }
        guard let packet = NikonGPSPairingPacket.decode(value), let first = stage1 else { return }
        if packet.stage == 2 && !stage3Sent {
            guard let response = NikonGPSPairingProtocol().stage3(for: first, stage2: packet), let pairCharacteristic else {
                state = .failed("Camera pairing rejected"); return
            }
            pairingTimeout?.cancel(); stage3Sent = true
            GPSDiagnostics.record("pairing stage3 sent")
            enqueueWrite(peripheral: peripheral, characteristic: pairCharacteristic, data: response.encode())
            pairingTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard let self, !Task.isCancelled, !self.idQueued else { return }
                self.state = .failed("Camera pairing handshake timeout")
            }
        } else if packet.stage == 4 {
            pairingTimeout?.cancel()
            Task { [weak self, weak peripheral] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, let peripheral, !Task.isCancelled else { return }
                self.queueControllerID(peripheral)
            }
        }
    }

    private func queueControllerID(_ peripheral: CBPeripheral) {
        guard !idQueued, let idCharacteristic else { return }
        idQueued = true; pairingTimeout?.cancel()
        GPSDiagnostics.record("ID queued")
        var data = Data(controllerName.prefix(32).utf8)
        data.append(contentsOf: repeatElement(0, count: max(0, 32 - data.count)))
        enqueueWrite(peripheral: peripheral, characteristic: idCharacteristic, data: data)
    }

    private static let serviceUUID = CBUUID(string: "0000DE00-3DD4-4255-8D62-6DC7B9BD5561")
    private static let pairUUID = CBUUID(string: "00002000-3DD4-4255-8D62-6DC7B9BD5561")
    private static let not1UUID = CBUUID(string: "00002008-3DD4-4255-8D62-6DC7B9BD5561")
    private static let idUUID = CBUUID(string: "00002002-3DD4-4255-8D62-6DC7B9BD5561")
    private static let geoUUID = CBUUID(string: "00002007-3DD4-4255-8D62-6DC7B9BD5561")
}

extension NikonGPSBluetoothClient: CBCentralManagerDelegate {
    nonisolated func centralManager(_ central: CBCentralManager,
                                    willRestoreState dict: [String: Any]) {
        let restoredBox = RestoredBluetoothPeripheral(
            value: (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        )
        MainActor.assumeIsolated { [weak self] in
            guard let self, let restored = restoredBox.value else { return }
            guard self.defaults.bool(forKey: GPSPreferences.enabled) else {
                self.central.cancelPeripheralConnection(restored)
                self.state = .disconnected
                return
            }
            self.shouldRun = true
            self.peripheral = restored
            self.peripheralIdentifier = restored.identifier
            self.savedPeripheralIdentifier = restored.identifier
            self.defaults.set(restored.identifier.uuidString, forKey: GPSPreferences.bleAddress)
            restored.delegate = self
            self.state = .connecting(restored.name ?? "Nikon")
            if restored.state == .connected {
                restored.discoverServices([Self.serviceUUID])
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
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
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            self.central.stopScan(); self.peripheral = peripheral; self.peripheralIdentifier = peripheral.identifier
            self.savedPeripheralIdentifier = peripheral.identifier
            self.defaults.set(peripheral.identifier.uuidString, forKey: GPSPreferences.bleAddress)
            self.state = .connecting(peripheral.name ?? "Nikon")
            peripheral.delegate = self; self.central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            self.directReconnectTask?.cancel()
            self.directReconnectTask = nil
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.peripheral?.identifier == peripheral.identifier else { return }
            let wasDirectReconnect = self.savedPeripheralIdentifier == peripheral.identifier &&
                self.state == .connecting(peripheral.name ?? "Nikon")
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
            guard let self, error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { self?.state = .failed("Camera GPS service unavailable"); return }
            self.state = .connecting(peripheral.name ?? "Nikon")
            peripheral.discoverCharacteristics([Self.pairUUID, Self.not1UUID, Self.idUUID, Self.geoUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, error == nil else { self?.state = .failed("Camera GPS service unavailable"); return }
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
            guard let self, error == nil, characteristic.isNotifying else {
                self?.state = .failed("Camera GPS notification unavailable")
                return
            }
            self.notificationsReady.insert(characteristic.uuid)
            self.beginPairingWhenReady(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, error == nil, let value = characteristic.value else { return }
            if characteristic.uuid == Self.pairUUID { self.handlePairingValue(value, peripheral: peripheral) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            self.writeInFlight = false
            let finished = self.writeQueue.isEmpty ? nil : self.writeQueue.removeFirst()
            finished?.completion?(error == nil)
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
                self.pairingTimeout?.cancel()
                if self.savedDevice == nil { self.state = .failed("需要完成蓝牙配对") }
                else {
                    self.state = .ready(peripheral.name ?? "Nikon")
                }
            }
            self.drainWrites(peripheral)
        }
    }
}
