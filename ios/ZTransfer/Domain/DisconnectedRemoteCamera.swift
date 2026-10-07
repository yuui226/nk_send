import Foundation

/// An explicitly unavailable control capability for a restored remote page.
/// This owns no CameraSession, repository, connection or protocol routing.
/// Every command fails as disconnected; cleanup remains idempotent.
struct DisconnectedRemoteCamera: RemoteCameraControlling {
    let isUSB: Bool
    func setRemoteActive(_ active: Bool) async {  }
    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) async throws -> RemotePropertyDescriptor? { throw CameraTransportError.disconnected }
    func remoteFocusMode() async throws -> RemotePropertyDescriptor? { throw CameraTransportError.disconnected }
    func remoteEvents() async throws -> [STAEvent] { throw CameraTransportError.disconnected }
    func startLiveView() async throws { throw CameraTransportError.disconnected }
    func endLiveView() async {  }
    func liveViewFrame() async throws -> RemoteLiveViewPacket { throw CameraTransportError.disconnected }
    func remoteMovieMode() async throws -> Bool? { throw CameraTransportError.disconnected }
    func capturePhoto() async throws { throw CameraTransportError.disconnected }
    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor? { throw CameraTransportError.disconnected }
    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws { throw CameraTransportError.disconnected }
    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult { throw CameraTransportError.disconnected }
    func halfPressFocus() async throws -> RemoteFocusResult { throw CameraTransportError.disconnected }
    func endSubjectTracking() async throws { throw CameraTransportError.disconnected }
    func startMovieRecording() async throws -> RemoteMovieStartResult { throw CameraTransportError.disconnected }
    func endMovieRecording() async throws -> UInt16 { throw CameraTransportError.disconnected }
    func refreshUSBRemoteSession() async throws -> String { throw CameraTransportError.disconnected }
    func setRemoteControlMode(_ enabled: Bool) async throws -> UInt16 { throw CameraTransportError.disconnected }
    func hasRemoteControlMode() async -> Bool { false }
    func hasMovieApplicationMode() async -> Bool { false }
    func ensureMovieApplicationMode() async throws { throw CameraTransportError.disconnected }
    func clearMovieApplicationMode(force: Bool) async {  }
    func startPreparedUSBMovieRecording() async throws -> RemoteMovieStartResult { throw CameraTransportError.disconnected }
}
