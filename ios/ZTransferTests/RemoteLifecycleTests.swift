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
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "selector")),
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

    func testTransportFailureUsesGlobalRecoveryOnceInsteadOfRestartingDeadLiveView() async throws {
        let camera = RemoteLifecycleCamera(transportFailure: true)
        var losses = 0
        let model = RemoteViewModel(camera: camera, onTransportLost: { losses += 1 })
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { losses == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.transportLossWasNotified)
        XCTAssertEqual(losses, 1)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1)
    }

    func testBatteryBecomesUnknownInsteadOfKeepingOldPercent() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .batteryLevel, dataType: 2, writable: false, current: 67, values: []))
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.batteryPercent == 67 }
        await camera.setProperty(.init(property: .batteryLevel, dataType: 2, writable: false, current: 255, values: []))
        await camera.emitBatteryEvent()
        try await waitFor { model.batteryPercent == nil }
    }

    func testCompatibleExposureUsesWritableFallbackAndRefreshesItsValueDomain() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .iso, writable: false, current: 100, values: [100]))
        await camera.setProperty(.init(property: .nikonISOEx, writable: true, current: 200, values: [100, 200]))
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        XCTAssertEqual(model.exposureDescriptors[.iso]?.property, .nikonISOEx)
        await camera.setProperty(.init(property: .nikonISOEx, writable: false, current: 400, values: [400, 800]))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.iso.rawValue),
                                  .init(code: 0x4006, handle: RemoteProperty.nikonISOEx.rawValue)])
        // Both descriptors are now read-only: Android retains the first readable
        // property and refreshes its complete description rather than stale enum.
        try await waitFor { model.exposureDescriptors[.iso]?.property == .iso }
        XCTAssertEqual(model.exposureDescriptors[.iso]?.values, [100])
        XCTAssertEqual(model.exposureDescriptors[.iso]?.writable, false)
    }

    func testInactiveMovieExposureEventRefreshesItsOwnCacheWithoutReplacingPhotoUI() async throws {
        let camera = RemoteLifecycleCamera(movie: false)
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        let before = await camera.log.filter { $0 == "property:movieISO" }.count
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.movieISO.rawValue)])
        try await waitFor {
            await camera.log.filter { $0 == "property:movieISO" }.count > before
        }
        XCTAssertFalse(model.movieMode)
        XCTAssertEqual(model.exposureDescriptors[.iso]?.property, .iso)
    }

    func testLevelDescribesOnDemandAndKeepsSwitchOnAfterThreeReadFailures() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .angleLevel, dataType: 5, writable: false,
                                       current: 23_514_322, values: []))
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        let before = await camera.log
        XCTAssertFalse(before.contains("property:angleLevel"))
        await camera.failRefresh(.angleLevel)
        model.setLevelVisible(true)
        try await waitFor { model.levelRoll != nil }
        XCTAssertEqual(try XCTUnwrap(model.levelRoll), -1.2, accuracy: 0.01)
        try await waitFor { model.levelRoll == nil }
        XCTAssertTrue(model.levelVisible)
        let stopped = await camera.log.filter { $0 == "refresh:angleLevel" }.count
        XCTAssertEqual(stopped, 3)
        try await Task.sleep(for: .milliseconds(300))
        let after = await camera.log.filter { $0 == "refresh:angleLevel" }.count
        XCTAssertEqual(after, stopped)
        model.setLevelVisible(false)
        XCTAssertFalse(model.levelVisible)
    }

    func testUnsupportedLevelClosesTheSameSwitchRenderedByTheView() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.markUnsupported(.angleLevel)
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        model.setLevelVisible(true)
        try await waitFor { !model.levelVisible }
        let calls = await camera.log
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "property:batteryLevel")),
                          try XCTUnwrap(calls.firstIndex(of: "property:angleLevel")))
        XCTAssertFalse(calls.contains("refresh:angleLevel"))
    }

    func testTapFocusInManualModeShowsAndroidHintWithoutSendingAF() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .focusMode, dataType: 0x0002,
                                       writable: false, current: 1, values: []))
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }

        model.focus(at: .init(x: 0.5, y: 0.5))

        XCTAssertEqual(model.interactionHint, AppLocalized.resource("remote_tap_focus_manual"))
        let calls = await camera.log
        XCTAssertFalse(calls.contains("tapfocus:start"))
    }

    func testInvalidTrackingModeShowsAndroidGuidance() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.queueFocusResults([
            .init(trackingStarted: false, polls: 0, timedOut: false,
                  responseCode: 0xA004, trackingResponseCode: 0xA004)
        ])
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }

        model.focus(at: .init(x: 0.5, y: 0.5))

        try await waitFor {
            model.interactionHint == AppLocalized.resource("remote_tracking_area_mode_required")
        }
        XCTAssertEqual(model.state.focus.phase, .failed)
    }

    func testTapFocusSeparatesTransientFeedbackFromThreeSecondConfirmedMarker() async throws {
        let camera = RemoteLifecycleCamera()
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }

        model.focus(at: .init(x: 0.25, y: 0.75))

        try await waitFor { model.confirmedFocusMarker != nil }
        XCTAssertEqual(model.state.focus.phase, .locked)
        XCTAssertEqual(model.confirmedFocusMarker?.fallbackPoint, .init(x: 0.25, y: 0.75))
        try await waitFor(timeout: 2.2) { model.state.focus.phase == .idle }
        XCTAssertNotNil(model.confirmedFocusMarker,
                        "Android keeps the confirmed marker after the 1.8-second feedback ends")
        try await waitFor(timeout: 1.6) { model.confirmedFocusMarker == nil }
    }

    func testHalfPressUsesLastFocusAreaAndKeepsLateConfirmedMarkerAfterRelease() async throws {
        let camera = RemoteLifecycleCamera()
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.delayFocus(milliseconds: 120)

        model.beginHalfPress()

        XCTAssertTrue(model.halfPressVisualActive)
        XCTAssertEqual(model.state.focus.phase, .focusing)
        XCTAssertEqual(model.state.focus.point, .init(x: 0.5, y: 0.5))
        model.endHalfPress(fire: false)
        XCTAssertFalse(model.halfPressVisualActive)
        XCTAssertEqual(model.state.focus.phase, .idle)
        try await waitFor { model.confirmedFocusMarker != nil }
        XCTAssertEqual(model.confirmedFocusMarker?.fallbackPoint, .init(x: 0.5, y: 0.5))
    }

    func testShutterWaitsForObjectAddedAndCommandFailureDoesNotFailLiveView() async throws {
        let camera = RemoteLifecycleCamera()
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.capture()
        try await waitFor { await camera.log.contains("capture") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.state.capture, .capturing)
        await camera.queueEvents([.init(code: 0xC101, handle: 17)])
        try await waitFor { model.state.capture == .idle }
        await camera.failCapture()
        model.capture()
        try await waitFor { model.state.capture == .idle }
        XCTAssertEqual(model.state.session, .ready)
    }

    func testMovieEventsSynchronizeCameraStateAndIgnoreLateStartAfterLocalStop() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.queueEvents([.init(code: 0xC10A, handle: 0)])
        try await waitFor { model.state.capture == .recording }
        await camera.queueEvents([.init(code: 0xC105, handle: 0)])
        try await waitFor { model.state.capture == .idle }
        model.toggleRecording()
        try await waitFor { model.state.capture == .recording && !model.recordingBusy }
        model.toggleRecording()
        try await waitFor { model.state.capture == .idle && !model.recordingBusy }
        await camera.queueEvents([.init(code: 0xC10A, handle: 0)])
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertEqual(model.state.capture, .idle)
    }

    func testWiFiMovieRecoveryRestartsLiveViewOnceAndWaitsForCompletionBeforeCleanup() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        await camera.queueMovieStarts([
            .init(responseCode: 0xA004, prohibitCondition: 1 << 14),
            .init(responseCode: PTPConstants.responseOK, prohibitCondition: nil)
        ])
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.toggleRecording()
        try await waitFor(timeout: 5) { model.state.capture == .recording && !model.recordingBusy }
        try await waitFor { model.state.session == .ready }

        let started = await camera.log
        let movieStarts = started.indices.filter { started[$0] == "movie:start" }
        XCTAssertEqual(movieStarts.count, 2)
        let recovery = Array(started[movieStarts[0]...movieStarts[1]])
        XCTAssertTrue(recovery.contains("end"))
        XCTAssertTrue(recovery.contains("app:on"))
        XCTAssertTrue(recovery.contains("set:liveViewImageSize"))
        XCTAssertTrue(recovery.contains("start"))

        model.toggleRecording()
        try await waitFor { await camera.log.contains("movie:end") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.recordingBusy, "application-mode stop waits for the completion event")
        let beforeEvent = await camera.log
        XCTAssertFalse(beforeEvent.contains("app:off:true"))
        await camera.queueEvents([.init(code: 0xC108, handle: 0)])
        try await waitFor(timeout: 3) { !model.recordingBusy }
        let stopped = await camera.log
        XCTAssertLessThan(try XCTUnwrap(stopped.firstIndex(of: "movie:end")),
                          try XCTUnwrap(stopped.firstIndex(of: "app:off:true")))
    }

    func testUSBMovieUsesFreshSessionAndReturnsToOrdinaryLiveViewAfterStop() async throws {
        let camera = RemoteLifecycleCamera(movie: true, isUSB: true)
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor(timeout: 5) { model.state.session == .ready }
        model.toggleRecording()
        try await waitFor(timeout: 5) {
            model.state.capture == .recording && !model.recordingBusy && model.state.session == .ready
        }
        let started = await camera.log
        let refresh = try XCTUnwrap(started.firstIndex(of: "usb:refresh"))
        XCTAssertLessThan(try XCTUnwrap(started[..<refresh].lastIndex(of: "end")), refresh)
        XCTAssertLessThan(refresh, try XCTUnwrap(started.firstIndex(of: "control:on")))
        XCTAssertLessThan(try XCTUnwrap(started.firstIndex(of: "control:on")),
                          try XCTUnwrap(started.firstIndex(of: "movie:prepared")))

        model.toggleRecording()
        try await waitFor { await camera.log.contains("movie:end") }
        await camera.queueEvents([.init(code: 0xC105, handle: 0)])
        try await waitFor(timeout: 3) { !model.recordingBusy && model.state.session == .ready }
        let stopped = await camera.log
        XCTAssertLessThan(try XCTUnwrap(stopped.firstIndex(of: "app:off:true")),
                          try XCTUnwrap(stopped.firstIndex(of: "control:off")))
        XCTAssertLessThan(try XCTUnwrap(stopped.firstIndex(of: "control:off")),
                          try XCTUnwrap(stopped.lastIndex(of: "start")))
    }

    func testExposureWritesCoalesceAndOldInFlightResultCannotReplaceNewValue() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .iso, writable: true, current: 100, values: [100, 200, 400, 800]))
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.acceptWrites(.iso)
        model.setExposure(.iso, value: 200, immediate: false)
        model.setExposure(.iso, value: 400, immediate: false)
        model.setExposure(.iso, value: 800, immediate: false)
        try await waitFor { await camera.log.contains("write:iso:800") }
        try await Task.sleep(for: .milliseconds(100))
        let writes = await camera.log.filter { $0.hasPrefix("write:iso:") }
        XCTAssertEqual(writes, ["write:iso:800"])
        await camera.delayWrites(milliseconds: 350)
        model.setExposure(.iso, value: 200)
        try await waitFor { await camera.log.contains("write:iso:200") }
        model.setExposure(.iso, value: 400)
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.iso.rawValue)])
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(model.exposureDescriptors[.iso]?.current, 400)
        try await waitFor { await camera.current(.iso) == 400 }
        await model.stopAndWait()
        let stopped = await camera.log
        try await Task.sleep(for: .milliseconds(200))
        let final = await camera.log
        XCTAssertEqual(stopped, final)
    }

    func testVerifiedWriteRetriesBusyAndConfirmsActualValue() async throws {
        let camera = RemoteLifecycleCamera()
        let descriptor = RemotePropertyDescriptor(property: .iso, writable: true, current: 100, values: [100, 200])
        await camera.setProperty(descriptor)
        await camera.acceptWrites(.iso)
        await camera.setWriteResponses(.iso, [0x2019, 0x2019, 0x2001])
        let result = try await camera.setRemotePropertyVerified(descriptor, value: 200)
        XCTAssertTrue(result.confirmed)
        XCTAssertEqual(result.actual?.current, 200)
        let writes = await camera.log.filter { $0 == "write:iso:200" }
        XCTAssertEqual(writes.count, 3)
    }

    func testAcceptedButUnadoptedValueIsNotConfirmedAndOnlyResentOnce() async throws {
        let camera = RemoteLifecycleCamera()
        let descriptor = RemotePropertyDescriptor(property: .iso, writable: true, current: 100, values: [100, 200])
        await camera.setProperty(descriptor)
        let result = try await camera.setRemotePropertyVerified(descriptor, value: 200)
        XCTAssertFalse(result.confirmed)
        XCTAssertEqual(result.actual?.current, 100)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "write:iso:200" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "refresh:iso" }.count, 5)
    }

    func testUnreadableWriteIsNotBlindlyResent() async throws {
        let camera = RemoteLifecycleCamera()
        let descriptor = RemotePropertyDescriptor(property: .iso, writable: true, current: 100, values: [100, 200])
        await camera.setProperty(descriptor)
        await camera.failRefresh(.iso)
        let result = try await camera.setRemotePropertyVerified(descriptor, value: 200)
        XCTAssertFalse(result.confirmed)
        XCTAssertNil(result.actual)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "write:iso:200" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "refresh:iso" }.count, 3)
    }

    func testMovieAutoISOFallsBackUsesNonzeroEnumAndIgnoresRepeatedTap() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        for property in [RemoteProperty.movieAutoISO, .nikonAutoISOAlternate] {
            await camera.setProperty(.init(property: property, dataType: 2, writable: true, current: 0, values: [0, 2]))
        }
        await camera.acceptWrites(.nikonAutoISOAlternate)
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.setAutoISO(true)
        model.setAutoISO(false)
        XCTAssertTrue(model.autoISOBusy)
        try await waitFor { !model.autoISOBusy }
        XCTAssertEqual(model.autoISODescriptor?.property, .nikonAutoISOAlternate)
        XCTAssertEqual(model.autoISODescriptor?.current, 2)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "write:movieAutoISO:2" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "write:nikonAutoISOAlternate:2" }.count, 1)
        XCTAssertFalse(calls.contains("write:movieAutoISO:0"))
    }

    func testAutoISOReadsEffectiveSensitivityAndStopsPollingWhenDisabled() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .nikonAutoISO, dataType: 2, writable: true, current: 1, values: [0, 1]))
        await camera.setProperty(.init(property: .nikonISOControlSensitivity, writable: false, current: 640, values: []))
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.effectiveISO?.current == 640 }
        await camera.setProperty(.init(property: .nikonISOControlSensitivity, writable: false, current: 800, values: []))
        try await waitFor { model.effectiveISO?.current == 800 }
        await camera.setProperty(.init(property: .nikonAutoISO, dataType: 2, writable: true, current: 0, values: [0, 1]))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.nikonAutoISO.rawValue)])
        try await waitFor { !model.autoISOEnabled }
        XCTAssertNil(model.effectiveISO)
        let count = await camera.log.filter { $0 == "refresh:nikonISOControlSensitivity" }.count
        try await Task.sleep(for: .milliseconds(650))
        let later = await camera.log.filter { $0 == "refresh:nikonISOControlSensitivity" }.count
        XCTAssertEqual(count, later)
    }

    func testLeavingDuringHalfPressDrainsAFWithoutCancellingOrLateCapture() async throws {
        let camera = RemoteLifecycleCamera()
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.delayFocus(milliseconds: 300)
        model.beginHalfPress()
        try await waitFor { await camera.log.contains("halfpress:start") }
        model.endHalfPress(fire: true)
        XCTAssertEqual(model.state.capture, .capturing, "Busy starts immediately while AF drains")
        await model.stopAndWait()
        let calls = await camera.log
        XCTAssertTrue(calls.contains("halfpress:end"))
        XCTAssertFalse(calls.contains("halfpress:cancelled"))
        XCTAssertFalse(calls.contains("capture"))
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "halfpress:end")),
                          try XCTUnwrap(calls.firstIndex(of: "gate:false")))
    }

    func testLeavingDuringTapFocusWaitsForTransactionAndDiscardsLateUIResult() async throws {
        let camera = RemoteLifecycleCamera()
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.delayFocus(milliseconds: 300)
        model.focus(at: .init(x: 0.5, y: 0.5))
        try await waitFor { await camera.log.contains("tapfocus:start") }
        await model.stopAndWait()
        let calls = await camera.log
        XCTAssertTrue(calls.contains("tapfocus:end"))
        XCTAssertFalse(calls.contains("tapfocus:cancelled"))
        XCTAssertEqual(model.state.session, .idle)
        XCTAssertEqual(model.state.focus.phase, .idle)
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "tapfocus:end")),
                          try XCTUnwrap(calls.firstIndex(of: "gate:false")))
    }

    private func waitFor(timeout: Double = 3, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for camera operation"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class RemoteMovieRulesTests: XCTestCase {
    func testLiveViewRestartMatchesAndroidProhibitMasks() {
        XCTAssertFalse(RemoteMovieStartResult(responseCode: PTPConstants.responseOK,
                                               prohibitCondition: nil).needsLiveViewRestart)
        for bit in [0, 1, 2, 3, 9, 10, 11] {
            XCTAssertFalse(RemoteMovieStartResult(responseCode: 0xA004,
                                                   prohibitCondition: 1 << bit).needsLiveViewRestart,
                           "bit \(bit) must not rebuild Live View")
        }
        for bit in [12, 14] {
            XCTAssertTrue(RemoteMovieStartResult(responseCode: 0xA004,
                                                  prohibitCondition: 1 << bit).needsLiveViewRestart,
                          "bit \(bit) requires the Android recovery path")
        }
        XCTAssertFalse(RemoteMovieStartResult(responseCode: 0xA004,
                                               prohibitCondition: 1 << 8).needsLiveViewRestart)
        XCTAssertTrue(RemoteMovieStartResult(responseCode: 0xA004,
                                              prohibitCondition: nil).needsLiveViewRestart)
        XCTAssertTrue(RemoteMovieStartResult(responseCode: PTPConstants.deviceBusy,
                                              prohibitCondition: 0).needsLiveViewRestart)
    }
}

@MainActor
private final class RemoteDecodedFrameCollector {
    var frames: [RemoteDecodedFrame] = []
}

final class RemoteFrameDecodePipelineTests: XCTestCase {
    func testPipelineConflatesPendingFramesRunsAnalysisOffMainAndRejectsOldGeneration() async throws {
        let collector = await MainActor.run { RemoteDecodedFrameCollector() }
        let pipeline = RemoteFrameDecodePipeline(decodeDelayNanoseconds: 80_000_000) { frame in
            collector.frames.append(frame)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        func request(_ fps: Double, generation: UInt64) -> RemoteFrameDecodePipeline.Request {
            .init(packet: .init(bytes: jpeg, jpegOffset: 0,
                                operation: PTPConstants.getLiveViewImage),
                  fps: fps, generation: generation)
        }

        await pipeline.reset(generation: 1)
        await pipeline.setAnalysis(histogram: true, zebra: true)
        await pipeline.submit(request(1, generation: 1))
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await pipeline.isDecoding), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        await pipeline.submit(request(2, generation: 1))
        await pipeline.submit(request(3, generation: 1))
        await pipeline.submit(request(4, generation: 1))
        await pipeline.waitUntilIdle()
        var frames = await MainActor.run { collector.frames }
        XCTAssertEqual(frames.map(\.fps), [1, 4])
        XCTAssertEqual(frames.last?.histogram?.count, 24)
        XCTAssertNotNil(frames.last?.zebraMask)

        await pipeline.submit(request(5, generation: 1))
        while !(await pipeline.isDecoding), ContinuousClock.now < deadline + .seconds(1) {
            try await Task.sleep(for: .milliseconds(1))
        }
        await pipeline.reset(generation: 2)
        await pipeline.setAnalysis(histogram: false, zebra: false)
        await pipeline.submit(request(6, generation: 2))
        await pipeline.waitUntilIdle()
        frames = await MainActor.run { collector.frames }
        XCTAssertEqual(frames.map(\.fps), [1, 4, 6])
        XCTAssertNil(frames.last?.histogram)
        XCTAssertNil(frames.last?.zebraMask)
    }
}

final class RemoteViewfinderRecorderTests: XCTestCase {
    func testRecorderWritesLiveViewFramesAndFinalizesPlayableContainer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-recorder-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent("rec_test.mp4")
        let recorder = RemoteViewfinderRecorder(outputURL: output,
                                                sourceSize: CGSize(width: 64, height: 48),
                                                withAudio: false)
        XCTAssertTrue(recorder.start())
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        recorder.append(image: image, receivedAtUptime: 100)
        recorder.append(image: image, receivedAtUptime: 100.05)
        recorder.pause()
        recorder.append(image: image, receivedAtUptime: 100.10)
        recorder.resume()
        recorder.append(image: image, receivedAtUptime: 100.15)
        let result = await recorder.stop()
        XCTAssertEqual(result, output)
        let values = try output.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertGreaterThan(values.fileSize ?? 0, 0)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RemoteLifecycleCamera: RemoteCameraControlling {
    nonisolated let isUSB: Bool
    private(set) var log: [String] = []
    private let movie: Bool
    private var failingFrames: Int
    private var transportFailure: Bool
    private var batteryEvent = false
    private var overrides: [RemoteProperty: RemotePropertyDescriptor] = [:]
    private var unsupported = Set<RemoteProperty>()
    private var refreshFailures = Set<RemoteProperty>()
    private var queuedEvents: [STAEvent] = []
    private var captureFails = false
    private var acceptedWrites = Set<RemoteProperty>()
    private var writeResponses: [RemoteProperty: [UInt16]] = [:]
    private var writeDelay = 0
    private var focusDelay = 0
    private var focusResults: [RemoteFocusResult] = []
    private var movieStarts: [RemoteMovieStartResult] = []
    private var remoteControlMode = false
    private var applicationMode = false
    private let frame: Data
    init(movie: Bool = false, failingFrames: Int = 0, isUSB: Bool = false,
         transportFailure: Bool = false) {
        self.movie = movie
        self.failingFrames = failingFrames
        self.isUSB = isUSB
        self.transportFailure = transportFailure
        self.frame = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.jpegData(compressionQuality: 0.5)!
    }
    func setRemoteActive(_ active: Bool) { log.append("gate:\(active)") }
    func startLiveView() { log.append("start") }
    func endLiveView() { log.append("end") }
    func liveViewFrame() async throws -> RemoteLiveViewPacket {
        log.append("frame")
        do { try await Task.sleep(for: .milliseconds(20)) }
        catch { log.append("cancelled-frame"); throw error }
        if transportFailure { transportFailure = false; throw PTPSessionError.timeout }
        if failingFrames > 0 { failingFrames -= 1; throw PTPSessionError.responseCode(0xA004) }
        return .init(bytes: frame, jpegOffset: 0, operation: PTPConstants.getLiveViewImage)
    }
    func remoteMovieMode() -> Bool? {
        log.append("selector")
        return overrides[.liveViewSelector].map { $0.current != 0 } ?? movie
    }
    func remoteProperty(_ property: RemoteProperty) -> RemotePropertyDescriptor? {
        log.append("property:\(property)")
        if unsupported.contains(property) { return nil }
        if let descriptor = overrides[property] { return descriptor }
        return .init(property: property, dataType: property == .batteryLevel ? 0x0002 : 0x0006, writable: true,
                     current: property == .liveViewSelector ? (movie ? 1 : 0) : 0, values: [0, 1])
    }
    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) -> RemotePropertyDescriptor? {
        log.append("refresh:\(descriptor.property)")
        if refreshFailures.contains(descriptor.property) { return nil }
        return overrides[descriptor.property] ?? descriptor
    }
    func remoteFocusMode() -> RemotePropertyDescriptor? {
        log.append("focus")
        return overrides[.focusMode] ?? overrides[.nikonAFMode]
    }
    func emitBatteryEvent() { batteryEvent = true }
    func setProperty(_ descriptor: RemotePropertyDescriptor) { overrides[descriptor.property] = descriptor }
    func markUnsupported(_ property: RemoteProperty) { unsupported.insert(property) }
    func failRefresh(_ property: RemoteProperty) { refreshFailures.insert(property) }
    func queueEvents(_ events: [STAEvent]) { queuedEvents += events }
    func queueMovieStarts(_ results: [RemoteMovieStartResult]) { movieStarts += results }
    func failCapture() { captureFails = true }
    func acceptWrites(_ property: RemoteProperty) { acceptedWrites.insert(property) }
    func setWriteResponses(_ property: RemoteProperty, _ codes: [UInt16]) { writeResponses[property] = codes }
    func delayFocus(milliseconds: Int) { focusDelay = milliseconds }
    func queueFocusResults(_ results: [RemoteFocusResult]) { focusResults += results }
    func delayWrites(milliseconds: Int) { writeDelay = milliseconds }
    func current(_ property: RemoteProperty) -> UInt64? { overrides[property]?.current }
    func remoteEvents() -> [STAEvent] {
        log.append("events")
        defer { batteryEvent = false; queuedEvents = [] }
        return queuedEvents + (batteryEvent ? [.init(code: 0x4006, handle: RemoteProperty.batteryLevel.rawValue)] : [])
    }
    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws {
        log.append("set:\(descriptor.property)")
        log.append("write:\(descriptor.property):\(value)")
        if writeDelay > 0 { try await Task.sleep(for: .milliseconds(writeDelay)) }
        if let code = writeResponses[descriptor.property]?.first {
            writeResponses[descriptor.property]?.removeFirst()
            if code != 0x2001 { throw PTPSessionError.responseCode(code) }
        }
        if acceptedWrites.contains(descriptor.property) {
            var actual = descriptor
            actual.current = value
            overrides[descriptor.property] = actual
        }
    }
    func capturePhoto() throws {
        log.append("capture")
        if captureFails { throw PTPSessionError.responseCode(0xA004) }
    }
    func focusAt(trackingX: UInt32, trackingY: UInt32, focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult {
        try await finishFocus("tapfocus")
    }
    func halfPressFocus() async throws -> RemoteFocusResult { try await finishFocus("halfpress") }
    private func finishFocus(_ prefix: String) async throws -> RemoteFocusResult {
        log.append("\(prefix):start")
        do { if focusDelay > 0 { try await Task.sleep(for: .milliseconds(focusDelay)) } }
        catch { log.append("\(prefix):cancelled"); throw error }
        log.append("\(prefix):end")
        if !focusResults.isEmpty { return focusResults.removeFirst() }
        return .init(trackingStarted: false, polls: 0, timedOut: false)
    }
    func endSubjectTracking() {}
    func startMovieRecording() -> RemoteMovieStartResult {
        log.append("movie:start")
        guard !movieStarts.isEmpty else {
            return .init(responseCode: PTPConstants.responseOK, prohibitCondition: nil)
        }
        return movieStarts.removeFirst()
    }
    func endMovieRecording() -> UInt16 { log.append("movie:end"); return PTPConstants.responseOK }
    func refreshUSBRemoteSession() -> String { log.append("usb:refresh"); return "refreshed" }
    func setRemoteControlMode(_ enabled: Bool) -> UInt16 {
        log.append("control:\(enabled ? "on" : "off")")
        remoteControlMode = enabled
        return PTPConstants.responseOK
    }
    func hasRemoteControlMode() -> Bool { remoteControlMode }
    func hasMovieApplicationMode() -> Bool { applicationMode }
    func ensureMovieApplicationMode() {
        log.append("app:on")
        applicationMode = true
    }
    func clearMovieApplicationMode(force: Bool) {
        log.append("app:off:\(force)")
        applicationMode = false
    }
    func startPreparedUSBMovieRecording() -> RemoteMovieStartResult {
        log.append("movie:prepared")
        applicationMode = true
        return .init(responseCode: PTPConstants.responseOK, prohibitCondition: nil)
    }
}

/// Replay the wire responses, including capability fallback and malformed frames.
/// These exercise CameraRepository, not a mock of its frame selection policy.
final class RemoteFrameProtocolTests: XCTestCase {
    private let standard = PTPConstants.getLiveViewImage
    private let enhanced = PTPConstants.getLiveViewImageEx
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

    func testUnadvertisedEnhancedOperationIsNeverProbed() async throws {
        let wire = RemoteWireReplay([.init(0x9201), .init(0x90C8), .init(standard, payload: jpeg)])
        let camera = repository(wire, enhanced: false)
        try await camera.startLiveView()
        let frame = try await camera.liveViewFrame()
        XCTAssertEqual(frame.operation, standard)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testUnsupportedEnhancedImmediatelyFallsBackAndRemembersAcrossRestart() async throws {
        let wire = RemoteWireReplay([
            .init(0x9201), .init(0x90C8), .init(enhanced, code: 0x2005), .init(standard, payload: jpeg),
            .init(0x9201), .init(0x90C8), .init(standard, payload: jpeg)
        ])
        let camera = repository(wire)
        try await camera.startLiveView()
        let first = try await camera.liveViewFrame()
        try await camera.startLiveView()
        let second = try await camera.liveViewFrame()
        XCTAssertEqual(first.operation, standard)
        XCTAssertEqual(second.operation, standard)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testBadEnhancedFrameNeedsTwoFailuresAndSuccessResetsCounter() async throws {
        let wire = RemoteWireReplay([
            .init(0x9201), .init(0x90C8), .init(enhanced, payload: Data([1, 2, 3])),
            .init(enhanced, payload: jpeg), .init(enhanced), .init(enhanced, code: 0xA004),
            .init(standard, payload: jpeg)
        ])
        let camera = repository(wire)
        try await camera.startLiveView()
        await expectFailure(camera, error: CameraRepositoryError.invalidDataset)
        let success = try await camera.liveViewFrame()
        XCTAssertEqual(success.operation, enhanced)
        await expectFailure(camera, error: CameraRepositoryError.invalidDataset)
        let fallback = try await camera.liveViewFrame()
        XCTAssertEqual(fallback.operation, standard)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testBusyAndNotLiveViewDoNotDowngradeOrEraseAnEarlierFailure() async throws {
        let wire = RemoteWireReplay([
            .init(0x9201), .init(0x90C8), .init(enhanced),
            .init(enhanced, code: 0x2019), .init(enhanced, code: 0xA00B),
            .init(enhanced), .init(standard, payload: jpeg)
        ])
        let camera = repository(wire)
        try await camera.startLiveView()
        await expectFailure(camera, error: CameraRepositoryError.invalidDataset)
        await expectFailure(camera, error: PTPSessionError.responseCode(0x2019))
        await expectFailure(camera, error: PTPSessionError.responseCode(0xA00B))
        let fallback = try await camera.liveViewFrame()
        XCTAssertEqual(fallback.operation, standard)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testDirectFrameReadDoesNotFetchDeviceInfoAndRequiresThreeByteSOI() async throws {
        let wire = RemoteWireReplay([
            .init(standard, payload: Data([0xFF, 0xD8, 0x01])),
            .init(standard, payload: Data([0, 0xFF, 0xD8, 0xFF, 0x01]))
        ])
        let camera = repository(wire)
        await expectFailure(camera, error: CameraRepositoryError.invalidDataset)
        let frame = try await camera.liveViewFrame()
        XCTAssertEqual(frame.jpegOffset, 1)
        XCTAssertEqual(frame.operation, standard)
    }

    func testSelectorReadsFirstByteWithoutRequiringDescription() async throws {
        let wire = RemoteWireReplay([
            .init(0x1015, parameters: [0xD1A6], payload: Data([2, 0])),
            .init(0x1015, parameters: [0xD1A6], payload: Data([0])),
            .init(0x1015, parameters: [0xD1A6], code: 0x2005)
        ])
        let camera = repository(wire)
        let movie = try await camera.remoteMovieMode()
        let photo = try await camera.remoteMovieMode()
        let unknown = try await camera.remoteMovieMode()
        XCTAssertEqual(movie, true)
        XCTAssertEqual(photo, false)
        XCTAssertNil(unknown)
    }

    func testCaptureUsesNoAutofocusCardParametersAndBusyRetry() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.captureInMedia, parameters: [.max, 0], code: 0x2019),
            .init(PTPConstants.captureInMedia, parameters: [.max, 0])
        ])
        try await repository(wire).capturePhoto()
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testNonBusyDeviceReadyResponseStillAllowsFrameAttempt() async throws {
        let wire = RemoteWireReplay([.init(0x9201), .init(0x90C8, code: 0x2005), .init(enhanced, payload: jpeg)])
        let camera = repository(wire)
        try await camera.startLiveView()
        _ = try await camera.liveViewFrame()
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testUnsupportedTrackingIsRememberedAndUsesIndependentAFCoordinates() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [900, 600], code: 0x2005),
            .init(0x9205, parameters: [90, 60]), .init(0x90C1), .init(0x90C8),
            .init(0x9205, parameters: [30, 20]), .init(0x90C1), .init(0x90C8)
        ])
        let camera = repository(wire)
        let first = try await camera.focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60)
        let second = try await camera.focusAt(trackingX: 300, trackingY: 200, focusX: 30, focusY: 20)
        XCTAssertFalse(first.trackingStarted)
        XCTAssertFalse(second.trackingStarted)
        XCTAssertEqual(first.polls, 1)
        XCTAssertEqual(second.responseCode, 0x2001)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testTrackingBusyDoesNotFallBackToAF() async throws {
        let wire = RemoteWireReplay([.init(0x9424, parameters: [900, 600], code: 0x2019)])
        let result = try await repository(wire).focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60)
        XCTAssertFalse(result.trackingStarted)
        XCTAssertEqual(result.responseCode, 0x2019)
        let operations = await wire.operations
        XCTAssertEqual(operations, [0x9424])
    }

    func testFailedEndTrackingPreventsNewTargetButEndLiveViewStillCloses() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [900, 600]), .init(0x90C1), .init(0x90C8),
            .init(0x9425, code: 0x2019), .init(0x9425, code: 0x2019), .init(0x9202)
        ])
        let camera = repository(wire)
        _ = try await camera.focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60)
        let second = try await camera.focusAt(trackingX: 300, trackingY: 200, focusX: 30, focusY: 20)
        XCTAssertFalse(second.trackingStarted)
        XCTAssertEqual(second.responseCode, 0x2019)
        await camera.endLiveView()
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testHalfPressEndsTrackingBeforeAFAndNegativeReadyIsNotSuccess() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [900, 600]), .init(0x90C1), .init(0x90C8),
            .init(0x9425, code: 0xA004), .init(0x90C1), .init(0x90C8, code: 0xA002),
            .init(0x9202)
        ])
        let camera = repository(wire)
        _ = try await camera.focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60)
        let halfPress = try await camera.halfPressFocus()
        XCTAssertEqual(halfPress.responseCode, 0xA002)
        XCTAssertFalse(halfPress.timedOut)
        await camera.endLiveView()
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testTrackingRemainsActiveAfterOutOfFocusAndIsClosedWithLiveView() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [900, 600]), .init(0x90C1), .init(0x90C8, code: 0xA002),
            .init(0x9425), .init(0x9202)
        ])
        let camera = repository(wire)
        let result = try await camera.focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60)
        XCTAssertTrue(result.trackingStarted)
        XCTAssertEqual(result.responseCode, 0xA002)
        await camera.endLiveView()
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testFramesCannotInterruptTrackingSettlingButMayRunBeforeReadyPoll() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [900, 600]), .init(0x90C1),
            .init(standard, payload: jpeg), .init(0x90C8)
        ])
        let camera = repository(wire)
        let focus = Task { try await camera.focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60) }
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await wire.operations.contains(0x9424)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let frame = Task { try await camera.liveViewFrame() }
        let result = try await focus.value
        _ = try await frame.value
        XCTAssertEqual(result.responseCode, 0x2001)
        let operations = await wire.operations
        XCTAssertEqual(operations, [0x9424, 0x90C1, standard, 0x90C8])
    }

    func testPreparedUSBMovieStartsDirectlyWhenApplicationModeIsNotRequired() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.getDevicePropValueEx, parameters: [0xD0A4]),
            .init(PTPConstants.getDevicePropValue, parameters: [0xD0A4], payload: littleEndian(0)),
            .init(PTPConstants.startMovieRecording)
        ])
        let result = try await repository(wire, usb: true).startPreparedUSBMovieRecording()
        XCTAssertTrue(result.indicatesRecording)
        XCTAssertEqual(result.prohibitExtendedResponse, PTPConstants.responseOK)
        XCTAssertNil(result.applicationModeResponse)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testPreparedUSBMovieEnablesApplicationOperationInsideOneSequence() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.getDevicePropValueEx, parameters: [0xD0A4]),
            .init(PTPConstants.getDevicePropValue, parameters: [0xD0A4], payload: littleEndian(1 << 14)),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [1]),
            .init(PTPConstants.startMovieRecording)
        ])
        let camera = repository(wire, usb: true)
        let result = try await camera.startPreparedUSBMovieRecording()
        XCTAssertEqual(result.applicationModeResponse, PTPConstants.responseOK)
        let active = await camera.hasMovieApplicationMode()
        let remaining = await wire.remaining
        XCTAssertTrue(active)
        XCTAssertEqual(remaining, 0)
    }

    func testPreparedUSBMovieFallsBackToApplicationPropertyWhenOperationIsUnsupported() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.getDevicePropValueEx, parameters: [0xD0A4]),
            .init(PTPConstants.getDevicePropValue, parameters: [0xD0A4], payload: littleEndian(1 << 14)),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [1], code: PTPConstants.operationNotSupported),
            .init(PTPConstants.setDevicePropValue, parameters: [RemoteProperty.applicationMode.rawValue],
                  sentData: Data([1])),
            .init(PTPConstants.getDevicePropValue, parameters: [0xD0A4], payload: littleEndian(0)),
            .init(PTPConstants.startMovieRecording)
        ])
        let result = try await repository(wire, usb: true).startPreparedUSBMovieRecording()
        XCTAssertEqual(result.applicationModeResponse, PTPConstants.operationNotSupported)
        XCTAssertEqual(result.applicationModePropertyResponse, PTPConstants.responseOK)
        XCTAssertTrue(result.indicatesRecording)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testControlModeBusyRetryAndApplicationCleanupFollowAndroidOrder() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.setControlMode, parameters: [1], code: PTPConstants.deviceBusy),
            .init(PTPConstants.setControlMode, parameters: [1], code: PTPConstants.deviceBusy),
            .init(PTPConstants.setControlMode, parameters: [1]),
            .init(PTPConstants.setDevicePropValue, parameters: [RemoteProperty.applicationMode.rawValue],
                  sentData: Data([1])),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [1]),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [0]),
            .init(PTPConstants.setDevicePropValue, parameters: [RemoteProperty.applicationMode.rawValue],
                  sentData: Data([0])),
            .init(PTPConstants.setControlMode, parameters: [0])
        ])
        let camera = repository(wire, usb: true)
        let enter = try await camera.setRemoteControlMode(true)
        XCTAssertEqual(enter, PTPConstants.responseOK)
        try await camera.ensureMovieApplicationMode()
        await camera.clearMovieApplicationMode(force: true)
        let leave = try await camera.setRemoteControlMode(false)
        let controlActive = await camera.hasRemoteControlMode()
        let applicationActive = await camera.hasMovieApplicationMode()
        let remaining = await wire.remaining
        XCTAssertEqual(leave, PTPConstants.responseOK)
        XCTAssertFalse(controlActive)
        XCTAssertFalse(applicationActive)
        XCTAssertEqual(remaining, 0)
    }

    private func repository(_ wire: RemoteWireReplay, enhanced: Bool = true,
                            usb: Bool = false) -> CameraRepository {
        let info = PTPDeviceInfo(standardVersion: 100, vendorExtensionID: 10, vendorExtensionVersion: 100,
            vendorExtensionDescription: "", functionalMode: 0, manufacturer: "Nikon", model: "Z30",
            version: "", serialNumber: "", operations: enhanced ? [standard, self.enhanced] : [standard],
            events: [], properties: [], captureFormats: [], imageFormats: [])
        return CameraRepository(session: PTPSession(transport: wire), isUSBConnection: usb, deviceInfo: info)
    }

    private func littleEndian(_ value: UInt32) -> Data {
        var raw = value.littleEndian
        return Data(bytes: &raw, count: MemoryLayout<UInt32>.size)
    }

    private func expectFailure<E: Error & Equatable>(_ camera: CameraRepository, error expected: E) async {
        do { _ = try await camera.liveViewFrame(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? E, expected) }
    }
}

private actor RemoteWireReplay: PTPCommandTransport {
    struct Step: Sendable {
        let operation: UInt16
        let parameters: [UInt32]
        let code: UInt16
        let payload: Data
        let sentData: Data?
        init(_ operation: UInt16, parameters: [UInt32] = [], code: UInt16 = 0x2001,
             payload: Data = Data(), sentData: Data? = nil) {
            self.operation = operation; self.parameters = parameters; self.code = code
            self.payload = payload; self.sentData = sentData
        }
    }
    private var steps: [Step]
    private(set) var operations: [UInt16] = []
    var remaining: Int { steps.count }
    init(_ steps: [Step]) { self.steps = steps }
    func sendPTP(command: Data, data: Data?) throws -> (response: Data, payload: Data) {
        let packet = try PTPCodec.decode(command)
        operations.append(packet.code)
        guard !steps.isEmpty else { throw CocoaError(.coderInvalidValue) }
        let expected = steps.removeFirst()
        var reader = PTPDataReader(packet.payload)
        var parameters: [UInt32] = []
        while let value = reader.readUInt32() { parameters.append(value) }
        guard packet.code == expected.operation, parameters == expected.parameters,
              expected.sentData == nil || data == expected.sentData else {
            throw CocoaError(.coderInvalidValue)
        }
        return (PTPCodec.encode(type: .response, code: expected.code, transactionID: packet.transactionID), expected.payload)
    }
}
