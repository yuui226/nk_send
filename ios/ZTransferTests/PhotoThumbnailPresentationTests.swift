import XCTest
@testable import ZTransfer
#if os(iOS)
import UIKit
import SwiftUI
#endif

final class PhotoThumbnailPresentationTests: XCTestCase, @unchecked Sendable {
    #if os(iOS)
    @MainActor
    func testProductionPhotoListKeepsDecodedImagesAcrossScrollAndThemeLayouts() async throws {
        let standard = UserDefaults.standard
        let keys = ["collapse_burst_photos", "thumbnail_columns", PhotoFilterPersistence.photoLoadingRangeKey]
        let saved = keys.map { standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) } }
        standard.set(true, forKey: keys[0]); standard.set(3, forKey: keys[1])
        standard.set(0, forKey: keys[2]) // This scrolling fixture requires all six shooting days.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CameraSession(repository: CameraRepository(debugData: .shared),
            thumbnailStore: PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root)))
        let model = PhotoListViewModel(session: session)
        defer { model.transportDidDisconnect() }
        await model.reload()
        var identities = Set<ObjectIdentifier>()
        for file in DebugCameraData.shared.files {
            _ = try await session.thumbnail(file: file)
            identities.insert(ObjectIdentifier(try XCTUnwrap(session.memoryThumbnailImage(file: file))))
        }
        let suite = "ThumbnailList-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for dark in [false, true] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
            window.rootViewController = UIHostingController(rootView: PhotoListView(session: session,
                listModel: model, presentationMode: .usb, queue: queue,
                directory: DirectoryAccessStore(defaults: defaults), effectsStore: PhotoEffectsStore(defaults: defaults))
                .environment(\.colorScheme, dark ? .dark : .light))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            try await Task.sleep(for: .milliseconds(400))
            let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }
                .first { $0.bounds.height > 200 && $0.contentSize.height > $0.bounds.height + 100 })
            for bottom in [false, true, false] {
                let target = bottom ? max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom) : -scroll.adjustedContentInset.top
                scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                try await Task.sleep(for: .milliseconds(220))
                let bitmaps = descendants(window).compactMap { $0 as? PhotoThumbnailBitmapView }.filter {
                    !$0.isHidden && $0.convert($0.bounds, to: window).intersects(window.bounds)
                }
                XCTAssertFalse(bitmaps.isEmpty)
                for bitmap in bitmaps {
                    XCTAssertTrue(identities.contains(ObjectIdentifier(try XCTUnwrap(bitmap.image))),
                                  "The real cell must reuse the session's decoded image after recycling")
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "photo-list-\(dark ? "dark" : "light")-\(bottom ? "bottom" : "top")"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    #endif

    func testCurrentCatalogLookupTracksMembershipDeletionReuseAndRecoveryCopy() {
        var catalog = PhotoFileCatalog()
        let old = file(1), other = file(2)
        catalog.replaceAll([old, other])
        var recovered = catalog
        let updated = CameraFile(id: 1, storageID: 1, format: old.format, size: old.size,
            fileName: old.fileName, captureDate: old.captureDate, isProtected: true, storageIDs: [1, 2])
        catalog.upsert(updated)
        XCTAssertEqual(catalog.files, [updated, other])
        XCTAssertEqual(catalog.file(for: 1), updated)
        XCTAssertEqual(recovered.file(for: 1), old, "Recovery copies cannot share mutable row indexes")
        catalog.replaceAll([other])
        XCTAssertNil(catalog.file(for: 1))
        let replacement = file(1, name: "REUSED.JPG")
        catalog.upsert(replacement)
        XCTAssertEqual(catalog.files, [other, replacement])
        XCTAssertEqual(catalog.file(for: 1), replacement)
        catalog.replaceAll([replacement, old])
        XCTAssertEqual(catalog.file(for: 1), replacement, "Bulk lookup preserves the previous first-match contract")
        catalog.upsert(updated)
        XCTAssertEqual(catalog.files, [updated, old])
        catalog.clear()
        XCTAssertNil(catalog.file(for: 1))
        XCTAssertTrue(catalog.files.isEmpty)
        recovered.upsert(file(3))
        XCTAssertEqual(recovered.files.map(\.id), [1, 2, 3])
    }

    func testCatalogLookupMatchesCurrentArrayAfterMixedBatchesAndReorder() {
        var catalog = PhotoFileCatalog()
        let files = (1...8_000).map { file(UInt32($0)) }
        catalog.replaceAll(files)
        for id: UInt32 in [1, 8_000, 4_031, 2, 7_999] {
            catalog.upsert(file(id, name: "changed-\(id).JPG"))
        }
        let reversed = Array(catalog.files.reversed())
        catalog.replaceAll(reversed)
        for photo in reversed { XCTAssertEqual(catalog.file(for: photo.id), photo) }
        XCTAssertNil(catalog.file(for: 8_001))
    }

    func testVisibleBurstMembershipKeepsFilteredOrderAndHasNoHiddenMembers() {
        let values = [file(8), file(3), file(1), file(9)]
        let ids: [UInt32: String] = [1: "a", 2: "a", 3: "a", 8: "b"]
        let grouped = visiblePhotoBurstMembers(files: values, burstIDs: ids)
        XCTAssertEqual(grouped["a"]?.map(\.id), [3, 1])
        XCTAssertEqual(grouped["b"]?.map(\.id), [8])
        XCTAssertEqual(grouped.count, 2)
        XCTAssertTrue(visiblePhotoBurstMembers(files: values, burstIDs: [:]).isEmpty)
        XCTAssertTrue(visiblePhotoBurstMembers(files: [], burstIDs: ids).isEmpty)
    }

    func testStackGeometryUsesAndroidAnglesAndFixedOffsets() {
        let two = (0..<2).map { PhotoThumbnailStackCard(frontIndex: $0, visibleCount: 2) }
        XCTAssertEqual(two.map(\.rotation), [3, -5])
        XCTAssertEqual(two.map(\.x), [0, -4])
        XCTAssertEqual(two.map(\.y), [1, 2])
        let three = (0..<3).map { PhotoThumbnailStackCard(frontIndex: $0, visibleCount: 90) }
        XCTAssertEqual(three.map(\.rotation), [0, 5, -6])
        XCTAssertEqual(three.map(\.x), [0, 4, -4])
        XCTAssertEqual(three.map(\.y), [1, 2, 2])
    }

    func testStackTailChangesDoNotAnimateAndAliasUpdatesCurrentPayload() {
        let original = (1...4).map { file(UInt32($0)) }
        var motion = PhotoThumbnailStackMotion(original)
        motion.update(Array(original.prefix(3)) + [file(99)])
        XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(motion.snapshots.count, 1)
        let alias = file(101, name: original[0].fileName)
        motion.update([alias, original[1], original[2]])
        XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(motion.snapshots[0].files[0].id, 101)
        XCTAssertEqual(motion.opacity(motion.target), 1)
    }

    func testStackCrossfadeUses180msEntranceAnd160msExit() {
        let original = [file(1), file(2), file(3)]
        var motion = PhotoThumbnailStackMotion(original)
        let old = motion.target
        motion.update([file(1), file(2), file(4)])
        XCTAssertEqual(motion.snapshots.count, 2)
        XCTAssertEqual(motion.opacity(old), 1)
        XCTAssertEqual(motion.opacity(motion.target), 0)
        motion.advance(0); motion.advance(80_000_000)
        XCTAssertEqual(motion.opacity(old), 0.2244387, accuracy: 0.00001)
        XCTAssertGreaterThan(motion.opacity(motion.target), 0)
        XCTAssertLessThan(motion.opacity(motion.target), 1)
        motion.advance(160_000_000)
        XCTAssertEqual(motion.opacity(old), 0)
        XCTAssertLessThan(motion.opacity(motion.target), 1)
        motion.advance(180_000_000)
        XCTAssertEqual(motion.opacity(motion.target), 1)
        XCTAssertEqual(motion.snapshots.count, 1)
        XCTAssertFalse(motion.isRunning)
    }

    func testInterruptedStackReversalKeepsDisplayedAlphaAndReusesOldLayer() {
        let first = [file(1), file(2), file(3)]
        var motion = PhotoThumbnailStackMotion(first)
        let firstID = motion.target
        motion.update([file(1), file(2), file(4)])
        let secondID = motion.target
        motion.advance(0); motion.advance(80_000_000)
        let firstAlpha = motion.opacity(firstID), secondAlpha = motion.opacity(secondID)
        motion.update(first)
        XCTAssertEqual(motion.opacity(firstID), firstAlpha)
        XCTAssertEqual(motion.opacity(secondID), secondAlpha)
        XCTAssertEqual(motion.snapshots.count, 2)
        for frame in 6...70 { motion.advance(Int64(frame) * 16_000_000) }
        XCTAssertEqual(motion.snapshots.count, 1)
        XCTAssertEqual(motion.target, firstID)
        XCTAssertEqual(motion.opacity(firstID), 1)
        XCTAssertFalse(motion.isRunning)
    }

    func testSameKeyPayloadUpdateDoesNotRestartAnActiveStackFade() {
        var motion = PhotoThumbnailStackMotion([file(1), file(2), file(3)])
        motion.update([file(1), file(2), file(4)])
        motion.advance(0); motion.advance(80_000_000)
        let replacement = file(104, name: "4.JPG")
        motion.update([file(1), file(2), replacement])
        motion.advance(180_000_000)
        XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(motion.snapshots[0].files[2].id, 104)
        XCTAssertEqual(motion.opacity(motion.target), 1)
    }

    @MainActor
    func testLateStorePublicationFillsMountedCellWithoutAnotherRemoteRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: folder))
        let photo = file(73)
        let loader = PhotoThumbnailLoader<Data>(cached: nil)
        let calls = ThumbnailPresentationReadCalls()
        let loading = Task {
            await loader.load(enabled: true, allowRemote: true,
                updates: { await store.updates(handle: photo.id) }, read: { remote in
                    let loaded = try? await store.load(file: photo, identity: "presentation", allowRemote: remote,
                                                       fetch: { throw ThumbnailPresentationMiss() })
                    await calls.record(remote)
                    return loaded
                })
        }
        defer { loading.cancel() }
        try await waitUntil { calls.values == [true] }
        let bytes = Data([4, 3, 2, 1])
        _ = try await store.prefetch(file: photo, identity: "presentation", fetch: { bytes })
        await store.publish(handle: 999)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertNil(loader.image, "Another photo's readiness cannot reload this cell")
        await store.publish(handle: photo.id)
        try await waitUntil { loader.image == bytes }
        await loading.value
        XCTAssertEqual(calls.values, [true, false])
        XCTAssertFalse(loader.fadeComplete)
        loader.finishFade()
        XCTAssertTrue(loader.fadeComplete)
    }

    func testFadeStartsAtFirstFrameAndMatchesAndroid180msCurve() {
        var fade = PhotoThumbnailFade()
        XCTAssertEqual(fade.opacity, 0)
        XCTAssertFalse(fade.isRunning)
        fade.update(ready: true)
        XCTAssertEqual(fade.opacity, 0)
        fade.advance(1_000_000_000)
        XCTAssertEqual(fade.opacity, 0)
        fade.advance(1_090_000_000)
        XCTAssertEqual(fade.opacity, 0.7755613, accuracy: 0.00001)
        fade.advance(1_180_000_000)
        XCTAssertEqual(fade.opacity, 1)
        XCTAssertFalse(fade.isRunning)
        fade.update(ready: false); fade.update(ready: true)
        XCTAssertEqual(fade.opacity, 1)
        XCTAssertFalse(fade.isRunning, "Filtering or later scan batches cannot replay a completed entrance")
    }

    func testInterruptedBatchFadeResumesFromDisplayedValueAndCacheStartsOpaque() {
        var fade = PhotoThumbnailFade()
        fade.update(ready: true); fade.advance(0); fade.advance(90_000_000)
        let paused = fade.opacity
        fade.update(ready: false); fade.advance(500_000_000)
        XCTAssertEqual(fade.opacity, paused)
        XCTAssertFalse(fade.isRunning)
        fade.update(ready: true); fade.advance(1_000_000_000)
        XCTAssertEqual(fade.opacity, paused)
        fade.advance(1_180_000_000)
        XCTAssertEqual(fade.opacity, 1)
        var cached = PhotoThumbnailFade(initiallyVisible: true)
        cached.update(ready: true)
        XCTAssertEqual(cached.opacity, 1)
        XCTAssertFalse(cached.isRunning)
    }

    @MainActor
    func testCachedCellDoesNotSubscribeOrReadAndDisabledCellKeepsImage() async {
        let loader = PhotoThumbnailLoader(cached: Data([4]))
        await loader.load(enabled: true, allowRemote: true, updates: {
            XCTFail("Cache hits have no loading subscription")
            return AsyncStream { $0.finish() }
        }, read: { _ in XCTFail(); return nil })
        await loader.load(enabled: false, allowRemote: false, updates: { AsyncStream { $0.finish() } }, read: { _ in nil })
        XCTAssertEqual(loader.image, Data([4]))
        XCTAssertTrue(loader.fadeComplete)
        XCTAssertTrue(loader.cachedAtMount)
    }

    @MainActor
    func testMissWaitsForItsNotificationThenReadsCacheAndStopsObserving() async throws {
        let loader = PhotoThumbnailLoader<Data>(cached: nil)
        let feed = ThumbnailPresentationFeed()
        var calls: [Bool] = []
        let work = Task {
            await loader.load(enabled: true, allowRemote: true,
                updates: { await feed.subscribe() }, read: { remote in
                    await MainActor.run {
                        calls.append(remote)
                        return calls.count == 1 ? nil : Data([7])
                    }
                })
        }
        try await waitUntil { calls.count == 1 }
        XCTAssertNil(loader.image)
        XCTAssertEqual(feed.listeners, 1)
        feed.publish()
        await work.value
        XCTAssertEqual(loader.image, Data([7]))
        XCTAssertEqual(calls, [true, false])
        XCTAssertFalse(loader.fadeComplete)
        loader.finishFade(); loader.finishFade()
        XCTAssertTrue(loader.fadeComplete)
        try await waitUntil { feed.listeners == 0 }
        feed.publish()
        XCTAssertEqual(calls.count, 2, "A ready cell must stop observing cache writes")
    }

    @MainActor
    func testCancelledReadAndReusedGenerationCannotPublishLateImage() async throws {
        for cancel in [false, true] {
            let loader = PhotoThumbnailLoader<Data>(cached: nil)
            let feed = ThumbnailPresentationFeed(), gate = ThumbnailPresentationReadGate()
            let old = Task {
                await loader.load(enabled: true, allowRemote: true, updates: { await feed.subscribe() },
                                  read: { _ in await gate.read() })
            }
            try await waitUntil { await gate.waiting }
            if cancel { old.cancel() }
            else {
                await loader.load(enabled: false, allowRemote: false,
                    updates: { await feed.subscribe() }, read: { _ in XCTFail(); return nil })
            }
            await gate.finish(Data([1])); await old.value
            XCTAssertNil(loader.image)
            await loader.load(enabled: true, allowRemote: false,
                updates: { await feed.subscribe() }, read: { remote in
                    XCTAssertFalse(remote)
                    return Data([2])
                })
            XCTAssertEqual(loader.image, Data([2]))
            try await waitUntil { feed.listeners == 0 }
        }
    }

    @MainActor
    func testLocalOnlyMissRetriesWhenRemoteGateChangesWithoutClearingReadyImage() async throws {
        let loader = PhotoThumbnailLoader<Data>(cached: nil), feed = ThumbnailPresentationFeed()
        var calls: [Bool] = []
        let first = Task {
            await loader.load(enabled: true, allowRemote: false, updates: { await feed.subscribe() }, read: { remote in
                await MainActor.run { calls.append(remote) }
                return nil
            })
        }
        try await waitUntil { calls.count == 1 }
        first.cancel(); await first.value
        await loader.load(enabled: true, allowRemote: true, updates: { await feed.subscribe() }, read: { remote in
            await MainActor.run { calls.append(remote) }
            return Data([3])
        })
        XCTAssertEqual(calls, [false, true])
        await loader.load(enabled: false, allowRemote: false, updates: { await feed.subscribe() }, read: { _ in XCTFail(); return nil })
        XCTAssertEqual(loader.image, Data([3]))
    }

    #if os(iOS)
    @MainActor
    func testBitmapReusesDecodedUIImageAndFadesOnlyItsLayer() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }
        let view = PhotoThumbnailBitmapView(automaticFrames: false)
        var completions = 0
        view.configure(image: image, cornerRadius: 10, fade: true) { completions += 1 }
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 60); view.layoutIfNeeded()
        XCTAssertTrue(view.image === image)
        XCTAssertEqual(view.layer.cornerRadius, 10)
        XCTAssertTrue(view.layer.allowsEdgeAntialiasing)
        XCTAssertFalse(view.layer.shouldRasterize)
        XCTAssertEqual(view.imageOpacity, 0)
        view.advance(0); view.advance(90_000_000)
        XCTAssertEqual(view.imageOpacity, 0.7755613, accuracy: 0.00001)
        view.configure(image: image, cornerRadius: 10, fade: true) { completions += 1 }
        view.advance(180_000_000)
        XCTAssertEqual(view.imageOpacity, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(view.clockRunning)
    }

    @MainActor
    func testSharedEntranceCompletesOnceAndStopsWhenHidden() {
        let clock = PhotoThumbnailBatchEntrance(automaticFrames: false)
        clock.update(hasItems: true); clock.advance(0); clock.advance(90_000_000)
        let paused = clock.opacity
        clock.update(hasItems: false); clock.advance(900_000_000)
        XCTAssertEqual(clock.opacity, paused)
        clock.update(hasItems: true); clock.advance(1_000_000_000); clock.advance(1_180_000_000)
        XCTAssertEqual(clock.opacity, 1)
        clock.update(hasItems: false); clock.update(hasItems: true)
        XCTAssertEqual(clock.opacity, 1)
        XCTAssertFalse(clock.clockRunning)
    }

    @MainActor
    func testReadyBitmapReturningWithSameImageDoesNotKeepPartialOpacity() {
        let bitmap = UIGraphicsImageRenderer(size: .init(width: 4, height: 4)).image { _ in UIColor.red.setFill(); UIRectFill(.init(x: 0, y: 0, width: 4, height: 4)) }
        let view = PhotoThumbnailBitmapView(automaticFrames: false)
        view.configure(image: bitmap, cornerRadius: 10, fade: true, onFadeComplete: {})
        view.advance(0); view.advance(70_000_000)
        XCTAssertLessThan(view.imageOpacity, 1)
        view.configure(image: bitmap, cornerRadius: 10, fade: false, onFadeComplete: { XCTFail() })
        XCTAssertTrue(view.image === bitmap)
        XCTAssertEqual(view.imageOpacity, 1)
        XCTAssertFalse(view.clockRunning)
    }
    #endif

    private func file(_ id: UInt32, name: String? = nil) -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 100,
            fileName: name ?? "\(id).JPG", captureDate: "20261031T120000", isProtected: false)
    }
    @MainActor
    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Thumbnail lifecycle did not reach its expected boundary")
    }
}

@MainActor
private final class ThumbnailPresentationFeed {
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    var listeners: Int { continuations.count }
    func subscribe() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
        continuation.yield(())
        return stream
    }
    func publish() { for continuation in continuations.values { continuation.yield(()) } }
}

private actor ThumbnailPresentationReadGate {
    private var continuation: CheckedContinuation<Data?, Never>?
    var waiting: Bool { continuation != nil }
    func read() async -> Data? { await withCheckedContinuation { continuation = $0 } }
    func finish(_ value: Data?) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor
private final class ThumbnailPresentationReadCalls {
    private(set) var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
}

private struct ThumbnailPresentationMiss: Error {}
