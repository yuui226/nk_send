@preconcurrency import CoreLocation
import Combine
import Foundation

/// Coordinates the Android-equivalent GPS lifecycle: location permission/fix,
/// Nikon BLE connection and throttled GEO writes.  The AP conflict is surfaced
/// by the caller instead of silently changing the selected connection mode.
@MainActor
final class GPSCoordinator: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var state = GPSState()
    @Published private(set) var frequency: GPSUpdateFrequency
    let bluetooth: NikonGPSBluetoothClient
    private let locationManager = CLLocationManager()
    private let defaults: UserDefaults
    private var lastWrite: Date?
    private var writeTask: Task<Void, Never>?
    private var bluetoothObservation: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.integer(forKey: "gps.updateFrequency")
        frequency = GPSUpdateFrequency(rawValue: raw) ?? .defaultValue
        bluetooth = NikonGPSBluetoothClient()
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        bluetoothObservation = bluetooth.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.applyBluetoothState(value) }
    }

    deinit { writeTask?.cancel(); locationManager.stopUpdatingLocation() }

    func setFrequency(_ value: GPSUpdateFrequency) {
        guard value != frequency else { return }
        frequency = value
        defaults.set(value.rawValue, forKey: "gps.updateFrequency")
    }

    func setEnabled(_ enabled: Bool) {
        writeTask?.cancel(); writeTask = nil
        guard enabled else {
            locationManager.stopUpdatingLocation(); bluetooth.stop(); state = GPSState(); lastWrite = nil; return
        }
        state = GPSState(enabled: true, status: .starting)
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: beginRunning()
        default: state = GPSState(enabled: true, status: .error, message: "需要定位权限")
        }
    }

    func retry() { guard state.enabled else { return }; beginRunning() }

    private func beginRunning() {
        locationManager.startUpdatingLocation()
        state.status = .searching
        bluetooth.start()
    }

    private func applyBluetoothState(_ value: NikonGPSBluetoothState) {
        guard state.enabled else { return }
        switch value {
        case .unavailable: state.status = .error; state.message = "请打开手机蓝牙"
        case .scanning: state.status = .searching; state.message = nil
        case .connecting(let name): state.status = .connecting; state.cameraName = name
        case .pairing: state.status = .pairing
        case .ready(let name):
            state.cameraName = name
            state.status = state.latitude == nil ? .connected : .ready
            if state.latitude != nil { scheduleWriteIfDue() }
        case .disconnected: state.status = .searching
        case .failed(let message): state.status = .error; state.message = message
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard state.enabled else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: beginRunning()
        case .denied, .restricted: state.status = .error; state.message = "需要定位权限"
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        state.latitude = location.coordinate.latitude
        state.longitude = location.coordinate.longitude
        state.altitudeMeters = location.verticalAccuracy >= 0 ? location.altitude : nil
        state.accuracyMeters = location.horizontalAccuracy
        if case .ready = bluetooth.state {
            state.status = .connected
            scheduleWriteIfDue()
        } else if state.status == .searching || state.status == .starting {
            state.status = .waitingFix
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard state.enabled else { return }
        state.status = .error; state.message = "无法获取定位"
    }

    private func scheduleWriteIfDue() {
        guard writeTask == nil else { return }
        let elapsed = lastWrite.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let wait = max(0, Double(frequency.rawValue) - elapsed)
        writeTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.writeCurrentFix()
        }
    }

    private func writeCurrentFix() {
        writeTask = nil
        guard state.enabled, let latitude = state.latitude, let longitude = state.longitude else { state.status = .waitingFix; return }
        guard case .ready = bluetooth.state else { return }
        state.status = .writing
        guard let payload = NikonGeoPayloadEncoder.encode(
            latitude: latitude,
            longitude: longitude,
            altitudeMeters: state.altitudeMeters ?? 0,
            satellites: 0,
            timestamp: Date()
        ) else {
            state.status = .error
            state.message = "GPS 写入失败"
            return
        }
        bluetooth.writeGeo(payload)
        lastWrite = Date(); state.lastSentAt = lastWrite; state.status = .ready
    }
}
