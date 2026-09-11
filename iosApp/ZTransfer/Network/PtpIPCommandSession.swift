import Foundation
import ZTransferShared

enum PtpIPSessionError: Error, LocalizedError {
    case malformedResponse, wrongTransaction, metadataLimit, openRejected(Int32)
    var errorDescription: String? {
        switch self {
        case .malformedResponse: return "相机事务响应不完整。"
        case .wrongTransaction: return "相机响应事务不匹配，连接已关闭。"
        case .metadataLimit: return "相机元数据超过本次读取上限。"
        case .openRejected(let code): return String(format: "相机拒绝打开会话：0x%04X。", code)
        }
    }
}

struct PtpIPCommandResult {
    let code: Int32
    let payload: Data?
}

struct PtpIPStreamResult {
    let code: Int32
    let bytes: Int64
    let declaredBytes: Int64
}

/// Owns a command socket after the transport handshake. FIFO covers the entire transaction,
/// not individual actor methods (actors alone permit interleaving whenever a read suspends).
/// Control datasets are bounded in memory; original-file download will use a separate streaming
/// transaction path under this same gate, not this metadata accumulator.
actor PtpIPCommandSession {
    private struct Waiter {
        let id: UUID
        let transferSlice: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private let stream: CameraTCPStream
    private let channel: PtpIPChannel
    private var lastTransactionId: Int32
    private var busy = false
    private var waiters: [Waiter] = []
    private var interactiveUses = Set<UUID>()
    private var terminalError: Error?

    init(stream: CameraTCPStream, initialTransactionId: Int32) {
        self.stream = stream
        self.channel = PtpIPChannel(stream: stream)
        self.lastTransactionId = initialTransactionId
    }

    func execute(
        operationCode: Int32,
        parameters: [Int32] = [],
        timeout: TimeInterval = 15,
        maximumPayloadBytes: Int = 1024 * 1024,
        requireIdle: Bool = false,
        outgoingData: Data? = nil,
        backgroundAdmission: (@Sendable () async -> Bool)? = nil
    ) async throws -> PtpIPCommandResult {
        let prefixSize = Int(PtpIpOperationCodec.shared.DATA_PREFIX_SIZE)
        guard timeout.isFinite, timeout > 0, maximumPayloadBytes >= 0,
              maximumPayloadBytes <= Int(PtpIpPacketCodec.shared.MAX_PACKET_SIZE) - prefixSize,
              (0...0xFFFF).contains(operationCode), parameters.count <= 5, (outgoingData?.count ?? 0) <= 64 * 1024 else {
            throw CameraStreamError.invalidArgument
        }
        try await acquire(requireIdle: requireIdle)
        defer { release() }
        // Cancellation while waiting does not tear down somebody else's active transaction.
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        // Recheck only speculative work AFTER the full-transaction gate is acquired. Rejection sends no command,
        // consumes no TID and does not terminate somebody else's connection. Normal commands take the original path.
        if let backgroundAdmission, !(await backgroundAdmission()) { throw CameraStreamError.operationInProgress }
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        lastTransactionId &+= 1
        let transactionId = lastTransactionId
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func remainingTime() throws -> TimeInterval {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CameraStreamError.timedOut }
            return remaining
        }
        do {
            try await channel.sendCommand(
                operationCode: operationCode, transactionId: transactionId,
                parameters: parameters, data: outgoingData, timeout: remainingTime()
            )
            var payload = Data()
            while true {
                // Response/StartData have fixed metadata even when the caller expects no data.
                let packet = try await channel.readControlPacket(
                    timeout: remainingTime(), maximumPayloadBytes: max(64, maximumPayloadBytes + prefixSize)
                )
                try Task.checkCancellation()
                switch packet.type {
                case PtpConstants.shared.CMD_RESPONSE:
                    guard let response = PtpIPChannel.operationResponse(packet.payload) else {
                        throw PtpIPSessionError.malformedResponse
                    }
                    guard response.transactionId == transactionId else { throw PtpIPSessionError.wrongTransaction }
                    return PtpIPCommandResult(code: response.code, payload: payload.isEmpty ? nil : payload)
                case PtpConstants.shared.DATA_PACKET, PtpConstants.shared.END_DATA_PACKET:
                    guard let id = PtpIPChannel.dataTransactionId(packet.payload) else {
                        throw PtpIPSessionError.malformedResponse
                    }
                    guard id == transactionId else { throw PtpIPSessionError.wrongTransaction }
                    let chunk = packet.payload.dropFirst(prefixSize)
                    guard chunk.count <= maximumPayloadBytes - payload.count else { throw PtpIPSessionError.metadataLimit }
                    payload.append(contentsOf: chunk)
                case PtpConstants.shared.START_DATA_PACKET:
                    // Android's control-data reader does not depend on the advertised data length.
                    // Preserve that tolerance; still prevent cross-transaction data from being used.
                    guard let id = PtpIPChannel.dataTransactionId(packet.payload) else {
                        throw PtpIPSessionError.malformedResponse
                    }
                    guard id == transactionId else { throw PtpIPSessionError.wrongTransaction }
                case PtpConstants.shared.PING:
                    try await channel.sendPong(timeout: remainingTime())
                default:
                    // Match the control reader's tolerance of other packet types, bounded by the
                    // overall operation deadline so unrelated traffic cannot extend it forever.
                    break
                }
            }
        } catch {
            terminate(error)
            throw error
        }
    }

    func close() { terminate(CameraStreamError.closed) }

    /// One complete data-in transaction. Response is always consumed after END_DATA, and media
    /// bytes never cross Kotlin/ObjC. Cancellation/sink failure sends shared Cancel and drains
    /// under the same gate; malformed/truncated/over-budget streams are never reused.
    func executeStreaming(
        operationCode: Int32, parameters: [Int32], idleTimeout: TimeInterval = 30,
        maximumBytes: Int64 = Int64.max, consume: @escaping (Data) throws -> Void
    ) async throws -> PtpIPStreamResult {
        guard idleTimeout.isFinite, idleTimeout > 0, maximumBytes >= 0,
              (0...0xFFFF).contains(operationCode), parameters.count <= 5 else {
            throw CameraStreamError.invalidArgument
        }
        while true {
            try await acquire(requireIdle: false, transferSlice: true)
            // The resumed slice rechecks on this actor, with no further suspension before TID
            // assignment. A window may have opened while it was resuming from the FIFO.
            if interactiveUses.isEmpty { break }
            release()
        }
        defer { release() }
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        lastTransactionId &+= 1
        let transactionID = lastTransactionId
        let recovery = StreamingAbortRecovery(channel: channel, stream: stream, transactionID: transactionID)
        // An unstructured child deliberately does NOT inherit caller cancellation. The caller
        // still awaits its terminal result while holding the gate; no detached transaction escapes.
        let operation = Task {
            try await self.streamingTransaction(operationCode: operationCode, parameters: parameters,
                idleTimeout: idleTimeout, maximumBytes: maximumBytes, transactionID: transactionID,
                recovery: recovery, consume: consume)
        }
        return try await withTaskCancellationHandler(operation: {
            try await operation.value
        }, onCancel: { recovery.request(CancellationError()) })
    }

    private func streamingTransaction(operationCode: Int32, parameters: [Int32], idleTimeout: TimeInterval,
        maximumBytes: Int64, transactionID: Int32, recovery: StreamingAbortRecovery,
        consume: @escaping (Data) throws -> Void) async throws -> PtpIPStreamResult {
        var drained = false
        var discarded: Int64 = 0
        var written: Int64 = 0
        var declared: Int64 = -1
        do {
            try await channel.sendCommand(operationCode: operationCode, transactionId: transactionID,
                                           parameters: parameters, timeout: idleTimeout)
            recovery.arm() // Cancel cannot race the command write or target the preceding TID.
            while true {
                try Task.checkCancellation()
                var frameType: Int32 = 0
                var prefix = Data()
                var control = Data()
                let type = try await channel.readPacketPayload(
                    timeout: idleTimeout, maximumPayloadBytes: Int(PtpIpPacketCodec.shared.MAX_PACKET_SIZE) - 8,
                    resetTimeoutAfterChunk: true,
                    inspectHeader: { type, length in
                        frameType = type
                        if type == PtpConstants.shared.DATA_PACKET || type == PtpConstants.shared.END_DATA_PACKET {
                            guard length >= 4 else { throw PtpIPSessionError.malformedResponse }
                        } else if length > 64 * 1024 {
                            throw PtpIPChannelError.payloadTooLarge
                        }
                    },
                    consume: { chunk in
                        if frameType == PtpConstants.shared.DATA_PACKET || frameType == PtpConstants.shared.END_DATA_PACKET {
                            let prefixCount = min(4 - prefix.count, chunk.count)
                            if prefixCount > 0 {
                                prefix.append(contentsOf: chunk.prefix(prefixCount))
                                if prefix.count == 4 {
                                    guard PtpIPChannel.dataTransactionId(prefix) == transactionID else {
                                        throw PtpIPSessionError.wrongTransaction
                                    }
                                }
                            }
                            let data = Data(chunk.dropFirst(prefixCount))
                            guard Int64(data.count) <= maximumBytes - written else { throw PtpIPSessionError.metadataLimit }
                            if !data.isEmpty {
                                if recovery.error == nil {
                                    do { try consume(data); written += Int64(data.count) }
                                    catch { recovery.request(error) }
                                }
                                if recovery.error != nil {
                                    discarded += Int64(chunk.count)
                                    guard discarded <= StreamingAbortRecovery.byteBudget else {
                                        throw PtpIPSessionError.metadataLimit
                                    }
                                }
                            }
                        } else {
                            control.append(chunk)
                        }
                    }
                )
                switch type {
                case PtpConstants.shared.CMD_RESPONSE:
                    guard let response = PtpIPChannel.operationResponse(control) else { throw PtpIPSessionError.malformedResponse }
                    guard response.transactionId == transactionID else { throw PtpIPSessionError.wrongTransaction }
                    drained = true
                    await recovery.finish()
                    if let error = recovery.error { throw error }
                    return PtpIPStreamResult(code: response.code, bytes: written, declaredBytes: declared)
                case PtpConstants.shared.START_DATA_PACKET:
                    guard let start = PtpIPChannel.dataStart(control) else { throw PtpIPSessionError.malformedResponse }
                    guard start.transactionId == transactionID else { throw PtpIPSessionError.wrongTransaction }
                    declared = start.declaredBytes
                case PtpConstants.shared.PING:
                    try await channel.sendPong(timeout: idleTimeout)
                default: break
                }
            }
        } catch {
            await recovery.finish()
            if !drained || recovery.connectionPoisoned { terminate(error) }
            throw recovery.error ?? error
        }
    }

    func isClosed() -> Bool { terminalError != nil }

    /// A priority window does not hold the socket. Ordinary commands remain FIFO; only the
    /// next download slice waits, including the gap between current-page FHD and EXIF.
    func beginInteractivePreview() throws -> UUID {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        let token = UUID()
        interactiveUses.insert(token)
        return token
    }

    func endInteractivePreview(_ token: UUID) {
        guard interactiveUses.remove(token) != nil else { return }
        if !busy { release() }
    }

    #if DEBUG
    func pendingTransferSliceCount() -> Int { waiters.filter(\.transferSlice).count }
    #endif

    private func acquire(requireIdle: Bool, transferSlice: Bool = false) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancellation can precede registration. Check again while actor-isolated so
                // cancelWaiter cannot run too early and leave an already-cancelled waiter queued.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else if busy || (transferSlice && !interactiveUses.isEmpty) {
                    if requireIdle {
                        continuation.resume(throwing: CameraStreamError.operationInProgress)
                    } else {
                        waiters.append(Waiter(id: id, transferSlice: transferSlice, continuation: continuation))
                    }
                } else {
                    busy = true
                    continuation.resume()
                }
            }
        }, onCancel: { Task { await self.cancelWaiter(id) } })
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if terminalError == nil,
           let index = waiters.firstIndex(where: { !$0.transferSlice || interactiveUses.isEmpty }) {
            busy = true
            waiters.remove(at: index).continuation.resume()
        } else {
            busy = false
        }
    }

    private func terminate(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        interactiveUses.removeAll()
        stream.close()
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: error) }
    }
}


/// Bounded recovery for one TID. The lock only protects tiny state; no socket work runs under it.
private final class StreamingAbortRecovery: @unchecked Sendable {
    static let byteBudget: Int64 = 32 * 1024 * 1024 // Android CANCEL_DRAIN_BUDGET.
    static let timeoutNanoseconds: UInt64 = 3_000_000_000 // Android 3-second drain safety boundary.
    private let lock = NSLock()
    private let channel: PtpIPChannel
    private let stream: CameraTCPStream
    private let transactionID: Int32
    private var failure: Error?
    private var poisoned = false
    private var armed = false
    private var finished = false
    private var sender: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    init(channel: PtpIPChannel, stream: CameraTCPStream, transactionID: Int32) {
        self.channel = channel; self.stream = stream; self.transactionID = transactionID
    }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    var connectionPoisoned: Bool { lock.lock(); defer { lock.unlock() }; return poisoned }
    func request(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if failure == nil { failure = error }
        startLocked()
    }
    func arm() {
        lock.lock(); defer { lock.unlock() }
        armed = true; startLocked()
    }
    private func startLocked() {
        guard armed, failure != nil, sender == nil, !finished else { return }
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.timeoutNanoseconds) } catch { return }
            self?.expire()
        }
        sender = Task { [weak self, channel, transactionID] in
            do { try await channel.sendCancel(transactionID: transactionID, timeout: 3) }
            catch { self?.closePoisoned() }
        }
    }
    private func expire() {
        lock.lock(); defer { lock.unlock() }
        if !finished { poisoned = true; stream.close() }
    }
    private func closePoisoned() {
        lock.lock(); defer { lock.unlock() }
        poisoned = true; stream.close()
    }
    private func end() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        finished = true; watchdog?.cancel(); watchdog = nil
        return sender
    }
    func finish() async { await end()?.value }
}
