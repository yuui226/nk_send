import Foundation
import Network

/// This small Apple I/O seam also permits deterministic callback/short-read tests.
protocol CameraByteConnection: AnyObject {
    func resolvedRemoteHost() -> String?
    func start(on queue: DispatchQueue, state: @escaping (CameraConnectionEvent) -> Void)
    func receive(maximumLength: Int, completion: @escaping (Data?, Bool, Error?) -> Void)
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func cancel()
}

extension CameraByteConnection {
    func resolvedRemoteHost() -> String? { nil } // Fixtures/non-Network transports provide no route evidence.
}

enum CameraConnectionEvent { case ready, failed(Error), cancelled }

private final class AppleCameraByteConnection: CameraByteConnection {
    private let connection: NWConnection
    private let permittedInterface: Bool

    func resolvedRemoteHost() -> String? {
        guard case .ready = connection.state, let path = connection.currentPath,
              CameraNetworkPathPolicy.failure(path) == nil else { return nil }
        return CameraNetworkPathPolicy.numericRemoteHost(path.remoteEndpoint)
    }

    convenience init(host: String, port: UInt16) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpointPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw CameraStreamError.invalidArgument
        }
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: endpointPort))
    }

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Camera hotspots have no Internet: never fall back to cellular for this socket.
        parameters.requiredInterfaceType = .wifi
        if case .service(_, _, _, let interface) = endpoint, let interface {
            parameters.requiredInterface = interface
            permittedInterface = interface.type == .wifi
        } else { permittedInterface = true }
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func start(on queue: DispatchQueue, state: @escaping (CameraConnectionEvent) -> Void) {
        guard permittedInterface else { state(.failed(CameraStreamError.wifiUnavailable)); return }
        var deliveredReady = false // Network callbacks are serialized on the supplied queue.
        connection.pathUpdateHandler = { path in
            guard deliveredReady, let failure = CameraNetworkPathPolicy.failure(path) else { return }
            state(.failed(failure))
        }
        connection.stateUpdateHandler = { [weak self] update in
            guard let self else { return }
            switch update {
            case .ready:
                guard let path = self.connection.currentPath else { state(.failed(CameraStreamError.wifiUnavailable)); return }
                if let failure = CameraNetworkPathPolicy.failure(path) { state(.failed(failure)); return }
                deliveredReady = true
                state(.ready)
            case .waiting:
                // Only explicit system evidence means denied. A prompt or timeout is not denial.
                if self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    state(.failed(CameraStreamError.localNetworkDenied))
                }
            case .failed(let error):
                if self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    state(.failed(CameraStreamError.localNetworkDenied))
                } else { state(.failed(error)) }
            case .cancelled: state(.cancelled)
            // Waiting may include the Local Network prompt. A deadline bounds it but does not
            // establish that the user denied permission.
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func receive(maximumLength: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
            data, _, complete, error in completion(data, complete, error)
        }
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0) })
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.cancel()
    }
}

enum CameraStreamError: Error, LocalizedError, Equatable {
    case invalidArgument, notConnected, operationInProgress, closed, timedOut, endOfStream
    case wifiUnavailable, localNetworkDenied
    var errorDescription: String? {
        switch self {
        case .wifiUnavailable: return "相机 Wi-Fi 路由不可用，请在系统 Wi-Fi 设置中加入相机热点或与相机相同的局域网；不会改用蜂窝网络。"
        case .localNetworkDenied: return "系统已禁止本应用访问局域网。请在应用系统设置中允许“本地网络”，返回后重新连接。"
        case .invalidArgument: return "相机网络参数无效。"
        case .notConnected: return "相机网络尚未连接。"
        case .operationInProgress: return "相机通道正在执行同类操作。"
        case .closed: return "相机网络连接已关闭。"
        case .timedOut: return "相机网络操作超时，请检查 Wi-Fi、相机状态和局域网权限。"
        case .endOfStream: return "相机关闭了网络连接。"
        }
    }
}

/// Apple transport evidence only, not camera authentication or Internet reachability.
enum CameraNetworkPathPolicy {
    static func numericRemoteHost(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint, case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4, .ipv6: return try? CameraEndpointAddress.parse(String(describing: host)).host
        default: return nil // Never turn an advertised name into a fabricated successful IP.
        }
    }
    static func failure(_ path: NWPath) -> CameraStreamError? {
        failure(satisfied: path.status == .satisfied, wifi: path.usesInterfaceType(.wifi),
                denied: path.unsatisfiedReason == .localNetworkDenied)
    }
    static func failure(satisfied: Bool, wifi: Bool, denied: Bool) -> CameraStreamError? {
        if denied { return .localNetworkDenied }
        if !satisfied || !wifi { return .wifiUnavailable }
        return nil
    }
}

/// Single-use TCP connection: one reader and one writer may operate concurrently.
/// All mutable state is queue-confined. Timeout/cancellation closes the entire connection because
/// a partly consumed PTP packet cannot be reused. Late callbacks are discarded by operation ID.
final class CameraTCPStream: @unchecked Sendable {
    private enum State { case idle, connecting, ready, closed }
    private struct Pending<T> {
        let id: UUID
        let continuation: CheckedContinuation<T, Error>
        let deadline: DispatchWorkItem?
    }
    private let connection: CameraByteConnection
    private let queue = DispatchQueue(label: "com.ztransfer.camera.tcp")
    private var state: State = .idle
    private var opening: Pending<Void>?
    private var reading: Pending<Data>?
    private var writing: Pending<Void>?
    private var readBuffer = Data()
    private var readCount = 0
    private var reachedEOF = false

    convenience init(host: String, port: UInt16) throws {
        self.init(connection: try AppleCameraByteConnection(host: host, port: port))
    }
    convenience init(service: CameraBonjourService) {
        self.init(connection: AppleCameraByteConnection(endpoint: service.endpoint))
    }
    init(connection: CameraByteConnection) { self.connection = connection }

    func resolvedRemoteHost() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.state == .ready ? self.connection.resolvedRemoteHost() : nil)
            }
        }
    }

    deinit { connection.cancel() }

    func connect(timeout: TimeInterval) async throws {
        try validate(timeout: timeout)
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard self.state == .idle else {
                        let error: CameraStreamError = self.state == .closed ? .closed : .operationInProgress
                        continuation.resume(throwing: error)
                        return
                    }
                    self.state = .connecting
                    self.opening = self.pending(continuation, timeout: timeout)
                    self.connection.start(on: self.queue) { [weak self] event in
                        guard let self else { return }
                        self.queue.async {
                            guard self.state != .closed else { return }
                            switch event {
                            case .ready:
                                guard let pending = self.opening else { return }
                                self.opening = nil
                                self.state = .ready
                                pending.deadline?.cancel()
                                pending.continuation.resume()
                            case .failed(let error): self.terminate(error)
                            case .cancelled: self.terminate(CameraStreamError.closed)
                            }
                        }
                    }
                }
            }
        }, onCancel: { self.close(with: CancellationError()) })
    }

    func readExactly(_ count: Int, timeout: TimeInterval?) async throws -> Data {
        if let timeout { try validate(timeout: timeout) }
        guard count >= 0 else { throw CameraStreamError.invalidArgument }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async {
                    guard self.state == .ready else {
                        continuation.resume(throwing: CameraStreamError.notConnected); return
                    }
                    guard self.reading == nil else {
                        continuation.resume(throwing: CameraStreamError.operationInProgress); return
                    }
                    if count == 0 { continuation.resume(returning: Data()); return }
                    guard !self.reachedEOF else {
                        continuation.resume(throwing: CameraStreamError.endOfStream); return
                    }
                    self.readBuffer = Data()
                    self.readCount = count
                    let pending = self.pending(continuation, timeout: timeout)
                    self.reading = pending
                    self.receiveNext(id: pending.id)
                }
            }
        }, onCancel: { self.close(with: CancellationError()) })
    }

    func write(_ data: Data, timeout: TimeInterval) async throws {
        try validate(timeout: timeout)
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard self.state == .ready else {
                        continuation.resume(throwing: CameraStreamError.notConnected); return
                    }
                    guard self.writing == nil else {
                        continuation.resume(throwing: CameraStreamError.operationInProgress); return
                    }
                    let pending = self.pending(continuation, timeout: timeout)
                    self.writing = pending
                    self.connection.send(data) { [weak self] error in
                        guard let self else { return }
                        self.queue.async {
                            guard self.writing?.id == pending.id else { return }
                            if let error { self.terminate(error); return }
                            self.writing = nil
                            pending.deadline?.cancel()
                            pending.continuation.resume()
                        }
                    }
                }
            }
        }, onCancel: { self.close(with: CancellationError()) })
    }

    func close() { close(with: CameraStreamError.closed) }
    private func close(with error: Error) { queue.async { self.terminate(error) } }

    private func validate(timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0 else { throw CameraStreamError.invalidArgument }
    }

    private func pending<T>(_ continuation: CheckedContinuation<T, Error>, timeout: TimeInterval?) -> Pending<T> {
        let id = UUID()
        guard let timeout else { return Pending(id: id, continuation: continuation, deadline: nil) }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self,
                  self.opening?.id == id || self.reading?.id == id || self.writing?.id == id else { return }
            self.terminate(CameraStreamError.timedOut)
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        return Pending(id: id, continuation: continuation, deadline: deadline)
    }

    private func receiveNext(id: UUID) {
        connection.receive(maximumLength: min(readCount - readBuffer.count, 64 * 1024)) { [weak self] data, complete, error in
            guard let self else { return }
            self.queue.async {
                guard let pending = self.reading, pending.id == id else { return }
                if let error { self.terminate(error); return }
                if let data { self.readBuffer.append(data) }
                self.reachedEOF = complete
                if self.readBuffer.count == self.readCount {
                    let result = self.readBuffer
                    self.readBuffer = Data()
                    self.reading = nil
                    pending.deadline?.cancel()
                    pending.continuation.resume(returning: result)
                } else if complete || data?.isEmpty != false || self.readBuffer.count > self.readCount {
                    self.terminate(CameraStreamError.endOfStream)
                } else {
                    self.receiveNext(id: id)
                }
            }
        }
    }

    private func terminate(_ error: Error) {
        guard state != .closed else { return }
        state = .closed
        connection.cancel()
        if let pending = opening {
            opening = nil
            pending.deadline?.cancel()
            pending.continuation.resume(throwing: error)
        }
        if let pending = reading {
            reading = nil
            pending.deadline?.cancel()
            pending.continuation.resume(throwing: error)
        }
        if let pending = writing {
            writing = nil
            pending.deadline?.cancel()
            pending.continuation.resume(throwing: error)
        }
        readBuffer = Data()
    }
}
