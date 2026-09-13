@preconcurrency import CoreLocation
import Combine
import Foundation

/// Coordinates the Android-equivalent GPS lifecycle: location permission/fix,
/// Nikon BLE connection and throttled GEO writes.  The AP conflict is surfaced
/// by the caller instead of silently changing the selected connection mode.
@MainActor
final class GPSCoordinator: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var state = GPSState()
    @Published private(set) var connectionHelpViewed = false
    @Published private(set) var frequency: GPSUpdateFrequency
    let bluetooth: NikonGPSBluetoothClient
    private let locationManager = CLLocationManager()
    private let defaults: UserDefaults
    private var lastWrite: Date?
    private var writeTask: Task<Void, Never>?
    private var bluetoothObservation: AnyCancellable?
    private var awaitingPairingAction = false

    init(defaults: UserDefaults? = nil) {
        let storage = defaults ?? UserDefaults(suiteName: GPSPreferences.suiteName)!
        self.defaults = storage
        let raw = storage.integer(forKey: GPSPreferences.updateFrequencySeconds)
        frequency = GPSUpdateFrequency(rawValue: raw) ?? .defaultValue
        bluetooth = NikonGPSBluetoothClient(defaults: storage)
        super.init()
        let enabled = storage.bool(forKey: GPSPreferences.enabled)
        state = GPSState(enabled: enabled, status: enabled ? .starting : .off)
        connectionHelpViewed = storage.bool(forKey: GPSPreferences.connectionHelpViewed)
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        bluetoothObservation = bluetooth.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.applyBluetoothState(value) }
        if enabled {
            // Android's foreground service restores an enabled GPS session on
            // process restart. Defer until NSObject/CoreLocation setup is done.
            Task { @MainActor [weak self] in self?.beginRunning() }
        }
    }

    deinit { writeTask?.cancel(); locationManager.stopUpdatingLocation() }

    func setFrequency(_ value: GPSUpdateFrequency) {
        guard value != frequency else { return }
        frequency = value
        defaults.set(value.rawValue, forKey: GPSPreferences.updateFrequencySeconds)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: GPSPreferences.enabled)
        awaitingPairingAction = false
        writeTask?.cancel(); writeTask = nil
        guard enabled else {
            locationManager.stopUpdatingLocation(); bluetooth.stop(); state = GPSState(); lastWrite = nil; return
        }
        state = GPSState(enabled: true, status: .starting)
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: beginRunning()
        default: state = GPSState(
            enabled: true,
            status: .error,
            message: AppLocalized.resource("gps_permission_required")
        )
        }
    }

    func retry() {
        guard state.enabled else { return }
        awaitingPairingAction = false
        beginRunning()
    }

    /// Matches GpsViewModel.clearPairing(): remove all camera identity data and
    /// turn the runtime off when a session is active.
    func clearPairing() {
        if state.enabled { setEnabled(false) }
        bluetooth.clearPairing()
    }

    func markConnectionHelpViewed() {
        guard !connectionHelpViewed else { return }
        defaults.set(true, forKey: GPSPreferences.connectionHelpViewed)
        connectionHelpViewed = true
    }

    private func beginRunning() {
        locationManager.startUpdatingLocation()
        state.status = .searching
        bluetooth.start()
    }

    private func applyBluetoothState(_ value: NikonGPSBluetoothState) {
        guard state.enabled else { return }
        switch value {
        case .unavailable:
            state.status = .error
            state.message = AppLocalized.resource("gps_bluetooth_required")
        case .scanning: state.status = .searching; state.message = nil
        case .connecting(let name): state.status = .connecting; state.cameraName = name
        case .pairing: state.status = .pairing
        case .ready(let name):
            state.cameraName = name
            state.status = state.latitude == nil ? .connected : .ready
            if state.latitude != nil { scheduleWriteIfDue() }
        case .disconnected:
            if !awaitingPairingAction { state.status = .searching }
        case .failed(let message): applyBluetoothFailure(message)
        }
    }

    /// Mirrors NikonGpsService.handleBleError's ordered message mapping. The
    /// BLE client may report protocol/transport English strings, but Android
    /// converts the user-visible result into a camera-action state first.
    private func applyBluetoothFailure(_ message: String) {
        let lowercased = message.lowercased()
        if lowercased.contains("pairing rejected") ||
            lowercased.contains("identity expired") ||
            lowercased.contains("not found") ||
            lowercased.contains("pairing") ||
            message.contains("配对") {
            defaults.removeObject(forKey: GPSPreferences.deviceID)
            defaults.removeObject(forKey: GPSPreferences.nonce)
            defaults.removeObject(forKey: GPSPreferences.bleAddress)
            awaitingPairingAction = true
            bluetooth.stop()
            state.status = .needsCamera
            state.message = "请在相机上打开蓝牙配对"
        } else if lowercased.contains("bluetooth unavailable") ||
                    lowercased.contains("scan failed") {
            state.status = .error
            state.message = "请打开手机蓝牙"
        } else {
            state.status = .error
            state.message = message
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard state.enabled else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: beginRunning()
        case .denied, .restricted:
            state.status = .error
            state.message = AppLocalized.resource("gps_permission_required")
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
