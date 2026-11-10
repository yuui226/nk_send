import XCTest
@testable import ZTransfer

/// Mirrors Android PhotoNp3StateInstrumentation with the production serial
/// queue. Provider gates deliberately ignore cancellation until released.
@MainActor
final class PhotoNp3EditorStateTests: XCTestCase {
    private final class Provider: @unchecked Sendable {
        final class Read: @unchecked Sendable {
            let file: PresetFile
            let condition = NSCondition()
            private var result: Result<ParsedPhotoNp3, Error>?
            init(_ file: PresetFile) { self.file = file }
            func complete(_ result: Result<ParsedPhotoNp3, Error>) {
                condition.lock(); self.result = result; condition.broadcast(); condition.unlock()
            }
            func wait() throws -> ParsedPhotoNp3 {
                condition.lock(); defer { condition.unlock() }
                let deadline = Date().addingTimeInterval(5)
                while result == nil, condition.wait(until: deadline) {}
                return try XCTUnwrap(result, "Provider gate was not released").get()
            }
        }
        let lock = NSLock()
        private var listed: [PresetFile] = []
        private var scanFailure: RemoteLUTFolderAccessError?
        private var reads: [Read] = []
        private var allReads: [Read] = []
        private var scans = 0
        private var scanWait: DispatchSemaphore?
        var scanGate: DispatchSemaphore? {
            get { lock.withLock { scanWait } }
            set { lock.withLock { scanWait = newValue } }
        }
        var files: [PresetFile] {
            get { lock.withLock { listed } }
            set { lock.withLock { listed = newValue } }
        }
        var error: RemoteLUTFolderAccessError? {
            get { lock.withLock { scanFailure } }
            set { lock.withLock { scanFailure = newValue } }
        }
        var scanCount: Int { lock.withLock { scans } }
        var readCount: Int { lock.withLock { allReads.count } }
        func popRead() -> Read? { lock.withLock { reads.isEmpty ? nil : reads.removeFirst() } }
        func releaseAll() { lock.withLock { allReads }.forEach { $0.complete(.failure(CancellationError())) } }
        var adapter: PhotoNp3Source {
            .init(scan: { [self] input, _ in
                let (files, failure, gate) = lock.withLock {
                    scans += 1
                    return (listed, scanFailure, scanWait)
                }
                if let gate, gate.wait(timeout: .now() + 5) != .success { throw RemoteLUTFolderAccessError.read }
                if let failure { throw failure }
                return .init(bookmark: Data(input.folder.path.utf8), files: files, root: input.folder)
            }, read: { [self] file, _, _ in
                let pending = Read(file)
                lock.withLock { reads.append(pending); allReads.append(pending) }
                return try pending.wait()
            })
        }
    }

    @MainActor private final class Fixture {
        let suite = "PhotoNp3EditorStateTests-" + UUID().uuidString
        let defaults: UserDefaults
        let store: PhotoNp3Store
        let provider = Provider()
        let queue = PresetIOQueue()
        var editors: [PhotoNp3EditorState] = []
        var selections: [(PhotoNp3Recipe, Bool)] = []
        var unavailable: [PhotoNp3Store.Role] = []
        var active = true
        let root = URL(fileURLWithPath: "/np3-fixture/a/", isDirectory: true)
        init() {
            defaults = UserDefaults(suiteName: suite)!
            store = PhotoNp3Store(defaults: defaults)
            store.replaceFolder(root, bookmark: Data([1]))
        }
        func file(_ name: String, root: URL? = nil) -> PresetFile {
            .init(identifier: (root ?? self.root).appendingPathComponent(name).absoluteString,
                name: name, relativePath: name, size: 100)
        }
        func editor(_ role: PhotoNp3Store.Role = .transfer, initial: PhotoNp3Recipe? = nil,
                    timeout: Duration = .seconds(10)) -> PhotoNp3EditorState {
            let result = PhotoNp3EditorState(store: store, role: role, initialRecipe: initial,
                source: provider.adapter, request: .init(queue: queue), timeout: timeout,
                onSelected: { [weak self] recipe, explicit in self?.selections.append((recipe, explicit)) },
                onUnavailable: { [weak self] in self?.unavailable.append(role) },
                selectionAllowed: { [weak self] in self?.active == true })
            editors.append(result); return result
        }
        func clean() {
            editors.forEach { $0.close() }; provider.releaseAll()
            defaults.removePersistentDomain(forName: suite)
        }
    }
    private func parsed(_ digit: Character = "a") throws -> ParsedPhotoNp3 {
        let template = try photoNp3SnapshotFixture("F:0"), hash = String(repeating: String(digit), count: 64)
        return .init(sourceSha256: hash,
            recipe: .init(preset: .init(id: "np3:\(hash):np3-srgb-v1", name: "Fixture \(digit)"), parameters: template.parameters),
            ignoredDetailControls: false)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func nextRead(_ provider: Provider) async throws -> Provider.Read {
        var value: Provider.Read?
        try await wait { value = provider.popRead(); return value != nil }
        return try XCTUnwrap(value)
    }
    private func settle(_ editor: PhotoNp3EditorState) async throws { try await wait { !editor.loading } }

    func testEmptyDirectoryLabelFollowsLoadingAndAccessFailureWithoutSelectingAFilter() async throws {
        let f = Fixture(); defer { f.clean() }
        let editor = f.editor()
        XCTAssertEqual(editor.emptyLabelKey, "photo_filter_folder_empty")
        let gate = DispatchSemaphore(value: 0)
        f.provider.scanGate = gate
        editor.refresh()
        XCTAssertEqual(editor.emptyLabelKey, "lut_reading_folder")
        gate.signal(); try await settle(editor)
        f.provider.scanGate = nil
        for (failure, expected) in [(RemoteLUTFolderAccessError.missing, "lut_folder_missing"),
                                   (.denied, "lut_folder_denied"), (.read, "lut_folder_read_failed"),
                                   (.tooMany, "lut_folder_too_many")] {
            f.provider.error = failure
            editor.refresh(); try await settle(editor)
            XCTAssertEqual(editor.emptyLabelKey, expected)
            XCTAssertEqual(editor.catalog(selected: nil, favorites: []).selectionOptions, [nil])
        }
        XCTAssertTrue(f.selections.isEmpty)
    }
    private func drain(_ queue: PresetIOQueue) async {
        await withCheckedContinuation { continuation in
            queue.submit(action: { _ in true }, deliver: { _ in continuation.resume() })
        }
    }
    private func selectedFixture() async throws -> (Fixture, PhotoNp3EditorState, PresetFile, ParsedPhotoNp3) {
        let f = Fixture(), a = f.file("A.NP3"), b = f.file("B.NP3"), recipe = try parsed()
        f.provider.files = [a, b]
        let editor = f.editor(); editor.refresh(); try await settle(editor)
        editor.choose(a.identifier)
        try await nextRead(f.provider).complete(.success(recipe))
        try await settle(editor)
        return (f, editor, a, recipe)
    }

    func testFreshSelectionAndRejectedCandidatePreserveAppliedRecipe() async throws {
        let (f, editor, a, recipe) = try await selectedFixture(); defer { f.clean() }
        XCTAssertEqual(editor.selectedRecipe, recipe.recipe); XCTAssertEqual(editor.selectedSource, a.identifier)
        XCTAssertEqual(f.selections.count, 1); XCTAssertTrue(f.selections[0].1)
        XCTAssertEqual(editor.knownPresetID(a.identifier), recipe.recipe.preset.id)
        for (reason, key) in [(PhotoNp3Failure.invalid, "photo_np3_invalid"), (.unsupported, "photo_np3_unsupported"), (.tooLarge, "photo_np3_too_large")] {
            editor.choose(f.file("B.NP3").identifier)
            XCTAssertTrue(editor.loadingSelection); XCTAssertEqual(editor.pendingSource, f.file("B.NP3").identifier)
            try await nextRead(f.provider).complete(.failure(PhotoNp3Error(reason: reason, message: "fixture")))
            try await settle(editor)
            XCTAssertEqual(editor.notice?.resource, key); XCTAssertEqual(editor.selectedRecipe, recipe.recipe)
            XCTAssertEqual(editor.selectedSource, a.identifier); XCTAssertEqual(f.selections.count, 1)
        }
        editor.choose("not-listed"); XCTAssertFalse(editor.loading)
    }

    func testRefreshAlwaysReadsButDoesNotEnableOffOrResetUnchangedDraft() async throws {
        let (f, editor, a, _) = try await selectedFixture(); defer { f.clean() }
        let changed = try parsed("c")
        editor.refresh(); editor.refresh()
        let pending = try await nextRead(f.provider)
        XCTAssertEqual(pending.file, a); XCTAssertFalse(editor.loadingSelection); XCTAssertNil(editor.pendingSource)
        pending.complete(.success(changed)); try await settle(editor)
        XCTAssertEqual(editor.selectedRecipe, changed.recipe)
        XCTAssertEqual(f.selections.count, 2); XCTAssertFalse(f.selections[1].1)
        editor.refresh(); try await nextRead(f.provider).complete(.success(changed)); try await settle(editor)
        XCTAssertEqual(f.provider.readCount, 3); XCTAssertEqual(f.selections.count, 2)
        XCTAssertEqual(f.provider.scanCount, 3)
    }

    func testScanFailureRetainsListRecipeAndSavedRoleOnlyCompleteDeletionDisablesDraft() async throws {
        let (f, editor, a, recipe) = try await selectedFixture(); defer { f.clean() }
        try f.store.save(.transfer, recipe: recipe.recipe, source: a.identifier)
        let oldFiles = editor.files
        for reason: RemoteLUTFolderAccessError in [.read, .missing, .denied, .tooMany] {
            f.provider.error = reason; editor.refresh(); try await settle(editor)
            XCTAssertEqual(editor.files, oldFiles); XCTAssertEqual(editor.selectedRecipe, recipe.recipe)
            XCTAssertEqual(editor.failure, reason); XCTAssertTrue(f.unavailable.isEmpty)
        }
        f.provider.error = nil; f.provider.files = []
        editor.refresh(); try await settle(editor)
        XCTAssertNil(editor.selectedRecipe); XCTAssertNil(editor.selectedSource); XCTAssertNil(editor.failure)
        XCTAssertEqual(f.unavailable, [.transfer])
        XCTAssertEqual(f.store.restore(.transfer), recipe.recipe, "The source draft does not commit its owner's settings")
    }

    func testListedNameRefreshSurvivesBadNewBytesWithoutChangingRecipeName() async throws {
        let (f, editor, a, recipe) = try await selectedFixture(); defer { f.clean() }
        f.provider.files = [.init(identifier: a.identifier, name: "Renamed.NP3", relativePath: a.relativePath, size: 120)]
        editor.refresh(); try await nextRead(f.provider).complete(.failure(CocoaError(.fileReadUnknown)))
        try await settle(editor)
        XCTAssertEqual(editor.selectedRecipe, recipe.recipe)
        XCTAssertEqual(editor.selectedSourceLabel?.name, "Renamed")
        XCTAssertEqual(f.store.sourceLabel(a.identifier)?.name, "Renamed")
        XCTAssertEqual(editor.notice?.resource, "photo_np3_read_failed")
    }

    func testCancelOffResetCloseAndInactiveOwnerRejectLateProviderResults() async throws {
        for operation in 0..<5 {
            let (f, editor, a, recipe) = try await selectedFixture(); defer { f.clean() }
            editor.choose(f.file("B.NP3").identifier)
            let pending = try await nextRead(f.provider)
            switch operation {
            case 0: editor.cancelPending()
            case 1: editor.off()
            case 2: editor.resetSelection(recipe.recipe)
            case 3: editor.close()
            default: f.active = false
            }
            pending.complete(.success(try parsed("b"))); await drain(f.queue)
            XCTAssertFalse(editor.loading); XCTAssertNil(editor.pendingSource)
            XCTAssertEqual(editor.selectedRecipe, operation == 1 ? nil : recipe.recipe)
            XCTAssertEqual(editor.selectedSource, operation == 1 ? nil : a.identifier)
            XCTAssertEqual(f.selections.count, 1); XCTAssertNil(editor.notice)
            if operation == 3 {
                let scans = f.provider.scanCount
                editor.refresh(); editor.folderPicked(f.root); editor.choose(a.identifier)
                XCTAssertEqual(f.provider.scanCount, scans); XCTAssertFalse(editor.loading)
            }
        }
    }

    func testRepeatedFolderReplacementClearsBothImportedDraftsAndBlocksStaleSaves() async throws {
        let f = Fixture(); defer { f.clean() }
        let first = try parsed(), second = try parsed("b"), a = f.file("A.NP3"), b = f.file("B.NP3")
        try f.store.save(.transfer, recipe: first.recipe, source: a.identifier)
        try f.store.save(.local, recipe: second.recipe, source: b.identifier)
        try f.store.rememberSource(a.identifier, sha256: first.sourceSha256, presetID: first.recipe.preset.id)
        let transfer = f.editor(initial: first.recipe), local = f.editor(.local, initial: second.recipe)
        let rootB = URL(fileURLWithPath: "/np3-fixture/b/", isDirectory: true)
        let c = f.file("C.NP3", root: rootB); f.provider.files = [c]
        transfer.folderPicked(rootB); try await settle(transfer)
        XCTAssertEqual(Set(f.unavailable.map(\.rawValue)), Set(["transfer", "local"]))
        XCTAssertNil(transfer.selectedRecipe); XCTAssertNil(local.selectedRecipe)
        XCTAssertEqual(transfer.files, [c]); XCTAssertTrue(local.files.isEmpty)
        XCTAssertEqual(local.folder, rootB); XCTAssertNil(f.store.restore(.transfer)); XCTAssertNil(f.store.restore(.local))
        XCTAssertNil(f.store.sourceHints().knownPresetID(a.identifier))
        XCTAssertFalse(try f.store.save(.transfer, recipe: first.recipe, source: a.identifier))
        XCTAssertFalse(try f.store.save(.local, recipe: second.recipe, source: nil))
        let built = try XCTUnwrap(TestPhotoFilterCatalog.np3Presets.first)
        let builtin = PhotoNp3Recipe(preset: .init(id: built.id, name: built.name), parameters: .flexible(built.parameters))
        transfer.resetSelection(builtin, source: c.identifier); local.resetSelection(builtin, source: c.identifier)
        XCTAssertTrue(try f.store.save(.transfer, recipe: builtin, source: c.identifier))
        try f.store.save(.local, recipe: builtin, source: c.identifier)
        f.provider.files = []
        transfer.folderPicked(URL(fileURLWithPath: "/np3-fixture/c/", isDirectory: true)); try await settle(transfer)
        XCTAssertNil(transfer.selectedRecipe); XCTAssertNil(local.selectedRecipe)
        XCTAssertNil(local.selectedSource); XCTAssertNil(f.store.restore(.local))
        XCTAssertEqual(f.unavailable.count, 4)
    }

    func testSameFolderAndFailedOrInactiveReplacementKeepRolesAndSourceHints() async throws {
        let (f, editor, a, recipe) = try await selectedFixture(); defer { f.clean() }
        try f.store.save(.transfer, recipe: recipe.recipe, source: a.identifier)
        editor.folderPicked(f.root); try await nextRead(f.provider).complete(.success(recipe)); try await settle(editor)
        XCTAssertTrue(f.unavailable.isEmpty); XCTAssertEqual(f.selections.count, 1)
        f.provider.error = .denied
        editor.folderPicked(URL(fileURLWithPath: "/elsewhere/", isDirectory: true)); try await settle(editor)
        XCTAssertEqual(f.store.folder, f.root); XCTAssertNil(editor.failure)
        XCTAssertEqual(editor.notice?.resource, "lut_folder_denied")
        XCTAssertEqual(f.store.restore(.transfer), recipe.recipe)
        f.provider.error = nil; f.active = false
        editor.folderPicked(URL(fileURLWithPath: "/elsewhere/", isDirectory: true)); try await settle(editor)
        XCTAssertEqual(f.store.folder, f.root); XCTAssertEqual(editor.selectedRecipe, recipe.recipe)
        XCTAssertEqual(f.store.sourceHints().knownPresetID(a.identifier), recipe.recipe.preset.id)
    }

    func testTimeoutEndsUIRequestAndDiscardsLateReadWithoutChangingSelection() async throws {
        let f = Fixture(); defer { f.clean() }
        let a = f.file("A.NP3"); f.provider.files = [a]
        let editor = f.editor(timeout: .milliseconds(80))
        editor.refresh(); try await settle(editor); editor.choose(a.identifier)
        let pending = try await nextRead(f.provider)
        try await settle(editor)
        XCTAssertEqual(editor.notice?.resource, "photo_np3_read_timeout")
        XCTAssertFalse(editor.loadingSelection); XCTAssertNil(editor.selectedRecipe)
        pending.complete(.success(try parsed())); await drain(f.queue)
        XCTAssertTrue(f.selections.isEmpty); XCTAssertNil(editor.selectedRecipe)
    }

    func testLateCancelledScanCannotCommitFolderBeforeNewerReplacement() async throws {
        let (f, editor, _, _) = try await selectedFixture(); defer { f.clean() }
        let b = URL(fileURLWithPath: "/np3-fixture/b/", isDirectory: true)
        let c = URL(fileURLWithPath: "/np3-fixture/c/", isDirectory: true)
        let gate = DispatchSemaphore(value: 0); defer { gate.signal() }
        var observed: [URL?] = []
        let observation = f.store.observeFolderChanges { observed.append(f.store.folder) }
        defer { observation.cancel() }
        f.provider.scanGate = gate; f.provider.files = [f.file("B.NP3", root: b)]
        editor.folderPicked(b); try await wait { f.provider.scanCount == 2 }
        f.provider.files = [f.file("C.NP3", root: c)]
        editor.folderPicked(c)
        XCTAssertEqual(f.store.folder, f.root)
        f.provider.scanGate = nil; gate.signal(); await drain(f.queue)
        XCTAssertEqual(observed, [c]); XCTAssertEqual(f.store.folder, c)
        XCTAssertEqual(editor.files.map(\.name), ["C.NP3"])
        XCTAssertEqual(f.unavailable, [.transfer])
    }

    func testQueuedScanTimeoutAndCancellationDoNotCancelAnotherEditorRead() async throws {
        for replacement in [false, true] {
            let f = Fixture(); defer { f.clean() }
            let a = f.file("A.NP3"); f.provider.files = [a]
            let first = f.editor(), second = f.editor(.local, timeout: .milliseconds(80))
            first.refresh(); try await settle(first); first.choose(a.identifier)
            let pending = try await nextRead(f.provider)
            if replacement { second.folderPicked(URL(fileURLWithPath: "/new/", isDirectory: true)) } else { second.refresh() }
            try await settle(second)
            XCTAssertEqual(second.failure, replacement ? nil : .read)
            XCTAssertEqual(second.notice?.resource, "photo_np3_read_timeout")
            XCTAssertTrue(first.loading)
            pending.complete(.success(try parsed())); await drain(f.queue)
            XCTAssertEqual(f.provider.scanCount, 1, "Timed out queued work must be physically removed")
            XCTAssertNotNil(first.selectedRecipe); XCTAssertNil(second.selectedRecipe)
            XCTAssertEqual(f.store.folder, f.root)
        }
    }

    func testResetWithoutMatchingSourceDoesNotBorrowAnotherRolesURI() async throws {
        let f = Fixture(); defer { f.clean() }
        let original = try parsed(), other = try parsed("b"), a = f.file("A.NP3")
        try f.store.save(.transfer, recipe: original.recipe, source: a.identifier)
        let local = f.editor(.local, initial: original.recipe)
        let mismatched = f.editor(initial: other.recipe)
        XCTAssertNil(local.selectedSource); XCTAssertNil(mismatched.selectedSource)
        local.resetSelection(original.recipe, source: a.identifier)
        local.resetSelection(other.recipe)
        XCTAssertNil(local.source(for: original.recipe.preset.id)); XCTAssertNil(local.selectedSource)
        XCTAssertEqual(f.store.restore(.transfer), original.recipe)
    }

    func testEditorReleaseCancelsItsRequestAndObserverWithoutRetainingHost() async throws {
        let f = Fixture(); defer { f.clean() }
        let a = f.file("A.NP3"); f.provider.files = [a]
        var editor: PhotoNp3EditorState? = f.editor(); weak var weakEditor = editor
        editor?.refresh(); try await settle(try XCTUnwrap(editor))
        editor?.choose(a.identifier); let pending = try await nextRead(f.provider)
        f.editors.removeAll(); editor = nil
        XCTAssertNil(weakEditor)
        f.store.replaceFolder(URL(fileURLWithPath: "/new/", isDirectory: true), bookmark: Data([2]))
        pending.complete(.success(try parsed())); await drain(f.queue)
        XCTAssertTrue(f.selections.isEmpty); XCTAssertTrue(f.unavailable.isEmpty)
    }
}

final class PhotoNp3FileProviderTests: XCTestCase {
    private final class Scopes: @unchecked Sendable {
        let lock = NSLock()
        var starts = 0, stops = 0
        var operations: DirectoryAccessOperations {
            .init(start: { [self] _ in lock.withLock { starts += 1 }; return true },
                  stop: { [self] _ in lock.withLock { stops += 1 } })
        }
    }
    private func sample(_ name: String = "vanilla") throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).resourceURL)
            .appendingPathComponent("PictureControlFixtures/flexible-color/\(name).NP3"))
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testRealDirectoryScanIsMetadataOnlyAndReadsFreshBoundedNP3WithBalancedScopes() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cat/Nested"), withIntermediateDirectories: true)
        let path = root.appendingPathComponent("Cat/A.NP3"), original = try sample()
        try original.write(to: path)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("B.np3"))
        try original.write(to: root.appendingPathComponent("Cat/Nested/ignored.NP3"))
        try original.write(to: root.appendingPathComponent("ignored.cube"))
        let scopes = Scopes(), source = PhotoNp3Source.fileProvider(operations: scopes.operations)
        let snapshot = try source.scan(.init(folder: root, previousFolder: nil, bookmark: nil, replacing: true), .init())
        XCTAssertEqual(snapshot.files.map(\.name), ["A.NP3", "B.np3"])
        XCTAssertEqual(snapshot.files.first?.category, "Cat")
        let file = try XCTUnwrap(snapshot.files.first)
        XCTAssertEqual(file.identifier, path.absoluteString)
        XCTAssertEqual(try source.read(file, snapshot.bookmark, .init()), try PhotoNp3Parser.parse(original))
        var changed = original; changed[changed.count - 1] ^= 1
        try changed.write(to: path)
        XCTAssertThrowsError(try source.read(file, snapshot.bookmark, .init()), "A known source must be read again")
        try Data(repeating: 0, count: PhotoNp3Parser.maximumBytes + 1).write(to: path)
        XCTAssertThrowsError(try source.read(file, snapshot.bookmark, .init())) { error in
            XCTAssertEqual((error as? PhotoNp3Error)?.reason, .tooLarge)
        }
        let cancelled = PresetIOQueue.Ticket(); cancelled.cancel()
        XCTAssertThrowsError(try source.read(file, snapshot.bookmark, cancelled)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(scopes.starts, 4); XCTAssertEqual(scopes.starts, scopes.stops)
    }

    func testBookmarkResolvedLocationDoesNotChangeStoredSourceIdentity() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try sample().write(to: root.appendingPathComponent("A.NP3"))
        let source = PhotoNp3Source.fileProvider(operations: Scopes().operations)
        let first = try source.scan(.init(folder: root, previousFolder: nil, bookmark: nil, replacing: true), .init())
        let identity = URL(fileURLWithPath: "/previous-container/filters/", isDirectory: true)
        for replacing in [false, true] {
            let request = PhotoNp3Source.ScanRequest(folder: replacing ? root : identity, previousFolder: identity,
                bookmark: first.bookmark, replacing: replacing)
            let refreshed = try source.scan(request, .init())
            XCTAssertEqual(refreshed.root, identity)
            let file = try XCTUnwrap(refreshed.files.first)
            XCTAssertEqual(file.identifier, identity.appendingPathComponent("A.NP3").absoluteString)
            XCTAssertEqual(try source.read(file, refreshed.bookmark, .init()), try PhotoNp3Parser.parse(sample()))
        }
    }

    func testFinalFileURIOrderIsUsedAfterEscapingDuplicateFilenames() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for category in ["\"", "$"] {
            let folder = root.appendingPathComponent(category, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("same.np3"))
        }
        let source = PhotoNp3Source.fileProvider(operations: Scopes().operations)
        let result = try source.scan(.init(folder: root, previousFolder: nil, bookmark: nil, replacing: true), .init())
        XCTAssertEqual(result.files.map(\.category), ["$", "\""])
        XCTAssertEqual(result.files.map(\.identifier), result.files.map(\.identifier).sorted {
            $0.utf16.lexicographicallyPrecedes($1.utf16)
        })
    }

    func testDeniedInvalidBookmarkTraversalAndPostLeaseCancellationFailCleanly() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try sample().write(to: root.appendingPathComponent("A.NP3"))
        let scopes = Scopes(), source = PhotoNp3Source.fileProvider(operations: scopes.operations)
        let prepared = try source.scan(.init(folder: root, previousFolder: nil, bookmark: nil, replacing: true), .init())
        let file = try XCTUnwrap(prepared.files.first)
        XCTAssertThrowsError(try source.read(file, Data([0]), .init()))
        let traversal = PresetFile(identifier: file.identifier, name: "bad", relativePath: "../outside.NP3", size: nil)
        XCTAssertThrowsError(try source.read(traversal, prepared.bookmark, .init()))
        let ticket = PresetIOQueue.Ticket()
        let operations = scopes.operations
        let cancelling = PhotoNp3Source.fileProvider(operations: .init(start: { url in
            let acquired = operations.start(url); ticket.cancel(); return acquired
        }, stop: operations.stop))
        XCTAssertThrowsError(try cancelling.read(file, prepared.bookmark, ticket)) { XCTAssertTrue($0 is CancellationError) }
        let scanTicket = PresetIOQueue.Ticket()
        let cancelledScan = PhotoNp3Source.fileProvider(operations: .init(start: { url in
            let acquired = operations.start(url); scanTicket.cancel(); return acquired
        }, stop: operations.stop))
        XCTAssertThrowsError(try cancelledScan.scan(.init(folder: root, previousFolder: nil, bookmark: nil, replacing: true), scanTicket)) {
            XCTAssertTrue($0 is CancellationError)
        }
        let denied = PhotoNp3Source.fileProvider(operations: .init(start: { _ in false }, stop: { _ in XCTFail("Unowned scope released") }))
        XCTAssertThrowsError(try denied.read(file, prepared.bookmark, .init())) { XCTAssertEqual($0 as? RemoteLUTFolderAccessError, .denied) }
        XCTAssertEqual(scopes.starts, 4); XCTAssertEqual(scopes.starts, scopes.stops)
    }
}
