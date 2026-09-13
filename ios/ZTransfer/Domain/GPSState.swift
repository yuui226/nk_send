import Foundation

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
        switch self { case .thirtySeconds: return "30秒"; case .oneMinute: return "1分钟"; case .twoMinutes: return "2分钟"; case .fiveMinutes: return "5分钟" }
    }
    static let defaultValue: Self = .oneMinute
}
