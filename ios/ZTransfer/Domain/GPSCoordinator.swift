@preconcurrency import CoreLocation
import Combine
import Foundation

func gpsBackgroundLocationModeEnabled(_ modes: [String]?) -> Bool {
    modes?.contains("location") == true
}

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
    var locationAuthorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }
    private let locationManager = CLLocationManager()
    private let defaults: UserDefaults
    private var lastWrite: Date?
    private var writeTask: Task<Void, Never>?
    private var writeTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var writeGeneration = 0
    private var geoWriteInFlight = false
    private var latestLocation: CLLocation?
    private var latestLocationDuringWrite: CLLocation?
    private var pendingAltitudeRefresh = false
    private var latestTrustedAltitudeFix: GPSTrustedAltitudeFix?
    private var cameraVerified = false
    private var preserveReadyDuringReconnect = false
    private var readyTransitionTask: Task<Void, Never>?
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
        locationManager.desiredAccuracy = frequency.desiredAccuracy
        locationManager.distanceFilter = kCLDistanceFilterNone
        bluetoothObservation = bluetooth.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.applyBluetoothState(value) }
        if enabled {
            // Android's foreground service restores an enabled GPS session on
            // process restart. Defer until NSObject/CoreLocation setup is done.
            Task { @MainActor [weak self] in self?.resumeEnabledSession() }
        }
    }

    deinit {
        writeTask?.cancel()
        writeTimeoutTask?.cancel()
        reconnectTask?.cancel()
        readyTransitionTask?.cancel()
        placeGeocoder?.cancelGeocode()
        locationManager.stopUpdatingLocation()
    }

    func setFrequency(_ value: GPSUpdateFrequency) {
        guard value != frequency else { return }
        frequency = value
        defaults.set(value.rawValue, forKey: GPSPreferences.updateFrequencySeconds)
        locationManager.desiredAccuracy = value.desiredAccuracy
        writeTask?.cancel(); writeTask = nil
        if state.enabled, !geoWriteInFlight { scheduleWriteIfDue() }
        GPSDiagnostics.record("update frequency=\(value.rawValue)s")
    }

    func setEnabled(_ enabled: Bool) {
        GPSDiagnostics.record("set enabled=\(enabled)")
        defaults.set(enabled, forKey: GPSPreferences.enabled)
        awaitingPairingAction = false
        writeTask?.cancel(); writeTask = nil
        writeTimeoutTask?.cancel(); writeTimeoutTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        readyTransitionTask?.cancel(); readyTransitionTask = nil
        writeGeneration &+= 1
        geoWriteInFlight = false
        guard enabled else {
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
            bluetooth.stop()
            state = GPSState()
            lastWrite = nil
            latestLocation = nil
            latestLocationDuringWrite = nil
            latestTrustedAltitudeFix = nil
            pendingAltitudeRefresh = false
            cameraVerified = false
            preserveReadyDuringReconnect = false
            return
        }
        state = GPSState(enabled: true, status: .starting)
        guard !apModeBlocked else {
            state.status = .apUnavailable
            state.message = AppLocalized.resource("gps_ap_unavailable")
            return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways: beginRunning()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
            beginRunning()
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
        reconnectTask?.cancel(); reconnectTask = nil
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways:
            beginRunning()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
            beginRunning()
        case .denied, .restricted:
            state.status = .error
            state.message = AppLocalized.resource("gps_permission_required")
        @unknown default:
            state.status = .error
            state.message = AppLocalized.resource("gps_permission_required")
        }
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
            writeTimeoutTask?.cancel(); writeTimeoutTask = nil
            reconnectTask?.cancel(); reconnectTask = nil
            readyTransitionTask?.cancel(); readyTransitionTask = nil
            writeGeneration &+= 1
            geoWriteInFlight = false
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
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
        locationManager.desiredAccuracy = frequency.desiredAccuracy
        locationManager.distanceFilter = kCLDistanceFilterNone
        configureBackgroundLocation()
        GPSDiagnostics.record("GPS session started")
        if case .ready = bluetooth.state {
            state.status = .waitingFix
            state.message = AppLocalized.text("正在获取手机位置")
            restartLocationPipeline()
            return
        }
        state.status = .searching
        bluetooth.start()
    }

    private func restartLocationPipeline() {
        locationManager.stopUpdatingLocation()
        locationManager.desiredAccuracy = frequency.desiredAccuracy
        locationManager.distanceFilter = kCLDistanceFilterNone
        configureBackgroundLocation()
        locationManager.startUpdatingLocation()
        GPSDiagnostics.record("location pipeline started")
    }

    private func configureBackgroundLocation() {
        let configuredModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        let enabled = locationManager.authorizationStatus == .authorizedAlways &&
            gpsBackgroundLocationModeEnabled(configuredModes)
        // Core Location raises an Objective-C assertion if this is set to true
        // without the matching background mode. Keep foreground GPS functional
        // even if a future target accidentally drops the plist capability.
        locationManager.allowsBackgroundLocationUpdates = enabled
        locationManager.showsBackgroundLocationIndicator = enabled
    }

    private func resumeEnabledSession() {
        guard state.enabled else { return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            beginRunning()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
            beginRunning()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            state.status = .error
            state.message = AppLocalized.resource("gps_permission_required")
        }
    }

    private func applyBluetoothState(_ value: NikonGPSBluetoothState) {
        guard state.enabled else { return }
        GPSDiagnostics.record("BLE state=\(String(describing: value))")
        switch value {
        case .unauthorized:
            locationManager.stopUpdatingLocation()
            state.status = .error
            state.message = AppLocalized.resource("gps_permission_required")
        case .unavailable:
            locationManager.stopUpdatingLocation()
            latestLocation = nil
            latestLocationDuringWrite = nil
            latestTrustedAltitudeFix = nil
            pendingAltitudeRefresh = false
            state.status = .error
            state.message = AppLocalized.resource("gps_bluetooth_required")
        case .scanning:
            if !preserveReadyDuringReconnect { state.status = .searching; state.message = nil }
        case .connecting(let name):
            state.cameraName = name
            if !preserveReadyDuringReconnect { state.status = .connecting }
        case .pairing: state.status = .pairing
        case .ready(let name):
            reconnectTask?.cancel(); reconnectTask = nil
            state.cameraName = name
            state.status = preserveReadyDuringReconnect ? .ready : .connected
            state.message = nil
            cameraVerified = preserveReadyDuringReconnect
            preserveReadyDuringReconnect = false
            restartLocationPipeline()
            if let latestLocation, isReusableGPSLocation(latestLocation) {
                scheduleWriteIfDue(force: true)
            }
        case .disconnected:
            guard !apModeBlocked, !awaitingPairingAction, reconnectTask == nil else { return }
            locationManager.stopUpdatingLocation()
            preserveReadyDuringReconnect = state.status == .ready
            cameraVerified = false
            lastWrite = nil
            writeTask?.cancel(); writeTask = nil
            writeTimeoutTask?.cancel(); writeTimeoutTask = nil
            readyTransitionTask?.cancel(); readyTransitionTask = nil
            writeGeneration &+= 1
            geoWriteInFlight = false
            latestLocationDuringWrite = nil
            pendingAltitudeRefresh = false
            if preserveReadyDuringReconnect {
                state.status = .ready
                state.message = AppLocalized.text("正在重连")
            } else {
                state.status = bluetooth.hasSavedPairing ? .connecting : .searching
                state.message = bluetooth.hasSavedPairing ? AppLocalized.text("正在重连") : nil
            }
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, !Task.isCancelled, self.state.enabled,
                      !self.apModeBlocked, !self.awaitingPairingAction else { return }
                self.reconnectTask = nil
                self.bluetooth.start()
            }
        case .failed(let message): applyBluetoothFailure(message)
        }
    }

    /// Mirrors NikonGpsService.handleBleError's ordered message mapping. The
    /// BLE client may report protocol/transport English strings, but Android
    /// converts the user-visible result into a camera-action state first.
    private func applyBluetoothFailure(_ message: String) {
        GPSDiagnostics.record("error=\(message)")
        locationManager.stopUpdatingLocation()
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
        } else if lowercased.contains("permission") ||
                    lowercased.contains("not authorized") ||
                    lowercased.contains("unauthorized") {
            state.status = .error
            state.message = AppLocalized.resource("gps_permission_required")
        } else if lowercased.contains("scan failed") {
            scheduleBluetoothRecovery(message: AppLocalized.resource("gps_bluetooth_required"))
        } else if lowercased.contains("bluetooth unavailable") {
            state.status = .error
            state.message = AppLocalized.resource("gps_bluetooth_required")
        } else {
            scheduleBluetoothRecovery(message: message)
        }
    }

    /// Android stops the failed GATT attempt and starts a clean BLE attempt
    /// five seconds later for transport/setup errors. Pairing and permission
    /// failures remain explicit user actions and never enter this path.
    private func scheduleBluetoothRecovery(message: String) {
        reconnectTask?.cancel()
        writeTask?.cancel(); writeTask = nil
        writeTimeoutTask?.cancel(); writeTimeoutTask = nil
        readyTransitionTask?.cancel(); readyTransitionTask = nil
        writeGeneration &+= 1
        geoWriteInFlight = false
        latestLocationDuringWrite = nil
        pendingAltitudeRefresh = false
        cameraVerified = false
        preserveReadyDuringReconnect = false
        locationManager.stopUpdatingLocation()
        bluetooth.stop()
        state.status = .error
        state.message = message
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.state.enabled,
                  !self.apModeBlocked, !self.awaitingPairingAction else { return }
            self.reconnectTask = nil
            self.beginRunning()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard state.enabled else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            beginRunning()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            beginRunning()
        case .denied, .restricted:
            locationManager.stopUpdatingLocation()
            state.status = .error
            state.message = AppLocalized.resource("gps_permission_required")
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state.enabled, case .ready = bluetooth.state,
              let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        latestLocation = location
        if geoWriteInFlight { latestLocationDuringWrite = location }
        let previousAltitude = state.altitudeMeters
        let altitude = resolvedGPSAltitude(
            for: location, cached: latestTrustedAltitudeFix
        )
        latestTrustedAltitudeFix = altitude.1
        state.latitude = location.coordinate.latitude
        state.longitude = location.coordinate.longitude
        state.altitudeMeters = altitude.0
        state.accuracyMeters = location.horizontalAccuracy
        GPSDiagnostics.record("location fix accuracy=\(location.horizontalAccuracy)")
        if case .ready = bluetooth.state {
            state.status = gpsStatusAfterLocationFix(state.status)
            scheduleWriteIfDue(force: previousAltitude == nil && altitude.0 != nil)
        } else if state.status == .searching || state.status == .starting {
            state.status = .waitingFix
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard state.enabled, case .ready = bluetooth.state else { return }
        let nsError = error as NSError
        let action: GPSLocationFailureAction
        if nsError.domain == kCLErrorDomain,
           let code = CLError.Code(rawValue: nsError.code) {
            action = gpsLocationFailureAction(for: code)
        } else {
            action = .locationUnavailable
        }
        switch action {
        case .keepWaiting:
            GPSDiagnostics.record("location fix temporarily unavailable")
        case .permissionRequired:
            locationManager.stopUpdatingLocation()
            state.status = .error
            state.message = AppLocalized.resource("gps_permission_required")
        case .locationUnavailable:
            locationManager.stopUpdatingLocation()
            state.status = .error
            state.message = AppLocalized.text("无法获取定位")
        }
    }

    private func scheduleWriteIfDue(force: Bool = false, afterFailure: Bool = false) {
        if geoWriteInFlight {
            if force { pendingAltitudeRefresh = true }
            return
        }
        if force { writeTask?.cancel(); writeTask = nil }
        guard writeTask == nil else { return }
        let elapsed = lastWrite.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let wait = force ? 0 : afterFailure
            ? Double(frequency.rawValue)
            : max(0, Double(frequency.rawValue) - elapsed)
        writeTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.writeCurrentFix()
        }
    }

    private func writeCurrentFix() {
        writeTask = nil
        guard state.enabled, let location = latestLocation else { state.status = .waitingFix; return }
        guard case .ready = bluetooth.state else { return }
        guard !geoWriteInFlight else { return }
        state.status = .writing
        guard let payload = NikonGeoPayloadEncoder.encode(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitudeMeters: state.altitudeMeters ?? 0,
            satellites: 0,
            timestamp: Date()
        ) else {
            state.status = .error
            state.message = AppLocalized.resource("gps_retry")
            return
        }
        geoWriteInFlight = true
        writeGeneration &+= 1
        let generation = writeGeneration
        bluetooth.writeGeo(payload) { [weak self] success in
            self?.finishGeoWrite(success: success, generation: generation, timedOut: false)
        }
        writeTimeoutTask?.cancel()
        writeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            self.finishGeoWrite(success: false, generation: generation, timedOut: true)
        }
        GPSDiagnostics.record("GEO queued accuracy=\(Int(location.horizontalAccuracy))m")
    }

    private func finishGeoWrite(success: Bool, generation: Int, timedOut: Bool) {
        guard generation == writeGeneration, geoWriteInFlight else { return }
        geoWriteInFlight = false
        writeTimeoutTask?.cancel(); writeTimeoutTask = nil
        GPSDiagnostics.record("GEO write success=\(success)")
        guard success else {
            lastWrite = nil
            latestLocationDuringWrite = nil
            pendingAltitudeRefresh = false
            if timedOut {
                scheduleBluetoothRecovery(message: "GPS write timeout")
                return
            }
            state.status = .error
            state.message = AppLocalized.text("GPS 写入失败")
            // Android's independent ticker remains alive after an explicit
            // GATT rejection and retries once the configured interval elapses.
            scheduleWriteIfDue(afterFailure: true)
            return
        }
        let firstVerifiedWrite = !cameraVerified
        cameraVerified = true
        lastWrite = Date()
        state.lastSentAt = lastWrite
        state.message = nil
        if firstVerifiedWrite {
            state.status = .connected
            readyTransitionTask?.cancel()
            readyTransitionTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled, self.state.enabled,
                      case .ready = self.bluetooth.state else { return }
                self.state.status = .ready
            }
        } else {
            state.status = .ready
        }
        let forceAltitude = pendingAltitudeRefresh && latestLocationDuringWrite != nil
        pendingAltitudeRefresh = false
        latestLocationDuringWrite = nil
        if forceAltitude {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.scheduleWriteIfDue(force: true)
            }
        } else {
            scheduleWriteIfDue()
        }
    }
}
