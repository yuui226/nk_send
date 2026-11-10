import XCTest
@testable import ZTransfer

/// User-imported duplicate content and filenames retain source identity. These verify metadata/selection semantics;
/// they do not replace its real dialog/wheel interaction scenarios.
@MainActor
final class PhotoFilterCatalogIndexTests: XCTestCase {
    private var imported: PhotoNp3Recipe {
        let value = TestPhotoFilterCatalog.np3Presets[0]
        return .init(preset: .init(id: value.id, name: value.name), parameters: .flexible(value.parameters))
    }
    private var custom: PhotoNp3Recipe {
        .init(preset: .init(id: "np3:" + String(repeating: "a", count: 64) + ":np3-srgb-v1", name: "Embedded name"),
            parameters: imported.parameters)
    }
    private func file(_ path: String, id: String? = nil) -> PresetFile {
        .init(identifier: id ?? URL(fileURLWithPath: "/catalog/" + path).absoluteString,
            name: (path as NSString).lastPathComponent, relativePath: path, size: 392)
    }
    private func index(_ files: [PresetFile] = [], recipe: PhotoNp3Recipe? = nil, source: String? = nil,
                       selected: PhotoFilterPreset? = nil, failure: RemoteLUTFolderAccessError? = nil,
                       hints: [String: String] = [:], favorites: [String] = [],
                       label: PhotoNp3SourceLabel? = nil) -> PhotoFilterCatalogIndex {
        .init(files: files, failure: failure, hints: hints, sourceRecipe: recipe, source: source,
            sourceLabel: label, selected: selected ?? recipe?.preset, favorites: favorites)
    }
    private func labels(_ index: PhotoFilterCatalogIndex) -> [String: String] {
        index.labels(locale: "en", uncategorized: "Uncategorized", restoredSourceFallback: "Selected NP3",
            builtInLabel: { "localized:" + $0.id })
    }

    func testImportedCopiesRetainTheirSourceIdentityAndLabels() {
        let first = file("Copy.np3"), second = file("Portraits/Copy.np3")
        let catalog = index([first, second], recipe: imported, source: second.identifier,
            hints: [first.identifier: imported.preset.id, second.identifier: imported.preset.id])
        XCTAssertEqual(catalog.currentKey, "document:" + second.identifier)
        XCTAssertEqual(catalog.choices.filter { $0.presetID == imported.preset.id }.count, 2)
        XCTAssertEqual(labels(catalog)[catalog.currentKey!], "Copy · Portraits")
        XCTAssertEqual(catalog.pendingKey(source: first.identifier), "document:" + first.identifier)
        XCTAssertNil(catalog.pendingKey(source: "file:///not-listed.np3"))
        let explicitImported = index([first, second], recipe: imported)
        XCTAssertEqual(explicitImported.currentKey, "preset:" + imported.preset.id)
    }

    func testFileAndCategoryOrderingMatchesAndroidCharacterComparator() {
        // Executed against libcore's charAt comparator with JDK Character maps.
        // Whole-string lowercase, localized collation, and scalar comparison
        // give different orders for dotted I, sigma, normalization and astral text.
        let names = ["i", "I", "\u{0130}", "\u{0131}", "\u{00df}", "ss", "\u{03a3}",
            "\u{03c3}", "\u{03c2}", "\u{e000}", "\u{10000}", "\u{1fb3}", "\u{1fbc}", "\u{e9}", "e\u{301}"]
        let expected = [14, 1, 0, 2, 3, 5, 4, 13, 6, 8, 7, 11, 12, 10, 9].map { names[$0] }
        let files = names.enumerated().map {
            PresetFile(identifier: String($0.offset), name: $0.element + ".np3",
                       relativePath: $0.element + "/" + $0.element + ".np3", size: nil)
        }
        XCTAssertEqual(RemoteLUTCatalog.visibleFiles(files, fileExtension: "np3").map(\.label), expected)
        XCTAssertEqual(PhotoLUTCategorySelection.categories(in: files).compactMap { $0 }, expected)
        XCTAssertEqual(PresetTextOrder.folded("\u{0130}\u{0131}I"), [105, 105, 105])
        XCTAssertEqual(PresetTextOrder.folded("\u{03a3}\u{03c2}\u{03c3}"), [963, 963, 963])
        XCTAssertEqual(PresetTextOrder.folded("\u{00df}ss"), [223, 115, 115])
        XCTAssertEqual(PresetTextOrder.folded("\u{1fb3}\u{1fbc}"), [0x1FB3, 0x1FB3])
        XCTAssertEqual(PresetTextOrder.folded("\u{10400}"), Array("\u{10400}".utf16), "Android leaves surrogate units unchanged")
        let index = PresetCatalogIndex(files: files)
        XCTAssertEqual(index.files(in: "\u{e9}")?.map(\.identifier), ["13"])
        XCTAssertEqual(index.files(in: "e\u{301}")?.map(\.identifier), ["14"])
        XCTAssertNotEqual(Optional("\u{e9}").presetCategoryIdentifier, Optional("e\u{301}").presetCategoryIdentifier)
        let np3 = self.index(files)
        XCTAssertEqual(np3.categories.filter { $0.builtIn == nil }.count, names.count)
        XCTAssertEqual(Set(np3.categories.map(\.key)).count, np3.categories.count)
        for group in np3.categories where group.builtIn == nil { XCTAssertEqual(group.choices.count, 1) }
    }

    func testOfflineDocumentNeverPretendsItsEmbeddedNameIsTheFilename() {
        let source = file("Actual filename.np3").identifier
        let fallback = index(recipe: custom, source: source)
        XCTAssertEqual(fallback.currentKey, "document:" + source)
        XCTAssertEqual(labels(fallback)[fallback.currentKey!], "Selected NP3")
        let saved = PhotoNp3SourceLabel(name: "Actual filename", category: "Portraits", showCategory: true, ordinal: 2)
        let restored = index(recipe: custom, source: source, label: saved)
        XCTAssertEqual(labels(restored)[restored.currentKey!], "Actual filename · Portraits · 2")
        let detached = index(recipe: custom)
        XCTAssertEqual(detached.currentKey, "preset:" + custom.preset.id)
        XCTAssertEqual(labels(detached)[detached.currentKey!], "Embedded name")
    }

    func testUnavailableFolderRetainsSnapshotButOnlyMissingOrDeniedHideFiles() {
        let source = file("Visible.np3")
        for failure in [RemoteLUTFolderAccessError.missing, .denied, .read, .tooMany] {
            let catalog = index([source], recipe: custom, source: source.identifier, failure: failure)
            let isDocument: Bool
            if case .document = catalog.byKey["document:" + source.identifier] { isDocument = true }
            else { isDocument = false }
            XCTAssertEqual(isDocument, failure == .read || failure == .tooMany)
            XCTAssertEqual(catalog.currentKey, "document:" + source.identifier)
            XCTAssertEqual(catalog.categories.contains { $0.key == "directory:root" }, isDocument)
        }
    }

    func testFavoritesUseContentKeysWithoutCoalescingDocumentsOrChangingOrdinals() {
        let a = file("same.np3", id: "file:///catalog/first"), b = file("same.np3", id: "file:///catalog/second")
        let key = PhotoFilterPreferences.catalogKey(custom.preset.id)!
        let builtinKey = PhotoFilterPreferences.catalogKey(imported.preset.id)!
        let catalog = index([a, b], hints: [a.identifier: imported.preset.id, b.identifier: custom.preset.id],
            favorites: [key, builtinKey])
        XCTAssertEqual(catalog.choices.prefix(3).map(\.key),
            ["document:" + b.identifier, "document:" + a.identifier])
        XCTAssertEqual(labels(catalog)["document:" + a.identifier], "same · Uncategorized · 1")
        XCTAssertEqual(labels(catalog)["document:" + b.identifier], "same · Uncategorized · 2")
        XCTAssertEqual(catalog.categories.first { $0.key == "builtin:favorites" }?.choices.count, 2)
        XCTAssertEqual(catalog.categories.first { $0.key == "directory:root" }?.choices.map(\.key),
            ["document:" + b.identifier, "document:" + a.identifier])
    }

    func testOffAndMismatchedSourceDoNotHighlightAnUnrelatedDocument() {
        let a = file("A.np3"), b = file("B.np3")
        let current = index([a, b], recipe: custom, source: a.identifier)
        XCTAssertNil(current.currentKey(enabled: false))
        XCTAssertEqual(current.currentKey(enabled: true), "document:" + a.identifier)
        let stale = index([a, b], recipe: custom, source: a.identifier, selected: imported.preset)
        XCTAssertEqual(stale.currentKey, "preset:" + imported.preset.id)
        XCTAssertEqual(stale.choices.count, 3)
        XCTAssertEqual(current.byKey["document:" + a.identifier]?.presetID, custom.preset.id)
        XCTAssertNil(current.byKey["document:" + b.identifier]?.presetID)
    }

    func testCategorySelectionPreservesBrowsingUntilTheSelectionChanges() {
        let a = file("Portraits/A.np3"), b = file("Landscapes/B.np3")
        let catalog = index([a, b], recipe: custom, source: a.identifier)
        var selection = PhotoFilterCategorySelection()
        selection.reconcile(catalog: catalog, selected: catalog.currentKey)
        XCTAssertEqual(selection.key, "builtin:all")
        selection.select("directory:folder:Portraits")
        selection.reconcile(catalog: catalog, selected: catalog.currentKey)
        XCTAssertEqual(selection.key, "directory:folder:Portraits")
        selection.reconcile(catalog: catalog, selected: "document:" + b.identifier)
        XCTAssertEqual(selection.key, "builtin:all")
        selection.select("directory:folder:Portraits")
        selection.reconcile(catalog: index([b]), selected: "document:" + b.identifier)
        XCTAssertEqual(selection.key, "builtin:all")
    }

    func testLargeDirectoryIsGroupedOnceAndLabelsAreCachedByLocale() {
        let files = (0..<10_000).map { file("category-\($0)/NP3.np3") }
        let catalog = index(files)
        XCTAssertEqual(catalog.choices.count, 10_000)
        XCTAssertEqual(catalog.categories.filter { $0.builtIn == nil }.reduce(0) { $0 + $1.choices.count }, 10_000)
        var calls = 0
        func localized(_ preset: PhotoFilterPreset) -> String { calls += 1; return preset.name }
        let first = catalog.labels(locale: "en", uncategorized: "Root", restoredSourceFallback: "NP3", builtInLabel: localized)
        for _ in 0..<20 {
            _ = catalog.labels(locale: "en", uncategorized: "Root", restoredSourceFallback: "NP3", builtInLabel: localized)
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(first.count, catalog.choices.count)
        _ = catalog.labels(locale: "zh", uncategorized: "Root", restoredSourceFallback: "NP3", builtInLabel: localized)
        XCTAssertEqual(calls, 0)
    }

    func testEditorKeepsIndexAcrossRequestChangesAndInvalidatesSourceOrFavorites() throws {
        let suite = "PhotoFilterCatalogIndexTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let editor = PhotoNp3EditorState(store: .init(defaults: defaults), role: .transfer,
            initialRecipe: imported, onSelected: { _, _ in }, onUnavailable: {})
        defer { editor.close() }
        let first = editor.catalog(selected: imported.preset, favorites: [])
        editor.cancelPending()
        for _ in 0..<100 { XCTAssertTrue(editor.catalog(selected: imported.preset, favorites: []) === first) }
        editor.resetSelection(imported, source: file("Copy.np3").identifier)
        let source = editor.catalog(selected: imported.preset, favorites: [])
        XCTAssertFalse(source === first)
        XCTAssertEqual(source.currentKey, "document:" + file("Copy.np3").identifier)
        let favorites = editor.catalog(selected: imported.preset, favorites: [PhotoEffectsSettings.filterKey(imported.preset.id)])
        XCTAssertFalse(favorites === source)
    }
}
