import XCTest
import SwiftUI
@testable import ZTransfer

@MainActor
final class PhotoEffectCompactWheelLayoutTests: XCTestCase {
    func testExpandedParametersRenderAt34AndMainRowsAt50() throws {
        for sizing in [PhotoEffectControlMetrics.parameterWheel, PhotoEffectControlMetrics.lutParameterWheel] {
            let wheel = DetentWheel(label: "参数", options: [20, 40, 60, 80, 100], selected: 80,
                optionLabel: { "\($0)%" }, onCommit: { _ in }, sizing: sizing)
            let image = try XCTUnwrap(ImageRenderer(content: wheel.frame(width: 160)).uiImage)
            XCTAssertEqual(image.size.height, 34)
            XCTAssertEqual(image.size.width, 160)
            XCTAssertEqual(wheel.rowHeight, sizing.rowHeight)
            XCTAssertEqual(wheel.optionFontSize, sizing.fontSize)
        }
        let main = DetentWheel(label: "滤镜", options: ["无滤镜"], selected: "无滤镜",
            optionLabel: { $0 }, onCommit: { _ in })
        XCTAssertEqual(try XCTUnwrap(ImageRenderer(content: main.frame(width: 160)).uiImage).size.height, 50)
    }

    func testCompactWheelsKeepHeightInWeightedWatermarkRow() throws {
        let row = PhotoEffectParameterRow(weights: [0.42, 0.29, 0.29]) {
            DetentWheel(label: "位置", options: ["照片底部居中"], selected: "照片底部居中",
                optionLabel: { $0 }, onCommit: { _ in }, sizing: PhotoEffectControlMetrics.parameterWheel)
            DetentWheel(label: "大小", options: [40, 60, 80], selected: 60,
                optionLabel: { "\($0)%" }, onCommit: { _ in }, sizing: PhotoEffectControlMetrics.parameterWheel)
            DetentWheel(label: "透明度", options: [60, 80, 100], selected: 80,
                optionLabel: { "\($0)%" }, onCommit: { _ in }, sizing: PhotoEffectControlMetrics.parameterWheel)
        }
        let image = try XCTUnwrap(ImageRenderer(content: row.frame(width: 320).environment(\.colorScheme, .light)).uiImage)
        XCTAssertEqual(image.size.height, 34)
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ztransfer-compact-wheels.png")
        try XCTUnwrap(image.pngData()).write(to: path)
        print("VISUAL_FIXTURE: \(path.path)")
    }
}

@MainActor
final class PhotoLUTEditorStateTests: XCTestCase {
    func testBothEntrypointsRetainAcceptedLUTWhenCandidateOrReplacementFails() async throws {
        for role: PhotoLUTStore.Role in [.camera, .local] {
            let fixture = try Fixture(role: role)
            defer { fixture.clean() }
            let editor = fixture.editor
            var draft = PhotoEffectsSettings()
            let disable = { disablePhotoLUTDraft(&draft, lutStore: editor.store) }
            editor.scanFolder(fixture.folder, onDisable: disable)
            try await settle(editor)
            let file = try XCTUnwrap(editor.files.first { $0.name == "A.cube" })
            editor.choose(file.identifier, onDisable: disable) { draft.selectedFilter = $0; draft.photoFilterEnabled = true }
            try await settle(editor)
            let accepted = try XCTUnwrap(draft.selectedFilter)
            // A module may be hidden while its outgoing view is still retained
            // by the 240ms transition. A finished candidate must not revive it.
            var moduleVisible = true
            let otherFile = try XCTUnwrap(editor.files.first { $0.name == "C.cube" })
            editor.choose(otherFile.identifier, onDisable: disable, shouldAccept: { moduleVisible }) { _ in
                XCTFail("Hidden module was reactivated")
            }
            moduleVisible = false
            try await settle(editor)
            XCTAssertEqual(editor.store.selectedIdentifier, file.identifier)
            let bookmark = editor.store.folderBookmark
            let files = editor.files
            let bad = try XCTUnwrap(files.first { $0.name == "Bad.cube" })
            editor.choose(bad.identifier, onDisable: disable) { _ in XCTFail("Invalid table was accepted") }
            try await settle(editor)
            XCTAssertEqual(editor.notice?.resource, "lut_invalid")
            XCTAssertNil(editor.folderFailure)
            XCTAssertEqual(draft.selectedFilter, accepted)
            XCTAssertEqual(editor.store.selectedIdentifier, file.identifier)
            editor.scanFolder(fixture.root.appendingPathComponent("missing"), onDisable: disable)
            try await settle(editor)
            XCTAssertNotNil(editor.notice)
            XCTAssertNil(editor.folderFailure)
            XCTAssertEqual(editor.store.folderBookmark, bookmark)
            XCTAssertEqual(editor.files, files)
            XCTAssertEqual(editor.store.restoreSelection(), accepted)
            XCTAssertEqual(draft.selectedFilter, accepted)
        }
    }

    func testSuccessfulRescanClearsMissingSelectionButKeepsOtherRole() async throws {
        let fixture = try Fixture(role: .local)
        defer { fixture.clean() }
        let editor = fixture.editor
        let other = PhotoLUTStore(role: .camera, defaults: fixture.defaults, directory: fixture.root.appendingPathComponent("snapshots"))
        other.select("other-role")
        var draft = PhotoEffectsSettings()
        let disable = { disablePhotoLUTDraft(&draft, lutStore: editor.store) }
        editor.scanFolder(fixture.folder, onDisable: disable)
        try await settle(editor)
        let file = try XCTUnwrap(editor.files.first { $0.name == "A.cube" })
        editor.choose(file.identifier, onDisable: disable) { draft.selectedFilter = $0; draft.photoFilterEnabled = true }
        try await settle(editor)
        try FileManager.default.removeItem(at: fixture.folder.appendingPathComponent("A.cube"))
        editor.refresh(onDisable: disable)
        try await settle(editor)
        XCTAssertNil(editor.store.selectedIdentifier)
        XCTAssertFalse(draft.photoFilterEnabled)
        XCTAssertEqual(other.selectedIdentifier, "other-role")
        XCTAssertEqual(PhotoColorEffectEditorVisibility(settings: draft, isPro: true),
                       PhotoColorEffectEditorVisibility(settings: PhotoEffectsSettings(), isPro: true))
    }

    func testFavoritesUseStableCatalogOrderAndAreSharedAcrossRoles() async throws {
        let fixture = try Fixture(role: .local)
        defer { fixture.clean() }
        let editor = fixture.editor
        editor.scanFolder(fixture.folder) {}
        try await settle(editor)
        let a = try XCTUnwrap(editor.files.first { $0.name == "A.cube" })
        let c = try XCTUnwrap(editor.files.first { $0.name == "C.cube" })
        let other = PhotoLUTStore(role: .camera, defaults: fixture.defaults)
        other.toggleFavorite(c.identifier)
        editor.store.toggleFavorite(a.identifier)
        XCTAssertEqual(editor.orderedFiles.prefix(2).map(\.identifier), [a.identifier, c.identifier])
        XCTAssertEqual(other.favorites, editor.store.favorites)
        editor.store.toggleFavorite(a.identifier)
        XCTAssertEqual(editor.orderedFiles.first?.identifier, c.identifier)
    }

    func testReopeningRefreshesSameRoleWithoutCopyingOtherRole() throws {
        let fixture = try Fixture(role: .camera)
        defer { fixture.clean() }
        let editor = fixture.editor
        let otherPresenter = PhotoLUTStore(role: .camera, defaults: fixture.defaults)
        otherPresenter.select("new-camera")
        otherPresenter.setIntensity(62)
        PhotoLUTStore(role: .local, defaults: fixture.defaults).select("local-only")
        editor.settingsExpanded = true
        editor.showingChooser = true
        editor.resetForPresentation()
        XCTAssertEqual(editor.store.selectedIdentifier, "new-camera")
        XCTAssertEqual(editor.store.intensityPercent, 62)
        XCTAssertFalse(editor.settingsExpanded)
        XCTAssertFalse(editor.showingChooser)
        XCTAssertNil(editor.notice)
    }

    func testCloseAndOffInvalidateQueuedSelectionForBothEntrypoints() async throws {
        for role: PhotoLUTStore.Role in [.camera, .local] {
            for turnOff in [false, true] {
                let queue = LUTIOQueue()
                let fixture = try Fixture(role: role, queue: queue)
                defer { fixture.clean() }
                let editor = fixture.editor
                var draft = PhotoEffectsSettings()
                let disable = { disablePhotoLUTDraft(&draft, lutStore: editor.store) }
                editor.scanFolder(fixture.folder, onDisable: disable)
                try await settle(editor)
                let a = try XCTUnwrap(editor.files.first { $0.name == "A.cube" })
                let c = try XCTUnwrap(editor.files.first { $0.name == "C.cube" })
                editor.choose(a.identifier, onDisable: disable) { draft.selectedFilter = $0; draft.photoFilterEnabled = true }
                try await settle(editor)
                let release = DispatchSemaphore(value: 0)
                defer { release.signal() }
                queue.submit(action: { _ in release.wait(); return true }, deliver: { _ in })
                editor.choose(c.identifier, onDisable: disable) { _ in XCTFail("Closed editor accepted a late selection") }
                XCTAssertTrue(editor.loadingSelection)
                if turnOff { editor.off(onDisable: disable) } else { editor.close() }
                var drained = false
                queue.submit(action: { _ in true }, deliver: { _ in drained = true })
                release.signal()
                for _ in 0..<300 {
                    if drained { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(drained)
                XCTAssertFalse(editor.loading)
                XCTAssertEqual(editor.store.selectedIdentifier, turnOff ? nil : a.identifier)
                XCTAssertEqual(draft.photoFilterEnabled, !turnOff)
            }
        }
    }

    func testChooserHeightIsBoundedAndEmptyCatalogDoesNotReserveAFullSheet() {
        XCTAssertEqual(PhotoEffectChooserMetrics.listHeight(categoryLabels: [], optionLabels: [], width: 300, viewportHeight: 800), 0)
        let small = PhotoEffectChooserMetrics.listHeight(categoryLabels: ["未分类"], optionLabels: ["Kodak"], width: 300, viewportHeight: 800)
        XCTAssertGreaterThan(small, 30)
        XCTAssertLessThan(small, 60)
        let large = PhotoEffectChooserMetrics.listHeight(categoryLabels: ["A"], optionLabels: Array(repeating: "Long two line LUT name", count: 100), width: 300, viewportHeight: 800)
        XCTAssertEqual(large, 382)
        XCTAssertLessThanOrEqual(PhotoEffectChooserMetrics.listHeight(categoryLabels: ["A"], optionLabels: ["B"], width: 240, viewportHeight: 180), 62)
    }

    private func settle(_ editor: PhotoLUTEditorState) async throws {
        for _ in 0..<300 {
            if !editor.loading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("LUT operation did not settle")
        editor.close()
    }

    @MainActor private struct Fixture {
        let root: URL
        let folder: URL
        let suite: String
        let defaults: UserDefaults
        let editor: PhotoLUTEditorState
        init(role: PhotoLUTStore.Role, queue: LUTIOQueue = LUTIOQueue()) throws {
            suite = "lut-editor-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            folder = root.appendingPathComponent("catalog")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = "LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)
            for name in ["A.cube", "C.cube"] { try Data(source.utf8).write(to: folder.appendingPathComponent(name)) }
            try Data("LUT_3D_SIZE 2\n0 0 0\n".utf8).write(to: folder.appendingPathComponent("Bad.cube"))
            editor = PhotoLUTEditorState(role: role, defaults: defaults, directory: root.appendingPathComponent("snapshots"), request: LUTRequestController(queue: queue))
        }
        func clean() {
            editor.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
