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
    guard let cached,
          abs(now.timeIntervalSince(cached.timestamp)) <= 120 else { return (nil, cached) }
    let cachedLocation = CLLocation(latitude: cached.latitude, longitude: cached.longitude)
    let distance = cachedLocation.distance(from: location)
    guard distance.isFinite, distance <= 1_000 else { return (nil, cached) }
    return (cached.altitudeMeters, cached)
}
