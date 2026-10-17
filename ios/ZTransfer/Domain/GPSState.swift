import Foundation
import CoreLocation

/// Android's GpsDiagnostics ring buffer used by the long-press troubleshooting
/// action. It is intentionally in-memory and capped at the same 80 entries.
enum GPSDiagnostics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String] = []

    static func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        if entries.count >= 80 { entries.removeFirst() }
        entries.append("\(ISO8601DateFormatter().string(from: Date())) \(message)")
    }

    static func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return entries.isEmpty ? "GPS: no events" : entries.joined(separator: "\n")
    }
}

/// Android's GpsViewModel uses a dedicated `nikon_gps` SharedPreferences file.
/// Keep the same namespace and keys on iOS so every GPS setting has one stable
/// persistence scope instead of sharing the app-wide defaults accidentally.
enum GPSPreferences {
    static let suiteName = "nikon_gps"
    static let enabled = "enabled"
    static let deviceID = "device_id"
    static let nonce = "nonce"
    static let bleAddress = "ble_address"
    static let connectionHelpViewed = "connection_help_viewed"
    static let updateFrequencySeconds = "update_frequency_seconds"
}

/// User-facing states copied from Android's GpsStatus.  Transport details stay
/// behind GPSCoordinator so the page only renders the same state transitions.
enum GPSStatus: String, Codable, Sendable {
    case off = "OFF", starting = "STARTING", searching = "SEARCHING", needsCamera = "NEEDS_CAMERA"
    case connecting = "CONNECTING", pairing = "PAIRING", cameraConfirm = "CAMERA_CONFIRM"
    case pairingSuccess = "PAIRING_SUCCESS", connected = "CONNECTED", writing = "WRITING"
    case waitingFix = "WAITING_FIX", ready = "READY", apUnavailable = "AP_UNAVAILABLE", error = "ERROR"
}

/// NikonGpsService.onError separates the displayed camera hint from whether
/// pairing actually requires an explicit user action.
struct GPSBluetoothFailurePolicy {
    let invalidatesIdentity: Bool
    let waitsForPairing: Bool
    let message: String
    let status: GPSStatus
    let retries: Bool

    init(_ raw: String) {
        let lower = raw.lowercased()
        invalidatesIdentity = lower.contains("pairing rejected") || lower.contains("identity expired")
        waitsForPairing = lower.contains("pairing") || raw.contains("配对")
        let permission = lower.contains("permission") || lower.contains("unauthorized") || lower.contains("not authorized")
        let unavailable = lower.contains("bluetooth unavailable")
        if permission { message = "需要蓝牙权限" }
        else if lower.contains("not found") || invalidatesIdentity { message = "请在相机上打开蓝牙配对" }
        else if unavailable || lower.contains("scan failed") { message = "请打开手机蓝牙" }
        else { message = raw }
        let permissionError = permission || message.contains("权限")
        status = permissionError ? .error :
            (message.contains("配对") || message.lowercased().contains("not found") ? .needsCamera : .error)
        retries = !permissionError && !waitsForPairing && !unavailable
    }
}

struct GPSState: Equatable, Sendable {
    var enabled = false
    var status: GPSStatus = .off
    var cameraName: String?
    var latitude: Double?
    var longitude: Double?
    var altitudeMeters: Double?
    var accuracyMeters: Double?
    var lastSentAt: Date?
    var message: String?
}

/// Core Location can report `locationUnknown` while it is still acquiring a fix.
/// Android keeps waiting in that situation; only a real authorization denial is
/// presented as a permission problem, while other setup failures use its
/// "无法获取定位" error state.
enum GPSLocationFailureAction: Equatable, Sendable {
    case keepWaiting
    case permissionRequired
    case locationUnavailable
}

func gpsLocationFailureAction(for code: CLError.Code) -> GPSLocationFailureAction {
    switch code {
    case .locationUnknown:
        return .keepWaiting
    case .denied:
        return .permissionRequired
    default:
        return .locationUnavailable
    }
}

func isReusableGPSLocation(_ location: CLLocation, now: Date = Date()) -> Bool {
    location.timestamp.timeIntervalSince1970 > 0 &&
        abs(now.timeIntervalSince(location.timestamp)) <= 120
}

func gpsStatusAfterLocationFix(_ status: GPSStatus) -> GPSStatus {
    switch status {
    case .ready, .writing, .connected, .connecting, .pairingSuccess, .error:
        return status
    default:
        return .connected
    }
}

/// One-shot coordinate lookup state copied from Android's GpsPlaceLookupState.
/// The coordinates stay attached to the result so a late geocoder callback
/// cannot be mistaken for the current location.
enum GPSPlaceLookupStatus: String, Sendable {
    case idle, loading, success, error
}

struct GPSPlaceLookupState: Equatable, Sendable {
    var latitude: Double?
    var longitude: Double?
    var status: GPSPlaceLookupStatus
    var placeName: String?

    static let idle = Self(latitude: nil, longitude: nil, status: .idle, placeName: nil)
}

enum GPSUpdateFrequency: Int, CaseIterable, Codable, Sendable {
    case thirtySeconds = 30, oneMinute = 60, twoMinutes = 120, fiveMinutes = 300
    var title: String {
        switch self {
        case .thirtySeconds: return AppLocalized.resource("gps_frequency_30_seconds")
        case .oneMinute: return AppLocalized.resource("gps_frequency_1_minute")
        case .twoMinutes: return AppLocalized.resource("gps_frequency_2_minutes")
        case .fiveMinutes: return AppLocalized.resource("gps_frequency_5_minutes")
        }
    }
    static let defaultValue: Self = .oneMinute

    /// CoreLocation has no provider-specific minimum-time API. These accuracy
    /// tiers are the closest iOS energy policy to Android's four sampling
    /// cadences; GEO transmission still follows the exact selected interval.
    var desiredAccuracy: Double {
        switch self {
        case .thirtySeconds, .oneMinute: return kCLLocationAccuracyNearestTenMeters
        case .twoMinutes, .fiveMinutes: return kCLLocationAccuracyHundredMeters
        }
    }
}

struct GPSTrustedAltitudeFix: Equatable, Sendable {
    let altitudeMeters: Double
    let latitude: Double
    let longitude: Double
    let timestamp: Date
}

/// Android canReuseGpsAltitude: inclusive age/distance limits and a valid fix time.
func canReuseGPSAltitude(now: Date, timestamp: Date, distanceMeters: Double) -> Bool {
    timestamp.timeIntervalSince1970 > 0 &&
        abs(now.timeIntervalSince(timestamp)) <= 120 &&
        distanceMeters.isFinite && distanceMeters <= 1_000
}

func resolvedGPSAltitude(for location: CLLocation,
                         cached: GPSTrustedAltitudeFix?,
                         now: Date = Date()) -> (Double?, GPSTrustedAltitudeFix?) {
    let age = abs(now.timeIntervalSince(location.timestamp))
    if location.verticalAccuracy >= 0, location.altitude.isFinite, age <= 120 {
        let fix = GPSTrustedAltitudeFix(
            altitudeMeters: location.altitude,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
        )
        return (location.altitude, fix)
    }
    guard let cached else { return (nil, cached) }
    let cachedLocation = CLLocation(latitude: cached.latitude, longitude: cached.longitude)
    let distance = cachedLocation.distance(from: location)
    guard canReuseGPSAltitude(now: now, timestamp: cached.timestamp, distanceMeters: distance) else { return (nil, cached) }
    return (cached.altitudeMeters, cached)
}


/// Android CoordinateFormat.kt: round total thousandths of minutes before
/// splitting, so a rounded 60.000 carries into the next degree.
enum GPSCoordinateFormat {
    static func value(_ value: Double?, latitude: Bool) -> String? {
        let maximum = latitude ? 90.0 : 180.0
        guard let value, value.isFinite, abs(value) <= maximum else { return nil }
        let hemisphere = latitude ? (value < 0 ? "S" : "N") : (value < 0 ? "W" : "E")
        let total = Int64((abs(value) * 60_000).rounded(.toNearestOrAwayFromZero))
        return String(format: "%@ %lld°%02lld.%03lld'", locale: Locale(identifier: "en_US_POSIX"),
                      hemisphere, total / 60_000, (total % 60_000) / 1_000, total % 1_000)
    }

    static func coordinates(latitude: Double, longitude: Double) -> String? {
        guard let latitude = value(latitude, latitude: true),
              let longitude = value(longitude, latitude: false) else { return nil }
        return "\(latitude), \(longitude)"
    }

    static func clipboard(latitude: Double, longitude: Double, placeName: String? = nil) -> String? {
        guard let coordinates = coordinates(latitude: latitude, longitude: longitude) else { return nil }
        return placeName.map { "\($0)\n\(coordinates)" } ?? coordinates
    }
}
