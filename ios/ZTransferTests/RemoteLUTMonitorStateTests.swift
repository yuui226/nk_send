import XCTest
import Metal
import MetalKit
import SwiftUI
import Combine
@testable import ZTransfer

@MainActor final class RemoteLUTMonitorStateTests: XCTestCase {
    private func lut() -> CubeLUT {
        try! CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
    }

    func testOnlyPresentedCandidateReplacesActiveAndFailurePreservesIt() {
        let state = RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: UserDefaults(suiteName: "lut-monitor-test")!))
        state.environment(movie: false, available: true, visible: true)
        let first = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        let second = RemoteLUTFile(identifier: "b", name: "b.cube", relativePath: "b.cube", size: nil)
        let id1 = state.beginSelection(first)!; state.loaded(first, lut: lut(), generation: id1)
        XCTAssertNil(state.active); state.presented(generation: id1); XCTAssertEqual(state.active?.file.identifier, "a")
        let id2 = state.beginSelection(second)!; state.failed(generation: id2, reason: "read")
        XCTAssertEqual(state.active?.file.identifier, "a")
    }
    func testEnvironmentInvalidatesOldModeAndPreservesIndependentSelections() {
        let suite = "lut-environment-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        preferences.setSelection("photo", movie: false)
        preferences.setSelection("movie", movie: true)
        let state = RemoteLUTMonitorState(preferences: preferences)
        let photo = RemoteLUTFile(identifier: "photo", name: "photo.cube", relativePath: "photo.cube", size: nil)
        state.environment(movie: false, available: true, visible: true)
        let pending = state.beginSelection(photo)!
        state.environment(movie: true, available: true, visible: true)
        state.loaded(photo, lut: lut(), generation: pending)
        state.presented(generation: pending)
        XCTAssertNil(state.active)
        XCTAssertNil(state.candidate)
        XCTAssertEqual(preferences.selection(movie: true), "movie")
        state.environment(movie: true, available: true, visible: false)
        XCTAssertNil(preferences.selection(movie: true))
        XCTAssertEqual(preferences.selection(movie: false), "photo")
    }

    func testRepeatedEnvironmentKeepsCandidateButSuspendAndCloseRejectLateCompletion() {
        let suite = "lut-suspend-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        let state = RemoteLUTMonitorState(preferences: preferences)
        let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        state.environment(movie: false, available: true, visible: true)
        let first = state.beginSelection(file)!
        state.loaded(file, lut: lut(), generation: first)
        state.environment(movie: false, available: true, visible: true)
        state.presented(generation: first)
        XCTAssertEqual(state.active?.file.identifier, "a")
        let pending = state.beginSelection(file)!
        state.suspendRendering()
        state.loaded(file, lut: lut(), generation: pending)
        state.presented(generation: pending)
        XCTAssertNil(state.active)
        XCTAssertEqual(preferences.selection(movie: false), "a")
        XCTAssertNil(state.beginSelection(file))
        state.environment(movie: false, available: true, visible: true)
        let closing = state.beginSelection(file)!
        state.close()
        state.loaded(file, lut: lut(), generation: closing)
        state.presented(generation: closing)
        state.environment(movie: false, available: true, visible: true)
        XCTAssertNil(state.beginSelection(file))
        XCTAssertNil(state.active)
        XCTAssertNil(state.candidate)
        XCTAssertEqual(preferences.selection(movie: false), "a")
    }

    func testGPUFailureRetriesOnceAndPreservesOldLayerUntilPresentation() {
        let suite = "lut-gpu-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        let state = RemoteLUTMonitorState(preferences: preferences)
        var notices: [String] = []
        state.onNotice = { notices.append($0) }
        state.environment(movie: false, available: true, visible: true)
        let first = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        let next = RemoteLUTFile(identifier: "b", name: "b.cube", relativePath: "b.cube", size: nil)
        let firstID = state.beginSelection(first)!
        state.loaded(first, lut: lut(), generation: firstID)
        XCTAssertEqual(state.loadingIdentifier, "a")
        XCTAssertNil(preferences.selection(movie: false))
        state.presented(generation: firstID)
        let nextID = state.beginSelection(next)!
        state.loaded(next, lut: lut(), generation: nextID)
        let original = state.candidate!
        state.renderFailed(original, reason: .gpu)
        XCTAssertEqual(state.candidate?.retry, 1)
        XCTAssertEqual(state.active?.file.identifier, "a")
        XCTAssertTrue(notices.isEmpty)
        state.renderFailed(original, reason: .gpu)
        XCTAssertNotNil(state.candidate, "Duplicate failure from old surface must be ignored")
        state.renderFailed(state.candidate!, reason: .gpu)
        XCTAssertNil(state.candidate)
        XCTAssertEqual(state.active?.file.identifier, "a")
        XCTAssertEqual(preferences.selection(movie: false), "a")
        XCTAssertEqual(notices, ["lut_gpu_failed"])
        state.presented(generation: nextID)
        XCTAssertEqual(state.active?.file.identifier, "a")
        state.renderFailed(state.active!, reason: .gpu)
        XCTAssertNil(state.active)
        XCTAssertEqual(preferences.selection(movie: false), "a")
    }

    func testUnsupportedColorDoesNotRetryOrOverwriteSavedSelection() {
        let suite = "lut-color-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        let state = RemoteLUTMonitorState(preferences: preferences)
        var notices: [String] = []
        state.onNotice = { notices.append($0) }
        state.environment(movie: true, available: true, visible: true)
        let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        let id = state.beginSelection(file)!
        state.loaded(file, lut: lut(), generation: id)
        state.renderFailed(state.candidate!, reason: .inputColor)
        XCTAssertNil(state.candidate)
        XCTAssertNil(state.active)
        XCTAssertNil(preferences.selection(movie: true))
        XCTAssertEqual(notices, ["lut_input_color_unsupported"])
    }

    func testPresentationGateRequiresBothSignalsAndRejectsLostSurfaceCallbacks() {
        for presentationFirst in [false, true] {
            var gate = RemoteLUTPresentationGate()
            let first = gate.begin()!
            XCTAssertNil(gate.begin())
            if presentationFirst {
                XCTAssertFalse(gate.present(first))
                XCTAssertTrue(gate.complete(first))
            } else {
                XCTAssertFalse(gate.complete(first))
                XCTAssertTrue(gate.present(first))
            }
            XCTAssertFalse(gate.complete(first))
            XCTAssertFalse(gate.present(first))
            let next = gate.begin()!
            XCTAssertFalse(gate.complete(next))
            XCTAssertFalse(gate.present(next), "A continuing surface acknowledges only once")
            let lost = gate.begin()!
            gate.invalidate()
            let replacement = gate.begin()!
            XCTAssertFalse(gate.accepts(lost), "Old GPU failures must not terminate the replacement surface")
            XCTAssertTrue(gate.accepts(replacement))
            XCTAssertFalse(gate.complete(lost))
            XCTAssertFalse(gate.present(lost))
            XCTAssertTrue(gate.inFlight)
            XCTAssertFalse(gate.present(replacement))
            XCTAssertTrue(gate.complete(replacement))
        }
    }

    func testOldSurfacePresentationCannotCommitRetry() {
        let suite = "lut-retry-presentation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        let state = RemoteLUTMonitorState(preferences: preferences)
        state.environment(movie: false, available: true, visible: true)
        let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        let id = state.beginSelection(file)!
        state.loaded(file, lut: lut(), generation: id)
        let failedLayer = state.candidate!
        state.renderFailed(failedLayer, reason: .gpu)
        state.presented(failedLayer)
        XCTAssertNil(state.active)
        XCTAssertNil(preferences.selection(movie: false))
        state.presented(state.candidate!)
        XCTAssertEqual(state.active?.retry, 1)
        XCTAssertEqual(preferences.selection(movie: false), "a")
    }

    func testQueuedLoadRunsOffMainAndDeadlineIncludesPresentation() async throws {
        let suite = "lut-queued-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        let table = lut()
        let state = RemoteLUTMonitorState(preferences: preferences, queue: LUTIOQueue(),
                                         timeout: .milliseconds(500), read: { _, _, ticket in
            XCTAssertFalse(Thread.isMainThread)
            try ticket.checkCancellation()
            return table
        })
        var notices: [String] = []
        state.onNotice = { notices.append($0) }
        state.environment(movie: false, available: true, visible: true)
        let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        state.select(file)
        for _ in 0..<40 {
            if state.candidate != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(state.candidate)
        XCTAssertEqual(state.loadingIdentifier, "a")
        XCTAssertNil(state.active)
        XCTAssertNil(preferences.selection(movie: false))
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertNil(state.candidate)
        XCTAssertNil(state.loadingIdentifier)
        XCTAssertEqual(notices, ["lut_read_timeout"])
        state.select(file)
        for _ in 0..<40 {
            if state.candidate != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let candidate = try XCTUnwrap(state.candidate)
        state.presented(candidate)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(preferences.selection(movie: false), "a")
        XCTAssertEqual(notices, ["lut_read_timeout"], "Presentation cancels the deadline")
        state.close()
    }

    func testCancelledUncooperativeReadCannotPublishAfterClose() async throws {
        let table = lut()
        let latch = LUTScanTestLatch()
        let state = RemoteLUTMonitorState(queue: LUTIOQueue(), timeout: .seconds(2), read: { _, _, _ in
            latch.wait()
            return table
        })
        state.environment(movie: false, available: true, visible: true)
        let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        state.select(file)
        for _ in 0..<300 {
            if latch.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(latch.started)
        for _ in 0..<300 {
            if state.failure == "timeout" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(state.loadingIdentifier)
        XCTAssertEqual(state.failure, "timeout")
        state.close()
        latch.release()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(state.candidate)
        XCTAssertNil(state.active)
    }

    func testFolderCommitIsTransactionalAndModesRestoreThroughQueue() async throws {
        let suite = "lut-folder-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        let access = RemoteLUTFolderAccess(defaults: defaults)
        let root = URL(fileURLWithPath: "/valid")
        let bad = URL(fileURLWithPath: "/denied")
        let photo = RemoteLUTFile(identifier: "photo", name: "p.cube", relativePath: "p.cube", size: nil)
        let movie = RemoteLUTFile(identifier: "movie", name: "m.cube", relativePath: "m.cube", size: nil)
        let table = lut()
        let state = RemoteLUTMonitorState(preferences: preferences, access: access, queue: LUTIOQueue(),
            scan: { replacement, _, ticket in
                XCTAssertFalse(Thread.isMainThread)
                try ticket.checkCancellation()
                if replacement == bad { throw RemoteLUTFolderAccessError.denied }
                return (root, .init(bookmark: Data([1]), files: [photo, movie]))
            }, read: { _, _, ticket in try ticket.checkCancellation(); return table })
        state.environment(movie: false, available: true, visible: true)
        state.refreshFolder(replacing: root)
        for _ in 0..<100 {
            if !state.scanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.folder, root)
        XCTAssertEqual(access.bookmarkData, Data([1]))
        preferences.setSelection(photo.identifier, movie: false)
        preferences.setSelection(movie.identifier, movie: true)
        state.environment(movie: true, available: true, visible: true)
        for _ in 0..<100 {
            if state.candidate != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.candidate?.file.identifier, "movie")
        state.presented(try XCTUnwrap(state.candidate))
        state.refreshFolder(replacing: bad)
        for _ in 0..<100 {
            if !state.scanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.folder, root)
        XCTAssertEqual(access.bookmarkData, Data([1]))
        XCTAssertEqual(state.active?.file.identifier, "movie")
        XCTAssertNil(state.folderFailure)
        XCTAssertEqual(preferences.selection(movie: false), "photo")
        state.environment(movie: false, available: true, visible: true)
        for _ in 0..<100 {
            if state.candidate != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.candidate?.file.identifier, "photo")
        state.presented(try XCTUnwrap(state.candidate))
        XCTAssertEqual(preferences.selection(movie: true), "movie")
        state.close()
    }

    func testMenuDismissalMutualExclusionAndSameSelectionCommitRules() {
        let suite = "lut-menu-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        let state = RemoteLUTMonitorState(preferences: preferences)
        var falseColor = true
        var closes = 0
        state.onCommit = { falseColor = false }
        state.onCloseMenu = { closes += 1 }
        state.environment(movie: false, available: true, visible: true)
        let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        let cancelled = state.beginSelection(file)!
        state.loaded(file, lut: lut(), generation: cancelled)
        XCTAssertTrue(falseColor)
        XCTAssertEqual(closes, 0)
        state.dismissMenu()
        state.presented(generation: cancelled)
        XCTAssertTrue(falseColor)
        XCTAssertNil(state.active)
        let id = state.beginSelection(file)!
        state.loaded(file, lut: lut(), generation: id)
        state.presented(try! XCTUnwrap(state.candidate))
        XCTAssertFalse(falseColor)
        XCTAssertEqual(closes, 1)
        let activeID = state.active?.id
        state.select(file)
        XCTAssertEqual(state.active?.id, activeID)
        XCTAssertNil(state.candidate)
        XCTAssertNil(state.loadingIdentifier)
        XCTAssertEqual(closes, 2)
        let automatic = state.beginSelection(file, manual: false)!
        state.dismissMenu()
        state.loaded(file, lut: lut(), generation: automatic)
        state.presented(generation: automatic)
        XCTAssertEqual(closes, 2, "Automatic restoration does not close the menu")
        state.turnOff()
        XCTAssertNil(state.active)
        XCTAssertNil(preferences.selection(movie: false))
        state.close()
    }

    func testRescanReloadsSameSizeOverwriteAndClearsDeletedModeSelections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.cube")
        func write(_ component: String, modified: TimeInterval) throws {
            try Data(("LUT_3D_SIZE 2\n" + String(repeating: "\(component) 0 0\n", count: 8)).utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
        }
        try write("0", modified: 100)
        let suite = "lut-rescan-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        let state = RemoteLUTMonitorState(preferences: preferences,
            access: RemoteLUTFolderAccess(defaults: defaults), queue: LUTIOQueue(),
            scan: { _, _, ticket in
                (root, .init(bookmark: Data([1]), files: try RemoteLUTFolderAccess.scanContents(root, checkCancelled: ticket.checkCancellation)))
            }, read: { _, file, ticket in
                try CubeLUTParser.parse(RemoteLUTFolderAccess.readBounded(root.appendingPathComponent(file.relativePath),
                                        checkCancelled: ticket.checkCancellation), checkCancelled: ticket.checkCancellation)
            })
        state.environment(movie: false, available: true, visible: true)
        state.refreshFolder(replacing: root)
        for _ in 0..<100 {
            if !state.scanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let original = try XCTUnwrap(state.files.first)
        XCTAssertEqual(original.modified, Date(timeIntervalSince1970: 100))
        state.select(original)
        for _ in 0..<100 {
            if state.candidate != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        state.presented(try XCTUnwrap(state.candidate))
        let originalDigest = state.active?.lut.digest
        try write("1", modified: 200)
        state.openMenu()
        for _ in 0..<100 {
            if state.candidate != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let replacement = try XCTUnwrap(state.candidate)
        XCTAssertEqual(replacement.file.size, original.size)
        XCTAssertNotEqual(replacement.lut.digest, originalDigest)
        XCTAssertEqual(state.active?.lut.digest, originalDigest, "Old LUT remains until replacement presents")
        state.presented(replacement)
        preferences.setSelection(original.identifier, movie: true)
        try FileManager.default.removeItem(at: url)
        state.openMenu()
        for _ in 0..<100 {
            if !state.scanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(state.files.isEmpty)
        XCTAssertNil(state.active)
        XCTAssertNil(preferences.selection(movie: false))
        XCTAssertNil(preferences.selection(movie: true))
        state.close()
    }

    func testExistingFolderErrorsDistinguishTransientReadFromLostAccess() async throws {
        for reason in [RemoteLUTFolderAccessError.read, .missing, .denied] {
            let suite = "lut-access-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = RemoteLUTPreferences(defaults: defaults)
            let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
            let root = URL(fileURLWithPath: "/root")
            let table = lut()
            let state = RemoteLUTMonitorState(preferences: preferences,
                access: RemoteLUTFolderAccess(defaults: defaults), queue: LUTIOQueue(),
                scan: { replacement, _, _ in
                    guard replacement != nil else { throw reason }
                    return (root, .init(bookmark: Data([1]), files: [file]))
                }, read: { _, _, _ in table })
            state.environment(movie: false, available: true, visible: true)
            state.refreshFolder(replacing: root)
            for _ in 0..<100 {
                if !state.scanning { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            state.select(file)
            for _ in 0..<100 {
                if state.candidate != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            state.presented(try XCTUnwrap(state.candidate))
            preferences.setSelection("a", movie: true)
            state.openMenu()
            for _ in 0..<100 {
                if !state.scanning { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(state.folderFailure)
            if reason == .read {
                XCTAssertEqual(state.active?.file.identifier, "a")
                XCTAssertEqual(preferences.selection(movie: false), "a")
                XCTAssertEqual(preferences.selection(movie: true), "a")
            } else {
                XCTAssertNil(state.active)
                XCTAssertNil(preferences.selection(movie: false))
                XCTAssertNil(preferences.selection(movie: true))
            }
            state.close()
        }
    }

    func testLateScanCannotReplaceNewFolderAndNewControllerRestoresSavedMode() async throws {
        let suite = "lut-late-scan-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        let access = RemoteLUTFolderAccess(defaults: defaults)
        let old = URL(fileURLWithPath: "/old")
        let newest = URL(fileURLWithPath: "/new")
        let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        let latch = LUTScanTestLatch()
        let table = lut()
        let state = RemoteLUTMonitorState(preferences: preferences, access: access, queue: LUTIOQueue(),
            scan: { replacement, _, _ in
                if replacement == old { latch.wait() }
                let root = replacement ?? newest
                return (root, .init(bookmark: Data(root.path.utf8), files: [file]))
            }, read: { _, _, _ in table })
        state.environment(movie: false, available: true, visible: true)
        state.refreshFolder(replacing: old)
        for _ in 0..<100 {
            if latch.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(latch.started)
        state.refreshFolder(replacing: newest)
        latch.release()
        for _ in 0..<100 {
            if !state.scanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.folder, newest)
        XCTAssertEqual(access.bookmarkData, Data(newest.path.utf8))
        preferences.setSelection("a", movie: true)
        state.close()
        let restored = RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: defaults),
            access: RemoteLUTFolderAccess(defaults: defaults), queue: LUTIOQueue(),
            scan: { replacement, bookmark, _ in
                XCTAssertNil(replacement)
                XCTAssertEqual(bookmark, Data(newest.path.utf8))
                return (newest, .init(bookmark: bookmark!, files: [file]))
            }, read: { _, _, _ in table })
        restored.environment(movie: true, available: true, visible: true)
        for _ in 0..<100 {
            if restored.candidate != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(restored.folder, newest)
        XCTAssertEqual(restored.candidate?.file.identifier, "a")
        XCTAssertNil(restored.active)
        restored.presented(try XCTUnwrap(restored.candidate))
        XCTAssertEqual(restored.active?.file.identifier, "a")
        restored.close()
    }

    func testScanDeadlineKeepsFolderAndOnlyMarksExistingFolderReadFailure() async throws {
        for replacing in [false, true] {
            let suite = "lut-scan-timeout-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = RemoteLUTPreferences(defaults: defaults)
            let access = RemoteLUTFolderAccess(defaults: defaults)
            let root = URL(fileURLWithPath: "/saved")
            let slow = URL(fileURLWithPath: "/slow")
            let state = RemoteLUTMonitorState(preferences: preferences, access: access,
                queue: LUTIOQueue(), timeout: .seconds(1), scan: { replacement, _, _ in
                    if replacement != root { Thread.sleep(forTimeInterval: 1.5) }
                    return (replacement ?? root, .init(bookmark: Data([replacement == root ? 1 : 2]), files: []))
                })
            state.environment(movie: false, available: true, visible: true)
            state.refreshFolder(replacing: root)
            for _ in 0..<200 {
                if !state.scanning { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(state.folder, root)
            preferences.setSelection("saved", movie: false)
            state.refreshFolder(replacing: replacing ? slow : nil)
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertFalse(state.scanning)
            XCTAssertEqual(state.folderFailure, replacing ? nil : .read)
            XCTAssertEqual(state.failure, "timeout")
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(access.bookmarkData, Data([1]))
            XCTAssertEqual(state.folder, root)
            XCTAssertEqual(preferences.selection(movie: false), "saved")
            state.close()
        }
    }

    func testSharedQueueKeepsOnlyNewestSelectionAfterOldPageCloses() async throws {
        let suite = "lut-quick-switch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = LUTIOQueue()
        let latch = LUTScanTestLatch()
        let log = LUTReadTestLog()
        let table = lut()
        let read: @Sendable (Data?, RemoteLUTFile, LUTIOQueue.Ticket) throws -> CubeLUT = { _, file, _ in
            log.append(file.identifier)
            if file.identifier == "a" { latch.wait() }
            return table
        }
        let old = RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: defaults), queue: queue, read: read)
        let newest = RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: defaults), queue: queue, read: read)
        let files = ["a", "b", "c"].map { RemoteLUTFile(identifier: $0, name: "\($0).cube", relativePath: "\($0).cube", size: nil) }
        old.environment(movie: false, available: true, visible: true)
        old.select(files[0])
        for _ in 0..<100 {
            if latch.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(latch.started)
        old.close()
        newest.environment(movie: true, available: true, visible: true)
        newest.select(files[1])
        newest.select(files[2])
        XCTAssertEqual(log.values, ["a"], "Cancellation must not spawn another worker while old provider blocks")
        latch.release()
        for _ in 0..<100 {
            if newest.candidate != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(log.values, ["a", "c"])
        XCTAssertNil(old.candidate)
        XCTAssertNil(old.active)
        XCTAssertEqual(newest.candidate?.file.identifier, "c")
        newest.presented(try XCTUnwrap(newest.candidate))
        XCTAssertEqual(newest.active?.file.identifier, "c")
        newest.close()
    }

    func testPanelStatusAndVisibleNoticesCoverUnavailableAndOff() {
        let noFolder = RemoteLUTPanelStatus(hasFolder: false, failure: nil, scanning: false, empty: true)
        XCTAssertEqual(noFolder.folderAction, "lut_folder")
        XCTAssertEqual(noFolder.guidance, "lut_choose_hint")
        XCTAssertTrue(noFolder.showMonitorOnly)
        XCTAssertEqual(RemoteLUTPanelStatus(hasFolder: true, failure: nil, scanning: true, empty: true).guidance, "lut_reading_folder")
        XCTAssertEqual(RemoteLUTPanelStatus(hasFolder: true, failure: nil, scanning: false, empty: true).guidance, "lut_folder_empty")
        for failure in [RemoteLUTFolderFailure.missing, .denied, .read, .tooMany] {
            let status = RemoteLUTPanelStatus(hasFolder: true, failure: failure, scanning: false, empty: false)
            XCTAssertNotNil(status.guidance)
            XCTAssertEqual(status.accessible, failure != .missing && failure != .denied)
            XCTAssertEqual(status.folderAction, "lut_folder")
        }
        let state = RemoteLUTMonitorState()
        var closed = false
        state.onCloseMenu = { closed = true }
        state.environment(movie: false, available: false, visible: true)
        let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        state.select(file)
        XCTAssertEqual(state.noticeResource, "lut_frame_unavailable")
        XCTAssertFalse(closed)
        state.chooseOff()
        XCTAssertTrue(closed)
        XCTAssertNil(state.active)
        state.close()
    }

    func testFolderToMetalSelectionPersistsAcrossModesReentryAndBackground() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, color) in [("photo", "1 0 0"), ("movie", "0 0 1")] {
            try Data(("LUT_3D_SIZE 2\n" + String(repeating: "\(color)\n", count: 8)).utf8)
                .write(to: root.appendingPathComponent("\(name).cube"))
        }
        let suite = "lut-full-path-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteLUTPreferences(defaults: defaults)
        // Local temporary fixtures need no provider grant; all bookmark/scan/read/
        // parse/cache operations are production code, with scope admission injected.
        let scope = DirectoryAccessOperations(start: { _ in true }, stop: { _ in })
        func makeState() -> RemoteLUTMonitorState {
            RemoteLUTMonitorState(preferences: preferences, access: RemoteLUTFolderAccess(defaults: defaults),
                queue: LUTIOQueue(), scan: { replacement, bookmark, ticket in
                    guard let folder = replacement ?? RemoteLUTFolderAccess.resolveBookmark(bookmark) else {
                        throw RemoteLUTFolderAccessError.missing
                    }
                    return (folder, try RemoteLUTFolderAccess.prepareFolder(folder, operations: scope,
                                                                            checkCancelled: ticket.checkCancellation))
                }, read: { bookmark, file, ticket in
                    try RemoteLUTFolderAccess.parseBookmark(bookmark, file: file, operations: scope,
                                                           checkCancelled: ticket.checkCancellation)
                })
        }
        func candidate(_ state: RemoteLUTMonitorState) async throws -> RemoteLUTLayer {
            for _ in 0..<300 {
                if let layer = state.candidate { return layer }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try XCTUnwrap(state.candidate, "Selection failed: \(state.noticeResource ?? "none")")
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func renderAndConfirm(_ state: RemoteLUTMonitorState, layer: RemoteLUTLayer, expected: [UInt8]) throws {
            let renderer = try RemoteLUTMetalRenderer(device: device)
            try renderer.setLUT(layer.lut)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .renderTarget]
            let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            [UInt8(0),255,0,255].withUnsafeBytes {
                source.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4)
            }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try renderer.encode(source: source, destination: output, commandBuffer: command)
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var actual = [UInt8](repeating: 0, count: 4)
            actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0) }
            XCTAssertEqual(actual, expected)
            var gate = RemoteLUTPresentationGate()
            let frame = try XCTUnwrap(gate.begin())
            XCTAssertFalse(gate.complete(frame))
            XCTAssertTrue(gate.present(frame)) // Model signal; not a real drawable/UI assertion.
            state.presented(layer)
        }
        let first = makeState()
        first.environment(movie: false, available: false, visible: true)
        first.refreshFolder(replacing: root)
        for _ in 0..<300 {
            if !first.scanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let photo = try XCTUnwrap(first.files.first { $0.name == "photo.cube" })
        let movie = try XCTUnwrap(first.files.first { $0.name == "movie.cube" })
        first.select(photo)
        XCTAssertEqual(first.noticeResource, "lut_frame_unavailable")
        first.environment(movie: false, available: true, visible: true)
        first.select(photo)
        let photoLayer = try await candidate(first)
        XCTAssertNil(preferences.selection(movie: false))
        try renderAndConfirm(first, layer: photoLayer, expected: [0,0,255,255])
        first.environment(movie: true, available: true, visible: true)
        XCTAssertNil(first.active)
        first.select(movie)
        try renderAndConfirm(first, layer: await candidate(first), expected: [255,0,0,255])
        first.close()
        let restored = makeState()
        restored.environment(movie: true, available: true, visible: true)
        try renderAndConfirm(restored, layer: await candidate(restored), expected: [255,0,0,255])
        restored.suspendRendering()
        XCTAssertNil(restored.active)
        XCTAssertEqual(preferences.selection(movie: true), movie.identifier)
        restored.environment(movie: true, available: true, visible: true)
        try renderAndConfirm(restored, layer: await candidate(restored), expected: [255,0,0,255])
        restored.environment(movie: true, available: true, visible: false)
        XCTAssertNil(preferences.selection(movie: true))
        XCTAssertEqual(preferences.selection(movie: false), photo.identifier)
        restored.environment(movie: false, available: true, visible: true)
        try renderAndConfirm(restored, layer: await candidate(restored), expected: [0,0,255,255])
        restored.close()
    }

}

private final class LUTScanTestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private let semaphore = DispatchSemaphore(value: 0)
    var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func wait() {
        lock.lock(); entered = true; lock.unlock()
        _ = semaphore.wait(timeout: .now() + 10)
    }
    func release() { semaphore.signal() }
}

private final class LUTReadTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    func append(_ value: String) { lock.lock(); entries.append(value); lock.unlock() }
}

@MainActor
final class RemoteLUTPanelPerformanceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "lut-performance-\(UUID())"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }

    private func table(_ color: String = "1 0 0") throws -> CubeLUT {
        try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "\(color)\n", count: 8)).utf8))
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    func testIdleCancellationDoesNotPublishButStillPersistsAndRejectsStaleWork() {
        let preferences = RemoteLUTPreferences(defaults: defaults())
        let state = RemoteLUTMonitorState(preferences: preferences)
        state.environment(movie: false, available: true, visible: true)
        var updates = 0
        let observation = state.objectWillChange.sink { updates += 1 }
        for _ in 0..<120 {
            preferences.setSelection("stale", movie: false)
            state.turnOff()
            state.prepareFolderPicker()
            state.dismissMenu()
            XCTAssertNil(preferences.selection(movie: false))
        }
        XCTAssertEqual(updates, 0)
        var notices = 0
        state.onNotice = { _ in notices += 1 }
        state.scanFailed(.read)
        let firstFailure = updates
        for _ in 0..<120 { state.scanFailed(.read) }
        XCTAssertEqual(updates, firstFailure)
        XCTAssertEqual(notices, 121, "Repeated error events still reach the shared hint host")
        let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: 10)
        let old = state.beginSelection(file)!
        state.prepareFolderPicker()
        let afterCancel = updates
        state.loaded(file, lut: try! table(), generation: old)
        state.presented(generation: old)
        XCTAssertEqual(updates, afterCancel)
        XCTAssertNil(state.active)
        state.close()
        observation.cancel()
    }

    func testUnchangedLargeScanReusesMetadataIndexAndCategorySelection() async throws {
        let defaults = defaults()
        let preferences = RemoteLUTPreferences(defaults: defaults)
        let access = RemoteLUTFolderAccess(defaults: defaults)
        let files = (0..<10_000).map { n in
            RemoteLUTFile(identifier: "\(n)", name: String(format: "%05d.cube", n),
                          relativePath: "C\(n % 10)/\(n).cube", size: 100, modified: Date(timeIntervalSince1970: 1))
        }
        let source = LUTPerformanceScanSource(Array(files.reversed()) + [
            RemoteLUTFile(identifier: "bad", name: "bad.cube", relativePath: "a/b/bad.cube", size: 1)])
        let state = RemoteLUTMonitorState(preferences: preferences, access: access, queue: LUTIOQueue(),
            scan: { replacement, _, ticket in
                XCTAssertFalse(Thread.isMainThread)
                try ticket.checkCancellation()
                return (replacement ?? URL(fileURLWithPath: "/lut-fixture"),
                        .init(bookmark: Data([1, 2, 3]), files: source.read()))
            })
        defer { state.close() }
        state.refreshFolder(replacing: URL(fileURLWithPath: "/lut-fixture"))
        try await waitFor { !state.scanning }
        XCTAssertEqual(state.files, files)
        let catalog = state.catalog
        let group = try XCTUnwrap(catalog.filesByCategory["C8"])
        let address = group.withUnsafeBufferPointer { $0.baseAddress }
        var selection = PhotoLUTCategorySelection()
        selection.reconcile(catalog: catalog, selected: "9999")
        XCTAssertEqual(selection.category, "C9")
        selection.category = "C8"
        var changes = 0
        let observer = state.$files.dropFirst().sink { _ in changes += 1 }
        defer { observer.cancel() }
        for _ in 0..<4 {
            state.refreshFolder()
            try await waitFor { !state.scanning }
            XCTAssertTrue(state.catalog === catalog)
        }
        for _ in 0..<120 {
            selection.reconcile(catalog: state.catalog, selected: "9999")
            XCTAssertEqual(selection.category, "C8", "Refresh must preserve the browsed category")
            XCTAssertEqual(state.catalog.filesByCategory["C8"]?.withUnsafeBufferPointer { $0.baseAddress }, address)
        }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(access.bookmarkData, Data([1, 2, 3]))
        var changed = files
        changed[0].modified = Date(timeIntervalSince1970: 2)
        source.replace(changed)
        state.refreshFolder()
        try await waitFor { !state.scanning }
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(state.catalog === catalog)
        XCTAssertEqual(state.catalog.filesByIdentifier["0"]?.modified, changed[0].modified)
        selection.reconcile(catalog: state.catalog, selected: "1")
        XCTAssertEqual(selection.category, "C1")
        source.replace(files.filter { $0.category != "C1" })
        state.refreshFolder()
        try await waitFor { !state.scanning }
        selection.reconcile(catalog: state.catalog, selected: "1")
        XCTAssertEqual(selection.category, "C0")
    }

    func testActualImageLeafCommitsWithoutRootUpdatesForCandidateOrReplacement() async throws {
        let state = RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: defaults()))
        let lifetime = RemoteLUTMonitorLifetime(state)
        state.environment(movie: false, available: true, visible: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.cgImage)
        let counts = Counts()
        let host = UIHostingController(rootView: ImageHarness(lifetime: lifetime, counts: counts, image: image))
        let window = try makeWindow(host)
        defer { state.close(); window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        let baseline = counts.root
        let file = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        let first = try XCTUnwrap(state.beginSelection(file))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(counts.root, baseline, "Pending selection does not rebuild the page")
        state.loaded(file, lut: try table(), generation: first)
        try await waitFor { state.active?.file.identifier == "a" }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(lifetime.isActive)
        XCTAssertGreaterThan(counts.root, baseline)
        XCTAssertEqual(findAll(MTKView.self, in: host.view).count, 1)
        let activeCount = counts.root
        let next = RemoteLUTFile(identifier: "b", name: "b.cube", relativePath: "b.cube", size: nil)
        let second = try XCTUnwrap(state.beginSelection(next))
        state.loaded(next, lut: try table("0 0 1"), generation: second)
        try await waitFor { state.active?.file.identifier == "b" }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(counts.root, activeCount, "New LUT is committed by the real image leaf, not a root rebuild")
        XCTAssertEqual(findAll(MTKView.self, in: host.view).count, 1)
        state.turnOff()
        try await waitFor { findAll(MTKView.self, in: host.view).isEmpty }
        XCTAssertFalse(lifetime.isActive)
        XCTAssertGreaterThan(counts.root, activeCount)
    }

    func testActualLargePanelKeepsScrollPositionDuringLoadingAndUnchangedRefresh() async throws {
        let defaults = defaults()
        let files = (0..<3_000).map { n in
            RemoteLUTFile(identifier: "\(n)", name: String(format: "%05d.cube", n), relativePath: "\(n).cube", size: 100)
        }
        let state = RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: defaults),
            access: RemoteLUTFolderAccess(defaults: defaults), queue: LUTIOQueue(),
            scan: { _, _, _ in (URL(fileURLWithPath: "/lut-list"), .init(bookmark: Data([1]), files: files)) })
        state.refreshFolder(replacing: URL(fileURLWithPath: "/lut-list"))
        try await waitFor { !state.scanning }
        state.environment(movie: false, available: true, visible: true)
        let selected = files[2_500]
        let request = try XCTUnwrap(state.beginSelection(selected))
        state.loaded(selected, lut: try table(), generation: request); state.presented(generation: request)
        let lifetime = RemoteLUTMonitorLifetime(state)
        let counts = Counts()
        let host = UIHostingController(rootView: PanelHarness(lifetime: lifetime, counts: counts))
        let window = try makeWindow(host)
        defer { state.close(); window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(400))
        let list = try XCTUnwrap(findAll(UICollectionView.self, in: host.view).first)
        XCTAssertEqual(list.numberOfItems(inSection: 0), 3_000)
        XCTAssertLessThan(list.visibleCells.count, 30)
        XCTAssertTrue(list.indexPathsForVisibleItems.contains(IndexPath(item: 2_500, section: 0)))
        list.setContentOffset(CGPoint(x: 0, y: list.contentOffset.y + 100), animated: false)
        try await Task.sleep(for: .milliseconds(50))
        let offset = list.contentOffset.y
        let visible = Set(list.indexPathsForVisibleItems)
        let parentBodies = counts.root
        let pending = try XCTUnwrap(state.beginSelection(files[2_510]))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(counts.root, parentBodies)
        XCTAssertEqual(list.contentOffset.y, offset, accuracy: 1)
        XCTAssertEqual(Set(list.indexPathsForVisibleItems), visible)
        XCTAssertFalse(findAll(UIActivityIndicatorView.self, in: host.view).isEmpty)
        state.failed(generation: pending, reason: "read")
        state.openMenu()
        try await waitFor { !state.scanning }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(counts.root, parentBodies)
        XCTAssertEqual(list.contentOffset.y, offset, accuracy: 1)
        XCTAssertEqual(Set(list.indexPathsForVisibleItems), visible)
    }

    func testLifetimeDoesNotFormObservationCycle() {
        weak var weakState: RemoteLUTMonitorState?
        weak var weakLifetime: RemoteLUTMonitorLifetime?
        do {
            let state = RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: defaults()))
            let lifetime = RemoteLUTMonitorLifetime(state)
            weakState = state; weakLifetime = lifetime
            XCTAssertFalse(lifetime.isActive)
        }
        XCTAssertNil(weakLifetime)
        XCTAssertNil(weakState)
    }

    private final class Counts { var root = 0 }
    private struct ImageHarness: View {
        @ObservedObject var lifetime: RemoteLUTMonitorLifetime
        let counts: Counts
        let image: CGImage
        var body: some View {
            counts.root += 1
            return RemoteLUTImage(image: image, monitor: lifetime.monitor, source: Color.green)
                .frame(width: 180, height: 120)
        }
    }
    private struct PanelHarness: View {
        @ObservedObject var lifetime: RemoteLUTMonitorLifetime
        let counts: Counts
        var body: some View {
            counts.root += 1
            return RemoteLUTPanel(monitor: lifetime.monitor) {}
        }
    }
    private func makeWindow(_ controller: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = controller; window.makeKeyAndVisible()
        return window
    }
    private func findAll<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { findAll(type, in: $0) }
    }
}

private final class LUTPerformanceScanSource: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [RemoteLUTFile]
    init(_ files: [RemoteLUTFile]) { self.files = files }
    func read() -> [RemoteLUTFile] { lock.lock(); defer { lock.unlock() }; return files }
    func replace(_ value: [RemoteLUTFile]) { lock.lock(); files = value; lock.unlock() }
}
