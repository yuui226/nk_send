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

    func testPCPreferenceSurvivesRecreationAndHidingClearsOnlyPreference() {
        withDefaults { defaults in
            let first = RemoteToolPreferences(defaults: defaults)
            XCTAssertFalse(first.computerControl)
            first.computerControl = true
            let restored = RemoteToolPreferences(defaults: defaults)
            XCTAssertTrue(restored.computerControl)
            restored.layout(movie: false).setVisible(.computerControl, false)
            XCTAssertFalse(restored.computerControl)
            XCTAssertFalse(RemoteToolPreferences(defaults: defaults).computerControl)
        }
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
            XCTAssertTrue(photo.visible(.lock))
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
            XCTAssertTrue(movie.visible(.lock))
        }
    }

    func testPinnedLockIgnoresOldHiddenAndOrderValues() {
        withDefaults { defaults in
            defaults.set(["lock"], forKey: "remote_hidden_tools_photo")
            defaults.set("lock,grid,hd", forKey: "remote_tool_order_photo")
            let layout = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in XCTFail() })
            let original = layout.order
            layout.move(.lock, to: 0)
            layout.setVisible(.lock, false)
            XCTAssertEqual(layout.order, original)
            XCTAssertTrue(layout.visible(.lock)); XCTAssertFalse(layout.order.contains(.lock))
            XCTAssertFalse(layout.hidden.contains("lock"))
            XCTAssertEqual(monitorToolRows([.hd, .fps, .lock, .rotate], columns: 3).first!, [.hd, .lock, .rotate])
            XCTAssertEqual(monitorToolRows([.lock, .rotate], columns: 1).first!, [.lock, .rotate])
        }
    }

    func testPictureControlPlacementMigratesOnlyOncePerMode() {
        withDefaults { defaults in
            let layout = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in })
            XCTAssertEqual(layout.shownTools[5], .pictureControl)
            layout.setVisible(.pictureControl, false)
            let restored = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in })
            XCTAssertFalse(restored.visible(.pictureControl))
            XCTAssertTrue(RemoteToolLayout(defaults: defaults, movie: true, onHide: { _ in }).visible(.pictureControl))
        }
    }

    func testRetiredRecorderIDIsIgnoredWithoutResettingEitherModesLayout() {
        withDefaults { defaults in
            for mode in ["photo", "movie"] {
                defaults.set(true, forKey: "remote_picture_control_placement_v1_\(mode)")
                defaults.set("record,fps,grid,unknown,hd,record,lut,lock,rotate", forKey: "remote_tool_order_\(mode)")
                defaults.set(["record", "grid", "unknown", "lock"], forKey: "remote_hidden_tools_\(mode)")
                let layout = RemoteToolLayout(defaults: defaults, movie: mode == "movie", onHide: { _ in })
                XCTAssertEqual(Array(layout.order.prefix(4)), [.fps, .grid, .hd, .lut])
                XCTAssertEqual(layout.hidden, ["grid"])
                XCTAssertEqual(layout.hiddenTools, [.grid])
                XCTAssertEqual(RemoteTool.allCases.count, 19)
                layout.move(.lut, to: 0)
                let restored = RemoteToolLayout(defaults: defaults, movie: mode == "movie", onHide: { _ in })
                XCTAssertEqual(restored.order.first, .lut); XCTAssertFalse(restored.visible(.grid))
                XCTAssertFalse((defaults.string(forKey: "remote_tool_order_\(mode)") ?? "").contains("record"))
            }
        }
    }

    func testComputerControlIsAnIndependentPersistedToolInBothModes() {
        withDefaults { defaults in
            let photo = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in })
            let movie = RemoteToolLayout(defaults: defaults, movie: true, onHide: { _ in })
            XCTAssertTrue(photo.visible(.computerControl))
            XCTAssertTrue(movie.visible(.computerControl))
            photo.setVisible(.computerControl, false)
            XCTAssertFalse(photo.visible(.computerControl))
            XCTAssertTrue(movie.visible(.computerControl))
            XCTAssertFalse(RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in }).visible(.computerControl))
            XCTAssertTrue(RemoteToolLayout(defaults: defaults, movie: true, onHide: { _ in }).visible(.computerControl))
        }
    }
}
