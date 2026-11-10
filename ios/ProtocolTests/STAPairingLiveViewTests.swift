import XCTest
import CoreGraphics
import ImageIO
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

// Real JPEG header parsing and production session serialization; no UI renderer.
@MainActor
final class STAPairingLiveViewTests: XCTestCase {
    func testValidEmbeddedFrameEndsOnlyMonitorStartedByVerification() async throws {
        let wire = STAScriptTransport(staValidFrameExchanges())
        try await verify(wire)
        let commands = await wire.commands, remaining = await wire.remaining
        XCTAssertEqual(commands.map(\.code), [0x1015, 0x9201, 0x90C8, 0x9203, 0x9202])
        XCTAssertEqual(remaining, 0)
    }
    func testExistingMonitorIsNeverStartedOrStopped() async throws {
        let wire = STAScriptTransport([.init(0x1015, [0xD1A2], payload: Data([1])), .init(0x9203, payload: staFrameJPEG())])
        try await verify(wire)
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }
    func testEnhancedUnsupportedAndInvalidFramesFallBackImmediatelyToStandard() async throws {
        for enhanced in [[STAExchange(0x9428, response: 0x2005)], [.init(0x9428, payload: Data([255, 216, 255, 217])), .init(0x9428)]] {
            let delays = STARecorder<Duration>()
            let wire = STAScriptTransport([.init(0x1015, [0xD1A2], payload: Data([1]))] + enhanced + [.init(0x9203, payload: staFrameJPEG())])
            try await STAPairingLiveView.verify(session: PTPSession(transport: wire), operations: [0x9428], trace: .init(), sleep: { await delays.append($0) })
            let recorded = await delays.values, remaining = await wire.remaining
            XCTAssertEqual(recorded, enhanced.count == 1 ? [] : [.milliseconds(100)])
            XCTAssertEqual(remaining, 0)
        }
    }
    func testBusyStartReadinessAndFrameRetryWithoutPrematureFallback() async throws {
        let pauses = STARecorder<Duration>()
        let wire = STAScriptTransport([
            .init(0x1015, [0xD1A2], payload: Data([0])), .init(0x9201, response: 0xA004), .init(0x9201),
            .init(0x90C8, response: 0x2019), .init(0x90C8, response: 0x2005),
            .init(0x9428, response: 0x2019), .init(0x9428, response: 0xA00B),
            .init(0x9428, payload: staFrameJPEG()), .init(0x9202, response: 0xA00B)])
        try await STAPairingLiveView.verify(session: PTPSession(transport: wire), operations: [0x9428], trace: .init(), sleep: { await pauses.append($0) })
        let recorded = await pauses.values, remaining = await wire.remaining
        XCTAssertEqual(recorded, [.milliseconds(200), .milliseconds(100), .milliseconds(100), .milliseconds(100)])
        XCTAssertEqual(remaining, 0)
    }
    func testStatusMustBeExactlyOneValidByte() async throws {
        for payload in [Data(), Data([2]), Data([1, 0])] {
            let wire = STAScriptTransport([.init(0x1015, [0xD1A2], payload: payload)])
            do { try await verify(wire); XCTFail() } catch { XCTAssertTrue(error is STAPairingVerificationFailure) }
            let commands = await wire.commands; XCTAssertEqual(commands.count, 1)
        }
    }
    func testNegativeStandardFrameClosesOwnedMonitorAndPreservesError() async throws {
        let wire = STAScriptTransport([.init(0x1015, [0xD1A2], payload: Data([0])), .init(0x9201), .init(0x90C8),
            .init(0x9203, response: 0x201F), .init(0x9202)])
        do { try await verify(wire); XCTFail() }
        catch { XCTAssertEqual((error as? STAPairingVerificationFailure)?.cause as? PTPSessionError, .responseCode(0x201F)) }
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }
    func testCancellationDuringStartStillClosesOwnedMonitor() async throws {
        let gate = STAReplyGate()
        let wire = STAScriptTransport([.init(0x1015, [0xD1A2], payload: Data([0])), .init(0x9201), .init(0x9202)])
        await wire.beforeNextReply(0x9201) { await gate.enter() }
        let task = Task { try await self.verify(wire) }
        await gate.waitUntilEntered()
        task.cancel(); await gate.release()
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }
    func testBrokenFrameStreamAbortsWithoutSendingCleanupOnDesynchronizedSocket() async throws {
        let wire = STAScriptTransport(staValidFrameExchanges()), aborted = STAAtomicBox(false)
        await wire.beforeNextReply(0x9203) { throw PTPSessionError.timeout }
        let session = PTPSession(transport: wire)
        do {
            try await STAPairingLiveView.verify(session: session, operations: [], trace: .init(), abort: { aborted.value = true })
            XCTFail()
        } catch { XCTAssertTrue(error is STAPairingVerificationFailure) }
        XCTAssertTrue(aborted.value)
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 1, "No EndLiveView on broken stream")
        do { _ = try await session.execute(operation: 0x1001); XCTFail() } catch { XCTAssertEqual(error as? PTPSessionError, .invalidated) }
    }
    func testCleanupFailureCannotConfirmPairing() async throws {
        var steps = staValidFrameExchanges(); steps[steps.count - 1] = .init(0x9202, response: 0x200F)
        let aborted = STAAtomicBox(false), wire = STAScriptTransport(steps)
        do { try await STAPairingLiveView.verify(session: PTPSession(transport: wire), operations: [], trace: .init(), abort: { aborted.value = true }); XCTFail() }
        catch { XCTAssertTrue(error is STAPairingVerificationFailure) }
        XCTAssertTrue(aborted.value)
    }
    func testEightSecondBudgetStopsRepeatedInvalidFramesAndCleansUp() async throws {
        let time = STAAtomicBox(ContinuousClock.now)
        let wire = STAScriptTransport([.init(0x1015, [0xD1A2], payload: Data([0])), .init(0x9201), .init(0x90C8), .init(0x9203), .init(0x9202)])
        do {
            try await STAPairingLiveView.verify(session: PTPSession(transport: wire), operations: [], trace: .init(), now: { time.value }, sleep: { _ in time.value = time.value.advanced(by: .seconds(8)) })
            XCTFail()
        } catch { XCTAssertTrue(error is STAPairingVerificationFailure) }
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }
    func testJPEGSignatureAloneIsNotProof() {
        XCTAssertFalse(STAPairingLiveView.validFrame(Data([255, 216, 0, 255, 217])))
        XCTAssertFalse(STAPairingLiveView.validFrame(staFrameJPEG().dropLast(4)))
        XCTAssertTrue(STAPairingLiveView.validFrame(staFrameJPEG()))
    }
    private func verify(_ wire: STAScriptTransport) async throws {
        try await STAPairingLiveView.verify(session: PTPSession(transport: wire), operations: [], trace: .init(), sleep: { _ in })
    }
}

func staValidFrameExchanges() -> [STAExchange] {
    [.init(0x1015, [0xD1A2], payload: Data([0])), .init(0x9201), .init(0x90C8), .init(0x9203, payload: staFrameJPEG()), .init(0x9202)]
}
func staFrameJPEG() -> Data {
    let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let data = NSMutableData(), image = context.makeImage()!
    let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return Data(repeating: 0, count: 32) + (data as Data) + Data([0, 0])
}
final class STAAtomicBox<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
actor STAReplyGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true; observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { waiting?.resume(); waiting = nil }
}
