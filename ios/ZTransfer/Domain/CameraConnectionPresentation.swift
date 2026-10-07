import Foundation

/// Android 617082c3 CameraConnectionPresentation.kt. Presentation history must
/// never choose a protocol transport or manufacture a connected camera session.
enum CameraPresentationMode: String, CaseIterable, Sendable {
    case usb = "USB", ap = "AP", sta = "STA"

    static let preferenceKey = "last_connection_mode"

    static func resolve(transport: CameraConnectionMode?, isSTA: Bool,
                        remembered: Self?, wireless: WirelessMode) -> Self {
        switch transport {
        case .usb: return .usb
        case .wifi: return isSTA ? .sta : .ap
        case nil: return remembered ?? (wireless == .sta ? .sta : .ap)
        }
    }

    init(isUSB: Bool, wirelessMode: WirelessMode?) {
        self = isUSB ? .usb : (wirelessMode == .sta ? .sta : .ap)
    }

    var disconnectedTitle: String { self == .usb ? "usb_connection_lost" : "connection_lost" }
    var disconnectedHint: String {
        switch self {
        case .usb: return "reconnect_camera_usb"
        case .ap: return "connect_camera_wifi"
        case .sta: return "reconnect_camera_sta"
        }
    }
    var disconnectedAction: String? {
        switch self {
        case .usb: return nil
        case .ap: return "open_wifi_settings"
        case .sta: return "reconnect_camera"
        }
    }

    func canRetrySTA(connected: Bool) -> Bool { self == .sta && !connected }
}
