import Foundation
import Network

/// PTP/IP command transport. The command and event sockets are separate, as in
/// Nikon's Android implementation; one instance serializes command transactions
/// through PTPSession and never lets a partial packet leak into the next request.
final class PTPIPSocketTransport: @unchecked Sendable, PTPCommandTransport {
    let host: String
    let port: UInt16
    private let command: NWConnection
    private let event: NWConnection
    private let queue = DispatchQueue(label: "com.ztransfer.ptpip")
    private var closed = false

    private init(host: String, port: UInt16, command: NWConnection, event: NWConnection) {
        self.host = host; self.port = port; self.command = command; self.event = event
    }

    static func open(host: String, port: UInt16 = 15740) async throws -> PTPIPSocketTransport {
        let parameters: NWParameters = {
            let value = NWParameters.tcp
            value.requiredInterfaceType = .wifi
            value.prohibitedInterfaceTypes = [.loopback]
            return value
        }()
        let command = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        let event = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        let transport = PTPIPSocketTransport(host: host, port: port, command: command, event: event)
        try await transport.start(command)
        try await transport.send(try PTPIPCodec.initCommandRequest())
        let ack = try await transport.receive(on: command)
        guard ack.type == .initCommandAck, ack.payload.count >= 4 else { throw PTPSessionError.invalidResponse }
        let connectionNumber = ack.payload.readUInt32LE(at: 0)
        try await transport.start(event)
        try await transport.send(try PTPIPCodec.initEventRequest(connectionNumber: connectionNumber), on: event)
        let eventAck = try await transport.receive(on: event)
        guard eventAck.type == .initEventAck else { throw PTPSessionError.invalidResponse }
        return transport
    }

    func close() {
        guard !closed else { return }
        closed = true
        command.cancel(); event.cancel()
    }

    func sendPTP(command ptpCommand: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        guard !closed else { throw PTPSessionError.invalidated }
        let request = try PTPIPCodec.commandRequest(from: ptpCommand, dataPhase: data == nil ? 0 : 2)
        try await send(request)
        if let data {
            let transaction = ptpCommand.readUInt32LE(at: 8)
            var startPayload = Data(); startPayload.append(contentsOf: transaction.littleEndianBytes); startPayload.append(contentsOf: UInt64(data.count).littleEndianBytes)
            try await send(try PTPIPCodec.encode(type: .startData, payload: startPayload))
            var endPayload = Data(); endPayload.append(contentsOf: transaction.littleEndianBytes); endPayload.append(data)
            try await send(try PTPIPCodec.encode(type: .endData, payload: endPayload))
        }
        var received = Data()
        while true {
            let packet = try await receive(on: self.command)
            switch packet.type {
            case .data, .endData:
                guard packet.payload.count >= 4 else { throw PTPSessionError.invalidResponse }
                received.append(packet.payload.dropFirst(4))
            case .commandResponse:
                guard packet.payload.count >= 6 else { throw PTPSessionError.invalidResponse }
                var response = Data(capacity: packet.payload.count + 4)
                response.append(contentsOf: UInt32(packet.payload.count + 4).littleEndianBytes)
                response.append(contentsOf: UInt16(3).littleEndianBytes)
                response.append(packet.payload)
                return (response, received)
            case .ping:
                try await send(try PTPIPCodec.encode(type: .pong), on: self.command)
            default:
                continue
            }
        }
    }

    private func start(_ connection: NWConnection) async throws {
        let flag = OnceFlag()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    guard flag.claim() else { return }
                    switch state {
                    case .ready: continuation.resume()
                    case .failed(let error): continuation.resume(throwing: error)
                    case .cancelled: continuation.resume(throwing: PTPSessionError.invalidated)
                    default: flag.reset()
                    }
                }
                connection.start(queue: queue)
            }
        }, onCancel: { connection.cancel() })
    }

    private func send(_ data: Data, on connection: NWConnection? = nil) async throws {
        let connection = connection ?? command
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }, onCancel: { connection.cancel() })
    }

    private func receive(on connection: NWConnection) async throws -> PTPIPPacket {
        let header = try await readExactly(8, on: connection)
        let length = Int(header.readUInt32LE(at: 0))
        guard length >= 8, length <= PTPIPCodec.maxPacketLength else { throw PTPIPCodecError.malformedLength }
        let body = try await readExactly(length - 8, on: connection)
        return try PTPIPCodec.decode(header + body)
    }

    private func readExactly(_ count: Int, on connection: NWConnection) async throws -> Data {
        if count == 0 { return Data() }
        var result = Data(capacity: count)
        while result.count < count {
            let chunk = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { content, _, isComplete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let content, !content.isEmpty { continuation.resume(returning: content) }
                        else if isComplete { continuation.resume(throwing: PTPSessionError.invalidated) }
                        else { continuation.resume(throwing: PTPIPCodecError.malformedLength) }
                    }
                }
            }, onCancel: { connection.cancel() })
            result.append(chunk)
        }
        return result
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !claimed else { return false }; claimed = true; return true }
    func reset() { lock.lock(); claimed = false; lock.unlock() }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset]) | UInt32(self[startIndex + offset + 1]) << 8 |
            UInt32(self[startIndex + offset + 2]) << 16 | UInt32(self[startIndex + offset + 3]) << 24
    }
}
private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian) { Array($0) } }
}
