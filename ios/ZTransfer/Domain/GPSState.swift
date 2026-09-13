import Foundation

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
}
