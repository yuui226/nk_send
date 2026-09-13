import Foundation

/// 所有相机连接方式都通过此边界进入业务层，避免页面直接依赖系统 I/O。
protocol CameraTransport: Sendable {
    associatedtype Event: Sendable

    func start()
    func stop()
    func events() -> AsyncStream<Event>
}

enum CameraTransportError: Error, Equatable, Sendable {
    case unavailable
    case permissionDenied
    case disconnected
    case timeout
    case protocolError(String)
}
