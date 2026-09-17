import Foundation

protocol PTPCommandTransport: Sendable {
    /// Raw socket/USB transports need the session watchdog. Framework-owned
    /// transports can suspend communication independently of Swift tasks and
    /// must rely on their own terminal callback/error instead.
    var managesCommandTimeouts: Bool { get }
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data)
    func receivePTP(command: Data, sink: PTPDataSink) async throws -> PTPDataTransfer
    /// Requests cancellation of an active data phase. Transports that can drain
    /// the final response keep the session reusable; others return false.
    func cancelPTP(transactionID: UInt32) async -> Bool
}

struct PTPDataSink: Sendable {
    let started: @Sendable (UInt64?) -> Void
    let received: @Sendable (Data) throws -> Void
    var activity: @Sendable () -> Void = {}
}

struct PTPDataTransfer: Sendable {
    let response: Data
    let receivedByteCount: UInt64
    let declaredByteCount: UInt64?
}

extension PTPCommandTransport {
    var managesCommandTimeouts: Bool { false }
    func cancelPTP(transactionID: UInt32) async -> Bool { false }

    /// ImageCaptureCore delivers one completed data phase. Socket transports
    /// override this adapter to deliver packets directly without buffering the
    /// whole object; the session still owns the transaction in both cases.
    func receivePTP(command: Data, sink: PTPDataSink) async throws -> PTPDataTransfer {
        let result = try await sendPTP(command: command, data: nil)
        try Task.checkCancellation()
        sink.started(nil)
        try Task.checkCancellation()
        try sink.received(result.payload)
        return PTPDataTransfer(response: result.response,
                               receivedByteCount: UInt64(result.payload.count), declaredByteCount: nil)
    }
}

struct PTPResponse: Equatable, Sendable {
    let code: UInt16
    let transactionID: UInt32
    let data: Data
    var receivedByteCount: UInt64 = 0
    var declaredByteCount: UInt64? = nil
}

enum PTPSessionError: Error, Equatable, Sendable {
    case invalidResponse
    case unexpectedResponseType(PTPContainerType)
    case responseCode(UInt16)
    case timeout
    case invalidated
}

/// A short sequence may retain the command mutex across several responses and
/// camera settling delays. The capability expires when its owning body returns.
struct PTPCommandSequence: Sendable {
    fileprivate let send: @Sendable (UInt16, [UInt32], Data?, UInt64?) async throws -> PTPResponse

    func executeResponse(operation: UInt16, parameters: [UInt32] = [], data: Data? = nil,
                         timeoutNanoseconds: UInt64? = nil) async throws -> PTPResponse {
        try await send(operation, parameters, data, timeoutNanoseconds)
    }
}

/// Android's I/O mutex stays held through the entire transaction. Actor isolation
/// alone cannot provide that guarantee because `await` permits reentrancy.
actor PTPSession {
    private let transport: PTPCommandTransport
    private let defaultTimeoutNanoseconds: UInt64
    private var nextTransactionID: UInt32
    private var executing = false
    private var invalidated = false
    private var sequenceOwner: UUID?
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(transport: PTPCommandTransport, firstTransactionID: UInt32 = 1, defaultTimeoutNanoseconds: UInt64 = 15_000_000_000) {
        self.transport = transport
        self.defaultTimeoutNanoseconds = defaultTimeoutNanoseconds
        self.nextTransactionID = firstTransactionID
    }

    func execute(operation: UInt16, parameters: [UInt32] = [], data: Data? = nil, timeoutNanoseconds: UInt64? = nil) async throws -> PTPResponse {
        let response = try await executeResponse(operation: operation, parameters: parameters, data: data,
                                                 timeoutNanoseconds: timeoutNanoseconds)
        guard response.code == PTPConstants.responseOK else { throw PTPSessionError.responseCode(response.code) }
        return response
    }

    /// Compatibility probes must retain both negative response codes and data,
    /// exactly like Android's recvRespWithPayload. They do not invalidate I/O.
    func executeResponse(operation: UInt16, parameters: [UInt32] = [], data: Data? = nil,
                         timeoutNanoseconds: UInt64? = nil) async throws -> PTPResponse {
        try await acquire()
        defer { release() }
        return try await perform(operation: operation, parameters: parameters, data: data, timeoutNanoseconds: timeoutNanoseconds ?? defaultTimeoutNanoseconds)
    }

    func withCommandSequence<T: Sendable>(
        _ body: @Sendable (PTPCommandSequence) async throws -> T
    ) async throws -> T {
        try await acquire()
        let owner = UUID()
        sequenceOwner = owner
        defer { sequenceOwner = nil; release() }
        let commands = PTPCommandSequence { [self] operation, parameters, data, timeout in
            try await performSequence(owner: owner, operation: operation, parameters: parameters,
                                      data: data, timeoutNanoseconds: timeout)
        }
        return try await body(commands)
    }

    private func performSequence(owner: UUID, operation: UInt16, parameters: [UInt32], data: Data?,
                                 timeoutNanoseconds: UInt64?) async throws -> PTPResponse {
        guard sequenceOwner == owner else { throw PTPSessionError.invalidated }
        return try await perform(operation: operation, parameters: parameters, data: data,
                                 timeoutNanoseconds: timeoutNanoseconds ?? defaultTimeoutNanoseconds)
    }

    func executeReceiving(operation: UInt16, parameters: [UInt32], sink: PTPDataSink,
                          timeoutNanoseconds: UInt64? = nil) async throws -> PTPResponse {
        try await acquire()
        defer { release() }
        return try await perform(operation: operation, parameters: parameters, data: nil,
                                 timeoutNanoseconds: timeoutNanoseconds ?? defaultTimeoutNanoseconds, sink: sink)
    }

    /// Small download probes (GetObjectSize) retain their response bytes but
    /// share the data transaction's inactivity timeout and abort boundary.
    func executeReceivingBuffered(operation: UInt16, parameters: [UInt32],
                                  timeoutNanoseconds: UInt64? = nil) async throws -> PTPResponse {
        let buffer = PTPReceiveBuffer()
        let response = try await executeReceiving(operation: operation, parameters: parameters, sink: buffer.sink,
                                                   timeoutNanoseconds: timeoutNanoseconds)
        return PTPResponse(code: response.code, transactionID: response.transactionID, data: buffer.data,
                           receivedByteCount: response.receivedByteCount, declaredByteCount: response.declaredByteCount)
    }

    var hasPendingCommand: Bool { executing || !waiters.isEmpty }
    var isInvalidated: Bool { invalidated }

    func keepaliveIfIdle() async -> Bool {
        guard !executing, waiters.isEmpty else { return true }
        executing = true
        defer { release() }
        do {
            _ = try await perform(operation: PTPConstants.getStorageIDs, parameters: [], data: nil,
                                  timeoutNanoseconds: 60_000_000_000)
            return true // Any complete response, including DeviceBusy, proves liveness.
        } catch { return false }
    }

    private func perform(operation: UInt16, parameters: [UInt32], data: Data?,
                         timeoutNanoseconds: UInt64, sink: PTPDataSink? = nil) async throws -> PTPResponse {
        // A request cancelled while waiting must never allocate an ID or touch I/O.
        try Task.checkCancellation()
        guard !invalidated else { throw PTPSessionError.invalidated }
        let transactionID = nextTransactionID
        nextTransactionID = nextTransactionID == UInt32.max ? 1 : nextTransactionID + 1
        let command = PTPCodec.encodeCommand(code: operation, transactionID: transactionID, parameters: parameters)
        let transport = self.transport
        var drainedAfterAbort = false
        do {
            let result: (response: Data, payload: Data, received: UInt64, declared: UInt64?)
            if let sink {
                // Keep the transport task alive while asking a PTP/IP transport
                // to send Cancel and drain the command response. Cancelling this
                // task would close the socket before the camera has synchronized.
                let activity = PTPReceiveActivity(timeoutNanoseconds: timeoutNanoseconds)
                let timedSink = PTPDataSink(
                    started: { expected in activity.record(); sink.started(expected) },
                    received: { bytes in activity.record(); try sink.received(bytes) },
                    activity: { activity.record(); sink.activity() }
                )
                let receiveTask = Task { try await transport.receivePTP(command: command, sink: timedSink) }
                do {
                    let transfer: PTPDataTransfer
                    if transport.managesCommandTimeouts {
                        // A framework request cannot be cancelled independently.
                        // Wait for its terminal callback so leaving a page never
                        // requires closing the camera connection to resync PTP.
                        transfer = try await receiveTask.value
                    } else {
                        transfer = try await AsyncDeadline.run(
                            timeout: { try await activity.waitForTimeout() }
                        ) { try await receiveTask.value }
                    }
                    result = (transfer.response, Data(), transfer.receivedByteCount, transfer.declaredByteCount)
                } catch {
                    if transport.managesCommandTimeouts, error is CancellationError {
                        // Cancellation before dispatch (for example while the
                        // browser is suspended) consumed no wire transaction.
                        drainedAfterAbort = true
                        receiveTask.cancel()
                        throw error
                    }
                    // Android transferTransaction performs the same cleanup
                    // for every data-phase exception, including write errors.
                    // Cleanup must not inherit the caller's cancellation.
                    let recovery = Task.detached {
                        await transport.cancelPTP(transactionID: transactionID)
                    }
                    drainedAfterAbort = await recovery.value
                    if drainedAfterAbort {
                        _ = await receiveTask.result
                    } else {
                        receiveTask.cancel()
                    }
                    throw error
                }
            } else {
                let operation: @Sendable () async throws -> (response: Data, payload: Data, received: UInt64, declared: UInt64?) = {
                    let reply = try await transport.sendPTP(command: command, data: data)
                    return (reply.response, reply.payload, UInt64(reply.payload.count), nil)
                }
                do {
                    if transport.managesCommandTimeouts {
                        // ImageCaptureCore owns timeout and suspension. Await its
                        // callback cooperatively; prompt Swift cancellation would
                        // abandon a live PTP transaction with no legal Cancel API.
                        result = try await operation()
                    } else {
                        result = try await AsyncDeadline.run(
                            nanoseconds: timeoutNanoseconds, timeoutError: PTPSessionError.timeout,
                            operation: operation
                        )
                    }
                } catch {
                    if transport.managesCommandTimeouts, error is CancellationError {
                        // ImageCapture requests already on the wire are awaited
                        // above. A cancellation reaching here occurred before
                        // dispatch, so the existing session remains reusable.
                        drainedAfterAbort = true
                        throw error
                    }
                    let recovery = Task.detached {
                        await transport.cancelPTP(transactionID: transactionID)
                    }
                    drainedAfterAbort = await recovery.value
                    throw error
                }
            }
            guard !invalidated else { throw PTPSessionError.invalidated }
            let response = try PTPCodec.decode(result.response)
            guard response.type == .response else { throw PTPSessionError.unexpectedResponseType(response.type) }
            guard response.transactionID == transactionID else {
                throw PTPCodecError.transactionMismatch(expected: transactionID, actual: response.transactionID)
            }
            return PTPResponse(code: response.code, transactionID: transactionID, data: result.payload,
                               receivedByteCount: result.received, declaredByteCount: result.declared)
        } catch let error as PTPSessionError {
            // A negative PTP response consumed the complete transaction; busy or
            // unsupported must not poison this session's remaining commands.
            if case .responseCode = error {} else if !drainedAfterAbort { invalidate() }
            throw error
        } catch {
            // The transport may still complete a timed-out/cancelled operation.
            // Never send another command on this channel or accept its late reply.
            if !drainedAfterAbort { invalidate() }
            throw error
        }
    }

    func invalidate() {
        invalidated = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: PTPSessionError.invalidated) }
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if invalidated { continuation.resume(throwing: PTPSessionError.invalidated) }
                else if executing { waiters.append((id, continuation)) }
                else { executing = true; continuation.resume() }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else { executing = false; return }
        waiters.removeFirst().continuation.resume()
    }
}

private final class PTPReceiveBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    var data: Data { lock.withLock { bytes } }
    var sink: PTPDataSink {
        PTPDataSink(started: { _ in }, received: { [self] data in lock.withLock { bytes.append(data) } })
    }
}

private final class PTPReceiveActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: Duration
    private var lastRead = ContinuousClock.now

    init(timeoutNanoseconds: UInt64) { timeout = .nanoseconds(Int64(clamping: timeoutNanoseconds)) }
    func record() { lock.withLock { lastRead = .now } }
    private var deadline: ContinuousClock.Instant { lock.withLock { lastRead.advanced(by: timeout) } }

    func waitForTimeout() async throws {
        while true {
            try await ContinuousClock().sleep(until: deadline)
            if ContinuousClock.now >= deadline { throw PTPSessionError.timeout }
        }
    }
}

enum PTPConstants {
    // NikonCamera.SO_TIMEOUT_MS, shared by USB/AP/STA download reads.
    static let cameraReadTimeoutNanoseconds: UInt64 = 60_000_000_000
    static let responseOK: UInt16 = 0x2001
    static let sessionAlreadyOpen: UInt16 = 0x201E
    static let nikonCompatibilityInit: UInt16 = 0x941C
    static let nikonChangeApplicationMode: UInt16 = 0x9435
    static let nikonPairingQuery: UInt16 = 0x952B
    static let nikonPairingResult: UInt16 = 0x935A
    static let deviceBusy: UInt16 = 0x2019
    static let operationNotSupported: UInt16 = 0x2005
    static let getDeviceInfo: UInt16 = 0x1001
    static let openSession: UInt16 = 0x1002
    static let closeSession: UInt16 = 0x1003
    static let getStorageIDs: UInt16 = 0x1004
    static let getObjectHandles: UInt16 = 0x1007
    static let getObjectInfo: UInt16 = 0x1008
    static let getObject: UInt16 = 0x1009
    static let getThumb: UInt16 = 0x100A
    static let getDevicePropDesc: UInt16 = 0x1014
    static let getDevicePropValue: UInt16 = 0x1015
    static let setDevicePropValue: UInt16 = 0x1016
    static let getPartialObjectEx: UInt16 = 0x9431
    static let getObjectSize: UInt16 = 0x9421
    static let getObjectsMetadata: UInt16 = 0x9434
    static let getLargeThumb: UInt16 = 0x90C4
    static let getFHDPicture: UInt16 = 0x920F

    // Nikon remote monitor operations (same opcodes used by Android RemoteLab).
    static let startLiveView: UInt16 = 0x9201
    static let endLiveView: UInt16 = 0x9202
    static let getLiveViewImage: UInt16 = 0x9203
    static let getLiveViewImageEx: UInt16 = 0x9428
    static let deviceReady: UInt16 = 0x90C8
    static let captureInMedia: UInt16 = 0x9207
    static let captureInSdram: UInt16 = 0x90C0
    static let startMovieRecording: UInt16 = 0x920A
    static let endMovieRecording: UInt16 = 0x920B
    static let setControlMode: UInt16 = 0x90C2
    static let getDevicePropValueEx: UInt16 = 0x943B

    // Nikon remote focus operations (Android RemoteLab).
    static let mfDrive: UInt16 = 0x9204
    static let changeAFArea: UInt16 = 0x9205
    static let afDrive: UInt16 = 0x90C1
    static let startTracking: UInt16 = 0x9424
    static let endTracking: UInt16 = 0x9425
    static let outOfFocus: UInt16 = 0xA002
}
