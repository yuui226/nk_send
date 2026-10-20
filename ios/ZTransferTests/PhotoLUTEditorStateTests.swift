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
    func testProductionEffectsWindowCommitsLUTAndNP3MemoryTogetherOnDismissal() async throws {
        let fixture = try Fixture(role: .camera)
        defer { fixture.clean() }
        let editor = fixture.editor
        let effects = PhotoEffectsStore(defaults: fixture.defaults, lutStore: editor.store)
        let state = SettingsState()
        state.draft = effects.beginDraft()
        state.draft.selectFilter(try XCTUnwrap(PhotoFilterCatalog.presets.dropFirst(3).first).id)
        let np3 = state.draft.selectedFilter
        let directory = DirectoryAccessStore(defaults: fixture.defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: SettingsHarness(state: state, editor: editor,
            effects: effects, directory: directory))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        editor.scanFolder(fixture.folder) {}
        try await settle(editor)
        let file = try XCTUnwrap(editor.files.first { $0.name == "A.cube" })
        editor.choose(file.identifier, onDisable: {}) {
            state.draft.selectedFilter = $0
            state.draft.photoFilterEnabled = true
        }
        try await settle(editor)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(fixture.defaults.dictionary(forKey: "photo_lut_selected_recipe"))
        let chosen = state.draft.selectedFilter
        state.closing = true
        for _ in 0..<100 {
            if fixture.defaults.string(forKey: "photo_lut_selected") == file.identifier { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(effects.settings.selectedFilter, chosen)
        XCTAssertEqual(effects.settings.rememberedBuiltinFilter, np3)
        let coldLUT = PhotoLUTStore(defaults: fixture.defaults, directory: editor.store.snapshotDirectory)
        XCTAssertEqual(coldLUT.restoreSelection(), chosen)
        let coldEffects = PhotoEffectsStore(defaults: fixture.defaults, lutStore: coldLUT)
        XCTAssertEqual(coldEffects.settings.selectedFilter, chosen)
        XCTAssertEqual(coldEffects.settings.rememberedBuiltinFilter, np3)
    }

    func testFolderPickerCancellationRefreshesButAccessFailurePreservesRecipeAndReportsDenied() async throws {
        for role: PhotoLUTStore.Role in [.camera, .local] {
            let fixture = try Fixture(role: role)
            defer { fixture.clean() }
            let editor = fixture.editor
            editor.scanFolder(fixture.folder) {}
            try await settle(editor)
            let file = try XCTUnwrap(editor.files.first { $0.name == "A.cube" })
            editor.choose(file.identifier, onDisable: {}) { _ in }
            try await settle(editor)
            let selection = editor.store.restoreSelection()
            editor.openFolder()
            editor.folderPickerCompleted(.failure(CocoaError(.userCancelled))) { XCTFail("Cancel disabled LUT") }
            try await settle(editor)
            XCTAssertFalse(editor.showingFolder)
            XCTAssertNil(editor.notice)
            XCTAssertEqual(editor.store.restoreSelection(), selection)
            editor.openFolder()
            editor.folderPickerCompleted(.failure(CocoaError(.fileReadNoPermission))) { XCTFail("Picker failure disabled LUT") }
            XCTAssertFalse(editor.showingFolder)
            XCTAssertEqual(editor.notice?.resource, "lut_folder_denied")
            XCTAssertFalse(editor.loading)
            XCTAssertEqual(editor.store.restoreSelection(), selection)
            XCTAssertEqual(editor.currentIdentifier, file.identifier)
        }
    }

    func testMissingPrivateSnapshotDoesNotExposeInactiveLUTControlsAndCanBeReselected() async throws {
        for role: PhotoLUTStore.Role in [.camera, .local] {
            let fixture = try Fixture(role: role)
            defer { fixture.clean() }
            let editor = fixture.editor
            editor.scanFolder(fixture.folder) {}
            try await settle(editor)
            let file = try XCTUnwrap(editor.files.first { $0.name == "A.cube" })
            editor.choose(file.identifier, onDisable: {}) { _ in }
            try await settle(editor)
            editor.store.commitDraft()
            let selection = try XCTUnwrap(editor.store.restoreSelection())
            try FileManager.default.removeItem(at: try XCTUnwrap(selection.snapshotOwner?.url))
            editor.resetForPresentation()
            XCTAssertNil(editor.store.restoreSelection())
            XCTAssertFalse(editor.active, "Source URI alone is not an active LUT recipe")
            XCTAssertEqual(editor.selectionOptions, [nil])
            editor.refresh(onDisable: {})
            try await settle(editor)
            editor.choose(file.identifier, onDisable: {}) { _ in }
            try await settle(editor)
            XCTAssertTrue(editor.active)
            XCTAssertNotNil(editor.store.restoreSelection())
        }
    }

    func testTransferLUTSelectionRemainsDraftWhileWorkbenchSavesImmediately() async throws {
        for role: PhotoLUTStore.Role in [.camera, .local] {
            let fixture = try Fixture(role: role)
            defer { fixture.clean() }
            let editor = fixture.editor
            editor.scanFolder(fixture.folder) {}
            try await settle(editor)
            let file = try XCTUnwrap(editor.files.first { $0.name == "A.cube" })
            editor.choose(file.identifier, onDisable: {}) { _ in }
            try await settle(editor)
            XCTAssertNotNil(editor.store.restoreSelection())
            let saved = PhotoLUTStore(role: role, defaults: fixture.defaults,
                directory: fixture.root.appendingPathComponent("snapshots"))
            XCTAssertEqual(saved.selectedIdentifier, role == .camera ? nil : file.identifier)
            XCTAssertEqual(saved.restoreSelection() == nil, role == .camera)
            editor.store.commitDraft()
            XCTAssertEqual(saved.restoreSelection(), editor.store.restoreSelection())
            editor.store.setIntensity(58)
            editor.store.setAdjustments(.init(highlights: -25, shadows: 35))
            if role == .camera {
                XCTAssertNotEqual(saved.restoreSelection(), editor.store.restoreSelection())
            } else {
                XCTAssertEqual(saved.restoreSelection(), editor.store.restoreSelection())
            }
            editor.store.commitDraft()
            XCTAssertEqual(saved.restoreSelection(), editor.store.restoreSelection())
            editor.resetForPresentation()
            XCTAssertEqual(editor.store.intensityPercent, 58)
            XCTAssertEqual(editor.store.adjustments, .init(highlights: -25, shadows: 35))
        }
    }

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

    func testCatalogIndexSurvivesRecipeLoadingAndSameScanButInvalidatesChangedFilesAndFavorites() async throws {
        let fixture = try Fixture(role: .camera)
        defer { fixture.clean() }
        let editor = fixture.editor
        editor.scanFolder(fixture.folder) {}
        try await settle(editor)
        let original = editor.catalog
        let a = try XCTUnwrap(editor.files.first { $0.name == "A.cube" })
        let c = try XCTUnwrap(editor.files.first { $0.name == "C.cube" })
        for index in 0..<120 {
            editor.store.setIntensity(index)
            editor.settingsExpanded.toggle()
            _ = editor.selectionOptions
            _ = editor.catalog.labels(uncategorized: "未分类")
            XCTAssertTrue(editor.catalog === original)
        }
        editor.choose(a.identifier, onDisable: {}) { _ in }
        XCTAssertTrue(editor.catalog === original)
        try await settle(editor)
        XCTAssertTrue(editor.catalog === original)
        editor.refresh(onDisable: {})
        try await settle(editor)
        XCTAssertTrue(editor.catalog === original, "Unchanged rescan must reuse the same index")

        let otherRole = PhotoLUTStore(role: .local, defaults: fixture.defaults)
        otherRole.toggleFavorite(c.identifier)
        let reordered = editor.catalog
        XCTAssertFalse(reordered === original)
        XCTAssertEqual(reordered.orderedFiles.first?.identifier, c.identifier)
        XCTAssertEqual(reordered.labels(uncategorized: "未分类"), original.labels(uncategorized: "未分类"))
        XCTAssertEqual(editor.store.selectedIdentifier, a.identifier)
        // An unrelated role/suite notification must not invalidate this catalog.
        otherRole.setIntensity(22)
        XCTAssertTrue(editor.catalog === reordered)

        try Data().write(to: fixture.folder.appendingPathComponent("new.cube"))
        editor.refresh(onDisable: {})
        try await settle(editor)
        XCTAssertFalse(editor.catalog === reordered)
        XCTAssertEqual(editor.catalog.filesByIdentifier.count, 4)
        try FileManager.default.removeItem(at: fixture.folder.appendingPathComponent("new.cube"))
        editor.refresh(onDisable: {})
        try await settle(editor)
        XCTAssertEqual(editor.catalog.filesByIdentifier.count, 3)
        editor.store.commitDraft()
        editor.resetForPresentation()
        XCTAssertTrue(editor.catalog.orderedFiles.isEmpty)
        XCTAssertEqual(editor.selectionOptions, [nil, a.identifier])
    }

    private final class SettingsState: ObservableObject {
        @Published var draft = PhotoEffectsSettings()
        @Published var closing = false
        @Published var chooser = PhotoFilterChooserState()
        @Published var hint: PhotoEffectsHint?
    }
    private struct SettingsHarness: View {
        @ObservedObject var state: SettingsState
        let editor: PhotoLUTEditorState
        let effects: PhotoEffectsStore
        let directory: DirectoryAccessStore
        var body: some View {
            SettingsView(showPhotoEffectsEntry: true, effectsStore: effects, directory: directory,
                effectsDraft: $state.draft, filterChooser: $state.chooser, effectsHint: $state.hint,
                dismissalRequested: state.closing, photoLUTEditor: editor, effectsOnly: true)
        }
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

@MainActor
final class PhotoEffectChooserPerformanceTests: XCTestCase {
    func testBoundedHeightMatchesUnboundedLayoutAndLargeCatalogNeedsNoTextMeasurement() {
        let labels = ["", "Kodak", "未分类", "A very long LUT title that wraps across two lines",
                      "电影胶片模拟——夏日的暖色与柔和光影", "Line 1\nLine 2\nLine 3"]
        let font = UIFont.systemFont(ofSize: 14, weight: .medium)
        func reference(_ labels: [String], width: CGFloat, category: Bool) -> CGFloat {
            labels.reduce(CGFloat(max(0, labels.count - 1)) * 2) { height, label in
                let text = (label as NSString).boundingRect(
                    with: CGSize(width: max(1, width - (category ? 16 : 20)), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
                return height + ceil(min(font.lineHeight * 2, max(font.lineHeight, text))) + (category ? 20 : 16)
            }
        }
        for width: CGFloat in [90, 160, 240, 300] {
            for viewport: CGFloat in [180, 320, 800] {
                for count in [0, 1, 3, 7, 12] {
                    let options = (0..<count).map { labels[$0 % labels.count] }
                    let categories = Array(options.reversed().prefix(4))
                    let expected = min(max(0, min(max(viewport - 120, 120), 440) - 58),
                        max(reference(categories, width: (width - 6) * 0.36, category: true),
                            reference(options, width: (width - 6) * 0.64, category: false)))
                    var measurements = 0
                    let actual = PhotoEffectChooserMetrics.listHeight(categoryLabels: categories,
                        optionLabels: options, width: width, viewportHeight: viewport) { label, width, font in
                        measurements += 1
                        return PhotoEffectChooserMetrics.measureText(label, width: width, font: font)
                    }
                    XCTAssertEqual(actual, expected)
                    XCTAssertLessThanOrEqual(measurements, 20)
                }
            }
        }
        let many = Array(repeating: labels[3], count: 10_000)
        for category in [false, true] {
            var measurements = 0
            let height = PhotoEffectChooserMetrics.listHeight(categoryLabels: category ? many : ["A"],
                optionLabels: category ? ["A"] : many, width: 300, viewportHeight: 800) { _, _, _ in
                measurements += 1; return 34
            }
            XCTAssertEqual(height, 382)
            XCTAssertEqual(measurements, 0)
        }
    }

    func testIndexedCatalogPreservesDuplicateNamesCategoryIdentityAndRestoredSelection() {
        let files = [
            RemoteLUTFile(identifier: "root", name: "Film.cube", relativePath: "Film.cube", size: 1),
            RemoteLUTFile(identifier: "a", name: "Film.cube", relativePath: "A/Film.cube", size: 2),
            RemoteLUTFile(identifier: "a2", name: "film.CUBE", relativePath: "A/film.CUBE", size: 3),
            RemoteLUTFile(identifier: "same-label", name: "Solo.cube", relativePath: "未分类/Solo.cube", size: 4)
        ]
        let index = PresetCatalogIndex(files: files, orderedFiles: [files[2], files[0], files[1], files[3]])
        XCTAssertEqual(index.categories, [nil, "A", "未分类"])
        XCTAssertEqual(index.filesByCategory["A"]?.map(\.identifier), ["a2", "a"])
        XCTAssertEqual(index.filesByCategory[nil]?.map(\.identifier), ["root"])
        XCTAssertEqual(index.labelsByCategory["A"], ["film", "Film"])
        XCTAssertEqual(index.labels(uncategorized: "未分类")["root"], "Film · 未分类")
        XCTAssertEqual(index.labels(uncategorized: "未分类")["a2"], "film · A · 3")
        XCTAssertEqual(index.labels(uncategorized: "Uncategorized")["root"], "Film · Uncategorized")
        XCTAssertEqual(index.labels(uncategorized: "Uncategorized")["same-label"], "Solo")
        let base = index.selectionOptions(current: "a")
        XCTAssertEqual(base, [nil, "a2", "root", "a", "same-label"])
        let restored = index.selectionOptions(current: "private-only")
        XCTAssertEqual(restored, base + ["private-only"])
        for _ in 0..<120 {
            let repeated = index.selectionOptions(current: "private-only")
            restored.withUnsafeBufferPointer { first in
                repeated.withUnsafeBufferPointer { second in
                    XCTAssertEqual(first.baseAddress, second.baseAddress, "Reuse storage on unrelated UI updates")
                }
            }
        }
        XCTAssertEqual(index.selectionOptions(current: nil), base)
        XCTAssertEqual(index.selectionOptions(current: "root"), base)
    }

    func testLazyProductionListPositionsDistantSelectionRetainsScrollAndResetsOnCategory() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = ListState()
        let probe = ListProbe()
        let host = UIHostingController(rootView: ListHarness(state: state, probe: probe))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 420)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(findScroll(host.view) as? UITableView)
        XCTAssertTrue(scroll.indexPathsForVisibleRows?.contains(IndexPath(row: 2_500, section: 0)) == true)
        XCTAssertEqual(scroll.rectForRow(at: IndexPath(row: 2_500, section: 0)).minY - scroll.contentOffset.y, 0, accuracy: 1)
        XCTAssertLessThan(probe.built.count, 200, "Do not build thousands of offscreen rows")
        XCTAssertGreaterThan(scroll.contentOffset.y, 1_000)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 90), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        let userTop = try XCTUnwrap(scroll.indexPathsForVisibleRows?.min())
        let userTopY = scroll.rectForRow(at: userTop).minY - scroll.contentOffset.y
        state.revision += 1
        try await Task.sleep(for: .milliseconds(150))
        // UITableView refines estimated heights above the visible window, so
        // absolute contentOffset may change while the same pixels stay still.
        XCTAssertEqual(scroll.indexPathsForVisibleRows?.min(), userTop)
        XCTAssertEqual(scroll.rectForRow(at: userTop).minY - scroll.contentOffset.y, userTopY, accuracy: 1,
            "Refresh must retain the visible item and its exact screen position")
        state.prepend = true
        try await Task.sleep(for: .milliseconds(150))
        let shifted = IndexPath(row: userTop.row + 10, section: 0)
        XCTAssertEqual(scroll.indexPathsForVisibleRows?.min(), shifted)
        XCTAssertEqual(scroll.rectForRow(at: shifted).minY - scroll.contentOffset.y, userTopY, accuracy: 1,
            "New catalog rows above the viewport must retain the old item by ID")
        print("CHOOSER_ROWS: distant-selection-and-refresh built=\(probe.built.count) catalog=3000")
        probe.built.removeAll()
        state.category = 1
        try await Task.sleep(for: .milliseconds(300))
        let nextScroll = try XCTUnwrap(findScroll(host.view) as? UITableView)
        XCTAssertEqual(nextScroll.rectForRow(at: IndexPath(row: 5, section: 0)).minY - nextScroll.contentOffset.y, 0, accuracy: 1)
        XCTAssertLessThan(probe.built.count, 200)
    }

    func testNativeRowsKeepSwiftUIHeightAndPixelsInBothColumns() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let labels = ["Kodak", "电影胶片模拟——夏日的暖色与柔和光影", "Third"]
        for category in [false, true] {
            let width: CGFloat = category ? 106 : 188
            func row(_ index: Int) -> PhotoEffectChooserRow {
                PhotoEffectChooserRow(label: labels[index], selected: index == 1,
                    favorite: index == 2, category: category) {}
            }
            let list = PhotoEffectChooserList(items: Array(labels.indices), id: \.self, row: row)
                .frame(width: width, height: 200).environment(\.colorScheme, .light)
            let host = UIHostingController(rootView: list)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 420)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let table = try XCTUnwrap(findScroll(host.view) as? UITableView)
            for index in labels.indices {
                let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: index, section: 0)))
                let reference = ImageRenderer(content: row(index).padding(.bottom, index < 2 ? 2 : 0)
                    .frame(width: width).environment(\.colorScheme, .light))
                reference.scale = 3
                let expected = try XCTUnwrap(reference.uiImage)
                XCTAssertEqual(cell.bounds.height, expected.size.height, accuracy: 1 / 3)
                let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
                format.preferredRange = .standard
                let actual = UIGraphicsImageRenderer(size: expected.size, format: format).image { _ in
                    cell.contentView.drawHierarchy(in: CGRect(origin: .zero, size: expected.size), afterScreenUpdates: true)
                }
                if index == 1 {
                    try XCTUnwrap(actual.pngData()).write(to: URL(fileURLWithPath: "/tmp/ztransfer-p15-row-\(category)-live.png"))
                    try XCTUnwrap(expected.pngData()).write(to: URL(fileURLWithPath: "/tmp/ztransfer-p15-row-\(category)-reference.png"))
                }
                let lhs = try rgba(actual), rhs = try rgba(expected)
                XCTAssertEqual(lhs.count, rhs.count)
                XCTAssertGreaterThan(lhs.filter { $0 != 0 }.count, 100)
                let total = zip(lhs, rhs).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                print("CHOOSER_PIXELS: category=\(category) index=\(index) mean=\(Double(total) / Double(lhs.count))")
                XCTAssertLessThan(Double(total) / Double(lhs.count), 3, "Native hosting must preserve row pixels, category=\(category) index=\(index)")
            }
        }
    }

    private func rgba(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return bytes
    }

    private func findScroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll($0) }.first
    }
    private final class ListState: ObservableObject {
        @Published var category = 0
        @Published var revision = 0
        @Published var prepend = false
    }
    private final class ListProbe {
        var built = Set<Int>()
    }
    private struct ListHarness: View {
        @ObservedObject var state: ListState
        let probe: ListProbe
        var body: some View {
            let selected = state.category == 0 ? 2_500 : 10_005
            PhotoEffectChooserList(items: state.category == 0 ?
                (state.prepend ? Array(-10..<0) : []) + Array(0..<3_000) : Array(10_000..<10_500),
                id: \.self, initialID: selected) { id in
                ListRow(id: id, selected: id == selected, revision: state.revision, probe: probe)
            }
            .id(state.category)
            .frame(width: 188, height: 382)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private struct ListRow: View {
        let id: Int
        let selected: Bool
        let revision: Int
        let probe: ListProbe
        var body: some View {
            let _ = probe.built.insert(id)
            PhotoEffectChooserRow(label: id.isMultiple(of: 3) ? "Long LUT title wrapping onto two lines \(id)" : "LUT \(id)",
                selected: selected, favorite: revision > 0) {}
        }
    }
}

@MainActor
final class PhotoEffectsParameterInvalidationTests: XCTestCase {
    func testIdleCancelAndEqualLUTPreferencesPublishNothingButChangedValuesStillPublish() throws {
        let suite = "effects-parameter-idle-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let editor = PhotoLUTEditorState(role: .camera, defaults: defaults)
        var notifications = 0
        let subscription = editor.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel(); editor.close() }
        for _ in 0..<120 {
            editor.cancelPending()
            editor.store.select(nil)
            editor.store.setIntensity(80)
            editor.store.setAdjustments(.init())
            editor.store.reloadRole()
        }
        XCTAssertEqual(notifications, 0)
        editor.store.setIntensity(62)
        XCTAssertEqual(notifications, 1)
        editor.store.select("private-snapshot")
        XCTAssertEqual(notifications, 2)
        XCTAssertNil(defaults.string(forKey: "photo_lut_selected"))
        editor.store.commitDraft()
        XCTAssertEqual(defaults.string(forKey: "photo_lut_selected"), "private-snapshot")
        editor.store.select(nil)
        XCTAssertEqual(notifications, 3)
        editor.store.commitDraft()
        XCTAssertNil(defaults.string(forKey: "photo_lut_selected"))
    }

    func testEqualNormalizedEffectsDoNotPublishButStillPersistFirstSaveAndExplicitRewrite() throws {
        for scope: PhotoEffectsStore.Scope in [.cameraTransfer, .localPhotos] {
            let suite = "effects-parameter-persist-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = PhotoEffectsStore(defaults: defaults, scope: scope, premiumAccess: PremiumAccess(.lifetime))
            let key = scope == .cameraTransfer ? "photoEffectsSettings.v1" : "localPhotoEffectsSettings.v1"
            store.update(store.settings)
            let stable = store.settings
            XCTAssertNotNil(defaults.data(forKey: key))
            var notifications = 0
            let subscription = store.objectWillChange.sink { notifications += 1 }
            defer { subscription.cancel() }
            for _ in 0..<120 {
                store.updateFromEditor(stable)
                store.setEnabled(store.isEnabled)
            }
            XCTAssertEqual(notifications, 0)
            defaults.removeObject(forKey: key)
            store.update(stable)
            XCTAssertNotNil(defaults.data(forKey: key), "Equal UI state must not skip an explicit persistence boundary")
            XCTAssertEqual(notifications, 0)
            var next = stable
            next.watermark.text = "New watermark"
            store.updateFromEditor(next)
            XCTAssertEqual(notifications, 1)
            XCTAssertEqual(store.settings.watermark.text, "New watermark")
            let restored = PhotoEffectsStore(defaults: defaults, scope: scope, premiumAccess: PremiumAccess(.lifetime))
            XCTAssertEqual(restored.settings.watermark.text, "New watermark")
        }
    }

    func testProductionLifetimeKeepsPageStableWhileControlsChooserAndNoticesUpdate() async throws {
        let suite = "effects-parameter-scope-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let editor = PhotoLUTEditorState(role: .camera, defaults: defaults)
        let probe = Probe()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: Page(editor: editor, probe: probe))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 420)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; editor.close() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let rootBodies = probe.rootBodies, leafBodies = probe.leafBodies
        for value in 0..<120 { editor.store.setIntensity(value) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.rootBodies, rootBodies)
        XCTAssertGreaterThan(probe.leafBodies, leafBodies)
        XCTAssertEqual(probe.displayedIntensity, editor.store.intensityPercent)
        editor.showingChooser = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.rootBodies, rootBodies)
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 2_000, "Chooser content must still render")
        editor.showingChooser = false
        editor.scanFolder(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) {}
        for _ in 0..<100 {
            if !editor.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(editor.loading)
        XCTAssertEqual(probe.notices.count, 1)
        XCTAssertEqual(probe.notices.last, editor.notice?.resource)
        XCTAssertEqual(probe.rootBodies, rootBodies)
    }

    private final class Probe {
        var rootBodies = 0
        var leafBodies = 0
        var displayedIntensity = 0
        var notices: [String] = []
    }
    private struct Page: View {
        @StateObject private var lifetime: PhotoLUTEditorLifetime
        @State private var draft = PhotoEffectsSettings()
        let probe: Probe
        init(editor: PhotoLUTEditorState, probe: Probe) {
            _lifetime = StateObject(wrappedValue: PhotoLUTEditorLifetime(editor))
            self.probe = probe
        }
        var body: some View {
            let _ = { probe.rootBodies += 1 }()
            ZStack {
                Status(editor: lifetime.editor, probe: probe)
                PhotoLUTChooserPresentation(editor: lifetime.editor, draft: $draft)
            }
            .onReceive(lifetime.editor.$notice.dropFirst()) { notice in
                if let notice { probe.notices.append(notice.resource) }
            }
        }
    }
    private struct Status: View {
        @ObservedObject var editor: PhotoLUTEditorState
        let probe: Probe
        var body: some View {
            let _ = { probe.leafBodies += 1; probe.displayedIntensity = editor.store.intensityPercent }()
            Text("\(editor.store.intensityPercent)")
        }
    }
}
