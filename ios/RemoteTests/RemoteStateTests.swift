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
}
