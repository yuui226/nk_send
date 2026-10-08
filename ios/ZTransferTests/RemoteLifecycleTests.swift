import XCTest
import UIKit
@preconcurrency import AVFoundation
@testable import ZTransfer

@MainActor
final class RemoteLifecycleTests: XCTestCase {
    func testZoomedTapCoordinatesReachCameraAndConfirmedMarker() async throws {
        let camera = RemoteLifecycleCamera()
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        var viewport = RemoteViewfinderViewport()
        viewport.resize(CGSize(width: 1000, height: 600), aspect: 5 / 3)
        viewport.transform(centroid: CGPoint(x: 500, y: 300), pan: CGSize(width: 100, height: -50), zoom: 2, aspect: 5 / 3)
        let point = try XCTUnwrap(viewport.focusPoint(at: CGPoint(x: 700, y: 400), aspect: 5 / 3))
        model.focus(at: point, coordinateSize: CGSize(width: 2000, height: 1200))
        try await waitFor { model.confirmedFocusMarker != nil }
        let coordinates = await camera.lastFocusCoordinates
        XCTAssertEqual(coordinates, [1099, 749, 1099, 749])
        XCTAssertEqual(model.confirmedFocusMarker?.fallbackPoint, point)
    }

    func testFocusAreaWriteRequiresTrackingReleaseAndClearsConfirmedFocusOnlyOnSuccess() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .focusArea, dataType: 4, writable: true,
                                       current: 0x8010, values: [0x8010, 0x8011]))
        await camera.acceptWrites(.focusArea)
        await camera.queueFocusResults([.init(trackingStarted: true, polls: 0, timedOut: false)])
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.focus(at: .init(x: 0.4, y: 0.6))
        try await waitFor { model.state.focus.tracking && model.confirmedFocusMarker != nil }
        model.openCameraTool(.focusArea)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        await camera.setTrackingReleaseResponse(PTPConstants.deviceBusy)
        panel.select(0x8011)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.errorResource, "remote_camera_tool_failed")
        XCTAssertTrue(model.state.focus.tracking)
        XCTAssertNotNil(model.confirmedFocusMarker)
        let refused = await camera.log
        XCTAssertFalse(refused.contains("write:focusArea:32785"))
        // Android accepts invalid-status as an already-ended tracking session.
        await camera.setTrackingReleaseResponse(0xA004)
        panel.select(0x8011)
        try await waitFor { !panel.busy }
        XCTAssertFalse(model.state.focus.tracking)
        XCTAssertNil(model.confirmedFocusMarker)
        XCTAssertEqual(model.state.focus.phase, .idle)
        XCTAssertTrue(panel.closeRequested)
        XCTAssertEqual(panel.descriptor?.current, 0x8011)
        let completed = await camera.log
        XCTAssertEqual(completed.filter { $0 == "end-tracking-tool" }.count, 2)
        XCTAssertEqual(completed.filter { $0 == "write:focusArea:32785" }.count, 1)
        XCTAssertTrue(completed.suffix(4).contains("focus"))
    }

    func testCameraToolLaterReadFailureKeepsRowsButUnavailableReadClearsThem() async throws {
        let camera = RemoteLifecycleCamera()
        var unavailable = 0
        let panel = RemoteCameraToolController(camera: camera, tool: .whiteBalance, movie: false,
            isCurrent: { true }, currentMovie: { false }, canWrite: { true }, beforeWrite: { true },
            onApplied: {}, onUnavailable: { unavailable += 1 }, onDismiss: {}, pollInterval: .milliseconds(20))
        panel.start()
        try await waitFor { !panel.loading }
        let first = panel.descriptor
        await camera.failProperty(.whiteBalance, error: .timeout)
        try await waitFor { await camera.log.filter { $0 == "property:whiteBalance" }.count >= 3 }
        XCTAssertEqual(panel.descriptor, first)
        XCTAssertEqual(unavailable, 0)
        await camera.failProperty(.whiteBalance, error: .responseCode(0x200A))
        try await waitFor { panel.descriptor == nil }
        XCTAssertTrue(panel.active)
        XCTAssertFalse(panel.loading)
        XCTAssertEqual(unavailable, 0)
        panel.dismiss()
        await panel.drain()
    }

    func testCameraToolLoadingCloseNeverPublishesLateRowsOrCancelsWireRead() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.delayProperty(.whiteBalance, milliseconds: 120)
        var unavailable = 0
        var dismissed = 0
        let panel = RemoteCameraToolController(camera: camera, tool: .whiteBalance, movie: false,
            isCurrent: { true }, currentMovie: { false }, canWrite: { true }, beforeWrite: { true },
            onApplied: {}, onUnavailable: { unavailable += 1 }, onDismiss: { dismissed += 1 })
        panel.start()
        try await waitFor { await camera.log.contains("property:whiteBalance") }
        panel.requestClose()
        XCTAssertFalse(panel.active)
        await panel.drain()
        XCTAssertNil(panel.descriptor)
        XCTAssertEqual(unavailable, 0)
        XCTAssertEqual(dismissed, 1)
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:whiteBalance"])
    }

    func testCameraToolPanelRechecksChangedOptionsWithoutWriting() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.whiteBalance)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 5]))
        panel.select(4)
        XCTAssertEqual(panel.pendingValue, 4)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.errorResource, "remote_camera_tool_changed")
        XCTAssertEqual(panel.descriptor?.values, [2, 5])
        XCTAssertFalse(panel.closeRequested)
        let calls = await camera.log
        XCTAssertFalse(calls.contains { $0.hasPrefix("write:whiteBalance:") })
        await model.stopAndWait()
    }

    func testCameraToolPanelRejectsPhysicalModeChangeBeforeWriting() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.whiteBalance)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        await camera.setProperty(.init(property: .liveViewSelector, writable: false, current: 1, values: []))
        panel.select(4)
        try await waitFor { !panel.busy }
        let calls = await camera.log
        XCTAssertFalse(calls.contains { $0.hasPrefix("write:whiteBalance:") })
        XCTAssertTrue(!panel.active || panel.errorResource == "remote_camera_tool_changed")
        await model.stopAndWait()
    }

    func testCameraToolWriteDrainsAfterMonitorExitWithoutLatePopup() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        await camera.acceptWrites(.whiteBalance)
        await camera.delayWrites(milliseconds: 180)
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.whiteBalance)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        panel.select(4)
        try await waitFor { await camera.log.contains("write:whiteBalance:4") }
        await model.stopAndWait()
        XCTAssertNil(model.cameraToolPanel)
        XCTAssertFalse(panel.busy)
        XCTAssertFalse(panel.active)
        let actual = await camera.current(.whiteBalance)
        XCTAssertEqual(actual, 4)
        let calls = await camera.log
        XCTAssertTrue(calls.contains("refresh:whiteBalance"))
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "refresh:whiteBalance")),
                          try XCTUnwrap(calls.firstIndex(of: "gate:false")))
    }

    func testCameraToolSelectionClosesOnlyAfterConfirmedReadback() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        await camera.acceptWrites(.whiteBalance)
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.whiteBalance)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        panel.select(99)
        XCTAssertFalse(panel.busy)
        panel.select(4)
        panel.select(2) // Busy admission ignores a second tap.
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.descriptor?.current, 4)
        XCTAssertTrue(panel.closeRequested)
        XCTAssertNil(panel.errorResource)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0.hasPrefix("write:whiteBalance:") }, ["write:whiteBalance:4"])
        await model.stopAndWait()
    }

    func testCameraToolFirstReadTimeoutDismissesButDrainsUncancelledTransaction() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.delayProperty(.whiteBalance, milliseconds: 180)
        var unavailable = 0
        var dismissed = 0
        let panel = RemoteCameraToolController(camera: camera, tool: .whiteBalance, movie: false,
            isCurrent: { true }, currentMovie: { false }, canWrite: { true }, beforeWrite: { true },
            onApplied: {}, onUnavailable: { unavailable += 1 }, onDismiss: { dismissed += 1 },
            readTimeout: .milliseconds(20))
        panel.start()
        try await waitFor { !panel.active }
        XCTAssertTrue(panel.loading)
        XCTAssertEqual(unavailable, 1)
        XCTAssertEqual(dismissed, 1)
        await panel.drain()
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:whiteBalance"])
        XCTAssertNil(panel.descriptor)
    }

    func testCameraToolFailedWriteRetainsActualValueAndAllowsRetry() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        let panel = RemoteCameraToolController(camera: camera, tool: .whiteBalance, movie: false,
            isCurrent: { true }, currentMovie: { false }, canWrite: { true }, beforeWrite: { true },
            onApplied: {}, onUnavailable: {}, onDismiss: {})
        panel.start()
        try await waitFor { !panel.loading }
        panel.select(4)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.descriptor?.current, 2)
        XCTAssertEqual(panel.errorResource, "remote_camera_tool_failed")
        XCTAssertFalse(panel.closeRequested)
        await camera.acceptWrites(.whiteBalance)
        panel.select(4)
        XCTAssertNil(panel.errorResource)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.descriptor?.current, 4)
        XCTAssertTrue(panel.closeRequested)
        panel.dismiss()
        await panel.drain()
    }

    func testCameraToolQueriesActualCandidatesAndPrefersWritableDomain() async throws {
        let camera = RemoteLifecycleCamera()
        let readOnly = RemotePropertyDescriptor(property: .focusArea, writable: false, current: 2, values: [2])
        let live = RemotePropertyDescriptor(property: .liveViewFocusArea, dataType: 2, writable: true, current: 1, values: [0, 1, 2])
        await camera.setProperty(readOnly)
        await camera.setProperty(live)
        let chosen = try await camera.remoteCameraTool(.focusArea, movie: false)
        XCTAssertEqual(chosen, live)
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:focusArea", "property:liveViewFocusArea"])
        await camera.markUnsupported(.liveViewFocusArea)
        let fallback = try await camera.remoteCameraTool(.focusArea, movie: false)
        XCTAssertEqual(fallback, readOnly)
    }

    func testFocusModeQueriesStandardThenVendorWithTypeValidation() async throws {
        let camera = RemoteLifecycleCamera()
        let locked = RemotePropertyDescriptor(property: .focusMode, dataType: 2, writable: false,
                                               current: 1, values: [1])
        let vendor = RemotePropertyDescriptor(property: .stillFocusMode, dataType: 2, writable: true,
                                              current: 0, values: [0, 1, 3, 4])
        await camera.setProperty(locked)
        await camera.setProperty(vendor)
        let chosen = try await camera.remoteCameraTool(.focusMode, movie: false)
        XCTAssertEqual(chosen, vendor)
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:focusMode", "property:stillFocusMode"])
    }

    func testFocusModeWriteRefreshesManualStateAndFixedVendorModeBlocksTapFocus() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .focusMode, dataType: 4, writable: true,
                                       current: 2, values: [1, 2]))
        await camera.acceptWrites(.focusMode)
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        XCTAssertFalse(model.state.focus.manual)
        model.openCameraTool(.focusMode)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        panel.select(1)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.descriptor?.current, 1)
        XCTAssertTrue(model.state.focus.manual)

        await camera.setProperty(.init(property: .stillFocusMode, dataType: 2, writable: false,
                                       current: 3, values: [3]))
        await camera.setProperty(.init(property: .focusMode, dataType: 4, writable: false,
                                       current: 99, values: []))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.focusMode.rawValue)])
        try await waitFor { model.state.focus.manual }
        model.focus(at: .init(x: 0.5, y: 0.5))
        XCTAssertEqual(model.interactionHint, AppLocalized.resource("remote_tap_focus_manual"))
    }

    func testStillFocusModeEventRefreshesManualState() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .stillFocusMode, dataType: 2, writable: true,
                                       current: 0, values: [0, 1, 3, 4]))
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        XCTAssertEqual(model.focusModeDescriptor?.property, .stillFocusMode)
        XCTAssertFalse(model.state.focus.manual)

        await camera.setProperty(.init(property: .stillFocusMode, dataType: 2, writable: true,
                                       current: 4, values: [0, 1, 3, 4]))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.stillFocusMode.rawValue)])
        try await waitFor { model.focusModeDescriptor?.current == 4 && model.state.focus.manual }
        XCTAssertTrue(model.state.focus.manual)
    }

    func testFocusModeWriteFailureStillRefreshesMode() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .focusMode, dataType: 4, writable: true,
                                       current: 2, values: [1, 2]))
        await camera.setWriteResponses(.focusMode, [0x2019, 0x2019, 0x2019])
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.focusMode)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        let beforeRefresh = await camera.log.filter { $0 == "focus" }.count
        panel.select(1)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.errorResource, "remote_camera_tool_failed")
        try await waitFor { await camera.log.filter { $0 == "focus" }.count > beforeRefresh }
        XCTAssertFalse(model.state.focus.manual)
    }

    func testCameraToolWriteBlocksFocusAndShutterCommands() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        await camera.acceptWrites(.whiteBalance)
        await camera.delayWrites(milliseconds: 300)
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.whiteBalance)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        panel.select(4)
        try await waitFor { model.cameraToolWriting }
        model.focus(at: .init(x: 0.5, y: 0.5))
        model.beginHalfPress()
        model.capture()
        XCTAssertEqual(model.state.capture, .idle)
        let duringWrite = await camera.log
        XCTAssertFalse(duringWrite.contains("tapfocus:start"))
        XCTAssertFalse(duringWrite.contains("halfpress:start"))
        XCTAssertFalse(duringWrite.contains("capture"))
        try await waitFor { !panel.busy }
    }

    func testMovieCameraToolNeverFallsBackToPhotoProperty() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.markUnsupported(.movieWhiteBalance)
        let alternative = RemotePropertyDescriptor(property: .movieWhiteBalanceAlternate, writable: true, current: 2, values: [2, 4])
        await camera.setProperty(alternative)
        let whiteBalance = try await camera.remoteCameraTool(.whiteBalance, movie: true)
        XCTAssertEqual(whiteBalance, alternative)
        await camera.markUnsupported(.movieFocusArea)
        let focus = try await camera.remoteCameraTool(.focusArea, movie: true)
        XCTAssertNil(focus)
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:movieWhiteBalance", "property:movieWhiteBalanceAlternate", "property:movieFocusArea"])
    }

    func testCameraToolUnsupportedResponseFallsBackButTransportFailureDoesNot() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.failProperty(.focusArea, error: .responseCode(0x200A))
        let fallback = try await camera.remoteCameraTool(.focusArea, movie: false)
        XCTAssertEqual(fallback?.property, .liveViewFocusArea)
        await camera.failProperty(.movieWhiteBalance, error: .timeout)
        do {
            _ = try await camera.remoteCameraTool(.whiteBalance, movie: true)
            XCTFail("Transport timeout must propagate")
        } catch PTPSessionError.timeout { }
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:focusArea", "property:liveViewFocusArea", "property:movieWhiteBalance"])
    }

    func testFirstWritableCameraToolStopsQueryAndUsesVerifiedWrite() async throws {
        let camera = RemoteLifecycleCamera()
        let descriptor = RemotePropertyDescriptor(property: .focusArea, dataType: 4, writable: true,
                                                   current: 0x8010, values: [0x8010, 0x8011])
        await camera.setProperty(descriptor)
        let queried = try await camera.remoteCameraTool(.focusArea, movie: false)
        let selected = try XCTUnwrap(queried)
        let reads = await camera.log
        XCTAssertEqual(reads, ["property:focusArea"])
        await camera.acceptWrites(.focusArea)
        let result = try await camera.setRemotePropertyVerified(selected, value: 0x8011)
        XCTAssertTrue(result.confirmed)
        XCTAssertEqual(result.actual?.current, 0x8011)
    }

    func testConcurrentTrialAndPageExitShareOneCleanup() async throws {
        let camera = RemoteLifecycleCamera()
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor { await camera.log.contains("frame") }
        async let trial: Void = model.stopAndWait()
        async let page: Void = model.stopAndWait()
        _ = await (trial, page)
        await model.stopAndWait()
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "gate:false" }.count, 1)
    }

    func testFreeLocalRecordingIsBlockedBeforeMicrophoneOrRecorder() {
        let camera = RemoteLifecycleCamera()
        let entitlements = PremiumEntitlementStore(access: PremiumAccess(.free))
        let model = RemoteViewModel(camera: camera, entitlements: entitlements)
        model.startLocalRecording()
        XCTAssertEqual(model.localRecordingPhase, .idle)
        XCTAssertEqual(model.localRecordingHint, AppLocalized.resource("remote_rec_pro_only"))
    }

    func testExpiryFinalizesPlayableRecordingBeforeExhaustedMonitorExits() async throws {
        try await verifyRecordingLoss(expiry: true)
    }

    func testHiddenRecordingToolBlocksAdmissionBeforeFrameOrPermission() {
        let model = RemoteViewModel(camera: RemoteLifecycleCamera(),
                                    entitlements: PremiumEntitlementStore(access: PremiumAccess(.lifetime)))
        model.setLocalRecordingToolVisible(false, fixedRecorder: true)
        model.startLocalRecording()
        XCTAssertEqual(model.localRecordingPhase, .idle)
        XCTAssertNil(model.localRecordingHint)
        model.setLocalRecordingToolVisible(true, fixedRecorder: false)
        model.startLocalRecording()
        XCTAssertEqual(model.localRecordingHint, AppLocalized.resource("remote_rec_start_failed"))
    }

    func testHiddenPortraitRecorderFinalizesButLandscapeFixedRecorderKeepsRecording() async throws {
        guard AVAudioSession.sharedInstance().recordPermission == .denied else {
            throw XCTSkip("Test simulator microphone permission must be denied")
        }
        let name = "RemoteHiddenRecording.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let model = RemoteViewModel(camera: RemoteLifecycleCamera(frameSize: CGSize(width: 64, height: 48)),
                                    recordingDirectory: directory,
                                    entitlements: PremiumEntitlementStore(access: PremiumAccess(.lifetime)),
                                    freeUsage: FreeUsageStore(defaults: defaults))
        addTeardownBlock {
            await model.stopAndWait()
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        model.start()
        try await waitFor { model.state.session == .ready && model.frameImage != nil }
        model.startLocalRecording()
        try await waitFor { model.localRecordingPhase == .recording }
        try await Task.sleep(for: .milliseconds(400))
        model.setLocalRecordingToolVisible(false, fixedRecorder: true)
        XCTAssertEqual(model.localRecordingPhase, .recording)
        model.toggleLocalRecordingPause()
        XCTAssertEqual(model.localRecordingPhase, .paused)
        model.setLocalRecordingToolVisible(false, fixedRecorder: false)
        XCTAssertEqual(model.localRecordingPhase, .finalizing)
        model.setLocalRecordingToolVisible(false, fixedRecorder: false)
        try await waitFor { model.localRecordingPhase == .saved }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        try await assertDecodableSilentRecording(XCTUnwrap(files.first))
        model.startLocalRecording()
        XCTAssertEqual(model.localRecordingPhase, .saved)
    }

    func testPausedRecordingFinalizesOnRevocationAndConcurrentPageExit() async throws {
        try await verifyRecordingLoss(expiry: false)
    }

    // Uses the real frame decoder, recorder, permission result and page cleanup.
    // Only camera packets and verified entitlement inputs are controlled; this
    // does not stand in for a real StoreKit refund or a physical camera test.
    private func verifyRecordingLoss(expiry: Bool) async throws {
        guard AVAudioSession.sharedInstance().recordPermission == .denied else {
            throw XCTSkip("Set the test simulator's com.ztransfer.ios microphone permission to denied with simctl privacy before running; no microphone capture is needed.")
        }
        let name = "RemoteRecordingLoss.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let usage = FreeUsageStore(defaults: defaults)
        if expiry { usage.consumeMonitoring(FreeUsageStore.monitoringLimit, isPro: false) }
        let entitlements = PremiumEntitlementStore(access: PremiumAccess(.lifetime))
        let camera = RemoteLifecycleCamera(frameSize: CGSize(width: 64, height: 48))
        let model = RemoteViewModel(camera: camera, recordingDirectory: directory,
                                   entitlements: entitlements, freeUsage: usage)
        addTeardownBlock {
            await model.stopAndWait()
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        model.start()
        try await waitFor { model.state.session == .ready && model.frameImage != nil }
        model.startLocalRecording()
        try await waitFor { model.localRecordingPhase == .recording }
        // Allow several real camera packets to pass through decode and encoding.
        try await Task.sleep(for: .milliseconds(400))
        if expiry {
            let until = Date().addingTimeInterval(0.15)
            entitlements.publish(.annual(until: until, gracePeriod: false))
            try await waitFor { model.trialEnded }
            XCTAssertEqual(entitlements.entitlement, .annual(until: until, gracePeriod: false),
                           "Known expiry must work without a second StoreKit publication")
        } else {
            model.toggleLocalRecordingPause()
            XCTAssertEqual(model.localRecordingPhase, .paused)
            entitlements.publish(.free)
            XCTAssertEqual(model.localRecordingPhase, .finalizing,
                           "Revocation must initiate saving before page exit")
            async let first: Void = model.stopAndWait()
            async let second: Void = model.stopAndWait()
            _ = await (first, second)
            XCTAssertFalse(model.trialEnded)
        }
        XCTAssertEqual(model.localRecordingPhase, .saved)
        XCTAssertFalse(model.usageMeter.isPro)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "gate:false" }.count, 1)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let recording = try XCTUnwrap(files.first)
        XCTAssertEqual(recording.pathExtension, "mp4")
        try await assertDecodableSilentRecording(recording)
        let attachment = XCTAttachment(data: try Data(contentsOf: recording),
                                       uniformTypeIdentifier: "public.mpeg-4")
        attachment.name = expiry ? "expired-recording.mp4" : "revoked-paused-recording.mp4"
        attachment.lifetime = .keepAlways
        add(attachment)
        model.startLocalRecording()
        XCTAssertEqual(model.localRecordingHint, AppLocalized.resource("remote_rec_pro_only"))
        XCTAssertNotEqual(model.localRecordingPhase, .recording)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

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

    func testFreshDualAxisHeaderSuspendsPropertyPollingAndStaleHeaderFallsBack() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setAttitudeFrame(roll: 12.5, pitch: -3.2)
        await camera.setProperty(.init(property: .angleLevel, dataType: 5, writable: false,
                                       current: 23_514_322, values: []))
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.frameMetadata?.attitude != nil }
        model.setLevelVisible(true)
        try await waitFor { model.levelPitch != nil }
        XCTAssertEqual(try XCTUnwrap(model.levelRoll), 12.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(model.levelPitch), -3.2, accuracy: 0.01)
        let headerCalls = await camera.log
        XCTAssertFalse(headerCalls.contains("property:angleLevel"))
        await camera.setAttitudeFrame(roll: 12.5, pitch: -3.2, age: 2)
        try await waitFor { model.levelPitch == nil && model.levelRoll != nil }
        XCTAssertEqual(try XCTUnwrap(model.levelRoll), -1.2, accuracy: 0.01)
        let fallbackCalls = await camera.log
        XCTAssertTrue(fallbackCalls.contains("property:angleLevel"))
    }

    func testDualAxisHeaderRecoversAfterPropertyDeclaredUnavailable() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.markUnsupported(.angleLevel)
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        model.setLevelVisible(true)
        try await waitFor { await camera.log.filter { $0 == "property:angleLevel" }.count == 3 }
        await camera.setAttitudeFrame(roll: 7.5, pitch: 2)
        try await waitFor { model.levelPitch == 2 }
        XCTAssertEqual(try XCTUnwrap(model.levelRoll), 7.5, accuracy: 0.01)
        XCTAssertTrue(model.levelVisible)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "property:angleLevel" }.count, 3)
        model.setLevelVisible(false)
        XCTAssertNil(model.levelRoll)
        XCTAssertNil(model.levelPitch)
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
        await camera.markUnsupported(.angleLevel)
        try await waitFor { model.levelRoll == nil }
        XCTAssertTrue(model.levelVisible)
        let stopped = await camera.log.filter { $0 == "refresh:angleLevel" }.count
        XCTAssertEqual(stopped, 1) // Failed refresh is followed by fresh descriptors.
        let descriptions = await camera.log.filter { $0 == "property:angleLevel" }.count
        XCTAssertEqual(descriptions, 3) // Initial success plus two failed re-describes.
        try await Task.sleep(for: .milliseconds(300))
        let after = await camera.log.filter { $0 == "refresh:angleLevel" }.count
        XCTAssertEqual(after, stopped)
        model.setLevelVisible(false)
        XCTAssertFalse(model.levelVisible)
    }

    func testUnsupportedLevelKeepsPreferenceAndStopsOnlyPropertyPolling() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.markUnsupported(.angleLevel)
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        model.setLevelVisible(true)
        try await waitFor { await camera.log.filter { $0 == "property:angleLevel" }.count == 3 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.levelVisible)
        XCTAssertNil(model.levelRoll)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "property:angleLevel" }.count, 3)
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
            model.interactionHint == AppLocalized.resource("remote_tap_focus_area_retry")
        }
        XCTAssertEqual(model.state.focus.phase, .failed)
    }

    func testMoveAreaFailureShowsAndroidAreaRetryHint() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.queueFocusResults([
            .init(trackingStarted: false, polls: 0, timedOut: false,
                  responseCode: 0x2019, moveResponseCode: 0x2019)
        ])
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.focus(at: .init(x: 0.5, y: 0.5))
        try await waitFor {
            model.interactionHint == AppLocalized.resource("remote_tap_focus_area_retry")
        }
        XCTAssertEqual(model.state.focus.phase, .failed)
    }

    func testZSeriesUnsupportedFocusAreaShowsAndroidGuidanceWithoutSendingAF() async throws {
        let camera = RemoteLifecycleCamera(model: "Z 30")
        await camera.setProperty(.init(property: .focusArea, dataType: 2, writable: true,
                                       current: 0x801C, values: [0x801C]))
        let area = try await camera.remoteCameraTool(.focusArea, movie: false)
        let modelName = await camera.remoteDeviceModel()
        XCTAssertEqual(modelName, "Z 30")
        XCTAssertEqual(area?.property, .focusArea)
        XCTAssertEqual(area?.current, 0x801C)
        XCTAssertEqual(rcTapFocusPath(area, model: modelName), .unsupported)
        let model = RemoteViewModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.focus(at: .init(x: 0.5, y: 0.5))
        try await waitFor {
            model.interactionHint == AppLocalized.resource("remote_tap_focus_area_unsupported")
        }
        XCTAssertEqual(model.state.focus.phase, .failed)
        let calls = await camera.log
        XCTAssertFalse(calls.contains("tapfocus:start"))
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

    func testUSBMoviePreparesExistingSessionAndReturnsToOrdinaryLiveViewAfterStop() async throws {
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

    func testLeavingDuringUSBMovieStartStopsLateCameraRecordingWithoutDisconnecting() async throws {
        let camera = RemoteLifecycleCamera(movie: true, isUSB: true)
        await camera.delayPreparedMovieStart(milliseconds: 250)
        let model = RemoteViewModel(camera: camera)
        model.start()
        try await waitFor(timeout: 5) { model.state.session == .ready }

        model.toggleRecording()
        try await waitFor { await camera.log.contains("movie:prepared") }
        await model.stopAndWait()

        let calls = await camera.log
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "movie:prepared")),
                          try XCTUnwrap(calls.firstIndex(of: "movie:end")))
        XCTAssertEqual(calls.last, "gate:false")
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
        await pipeline.setAnalysis(histogram: true, zebra: true, falseColor: true)
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
        XCTAssertEqual(frames.last?.histogram?.count, 256)
        XCTAssertNotNil(frames.last?.zebraMask)
        XCTAssertEqual(frames.last?.falseColorPixels?.count, 72 * 48)
        XCTAssertEqual(frames.last?.falseColorWidth, 72)
        XCTAssertEqual(frames.last?.falseColorHeight, 48)

        await pipeline.submit(request(5, generation: 1))
        while !(await pipeline.isDecoding), ContinuousClock.now < deadline + .seconds(1) {
            try await Task.sleep(for: .milliseconds(1))
        }
        await pipeline.reset(generation: 2)
        await pipeline.setAnalysis(histogram: false, zebra: false, falseColor: false)
        await pipeline.submit(request(6, generation: 2))
        await pipeline.waitUntilIdle()
        frames = await MainActor.run { collector.frames }
        XCTAssertEqual(frames.map(\.fps), [1, 4, 6])
        XCTAssertNil(frames.last?.histogram)
        XCTAssertNil(frames.last?.zebraMask)
        XCTAssertNil(frames.last?.falseColorPixels)
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
        try await assertDecodableSilentRecording(output)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Decode every frame: a nonempty MP4 alone does not prove its muxer was closed.
private func assertDecodableSilentRecording(_ url: URL,
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
    let asset = AVURLAsset(url: url)
    let playable = try await asset.load(.isPlayable)
    let duration = try await asset.load(.duration)
    XCTAssertTrue(playable, file: file, line: line)
    XCTAssertGreaterThan(duration.seconds, 0, file: file, line: line)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    XCTAssertEqual(videoTracks.count, 1, file: file, line: line)
    XCTAssertTrue(audioTracks.isEmpty, file: file, line: line)
    let track = try XCTUnwrap(videoTracks.first, file: file, line: line)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    reader.add(output)
    XCTAssertTrue(reader.startReading(), file: file, line: line)
    var frames = 0
    var previous = CMTime.invalid
    while let sample = output.copyNextSampleBuffer() {
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample), file: file, line: line)
        XCTAssertEqual(CVPixelBufferGetWidth(pixels), 64, file: file, line: line)
        XCTAssertEqual(CVPixelBufferGetHeight(pixels), 48, file: file, line: line)
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if previous.isValid { XCTAssertGreaterThan(time.seconds, previous.seconds, file: file, line: line) }
        previous = time
        frames += 1
    }
    XCTAssertNil(reader.error, file: file, line: line)
    XCTAssertEqual(reader.status, .completed, file: file, line: line)
    XCTAssertGreaterThan(frames, 1, file: file, line: line)
}

private actor RemoteLifecycleCamera: RemoteCameraControlling {
    nonisolated let isUSB: Bool
    private(set) var log: [String] = []
    private let movie: Bool
    private let model: String?
    private var failingFrames: Int
    private var transportFailure: Bool
    private var batteryEvent = false
    private var overrides: [RemoteProperty: RemotePropertyDescriptor] = [:]
    private var unsupported = Set<RemoteProperty>()
    private var propertyErrors: [RemoteProperty: PTPSessionError] = [:]
    private var propertyDelays: [RemoteProperty: Int] = [:]
    private var refreshFailures = Set<RemoteProperty>()
    private var queuedEvents: [STAEvent] = []
    private var captureFails = false
    private var acceptedWrites = Set<RemoteProperty>()
    private var writeResponses: [RemoteProperty: [UInt16]] = [:]
    private var writeDelay = 0
    private var focusDelay = 0
    private var focusResults: [RemoteFocusResult] = []
    private var trackingReleaseResponse: UInt16? = nil
    private var movieStarts: [RemoteMovieStartResult] = []
    private var preparedMovieStartDelay = 0
    private var remoteControlMode = false
    private var applicationMode = false
    private let frame: Data
    init(movie: Bool = false, failingFrames: Int = 0, isUSB: Bool = false,
         model: String? = nil,
         transportFailure: Bool = false, frameSize: CGSize = CGSize(width: 8, height: 8)) {
        self.movie = movie
        self.model = model
        self.failingFrames = failingFrames
        self.isUSB = isUSB
        self.transportFailure = transportFailure
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        self.frame = UIGraphicsImageRenderer(size: frameSize, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: frameSize))
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
        if let enhancedFrame {
            return .init(bytes: enhancedFrame, jpegOffset: 512, operation: PTPConstants.getLiveViewImageEx,
                         receivedAtUptime: ProcessInfo.processInfo.systemUptime - frameAge)
        }
        return .init(bytes: frame, jpegOffset: 0, operation: PTPConstants.getLiveViewImage)
    }
    private var enhancedFrame: Data?
    private var frameAge: TimeInterval = 0
    func setAttitudeFrame(roll: Float, pitch: Float, age: TimeInterval = 0) {
        var bytes = [UInt8](repeating: 0, count: 512)
        func put16(_ offset: Int, _ value: Int) {
            bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
        }
        func put32(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { bytes[offset+i] = UInt8(truncatingIfNeeded: value >> (24-i*8)) }
        }
        put16(0, 1); put32(8, 512); put32(12, UInt32(frame.count))
        put16(16, 2000); put16(18, 1200); put16(28, 200); put16(30, 120)
        put32(404, UInt32((roll < 0 ? roll + 360 : roll) * 65536))
        put32(408, UInt32((pitch < 0 ? pitch + 360 : pitch) * 65536))
        enhancedFrame = Data(bytes) + frame
        frameAge = age
    }
    func remoteDeviceModel() async -> String? { model }
    func remoteMovieMode() -> Bool? {
        log.append("selector")
        return overrides[.liveViewSelector].map { $0.current != 0 } ?? movie
    }
    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor? {
        log.append("property:\(property)")
        if let delay = propertyDelays[property] {
            do { try await Task.sleep(for: .milliseconds(delay)) }
            catch { log.append("cancelled-property:\(property)"); throw error }
        }
        if let error = propertyErrors[property] { throw error }
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
        if let standard = overrides[.focusMode],
           RemoteFocusMode.label(property: .focusMode, value: standard.current) != nil {
            return standard
        }
        if let still = overrides[.stillFocusMode],
           RemoteFocusMode.label(property: .stillFocusMode, value: still.current) != nil {
            return still
        }
        if let vendor = overrides[.nikonAFMode],
           RemoteFocusMode.label(property: .nikonAFMode, value: vendor.current) != nil {
            return vendor
        }
        return nil
    }
    func emitBatteryEvent() { batteryEvent = true }
    func setProperty(_ descriptor: RemotePropertyDescriptor) { overrides[descriptor.property] = descriptor }
    func delayProperty(_ property: RemoteProperty, milliseconds: Int) { propertyDelays[property] = milliseconds }
    func failProperty(_ property: RemoteProperty, error: PTPSessionError) { propertyErrors[property] = error }
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
    func delayPreparedMovieStart(milliseconds: Int) { preparedMovieStartDelay = milliseconds }
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
    private(set) var lastFocusCoordinates: [UInt32]?
    func focusAt(trackingX: UInt32, trackingY: UInt32, focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult {
        lastFocusCoordinates = [trackingX, trackingY, focusX, focusY]
        return try await finishFocus("tapfocus")
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
    func setTrackingReleaseResponse(_ response: UInt16?) { trackingReleaseResponse = response }
    func endSubjectTrackingForTool() -> UInt16? {
        log.append("end-tracking-tool")
        return trackingReleaseResponse
    }
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
    func startPreparedUSBMovieRecording() async -> RemoteMovieStartResult {
        log.append("movie:prepared")
        if preparedMovieStartDelay > 0 {
            try? await Task.sleep(for: .milliseconds(preparedMovieStartDelay))
        }
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

    func testExplicitMoveAreaPathSkipsTrackingProbeAndUsesFullFocusCoordinates() async throws {
        let wire = RemoteWireReplay([
            .init(0x9205, parameters: [901, 601]), .init(0x90C1), .init(0x90C8)
        ])
        let result = try await repository(wire).focusAt(trackingX: 100, trackingY: 200,
                                                         focusX: 901, focusY: 601,
                                                         tapPath: .moveArea)
        XCTAssertFalse(result.trackingStarted)
        XCTAssertEqual(result.moveResponseCode, PTPConstants.responseOK)
        XCTAssertEqual(result.afStartResponseCode, PTPConstants.responseOK)
        let operations = await wire.operations
        XCTAssertEqual(operations, [0x9205, 0x90C1, 0x90C8])
    }

    func testExplicitTrackingPathUsesTrackingCoordinatesAndDoesNotFallbackOnBusy() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [901, 601]), .init(0x90C1), .init(0x90C8)
        ])
        let result = try await repository(wire).focusAt(trackingX: 901, trackingY: 601,
                                                         focusX: 31, focusY: 21,
                                                         tapPath: .tracking)
        XCTAssertTrue(result.trackingStarted)
        XCTAssertEqual(result.trackingResponseCode, PTPConstants.responseOK)
        let operations = await wire.operations
        XCTAssertEqual(operations, [0x9424, 0x90C1, 0x90C8])

        let busy = RemoteWireReplay([.init(0x9424, parameters: [1, 2], code: 0x2019)])
        let failure = try await repository(busy).focusAt(trackingX: 1, trackingY: 2,
                                                          focusX: 3, focusY: 4,
                                                          tapPath: .tracking)
        XCTAssertEqual(failure.responseCode, 0x2019)
        let busyOperations = await busy.operations
        XCTAssertEqual(busyOperations, [0x9424])
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
