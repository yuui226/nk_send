import Foundation
import Network

/// PTP/IP command transport. The command and event sockets are separate, as in
/// Nikon's Android implementation; one instance serializes command transactions
/// through PTPSession and never lets a partial packet leak into the next request.
final class PTPIPSocketTransport: @unchecked Sendable, PTPCommandTransport {
    var completesBufferedCommandsAfterCancellation: Bool { true }
    let host: String
    let port: UInt16
    private let command: PTPIPSocketConnection
    private let event: PTPIPSocketConnection
    private let queue = DispatchQueue(label: "com.ztransfer.ptpip")
    private let lifecycleLock = NSLock()
    private let receiveBufferLock = NSLock()
    private var closed = false
    private var eventTask: Task<Void, Never>?
    private var eventDeliveryTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<STAEvent>.Continuation?
    private var activeAbort: PTPIPAbortState?
    /// Android wraps each PTP/IP input stream in a 64 KiB BufferedInputStream.
    /// Keep bytes beyond the current packet field here so an 8-byte header and
    /// its body do not require separate Network.framework receive callbacks.
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
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

    private init(host: String, port: UInt16, command: PTPIPSocketConnection, event: PTPIPSocketConnection) {
        self.host = host; self.port = port; self.command = command; self.event = event
    }

    static func parameters(localAddress: String? = nil, sta: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Android enables TCP_NODELAY on the command socket. STA catalog and
        // thumbnail traffic consists of many tiny request/response pairs, so
        // Nagle + delayed ACK can otherwise add a full latency interval to
        // practically every object-size or partial-object command.
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
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
                     connectionParameters: NWParameters? = nil,
                     backend: PTPIPSocketBackend = .networkFramework) async throws -> PTPIPSocketTransport {
        let parameters = connectionParameters ?? parameters(localAddress: localAddress, sta: staInitiatorID != nil)
        let command = PTPIPSocketConnection(host: host, port: port, localAddress: localAddress, parameters: parameters, backend: backend)
        let event = PTPIPSocketConnection(host: host, port: port, localAddress: localAddress, parameters: parameters,
                                         backend: backend, isCommandChannel: false)
        let transport = PTPIPSocketTransport(host: host, port: port, command: command, event: event)
        do {
            try await transport.start(command, timeout: 3_000_000_000)
            let initialization = try staInitiatorID.map { try PTPIPCodec.staInitCommandRequest(initiatorID: $0) }
                ?? PTPIPCodec.initCommandRequest()
            let ack = try await transport.exchangeInitialization(initialization, on: command)
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
            let eventAck = try await transport.exchangeInitialization(
                PTPIPCodec.initEventRequest(connectionNumber: connectionNumber), on: event)
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
        let delivery = eventDeliveryTask
        let events = eventContinuation
        eventTask = nil
        eventDeliveryTask = nil
        eventContinuation = nil
        lifecycleLock.unlock()
        delivery?.cancel()
        events?.finish()
        task?.cancel()
        command.cancel(); event.cancel()
    }

    /// Android's NikonCamera.close keeps the command mutex and finishes
    /// CloseSession even when its caller has been cancelled. Retire only a
    /// session that reached a successful OpenSession response.
    static func retireOpenedSession(_ session: PTPSession, socket: PTPIPSocketTransport,
                                    opened: Bool) async {
        let cleanup = Task.detached {
            if opened {
                _ = try? await session.executeResponse(operation: PTPConstants.closeSession,
                                                       timeoutNanoseconds: PTPConstants.cameraReadTimeoutNanoseconds)
            }
            await session.invalidate()
            socket.close()
        }
        await cleanup.value
    }

    /// Only called before starting the continuous reader. Missing pacing events
    /// never undo the already-acknowledged pairing (NikonCamera.completeInitialPairing).
    func waitForPairingEvent(timeoutNanoseconds: UInt64 = 8_000_000_000) async {
        let usesSocketTimeout = event.network == nil
        let operation: @Sendable () async throws -> Void = {
            let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(clamping: timeoutNanoseconds)))
            while !Task.isCancelled {
                var readTimeout: UInt64?
                if usesSocketTimeout {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    guard remaining > .zero else { return }
                    // completeInitialPairing sets SO_TIMEOUT from the remaining
                    // whole-millisecond budget before each packet; fragmented
                    // reads inside that packet each receive the same budget.
                    let parts = remaining.components
                    let milliseconds = max(1, parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
                    readTimeout = UInt64(milliseconds) * 1_000_000
                }
                let packet = try await self.receive(on: self.event, timeoutNanoseconds: readTimeout)
                if packet.type == .ping {
                    try await self.send(try PTPIPCodec.encode(type: .pong), on: self.event)
                } else if packet.type == .event {
                    var reader = PTPDataReader(packet.payload)
                    if reader.readUInt16() == 0x4008 { return }
                }
            }
            throw CancellationError()
        }
        if usesSocketTimeout {
            // Wait until the actual reader finishes. A detached total timer
            // could return while an old read still owns the event socket.
            _ = try? await AsyncDeadline.run(operation: operation)
        } else {
            _ = try? await AsyncDeadline.run(nanoseconds: timeoutNanoseconds,
                                            timeoutError: PTPSessionError.timeout, operation: operation)
        }
    }

    func startEvents(onEvent: (@Sendable (STAEvent) async -> Void)? = nil) {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !closed, eventTask == nil else { return }
        // NikonCamera uses Channel(capacity=64).trySend: keep FIFO entries
        // already queued and drop a new event when full, never block PING/PONG
        // on CameraRepository's actor. Invalid payloads consume no capacity.
        var continuation: AsyncStream<STAEvent>.Continuation?
        if let onEvent {
            let events = AsyncStream<STAEvent>(bufferingPolicy: .bufferingOldest(64)) { continuation = $0 }
            eventContinuation = continuation
            eventDeliveryTask = Task {
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await onEvent(event)
                }
            }
        }
        let eventOutput = continuation
        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let packet = try await self.receive(on: self.event)
                    if packet.type == .ping {
                        try await self.send(try PTPIPCodec.encode(type: .pong), on: self.event)
                    } else if packet.type == .event, let parsed = STAEvent.socket(packet.payload) {
                        eventOutput?.yield(parsed)
                    }
                }
            } catch {
                // Android detects transport loss on the command keepalive.
            }
        }
    }

    func sendPTP(command ptpCommand: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        try await sendPTP(command: ptpCommand, data: data, readTimeoutNanoseconds: PTPConstants.cameraReadTimeoutNanoseconds)
    }

    func sendPTP(command ptpCommand: Data, data: Data?, readTimeoutNanoseconds: UInt64) async throws -> (response: Data, payload: Data) {
        guard !isClosed else { throw PTPSessionError.invalidated }
        let transactionID = try PTPCodec.decode(ptpCommand).transactionID
        let state = PTPIPAbortState(transactionID: transactionID)
        setActiveAbort(state)
        // Cancellation of one thumbnail/catalog request must never cancel the
        // shared NWConnection. The uncancelled PTPSession recovery task sends
        // PTP/IP Cancel while this receiver drains to COMMAND_RESPONSE.
        defer { state.finishReceiver() }
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
            let packet = try await receive(on: self.command, activity: state,
                                            timeoutNanoseconds: command.network == nil ? readTimeoutNanoseconds : nil)
            if packet.type == .ping {
                try await send(try PTPIPCodec.encode(type: .pong), on: self.command)
                continue
            }
            if state.isCancelled {
                if try state.consumeDrainPacket(packet) {
                    let response = try PTPIPCodec.commandResponseContainer(packet.payload)
                    state.markResponseSeen()
                    return (response, received)
                }
                continue
            }
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
                state.markResponseSeen()
                return (response, received)
            default:
                continue
            }
        }
    }

    func receivePTP(command ptpCommand: Data, sink: PTPDataSink) async throws -> PTPDataTransfer {
        try Task.checkCancellation()
        guard !isClosed else { throw PTPSessionError.invalidated }
        sink.diagnostics?.transport(bsdSocket: command.network == nil, receiveBufferBytes: command.receiveBufferBytes,
                                    tcpSnapshot: { [command] in command.diagnosticSnapshot() })
        let transactionID = try PTPCodec.decode(ptpCommand).transactionID
        let state = PTPIPAbortState(transactionID: transactionID)
        setActiveAbort(state)
        // A local write failure can end the receiver before Cancel is sent.
        // Retain this transaction's state so recovery can take over the reader.
        defer { state.finishReceiver() }
        try await send(PTPIPCodec.commandRequest(from: ptpCommand, dataPhase: 1))
        sink.diagnostics?.commandSent()
        if command.network == nil {
            // Transfer existing read-ahead into the queue-confined reader and
            // restore leftovers even on sink failure, before recovery takes over.
            let buffered = takeBuffered(upTo: Int.max, for: command)
            return try await command.withPOSIXPacketPump(
                buffered: buffered, activity: { state.recordRead(); sink.activity() },
                diagnostics: sink.diagnostics,
                readTimeoutNanoseconds: sink.readTimeoutNanoseconds ?? PTPConstants.cameraReadTimeoutNanoseconds,
                preserveBuffered: { [self] bytes in storeBuffered(bytes, for: command) }
            ) { readPacket, sendPacket in
                var phase = PTPIPDownloadPhase(transactionID: transactionID)
                while true {
                    var completed: PTPDataTransfer?
                    var needsPong = false
                    try readPacket { type, payload in
                        if type == .ping {
                            needsPong = true
                        } else if state.isCancelled {
                            // Exceptional drain keeps the existing framing and
                            // byte budget. No borrowed pointer escapes the read.
                            completed = try Self.consumeDownloadPacket(PTPIPPacket(type: type, payload: Data(payload)),
                                                                       phase: &phase, state: state, sink: sink)
                        } else {
                            completed = try phase.consume(type: type, payload: payload, sink: sink)
                            if completed != nil { state.markResponseSeen() }
                        }
                    }
                    if needsPong { try sendPacket(PTPIPCodec.encode(type: .pong)) }
                    if let completed { return completed }
                }
            }
        }
        var phase = PTPIPDownloadPhase(transactionID: transactionID)
        while true {
            let packet = try await receive(on: command, activity: state,
                                           coalesceReads: false, onActivity: sink.activity, diagnostics: sink.diagnostics)
            if packet.type == .ping {
                try await send(PTPIPCodec.encode(type: .pong), on: command)
            } else if let completed = try Self.consumeDownloadPacket(packet, phase: &phase, state: state, sink: sink) {
                return completed
            }
        }
    }

    private static func consumeDownloadPacket(_ packet: PTPIPPacket, phase: inout PTPIPDownloadPhase,
                                              state: PTPIPAbortState, sink: PTPDataSink) throws -> PTPDataTransfer? {
        if state.isCancelled {
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
        return nil
    }

    var usesSocketReadTimeouts: Bool { command.network == nil }

    private func exchangeInitialization(_ packet: Data, on connection: PTPIPSocketConnection) async throws -> PTPIPPacket {
        if connection.network == nil {
            return try await AsyncDeadline.run {
                try await self.send(packet, on: connection)
                return try await self.receive(on: connection, timeoutNanoseconds: 5_000_000_000)
            }
        }
        return try await AsyncDeadline.run(nanoseconds: 5_000_000_000, timeoutError: PTPSessionError.timeout) {
            try await self.send(packet, on: connection)
            return try await self.receive(on: connection)
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
                                                   timeoutNanoseconds: Self.cancelDrainTimeoutNanoseconds,
                                                   coalesceReads: false)
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

    private func start(_ connection: PTPIPSocketConnection, timeout: UInt64) async throws {
        try await AsyncDeadline.run(nanoseconds: timeout, timeoutError: PTPSessionError.timeout) {
            if let network = connection.network { try await self.startConnection(network) }
            else { try await connection.startPOSIX() }
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

    private func send(_ data: Data, on connection: PTPIPSocketConnection? = nil) async throws {
        let connection = connection ?? command
        guard let network = connection.network else { return try await connection.sendPOSIX(data) }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                network.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }, onCancel: {
            // An opened command/event socket is session-owned. Its transaction
            // recovery decides whether retirement is required; cancelling one
            // caller is not authority to close the shared connection.
        })
    }

    private func receive(on connection: PTPIPSocketConnection, activity: PTPIPAbortState? = nil,
                         timeoutNanoseconds: UInt64? = nil, coalesceReads: Bool = true,
                         onActivity: @Sendable () -> Void = {}, diagnostics: PTPTransferDiagnostics? = nil) async throws -> PTPIPPacket {
        let header = try await readExactly(8, on: connection, activity: activity,
                                           timeoutNanoseconds: timeoutNanoseconds,
                                           coalesceReads: coalesceReads, onActivity: onActivity, diagnostics: diagnostics)
        let length = Int(header.readUInt32LE(at: 0))
        guard length >= 8, length <= PTPIPCodec.maxPacketLength else { throw PTPIPCodecError.malformedLength }
        let body = try await readExactly(length - 8, on: connection, activity: activity,
                                         timeoutNanoseconds: timeoutNanoseconds,
                                         coalesceReads: coalesceReads, onActivity: onActivity, diagnostics: diagnostics)
        return try PTPIPCodec.decode(header: header, body: body)
    }

    private func readExactly(_ count: Int, on connection: PTPIPSocketConnection, activity: PTPIPAbortState? = nil,
                             timeoutNanoseconds: UInt64? = nil, coalesceReads: Bool,
                             onActivity: @Sendable () -> Void = {}, diagnostics: PTPTransferDiagnostics? = nil) async throws -> Data {
        if count == 0 { return Data() }
        // Defer allocating an assembly buffer. Network.framework commonly
        // delivers a complete PTP/IP body in one callback; returning that Data
        // directly avoids allocating and copying every download packet before
        // the file sink writes it. Only fragmented reads need concatenation.
        var result = Data()
        var reservedAssemblyCapacity = false
        while result.count < count {
            let remaining = count - result.count
            let buffered = takeBuffered(upTo: remaining, for: connection)
            if !buffered.isEmpty {
                if result.isEmpty, buffered.count == count { return buffered }
                if !reservedAssemblyCapacity {
                    result.reserveCapacity(count)
                    reservedAssemblyCapacity = true
                }
                result.append(buffered)
                continue
            }
            let chunk: Data
            // Ordinary replies mirror Android's 64 KiB BufferedInputStream and
            // may coalesce header + body. Streaming also coalesces small
            // packets, with a one-byte minimum so every arrival renews the
            // inactivity timeout. Large bodies can take up to 4 MiB at once.
            let window = ptpipReadWindow(remaining: remaining, coalesce: coalesceReads)
            let minimumLength = window.minimum
            let maximumLength = window.maximum
            let readStarted = diagnostics.map { _ in ContinuousClock.now }
            if connection.network == nil {
                // The socket bounds each blocking recv. Do not race a second
                // task timer against a partially received header/body.
                chunk = try await connection.receivePOSIX(maximumLength: maximumLength, diagnostics: diagnostics,
                                                          readTimeoutNanoseconds: timeoutNanoseconds)
            } else if let timeoutNanoseconds {
                chunk = try await AsyncDeadline.run(nanoseconds: timeoutNanoseconds, timeoutError: PTPSessionError.timeout) {
                    try await self.readChunk(minimumLength: minimumLength,
                                             maximumLength: maximumLength,
                                             on: connection, diagnostics: diagnostics)
                }
            } else {
                chunk = try await readChunk(minimumLength: minimumLength,
                                            maximumLength: maximumLength,
                                            on: connection, diagnostics: diagnostics)
            }
            activity?.recordRead()
            onActivity()
            if let readStarted { diagnostics?.read(bytes: chunk.count, waitedMS: PTPTransferDiagnostics.milliseconds(since: readStarted)) }
            if chunk.count <= remaining {
                if result.isEmpty, chunk.count == count { return chunk }
                if !reservedAssemblyCapacity {
                    result.reserveCapacity(count)
                    reservedAssemblyCapacity = true
                }
                result.append(chunk)
            } else {
                if !reservedAssemblyCapacity {
                    result.reserveCapacity(count)
                    reservedAssemblyCapacity = true
                }
                result.append(chunk.prefix(remaining))
                storeBuffered(Data(chunk.dropFirst(remaining)), for: connection)
            }
        }
        return result
    }

    private func takeBuffered(upTo count: Int, for connection: PTPIPSocketConnection) -> Data {
        receiveBufferLock.lock(); defer { receiveBufferLock.unlock() }
        let key = ObjectIdentifier(connection)
        guard var bytes = receiveBuffers[key], !bytes.isEmpty else { return Data() }
        let length = min(count, bytes.count)
        let result = Data(bytes.prefix(length))
        bytes.removeFirst(length)
        if bytes.isEmpty { receiveBuffers.removeValue(forKey: key) }
        else { receiveBuffers[key] = bytes }
        return result
    }

    private func storeBuffered(_ bytes: Data, for connection: PTPIPSocketConnection) {
        guard !bytes.isEmpty else { return }
        receiveBufferLock.lock(); defer { receiveBufferLock.unlock() }
        receiveBuffers[ObjectIdentifier(connection), default: Data()].append(bytes)
    }

    private func readChunk(minimumLength: Int, maximumLength: Int,
                           on connection: PTPIPSocketConnection, diagnostics: PTPTransferDiagnostics? = nil) async throws -> Data {
        guard let network = connection.network else {
            return try await connection.receivePOSIX(maximumLength: maximumLength, diagnostics: diagnostics)
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                network.receive(minimumIncompleteLength: minimumLength,
                                   maximumLength: maximumLength) { content, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let content, !content.isEmpty { continuation.resume(returning: content) }
                    else if isComplete { continuation.resume(throwing: PTPSessionError.invalidated) }
                    else { continuation.resume(throwing: PTPIPCodecError.malformedLength) }
                }
            }
        }, onCancel: {
            // Keep the outstanding receive alive for PTP Cancel + drain. Open
            // handshake failures still close both sockets in `open`'s catch.
        })
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
    func recordRead() {
        lock.withLock {
            // Only recovery uses this deadline; requestCancel starts it.
            // Normal STA reads are timed by the socket, not a second clock.
            if cancelled { lastRead = .now }
        }
    }
    func finishReceiver() { lock.withLock { finished = true } }
    func markResponseSeen() { lock.withLock { response = true } }
    func consumeDrainPacket(_ packet: PTPIPPacket) throws -> Bool {
        try lock.withLock { try budget.consume(packet) }
    }
}
