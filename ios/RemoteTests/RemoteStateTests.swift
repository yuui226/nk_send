import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferRemote
#else
@testable import ZTransfer
#endif

final class RemoteStateTests: XCTestCase {
    func testStartReadyAndFirstFrameTransitions() {
        var state = RemoteState()
        state = state.applying(.startRequested)
        XCTAssertEqual(state.session, .starting)
        XCTAssertFalse(state.liveViewStable)
        state = state.applying(.deviceReady)
        XCTAssertEqual(state.session, .warmingUp)
        state = state.applying(.frameReceived(fps: 29.5))
        XCTAssertEqual(state.session, .ready)
        XCTAssertTrue(state.liveViewStable)
        XCTAssertEqual(state.frameSequence, 1)
        XCTAssertEqual(state.fps, 29.5, accuracy: 0.001)
    }

    func testFrameLossRecoversAndDisconnectResets() {
        var state = RemoteState().applying(.startRequested)
        state = state.applying(.frameReceived(fps: 30))
        state = state.applying(.frameLost)
        XCTAssertEqual(state.session, .recovering)
        XCTAssertFalse(state.liveViewStable)
        state = state.applying(.disconnected)
        XCTAssertEqual(state, RemoteState())
    }

    func testPhotoAndMovieCaptureUseDistinctStates() {
        var photo = RemoteState().applying(.startRequested)
        photo = photo.applying(.captureRequested)
        XCTAssertEqual(photo.capture, .capturing)
        photo = photo.applying(.captureConfirmed)
        XCTAssertEqual(photo.capture, .idle)

        var movie = RemoteState()
        movie.movieMode = true
        movie = movie.applying(.captureRequested)
        XCTAssertEqual(movie.capture, .idle)
        movie = movie.applying(.recordingStarted)
        XCTAssertEqual(movie.capture, .recording)
        movie = movie.applying(.recordingStopped)
        XCTAssertEqual(movie.capture, .idle)
    }

    func testLiveViewParserStripsNikonPrefixAndSuffix() {
        let payload = Data([0x01, 0x02, 0xFF, 0xD8, 0x11, 0x22, 0xFF, 0xD9, 0x03])
        XCTAssertEqual(RemoteFrameParser.jpegData(from: payload),
                       Data([0xFF, 0xD8, 0x11, 0x22, 0xFF, 0xD9]))
        XCTAssertNil(RemoteFrameParser.jpegData(from: Data([0xFF, 0xD8, 0x01])))
        XCTAssertNil(RemoteFrameParser.jpegData(from: Data([0x01, 0x02, 0x03, 0x04])))
    }

    func testFocusPointAndTransitionsMatchAndroidFeedbackStates() {
        let point = RemoteFocusPoint(x: 1.4, y: -0.2)
        XCTAssertEqual(point, RemoteFocusPoint(x: 1, y: 0))
        var state = RemoteState().applying(.startRequested)
        state = state.applying(.frameReceived(fps: 30))
        state = state.applying(.focusRequested(point))
        XCTAssertEqual(state.focus.phase, .focusing)
        XCTAssertEqual(state.focus.point, RemoteFocusPoint(x: 1, y: 0))
        state.focus.tracking = true
        state = state.applying(.focusLocked)
        XCTAssertEqual(state.focus.phase, .locked)
        state = state.applying(.trackingEnded)
        XCTAssertEqual(state.focus.phase, .idle)
        XCTAssertFalse(state.focus.tracking)
    }

    func testAndroidDisplayInformationHeaderParsesFocusFrameAndSoundLevels() throws {
        var payload = [UInt8](repeating: 0, count: 512 + 4)
        put16(&payload, 0, 1); put16(&payload, 2, 0)
        put32(&payload, 8, 512); put32(&payload, 12, 4)
        put16(&payload, 16, 1000); put16(&payload, 18, 800)
        put16(&payload, 28, 500); put16(&payload, 30, 400)
        payload[42] = 2; payload[44] = 1; payload[45] = 0
        put16(&payload, 48, 200); put16(&payload, 50, 160)
        put16(&payload, 52, 500); put16(&payload, 54, 400)
        payload[388..<392] = [14, 12, 9, 7]
        payload[512..<516] = [0xFF, 0xD8, 0xFF, 0xD9]

        let metadata = try XCTUnwrap(RemoteFrameParser.metadata(
            from: Data(payload), jpegOffset: 512, operation: PTPConstants.getLiveViewImageEx
        ))
        XCTAssertEqual(metadata.focusJudgement, .focused)
        let frame = try XCTUnwrap(metadata.selectedFocusFrame)
        XCTAssertEqual(frame.centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(frame.centerY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(frame.width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(metadata.soundLevels, RemoteLiveViewSoundLevels(
            peakLeft: 14, peakRight: 12, currentLeft: 9, currentRight: 7
        ))
    }

    func testUnknownHeaderAndOutOfRangeSoundLevelsAreRejected() {
        var payload = [UInt8](repeating: 0, count: 512 + 4)
        put16(&payload, 0, 1); put32(&payload, 8, 512); put32(&payload, 12, 4)
        put16(&payload, 16, 1000); put16(&payload, 18, 800)
        payload[42] = 2; payload[44] = 1; payload[45] = 0
        put16(&payload, 48, 200); put16(&payload, 50, 160)
        put16(&payload, 52, 500); put16(&payload, 54, 400)
        payload[388] = 15
        payload[512..<516] = [0xFF, 0xD8, 0xFF, 0xD9]
        let metadata = RemoteFrameParser.metadata(
            from: Data(payload), jpegOffset: 512, operation: PTPConstants.getLiveViewImageEx
        )
        XCTAssertNotNil(metadata)
        XCTAssertNil(metadata?.soundLevels)
        XCTAssertNil(RemoteFrameParser.metadata(
            from: Data(payload), jpegOffset: 512, operation: PTPConstants.getLiveViewImage
        ))
    }

    private func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    private func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
}
