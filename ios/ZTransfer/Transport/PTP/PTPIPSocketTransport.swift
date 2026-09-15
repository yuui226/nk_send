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
    private let lifecycleLock = NSLock()
    private var closed = false
    private var eventTask: Task<Void, Never>?
    private var activeAbort: PTPIPAbortState?
    private(set) var connectionNumber: UInt32 = 0
    private(set) var responderGUID: String?

    private var isClosed: Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return closed
    }

    private func setActiveAbort(_ state: PTPIPAbortState) {
        lifecycleLock.lock(); activeAbort = state; lifecycleLock.unlock()
    }

    private var currentAbort: PTPIPAbortState? {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return activeAbort
    }

    private static let cancelDrainTimeoutNanoseconds: UInt64 = 3_000_000_000

    private init(host: String, port: UInt16, command: NWConnection, event: NWConnection) {
        self.host = host; self.port = port; self.command = command; self.event = event
    }

    static func parameters(localAddress: String? = nil, sta: Bool) -> NWParameters {
        let parameters = NWParameters.tcp
        // Personal Hotspot's camera traffic can use bridge/ap rather than en0.
        // Android binds the proven candidate's local address, not the default route.
        if sta {
            parameters.prohibitedInterfaceTypes = [.cellular, .loopback]
            if let localAddress {
                parameters.requiredLocalEndpoint = .hostPort(host: .init(localAddress), port: .any)
            }
        } else {
            parameters.requiredInterfaceType = .wifi
            parameters.prohibitedInterfaceTypes = [.loopback]
        }
        return parameters
    }

    static func open(host: String, port: UInt16 = 15740, localAddress: String? = nil,
                     staInitiatorID: Data? = nil, expectedGUID: String? = nil,
                     connectionParameters: NWParameters? = nil) async throws -> PTPIPSocketTransport {
        let parameters = connectionParameters ?? parameters(localAddress: localAddress, sta: staInitiatorID != nil)
        let command = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: parameters)
        let event = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: parameters)
        let transport = PTPIPSocketTransport(host: host, port: port, command: command, event: event)
        do {
            try await transport.start(command, timeout: 3_000_000_000)
            let initialization = try staInitiatorID.map { try PTPIPCodec.staInitCommandRequest(initiatorID: $0) }
                ?? PTPIPCodec.initCommandRequest()
            let ack = try await AsyncDeadline.run(nanoseconds: 5_000_000_000, timeoutError: PTPSessionError.timeout) {
                try await transport.send(initialization)
                return try await transport.receive(on: command)
            }
            if ack.type == .initFail { throw STAConnectionError.cameraRefused }
            guard ack.type == .initCommandAck, ack.payload.count >= 4 else { throw PTPSessionError.invalidResponse }
            transport.connectionNumber = ack.payload.readUInt32LE(at: 0)
            if ack.payload.count >= 20 {
                transport.responderGUID = ack.payload[4..<20].map { String(format: "%02x", $0) }.joined()
            }
            if let expectedGUID, transport.responderGUID != expectedGUID {
                throw STAConnectionError.unexpectedResponder(expected: expectedGUID, actual: transport.responderGUID)
            }
            try await transport.start(event, timeout: 3_000_000_000)
            let connectionNumber = transport.connectionNumber
            let eventAck = try await AsyncDeadline.run(nanoseconds: 5_000_000_000, timeoutError: PTPSessionError.timeout) {
                try await transport.send(try PTPIPCodec.initEventRequest(connectionNumber: connectionNumber), on: event)
                return try await transport.receive(on: event)
            }
            guard eventAck.type == .initEventAck else { throw PTPSessionError.invalidResponse }
            try Task.checkCancellation()
            return transport
        } catch {
            transport.close()
            throw error
        }
    }

    func close() {
        lifecycleLock.lock()
        guard !closed else { lifecycleLock.unlock(); return }
        closed = true
        let task = eventTask
        eventTask = nil
        lifecycleLock.unlock()
        task?.cancel()
        command.cancel(); event.cancel()
    }

    /// Only called before starting the continuous reader. Missing pacing events
    /// never undo the already-acknowledged pairing (NikonCamera.completeInitialPairing).
    func waitForPairingEvent() async {
        _ = try? await AsyncDeadline.run(nanoseconds: 8_000_000_000, timeoutError: PTPSessionError.timeout) {
            while !Task.isCancelled {
                let packet = try await self.receive(on: self.event)
                if packet.type == .ping {
                    try await self.send(try PTPIPCodec.encode(type: .pong), on: self.event)
                } else if packet.type == .event {
                    var reader = PTPDataReader(packet.payload)
                    if reader.readUInt16() == 0x4008 { return }
                }
            }
            throw CancellationError()
        }
    }

    func startEvents(onEvent: @escaping @Sendable (Data) async -> Void = { _ in }) {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !closed, eventTask == nil else { return }
        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let packet = try await self.receive(on: self.event)
                    if packet.type == .ping {
                        try await self.send(try PTPIPCodec.encode(type: .pong), on: self.event)
                    } else if packet.type == .event { await onEvent(packet.payload) }
                }
            } catch {
                // Android detects transport loss on the command keepalive.
            }
        }
    }

    func sendPTP(command ptpCommand: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        guard !isClosed else { throw PTPSessionError.invalidated }
        clearPreviousTransfer()
        let request = try PTPIPCodec.commandRequest(from: ptpCommand, dataPhase: data == nil ? 1 : 2)
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
                guard packet.payload.readUInt32LE(at: 0) == ptpCommand.readUInt32LE(at: 8) else {
                    throw PTPSessionError.invalidResponse
                }
                received.append(packet.payload.dropFirst(4))
            case .commandResponse:
                guard packet.payload.count >= 6 else { throw PTPSessionError.invalidResponse }
                let response = try PTPIPCodec.commandResponseContainer(packet.payload)
                return (response, received)
            case .ping:
                try await send(try PTPIPCodec.encode(type: .pong), on: self.command)
            default:
                continue
            }
        }
    }

    func receivePTP(command ptpCommand: Data, sink: PTPDataSink) async throws -> PTPDataTransfer {
        try Task.checkCancellation()
        guard !isClosed else { throw PTPSessionError.invalidated }
        let transactionID = try PTPCodec.decode(ptpCommand).transactionID
        let state = PTPIPAbortState(transactionID: transactionID)
        setActiveAbort(state)
        // A local write failure can end the receiver before Cancel is sent.
        // Retain this transaction's state so recovery can take over the reader.
        defer { state.finishReceiver() }
        try await send(PTPIPCodec.commandRequest(from: ptpCommand, dataPhase: 1))
        var phase = PTPIPDownloadPhase(transactionID: transactionID)
        while true {
            let packet = try await receive(on: command, activity: state, onActivity: sink.activity)
            if packet.type == .ping {
                try await send(PTPIPCodec.encode(type: .pong), on: command)
            } else if state.isCancelled {
                if try state.consumeDrainPacket(packet) {
                    let response = try PTPIPCodec.commandResponseContainer(packet.payload)
                    state.markResponseSeen()
                    return PTPDataTransfer(response: response, receivedByteCount: phase.receivedByteCount,
                                           declaredByteCount: phase.declaredByteCount)
                }
            } else if let completed = try phase.consume(packet, sink: sink) {
                state.markResponseSeen()
                return completed
            }
        }
    }

    func cancelPTP(transactionID: UInt32) async -> Bool {
        // PTPSession invokes recovery in its uncancelled cleanup task.
        guard let state = currentAbort, state.transactionID == transactionID else { return false }
        if state.responseSeen { return true }
        state.requestCancel()
        do {
            try await send(PTPIPCodec.cancelRequest(transactionID: transactionID), on: command)
            while !state.responseSeen {
                if state.exceeded { throw PTPSessionError.invalidResponse }
                if state.receiverFinished {
                    // The original receiver failed after consuming a packet
                    // (e.g. output.write failed). There is now exactly one reader.
                    let packet = try await receive(on: command, activity: state,
                                                   timeoutNanoseconds: Self.cancelDrainTimeoutNanoseconds)
                    if packet.type == .ping {
                        try await send(PTPIPCodec.encode(type: .pong), on: command)
                    } else if try state.consumeDrainPacket(packet) {
                        state.markResponseSeen()
                    }
                } else {
                    // Android's SO_TIMEOUT is an inactivity limit, not a
                    // deadline for the whole drain. Renew it on received bytes.
                    guard !state.drainReadTimedOut else { throw PTPSessionError.timeout }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            return true
        } catch {
            close()
            return false
        }
    }

    private func clearPreviousTransfer() {
        lifecycleLock.lock(); activeAbort = nil; lifecycleLock.unlock()
    }

    private func start(_ connection: NWConnection, timeout: UInt64) async throws {
        try await AsyncDeadline.run(nanoseconds: timeout, timeoutError: PTPSessionError.timeout) {
            try await self.startConnection(connection)
        }
    }

    private func startConnection(_ connection: NWConnection) async throws {
        let flag = OnceFlag()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if flag.claim() { continuation.resume() }
                    case .failed(let error):
                        if flag.claim() { continuation.resume(throwing: error) }
                    case .cancelled:
                        if flag.claim() { continuation.resume(throwing: PTPSessionError.invalidated) }
                    default: break
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

    private func receive(on connection: NWConnection, activity: PTPIPAbortState? = nil,
                         timeoutNanoseconds: UInt64? = nil, onActivity: @Sendable () -> Void = {}) async throws -> PTPIPPacket {
        let header = try await readExactly(8, on: connection, activity: activity, timeoutNanoseconds: timeoutNanoseconds, onActivity: onActivity)
        let length = Int(header.readUInt32LE(at: 0))
        guard length >= 8, length <= PTPIPCodec.maxPacketLength else { throw PTPIPCodecError.malformedLength }
        let body = try await readExactly(length - 8, on: connection, activity: activity, timeoutNanoseconds: timeoutNanoseconds, onActivity: onActivity)
        return try PTPIPCodec.decode(header + body)
    }

    private func readExactly(_ count: Int, on connection: NWConnection, activity: PTPIPAbortState? = nil,
                             timeoutNanoseconds: UInt64? = nil, onActivity: @Sendable () -> Void = {}) async throws -> Data {
        if count == 0 { return Data() }
        var result = Data(capacity: count)
        while result.count < count {
            let remaining = count - result.count
            let chunk: Data
            if let timeoutNanoseconds {
                chunk = try await AsyncDeadline.run(nanoseconds: timeoutNanoseconds, timeoutError: PTPSessionError.timeout) {
                    try await self.readChunk(remaining, on: connection)
                }
            } else {
                chunk = try await readChunk(remaining, on: connection)
            }
            activity?.recordRead()
            onActivity()
            result.append(chunk)
        }
        return result
    }

    private func readChunk(_ maximumLength: Int, on connection: NWConnection) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let content, !content.isEmpty { continuation.resume(returning: content) }
                    else if isComplete { continuation.resume(throwing: PTPSessionError.invalidated) }
                    else { continuation.resume(throwing: PTPIPCodecError.malformedLength) }
                }
            }
        }, onCancel: { connection.cancel() })
    }

}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !claimed else { return false }; claimed = true; return true }
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

/// NikonCamera.drainCmdResponse counts the complete payload of every packet
/// except PING and COMMAND_RESPONSE (including transaction IDs and START_DATA).
struct PTPIPDrainBudget {
    private(set) var drained: UInt64 = 0
    let maximum: UInt64

    init(maximum: UInt64 = 32 * 1024 * 1024) { self.maximum = maximum }
    var exceeded: Bool { drained > maximum }

    mutating func consume(_ packet: PTPIPPacket) throws -> Bool {
        guard !exceeded else { throw PTPSessionError.invalidResponse }
        switch packet.type {
        case .commandResponse: return true
        case .ping: break
        default: drained += UInt64(packet.payload.count)
        }
        guard !exceeded else { throw PTPSessionError.invalidResponse }
        return false
    }
}

private final class PTPIPAbortState: @unchecked Sendable {
    let transactionID: UInt32
    private let lock = NSLock()
    private var cancelled = false
    private var response = false
    private var finished = false
    private var budget = PTPIPDrainBudget()
    private var lastRead = ContinuousClock.now

    init(transactionID: UInt32) { self.transactionID = transactionID }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var responseSeen: Bool { lock.withLock { response } }
    var receiverFinished: Bool { lock.withLock { finished } }
    var exceeded: Bool { lock.withLock { budget.exceeded } }
    var drainReadTimedOut: Bool { lock.withLock { lastRead.duration(to: .now) >= .seconds(3) } }
    func requestCancel() { lock.withLock { cancelled = true; lastRead = .now } }
    func recordRead() { lock.withLock { lastRead = .now } }
    func finishReceiver() { lock.withLock { finished = true } }
    func markResponseSeen() { lock.withLock { response = true } }
    func consumeDrainPacket(_ packet: PTPIPPacket) throws -> Bool {
        try lock.withLock { try budget.consume(packet) }
    }
}
