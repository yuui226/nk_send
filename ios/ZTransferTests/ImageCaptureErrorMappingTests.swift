import ImageCaptureCore
import SwiftUI
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
            XCTAssertEqual(operations, [0x1001], "The raw channel stays independent; first photo entry checks storage in CameraRepository")
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

/// The first-entry exception was explicitly approved on 2026-10-18. These
/// synthetic PTP fixtures do not claim physical power-switch detection.
@MainActor final class USBPhotoAdmissionTests: XCTestCase {
    private func repository(_ wire: PhotoAdmissionWire) -> CameraRepository {
        CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
    }
    private func ids(_ values: [UInt32]) -> Data {
        ([UInt32(values.count)] + values).reduce(into: Data()) { data, value in
            for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8((value >> shift) & 255)) }
        }
    }
    private var info: Data { Data([4, 0, 3, 0, 0, 0]) + Data(repeating: 0, count: 20) }
    private func expect(_ reason: CameraPhotoReadinessError, wire: PhotoAdmissionWire) async {
        do { try await repository(wire).prepareUSBPhotoList(); XCTFail("Unreadable storage admitted") }
        catch { XCTAssertEqual(error as? CameraPhotoReadinessError, reason) }
        let remaining = await wire.remainingCount()
        XCTAssertEqual(remaining, 0)
    }
    func testReadableEmptyCardUsesOnlyTwoSmallCommandsAndReusesIDsOnce() async throws {
        let raw = ids([0, 0x10000, 0x10001, 0x10001])
        let wire = PhotoAdmissionWire([.init(0x1004, payload: raw), .init(0x1005, parameters: [0x10001], payload: info),
                                       .init(0x1004, payload: raw)])
        let repo = repository(wire)
        try await repo.prepareUSBPhotoList()
        let cached = try await repo.loadStorageIDs()
        XCTAssertEqual(cached, [0, 0x10000, 0x10001, 0x10001])
        let firstOperations = await wire.recordedOperations()
        XCTAssertEqual(firstOperations, [0x1004, 0x1005], "No object enumeration or system session open")
        _ = try await repo.loadStorageIDs()
        let finalOperations = await wire.recordedOperations()
        XCTAssertEqual(finalOperations, [0x1004, 0x1005, 0x1004])
    }
    func testNoUsableStorageIsDifferentFromEmptyAlbum() async {
        for raw in [ids([]), ids([0, 0x10000, 0x20000])] {
            await expect(.storageUnavailable, wire: PhotoAdmissionWire([.init(0x1004, payload: raw)]))
        }
    }
    func testExplicitUnavailableRepliesStayCardErrors() async {
        for code: UInt16 in [0x2008, 0x2013, 0xA802] {
            await expect(.storageUnavailable, wire: PhotoAdmissionWire([
                .init(0x1004, payload: ids([0x10001])), .init(0x1005, parameters: [0x10001], response: code)]))
        }
        await expect(.storageUnavailable, wire: PhotoAdmissionWire([.init(0x1004, response: 0x2013)]))
    }
    func testOneReadableSlotAllowsDualCardBodyWithoutWaitingForEmptySlot() async throws {
        let wire = PhotoAdmissionWire([.init(0x1004, payload: ids([0x20001, 0x10001])),
            .init(0x1005, parameters: [0x10001], response: 0x2013),
            .init(0x1005, parameters: [0x20001], payload: info)])
        try await repository(wire).prepareUSBPhotoList()
        let remaining = await wire.remainingCount(); XCTAssertEqual(remaining, 0)
    }
    func testUnknownCapacityAndReadOnlyFullCardDoNotBecomePowerOrCardFailures() async throws {
        for payload in [Data(repeating: 0, count: 26), Data([4, 0, 3, 0, 1, 0]) + Data(repeating: 255, count: 20)] {
            let wire = PhotoAdmissionWire([.init(0x1004, payload: ids([0x10001])),
                                           .init(0x1005, parameters: [0x10001], payload: payload)])
            try await repository(wire).prepareUSBPhotoList()
        }
    }
    func testTruncatedRepliesAreNotReadyAndNeverDiagnoseAnEmptyCard() async {
        for payload in [Data(), Data([2, 0, 0, 0, 1, 0, 1, 0])] {
            await expect(.notReady, wire: PhotoAdmissionWire([.init(0x1004, payload: payload)]))
        }
        await expect(.notReady, wire: PhotoAdmissionWire([.init(0x1004, payload: ids([0x10001])),
            .init(0x1005, parameters: [0x10001], payload: Data(repeating: 0, count: 25))]))
    }
    func testBusyCardThenReadyRechecksWithoutCachingFailedIDs() async throws {
        let raw = ids([0x10001])
        let wire = PhotoAdmissionWire([.init(0x1004, payload: raw), .init(0x1005, parameters: [0x10001], response: 0x2019),
            .init(0x1004, payload: raw), .init(0x1005, parameters: [0x10001], payload: info)])
        let repo = repository(wire)
        do { try await repo.prepareUSBPhotoList(); XCTFail("Busy admitted") }
        catch { XCTAssertEqual(error as? CameraPhotoReadinessError, .notReady) }
        try await repo.prepareUSBPhotoList()
        let operations = await wire.recordedOperations()
        XCTAssertEqual(operations, [0x1004, 0x1005, 0x1004, 0x1005])
    }
    func testTransportFailuresEscapeAdmissionPolling() async {
        for failure in [CameraTransportError.permissionDenied, .disconnected, .timeout] {
            let wire = PhotoAdmissionWire([.init(0x1004, failure: failure)])
            var waits = 0
            do {
                try await CameraPhotoAdmission.waitUntilReady(check: { try await self.repository(wire).prepareUSBPhotoList() },
                    isCurrent: { true }, isActive: { true }, onWaiting: { _ in waits += 1 }, retryDelay: .milliseconds(1))
                XCTFail("Transport failure admitted")
            } catch { XCTAssertEqual(error as? CameraTransportError, failure) }
            XCTAssertEqual(waits, 0)
        }
    }
    func testWaitingOnlyPublishesSuccessAfterAReadableReply() async throws {
        var checks = 0, waits: [CameraPhotoReadinessError] = []
        try await CameraPhotoAdmission.waitUntilReady(check: {
            checks += 1
            if checks == 1 { throw CameraPhotoReadinessError.storageUnavailable }
            if checks == 2 { throw CameraPhotoReadinessError.notReady }
        }, isCurrent: { true }, isActive: { true }, onWaiting: { waits.append($0) }, retryDelay: .milliseconds(1))
        XCTAssertEqual(checks, 3); XCTAssertEqual(waits, [.storageUnavailable, .notReady])
    }
    func testBackgroundWaitingDoesNotSendCommandsAndForegroundResumes() async throws {
        var active = false, checks = 0
        let task = Task {
            try await CameraPhotoAdmission.waitUntilReady(check: { checks += 1 }, isCurrent: { true },
                isActive: { active }, onWaiting: { _ in XCTFail() }, retryDelay: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(20)); XCTAssertEqual(checks, 0)
        active = true
        try await task.value; XCTAssertEqual(checks, 1)
    }
    func testCancelledWaitingStopsImmediatelyWithoutAnotherProbe() async {
        let waiting = expectation(description: "Waiting for camera")
        var checks = 0
        let task = Task {
            try await CameraPhotoAdmission.waitUntilReady(check: { checks += 1; throw CameraPhotoReadinessError.notReady },
                isCurrent: { true }, isActive: { true }, onWaiting: { _ in waiting.fulfill() })
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled gate completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(checks, 1)
    }
    func testRemovedOrReplacedCameraCannotPublishLateSuccessOrFailure() async {
        for fails in [false, true] {
            let started = expectation(description: "In-flight read")
            var current = true, resume: CheckedContinuation<Void, Never>?
            let task = Task {
                try await CameraPhotoAdmission.waitUntilReady(check: {
                    await withCheckedContinuation { resume = $0; started.fulfill() }
                    if fails { throw CameraPhotoReadinessError.notReady }
                }, isCurrent: { current }, isActive: { true }, onWaiting: { _ in XCTFail("Late message") })
            }
            await fulfillment(of: [started], timeout: 2)
            current = false; resume?.resume()
            do { try await task.value; XCTFail("Old camera admitted") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }
    func testAdmissionMessagesExistInAllLanguagesAndNeverAssertPowerIsOff() {
        for language in ["zh", "en", "hant"] {
            for key in ["usb_camera_not_ready", "usb_storage_unavailable"] {
                XCTAssertNotEqual(AppLocalized.resource(key, language: language), key)
            }
        }
        XCTAssertEqual(AppLocalized.resource("usb_camera_not_ready", language: "zh"), "相机尚未就绪，请确认相机已开机并检查连接")
        XCTAssertEqual(AppLocalized.resource("usb_storage_unavailable", language: "zh"), "相机存储卡不可用，请检查存储卡")
    }

    func testRenderFullReadinessMessagesAtNarrowCardWidth() async throws {
        let content = VStack(spacing: 12) {
            ForEach(["zh", "en", "hant"], id: \.self) { language in
                HStack(spacing: 12) {
                    ForEach(["usb_camera_not_ready", "usb_storage_unavailable"], id: \.self) { key in
                        let state = ConnectionState(usbPhase: .failed(AppLocalized.resource(key, language: language)))
                        ConnectionMethodCard(mode: .usb, state: state, height: 250, dimmed: false,
                            attentionActive: false, attentionOrigin: .now, selected: false, celebrationStart: nil,
                            previewPremiumCelebration: false)
                            .frame(width: 140)
                    }
                }
            }
        }.padding(14).background(Color.white).environment(\.colorScheme, .light)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 802)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/ztransfer-1018-usb-admission-card.png"))
    }
}

private actor PhotoAdmissionWire: PTPCommandTransport {
    struct Step: Sendable {
        var operation: UInt16
        var parameters: [UInt32] = []
        var payload: Data = Data()
        var response: UInt16 = 0x2001
        var failure: CameraTransportError? = nil
        init(_ operation: UInt16, parameters: [UInt32] = [], payload: Data = Data(), response: UInt16 = 0x2001,
             failure: CameraTransportError? = nil) {
            self.operation = operation; self.parameters = parameters; self.payload = payload
            self.response = response; self.failure = failure
        }
    }
    private var steps: [Step]
    private var operations: [UInt16] = []
    init(_ steps: [Step]) { self.steps = steps }
    func remainingCount() -> Int { steps.count }
    func recordedOperations() -> [UInt16] { operations }
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        let request = try PTPCodec.decode(command)
        operations.append(request.code)
        guard !steps.isEmpty else { XCTFail("Unexpected extra request"); throw PTPSessionError.invalidResponse }
        let step = steps.removeFirst()
        XCTAssertEqual(request.code, step.operation)
        let parameters = step.parameters.reduce(into: Data()) { data, value in
            for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8((value >> shift) & 255)) }
        }
        XCTAssertEqual(request.payload, parameters); XCTAssertNil(data)
        if let failure = step.failure { throw failure }
        return (PTPCodec.encode(type: .response, code: step.response, transactionID: request.transactionID), step.payload)
    }
}
