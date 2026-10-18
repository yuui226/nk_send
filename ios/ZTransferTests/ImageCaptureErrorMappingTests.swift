import ImageCaptureCore
import XCTest
@testable import ZTransfer

final class ImageCaptureErrorMappingTests: XCTestCase {
    @MainActor
    func testBlockingControlPermissionDoesNotBlockMainThreadOrDuplicatePrompt() async throws {
        let entered = expectation(description: "Permission call entered")
        let provider = BlockingUSBPermission(contents: .authorized, entered: entered)
        let transport = ImageCaptureUSBTransport(authorizationAccess: provider.access)
        defer { provider.release.signal(); transport.stop() }
        transport.startAuthorizationForTesting()
        await fulfillment(of: [entered], timeout: 3)
        // The provider is still synchronously blocked, exactly where the old
        // first-launch path froze. MainActor and its cached status remain usable.
        let heartbeat = expectation(description: "Main run loop responds during permission")
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        for _ in 0..<5 { transport.refreshAuthorization() }
        XCTAssertEqual(transport.currentAuthorization(), .notDetermined)
        XCTAssertFalse(provider.usedMainThread)
        provider.release.signal()
        try await waitForAuthorization(.authorized, transport)
        XCTAssertEqual(provider.controlRequests, 1)
        XCTAssertFalse(provider.timedOut)
    }

    @MainActor
    func testBlockingStatusReadDoesNotBlockResumeAndLateGrantAfterStopIsIgnored() async throws {
        let entered = expectation(description: "Status read entered")
        let provider = BlockingUSBPermission(contents: .authorized, entered: entered, blockRead: true)
        let transport = ImageCaptureUSBTransport(authorizationAccess: provider.access)
        defer { provider.release.signal(); transport.stop() }
        transport.startAuthorizationForTesting()
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(transport.currentAuthorization(), .notDetermined)
        transport.refreshAuthorization()
        transport.stop()
        provider.release.signal()
        await provider.waitUntilReturned()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.currentAuthorization(), .notDetermined)
        XCTAssertEqual(provider.controlRequests, 0)
        XCTAssertFalse(provider.usedMainThread)
    }

    @MainActor
    func testDeniedContentsDoesNotRequestCameraControl() async throws {
        let provider = BlockingUSBPermission(contents: .denied)
        let transport = ImageCaptureUSBTransport(authorizationAccess: provider.access)
        defer { transport.stop() }
        transport.startAuthorizationForTesting()
        try await waitForAuthorization(.denied, transport)
        XCTAssertEqual(provider.controlRequests, 0)
        XCTAssertFalse(provider.usedMainThread)
    }

    @MainActor
    private func waitForAuthorization(_ expected: USBAuthorizationState, _ transport: ImageCaptureUSBTransport) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while transport.currentAuthorization() != expected && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(transport.currentAuthorization(), expected)
    }

    func testPTPHandshakeToleratesMissingOrMalformedOptionalDeviceInfo() async throws {
        for payload in [Data(), Data([100]), Data([100, 0]) + Data(repeating: 0, count: 33)] {
            let script = USBHandshakeScript(deviceInfo: payload)
            try await ImageCaptureUSBTransport.validatePTPChannel { try await script.send($0) }
            let operations = await script.operations
            XCTAssertEqual(operations, [0x1001], "Storage availability must not gate connection admission")
        }
    }

    func testPTPHandshakeRejectsCameraFailureResponse() async {
        let script = USBHandshakeScript(responseCode: 0x2003)
        do {
            try await ImageCaptureUSBTransport.validatePTPChannel { try await script.send($0) }
            XCTFail("An unsuccessful reply must not establish a channel")
        } catch {
            XCTAssertEqual(error as? PTPSessionError, .responseCode(0x2003))
        }
        let operations = await script.operations
        XCTAssertEqual(operations, [0x1001])
    }

    func testPTPHandshakeRejectsMalformedOrNonResponseContainers() async {
        for response in [Data([12, 0]), PTPCodec.encode(type: .event, code: 0x4002, transactionID: 1)] {
            do {
                try await ImageCaptureUSBTransport.validatePTPChannel { _ in (response, Data()) }
                XCTFail("A malformed or event container must not establish a channel")
            } catch {
                XCTAssertTrue(error is PTPCodecError || error is PTPSessionError)
            }
        }
    }

    func testCancelledHandshakeDoesNotAdvanceOrPublishSuccess() async {
        let script = USBHandshakeScript()
        let task = Task {
            try await ImageCaptureUSBTransport.validatePTPChannel { command in
                let result = try await script.send(command)
                withUnsafeCurrentTask { $0?.cancel() }
                return result
            }
        }
        do { try await task.value; XCTFail("Cancelled handshake must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let operations = await script.operations
        XCTAssertEqual(operations, [0x1001])
    }

    func testImageCaptureCompletionKeepsInDataSeparateFromPTPResponse() {
        let payload = Data([1, 2, 3])
        let response = Data([12, 0, 0, 0, 3, 0, 1, 32])
        let result = ImageCaptureUSBTransport.ptpResultForTesting(inData: payload, response: response)
        XCTAssertEqual(result.response, response)
        XCTAssertEqual(result.payload, payload)
    }

    func testFrameworkWireTransactionIsCorrelatedToItsRequest() throws {
        let command = PTPCodec.encodeCommand(code: 0x1001, transactionID: 1)
        let payload = Data([7, 8, 9])
        for code in [UInt16(0x2001), UInt16(0x2019)] {
            let response = PTPCodec.encode(type: .response, code: code, transactionID: 1831,
                                           payload: Data([1, 0, 0, 0]))
            let result = try ImageCaptureUSBTransport.correlatedPTPResult(command: command, inData: payload, response: response)
            let decoded = try PTPCodec.decode(result.response)
            XCTAssertEqual(decoded.transactionID, 1)
            XCTAssertEqual(decoded.code, code)
            XCTAssertEqual(decoded.payload, Data([1, 0, 0, 0]))
            XCTAssertEqual(result.payload, payload)
        }
    }

    func testFrameworkCorrelationRejectsMalformedOrNonResponseContainers() {
        let command = PTPCodec.encodeCommand(code: 0x1001, transactionID: 1)
        for response in [Data([12, 0]), PTPCodec.encode(type: .event, code: 0x4002, transactionID: 1831)] {
            XCTAssertThrowsError(try ImageCaptureUSBTransport.correlatedPTPResult(command: command, inData: Data(), response: response))
        }
    }

    func testUSBRequiresBothContentsAndControlAuthorization() {
        XCTAssertEqual(
            ImageCaptureUSBTransport.combinedAuthorizationForTesting(
                contents: .authorized,
                control: .authorized
            ),
            .authorized
        )
        XCTAssertEqual(
            ImageCaptureUSBTransport.combinedAuthorizationForTesting(
                contents: .authorized,
                control: .notDetermined
            ),
            .notDetermined
        )
        XCTAssertEqual(
            ImageCaptureUSBTransport.combinedAuthorizationForTesting(
                contents: .denied,
                control: .authorized
            ),
            .denied
        )
        XCTAssertEqual(
            ImageCaptureUSBTransport.combinedAuthorizationForTesting(
                contents: .authorized,
                control: .restricted
            ),
            .restricted
        )
    }

    func testImageCaptureTimeoutAndPermissionCategoriesMatchTransportErrors() {
        XCTAssertEqual(
            ImageCaptureUSBTransport.mapForTesting(NSError(domain: "ICErrorDomain", code: -9923)),
            .timeout
        )
        XCTAssertEqual(
            ImageCaptureUSBTransport.mapForTesting(NSError(domain: "ICErrorDomain", code: -21343)),
            .permissionDenied
        )
    }

    func testImageCaptureDisconnectCategoriesDoNotBecomeProtocolFailures() {
        for code in [
            -20098, -9937,
            -21350, -21349, -21348, -21347, -21345, -21344,
            -21250,
            -9900, -9901, -9902, -9914, -9921, -9927, -9928,
            -9936, -9956, -9957, -9958,
        ] {
            XCTAssertEqual(
                ImageCaptureUSBTransport.mapForTesting(NSError(domain: "ICErrorDomain", code: code)),
                .disconnected,
                "unexpected mapping for ImageCaptureCore code \(code)"
            )
        }
    }
}

private final class BlockingUSBPermission: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let contentsStatus: ICAuthorizationStatus
    private let entered: XCTestExpectation?
    private let blockRead: Bool
    private var main = false, timeout = false, returned = false
    private var requests = 0
    init(contents: ICAuthorizationStatus, entered: XCTestExpectation? = nil, blockRead: Bool = false) {
        contentsStatus = contents; self.entered = entered; self.blockRead = blockRead
    }
    var access: ImageCaptureAuthorizationAccess {
        .init(contents: { self.read() }, control: { self.observeThread(); return .notDetermined },
              requestContents: { _ in XCTFail("Determined contents must not prompt again") },
              requestControl: { done in
                  self.lock.lock(); self.requests += 1; self.lock.unlock()
                  self.observeThread(); self.block(); done(.authorized)
              })
    }
    private func read() -> ICAuthorizationStatus {
        observeThread()
        if blockRead { block() }
        return contentsStatus
    }
    private func observeThread() { lock.lock(); main = main || Thread.isMainThread; lock.unlock() }
    private func block() {
        entered?.fulfill()
        let expired = release.wait(timeout: .now() + 5) == .timedOut
        lock.lock(); timeout = expired; returned = true; lock.unlock()
    }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return main }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timeout }
    var controlRequests: Int { lock.lock(); defer { lock.unlock() }; return requests }
    private var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }
    func waitUntilReturned() async {
        for _ in 0..<600 {
            if hasReturned { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Blocked permission read did not drain")
    }
}

private actor USBHandshakeScript {
    private let deviceInfo: Data
    private let responseCode: UInt16
    private(set) var operations: [UInt16] = []

    init(deviceInfo: Data = Data([100, 0]) + Data(repeating: 0, count: 33),
         responseCode: UInt16 = 0x2001) {
        self.deviceInfo = deviceInfo
        self.responseCode = responseCode
    }

    func send(_ command: Data) throws -> (response: Data, payload: Data) {
        let request = try PTPCodec.decode(command)
        operations.append(request.code)
        guard request.code == 0x1001 else {
            throw PTPSessionError.invalidResponse
        }
        return (PTPCodec.encode(type: .response,
                               code: responseCode,
                               transactionID: request.transactionID),
                deviceInfo)
    }
}
