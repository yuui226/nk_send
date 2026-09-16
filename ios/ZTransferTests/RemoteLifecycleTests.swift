import XCTest
import UIKit
@testable import ZTransfer

@MainActor
final class RemoteLifecycleTests: XCTestCase {
    func testEntryGatesBeforeParametersAndSelectsMovieExposureBeforeLiveView() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor { await camera.log.contains("frame") }
        let calls = await camera.log
        XCTAssertEqual(calls.first, "gate:true")
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "property:liveViewSelector")),
                          try XCTUnwrap(calls.firstIndex(of: "property:movieISO")))
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "property:batteryLevel")),
                          try XCTUnwrap(calls.firstIndex(of: "start")))
        XCTAssertFalse(calls.contains("property:iso"))
        XCTAssertTrue(model.movieMode)
        await model.stopAndWait()
        let stopped = await camera.log
        XCTAssertEqual(stopped.last, "gate:false")
        XCTAssertLessThan(try XCTUnwrap(stopped.lastIndex(of: "end")), stopped.count - 1)
    }

    func testBatteryUsesEventsInsteadOfSixHundredMillisecondPolling() async throws {
        let camera = RemoteLifecycleCamera()
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor { await camera.log.contains("events") }
        try await Task.sleep(for: .milliseconds(1300))
        let before = await camera.log
        XCTAssertEqual(before.filter { $0 == "property:batteryLevel" }.count, 1)
        XCTAssertFalse(before.contains("refresh:batteryLevel"))
        await camera.emitBatteryEvent()
        try await waitFor { await camera.log.contains("refresh:batteryLevel") }
        await model.stopAndWait()
        let after = await camera.log
        try await Task.sleep(for: .milliseconds(150))
        let final = await camera.log
        XCTAssertEqual(after, final, "No polling commands may survive page disposal")
    }

    func testHDChangeEndsOldLiveViewWithoutReleasingPageGate() async throws {
        let camera = RemoteLifecycleCamera()
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor { await camera.log.contains("frame") }
        model.setHDLiveView(true)
        try await waitFor { await camera.log.filter { $0 == "start" }.count == 2 }
        let calls = await camera.log
        let starts = calls.indices.filter { calls[$0] == "start" }
        XCTAssertTrue(calls[starts[0]..<starts[1]].contains("end"))
        XCTAssertFalse(calls.contains("gate:false"))
        XCTAssertFalse(calls.contains("cancelled-frame"))
        await model.stopAndWait()
    }

    func testRepeatedNonBusyFrameErrorsRestartLiveView() async throws {
        let camera = RemoteLifecycleCamera(failingFrames: 3)
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor(timeout: 5) { await camera.log.filter { $0 == "start" }.count == 2 }
        let calls = await camera.log
        XCTAssertTrue(calls.contains("end"))
        XCTAssertFalse(calls.contains("gate:false"))
        await model.stopAndWait()
    }

    private func waitFor(timeout: Double = 3, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for camera operation"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor RemoteLifecycleCamera: RemoteCameraControlling {
    nonisolated let isUSB = false
    private(set) var log: [String] = []
    private let movie: Bool
    private var failingFrames: Int
    private var batteryEvent = false
    private let frame: Data
    init(movie: Bool = false, failingFrames: Int = 0) {
        self.movie = movie
        self.failingFrames = failingFrames
        self.frame = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.jpegData(compressionQuality: 0.5)!
    }
    func setRemoteActive(_ active: Bool) { log.append("gate:\(active)") }
    func startLiveView() { log.append("start") }
    func endLiveView() { log.append("end") }
    func liveViewFrame(preferEnhanced: Bool) async throws -> Data {
        log.append("frame")
        do { try await Task.sleep(for: .milliseconds(20)) }
        catch { log.append("cancelled-frame"); throw error }
        if failingFrames > 0 { failingFrames -= 1; throw PTPSessionError.responseCode(0xA004) }
        return frame
    }
    func remoteProperty(_ property: RemoteProperty) -> RemotePropertyDescriptor? {
        log.append("property:\(property)")
        return .init(property: property, writable: true,
                     current: property == .liveViewSelector ? (movie ? 1 : 0) : 0, values: [0, 1])
    }
    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) -> RemotePropertyDescriptor? {
        log.append("refresh:\(descriptor.property)"); return descriptor
    }
    func remoteFocusMode() -> RemotePropertyDescriptor? { log.append("focus"); return nil }
    func emitBatteryEvent() { batteryEvent = true }
    func remoteEvents() -> [STAEvent] {
        log.append("events")
        defer { batteryEvent = false }
        return batteryEvent ? [.init(code: 0x4006, handle: RemoteProperty.batteryLevel.rawValue)] : []
    }
    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) { log.append("set:\(descriptor.property)") }
    func capturePhoto() {}
    func focusAt(trackingX: UInt32, trackingY: UInt32, focusX: UInt32, focusY: UInt32) -> RemoteFocusResult {
        .init(trackingStarted: false, polls: 0, timedOut: false)
    }
    func halfPressFocus() -> RemoteFocusResult { .init(trackingStarted: false, polls: 0, timedOut: false) }
    func endSubjectTracking() {}
    func startMovieRecording() -> RemoteMovieStartResult { .init(responseCode: PTPConstants.responseOK, prohibitCondition: nil) }
    func endMovieRecording() -> UInt16 { PTPConstants.responseOK }
}
