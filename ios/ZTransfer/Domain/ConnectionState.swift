import Foundation

/// 连接页面只表达已经确认的状态；具体传输和协议实现由 transport 层提供。

enum CameraConnectionMode: String, CaseIterable, Identifiable, Sendable {
    case usb
    case wifi

    var id: String { rawValue }
}

enum WirelessMode: String, CaseIterable, Hashable, Sendable { case sta, ap }

enum USBConnectionPhase: Equatable, Sendable {
    case unavailable
    case waitingForCamera
    case connecting
    case connected
    case failed(String)
}

enum WiFiConnectionPhase: Equatable, Sendable {
    case unavailable, idle, discovering, pairing, connecting, connected, reconnecting, failed(String)
}

/// Android keeps the AP card's short title/body separate from the transport
/// exception. Preserve that classification so the iOS card never exposes a
/// raw socket error where Android shows its localized feedback pair.
enum WiFiFailureKind: String, Equatable, Sendable {
    case notFound, refused, failed
}

struct ConnectionState: Equatable, Sendable {
    var selectedMode: CameraConnectionMode = .usb
    var wirelessMode: WirelessMode = .sta
    var usbPhase: USBConnectionPhase = .waitingForCamera
    var staProgressIP: String?
    var wifiPhase: WiFiConnectionPhase = .idle
    var wifiFailureKind: WiFiFailureKind?
    var usbAuthorization: USBAuthorizationState = .notDetermined
    var discoveredDevices: [USBDeviceDescriptor] = []
    var selectedDeviceID: String?
    var errorMessage: String?

    /// HomeScreen.connectionHapticOutcome folds changing error details into
    /// one outcome. A rebuilt view or an AP error subtype change stays silent.
    func hapticOutcome(connectedViaUSB: Bool?) -> ConnectionHapticOutcome {
        if let connectedViaUSB {
            return connectedViaUSB ? .usbSuccess : (wirelessMode == .sta ? .staSuccess : .apSuccess)
        }
        if selectedMode == .usb, case .failed = usbPhase { return .usbFailure }
        if case .failed = wifiPhase {
            if wirelessMode == .sta { return .staFailure }
            if selectedMode != .usb { return .apFailure }
        }
        return .none
    }
}

enum ConnectionHapticOutcome: Equatable {
    case none, usbSuccess, staSuccess, apSuccess, usbFailure, staFailure, apFailure
    var isFailure: Bool {
        switch self {
        case .usbFailure, .staFailure, .apFailure: return true
        default: return false
        }
    }
}

extension ConnectionState {
    /// Pure Android-parity reducer for externally observable USB transitions.
    /// Side effects (starting/stopping ImageCaptureCore) stay in the view model.
    func applying(_ event: USBTransportEvent) -> ConnectionState {
        var next = self
        switch event {
        case let .authorization(status):
            next.usbAuthorization = status
            if status == .denied || status == .restricted {
                // iOS authorization is app-scoped rather than cable-scoped;
                // keep an actionable error until Settings grants access.
                let message = AppLocalized.resource("usb_permission_required")
                next.usbPhase = .failed(message)
                next.errorMessage = message
            } else if status == .authorized,
                      (next.usbPhase == .unavailable ||
                       next.usbPhase == .failed(AppLocalized.resource("usb_permission_required"))) {
                next.usbPhase = .waitingForCamera
                next.errorMessage = nil
            }
        case let .deviceAdded(device):
            if let index = next.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                next.discoveredDevices[index] = device
            } else {
                next.discoveredDevices.append(device)
            }
            if next.selectedDeviceID == nil || next.selectedDeviceID == device.id {
                next.selectedDeviceID = device.id
                // A fresh attach retries transient open failures, but iOS
                // camera authorization is app-scoped and survives a replug.
                // Keep its actionable error until Settings grants both
                // ImageCaptureCore contents and control access.
                if next.usbPhase != .connected,
                   next.usbAuthorization != .denied,
                   next.usbAuthorization != .restricted {
                    next.usbPhase = .waitingForCamera
                    next.errorMessage = nil
                }
            }
        case let .deviceRemoved(id):
            next.discoveredDevices.removeAll { $0.id == id }
            if next.selectedDeviceID == id {
                next.selectedDeviceID = nil
                if next.usbAuthorization == .denied || next.usbAuthorization == .restricted {
                    let message = AppLocalized.resource("usb_permission_required")
                    next.usbPhase = .failed(message)
                    next.errorMessage = message
                } else {
                    next.usbPhase = .waitingForCamera
                    next.errorMessage = nil
                }
            }
        case let .ready(id):
            if next.selectedDeviceID == nil { next.selectedDeviceID = id }
        case let .sessionOpened(id, _):
            // ImageCaptureCore's session-open callback precedes DeviceInfo and
            // catalog loading. The user-visible connected state is committed by
            // ConnectionViewModel only after that handshake succeeds.
            next.selectedDeviceID = id
            if next.usbAuthorization == .denied || next.usbAuthorization == .restricted {
                let message = AppLocalized.resource("usb_permission_required")
                next.usbPhase = .failed(message)
                next.errorMessage = message
            } else {
                next.usbPhase = .connecting
                next.errorMessage = nil
            }
        case let .sessionClosed(id, _):
            if next.selectedDeviceID == id {
                if next.usbAuthorization == .denied || next.usbAuthorization == .restricted {
                    let message = AppLocalized.resource("usb_permission_required")
                    next.usbPhase = .failed(message)
                    next.errorMessage = message
                } else {
                    next.usbPhase = .waitingForCamera
                }
            }
        case let .failed(id, message):
            if id == nil || id == next.selectedDeviceID {
                let resolved = (next.usbAuthorization == .denied || next.usbAuthorization == .restricted)
                    ? AppLocalized.resource("usb_permission_required")
                    : (message.isEmpty ? AppLocalized.resource("usb_unknown_error") : message)
                next.usbPhase = .failed(resolved)
                next.errorMessage = resolved
            }
        }
        return next
    }
}
