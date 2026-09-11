import Foundation
import CoreBluetooth

/// CoreBluetooth-only I/O. A fresh driver/central is required for every connection generation;
/// peripheral UUIDs are installation-local candidates, not Android MAC addresses or Nikon identity.
@MainActor final class AppleNikonGpsGattDriver: NSObject, NikonGpsGattDriver, CBCentralManagerDelegate, CBPeripheralDelegate {
    var eventHandler: ((GpsGattDriverEvent) -> Void)?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var characteristics: [GpsGattChannel: CBCharacteristic] = [:]
    private var waitingSubscription: GpsGattChannel?
    private var wantsScan = false
    private var closed = false
    private var ready = false
    static let service = CBUUID(string: "0000de00-3dd4-4255-8d62-6dc7b9bd5561")
    static func uuid(_ channel: GpsGattChannel) -> CBUUID {
        let part: String
        switch channel {
        case .pair: part = "2000"
        case .notification: part = "2008"
        case .controllerId: part = "2002"
        case .geo: part = "2007"
        }
        return CBUUID(string: "0000\(part)-3dd4-4255-8d62-6dc7b9bd5561")
    }

    func scan() {
        guard central == nil, !closed else { eventHandler?(.failed(GpsGattError.invalidState)); return }
        wantsScan = true
        // Construction and scanning only happen after an explicit user action, never at launch.
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    func stopScan() { wantsScan = false; central?.stopScan() }
    func connect(_ identifier: UUID) {
        guard !closed, peripheral == nil, let central, central.state == .poweredOn,
              let selected = discovered[identifier] else { eventHandler?(.failed(GpsGattError.unknownDevice)); return }
        stopScan()
        peripheral = selected
        selected.delegate = self
        central.connect(selected, options: nil)
    }
    func write(_ data: Data, channel: GpsGattChannel) {
        guard !closed, ready, let peripheral, let characteristic = characteristics[channel],
              characteristic.properties.contains(.write) else { eventHandler?(.failed(GpsGattError.invalidState)); return }
        guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            eventHandler?(.failed(GpsGattError.payloadTooLarge)); return
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }
    func close() {
        guard !closed else { return }
        closed = true; wantsScan = false; ready = false
        central?.stopScan()
        peripheral?.delegate = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.delegate = nil
        peripheral = nil; central = nil; discovered.removeAll(); characteristics.removeAll()
        waitingSubscription = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !closed, central === self.central else { return }
        switch central.state {
        case .poweredOn:
            guard wantsScan else { return }
            central.scanForPeripherals(withServices: [Self.service],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            eventHandler?(.scanning)
        case .unknown, .resetting:
            // Resetting invalidates discovered services/peripherals. Do not reuse an active owner.
            if peripheral != nil { eventHandler?(.failed(GpsGattError.unavailable)) }
        case .poweredOff, .unauthorized, .unsupported: eventHandler?(.failed(GpsGattError.unavailable))
        @unknown default: eventHandler?(.failed(GpsGattError.unavailable))
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !closed, wantsScan, central === self.central else { return }
        guard discovered[peripheral.identifier] != nil || discovered.count < 64 else { return }
        discovered[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Nikon"
        eventHandler?(.candidate(GpsBluetoothCandidate(id: peripheral.identifier, name: String(name.prefix(128)), rssi: RSSI.intValue)))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard owns(central, peripheral) else { return }
        peripheral.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard owns(central, peripheral) else { return }
        eventHandler?(.failed(error ?? GpsGattError.disconnected))
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard owns(central, peripheral) else { return }
        eventHandler?(.failed(error ?? GpsGattError.disconnected))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard owns(peripheral) else { return }
        if let error { eventHandler?(.failed(error)); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            eventHandler?(.failed(GpsGattError.missingService)); return
        }
        peripheral.discoverCharacteristics(GpsGattChannel.allCases.map(Self.uuid), for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard owns(peripheral), service.uuid == Self.service else { return }
        if let error { eventHandler?(.failed(error)); return }
        for channel in GpsGattChannel.allCases {
            guard let value = service.characteristics?.first(where: { $0.uuid == Self.uuid(channel) }) else {
                eventHandler?(.failed(GpsGattError.missingCharacteristic)); return
            }
            characteristics[channel] = value
        }
        guard let pair = characteristics[.pair], pair.properties.contains(.indicate),
              characteristics[.notification]?.properties.contains(.notify) == true,
              [GpsGattChannel.pair, .controllerId, .geo].allSatisfy({ characteristics[$0]?.properties.contains(.write) == true }) else {
            eventHandler?(.failed(GpsGattError.notificationUnavailable)); return
        }
        // Android enables PAIR indications then NOT1 notifications. CoreBluetooth owns CCCD writes;
        // never write 0x2902 manually. If both notify/indicate are advertised, the OS choice needs
        // real-camera verification; setNotifyValue does not expose Android's descriptor-byte switch.
        waitingSubscription = .pair
        peripheral.setNotifyValue(true, for: pair)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard owns(peripheral) else { return }
        if ready, let channel = channel(for: characteristic), channel == .pair || channel == .notification {
            if error != nil || !characteristic.isNotifying { eventHandler?(.failed(error ?? GpsGattError.notificationUnavailable)) }
            return
        }
        guard let waiting = waitingSubscription,
              characteristics[waiting] === characteristic else { return }
        if let error { eventHandler?(.failed(error)); return }
        guard characteristic.isNotifying else { eventHandler?(.failed(GpsGattError.notificationUnavailable)); return }
        if waiting == .pair, let next = characteristics[.notification] {
            waitingSubscription = .notification
            peripheral.setNotifyValue(true, for: next)
        } else {
            waitingSubscription = nil; ready = true
            eventHandler?(.ready(maximumWriteLength: peripheral.maximumWriteValueLength(for: .withResponse)))
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard owns(peripheral), let channel = channel(for: characteristic),
              channel == .pair || channel == .notification else { return }
        if let error { eventHandler?(.failed(error)); return }
        guard let value = characteristic.value else { return }
        eventHandler?(.value(channel, value))
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard owns(peripheral), let channel = channel(for: characteristic) else { return }
        eventHandler?(.written(channel, error))
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard owns(peripheral), invalidatedServices.contains(where: { $0.uuid == Self.service }) else { return }
        eventHandler?(.failed(GpsGattError.missingService))
    }
    private func channel(for characteristic: CBCharacteristic) -> GpsGattChannel? {
        GpsGattChannel.allCases.first { characteristics[$0] === characteristic }
    }
    private func owns(_ peripheral: CBPeripheral) -> Bool { !closed && peripheral === self.peripheral }
    private func owns(_ central: CBCentralManager, _ peripheral: CBPeripheral) -> Bool {
        central === self.central && owns(peripheral)
    }
}
