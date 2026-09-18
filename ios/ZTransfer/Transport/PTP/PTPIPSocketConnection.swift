import Foundation
import Network

enum PTPIPSocketBackend: Sendable {
    case networkFramework
    case bsdSocket
}

/// Only the byte channel varies. PTP framing, pairing, session ownership,
/// cancellation and drain remain in PTPIPSocketTransport for both backends.
final class PTPIPSocketConnection: @unchecked Sendable {
    let network: NWConnection?
    private let host: String
    private let port: UInt16
    private let localAddress: String?
    private let isCommandChannel: Bool
    private let lock = NSLock()
    private var posix: PTPIPPOSIXChannel?
    private var closed = false
    var receiveBufferBytes: Int? { lock.withLock { posix?.receiveBufferBytes } }
    func diagnosticSnapshot() -> [String: Double]? {
        let channel = lock.withLock { posix }
        return channel?.diagnosticSnapshot()
    }

    init(host: String, port: UInt16, localAddress: String?, parameters: NWParameters, backend: PTPIPSocketBackend,
         isCommandChannel: Bool = true) {
        self.host = host
        self.port = port
        self.localAddress = localAddress
        self.isCommandChannel = isCommandChannel
        network = backend == .networkFramework
            ? NWConnection(host: .init(host), port: .init(rawValue: port)!, using: parameters) : nil
    }

    func startPOSIX() async throws {
        let channel = try await PTPIPPOSIXChannel.connect(host: host, port: port, localAddress: localAddress,
                                                        isCommandChannel: isCommandChannel)
        let accepted = lock.withLock {
            guard !closed, posix == nil else { return false }
            posix = channel
            return true
        }
        guard accepted else { channel.close(); throw PTPSessionError.invalidated }
    }

    func sendPOSIX(_ data: Data) async throws { try await readyPOSIX().send(data) }
    func receivePOSIX(maximumLength: Int, diagnostics: PTPTransferDiagnostics? = nil,
                      readTimeoutNanoseconds: UInt64? = nil) async throws -> Data {
        try await readyPOSIX().receive(maximumLength: maximumLength, diagnostics: diagnostics,
                                       readTimeoutNanoseconds: readTimeoutNanoseconds)
    }

    func withPOSIXPacketPump<T: Sendable>(
        buffered: Data, activity: @escaping @Sendable () -> Void,
        diagnostics: PTPTransferDiagnostics?, readTimeoutNanoseconds: UInt64,
        preserveBuffered: @escaping @Sendable (Data) -> Void,
        operation: @escaping @Sendable (PTPIPBorrowedPacketRead, (Data) throws -> Void) throws -> T
    ) async throws -> T {
        try await readyPOSIX().withPacketPump(buffered: buffered, activity: activity, diagnostics: diagnostics,
                                              readTimeoutNanoseconds: readTimeoutNanoseconds,
                                              preserveBuffered: preserveBuffered, operation: operation)
    }

    private func readyPOSIX() throws -> PTPIPPOSIXChannel {
        try lock.withLock {
            guard !closed, let posix else { throw PTPSessionError.invalidated }
            return posix
        }
    }

    func cancel() {
        let channel = lock.withLock {
            closed = true
            return posix
        }
        network?.cancel()
        channel?.close()
    }
}
