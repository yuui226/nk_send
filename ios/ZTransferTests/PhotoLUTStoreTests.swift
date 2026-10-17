import XCTest
import UIKit
@testable import ZTransfer

@MainActor final class PhotoLUTStoreTests: XCTestCase {
    func testSnapshotWriteFailurePreservesSavedRoleAndDoesNotPublishNewLUT() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lut-write-failure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let saved = PhotoLUTStore(defaults: defaults, directory: root.appendingPathComponent("saved"))
        let old = try CubeLUTParser.parse(Data(("TITLE write-old\nLUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        let rejected = try CubeLUTParser.parse(Data(("TITLE write-rejected\nLUT_3D_SIZE 2\n" + String(repeating: "1 1 1\n", count: 8)).utf8))
        _ = try saved.selectLUT(old, name: "Old", sourceIdentifier: "old.cube")
        saved.setIntensity(42)
        saved.setAdjustments(.init(contrast: 20, saturation: -30))
        let original = try XCTUnwrap(saved.restoreSelection())
        let blocked = root.appendingPathComponent("blocked")
        try Data([1]).write(to: blocked)
        let failing = PhotoLUTStore(defaults: defaults, directory: blocked)
        XCTAssertThrowsError(try failing.selectLUT(rejected, name: "Rejected", sourceIdentifier: "new.cube"))
        XCTAssertEqual(failing.selectedIdentifier, "old.cube")
        XCTAssertEqual(failing.intensityPercent, 42)
        XCTAssertEqual(failing.adjustments, original.lutAdjustments)
        XCTAssertEqual(saved.restoreSelection(), original)
        XCTAssertFalse(PhotoLUTRuntime.contains(digest: rejected.digest))
        XCTAssertNil(PhotoLUTRuntime.table(digest: rejected.digest))
        try FileManager.default.removeItem(at: blocked)
        let accepted = try failing.selectLUT(rejected, name: "Retried", sourceIdentifier: "new.cube")
        XCTAssertEqual(failing.restoreSelection(), accepted)
        XCTAssertEqual(PhotoLUTRuntime.table(digest: rejected.digest), rejected)
    }

    func testMaximumSizeLUTsRespectDefaultBudgetAndActiveValuesSurviveEviction() throws {
        let cache = PhotoLUTResourceCache()
        let size = CubeLUTParser.maxSize
        XCTAssertEqual(size, 65)
        let valueCount = size * size * size * 3
        let tableBytes = valueCount * MemoryLayout<Float>.stride
        func table(_ id: Int) -> CubeLUT {
            CubeLUT(size: size, domainMin: .zero, domainMax: SIMD3(repeating: 1),
                    rgb: Array(repeating: Float(id) / 20, count: valueCount), digest: "large-\(id)")
        }
        let active = try XCTUnwrap(cache.acquire("large-1") { table(1) })
        for id in 2...20 {
            let loaded = try XCTUnwrap(cache.acquire("large-\(id)") { table(id) })
            XCTAssertEqual(loaded.rgb.last, Float(id) / 20)
            XCTAssertLessThanOrEqual(cache.retainedBytes, 8 * 1024 * 1024)
            XCTAssertEqual(cache.count, 2, "Two 65-cube Float arrays fit the iOS budget")
            XCTAssertEqual(cache.retainedBytes, 2 * tableBytes)
        }
        XCTAssertNil(cache.table("large-1"))
        XCTAssertEqual(active.rgb.count, valueCount)
        XCTAssertEqual(active.rgb.first, 0.05)
        XCTAssertEqual(active.rgb.last, 0.05)
        cache.removeAll()
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertEqual(active.rgb.last, 0.05, "Purging cannot invalidate an active immutable value")

        let uncached = PhotoLUTResourceCache(budget: tableBytes - 1)
        var reads = 0
        for _ in 0..<2 {
            let loaded = try XCTUnwrap(uncached.acquire("large-1") { reads += 1; return table(1) })
            XCTAssertEqual(loaded.rgb.count, valueCount)
            XCTAssertEqual(uncached.retainedBytes, 0)
            XCTAssertEqual(uncached.count, 0)
        }
        XCTAssertEqual(reads, 2, "An oversized table is returned to its caller but not retained")

        let entryLimited = PhotoLUTResourceCache()
        for id in 0..<20 {
            entryLimited.seed(CubeLUT(size: 2, domainMin: .zero, domainMax: SIMD3(repeating: 1),
                                     rgb: Array(repeating: 0, count: 24), digest: "small-\(id)"))
        }
        XCTAssertEqual(entryLimited.count, 16)
        XCTAssertNil(entryLimited.table("small-3"))
        XCTAssertNotNil(entryLimited.table("small-4"))
    }

    func testPruneDuringWriteHandoffRetainsFileUntilCancelledWriterReleasesOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lut-write-handoff-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let lut = try CubeLUTParser.parse(Data(("TITLE cancelled-write-handoff\nLUT_3D_SIZE 2\n" + String(repeating: "0.2 0.4 0.6\n", count: 8)).utf8))
        let store = PhotoLUTStore(defaults: defaults, directory: root)
        let file = root.appendingPathComponent("\(lut.digest).bin")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writer = Task.detached {
            try PhotoLUTStore.prepareSelection(lut, directory: root) {
                // The final cancellation checkpoint runs after atomic publication,
                // but before PreparedSelection is handed to the main actor.
                if FileManager.default.fileExists(atPath: file.path) {
                    entered.signal()
                    guard release.wait(timeout: .now() + 5) == .success else {
                        throw NSError(domain: "write-handoff-timeout", code: 1)
                    }
                    throw CancellationError()
                }
            }
        }
        let deadline = Date().addingTimeInterval(3)
        while !consumeSignal(entered) {
            guard Date() < deadline else { XCTFail("Writer did not reach publication checkpoint"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        await store.pruneSnapshots()
        XCTAssertEqual(PhotoLUTStore.readSnapshot(at: file, digest: lut.digest), lut)
        XCTAssertNil(store.selectedIdentifier)
        XCTAssertNil(store.restoreSelection())
        release.signal()
        do { _ = try await writer.value; XCTFail("Cancelled preparation must not publish a recipe") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected writer error: \(error)") }
        await store.pruneSnapshots()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(store.selectedIdentifier)
    }

    func testSnapshotPruningRetainsBothRolesActiveRecipesAndPreparedWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lut-prune-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func lut(_ name: String) throws -> CubeLUT {
            try CubeLUTParser.parse(Data(("TITLE \(name)\nLUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        }
        let camera = PhotoLUTStore(defaults: defaults, directory: root)
        let local = PhotoLUTStore(role: .local, defaults: defaults, directory: root)
        let old = try lut("queued"), current = try lut("camera"), localLUT = try lut("local"), pending = try lut("pending")
        var queued: PhotoFilterSelection? = try camera.selectLUT(old, name: "Queued", sourceIdentifier: "old")
        _ = try camera.selectLUT(current, name: "Camera", sourceIdentifier: "current")
        _ = try local.selectLUT(localLUT, name: "Local", sourceIdentifier: "local")
        var prepared: PhotoLUTStore.PreparedSelection? = try PhotoLUTStore.prepareSelection(pending, directory: root)
        let orphan = root.appendingPathComponent("orphan.bin")
        let unrelated = root.appendingPathComponent("notes.txt")
        try Data([1]).write(to: orphan); try Data([2]).write(to: unrelated)
        await camera.pruneSnapshots()
        for table in [old, current, localLUT, pending] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(table.digest).bin").path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        PhotoLUTRuntime.purgeMemoryCache()
        XCTAssertEqual(PhotoLUTRuntime.table(owner: try XCTUnwrap(queued?.snapshotOwner)), old)
        XCTAssertNotNil(prepared)
        queued = nil; prepared = nil
        await camera.pruneSnapshots()
        for table in [old, pending] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(table.digest).bin").path))
        }
        XCTAssertNotNil(camera.restoreSelection())
        XCTAssertNotNil(local.restoreSelection())
        PhotoLUTRuntime.purgeMemoryCache()
        XCTAssertFalse(PhotoLUTRuntime.contains(digest: old.digest))
    }

    func testRecipeCopiesOwnSnapshotWithoutRuntimePinningOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lut-owner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let lut = try CubeLUTParser.parse(Data(("TITLE recipe-owner\nLUT_3D_SIZE 2\n" + String(repeating: "0.3 0.2 0.1\n", count: 8)).utf8))
        let store = PhotoLUTStore(defaults: defaults, directory: root)
        var editor: PhotoFilterSelection? = try store.selectLUT(lut, name: "Owned", sourceIdentifier: "source")
        weak var owner = editor?.snapshotOwner
        XCTAssertNotNil(owner)
        var queued = editor
        editor = nil
        XCTAssertNotNil(owner, "A copied queue recipe retains the owner")
        let originalURL = root.appendingPathComponent("\(lut.digest).bin")
        PhotoLUTRuntime.registerSnapshot(digest: lut.digest, url: root.appendingPathComponent("missing.bin"))
        PhotoLUTRuntime.purgeMemoryCache()
        XCTAssertEqual(queued?.snapshotOwner?.url, originalURL)
        XCTAssertEqual(PhotoLUTRuntime.table(owner: try XCTUnwrap(queued?.snapshotOwner)), lut)
        do {
            let host = PhotoEffectsStore(defaults: defaults, scope: .cameraTransfer,
                premiumAccess: PremiumAccess(.lifetime), lutStore: store)
            PhotoLUTRuntime.registerSnapshot(digest: lut.digest, url: root.appendingPathComponent("other-missing.bin"))
            var draft = host.settings
            draft.selectedFilter = queued
            host.update(draft)
            XCTAssertTrue(host.settings.selectedFilter?.snapshotOwner === owner)
        }
        let data = try JSONEncoder().encode(try XCTUnwrap(queued))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("snapshotOwner"))
        XCTAssertEqual(try JSONDecoder().decode(PhotoFilterSelection.self, from: data), queued)
        queued = nil
        XCTAssertNil(owner, "The registry must not strongly retain obsolete recipe owners")
    }

    func testRestoredRecipeDefersSnapshotDecodingUntilCacheMiss() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lut-lazy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let lut = try CubeLUTParser.parse(Data(("TITLE lazy-restore\nLUT_3D_SIZE 2\n" + String(repeating: "0.1 0.2 0.3\n", count: 8)).utf8))
        let store = PhotoLUTStore(defaults: defaults, directory: root)
        let selection = try store.selectLUT(lut, name: "Lazy", sourceIdentifier: "missing-source")
        let url = root.appendingPathComponent("\(lut.digest).bin")
        let valid = try Data(contentsOf: url)
        PhotoLUTRuntime.purgeMemoryCache()
        let reopened = PhotoLUTStore(defaults: defaults, directory: root)
        XCTAssertEqual(reopened.restoreSelection(), selection)
        // Mutating after restore distinguishes metadata-only restoration from an
        // eager decoder that silently keeps a warm table.
        try Data([0]).write(to: url)
        XCTAssertNil(PhotoLUTRuntime.table(digest: lut.digest))
        XCTAssertEqual(reopened.restoreSelection(), selection)
        try valid.write(to: url)
        XCTAssertEqual(PhotoLUTRuntime.table(digest: lut.digest), lut)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(reopened.restoreSelection(), "Warm cache must not hide a missing snapshot")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertNil(reopened.restoreSelection(), "A directory is not a snapshot")
    }

    func testConcurrentCacheReadAndFailureRetry() async throws {
        let cache = PhotoLUTResourceCache()
        let lut = CubeLUT(size: 2, domainMin: .zero, domainMax: SIMD3(repeating: 1),
                          rgb: Array(repeating: 0, count: 24), digest: "slow")
        let fast = CubeLUT(size: 2, domainMin: .zero, domainMax: SIMD3(repeating: 1),
                           rgb: Array(repeating: 0, count: 24), digest: "fast")
        cache.seed(fast)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task.detached {
            cache.acquire("slow") {
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else { return nil }
                return lut
            }
        }
        let deadline = Date().addingTimeInterval(3)
        while !consumeSignal(entered) {
            guard Date() < deadline else { XCTFail("Reader did not start"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let duplicate = Task.detached {
            cache.acquire("slow") { XCTFail("Duplicate snapshot read"); return nil }
        }
        XCTAssertEqual(cache.acquire("fast") { XCTFail("Cached LUT reread"); return nil }, fast)
        release.signal()
        let firstResult = await first.value
        let duplicateResult = await duplicate.value
        XCTAssertEqual(firstResult, lut)
        XCTAssertEqual(duplicateResult, lut)
        cache.removeAll()
        XCTAssertNil(cache.acquire("slow") { nil })
        XCTAssertEqual(cache.acquire("slow") { lut }, lut)
    }

    func testBoundedCacheEvictionAndPrivateSnapshotReload() throws {
        func table(_ id: String) -> CubeLUT {
            CubeLUT(size: 2, domainMin: .zero, domainMax: SIMD3(repeating: 1),
                    rgb: Array(repeating: 0, count: 24), digest: id)
        }
        let cache = PhotoLUTResourceCache(budget: 192, maximumEntries: 2)
        cache.seed(table("a")); cache.seed(table("b"))
        XCTAssertNotNil(cache.table("a"))
        cache.seed(table("c"))
        XCTAssertNil(cache.table("b"))
        XCTAssertEqual(cache.retainedBytes, 192)
        XCTAssertEqual(cache.count, 2)
        let tooSmall = PhotoLUTResourceCache(budget: 95)
        tooSmall.seed(table("a"))
        XCTAssertEqual(tooSmall.count, 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lut-eviction-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let lut = try CubeLUTParser.parse(Data(("TITLE reload\nLUT_3D_SIZE 2\n" + String(repeating: "0.1 0.2 0.3\n", count: 8)).utf8))
        let store = PhotoLUTStore(defaults: defaults, directory: root)
        let selected = try store.selectLUT(lut, name: "Reload", sourceIdentifier: "missing-source")
        PhotoLUTRuntime.purgeMemoryCache()
        XCTAssertTrue(PhotoLUTRuntime.contains(digest: lut.digest))
        XCTAssertEqual(PhotoLUTRuntime.table(digest: lut.digest), lut)
        XCTAssertEqual(store.restoreSelection(), selected)
    }

    func testWorkerSnapshotReaderRejectsOversizedFileAndDoesNotPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lut = try CubeLUTParser.parse(Data(("TITLE unique-worker-read\nLUT_3D_SIZE 2\n" + String(repeating: "0.2 0.3 0.4\n", count: 8)).utf8))
        _ = try await Task.detached {
            try PhotoLUTStore.prepareSelection(lut, directory: root)
        }.value
        let url = root.appendingPathComponent("\(lut.digest).bin")
        let read = await Task.detached { PhotoLUTStore.readSnapshot(at: url, digest: lut.digest) }.value
        XCTAssertEqual(read, lut)
        XCTAssertNil(PhotoLUTRuntime.table(digest: lut.digest))
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(32 + 65 * 65 * 65 * 12 + 1))
        try writer.close()
        let oversized = await Task.detached { PhotoLUTStore.readSnapshot(at: url, digest: lut.digest) }.value
        XCTAssertNil(oversized)
        XCTAssertNil(PhotoLUTRuntime.table(digest: lut.digest))
    }

    func testLegacyCacheSnapshotMigratesOnlyAfterValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lut-migrate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Caches")
        let durable = root.appendingPathComponent("ApplicationSupport")
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        let old = PhotoLUTStore(defaults: defaults, directory: legacy)
        let selection = try old.selectLUT(lut, name: "Saved", sourceIdentifier: "unavailable")
        let migrated = PhotoLUTStore(defaults: defaults, directory: durable, legacyDirectory: legacy)
        let restored = try XCTUnwrap(migrated.restoreSelection())
        XCTAssertEqual(restored, selection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durable.appendingPathComponent("\(lut.digest).bin").path))
        let restoredOwner = try XCTUnwrap(restored.snapshotOwner)
        let migratedTable = await Task.detached { PhotoLUTRuntime.table(owner: restoredOwner) }.value
        XCTAssertEqual(migratedTable, lut)
        try FileManager.default.removeItem(at: legacy)
        XCTAssertEqual(PhotoLUTStore(defaults: defaults, directory: durable, legacyDirectory: legacy).restoreSelection(), selection)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([0, 1]).write(to: legacy.appendingPathComponent("\(lut.digest).bin"))
        let another = root.appendingPathComponent("Another")
        let corrupt = try XCTUnwrap(PhotoLUTStore(defaults: defaults, directory: another, legacyDirectory: legacy).restoreSelection())
        XCTAssertNil(PhotoLUTRuntime.table(owner: try XCTUnwrap(corrupt.snapshotOwner)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: another.appendingPathComponent("\(lut.digest).bin").path))
        // A valid old file must not be accepted when its durable directory cannot
        // be created. Retrying after the obstruction is removed must succeed.
        try Data(contentsOf: durable.appendingPathComponent("\(lut.digest).bin"))
            .write(to: legacy.appendingPathComponent("\(lut.digest).bin"))
        try Data([1]).write(to: another)
        let retryOwner = try XCTUnwrap(corrupt.snapshotOwner)
        let blocked = await Task.detached { PhotoLUTRuntime.table(owner: retryOwner) }.value
        XCTAssertNil(blocked)
        try FileManager.default.removeItem(at: another)
        let retried = await Task.detached { PhotoLUTRuntime.table(owner: retryOwner) }.value
        XCTAssertEqual(retried, lut)
        XCTAssertNotNil(PhotoLUTStore.readSnapshot(at: another.appendingPathComponent("\(lut.digest).bin"), digest: lut.digest))
        XCTAssertTrue(PhotoLUTStore(defaults: defaults).snapshotDirectory.path.contains("Application Support"))
    }

    func testCorruptSnapshotDomainsAndTrailingBytesNeverRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lut-corrupt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        let store = PhotoLUTStore(defaults: defaults, directory: directory)
        let selected = try store.selectLUT(lut, name: "Valid", sourceIdentifier: "valid")
        let path = directory.appendingPathComponent("\(lut.digest).bin")
        let valid = try Data(contentsOf: path)
        func replacing(_ data: Data, at offset: Int, with value: Float) -> Data {
            var copy = data
            var bits = value.bitPattern.bigEndian
            copy.replaceSubrange(offset..<offset + 4, with: withUnsafeBytes(of: &bits, Array.init))
            return copy
        }
        let zero = replacing(valid, at: 20, with: 0)
        let reversed = replacing(valid, at: 20, with: -1)
        let nan = replacing(valid, at: 8, with: .nan)
        let overflow = replacing(replacing(valid, at: 8, with: -3e38), at: 20, with: 3e38)
        let reciprocal = replacing(valid, at: 20, with: 3e38)
        let badColor = replacing(valid, at: 32, with: .infinity)
        for bad in [zero, reversed, nan, overflow, reciprocal, badColor, valid + Data([0]), Data(valid.dropLast())] {
            try bad.write(to: path)
            XCTAssertNil(store.restoreSnapshot(digest: lut.digest))
            XCTAssertEqual(store.restoreSelection(), selected, "Restore reads metadata; decoding remains lazy")
            XCTAssertEqual(store.selectedIdentifier, "valid")
            XCTAssertEqual(PhotoLUTRuntime.table(digest: lut.digest), lut)
        }
        try valid.write(to: path)
        XCTAssertEqual(store.restoreSelection(), selected)
    }

    func testBackgroundSelectionPreparationCannotChangeRoleUntilAccepted() async throws {
        let suite = "lut-prepare-cancel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let oldLUT = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        let newLUT = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "1 1 1\n", count: 8)).utf8))
        let store = PhotoLUTStore(defaults: defaults, directory: directory)
        let old = try store.selectLUT(oldLUT, name: "Old", sourceIdentifier: "old")
        let ticket = LUTIOQueue.Ticket()
        ticket.cancel()
        let cancelled = await Task.detached {
            Result { try PhotoLUTStore.prepareSelection(newLUT, directory: directory,
                                                        checkCancelled: ticket.checkCancellation) }
        }.value
        XCTAssertThrowsError(try cancelled.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(newLUT.digest).bin").path))
        XCTAssertEqual(store.restoreSelection(), old)
        let queue = LUTIOQueue()
        let request = LUTRequestController(queue: queue)
        let preparedSignal = DispatchSemaphore(value: 0)
        let returnSignal = DispatchSemaphore(value: 0)
        defer { returnSignal.signal() }
        request.submit(action: { ticket in
            let prepared = try PhotoLUTStore.prepareSelection(newLUT, directory: directory,
                                                               checkCancelled: ticket.checkCancellation)
            preparedSignal.signal()
            returnSignal.wait() // Snapshot exists, but result has not crossed to MainActor.
            return prepared
        }, onTimeout: { XCTFail("Unexpected timeout") }, deliver: { result in
            if case .success(let prepared) = result {
                _ = store.acceptSelection(prepared, name: "Late", sourceIdentifier: "late")
            }
            XCTFail("Cancelled prepared result must not be delivered")
        })
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !consumeSignal(preparedSignal) {
            guard ContinuousClock.now < deadline else { XCTFail("Preparation did not finish"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        request.cancel()
        XCTAssertFalse(request.loading)
        var drained = false
        queue.submit(action: { _ in true }, deliver: { _ in drained = true })
        returnSignal.signal()
        while !drained && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(drained)
        XCTAssertEqual(store.restoreSelection(), old)
        XCTAssertEqual(store.selectedIdentifier, "old")
        let prepared = try await Task.detached {
            try PhotoLUTStore.prepareSelection(newLUT, directory: directory)
        }.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(newLUT.digest).bin").path))
        XCTAssertEqual(store.restoreSelection(), old)
        XCTAssertEqual(store.selectedIdentifier, "old")
        let accepted = store.acceptSelection(prepared, name: "New", sourceIdentifier: "new")
        XCTAssertEqual(store.restoreSelection(), accepted)
        XCTAssertEqual(accepted.preset.id, "cube:\(newLUT.digest)")
    }

    private func consumeSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    func testLUTRequestTimeoutDoesNotStartAnotherReaderUntilBlockedWorkReturns() async throws {
        let queue = LUTIOQueue()
        let request = LUTRequestController(queue: queue)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var timedOut = false
        request.submit(timeout: .milliseconds(500), selectionIdentifier: "old", action: { _ in
            started.signal()
            release.wait() // Deliberately ignores cancellation, like a blocked provider.
            return 1
        }, onTimeout: { timedOut = true }, deliver: { _ in XCTFail("Timed-out result delivered") })
        XCTAssertEqual(request.pendingIdentifier, "old")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !consumeSignal(started) {
            guard ContinuousClock.now < deadline else { XCTFail("Worker did not start"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        while !timedOut && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(timedOut)
        XCTAssertFalse(request.loading)
        XCTAssertNil(request.pendingIdentifier)
        request.submit(selectionIdentifier: "superseded", action: { _ in
            XCTFail("Superseded pending request ran")
            return 2
        }, onTimeout: { XCTFail("Unexpected timeout") }, deliver: { _ in XCTFail("Superseded result delivered") })
        let nextStarted = DispatchSemaphore(value: 0)
        var accepted: Int?
        request.submit(selectionIdentifier: "latest", action: { _ in nextStarted.signal(); return 3 },
                       onTimeout: { XCTFail("Unexpected timeout") },
                       deliver: { accepted = try? $0.get() })
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(consumeSignal(nextStarted))
        XCTAssertTrue(request.loading)
        XCTAssertEqual(request.pendingIdentifier, "latest")
        release.signal()
        while accepted == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(accepted, 3)
        XCTAssertNil(request.pendingIdentifier)
        XCTAssertFalse(request.loading)
    }

    func testLUTIOQueueOwnerCancelsItsObsoletePendingAndActiveResults() async throws {
        let queue = LUTIOQueue()
        let gate = DispatchSemaphore(value: 0)
        let first = queue.submit(action: { _ in
            gate.wait()
            return 1
        }, deliver: { _ in XCTFail("Cancelled active result must not be delivered") })
        let replaced = queue.submit(action: { _ in
            XCTFail("Replaced pending work must not run")
            return 2
        }, deliver: { _ in XCTFail("Replaced pending result must not be delivered") })
        var result: Int?
        queue.submit(action: { ticket in
            try ticket.checkCancellation()
            return 3
        }, deliver: { result = try? $0.get() })
        XCTAssertFalse(replaced.isCancelled, "Other submissions must not cancel this owner")
        replaced.cancel()
        XCTAssertTrue(replaced.isCancelled)
        first.cancel()
        gate.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while result == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(result, 3)
    }

    func testSharedPresetQueueKeepsOtherOwnersFIFOAndDrainsCleanupAfterThrowingDelivery() async throws {
        enum Failure: Error { case callback }
        let queue = PresetIOQueue()
        let gate = DispatchSemaphore(value: 0)
        var delivered: [Int] = []
        let first = queue.submit(action: { _ in gate.wait(); return 1 }, deliver: { result in
            delivered.append(try result.get())
            queue.cleanup { throw Failure.callback }
            throw Failure.callback
        })
        queue.submit(action: { _ in 2 }, deliver: { delivered.append(try $0.get()) })
        queue.submit(action: { _ in 3 }, deliver: { delivered.append(try $0.get()) })
        XCTAssertFalse(first.isCancelled)
        gate.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while delivered.count < 3 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(delivered, [1, 2, 3])
    }

    func testSharedPresetQueueDiscardsCancelledAcceptedReadBeforeNextOwner() async throws {
        let queue = PresetIOQueue()
        let started = expectation(description: "Reader started")
        let discarded = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let first = queue.submit(action: { _ in
            started.fulfill(); gate.wait(); return 1
        }, discard: { _ in discarded.signal() }, deliver: { _ in XCTFail("Cancelled read delivered") })
        await fulfillment(of: [started], timeout: 3)
        first.cancel()
        var complete = false
        queue.submit(action: { _ in discarded.wait(timeout: .now() + 1) == .success }, deliver: {
            XCTAssertTrue(try $0.get()); complete = true
        })
        gate.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !complete && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(complete)
    }

    func testFolderPreparationDoesNotReplaceBookmarkUntilAccepted() throws {
        let suite = "lut-folder-transaction-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Old")
        let new = root.appendingPathComponent("New")
        for folder in [old, new] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data().write(to: new.appendingPathComponent("new.cube"))
        let access = RemoteLUTFolderAccess(defaults: defaults, scope: .photo)
        try access.save(old)
        let original = access.bookmarkData
        let operations = DirectoryAccessOperations(start: { _ in true }, stop: { _ in })
        let prepared = try RemoteLUTFolderAccess.prepareFolder(new, operations: operations)
        XCTAssertEqual(access.bookmarkData, original)
        XCTAssertEqual(prepared.files.map(\.relativePath), ["new.cube"])
        XCTAssertThrowsError(try RemoteLUTFolderAccess.prepareFolder(root.appendingPathComponent("Missing"), operations: operations))
        XCTAssertEqual(access.bookmarkData, original)
        XCTAssertThrowsError(try RemoteLUTFolderAccess.prepareFolder(new,
            operations: .init(start: { _ in false }, stop: { _ in }))) {
            XCTAssertEqual($0 as? RemoteLUTFolderAccessError, .denied)
        }
        XCTAssertEqual(access.bookmarkData, original)
        access.commit(prepared)
        XCTAssertEqual(access.resolve()?.standardizedFileURL, new.standardizedFileURL)
    }

    func testFolderFailureDistinguishesRootFromUnreadableChild() throws {
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let wrapped = NSError(domain: "Provider", code: 1, userInfo: [NSUnderlyingErrorKey: denied])
        XCTAssertEqual(RemoteLUTFolderAccess.folderFailure(wrapped, isRoot: true), .denied)
        XCTAssertEqual(RemoteLUTFolderAccess.folderFailure(wrapped, isRoot: false), .read)
        let missing = CocoaError(.fileReadNoSuchFile)
        XCTAssertEqual(RemoteLUTFolderAccess.folderFailure(missing, isRoot: true), .missing)
        XCTAssertEqual(RemoteLUTFolderAccess.folderFailure(missing, isRoot: false), .read)
        XCTAssertEqual(RemoteLUTFolderAccess.folderFailure(CocoaError(.fileReadUnknown), isRoot: true), .read)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        XCTAssertThrowsError(try RemoteLUTFolderAccess.scanContents(file)) {
            XCTAssertEqual($0 as? RemoteLUTFolderAccessError, .missing)
        }
    }

    func testLUTScanCountsAllEntriesAndStopsAtOneCategoryLevel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let category = root.appendingPathComponent("Category")
        let nested = category.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for relative in ["root.cube", ".hidden.txt", "plain.txt", "Category/child.CUBE", "Category/Nested/ignored.cube"] {
            try Data().write(to: root.appendingPathComponent(relative))
        }
        let files = try RemoteLUTFolderAccess.scanContents(root, entryLimit: 6)
        XCTAssertEqual(Set(files.map(\.relativePath)), ["root.cube", "Category/child.CUBE"])
        XCTAssertThrowsError(try RemoteLUTFolderAccess.scanContents(root, entryLimit: 5)) {
            XCTAssertEqual($0 as? RemoteLUTFolderAccessError, .tooMany)
        }
        var checks = 0
        XCTAssertThrowsError(try RemoteLUTFolderAccess.scanContents(root, checkCancelled: {
            checks += 1
            if checks == 3 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 3)
        XCTAssertThrowsError(try RemoteLUTFolderAccess.scanContents(root.appendingPathComponent("Missing"))) {
            XCTAssertEqual($0 as? RemoteLUTFolderAccessError, .missing)
        }
    }

    func testBoundedLUTReadRejectsGrowthAfterMetadataAndAcceptsExactLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([65]).write(to: url)
        var checks = 0
        XCTAssertThrowsError(try RemoteLUTFolderAccess.readBounded(url, checkCancelled: {
            checks += 1
            if checks == 2 {
                // Metadata was read while size was one byte. Grow before first read.
                let writer = try FileHandle(forWritingTo: url)
                defer { try? writer.close() }
                try writer.truncate(atOffset: UInt64(CubeLUTParser.maxBytes + 1))
            }
        })) { XCTAssertEqual($0 as? CubeLUTFailure, .tooLarge) }
        XCTAssertGreaterThan(checks, 3)
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(CubeLUTParser.maxBytes))
        try writer.close()
        XCTAssertEqual(try RemoteLUTFolderAccess.readBounded(url).count, CubeLUTParser.maxBytes)
    }

    func testBoundedLUTReadChecksActualSizeAndCancellation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data(repeating: 65, count: 128 * 1024 + 7)
        try bytes.write(to: url)
        XCTAssertEqual(try RemoteLUTFolderAccess.readBounded(url), bytes)
        var checks = 0
        XCTAssertThrowsError(try RemoteLUTFolderAccess.readBounded(url, checkCancelled: {
            checks += 1
            if checks == 3 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 3)
        // A sparse file exercises the production 32 MiB metadata boundary without
        // allocating an oversized Data value in the reader.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(CubeLUTParser.maxBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try RemoteLUTFolderAccess.readBounded(url)) {
            XCTAssertEqual($0 as? CubeLUTFailure, .tooLarge)
        }
    }

    func testLUTControlCommitsOnceCancelsAndAcceptsConsecutiveAccessibilitySteps() {
        let slider = PhotoLUTReleaseSlider.ReleaseSlider()
        slider.minimumValue = -100
        slider.maximumValue = 100
        slider.step = 5
        slider.savedValue = 0
        var commits: [Int] = []
        var previews: [Int?] = []
        slider.commit = { commits.append($0) }
        slider.preview = { previews.append($0) }
        slider.value = 23
        slider.changed()
        XCTAssertEqual(previews.last!, 25)
        XCTAssertTrue(commits.isEmpty)
        slider.cancelTracking(with: nil)
        XCTAssertEqual(slider.value, 0)
        XCTAssertTrue(commits.isEmpty)
        slider.value = 23
        slider.changed()
        slider.endTracking(nil, with: nil)
        slider.endTracking(nil, with: nil)
        XCTAssertEqual(commits, [25])
        slider.accessibilityIncrement()
        slider.accessibilityIncrement()
        slider.accessibilityDecrement()
        XCTAssertEqual(commits, [25, 30, 35, 30])
        slider.isEnabled = false
        slider.value = 70
        slider.endTracking(nil, with: nil)
        slider.accessibilityIncrement()
        XCTAssertEqual(commits, [25, 30, 35, 30])
        slider.isEnabled = true
        slider.savedValue = 100
        slider.accessibilityIncrement()
        XCTAssertEqual(commits.count, 4)
        slider.minimumValue = 2
        slider.step = 2
        slider.savedValue = 2
        slider.accessibilityDecrement()
        XCTAssertEqual(commits.count, 4)
    }

    func testLegacyRoleRestoreUsesSameFallbackForControlsAndRenderedSelection() throws {
        let suite = "lut-legacy-role-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        let store = PhotoLUTStore(defaults: defaults, directory: directory)
        try store.selectLUT(lut, name: "Legacy", sourceIdentifier: "source")
        store.setIntensity(42)
        store.setAdjustments(.init(contrast: 25, saturation: -30, highlights: 40, shadows: -50))
        let key = "photo_lut_selected_recipe"
        var recipe = try XCTUnwrap(defaults.dictionary(forKey: key))
        recipe.removeValue(forKey: "adjustments")
        recipe.removeValue(forKey: "intensity")
        defaults.set(recipe, forKey: key)
        defaults.set(90, forKey: "photo_lut_intensity")
        let reopened = PhotoLUTStore(defaults: defaults, directory: directory)
        let selected = try XCTUnwrap(reopened.restoreSelection())
        XCTAssertEqual(selected.intensityPercent, 42)
        XCTAssertEqual(reopened.intensityPercent, selected.intensityPercent)
        XCTAssertEqual(reopened.adjustments, selected.lutAdjustments)
        XCTAssertEqual(selected.lutAdjustments, .init(contrast: 25, saturation: -30, highlights: 40, shadows: -50))
        // An explicitly saved neutral role must not inherit newer digest edits.
        recipe["adjustments"] = ["contrast": 0]
        recipe["intensity"] = 64
        defaults.set(recipe, forKey: key)
        let neutral = PhotoLUTStore(defaults: defaults, directory: directory)
        XCTAssertTrue(neutral.adjustments.isNeutral)
        XCTAssertEqual(neutral.restoreSelection()?.lutAdjustments, neutral.adjustments)
        XCTAssertEqual(neutral.intensityPercent, 64)
    }

    func testOutputIdentityIncludesEveryLUTAdjustmentAndSurvivesSnapshotCoding() throws {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = false
        settings.photoFilterEnabled = true
        settings.selectedFilter = .init(preset: .init(id: "cube:test", name: "Test"), intensityPercent: 80)
        let original = androidPhotoFrameOutputName(sourceName: "a.jpg", settings: settings)
        var names = Set([original])
        for keyPath in [\LUTAdjustments.contrast, \.saturation, \.highlights, \.shadows] {
            var snapshot = settings
            snapshot.selectedFilter?.lutAdjustments[keyPath: keyPath] = 25
            let name = androidPhotoFrameOutputName(sourceName: "a.jpg", settings: snapshot)
            XCTAssertTrue(names.insert(name).inserted)
            let decoded = try JSONDecoder().decode(PhotoEffectsSettings.self, from: JSONEncoder().encode(snapshot))
            XCTAssertEqual(decoded.selectedFilter, snapshot.selectedFilter)
            XCTAssertEqual(androidPhotoFrameOutputName(sourceName: "a.jpg", settings: decoded), name)
        }
        XCTAssertEqual(androidPhotoFrameOutputName(sourceName: "a.jpg", settings: settings), original)
    }

    func testDigestMemoryMigratesSourceStrengthAndKeepsRoleSnapshotsIndependent() throws {
        let suite = "lut-adjustment-memory-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let black = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        let white = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "1 1 1\n", count: 8)).utf8))
        defaults.set(37, forKey: "strength:original")
        let camera = PhotoLUTStore(role: .camera, defaults: defaults, directory: directory)
        let local = PhotoLUTStore(role: .local, defaults: defaults, directory: directory)
        XCTAssertEqual(try camera.selectLUT(black, name: "A", sourceIdentifier: "original").intensityPercent, 38)
        camera.setAdjustments(.init(contrast: 25, saturation: -30, highlights: 40, shadows: -50))
        let cameraRecipe = try XCTUnwrap(camera.restoreSelection())
        let shared = try local.selectLUT(black, name: "A copy", sourceIdentifier: "another")
        XCTAssertEqual(shared.intensityPercent, 38)
        XCTAssertEqual(shared.lutAdjustments, cameraRecipe.lutAdjustments)
        local.setIntensity(99)
        local.setAdjustments(.init(contrast: -70))
        XCTAssertEqual(camera.restoreSelection(), cameraRecipe)
        XCTAssertEqual(camera.adjustments, cameraRecipe.lutAdjustments)
        let other = try local.selectLUT(white, name: "B", sourceIdentifier: "white")
        XCTAssertEqual(other.intensityPercent, 80)
        XCTAssertTrue(other.lutAdjustments.isNeutral)
        let again = try local.selectLUT(black, name: "A again", sourceIdentifier: "third")
        XCTAssertEqual(again.intensityPercent, 100)
        XCTAssertEqual(again.lutAdjustments.contrast, -70)
        let reopened = PhotoLUTStore(role: .camera, defaults: defaults, directory: directory)
        XCTAssertEqual(reopened.restoreSelection(), cameraRecipe)
        XCTAssertEqual(reopened.adjustments, cameraRecipe.lutAdjustments)
    }

    func testBothEffectsStoresRestoreRoleRecipeBeforeRendering() throws {
        let suite = "lut-host-restore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let snapshots = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: snapshots)
        }
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        for scope: PhotoEffectsStore.Scope in [.cameraTransfer, .localPhotos] {
            let role: PhotoLUTStore.Role = scope == .cameraTransfer ? .camera : .local
            let chooserStore = PhotoLUTStore(role: role, defaults: defaults, directory: snapshots)
            chooserStore.setIntensity(64)
            let selected = try chooserStore.selectLUT(lut, name: "Original display name", sourceIdentifier: "/unavailable/source.cube")
            let host = PhotoEffectsStore(defaults: defaults, scope: scope,
                premiumAccess: PremiumAccess(.lifetime),
                lutStore: PhotoLUTStore(role: role, defaults: defaults, directory: snapshots))
            XCTAssertEqual(host.settings.selectedFilter, selected)
            XCTAssertTrue(host.settings.photoFilterEnabled)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            let actual = try PhotoEffectsRenderer.render(image,
                settings: effectivePhotoEffectsSettings(host.settings, isPro: true))
            var unfiltered = host.settings
            unfiltered.photoFilterEnabled = false
            XCTAssertNotEqual(actual.pngData(), try PhotoEffectsRenderer.render(image,
                settings: effectivePhotoEffectsSettings(unfiltered, isPro: true)).pngData())
            var draft = host.settings
            disablePhotoLUTDraft(&draft, lutStore: chooserStore)
            host.updateFromEditor(draft)
            XCTAssertFalse(PhotoEffectsStore(defaults: defaults, scope: scope,
                premiumAccess: PremiumAccess(.lifetime), lutStore: chooserStore).settings.photoFilterEnabled)
        }
    }

    func testRoleRecipeRestoresPrivateSnapshotWithoutOriginalSource() throws {
        let suite = "lut-private-recipe-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Original name.cube")
        let bytes = Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8)
        try bytes.write(to: source)
        let lut = try CubeLUTParser.parse(Data(contentsOf: source))
        let snapshots = root.appendingPathComponent("snapshots")
        let camera = PhotoLUTStore(role: .camera, defaults: defaults, directory: snapshots)
        let local = PhotoLUTStore(role: .local, defaults: defaults, directory: snapshots)
        camera.setIntensity(64)
        local.setIntensity(80)
        let expected = try camera.selectLUT(lut, name: "Original name", sourceIdentifier: source.path)
        let localLUT = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "1 1 1\n", count: 8)).utf8))
        _ = try local.selectLUT(localLUT, name: "Local name", sourceIdentifier: "local-source")
        local.setIntensity(42)
        local.setAdjustments(.init(contrast: -20, saturation: 30, highlights: -40, shadows: 50))
        let expectedLocal = try XCTUnwrap(local.restoreSelection())
        XCTAssertNotEqual(expected.preset.id, expectedLocal.preset.id)
        try FileManager.default.removeItem(at: source)
        let reopened = PhotoLUTStore(role: .camera, defaults: defaults, directory: snapshots)
        XCTAssertEqual(reopened.restoreSelection(), expected)
        XCTAssertEqual(reopened.selectedIdentifier, source.path)
        let reopenedLocal = PhotoLUTStore(role: .local, defaults: defaults, directory: snapshots)
        XCTAssertEqual(reopenedLocal.restoreSelection(), expectedLocal)
        XCTAssertEqual(reopenedLocal.restoreSelection()?.preset.name, "Local name")
        XCTAssertEqual(reopenedLocal.restoreSelection()?.intensityPercent, 42)
        camera.select(nil)
        XCTAssertNil(PhotoLUTStore(role: .camera, defaults: defaults, directory: snapshots).restoreSelection())
        XCTAssertNotNil(reopenedLocal.restoreSelection())
        try FileManager.default.removeItem(at: snapshots)
        XCTAssertNil(reopenedLocal.restoreSelection(), "A warm runtime table must not hide a missing private snapshot")
    }

    func testPhotoAndMonitorFolderBookmarksRestoreIndependently() throws {
        let suite = "lut-folder-scopes-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let photoURL = root.appendingPathComponent("photo", isDirectory: true)
        let monitorURL = root.appendingPathComponent("monitor", isDirectory: true)
        for url in [photoURL, monitorURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let photo = RemoteLUTFolderAccess(defaults: defaults, scope: .photo)
        let monitor = RemoteLUTFolderAccess(defaults: defaults)
        try monitor.save(monitorURL)
        XCTAssertNil(photo.resolve())
        try photo.save(photoURL)
        XCTAssertEqual(photo.resolve()?.standardizedFileURL, photoURL.standardizedFileURL)
        XCTAssertEqual(monitor.resolve()?.standardizedFileURL, monitorURL.standardizedFileURL)
        XCTAssertEqual(PhotoLUTStore(role: .local, defaults: defaults).folderBookmark, photo.bookmarkData)
        XCTAssertEqual(RemoteLUTFolderAccess(defaults: defaults, scope: .photo).resolve()?.standardizedFileURL, photoURL.standardizedFileURL)
        XCTAssertEqual(RemoteLUTFolderAccess(defaults: defaults).resolve()?.standardizedFileURL, monitorURL.standardizedFileURL)
        // Users may intentionally select the same directory in both contexts.
        try photo.save(monitorURL)
        XCTAssertEqual(photo.resolve(), monitor.resolve())
        defaults.removeObject(forKey: "photo_lut_folder_bookmark")
        XCTAssertNil(photo.resolve())
        XCTAssertEqual(monitor.resolve()?.standardizedFileURL, monitorURL.standardizedFileURL)
    }

    func testTurningLUTOffReopensBothEditorsAndPreservesOtherRole() throws {
        let np3 = try XCTUnwrap(PhotoFilterCatalog.presets.first)
        for role: PhotoLUTStore.Role in [.camera, .local] {
            let suite = "lut-off-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let current = PhotoLUTStore(role: role, defaults: defaults)
            let otherRole: PhotoLUTStore.Role = role == .camera ? .local : .camera
            let other = PhotoLUTStore(role: otherRole, defaults: defaults)
            other.select("other")
            current.select("cube:" + String(repeating: "a", count: 64))
            current.setIntensity(64)
            var draft = PhotoEffectsSettings()
            draft.selectedFilter = .init(preset: .init(id: current.selectedIdentifier!, name: "Cube"), intensityPercent: 64)
            draft.photoFilterEnabled = true
            XCTAssertFalse(PhotoColorEffectEditorVisibility(settings: draft, isPro: true).filter)
            disablePhotoLUTDraft(&draft, lutStore: current)
            XCTAssertNil(draft.selectedFilter)
            XCTAssertFalse(draft.photoFilterEnabled)
            XCTAssertTrue(PhotoColorEffectEditorVisibility(settings: draft, isPro: true).filter)
            XCTAssertTrue(PhotoColorEffectEditorVisibility(settings: draft, isPro: true).lut)
            XCTAssertNil(PhotoLUTStore(role: role, defaults: defaults).selectedIdentifier)
            XCTAssertEqual(PhotoLUTStore(role: otherRole, defaults: defaults).selectedIdentifier, "other")
            XCTAssertEqual(current.intensityPercent, 64)
            draft.selectFilter(np3.id)
            XCTAssertTrue(draft.photoFilterEnabled)
            XCTAssertFalse(PhotoColorEffectEditorVisibility(settings: draft, isPro: true).lut)
            draft.selectFilter(nil)
            XCTAssertTrue(PhotoColorEffectEditorVisibility(settings: draft, isPro: true).lut)
            let remembered = draft.selectedFilter
            disablePhotoLUTDraft(&draft, lutStore: current)
            XCTAssertEqual(draft.selectedFilter, remembered)
        }
    }

    func testModuleCommandClearsOnlyItsLUTRoleAndNeverReactivates() throws {
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        PhotoLUTRuntime.register(lut)
        for role: PhotoLUTStore.Role in [.camera, .local] {
            let suite = "cube-hide-role-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let current = PhotoLUTStore(role: role, defaults: defaults)
            let otherRole: PhotoLUTStore.Role = role == .camera ? .local : .camera
            let other = PhotoLUTStore(role: otherRole, defaults: defaults)
            current.select("cube:\(lut.digest)")
            current.setIntensity(64)
            other.select("other-recipe")
            var draft = PhotoEffectsSettings()
            draft.photoEffectModules = PhotoEffectModule.lut.rawValue
            draft.selectedFilter = .init(preset: .init(id: "cube:\(lut.digest)", name: "Keep name"), intensityPercent: 64)
            draft.photoFilterEnabled = true
            let original = draft
            XCTAssertFalse(togglePhotoEffectModuleDraft(.lut, draft: &draft, lutStore: current, isPro: true))
            XCTAssertEqual(draft, original)
            XCTAssertNotNil(current.selectedIdentifier)
            XCTAssertTrue(togglePhotoEffectModuleDraft(.filter, draft: &draft, lutStore: current, isPro: true))
            XCTAssertTrue(togglePhotoEffectModuleDraft(.lut, draft: &draft, lutStore: current, isPro: true))
            XCTAssertFalse(draft.photoFilterEnabled)
            XCTAssertNil(current.selectedIdentifier)
            XCTAssertNil(PhotoLUTStore(role: role, defaults: defaults).selectedIdentifier)
            XCTAssertEqual(PhotoLUTStore(role: otherRole, defaults: defaults).selectedIdentifier, "other-recipe")
            XCTAssertEqual(current.intensityPercent, 64)
            XCTAssertTrue(togglePhotoEffectModuleDraft(.lut, draft: &draft, lutStore: current, isPro: true))
            XCTAssertFalse(draft.photoFilterEnabled)
            XCTAssertEqual(draft.selectedFilter, original.selectedFilter)
            XCTAssertNil(current.selectedIdentifier)
            let scope: PhotoEffectsStore.Scope = role == .camera ? .cameraTransfer : .localPhotos
            let effects = PhotoEffectsStore(defaults: defaults, scope: scope, premiumAccess: PremiumAccess(.lifetime))
            effects.updateFromEditor(draft)
            XCTAssertFalse(effects.settings.photoFilterEnabled)
            XCTAssertFalse(PhotoEffectsStore(defaults: defaults, scope: scope,
                premiumAccess: PremiumAccess(.lifetime)).settings.photoFilterEnabled)
        }
    }

    func testColorModuleMasksGatePreviewCommitAndRenderedOutputInBothScopes() throws {
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        PhotoLUTRuntime.register(lut)
        let presets = [try XCTUnwrap(PhotoFilterCatalog.presets.first),
                       PhotoFilterPreset(id: "cube:\(lut.digest)", name: "Black cube")]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            UIColor(red: 0.8, green: 0.3, blue: 0.6, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        for scope: PhotoEffectsStore.Scope in [.cameraTransfer, .localPhotos] {
            let suite = "color-module-output-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = PhotoEffectsStore(defaults: defaults, scope: scope,
                                          premiumAccess: PremiumAccess(.lifetime))
            for preset in presets {
                var reference = PhotoEffectsSettings()
                reference.photoFrameEnabled = false
                reference.photoFilterEnabled = true
                reference.selectedFilter = .init(preset: preset, intensityPercent: 80)
                let enabledPNG = try XCTUnwrap(PhotoEffectsRenderer.render(source, settings: reference).pngData())
                reference.photoFilterEnabled = false
                let disabledPNG = try XCTUnwrap(PhotoEffectsRenderer.render(source, settings: reference).pngData())
                for mask in 0...3 {
                    var draft = reference
                    // An unrelated module keeps the both-hidden mask nonempty.
                    draft.photoEffectModules = mask | PhotoEffectModule.frame.rawValue
                    draft.photoFilterEnabled = true
                    let bit = preset.id.hasPrefix("cube:") ? 2 : 1
                    let enabled = mask & bit != 0
                    for isPro in [false, true] {
                        let preview = effectivePhotoEffectsSettings(draft, isPro: isPro)
                        XCTAssertEqual(preview.photoFilterEnabled, enabled)
                        XCTAssertEqual(try XCTUnwrap(PhotoEffectsRenderer.render(source, settings: preview).pngData()),
                                       enabled ? enabledPNG : disabledPNG)
                    }
                    store.updateFromEditor(draft)
                    XCTAssertEqual(store.settings.photoFilterEnabled, enabled)
                    XCTAssertEqual(store.settings.selectedFilter, draft.selectedFilter)
                    let committed = effectivePhotoEffectsSettings(store.settings, isPro: true)
                    XCTAssertEqual(try XCTUnwrap(PhotoEffectsRenderer.render(source, settings: committed).pngData()),
                                   enabled ? enabledPNG : disabledPNG)
                }
            }
        }
    }

    func testColorEditorsRespectModulesAndOnlyActiveSelectionsExcludeEachOther() throws {
        let np3 = try XCTUnwrap(PhotoFilterCatalog.presets.first)
        let cube = PhotoFilterPreset(id: "cube:" + String(repeating: "a", count: 64), name: "Cube")
        for isPro in [false, true] {
            for mask in 1...15 {
                for preset in [np3, cube] {
                    var settings = PhotoEffectsSettings()
                    settings.photoEffectModules = mask
                    settings.selectedFilter = .init(preset: preset, intensityPercent: 80)
                    let hasFilter = mask & PhotoEffectModule.filter.rawValue != 0
                    let hasLUT = mask & PhotoEffectModule.lut.rawValue != 0
                    settings.photoFilterEnabled = false
                    var visibility = PhotoColorEffectEditorVisibility(settings: settings, isPro: isPro)
                    XCTAssertEqual(visibility.filter, hasFilter)
                    XCTAssertEqual(visibility.lut, hasLUT)
                    settings.photoFilterEnabled = true
                    visibility = .init(settings: settings, isPro: isPro)
                    XCTAssertEqual(visibility.filter, hasFilter && preset.id == np3.id)
                    XCTAssertEqual(visibility.lut, hasLUT && preset.id == cube.id)
                    settings.selectFilter(nil)
                    visibility = .init(settings: settings, isPro: isPro)
                    XCTAssertEqual(visibility.filter, hasFilter)
                    XCTAssertEqual(visibility.lut, hasLUT)
                }
            }
        }
    }

    func testCubeSurvivesBothEditorCommitPathsAndUsesLUTModule() throws {
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        PhotoLUTRuntime.register(lut)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        func pixel(_ image: UIImage) throws -> [UInt8] {
            let cgImage = try XCTUnwrap(image.cgImage)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2,
                bitsPerComponent: 8, bytesPerRow: 8, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 2, height: 2))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: bytes, count: 4))
        }
        let selection = PhotoFilterSelection(
            preset: PhotoFilterPreset(id: "cube:\(lut.digest)", name: "Original LUT name"),
            intensityPercent: 64)
        for scope: PhotoEffectsStore.Scope in [.cameraTransfer, .localPhotos] {
            let suite = "cube-editor-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = PhotoEffectsStore(defaults: defaults, scope: scope,
                                          premiumAccess: PremiumAccess(.lifetime))
            var draft = store.settings
            draft.photoFrameEnabled = false
            draft.photoEffectModules = PhotoEffectModule.lut.rawValue
            draft.selectedFilter = selection
            draft.photoFilterEnabled = true
            store.updateFromEditor(draft)
            XCTAssertEqual(store.settings.selectedFilter, selection)
            XCTAssertTrue(store.settings.photoFilterEnabled)
            let effective = effectivePhotoEffectsSettings(store.settings, isPro: true)
            XCTAssertTrue(effective.photoFilterEnabled)
            XCTAssertEqual(effective.selectedFilter, selection)
            // A black cube at 64% maps white to round(255 * 0.36) = 92.
            // Exercise the actual renderer using the committed effective recipe.
            XCTAssertEqual(try pixel(PhotoEffectsRenderer.render(source, settings: effective)), [92, 92, 92, 255])
            // Camera commit and local direct updates both normalize settings.
            store.update(effective)
            XCTAssertEqual(store.settings.selectedFilter, selection)
            XCTAssertTrue(store.settings.photoFilterEnabled)
            draft.photoEffectModules = PhotoEffectModule.filter.rawValue
            store.updateFromEditor(draft)
            XCTAssertFalse(store.settings.photoFilterEnabled)
            XCTAssertEqual(store.settings.selectedFilter, selection)
            XCTAssertFalse(effectivePhotoEffectsSettings(draft, isPro: true).photoFilterEnabled)
            XCTAssertEqual(try pixel(PhotoEffectsRenderer.render(source,
                settings: effectivePhotoEffectsSettings(store.settings, isPro: true))), [255, 255, 255, 255])
            // A later editor change cannot mutate the already captured recipe.
            XCTAssertEqual(try pixel(PhotoEffectsRenderer.render(source, settings: effective)), [92, 92, 92, 255])
            draft.selectedFilter = .init(preset: .init(id: "cube:missing", name: "Missing"), intensityPercent: 64)
            store.update(draft)
            XCTAssertNil(store.settings.selectedFilter)
            XCTAssertFalse(store.settings.photoFilterEnabled)
        }
    }

    func testLiveRolesShareFavoritesAndFolderWithoutOverwritingEachOther() {
        let suite = "photo-lut-live-\(UUID().uuidString)"
        let otherSuite = "photo-lut-other-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            otherDefaults.removePersistentDomain(forName: otherSuite)
        }
        // Separate defaults instances deliberately share the same suite.
        let camera = PhotoLUTStore(role: .camera, defaults: defaults)
        let local = PhotoLUTStore(role: .local, defaults: UserDefaults(suiteName: suite)!)
        let unrelated = PhotoLUTStore(role: .local, defaults: otherDefaults)
        camera.select("camera")
        local.select("local")
        camera.toggleFavorite("a")
        XCTAssertEqual(local.favorites, ["a"])
        local.toggleFavorite("b")
        XCTAssertEqual(camera.favorites, ["a", "b"])
        XCTAssertEqual(camera.favoriteOrder, ["a", "b"])
        camera.toggleFavorite("a")
        XCTAssertEqual(local.favorites, ["b"])
        XCTAssertEqual(local.favoriteOrder, ["b"])
        local.setFolderBookmark(Data([9]))
        XCTAssertEqual(camera.folderBookmark, Data([9]))
        camera.setFolderBookmark(nil)
        XCTAssertNil(local.folderBookmark)
        XCTAssertEqual(camera.selectedIdentifier, "camera")
        XCTAssertEqual(local.selectedIdentifier, "local")
        XCTAssertTrue(unrelated.favorites.isEmpty)
        XCTAssertNil(unrelated.folderBookmark)
        XCTAssertEqual(PhotoLUTStore(defaults: defaults).favorites, ["b"])
    }

    func testCameraAndLocalRecipesRemainIndependentAcrossRecreation() {
        let suite = "photo-lut-roles-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Existing camera configuration is retained, never copied into local.
        defaults.set("camera-old", forKey: "photo_lut_selected")
        defaults.set(65, forKey: "photo_lut_intensity")
        let camera = PhotoLUTStore(role: .camera, defaults: defaults)
        let local = PhotoLUTStore(role: .local, defaults: defaults)
        XCTAssertEqual(camera.selectedIdentifier, "camera-old")
        XCTAssertNil(local.selectedIdentifier)
        XCTAssertEqual(local.intensityPercent, 80)
        local.select("local-b")
        local.setIntensity(25)
        camera.select("camera-a")
        camera.setIntensity(90)
        local.setFolderBookmark(Data([1, 2, 3]))
        local.toggleFavorite("shared-favorite")
        let reopenedCamera = PhotoLUTStore(role: .camera, defaults: defaults)
        let reopenedLocal = PhotoLUTStore(role: .local, defaults: defaults)
        XCTAssertEqual(reopenedCamera.selectedIdentifier, "camera-a")
        XCTAssertEqual(reopenedCamera.intensityPercent, 90)
        XCTAssertEqual(reopenedLocal.selectedIdentifier, "local-b")
        XCTAssertEqual(reopenedLocal.intensityPercent, 26)
        XCTAssertEqual(reopenedCamera.folderBookmark, Data([1, 2, 3]))
        XCTAssertEqual(reopenedCamera.favorites, reopenedLocal.favorites)
        XCTAssertTrue(reopenedCamera.favorites.contains("shared-favorite"))
        reopenedLocal.select(nil)
        XCTAssertNil(PhotoLUTStore(role: .local, defaults: defaults).selectedIdentifier)
        XCTAssertEqual(PhotoLUTStore(role: .camera, defaults: defaults).selectedIdentifier, "camera-a")
    }

    func testSelectionStrengthAndFavoritesRestoreAcrossInstances() {
        let suite = "photo-lut-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PhotoLUTStore(defaults: defaults, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        first.select("cube-a"); first.setIntensity(140); first.toggleFavorite("cube-a")
        let second = PhotoLUTStore(defaults: defaults, directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(second.selectedIdentifier, "cube-a")
        XCTAssertEqual(second.intensityPercent, 100)
        XCTAssertTrue(second.favorites.contains("cube-a"))
    }

    func testFavoriteToggleIsIdempotent() {
        let suite = "photo-lut-toggle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoLUTStore(defaults: defaults)
        store.toggleFavorite("cube-a"); XCTAssertTrue(store.favorites.contains("cube-a"))
        store.toggleFavorite("cube-a"); XCTAssertFalse(store.favorites.contains("cube-a"))
    }
}
