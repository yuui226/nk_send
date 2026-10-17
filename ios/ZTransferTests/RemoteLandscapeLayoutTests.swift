import XCTest
@testable import ZTransfer

final class RemoteLandscapeLayoutTests: XCTestCase {
    // Port of all seven LandscapeMonitorLayoutTest.kt cases; include the
    // desqueeze widths and small screens rather than only a phone screenshot.
    func testImageAndControlHitTargetsNeverOverlap() {
        for width: CGFloat in [320, 640, 800, 1024, 1366] {
            for height: CGFloat in [240, 360, 600, 800] {
                for aspect: CGFloat in [1.5, 16 / 9, 2.35, 3.56] {
                    let layout = RemoteLandscapeLayout(width: width, height: height, imageAspect: aspect)
                    XCTAssertEqual(layout.image.width / layout.image.height, aspect, accuracy: 0.0001)
                    for bounds in [layout.image, layout.controls] {
                        XCTAssertGreaterThanOrEqual(bounds.minX, 0)
                        XCTAssertGreaterThanOrEqual(bounds.minY, 0)
                        XCTAssertLessThanOrEqual(bounds.maxX, width + 0.001)
                        XCTAssertLessThanOrEqual(bounds.maxY, height + 0.001)
                    }
                    XCTAssertTrue(layout.bottomControls ? layout.controls.minY >= layout.image.maxY + 7.99
                                  : layout.controls.minX >= layout.image.maxX + 7.99)
                    XCTAssertGreaterThanOrEqual(layout.controls.width, 116)
                }
            }
        }
    }

    func testTallNarrowRailKeepsFourWheelsAndRecorderOutsideImage() {
        let layout = RemoteLandscapeLayout(width: 860, height: 500, imageAspect: 1.5)
        XCTAssertEqual(layout.columns, 1)
        XCTAssertEqual(layout.controls.width, 116, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(layout.controls.height - 36 - 8 - layout.footerHeight, 4 * 46 + 3 * 2)
    }

    func testVideoUsesOneColumnWithoutReservingAnother() {
        let layout = RemoteLandscapeLayout(width: 640, height: 360, imageAspect: 16 / 9)
        XCTAssertFalse(layout.bottomControls)
        XCTAssertEqual(layout.columns, 1)
        XCTAssertEqual(layout.image.width, 508, accuracy: 0.001)
        XCTAssertEqual(layout.controls.width, 116, accuracy: 0.001)
        XCTAssertTrue((42...46).contains(layout.parameterHeight))
        XCTAssertLessThanOrEqual(4 * layout.parameterHeight + 6, layout.controls.height - 36 - 8 - layout.footerHeight)
    }

    func testSquareScreenRetainsFullWidthVideo() {
        let layout = RemoteLandscapeLayout(width: 800, height: 800, imageAspect: 16 / 9)
        XCTAssertTrue(layout.bottomControls)
        XCTAssertEqual(layout.image.width, 792, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(layout.controls.height, 40 + max(96, layout.footerHeight))
        XCTAssertGreaterThanOrEqual((layout.controls.width - 96 - layout.shutterSize - 16 - 6) / 2, 80)
    }

    func testDesqueezeMovesControlsBelowImage() {
        XCTAssertFalse(RemoteLandscapeLayout(width: 800, height: 400, imageAspect: 16 / 9).bottomControls)
        let wide = RemoteLandscapeLayout(width: 800, height: 400, imageAspect: 16 / 9 * 2)
        XCTAssertTrue(wide.bottomControls)
        XCTAssertEqual(wide.image.width, 792, accuracy: 0.001)
        XCTAssertEqual(wide.image.width / wide.image.height, 16 / 9 * 2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(wide.controls.height, 40 + max(96, wide.footerHeight))
        XCTAssertGreaterThanOrEqual(wide.controls.minY, wide.image.maxY + 7.99)
    }

    func testNaturalSideSpaceRetainsFullHeightPhoto() {
        let layout = RemoteLandscapeLayout(width: 1000, height: 400, imageAspect: 1.5)
        XCTAssertFalse(layout.bottomControls)
        XCTAssertEqual(layout.image.height, 392, accuracy: 0.001)
    }

    func testCaptureFooterLeavesRecorderAndDispHitTargetsClear() {
        for height: CGFloat in [240, 360, 500, 800] {
            let layout = RemoteLandscapeLayout(width: 640, height: height, imageAspect: 16 / 9)
            XCTAssertGreaterThanOrEqual(layout.footerHeight - layout.shutterSize, 40)
            XCTAssertGreaterThanOrEqual(layout.controls.width - layout.shutterSize, 48)
        }
    }

    func testDockDisablesOutgoingControlsImmediatelyAndNeverOverlapsLayers() {
        var state = RemoteDockMotion()
        XCTAssertTrue(state.acceptsInput(dock: false))
        state.setOpen(true)
        XCTAssertFalse(state.acceptsInput(dock: false))
        XCTAssertFalse(state.acceptsInput(dock: true))
        state.advance(0)
        for ms in 1...280 {
            state.advance(Int64(ms) * 1_000_000)
            XCTAssertTrue(state.visibility(dock: true) == 0 || state.visibility(dock: false) == 0)
            XCTAssertFalse(state.acceptsInput(dock: false))
        }
        XCTAssertEqual(state.progress, 1)
        XCTAssertTrue(state.acceptsInput(dock: true))
        XCTAssertFalse(state.animation.isRunning)
    }

    func testDockReversalRetainsCurrentFrameAndUsesTheFullTweenDuration() {
        var state = RemoteDockMotion()
        state.setOpen(true)
        state.advance(0)
        state.advance(170_000_000)
        let progress = state.progress
        XCTAssertGreaterThan(progress, 0)
        state.setOpen(false)
        XCTAssertEqual(state.progress, progress)
        XCTAssertFalse(state.acceptsInput(dock: true))
        state.advance(310_000_000)
        let expected = ZTransferAndroidMotion.tween(milliseconds: 280)
            .sample(at: 140_000_000, from: progress, to: -1, velocity: 0).value
        XCTAssertEqual(state.progress, expected, accuracy: 0.00001)
        state.advance(450_000_000)
        XCTAssertEqual(state.progress, -1)
        XCTAssertTrue(state.acceptsInput(dock: false))
    }

    @MainActor func testDockMeasuresEnglishWordsAndCJKBeforeReveal() {
        let english = ["Computer control", "White balance", "Focus area", "De-squeeze", "Histogram"]
        let narrow = RemoteDockMeasurements(names: english, width: 108, bottom: false)
        XCTAssertEqual(narrow.columns, 1)
        let rail = RemoteDockMeasurements(names: english, width: 220, bottom: false)
        XCTAssertGreaterThan(rail.columns, 1)
        XCTAssertLessThanOrEqual(rail.columns, 3)
        let bottom = RemoteDockMeasurements(names: english, width: 784, bottom: true)
        XCTAssertEqual(bottom.columns, english.count)
        let chinese = RemoteDockMeasurements(names: ["完全控制", "白平衡", "自动对焦区域", "水平仪"], width: 176, bottom: false)
        XCTAssertEqual(chinese.columns, 2)
        XCTAssertTrue(chinese.lines.allSatisfy { (1...2).contains($0) })
        XCTAssertEqual(chinese.rowLines(1), chinese.lines.suffix(2).max())
    }
}

extension RemoteLandscapeLayoutTests {
    func testMeterStackUsesAndroidAdaptiveHeightAndScopeLane() {
        for height: CGFloat in [100, 160, 240, 400] {
            for landscape in [false, true] {
                for exposure in [false, true] {
                    let size = CGSize(width: height * 1.5, height: height)
                    let layout = RemoteMonitorMeterLayout(size: size, landscape: landscape,
                        movie: true, showExposure: exposure, audioEnabled: true)
                    XCTAssertEqual(layout.exposureTop, 34)
                    XCTAssertEqual(layout.scopeStartInset, landscape ? 8 : 48)
                    XCTAssertGreaterThanOrEqual(layout.audio.height, 0)
                    XCTAssertLessThanOrEqual(layout.audio.height, 72)
                    XCTAssertLessThanOrEqual(layout.audio.maxY, height)
                    if landscape && layout.audio.height > 0 {
                        XCTAssertGreaterThanOrEqual(layout.audio.minY, 34 + (exposure ? 126 : 0))
                        XCTAssertEqual(layout.audio.maxX, size.width - 8)
                    } else if !landscape {
                        XCTAssertLessThan(layout.audio.maxX, layout.scopeStartInset)
                        XCTAssertEqual(layout.audio.maxY, height - 8)
                    }
                }
            }
        }
        let disabled = RemoteMonitorMeterLayout(size: CGSize(width: 360, height: 240),
            landscape: false, movie: false, showExposure: true, audioEnabled: false)
        XCTAssertEqual(disabled.audio.height, 0)
        XCTAssertEqual(disabled.exposureTop, 10)
        XCTAssertEqual(disabled.scopeStartInset, 8)
    }
}
