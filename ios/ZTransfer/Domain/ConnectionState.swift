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
    case unavailable, idle, discovering, connecting, connected, failed(String)
}

struct ConnectionState: Equatable, Sendable {
    var selectedMode: CameraConnectionMode = .usb
    var wirelessMode: WirelessMode = .sta
    var usbPhase: USBConnectionPhase = .waitingForCamera
    var wifiPhase: WiFiConnectionPhase = .idle
    var usbAuthorization: USBAuthorizationState = .notDetermined
    var discoveredDevices: [USBDeviceDescriptor] = []
    var selectedDeviceID: String?
    var errorMessage: String?
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
                // Android keeps the USB card selected and exposes the same
                // actionable permission error until the cable is reattached.
                let message = "未获得 USB 权限，请重新插线并允许访问"
                next.usbPhase = .failed(message)
                next.errorMessage = message
            } else if status == .authorized,
                      (next.usbPhase == .unavailable ||
                       next.usbPhase == .failed("未获得 USB 权限，请重新插线并允许访问")) {
                next.usbPhase = .waitingForCamera
                next.errorMessage = nil
            }
        case let .deviceAdded(device):
            if !next.discoveredDevices.contains(device) { next.discoveredDevices.append(device) }
            if next.selectedDeviceID == nil || next.selectedDeviceID == device.id {
                next.selectedDeviceID = device.id
                // A fresh attach is the Android retry boundary: clear the
                // previous permission/open error and wait for a new attempt.
                if next.usbPhase != .connected {
                    next.usbPhase = .waitingForCamera
                    next.errorMessage = nil
                }
            }
        case let .deviceRemoved(id):
            next.discoveredDevices.removeAll { $0.id == id }
            if next.selectedDeviceID == id {
                next.selectedDeviceID = nil
                next.usbPhase = .waitingForCamera
                next.errorMessage = nil
            }
        case let .ready(id):
            if next.selectedDeviceID == nil { next.selectedDeviceID = id }
        case let .sessionOpened(id):
            // ImageCaptureCore's session-open callback precedes DeviceInfo and
            // catalog loading. The user-visible connected state is committed by
            // ConnectionViewModel only after that handshake succeeds.
            next.selectedDeviceID = id; next.usbPhase = .connecting; next.errorMessage = nil
        case let .sessionClosed(id):
            if next.selectedDeviceID == id { next.usbPhase = .waitingForCamera }
        case let .failed(id, message):
            if id == nil || id == next.selectedDeviceID { next.usbPhase = .failed(message); next.errorMessage = message }
        }
        return next
    }
}
