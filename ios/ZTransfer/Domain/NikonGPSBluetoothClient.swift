@preconcurrency import CoreBluetooth
import Combine
import Foundation

enum NikonGPSBluetoothState: Equatable, Sendable {
    case unavailable
    case scanning
    case connecting(String)
    case pairing
    case ready(String)
    case disconnected
    case failed(String)
}

/// CoreBluetooth counterpart of Android's NikonGpsBleClient.  All GATT writes
/// are serialized through CoreBluetooth's callback order; no parallel writes
/// are issued to the camera characteristics.
@MainActor
final class NikonGPSBluetoothClient: NSObject, ObservableObject {
    @Published private(set) var state: NikonGPSBluetoothState = .disconnected
    @Published private(set) var peripheralIdentifier: UUID?

    private let central: CBCentralManager
    private var peripheral: CBPeripheral?
    private var pairCharacteristic: CBCharacteristic?
    private var idCharacteristic: CBCharacteristic?
    private var geoCharacteristic: CBCharacteristic?
    private var stage1: NikonGPSPairingPacket?
    private var stage3Sent = false
    private var idQueued = false
    private var savedDevice: UInt32?
    private var savedNonce: UInt32?
    private var controllerName = "ZTransfer"
    private var pendingGeo: Data?
    private var writeQueue: [(CBCharacteristic, Data)] = []
    private var writeInFlight = false
    private var notificationsReady = Set<CBUUID>()
    private var pairingTimeout: Task<Void, Never>?
    private let defaults: UserDefaults

    init(controllerName: String = "ZTransfer", savedDevice: UInt32? = nil, savedNonce: UInt32? = nil, defaults: UserDefaults = .standard) {
        self.controllerName = controllerName
        self.defaults = defaults
        self.savedDevice = savedDevice ?? (defaults.object(forKey: "gps.pairing.device") as? NSNumber).map { $0.uint32Value }
        self.savedNonce = savedNonce ?? (defaults.object(forKey: "gps.pairing.nonce") as? NSNumber).map { $0.uint32Value }
        central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        central.delegate = self
    }

    func start() {
        guard central.state == .poweredOn else {
            state = central.state == .unauthorized || central.state == .unsupported ? .unavailable : .failed("Bluetooth unavailable")
            return
        }
        guard peripheral == nil else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stop() {
        pairingTimeout?.cancel(); pairingTimeout = nil
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        clearConnectionState()
        state = .disconnected
    }

    func writeGeo(_ data: Data) {
        guard let peripheral, let characteristic = geoCharacteristic else { pendingGeo = data; return }
        enqueueWrite(peripheral: peripheral, characteristic: characteristic, data: data)
    }

    var hasSavedPairing: Bool { savedDevice != nil && savedNonce != nil }

    func clearPairing() {
        defaults.removeObject(forKey: "gps.pairing.device")
        defaults.removeObject(forKey: "gps.pairing.nonce")
        savedDevice = nil
        savedNonce = nil
        stop()
    }

    private func clearConnectionState() {
        peripheral = nil; pairCharacteristic = nil; idCharacteristic = nil; geoCharacteristic = nil
        stage1 = nil; stage3Sent = false; idQueued = false; pendingGeo = nil
        writeQueue.removeAll(); writeInFlight = false
        notificationsReady.removeAll()
    }

    private func enqueueWrite(peripheral: CBPeripheral, characteristic: CBCharacteristic, data: Data) {
        writeQueue.append((characteristic, data)); drainWrites(peripheral)
    }

    private func drainWrites(_ peripheral: CBPeripheral) {
        guard !writeInFlight, let next = writeQueue.first else { return }
        writeInFlight = true
        peripheral.writeValue(next.1, for: next.0, type: .withResponse)
    }

    private func beginPairing(_ peripheral: CBPeripheral) {
        guard let pairCharacteristic else { return }
        stage1 = NikonGPSPairingProtocol().newStage1(deviceOverride: savedDevice, nonceOverride: savedNonce)
        if let stage1 {
            defaults.set(stage1.device, forKey: "gps.pairing.device")
            defaults.set(stage1.nonce, forKey: "gps.pairing.nonce")
        }
        stage3Sent = false; idQueued = false
        if savedDevice == nil { state = .pairing }
        pairingTimeout?.cancel()
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard let self, !Task.isCancelled, !self.idQueued else { return }
            self.state = .failed(savedDevice == nil ? "Camera pairing handshake timeout" : "Camera pairing identity expired")
        }
        enqueueWrite(peripheral: peripheral, characteristic: pairCharacteristic, data: stage1!.encode())
    }

    private func handlePairingValue(_ value: Data, peripheral: CBPeripheral) {
        if value == Data([0x01, 0x00]) { queueControllerID(peripheral); return }
        guard let packet = NikonGPSPairingPacket.decode(value), let first = stage1 else { return }
        if packet.stage == 2 && !stage3Sent {
            guard let response = NikonGPSPairingProtocol().stage3(for: first, stage2: packet), let pairCharacteristic else {
                state = .failed("Camera pairing rejected"); return
            }
            pairingTimeout?.cancel(); stage3Sent = true
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
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            if central.state == .poweredOn { self.start() } else { self.state = .unavailable }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            self.central.stopScan(); self.peripheral = peripheral; self.peripheralIdentifier = peripheral.identifier
            self.state = .connecting(peripheral.name ?? "Nikon")
            peripheral.delegate = self; self.central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { peripheral.discoverServices([Self.serviceUUID]) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.peripheral?.identifier == peripheral.identifier else { return }
            self.clearConnectionState(); self.state = error.map { .failed($0.localizedDescription) } ?? .disconnected
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
            if !self.writeQueue.isEmpty { self.writeQueue.removeFirst() }
            if let error { self.state = .failed(error.localizedDescription); return }
            if characteristic.uuid == Self.idUUID {
                self.pairingTimeout?.cancel()
                if self.savedDevice == nil { self.state = .failed("需要完成蓝牙配对") }
                else {
                    self.state = .ready(peripheral.name ?? "Nikon")
                    if let pending = self.pendingGeo, let geo = self.geoCharacteristic {
                        self.pendingGeo = nil
                        self.enqueueWrite(peripheral: peripheral, characteristic: geo, data: pending)
                    }
                }
            }
            self.drainWrites(peripheral)
        }
    }
}
