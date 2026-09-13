import Foundation

protocol PTPCommandTransport: Sendable {
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data)
}

struct PTPResponse: Equatable, Sendable {
    let code: UInt16
    let transactionID: UInt32
    let data: Data
}

enum PTPSessionError: Error, Equatable, Sendable {
    case invalidResponse
    case unexpectedResponseType(PTPContainerType)
    case responseCode(UInt16)
    case timeout
    case invalidated
}

/// Android's I/O mutex stays held through the entire transaction. Actor isolation
/// alone cannot provide that guarantee because `await` permits reentrancy.
actor PTPSession {
    private let transport: PTPCommandTransport
    private var nextTransactionID: UInt32 = 1
    private var executing = false
    private var invalidated = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(transport: PTPCommandTransport) {
        self.transport = transport
    }

    func execute(operation: UInt16, parameters: [UInt32] = [], data: Data? = nil, timeoutNanoseconds: UInt64 = 15_000_000_000) async throws -> PTPResponse {
        try await acquire()
        defer { release() }
        // A request cancelled while waiting must never allocate an ID or touch I/O.
        try Task.checkCancellation()
        guard !invalidated else { throw PTPSessionError.invalidated }
        let transactionID = nextTransactionID
        nextTransactionID = nextTransactionID == UInt32.max ? 1 : nextTransactionID + 1
        let command = PTPCodec.encodeCommand(code: operation, transactionID: transactionID, parameters: parameters)
        let transport = self.transport
        do {
            let result = try await AsyncDeadline.run(
                nanoseconds: timeoutNanoseconds, timeoutError: PTPSessionError.timeout
            ) { try await transport.sendPTP(command: command, data: data) }
            guard !invalidated else { throw PTPSessionError.invalidated }
            let response = try PTPCodec.decode(result.response)
            guard response.type == .response else { throw PTPSessionError.unexpectedResponseType(response.type) }
            guard response.transactionID == transactionID else {
                throw PTPCodecError.transactionMismatch(expected: transactionID, actual: response.transactionID)
            }
            if response.code != PTPConstants.responseOK { throw PTPSessionError.responseCode(response.code) }
            return PTPResponse(code: response.code, transactionID: transactionID, data: result.payload)
        } catch let error as PTPSessionError {
            // A negative PTP response consumed the complete transaction; busy or
            // unsupported must not poison this session's remaining commands.
            if case .responseCode = error {} else { invalidate() }
            throw error
        } catch {
            // The transport may still complete a timed-out/cancelled operation.
            // Never send another command on this channel or accept its late reply.
            invalidate()
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

enum PTPConstants {
    static let responseOK: UInt16 = 0x2001
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

    // Nikon remote focus operations (Android RemoteLab).
    static let mfDrive: UInt16 = 0x9204
    static let changeAFArea: UInt16 = 0x9205
    static let afDrive: UInt16 = 0x90C1
    static let startTracking: UInt16 = 0x9424
    static let endTracking: UInt16 = 0x9425
    static let outOfFocus: UInt16 = 0xA002
}
