import SwiftUI
import XCTest
@testable import ZTransfer

@MainActor
final class PhotoFilterEditorSessionTests: XCTestCase {
    private final class Provider: @unchecked Sendable {
        let lock = NSLock()
        var files: [PresetFile] = []
        var parsed: ParsedPhotoNp3!
        var scans = 0
        var reads = 0
        var gate: DispatchSemaphore?
        var source: PhotoNp3Source {
            .init(scan: { [self] input, _ in
                let files = lock.withLock { scans += 1; return self.files }
                return .init(bookmark: Data([1]), files: files, root: input.folder)
            }, read: { [self] _, _, _ in
                let (gate, recipe) = lock.withLock { reads += 1; return (self.gate, parsed!) }
                if let gate { _ = gate.wait(timeout: .now() + 4) }
                return recipe
            })
        }
        var count: Int { lock.withLock { scans } }
        var readCount: Int { lock.withLock { reads } }
    }
    @MainActor private final class Fixture: ObservableObject {
        let suite = "NP3Session-" + UUID().uuidString
        let defaults: UserDefaults
        let store: PhotoNp3Store
        let provider = Provider()
        let session: PhotoFilterEditorSession
        let effects: PhotoEffectsStore
        let role: PhotoNp3Store.Role
        let root = URL(fileURLWithPath: "/np3-session/", isDirectory: true)
        @Published var draft = PhotoEffectsSettings()
        @Published var closing = false
        @Published var hint: PhotoEffectsHint?
        var explicitChanges = 0
        init(_ role: PhotoNp3Store.Role = .transfer, folder: Bool = true) throws {
            self.role = role
            defaults = UserDefaults(suiteName: suite)!
            store = PhotoNp3Store(defaults: defaults)
            if folder { store.replaceFolder(root, bookmark: Data([1])) }
            let recipe = try photoNp3SnapshotFixture("F:0")
            let hash = String(repeating: "b", count: 64)
            provider.parsed = .init(sourceSha256: hash,
                recipe: .init(preset: .init(id: "np3:\(hash):np3-srgb-v1", name: "Embedded"), parameters: recipe.parameters),
                ignoredDetailControls: false)
            provider.files = [.init(identifier: root.appendingPathComponent("Actual.np3").absoluteString,
                name: "Actual.np3", relativePath: "Actual.np3", size: 392)]
            effects = PhotoEffectsStore(defaults: defaults, scope: role == .transfer ? .cameraTransfer : .localPhotos, np3Store: store)
            draft = effects.beginDraft()
            session = .init(store: store, role: role, source: provider.source)
        }
        var binding: Binding<PhotoEffectsSettings> {
            Binding(get: { [unowned self] in draft }, set: { [unowned self] in
                draft = $0
                if role == .local { effects.updateFromEditor($0) }
                else { effects.persistEditorPreferences(from: $0) }
            })
        }
        func begin(active: Bool = true) { session.begin(draft: binding, active: active) { [weak self] in self?.explicitChanges += 1 } }
        func choose() { session.choose(.document(provider.files[0], presetID: nil)) }
        func clean() { provider.gate?.signal(); session.end(); defaults.removePersistentDomain(forName: suite) }
    }
    private func settle(_ session: PhotoFilterEditorSession) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while session.editor.loading {
            guard ContinuousClock.now < deadline else { XCTFail("NP3 request did not settle"); return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func testBothRolesCarryNewSourceToTheirCorrectCommitBoundary() async throws {
        for role in [PhotoNp3Store.Role.transfer, .local] {
            let f = try Fixture(role); defer { f.clean() }
            f.begin(); try await settle(f.session); f.choose(); try await settle(f.session)
            XCTAssertEqual(f.draft.selectedFilter?.preset.id, f.provider.parsed.recipe.preset.id)
            XCTAssertEqual(f.session.source(for: f.draft), f.provider.files[0].identifier)
            XCTAssertEqual(f.explicitChanges, 1)
            if role == .transfer {
                XCTAssertNil(f.store.restore(.transfer))
                XCTAssertTrue(f.effects.commitFromEditor(f.draft, np3Source: f.session.source(for: f.draft)))
            }
            XCTAssertEqual(f.store.restore(role)?.preset.id, f.provider.parsed.recipe.preset.id)
            XCTAssertEqual(f.store.source(role), f.provider.files[0].identifier)
            f.session.disable()
            XCTAssertFalse(f.draft.photoFilterEnabled)
            XCTAssertNotNil(f.draft.builtinFilterSelection)
            f.session.end()
            XCTAssertEqual(f.store.source(role), f.provider.files[0].identifier)
        }
    }

    func testFolderHintCancellationAndNativePickerResumeDoNotScan() async throws {
        let f = try Fixture(folder: false); defer { f.clean() }
        f.begin(); f.session.openChooser(); f.session.requestFolder()
        XCTAssertTrue(f.session.showingFolderHint)
        XCTAssertTrue(f.session.showingChooser)
        f.session.launchFolderPicker()
        XCTAssertTrue(f.session.showingFolder)
        XCTAssertFalse(f.session.showingChooser)
        f.session.setSceneActive(false)
        f.session.folderPickerCompleted(.failure(CocoaError(.userCancelled)), lifetimeID: f.session.lifetimeID)
        f.session.setSceneActive(true)
        XCTAssertNil(f.store.folder); XCTAssertEqual(f.provider.count, 0); XCTAssertNil(f.session.notice)
        f.session.folderPickerCompleted(.success([]), lifetimeID: f.session.lifetimeID)
        XCTAssertEqual(f.provider.count, 0)
        f.session.folderPickerCompleted(.failure(CocoaError(.fileReadNoPermission)), lifetimeID: f.session.lifetimeID)
        XCTAssertEqual(f.session.notice?.resource, "lut_folder_denied")
        f.session.folderPickerCompleted(.success([f.root]), lifetimeID: f.session.lifetimeID)
        try await settle(f.session)
        XCTAssertEqual(f.store.folder, f.root); XCTAssertEqual(f.provider.count, 1)
    }

    func testEmptyFilterEntryOpensFolderDirectlyAndCancellationPreservesBothDrafts() async throws {
        for role in [PhotoNp3Store.Role.transfer, .local] {
            let f = try Fixture(role, folder: false); defer { f.clean() }
            f.begin()
            let original = f.draft
            XCTAssertEqual(f.session.editor.emptyLabelKey, "photo_filter_set_folder")
            XCTAssertEqual(f.session.editor.catalog(selected: nil, favorites: []).selectionOptions, [nil])
            f.session.launchFolderPicker()
            XCTAssertTrue(f.session.showingFolder)
            XCTAssertFalse(f.session.showingChooser)
            XCTAssertFalse(f.session.showingFolderHint)
            f.session.folderPickerCompleted(.failure(CocoaError(.userCancelled)), lifetimeID: f.session.lifetimeID)
            XCTAssertEqual(f.draft, original)
            XCTAssertNil(f.store.folder)
            XCTAssertEqual(f.provider.count, 0)
            XCTAssertFalse(f.session.showingFolder)
            f.provider.files = []
            f.session.launchFolderPicker()
            f.session.folderPickerCompleted(.success([f.root]), lifetimeID: f.session.lifetimeID)
            try await settle(f.session)
            XCTAssertEqual(f.session.editor.emptyLabelKey, "photo_filter_folder_empty")
            XCTAssertEqual(f.session.editor.catalog(selected: nil, favorites: []).selectionOptions, [nil])
            XCTAssertFalse(f.draft.photoFilterEnabled)
        }
    }

    func testRetainedInactivePageRejectsPickerAndLateReadThenRefreshesOnReturn() async throws {
        let f = try Fixture(.local); defer { f.clean() }
        f.begin(); try await settle(f.session)
        let gate = DispatchSemaphore(value: 0); f.provider.gate = gate
        f.choose()
        let deadline = ContinuousClock.now + .seconds(2)
        while f.provider.readCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(f.provider.readCount, 1)
        f.session.setActive(false); gate.signal()
        f.session.folderPickerCompleted(.success([URL(fileURLWithPath: "/other/")]), lifetimeID: f.session.lifetimeID)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(f.draft.selectedFilter?.np3Recipe)
        XCTAssertEqual(f.store.folder, f.root)
        XCTAssertFalse(f.session.showingChooser)
        f.provider.gate = nil
        f.session.setActive(true); try await settle(f.session)
        XCTAssertEqual(f.provider.count, 2)
        f.choose(); try await settle(f.session)
        XCTAssertNotNil(f.draft.selectedFilter?.np3Recipe)
    }

    func testFreshPresentationRestoresOwnerInsteadOfReusingClosedState() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.begin(); try await settle(f.session); f.choose(); try await settle(f.session)
        let old = f.session.editor
        f.session.end()
        f.draft = f.effects.beginDraft()
        f.begin(); try await settle(f.session)
        XCTAssertFalse(f.session.editor === old)
        XCTAssertNil(f.session.editor.selectedSource)
        XCTAssertNil(f.draft.selectedFilter?.np3Recipe, "An unapplied transfer draft must not become the next applied selection")
        old.choose(f.provider.files[0].identifier)
        XCTAssertFalse(old.loading)
        f.choose(); try await settle(f.session)
        XCTAssertEqual(f.explicitChanges, 2)
    }

    func testOldNativePickerCannotMutateOrDismissNextPresentation() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.begin(); try await settle(f.session)
        f.session.launchFolderPicker()
        let previous = f.session.lifetimeID
        f.begin(); try await settle(f.session)
        f.session.launchFolderPicker()
        f.session.folderPickerCompleted(.success([URL(fileURLWithPath: "/old-picker/")]), lifetimeID: previous)
        XCTAssertTrue(f.session.showingFolder)
        XCTAssertEqual(f.store.folder, f.root)
        XCTAssertNil(f.session.notice)
    }

    func testNP3ResourcesResolveThroughTheActualAppLookupInAllThreeLanguages() {
        let keys = ["photo_np3_selected_source", "photo_filter_folder", "photo_filter_folder_hint",
            "photo_filter_folder_empty", "photo_np3_invalid", "photo_np3_unsupported", "photo_np3_too_large",
            "photo_np3_read_failed", "photo_np3_read_timeout", "photo_filter_settings", "photo_color_reset"]
            + PhotoEffectFilterCategory.allCases.map { "photo_filter_category_" + $0.rawValue }
        for key in keys {
            for language in ["en", "zh", "hant"] {
                let value = AppLocalized.resource(key, language: language)
                XCTAssertNotEqual(value, key, "Missing \(language)/\(key)")
                XCTAssertFalse(value.isEmpty)
            }
        }
        XCTAssertEqual(AppLocalized.resource("photo_filter_settings", language: "zh"), "调整效果")
        XCTAssertEqual(AppLocalized.resource("photo_filter_settings", language: "en"), "Adjust")
        XCTAssertEqual(AppLocalized.resource("photo_filter_set_folder", language: "zh"), "设置NP3文件目录")
        XCTAssertEqual(AppLocalized.resource("photo_filter_set_folder", language: "en"), "Set NP3 folder")
        XCTAssertEqual(AppLocalized.resource("photo_filter_set_folder", language: "hant"), "設定NP3檔案目錄")
        XCTAssertEqual(AppLocalized.resource("photo_filter_category_cinematic", language: "hant"), "電影")
        XCTAssertTrue(AppLocalized.resource("photo_filter_folder_hint", language: "en").contains("\n\n"))
    }

    func testSameContentImportedSelectionRetainsDocumentAndAdjustmentMemory() async throws {
        let f = try Fixture(); defer { f.clean() }
        let builtin = TestPhotoFilterCatalog.np3Presets[0]
        f.provider.parsed = .init(sourceSha256: PhotoNp3RecipeKind.sourceDigest(builtin.id)!,
            recipe: .init(preset: .init(id: builtin.id, name: builtin.name), parameters: .flexible(builtin.parameters)), ignoredDetailControls: false)
        f.draft.filterIntensities[builtin.catalogKey] = 54
        f.draft.filterAdjustments[builtin.catalogKey] = .init(contrast: 9, saturation: -7, highlights: 13, shadows: -24)
        f.begin(); try await settle(f.session); f.choose(); try await settle(f.session)
        XCTAssertEqual(f.draft.selectedFilter?.intensityPercent, 54)
        XCTAssertEqual(f.draft.selectedFilter?.lutAdjustments.contrast, 9)
        XCTAssertNotNil(f.session.source(for: f.draft))
        f.session.settingsExpanded = true
        f.choose(); try await settle(f.session)
        XCTAssertNotNil(f.session.source(for: f.draft))
        XCTAssertTrue(f.session.settingsExpanded)
        XCTAssertEqual(f.draft.selectedFilter?.lutAdjustments.shadows, -24)
        f.session.disable(); XCTAssertFalse(f.session.settingsExpanded)
    }

    func testDirectoryReplacementClearsOpenDraftAndItsRememberedCustomControls() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.begin(); try await settle(f.session); f.choose(); try await settle(f.session)
        let key = PhotoEffectsSettings.filterKey(f.provider.parsed.recipe.preset.id)
        f.draft.filterAdjustments[key] = .init(contrast: 35)
        f.store.replaceFolder(URL(fileURLWithPath: "/new-directory/", isDirectory: true), bookmark: Data([2]))
        XCTAssertNil(f.draft.selectedFilter)
        XCTAssertNil(f.draft.filterAdjustments[key]); XCTAssertNil(f.draft.filterIntensities[key])
        XCTAssertNil(f.session.source(for: f.draft))
    }

    func testDisclosureSurvivesInactivePagerButResetsOnDisabledFilter() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.begin(); try await settle(f.session); f.choose(); try await settle(f.session)
        f.session.settingsExpanded = true
        f.session.setActive(false)
        XCTAssertTrue(f.session.settingsExpanded)
        f.session.setActive(true); try await settle(f.session)
        XCTAssertTrue(f.session.settingsExpanded)
        f.draft.photoFilterEnabled = false
        f.session.draftChanged(f.draft)
        XCTAssertFalse(f.session.settingsExpanded)
        f.session.choose(.preset(f.provider.parsed.recipe.preset, source: f.provider.files[0].identifier))
        XCTAssertTrue(f.draft.photoFilterEnabled)
        XCTAssertFalse(f.session.settingsExpanded)
    }

    func testImportedFavoriteSurvivesOwnerNormalizationAndReload() async throws {
        for role in [PhotoNp3Store.Role.transfer, .local] {
            let f = try Fixture(role); defer { f.clean() }
            f.begin(); try await settle(f.session); f.choose(); try await settle(f.session)
            var value = f.draft
            f.effects.toggleFilterFavorite(try XCTUnwrap(value.builtinFilterSelection))
            value.favoriteFilterIDs += ["unknown", "np3:invalid"]
            f.binding.wrappedValue = value
            let expected = [PhotoEffectsSettings.filterKey(f.provider.parsed.recipe.preset.id)]
            XCTAssertEqual(f.effects.settings.favoriteFilterIDs, expected)
            let restored = PhotoEffectsStore(defaults: f.defaults, scope: role == .transfer ? .cameraTransfer : .localPhotos)
            XCTAssertEqual(restored.settings.favoriteFilterIDs, expected)
        }
    }

    func testParameterSnapshotInvalidatesOldWheelDragWithoutRecreatingTheWheel() {
        let preset = TestPhotoFilterCatalog.presets[0]
        var selection = testPhotoFilterSelection(preset: preset, intensityPercent: 60)
        let first = DetentWheelConfiguration(options: Array(stride(from: 100, through: 2, by: -2)),
            rowHeight: 16, enabled: true, readOnly: false, identity: PhotoColorControlIdentity(selection))
        var drag = DetentWheelDragSession(configuration: first)
        let revision = drag.revision
        XCTAssertTrue(drag.begin(revision: revision, selectedIndex: 20))
        selection.lutAdjustments.contrast = 9
        drag.update(configuration: .init(options: first.options, rowHeight: 16, enabled: true, readOnly: false,
            identity: PhotoColorControlIdentity(selection)))
        XCTAssertNil(drag.release(revision: revision, translation: 32))
        let values = PhotoColorAdjustmentControls.options(9)
        XCTAssertEqual(values[try! XCTUnwrap(values.firstIndex(of: 9)) + 1], 5)
        XCTAssertEqual(PhotoColorAdjustmentControls.options(-7).filter { $0 == -7 }.count, 1)
        XCTAssertEqual(PhotoColorAdjustmentControls.options(0).count, 41)
    }

    private struct TransferHost: View {
        @ObservedObject var fixture: Fixture
        let lut: PhotoLUTEditorState
        let directory: DirectoryAccessStore
        var body: some View {
            SettingsView(showPhotoEffectsEntry: true, effectsStore: fixture.effects, directory: directory,
                effectsDraft: fixture.binding, effectsHint: $fixture.hint, dismissalRequested: fixture.closing,
                photoLUTEditor: lut, photoFilterSession: fixture.session, effectsOnly: true)
                .overlay { PhotoNP3ChooserPresentation(session: fixture.session, draft: fixture.binding) }
                .onAppear { fixture.begin() }
                .onDisappear { fixture.session.end() }
        }
    }

    private struct PopupHost: View {
        @ObservedObject var fixture: Fixture
        let directory: DirectoryAccessStore
        var body: some View {
            Color.clear.overlay(alignment: .topLeading) {
                Color.clear.frame(width: 44, height: 36).geniePopupAnchor(.settings)
            }.overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
                if let anchor = anchors[.settings] {
                    SettingsPopupOverlay(isPresented: Binding(get: { !fixture.closing }, set: { fixture.closing = !$0 }),
                        showPhotoEffectsEntry: true, effectsStore: fixture.effects, directory: directory,
                        anchor: anchor, effectsOnly: true, photoFilterSession: fixture.session)
                }
            }
        }
    }

    func testActualPopupReopeningUsesFreshSessionAndHiddenModuleDoesNotScan() async throws {
        for visible in [true, false] {
            let f = try Fixture(); defer { f.clean() }
            var settings = f.effects.settings
            settings.photoEffectModules = visible ? PhotoEffectModule.filter.rawValue : PhotoEffectModule.frame.rawValue
            f.effects.updateFromEditor(settings)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: PopupHost(fixture: f, directory: .init(defaults: f.defaults)))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            try await Task.sleep(for: .milliseconds(150)); try await settle(f.session)
            XCTAssertEqual(f.session.active, visible)
            XCTAssertEqual(f.provider.count, visible ? 1 : 0)
            let previousID = f.session.lifetimeID
            f.closing = true
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertFalse(f.session.active)
            f.closing = false
            try await Task.sleep(for: .milliseconds(150)); try await settle(f.session)
            XCTAssertNotEqual(f.session.lifetimeID, previousID)
            XCTAssertEqual(f.session.active, visible)
            XCTAssertEqual(f.provider.count, visible ? 2 : 0)
        }
    }

    func testActualTransferAndLocalPagesUseSourceAndKeepTheirCommitBoundaries() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: "app_language")
        UserDefaults.standard.set("zh-Hans", forKey: "app_language")
        defer { UserDefaults.standard.set(previousLanguage, forKey: "app_language") }
        for role in [PhotoNp3Store.Role.transfer, .local] {
            let f = try Fixture(role); defer { f.clean() }
            let lut = PhotoLUTEditorState(role: role == .transfer ? .camera : .local, defaults: f.defaults)
            let content: AnyView
            if role == .transfer {
                content = AnyView(TransferHost(fixture: f, lut: lut, directory: .init(defaults: f.defaults)))
            } else {
                content = AnyView(LocalPhotoEffectsView(onNavigateUp: {}, effectsStore: f.effects,
                    photoFilterSession: f.session, photoLUTEditor: lut))
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: role == .transfer ? 390 : 280, height: 844)
            window.rootViewController = UIHostingController(rootView: content.environment(\.colorScheme, role == .transfer ? .light : .dark))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            try await Task.sleep(for: .milliseconds(150)); try await settle(f.session)
            XCTAssertTrue(f.session.active)
            f.choose(); try await settle(f.session)
            let value = role == .transfer ? f.draft : f.effects.settings
            XCTAssertEqual(value.selectedFilter?.preset.id, f.provider.parsed.recipe.preset.id)
            XCTAssertEqual(f.session.source(for: value), f.provider.files[0].identifier)
            if role == .transfer { XCTAssertNil(f.store.restore(role)) }
            else { XCTAssertEqual(f.store.restore(role)?.preset.id, value.selectedFilter?.preset.id) }
            // Both real page hosts subscribe to the authoritative favorites,
            // while retaining their independent selection/commit boundaries.
            let selected = try XCTUnwrap(value.builtinFilterSelection)
            let favoriteKey = PhotoEffectsSettings.filterKey(selected.preset.id)
            f.effects.toggleFilterFavorite(selected)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual((role == .transfer ? f.draft : f.effects.settings).favoriteFilterIDs, [favoriteKey])
            let otherEntry = SharedPhotoFilterFavorites(defaults: f.defaults, legacyLocal: f.defaults)
            otherEntry.toggle(favoriteKey)
            try await Task.sleep(for: .milliseconds(30))
            let synced = role == .transfer ? f.draft : f.effects.settings
            XCTAssertTrue(synced.favoriteFilterIDs.isEmpty)
            XCTAssertEqual(synced.selectedFilter, selected)
            f.session.settingsExpanded = true
            try await Task.sleep(for: .milliseconds(300))
            try capture(window, name: "np3-\(role.rawValue)-controls")
            f.session.openChooser(); try await settle(f.session)
            try await Task.sleep(for: .milliseconds(300))
            try capture(window, name: "np3-\(role.rawValue)-chooser")
            f.session.showingFolderHint = true
            try await Task.sleep(for: .milliseconds(30))
            try capture(window, name: "np3-\(role.rawValue)-hint")
            f.session.closeChooser()
            if role == .transfer {
                f.closing = true
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertEqual(f.store.restore(role)?.preset.id, value.selectedFilter?.preset.id)
                XCTAssertEqual(f.store.source(role), f.provider.files[0].identifier)
            }
        }
    }

    private func capture(_ window: UIWindow, name: String) throws {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try XCTUnwrap(image.pngData()).write(to: path)
        print("NP3_SCREENSHOT: \(path.path)")
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
