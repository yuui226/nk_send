@preconcurrency import CoreLocation
import Combine
import Foundation

/// Coordinates the Android-equivalent GPS lifecycle: location permission/fix,
/// Nikon BLE connection and throttled GEO writes.  The AP conflict is surfaced
/// by the caller instead of silently changing the selected connection mode.
@MainActor
final class GPSCoordinator: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var state = GPSState()
    @Published private(set) var placeLookupState = GPSPlaceLookupState.idle
    @Published private(set) var connectionHelpViewed = false
    @Published private(set) var frequency: GPSUpdateFrequency
    let bluetooth: NikonGPSBluetoothClient
    private let locationManager = CLLocationManager()
    private let defaults: UserDefaults
    private var lastWrite: Date?
    private var writeTask: Task<Void, Never>?
    private var bluetoothObservation: AnyCancellable?
    private var awaitingPairingAction = false
    private var apModeBlocked = false
    private var placeCache: [String: String] = [:]
    private var placeCacheOrder: [String] = []
    private var placeRequestID = 0
    private var placeGeocoder: CLGeocoder?

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

    deinit {
        writeTask?.cancel()
        placeGeocoder?.cancelGeocode()
        locationManager.stopUpdatingLocation()
    }

    func setFrequency(_ value: GPSUpdateFrequency) {
        guard value != frequency else { return }
        frequency = value
        defaults.set(value.rawValue, forKey: GPSPreferences.updateFrequencySeconds)
        GPSDiagnostics.record("update frequency=\(value.rawValue)s")
    }

    func setEnabled(_ enabled: Bool) {
        GPSDiagnostics.record("set enabled=\(enabled)")
        defaults.set(enabled, forKey: GPSPreferences.enabled)
        awaitingPairingAction = false
        writeTask?.cancel(); writeTask = nil
        guard enabled else {
            locationManager.stopUpdatingLocation(); bluetooth.stop(); state = GPSState(); lastWrite = nil; return
        }
        state = GPSState(enabled: true, status: .starting)
        guard !apModeBlocked else {
            state.status = .apUnavailable
            state.message = AppLocalized.resource("gps_ap_unavailable")
            return
        }
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
        GPSDiagnostics.record("retry status=\(state.status.rawValue)")
        guard !apModeBlocked else {
            state.status = .apUnavailable
            state.message = AppLocalized.resource("gps_ap_unavailable")
            return
        }
        awaitingPairingAction = false
        beginRunning()
    }

    /// Android's HomeScreen informs the GPS foreground service whenever an AP
    /// camera session is connected. GPS remains enabled in preferences, but
    /// its active BLE/location session is stopped until the AP session ends.
    func setAPModeBlocked(_ blocked: Bool) {
        guard apModeBlocked != blocked else { return }
        GPSDiagnostics.record("AP mode blocked=\(blocked)")
        apModeBlocked = blocked
        if blocked {
            writeTask?.cancel(); writeTask = nil
            locationManager.stopUpdatingLocation()
            bluetooth.stop()
            guard state.enabled else { return }
            state.status = .apUnavailable
            state.message = AppLocalized.resource("gps_ap_unavailable")
        } else if state.enabled {
            state.message = nil
            state.status = .starting
            beginRunning()
        }
    }

    /// Matches GpsViewModel.clearPairing(): remove all camera identity data and
    /// turn the runtime off when a session is active.
    func clearPairing() {
        GPSDiagnostics.record("clear pairing")
        if state.enabled { setEnabled(false) }
        bluetooth.clearPairing()
    }

    func markConnectionHelpViewed() {
        guard !connectionHelpViewed else { return }
        defaults.set(true, forKey: GPSPreferences.connectionHelpViewed)
        connectionHelpViewed = true
    }

    /// Android's GpsViewModel resolves one-shot place names through an
    /// eight-entry LRU cache keyed by a roughly 100 m coordinate cell and the
    /// active locale. A new request cancels the old one so a late geocoder
    /// callback can never replace the result for a newer coordinate. Android
    /// leaves the platform geocoder's completion timing unchanged, so this
    /// adapter deliberately does not add an iOS-only timeout.
    func lookupPlaceName(latitude: Double, longitude: Double) {
        placeRequestID += 1
        let requestID = placeRequestID
        placeGeocoder?.cancelGeocode()
        placeGeocoder = nil
        guard latitude.isFinite, latitude >= -90, latitude <= 90,
              longitude.isFinite, longitude >= -180, longitude <= 180 else {
            placeLookupState = GPSPlaceLookupState(
                latitude: latitude, longitude: longitude, status: .error, placeName: nil,
            )
            return
        }

        let key = placeCacheKey(latitude: latitude, longitude: longitude)
        if let cached = placeCache[key] {
            touchPlaceCache(key)
            placeLookupState = GPSPlaceLookupState(
                latitude: latitude, longitude: longitude, status: .success, placeName: cached,
            )
            return
        }

        placeLookupState = GPSPlaceLookupState(
            latitude: latitude, longitude: longitude, status: .loading, placeName: nil,
        )
        let geocoder = CLGeocoder()
        placeGeocoder = geocoder
        geocoder.reverseGeocodeLocation(
            CLLocation(latitude: latitude, longitude: longitude),
        ) { [weak self] placemarks, _ in
            Task { @MainActor [weak self] in
                guard let self, self.placeRequestID == requestID else { return }
                let name = placemarks?.first.flatMap(Self.bestPlaceName)
                self.finishPlaceLookup(
                    requestID: requestID, key: key,
                    latitude: latitude, longitude: longitude, name: name,
                )
            }
        }
    }

    func cancelPlaceLookup() {
        placeRequestID += 1
        placeGeocoder?.cancelGeocode(); placeGeocoder = nil
        placeLookupState = .idle
    }

    @discardableResult
    private func finishPlaceLookup(
        requestID: Int,
        key: String,
        latitude: Double,
        longitude: Double,
        name: String?,
    ) {
        guard placeRequestID == requestID else { return }
        placeGeocoder = nil
        if let name, !name.isEmpty {
            placeCache[key] = name
            touchPlaceCache(key)
            while placeCacheOrder.count > 8 {
                let evicted = placeCacheOrder.removeFirst()
                placeCache.removeValue(forKey: evicted)
            }
        }
        placeLookupState = GPSPlaceLookupState(
            latitude: latitude,
            longitude: longitude,
            status: name == nil ? .error : .success,
            placeName: name,
        )
        // Invalidate any late callback from this request after the result has
        // been committed, matching the Android request-id guard.
        placeRequestID += 1
    }

    private func placeCacheKey(latitude: Double, longitude: Double) -> String {
        let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let coordinate = String(
            format: "%.3f,%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            latitude,
            longitude,
        )
        return "\(locale)|\(coordinate)"
    }

    private func touchPlaceCache(_ key: String) {
        placeCacheOrder.removeAll { $0 == key }
        placeCacheOrder.append(key)
    }

    private static func bestPlaceName(_ placemark: CLPlacemark) -> String? {
        let values: [String?] = [
            placemark.name,
            placemark.thoroughfare,
            placemark.locality,
            placemark.subLocality,
            placemark.administrativeArea,
        ]
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func beginRunning() {
        guard !apModeBlocked else {
            state.status = .apUnavailable
            state.message = AppLocalized.resource("gps_ap_unavailable")
            return
        }
        locationManager.startUpdatingLocation()
        state.status = .searching
        GPSDiagnostics.record("GPS session started")
        bluetooth.start()
    }

    private func applyBluetoothState(_ value: NikonGPSBluetoothState) {
        guard state.enabled else { return }
        GPSDiagnostics.record("BLE state=\(String(describing: value))")
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
        GPSDiagnostics.record("error=\(message)")
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
            state.message = AppLocalized.resource("gps_bluetooth_required")
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
        GPSDiagnostics.record("location fix accuracy=\(location.horizontalAccuracy)")
        if case .ready = bluetooth.state {
            state.status = .connected
            scheduleWriteIfDue()
        } else if state.status == .searching || state.status == .starting {
            state.status = .waitingFix
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard state.enabled else { return }
        state.status = .error; state.message = AppLocalized.resource("gps_permission_required")
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
            state.message = AppLocalized.resource("gps_retry")
            return
        }
        bluetooth.writeGeo(payload)
        lastWrite = Date(); state.lastSentAt = lastWrite; state.status = .ready
        GPSDiagnostics.record("GEO write success=true")
    }
}
