import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

@MainActor
final class PTPSessionTests: XCTestCase {
    func testConcurrentCallersNeverOverlapCameraIO() async throws {
        let transport = RecordingTransport()
        let session = PTPSession(transport: transport)
        let responses = try await withThrowingTaskGroup(of: PTPResponse.self) { group in
            for _ in 0..<40 {
                group.addTask { try await session.execute(operation: PTPConstants.getDeviceInfo) }
            }
            var responses: [PTPResponse] = []
            for try await response in group { responses.append(response) }
            return responses
        }
        let commands = await transport.commands
        let peak = await transport.peakActive
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(commands.map(\.transactionID), Array(UInt32(1)...40))
        XCTAssertEqual(Set(responses.map(\.transactionID)), Set(UInt32(1)...40))
    }

    func testCancellingAQueuedCallerDoesNotSendOrConsumeTransactionID() async throws {
        let transport = HeldTransport()
        let session = PTPSession(transport: transport)
        let first = Task { try await session.execute(operation: PTPConstants.getDeviceInfo) }
        try await transport.waitForRequestCount(1)
        let queued = Task { try await session.execute(operation: PTPConstants.getStorageIDs) }
        // Give the second task a chance to enter the session while the first I/O
        // is explicitly held; no camera response can race with this cancellation.
        await Task.yield()
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Cancelled request returned a response") }
        catch { XCTAssertTrue(error is CancellationError) }
        await transport.finishNext()
        _ = try await first.value
        let third = Task { try await session.execute(operation: PTPConstants.getStorageIDs) }
        try await transport.waitForRequestCount(2)
        await transport.finishNext()
        let thirdResponse = try await third.value
        XCTAssertEqual(thirdResponse.transactionID, 2)
        let commands = await transport.commands
        XCTAssertEqual(commands.map(\.code), [PTPConstants.getDeviceInfo, PTPConstants.getStorageIDs])
    }

    func testTimeoutReturnsBeforeNonCooperativeCallbackAndRetiresSession() async throws {
        let transport = HeldTransport()
        let session = PTPSession(transport: transport)
        let call = Task {
            try await session.execute(operation: PTPConstants.getDeviceInfo, timeoutNanoseconds: 10_000_000)
        }
        try await transport.waitForRequestCount(1)
        // A broken task-group timeout still exits eventually so the test reports
        // a failure instead of leaving the test runner hanging forever.
        let rescue = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await transport.finishNext()
        }
        defer { rescue.cancel() }
        let start = ContinuousClock.now
        do { _ = try await call.value; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? PTPSessionError, .timeout) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        await transport.finishNext() // Late reply is safe and cannot reopen the channel.
        do { _ = try await session.execute(operation: PTPConstants.getStorageIDs); XCTFail("Session reused after timeout") }
        catch { XCTAssertEqual(error as? PTPSessionError, .invalidated) }
        let commands = await transport.commands
        XCTAssertEqual(commands.count, 1)
    }

    func testActiveCancellationReturnsWithoutCallbackAndFailsWaitingCommands() async throws {
        let transport = HeldTransport()
        let session = PTPSession(transport: transport)
        let active = Task { try await session.execute(operation: PTPConstants.getDeviceInfo) }
        try await transport.waitForRequestCount(1)
        let queued = Task { try await session.execute(operation: PTPConstants.getStorageIDs) }
        let rescue = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await transport.finishNext()
        }
        defer { rescue.cancel() }
        let start = ContinuousClock.now
        active.cancel()
        do { _ = try await active.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        do { _ = try await queued.value; XCTFail("Queued I/O sent on cancelled channel") }
        catch { XCTAssertEqual(error as? PTPSessionError, .invalidated) }
        await transport.finishNext()
        let commands = await transport.commands
        XCTAssertEqual(commands.count, 1)
    }

    func testValidNegativeResponseDoesNotInvalidateSession() async throws {
        let transport = RecordingTransport(responseCodes: [0x2019, 0x2005, 0x2001])
        let session = PTPSession(transport: transport)
        for code: UInt16 in [0x2019, 0x2005] {
            do { _ = try await session.execute(operation: PTPConstants.getDeviceInfo); XCTFail("Negative response ignored") }
            catch { XCTAssertEqual(error as? PTPSessionError, .responseCode(code)) }
        }
        let response = try await session.execute(operation: PTPConstants.getDeviceInfo)
        XCTAssertEqual(response.transactionID, 3)
    }

    func testWrongTransactionAndContainerTypeRetireSession() async throws {
        for transport in [RecordingTransport(transactionDelta: 1), RecordingTransport(responseType: .data)] {
            let session = PTPSession(transport: transport)
            do { _ = try await session.execute(operation: PTPConstants.getDeviceInfo); XCTFail("Invalid response accepted") }
            catch {
                XCTAssertTrue(error is PTPCodecError || error is PTPSessionError)
            }
            do { _ = try await session.execute(operation: PTPConstants.getStorageIDs); XCTFail("Invalidated channel reused") }
            catch { XCTAssertEqual(error as? PTPSessionError, .invalidated) }
        }
    }

    func testDataOutAndPayloadArePreserved() async throws {
        let transport = RecordingTransport()
        let response = try await PTPSession(transport: transport).execute(
            operation: 0x1016, parameters: [0x5001], data: Data([1, 2, 3])
        )
        XCTAssertEqual(response.data, Data([1, 2, 3]))
        let commands = await transport.commands
        XCTAssertEqual(commands.first?.payload, Data([1, 0x50, 0, 0]))
    }
}

private actor RecordingTransport: PTPCommandTransport {
    private(set) var commands: [PTPContainer] = []
    private(set) var peakActive = 0
    private var active = 0
    private let responseCodes: [UInt16]
    private let transactionDelta: UInt32
    private let responseType: PTPContainerType

    init(responseCodes: [UInt16] = [], transactionDelta: UInt32 = 0, responseType: PTPContainerType = .response) {
        self.responseCodes = responseCodes
        self.transactionDelta = transactionDelta
        self.responseType = responseType
    }

    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        let packet = try PTPCodec.decode(command)
        let responseCode = commands.count < responseCodes.count ? responseCodes[commands.count] : 0x2001
        commands.append(packet)
        active += 1
        peakActive = max(peakActive, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 1_000_000)
        return (PTPCodec.encode(type: responseType, code: responseCode, transactionID: packet.transactionID + transactionDelta), data ?? Data())
    }
}

/// Deliberately ignores task cancellation, just as a stalled system callback can.
private actor HeldTransport: PTPCommandTransport {
    typealias Reply = (response: Data, payload: Data)
    private(set) var commands: [PTPContainer] = []
    private var pending: [(UInt32, CheckedContinuation<Reply, any Error>)] = []

    func sendPTP(command: Data, data: Data?) async throws -> Reply {
        let packet = try PTPCodec.decode(command)
        commands.append(packet)
        return try await withCheckedThrowingContinuation { pending.append((packet.transactionID, $0)) }
    }

    func finishNext() {
        guard !pending.isEmpty else { return }
        let (transaction, continuation) = pending.removeFirst()
        continuation.resume(returning: (PTPCodec.encode(type: .response, code: 0x2001, transactionID: transaction), Data()))
    }

    func waitForRequestCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while commands.count < count {
            guard ContinuousClock.now < deadline else { throw TestError.requestNotReceived }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private enum TestError: Error { case requestNotReceived }
}
