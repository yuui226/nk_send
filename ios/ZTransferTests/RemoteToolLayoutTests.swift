import XCTest
@testable import ZTransfer

@MainActor
final class RemoteToolLayoutTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "remote-tool-layout-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    func testAndroidDefaultOrderNormalizesStoredIDsAndPhotoExcludesAudio() {
        withDefaults { defaults in
            defaults.set("grid,unknown,rotate,grid,hd", forKey: "remote_tool_order_photo")
            let photo = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in })
            XCTAssertEqual(Array(photo.order.prefix(2)), [.grid, .hd])
            XCTAssertEqual(Set(photo.order).count, photo.order.count)
            XCTAssertFalse(photo.order.contains(.audio))
            XCTAssertFalse(photo.order.contains(.rotate))
            XCTAssertTrue(photo.visible(.rotate))
            XCTAssertTrue(photo.lockStartsSecondRow)
        }
    }

    func testHideRestoreTailAndRepeatedHideDisableCallback() {
        withDefaults { defaults in
            var disabled: [RemoteTool] = []
            let layout = RemoteToolLayout(defaults: defaults, movie: false) { disabled.append($0) }
            layout.setVisible(.grid, false)
            layout.setVisible(.grid, false)
            XCTAssertEqual(disabled, [.grid, .grid])
            XCTAssertEqual(layout.order.last, .grid)
            layout.setVisible(.hd, false)
            layout.setVisible(.grid, true)
            XCTAssertEqual(layout.shownTools.last, .grid)
            XCTAssertEqual(layout.hiddenTools, [.hd])
            XCTAssertEqual(layout.order.last, .hd)
            let restored = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in })
            XCTAssertEqual(restored.order, layout.order)
            XCTAssertEqual(restored.hiddenTools, [.hd])
        }
    }

    func testHiddenAndFixedToolsCannotMoveAndModesPersistIndependently() {
        withDefaults { defaults in
            let photo = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in })
            let movie = RemoteToolLayout(defaults: defaults, movie: true, onHide: { _ in })
            photo.setVisible(.hd, false)
            let order = photo.order
            photo.move(.hd, to: 0)
            photo.move(.rotate, to: 0)
            photo.setVisible(.rotate, false)
            photo.setVisible(.audio, false)
            XCTAssertEqual(photo.order, order)
            XCTAssertTrue(photo.visible(.rotate))
            XCTAssertTrue(movie.visible(.hd))
            XCTAssertTrue(movie.visible(.audio))
            XCTAssertTrue(movie.lockStartsSecondRow)
        }
    }

    func testLockDetachesFromSecondRowAndRestoreDoesNotReattach() {
        withDefaults { defaults in
            let layout = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in })
            var visual = layout.shownTools.filter { $0 != .lock }
            visual.insert(.lock, at: 4)
            layout.move(.lock, to: 0, displayedOrder: visual)
            XCTAssertEqual(layout.shownTools.first, .lock)
            XCTAssertFalse(layout.lockStartsSecondRow)
            layout.setVisible(.lock, false)
            layout.setVisible(.lock, true)
            XCTAssertEqual(layout.shownTools.last, .lock)
            XCTAssertFalse(layout.lockStartsSecondRow)
            XCTAssertFalse(RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in }).lockStartsSecondRow)
        }
    }

    func testLandscapeRetainsHiddenRecorderControlsWithoutRestoringPreference() {
        withDefaults { defaults in
            let layout = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in })
            layout.setVisible(.record, false)
            layout.setVisible(.grid, false)
            XCTAssertFalse(layout.presentedTools(fixedRecorder: false).contains(.record))
            XCTAssertTrue(layout.presentedTools(fixedRecorder: true).contains(.record))
            XCTAssertFalse(layout.presentedTools(fixedRecorder: true).contains(.grid))
            XCTAssertFalse(layout.visible(.record))
            XCTAssertEqual(layout.hiddenTools, [.record, .grid])
        }
    }
}
