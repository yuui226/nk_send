import Foundation
import CoreGraphics
import CoreLocation
import ImageIO
import UIKit
import ZTransferShared
import XCTest
@testable import ZTransfer

@MainActor private final class FakeGpsGattDriver: NikonGpsGattDriver {
    var eventHandler: ((GpsGattDriverEvent) -> Void)?
    var onWrite: (() -> Void)?
    var maximumWriteLength = 512
    let candidate = GpsBluetoothCandidate(id: UUID(), name: "Nikon test", rssi: -45)
    private(set) var writes: [(GpsGattChannel, Data)] = []
    private(set) var closed = false
    func scan() { eventHandler?(.scanning); eventHandler?(.candidate(candidate)) }
    func stopScan() {}
    func connect(_ identifier: UUID) { eventHandler?(.ready(maximumWriteLength: maximumWriteLength)) }
    func write(_ data: Data, channel: GpsGattChannel) { writes.append((channel, data)); onWrite?() }
    func reply(_ channel: GpsGattChannel) { eventHandler?(.written(channel, nil)) }
    func close() { closed = true }
}

@MainActor private final class QueueActionCompletionProbe: NSObject, NativeQueueActionCompletion {
    let expectation: XCTestExpectation
    private(set) var succeeded: Bool?
    init(_ expectation: XCTestExpectation) { self.expectation = expectation }
    func complete(succeeded: Bool) { self.succeeded = succeeded; expectation.fulfill() }
}

@MainActor private final class FilesEnqueueCompletionProbe: NSObject, NativeFilesEnqueueCompletion {
    private(set) var count: Int32?
    func complete(acceptedCount: Int32) { count = acceptedCount }
}

@MainActor private final class PreviewExifCompletionProbe: NSObject, NativePreviewExifCompletion {
    let done: XCTestExpectation
    private(set) var value: PhotoExif?
    private(set) var count = 0
    init(_ done: XCTestExpectation) { self.done = done; super.init(); done.assertForOverFulfill = true }
    func complete(exif: PhotoExif?) { value = exif; count += 1; done.fulfill() }
}

@MainActor private final class PreviewPriorityCompletionProbe: NSObject, NativePreviewPriorityCompletion {
    let done: XCTestExpectation
    private(set) var granted: Bool?
    init(_ done: XCTestExpectation) { self.done = done; super.init(); done.assertForOverFulfill = true }
    func complete(granted: Bool) { self.granted = granted; done.fulfill() }
}

private actor FakeExifSource: CameraExifSource {
    private var priorityTokens = Set<UUID>()
    private(set) var priorityReleases = 0
    private var priorityBegan: (() -> Void)?
    private var heldPriority: CheckedContinuation<Void, Never>?
    func holdNextPriority(_ began: @escaping () -> Void) { priorityBegan = began }
    func releaseHeldPriority() { heldPriority?.resume(); heldPriority = nil }
    func beginInteractivePreview() async throws -> UUID {
        try Task.checkCancellation()
        if let began = priorityBegan {
            priorityBegan = nil
            await withCheckedContinuation { heldPriority = $0; began() }
            // Deliberately returns a late token even after cancellation: the bridge must release it.
        }
        let token = UUID(); priorityTokens.insert(token); return token
    }
    func endInteractivePreview(_ token: UUID) {
        if priorityTokens.remove(token) != nil { priorityReleases += 1 }
    }
    func priorityCount() -> Int { priorityTokens.count }
    enum Reply: Sendable { case bytes(Data), missing, failure }
    let reply: Reply
    let holdFirst: Bool
    let onRequest: (() -> Void)?
    private var calls: [(Int32, Int32)] = []
    private var held: CheckedContinuation<Void, Never>?
    init(_ reply: Reply, holdFirst: Bool = false, onRequest: (() -> Void)? = nil) {
        self.reply = reply; self.holdFirst = holdFirst; self.onRequest = onRequest
    }
    func exifHeader(handle: Int32, maximumBytes: Int32) async throws -> Data? {
        calls.append((handle, maximumBytes))
        if holdFirst && calls.count == 1 { await withCheckedContinuation { held = $0; onRequest?() } }
        else if calls.count == 1 { onRequest?() }
        try Task.checkCancellation()
        switch reply { case .bytes(let data): return data; case .missing: return nil; case .failure: throw CameraStreamError.timedOut }
    }
    func requests() -> [(Int32, Int32)] { calls }
    func release() { held?.resume(); held = nil }
}

final class CameraNetworkTests: XCTestCase {
    private func waitUntil(_ description: String, _ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail(description)
        throw CameraStreamError.timedOut
    }

    func testInteractiveWindowKeepsDownloadBetweenTransactionsUntilFhdAndExifFinish() async throws {
        let wire = FakeCameraConnection(bytes: response(transaction: 1) + response(transaction: 2)
            + response(transaction: 3) + response(transaction: 4))
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        let window = try await session.beginInteractivePreview()
        let download = Task { try await session.executeStreaming(operationCode: 0x1009, parameters: [7]) { _ in } }
        try await waitUntil("download is parked without owning the socket") { await session.pendingTransferSliceCount() == 1 }
        XCTAssertTrue(wire.sent().isEmpty)
        let nested = try await session.beginInteractivePreview()
        _ = try await session.execute(operationCode: 0x9428, parameters: [7])
        await session.endInteractivePreview(nested)
        // Ordinary metadata remains eligible. Only transfer slices yield, not the whole camera.
        _ = try await session.execute(operationCode: 0x1004)
        _ = try await session.execute(operationCode: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX, parameters: [7, 0, 0, 131072, 0])
        XCTAssertEqual(wire.sent().count, 3)
        let pending = await session.pendingTransferSliceCount(); XCTAssertEqual(pending, 1)
        await session.endInteractivePreview(UUID()) // Foreign/duplicate releases cannot open the window.
        await session.endInteractivePreview(nested)
        XCTAssertEqual(wire.sent().count, 3)
        await session.endInteractivePreview(window)
        let result = try await download.value; XCTAssertEqual(result.code, 0x2001)
        XCTAssertEqual(wire.sent().last, hex("16000000060000000100000009100400000007000000"))
    }

    func testPriorityNeverInterruptsAnAlreadyStartedStreamingTransaction() async throws {
        let received = expectation(description: "first complete slice owns the wire")
        received.assertForOverFulfill = false
        let wire = FakeCameraConnection(onReceive: { received.fulfill() })
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        let active = Task { try await session.executeStreaming(operationCode: 0x1009, parameters: [7], idleTimeout: 3) { _ in } }
        await fulfillment(of: [received], timeout: 1)
        let token = try await session.beginInteractivePreview()
        let next = Task { try await session.executeStreaming(operationCode: 0x1009, parameters: [8]) { _ in } }
        try await waitUntil("next slice queued behind active data") { await session.pendingTransferSliceCount() == 1 }
        XCTAssertEqual(wire.sent().count, 1)
        wire.feed(response(transaction: 1) + response(transaction: 2) + response(transaction: 3))
        let completed = try await active.value; XCTAssertEqual(completed.code, 0x2001)
        _ = try await session.execute(operationCode: 0x9428, parameters: [9])
        XCTAssertEqual(wire.sent().count, 2)
        await session.endInteractivePreview(token)
        _ = try await next.value
        XCTAssertEqual(wire.sent().last, hex("16000000060000000100000009100300000008000000"))
    }

    func testCancellingAPriorityParkedSliceConsumesNoTidAndDoesNotCloseTheConnection() async throws {
        let wire = FakeCameraConnection(bytes: response(transaction: 1))
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        let token = try await session.beginInteractivePreview()
        let waiting = Task { try await session.executeStreaming(operationCode: 0x1009, parameters: [7]) { _ in } }
        try await waitUntil("slice waits for priority") { await session.pendingTransferSliceCount() == 1 }
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(wire.sent().isEmpty)
        let closed = await session.isClosed(); XCTAssertFalse(closed)
        await session.endInteractivePreview(token)
        _ = try await session.execute(operationCode: 0x1004)
        XCTAssertEqual(wire.sent(), [hex("120000000600000001000000041001000000")])
    }

    func testClosingSessionWakesPriorityParkedSlicesAndRejectsNewWindows() async throws {
        let wire = FakeCameraConnection()
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        let token = try await session.beginInteractivePreview()
        let waiting = Task { try await session.executeStreaming(operationCode: 0x1009, parameters: [7]) { _ in } }
        try await waitUntil("slice parked before close") { await session.pendingTransferSliceCount() == 1 }
        await session.close()
        do { _ = try await waiting.value; XCTFail("Closed owner must wake its waiter") }
        catch { XCTAssertEqual(error as? CameraStreamError, .closed) }
        await session.endInteractivePreview(token)
        do { _ = try await session.beginInteractivePreview(); XCTFail("Closed owner cannot issue tokens") }
        catch { XCTAssertEqual(error as? CameraStreamError, .closed) }
        XCTAssertTrue(wire.sent().isEmpty)
    }

    @MainActor func testPagePriorityWindowUsesBorrowedOwnerAndReleasesExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FakeExifSource(.missing)
        let page = try exifPage(NativePreviewExifCache(), source: source, root: root).page
        defer { page.close() }
        let reply = PreviewPriorityCompletionProbe(expectation(description: "priority granted"))
        page.beginPreviewPriority(sessionId: 1, requestId: 1, completion: reply)
        await fulfillment(of: [reply.done], timeout: 1)
        XCTAssertEqual(reply.granted, true)
        let count = await source.priorityCount(); XCTAssertEqual(count, 1)
        page.endPreviewPriority(sessionId: 1, requestId: 1)
        page.endPreviewPriority(sessionId: 1, requestId: 1)
        try await waitUntil("one release acknowledged") { await source.priorityReleases == 1 }
        let next = PreviewPriorityCompletionProbe(expectation(description: "second priority"))
        page.beginPreviewPriority(sessionId: 1, requestId: 2, completion: next)
        await fulfillment(of: [next.done], timeout: 1)
        page.endPreviewReads(sessionId: 1)
        try await waitUntil("overlay close releases remaining window") { await source.priorityReleases == 2 }
        let remaining = await source.priorityCount(); XCTAssertEqual(remaining, 0)
    }

    @MainActor func testLatePriorityTokenIsReleasedAfterPageSessionReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FakeExifSource(.missing)
        let began = expectation(description: "priority registration held")
        await source.holdNextPriority { began.fulfill() }
        let page = try exifPage(NativePreviewExifCache(), source: source, root: root).page
        defer { page.close() }
        let old = PreviewPriorityCompletionProbe(expectation(description: "old grant rejected"))
        page.beginPreviewPriority(sessionId: 1, requestId: 1, completion: old)
        await fulfillment(of: [began], timeout: 1)
        page.beginPreviewReads(sessionId: 2)
        let fresh = PreviewPriorityCompletionProbe(expectation(description: "new grant"))
        page.beginPreviewPriority(sessionId: 2, requestId: 1, completion: fresh)
        await fulfillment(of: [fresh.done], timeout: 1)
        XCTAssertEqual(fresh.granted, true)
        await source.releaseHeldPriority()
        await fulfillment(of: [old.done], timeout: 1)
        XCTAssertEqual(old.granted, false)
        try await waitUntil("late old token released") { await source.priorityReleases == 1 }
        let count = await source.priorityCount(); XCTAssertEqual(count, 1)
        page.close()
        try await waitUntil("new token released on page close") { await source.priorityCount() == 0 }
    }

    @MainActor private func exifPage(_ cache: NativePreviewExifCache, source: CameraExifSource, root: URL,
                                     handle: Int32 = 7, name: String = "sample.JPG", size: Int = 7)
        throws -> (page: OriginalFilesPageBridge, file: CameraFileInfo, queue: CameraOriginalQueue) {
        let camera = stationCamera(command: FakeCameraConnection(bytes: Data()))
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        let page = OriginalFilesPageBridge(connectionID: camera.connectionID,
            catalog: CameraCatalog(source: camera, stationMode: true), queue: queue,
            previews: CameraPreviewStore(source: camera), exifSource: source, exifCache: cache, stationMode: true)
        var bytes = Data(repeating: 0, count: 52)
        bytes[0] = 1; bytes[2] = 1; bytes[4] = 1; bytes[5] = 0x38
        for i in 0..<4 { bytes[8 + i] = UInt8(truncatingIfNeeded: size >> (8 * i)) }
        bytes.append(UInt8(name.utf16.count + 1))
        for unit in name.utf16 { bytes.append(UInt8(unit & 255)); bytes.append(UInt8(unit >> 8)) }
        bytes.append(contentsOf: [0,0,0])
        let info = try XCTUnwrap(PtpIPChannel.objectInfo(handle: handle, payload: bytes))
        let file = try XCTUnwrap(NativeOriginalTransferQueue().enqueue(info: info, byDate: false, dayKey: 0)).file
        page.setConnected(true)
        let catalog = CameraCatalogSnapshot(connectionID: camera.connectionID, revision: 0, storageIDs: [0x10001],
            files: [file], objectInfos: [handle: info], totalHandles: 1, metadataComplete: true, changedWhileScanning: false)
        XCTAssertTrue(page.acceptCatalog(catalog, sequence: page.model.beginScan()))
        page.beginPreviewReads(sessionId: 1)
        return (page, file, queue)
    }

    @MainActor func testExifCacheSurvivesPageAndConnectionReplacementAndServesLocalOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = NativePreviewExifCache()
        let data = try rawBiasJpegFixture(numerator: 36_293_949, denominator: 725_879_001, little: true)
        let firstSource = FakeExifSource(.bytes(data))
        let first = try exifPage(cache, source: firstSource, root: root)
        let done = PreviewExifCompletionProbe(expectation(description: "remote EXIF"))
        first.page.readExif(sessionId: 1, requestId: 1, file: first.file, completion: done)
        await fulfillment(of: [done.done], timeout: 3)
        XCTAssertEqual(done.value?.exposureCompensation, "+0.1 EV"); XCTAssertEqual(done.count, 1)
        let calls = await firstSource.requests(); XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?.1, 128 * 1024)
        first.page.close()
        let secondSource = FakeExifSource(.failure)
        let second = try exifPage(cache, source: secondSource, root: root, handle: 9)
        defer { second.page.close() }
        second.page.setConnected(false)
        let local = PreviewExifCompletionProbe(expectation(description: "local cached EXIF"))
        second.page.readLocalExif(sessionId: 1, requestId: 1, file: second.file, source: "file:///not-opened/sample.JPG", completion: local)
        await fulfillment(of: [local.done], timeout: 1)
        XCTAssertEqual(local.value?.exposureCompensation, "+0.1 EV")
        let offline = PreviewExifCompletionProbe(expectation(description: "offline cached EXIF"))
        second.page.readExif(sessionId: 1, requestId: 2, file: second.file, completion: offline)
        await fulfillment(of: [offline.done], timeout: 1)
        XCTAssertEqual(offline.value?.exposureCompensation, "+0.1 EV")
        let laterCalls = await secondSource.requests(); XCTAssertTrue(laterCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testExifNegativeCacheDistinguishesFailedAttemptAndSuppressesLocalRetry() async throws {
        for reply in [FakeExifSource.Reply.missing, .failure] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = NativePreviewExifCache(), source = FakeExifSource(reply)
            let context = try exifPage(cache, source: source, root: root)
            defer { context.page.close() }
            XCTAssertNil(cache.cached(file: context.file))
            let remote = PreviewExifCompletionProbe(expectation(description: "negative remote"))
            context.page.readExif(sessionId: 1, requestId: 1, file: context.file, completion: remote)
            await fulfillment(of: [remote.done], timeout: 3)
            XCTAssertNil(try XCTUnwrap(cache.cached(file: context.file)).value)
            let local = PreviewExifCompletionProbe(expectation(description: "negative local"))
            context.page.readLocalExif(sessionId: 1, requestId: 2, file: context.file, source: "file:///not-opened/sample.JPG", completion: local)
            await fulfillment(of: [local.done], timeout: 1)
            XCTAssertNil(local.value)
            let calls = await source.requests(); XCTAssertEqual(calls.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    @MainActor func testOfflineExifMissIsNotCachedButUnsupportedFormatIsCachedWithoutIo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = NativePreviewExifCache(), source = FakeExifSource(.missing)
        let context = try exifPage(cache, source: source, root: root)
        defer { context.page.close() }
        context.page.setConnected(false)
        let offline = PreviewExifCompletionProbe(expectation(description: "offline miss"))
        context.page.readExif(sessionId: 1, requestId: 1, file: context.file, completion: offline)
        await fulfillment(of: [offline.done], timeout: 1)
        XCTAssertNil(cache.cached(file: context.file))
        let noCalls = await source.requests(); XCTAssertTrue(noCalls.isEmpty)
        context.page.setConnected(true)
        let retry = PreviewExifCompletionProbe(expectation(description: "connected attempt"))
        context.page.readExif(sessionId: 1, requestId: 2, file: context.file, completion: retry)
        await fulfillment(of: [retry.done], timeout: 3)
        XCTAssertNotNil(cache.cached(file: context.file))
        let unsupportedSource = FakeExifSource(.failure)
        let video = try exifPage(cache, source: unsupportedSource, root: root, name: "sample.MOV")
        defer { video.page.close() }
        video.page.setConnected(false)
        let unsupported = PreviewExifCompletionProbe(expectation(description: "unsupported"))
        video.page.readExif(sessionId: 1, requestId: 1, file: video.file, completion: unsupported)
        await fulfillment(of: [unsupported.done], timeout: 1)
        XCTAssertNil(try XCTUnwrap(cache.cached(file: video.file)).value)
        let videoCalls = await unsupportedSource.requests(); XCTAssertTrue(videoCalls.isEmpty)
    }

    @MainActor func testCancelledExifRequestDoesNotCreateNegativeEntryAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let began = expectation(description: "EXIF source held")
        let data = try rawBiasJpegFixture(numerator: -2, denominator: 3, little: true)
        let source = FakeExifSource(.bytes(data), holdFirst: true, onRequest: { began.fulfill() })
        let cache = NativePreviewExifCache(), context = try exifPage(cache, source: source, root: root)
        defer { context.page.close() }
        let first = PreviewExifCompletionProbe(expectation(description: "cancelled result"))
        context.page.readExif(sessionId: 1, requestId: 1, file: context.file, completion: first)
        await fulfillment(of: [began], timeout: 3)
        context.page.cancelPreviewRead(sessionId: 1, requestId: 1)
        await source.release()
        await fulfillment(of: [first.done], timeout: 3)
        XCTAssertNil(cache.cached(file: context.file))
        let next = PreviewExifCompletionProbe(expectation(description: "retry result"))
        context.page.readExif(sessionId: 1, requestId: 2, file: context.file, completion: next)
        await fulfillment(of: [next.done], timeout: 3)
        XCTAssertEqual(next.value?.exposureCompensation, "-0.7 EV")
        let calls = await source.requests(); XCTAssertEqual(calls.count, 2)
    }

    @MainActor func testLocalExifPopulatesSameCacheBeforeRemoteRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try previewExifJpegFixture(), url = root.appendingPathComponent("sample.JPG")
        try data.write(to: url)
        let cache = NativePreviewExifCache(), source = FakeExifSource(.failure)
        let context = try exifPage(cache, source: source, root: root, size: data.count)
        defer { context.page.close() }
        _ = try await context.queue.originals(since: -1, rescan: true)
        let local = PreviewExifCompletionProbe(expectation(description: "local EXIF"))
        context.page.readLocalExif(sessionId: 1, requestId: 1, file: context.file, source: url.absoluteString, completion: local)
        await fulfillment(of: [local.done], timeout: 3)
        XCTAssertEqual(local.value?.aperture, "f/4")
        let remote = PreviewExifCompletionProbe(expectation(description: "same cached metadata"))
        context.page.readExif(sessionId: 1, requestId: 2, file: context.file, completion: remote)
        await fulfillment(of: [remote.done], timeout: 1)
        XCTAssertEqual(remote.value?.aperture, "f/4")
        let calls = await source.requests(); XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    private func fillCatalog(_ id: UUID, handles: [Int32], dated: Bool = false,
                             complete: Bool = true, changed: Bool = false) throws -> CameraCatalogSnapshot {
        let queue = NativeOriginalTransferQueue()
        var infos: [Int32: PtpObjectInfo] = [:]
        var files: [CameraFileInfo] = []
        for handle in handles {
            let info = try sampleInfo(handle, captureDate: dated ? "2026090\(handle)T120000" : nil)
            infos[handle] = info
            files.append(try XCTUnwrap(queue.enqueue(info: info, byDate: false, dayKey: 0)).file)
        }
        return CameraCatalogSnapshot(connectionID: id, revision: 0, storageIDs: [0x10001], files: files,
            objectInfos: infos, totalHandles: handles.count, metadataComplete: complete, changedWhileScanning: changed)
    }
    private func waitForFillIdle(_ store: CameraPreviewStore) async throws {
        for _ in 0..<500 {
            if !(await store.fillCounts()).running { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Background fill did not reach a bounded idle state")
    }

    func testBackgroundFillUsesOneWorkerAndPersistsTheCompleteCatalogWithoutAPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try thumbnailFixture(), id = UUID()
        let source = FillPreviewSource(results: [3: [.bytes(png)], 2: [.bytes(png)], 1: [.bytes(png)]])
        let store = CameraPreviewStore(source: source, connectionID: id)
        _ = await store.openDiskCache(root: root, cameraIdentity: "body")
        await store.startBackgroundFill(startDay: 0, endDay: 0, revision: 1)
        let snapshot = try fillCatalog(id, handles: [3, 2, 1])
        _ = await store.reconcile(snapshot)
        try await waitForFillIdle(store)
        let first = await source.stats()
        XCTAssertEqual(first.handles, [3, 2, 1]); XCTAssertEqual(first.maximumActive, 1)
        let disk = try CameraThumbnailDiskCache(root: root, cameraIdentity: "body")
        for info in snapshot.objectInfos.values { XCTAssertEqual(try disk.read(key: NativePreviewPolicy().thumbnailKey(info: info)), png) }
        await store.clearForMemoryPressure()
        _ = await store.reconcile(snapshot) // Rechecks disk after each full scan without re-reading the camera.
        try await waitForFillIdle(store)
        let second = await source.stats()
        XCTAssertEqual(second.handles, first.handles)
        await store.close()
    }

    func testBackgroundFillWaitsForExecutingQueueAndEveryForegroundUseToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), source = FillPreviewSource(results: [1: [.missing]])
        let store = CameraPreviewStore(source: source, connectionID: id)
        _ = await store.openDiskCache(root: root, cameraIdentity: "body")
        let first = await store.beginForegroundUse(), second = await store.beginForegroundUse()
        await store.setTransfersBusy(true)
        await store.startBackgroundFill(startDay: 0, endDay: 0, revision: 1)
        _ = await store.reconcile(try fillCatalog(id, handles: [1]))
        await store.endForegroundUse(first); await store.setTransfersBusy(false)
        let blocked = await source.stats(); XCTAssertTrue(blocked.handles.isEmpty)
        await store.endForegroundUse(second)
        try await waitForFillIdle(store)
        let done = await source.stats(); XCTAssertEqual(done.handles, [1])
        await store.endForegroundUse(second) // Duplicate release must not resume/retry anything twice.
        let counts = await store.fillCounts(); XCTAssertEqual(counts.pending, 0); XCTAssertEqual(counts.failed, 0)
        await store.close()
    }

    func testBackgroundFailureDoesNotHotLoopAndOnlyRealRangeChangeRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), source = FillPreviewSource(results: [1: [.busy, .missing]])
        let store = CameraPreviewStore(source: source, connectionID: id)
        _ = await store.openDiskCache(root: root, cameraIdentity: "body")
        await store.startBackgroundFill(startDay: 0, endDay: 0, revision: 1)
        _ = await store.reconcile(try fillCatalog(id, handles: [1]))
        try await waitForFillIdle(store)
        let failed = await store.fillCounts(); XCTAssertEqual(failed.failed, 1)
        await store.setTransfersBusy(false)
        await store.setPriorityRange(startDay: 0, endDay: 0, revision: 2)
        try await Task.sleep(nanoseconds: 30_000_000)
        let unchanged = await source.stats(); XCTAssertEqual(unchanged.handles, [1])
        await store.setPriorityRange(startDay: 20260901, endDay: 20260901, revision: 3)
        try await waitForFillIdle(store)
        let retried = await source.stats(); XCTAssertEqual(retried.handles, [1, 1])
        await store.close()
    }

    func testBackgroundPauseDrainsCurrentRequestThenResumesOnlyRemainingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let began = expectation(description: "first background request admitted")
        let id = UUID(), source = FillPreviewSource(results: [1: [.missing], 2: [.missing]], holdFirst: true, onFirst: { began.fulfill() })
        let store = CameraPreviewStore(source: source, connectionID: id)
        _ = await store.openDiskCache(root: root, cameraIdentity: "body")
        await store.startBackgroundFill(startDay: 0, endDay: 0, revision: 1)
        _ = await store.reconcile(try fillCatalog(id, handles: [1, 2]))
        await fulfillment(of: [began], timeout: 2)
        await store.setTransfersBusy(true)
        await source.releaseFirst()
        try await waitForFillIdle(store)
        let paused = await source.stats(); XCTAssertEqual(paused.handles, [1])
        let pending = await store.fillCounts(); XCTAssertEqual(pending.pending, 1)
        await store.setTransfersBusy(false)
        try await waitForFillIdle(store)
        let done = await source.stats(); XCTAssertEqual(done.handles, [1, 2]); XCTAssertEqual(done.maximumActive, 1)
        await store.close()
    }

    func testBackgroundFillRejectsOldScanTokenAndPartialCatalogUntilACompleteScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), source = FillPreviewSource(results: [1: [.missing]])
        let store = CameraPreviewStore(source: source, connectionID: id)
        _ = await store.openDiskCache(root: root, cameraIdentity: "body")
        await store.startBackgroundFill(startDay: 0, endDay: 0, revision: 1)
        let old = await store.beginCatalogScan(), newer = await store.beginCatalogScan()
        let rejected = await store.finishCatalogScan(try XCTUnwrap(old), snapshot: try fillCatalog(id, handles: [1]))
        XCTAssertFalse(rejected)
        let partial = await store.finishCatalogScan(try XCTUnwrap(newer), snapshot: try fillCatalog(id, handles: [1], complete: false))
        XCTAssertFalse(partial)
        let before = await source.stats(); XCTAssertTrue(before.handles.isEmpty)
        let final = await store.beginCatalogScan()
        let accepted = await store.finishCatalogScan(try XCTUnwrap(final), snapshot: try fillCatalog(id, handles: [1]))
        XCTAssertTrue(accepted)
        try await waitForFillIdle(store)
        let after = await source.stats(); XCTAssertEqual(after.handles, [1])
        await store.close()
    }
    func testBackgroundDiskFailureStopsAtCurrentFileAndManualRescanCanRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try thumbnailFixture(), id = UUID()
        let began = expectation(description: "background request before cache becomes unavailable")
        let source = FillPreviewSource(results: [1: [.bytes(png)], 2: [.bytes(png)]], holdFirst: true, onFirst: { began.fulfill() })
        let store = CameraPreviewStore(source: source, connectionID: id)
        _ = await store.openDiskCache(root: root, cameraIdentity: "body")
        let disk = try CameraThumbnailDiskCache(root: root, cameraIdentity: "body")
        await store.startBackgroundFill(startDay: 0, endDay: 0, revision: 1)
        let snapshot = try fillCatalog(id, handles: [1, 2])
        _ = await store.reconcile(snapshot)
        await fulfillment(of: [began], timeout: 2)
        try FileManager.default.removeItem(at: disk.directory)
        try Data([7]).write(to: disk.directory) // A regular file cannot be treated as a writable cache directory.
        await source.releaseFirst()
        try await waitForFillIdle(store)
        let blocked = await store.diskWritesBlocked
        XCTAssertTrue(blocked)
        let stopped = await source.stats(); XCTAssertEqual(stopped.handles, [1])
        try FileManager.default.removeItem(at: disk.directory)
        _ = await store.reconcile(snapshot)
        try await waitForFillIdle(store)
        let recovered = await source.stats(); XCTAssertEqual(recovered.handles, [1, 2])
        await store.close()
    }

    func testBackgroundFillRequiresDiskAndDoesNotIssueSpeculativeMemoryOnlyRequests() async throws {
        let source = FillPreviewSource(results: [1: [.missing]])
        let id = UUID(), store = CameraPreviewStore(source: source, connectionID: UUID())
        // A different-connection snapshot is rejected independently of missing disk configuration.
        let rejected = await store.reconcile(try fillCatalog(id, handles: [1]))
        XCTAssertFalse(rejected)
        let actual = CameraPreviewStore(source: source, connectionID: id)
        await actual.startBackgroundFill(startDay: 0, endDay: 0, revision: 1)
        _ = await actual.reconcile(try fillCatalog(id, handles: [1]))
        let counts = await actual.fillCounts(); XCTAssertFalse(counts.running); XCTAssertEqual(counts.pending, 1)
        let requests = await source.stats(); XCTAssertTrue(requests.handles.isEmpty)
        await actual.close(); await store.close()
    }

    func testBackgroundDatePriorityKeepsNewestRelayAndUsesSharedOrdering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), source = FillPreviewSource(results: [1: [.missing], 2: [.missing], 3: [.missing]])
        let store = CameraPreviewStore(source: source, connectionID: id)
        _ = await store.openDiskCache(root: root, cameraIdentity: "body")
        await store.startBackgroundFill(startDay: 0, endDay: 0, revision: 1)
        await store.setPriorityRange(startDay: 20260901, endDay: 20260901, revision: 3)
        await store.setPriorityRange(startDay: 20260903, endDay: 20260903, revision: 2)
        _ = await store.reconcile(try fillCatalog(id, handles: [3, 2, 1], dated: true))
        try await waitForFillIdle(store)
        let requests = await source.stats(); XCTAssertEqual(requests.handles, [1, 3, 2])
        await store.close()
    }

    func testRejectedBackgroundAdmissionSendsNothingConsumesNoTransactionAndKeepsSessionUsable() async throws {
        let wire = FakeCameraConnection(bytes: response(transaction: 1))
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        await expect(.operationInProgress) {
            _ = try await session.execute(operationCode: 0x100A, parameters: [1], backgroundAdmission: { false })
        }
        XCTAssertTrue(wire.sent().isEmpty)
        let closed = await session.isClosed(); XCTAssertFalse(closed)
        let result = try await session.execute(operationCode: 0x1004)
        XCTAssertEqual(result.code, 0x2001)
        XCTAssertEqual(wire.sent(), [hex("120000000600000001000000041001000000")])
    }

    func testQueuedBackgroundAdmissionRechecksAfterActiveTransactionFinishes() async throws {
        let reading = expectation(description: "foreground transaction holds the channel")
        reading.assertForOverFulfill = false
        let wire = FakeCameraConnection(onReceive: { reading.fulfill() })
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        let foreground = Task { try await session.execute(operationCode: 0x1004, timeout: 3) }
        await fulfillment(of: [reading], timeout: 1)
        let probe = BackgroundAdmissionProbe()
        let started = expectation(description: "background task submitted")
        let background = Task {
            started.fulfill()
            return try await session.execute(operationCode: 0x100A, parameters: [1],
                backgroundAdmission: { await probe.check() })
        }
        await fulfillment(of: [started], timeout: 1)
        // Give the submitted task an opportunity to enter the FIFO while the response is held.
        try await Task.sleep(nanoseconds: 50_000_000)
        let before = await probe.checks; XCTAssertEqual(before, 0)
        await probe.deny() // A foreground/scan state change while the background request is queued.
        wire.feed(response(transaction: 1))
        let first = try await foreground.value; XCTAssertEqual(first.code, 0x2001)
        do { _ = try await background.value; XCTFail("Queued work must recheck the current gate") }
        catch { XCTAssertEqual(error as? CameraStreamError, .operationInProgress) }
        let after = await probe.checks; XCTAssertEqual(after, 1)
        XCTAssertEqual(wire.sent().count, 1)
        wire.feed(response(transaction: 2))
        let next = try await session.execute(operationCode: 0x1004)
        XCTAssertEqual(next.code, 0x2001)
        XCTAssertEqual(wire.sent().last, hex("120000000600000001000000041002000000"))
    }

    @MainActor func testOriginalSinglePhotoControllerAcceptsNormalizedPNGAndRejectsMalformedInput() async throws {
        let decoder = PreviewImageDecoder()
        let image = try await decoder.decode(thumbnailFixture())
        let png = try await decoder.singlePhotoPNG(image)
        var closed = false
        let controller = SharedUiController.shared.singlePhotoPreview(data: png as NSData, title: "actual fixture",
            rotationDescription: "Rotate photo", onBack: { closed = true; return KotlinUnit() })
        XCTAssertNotNil(controller)
        controller?.loadViewIfNeeded()
        XCTAssertFalse(closed) // Construction must not dismiss or initiate camera IO.
        XCTAssertNil(SharedUiController.shared.singlePhotoPreview(data: Data() as NSData, title: "empty",
            rotationDescription: "Rotate photo", onBack: { KotlinUnit() }))
        var malformed = png
        malformed[16] = 0x7f // Oversized unsigned width in IHDR must be rejected before Skia allocation.
        XCTAssertNil(SharedUiController.shared.singlePhotoPreview(data: malformed as NSData, title: "oversized",
            rotationDescription: "Rotate photo", onBack: { KotlinUnit() }))
    }

    func testSinglePhotoPNGEncodingPreservesNormalizedSizeAndRejectsUnboundedImages() async throws {
        let decoder = PreviewImageDecoder()
        let image = try await decoder.decode(thumbnailFixture())
        let png = try await decoder.singlePhotoPNG(image)
        let decoded = try await decoder.decode(png)
        XCTAssertEqual(decoded.width, image.width); XCTAssertEqual(decoded.height, image.height)
        XCTAssertLessThanOrEqual(png.count, 20 * 1024 * 1024)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2049, height: 1, bitsPerComponent: 8,
            bytesPerRow: 2049 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let oversized = try XCTUnwrap(context.makeImage())
        do { _ = try await decoder.singlePhotoPNG(oversized); XCTFail("Unbounded bridge input must be rejected") }
        catch { guard case PreviewImageError.invalidSize = error else { return XCTFail("Unexpected error: \(error)") } }
    }

    private func thumbnailFixture() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8,
            bytesPerRow: 48, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.7, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    func testThumbnailDiskCachePersistsByCameraAndCompleteFileIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try thumbnailFixture()
        let key = NativePreviewPolicy().thumbnailKey(info: try sampleInfo(1))
        let first = try CameraThumbnailDiskCache(root: root, cameraIdentity: "body-one")
        XCTAssertTrue(try first.write(bytes, key: key))
        XCTAssertEqual(try first.read(key: key), bytes)
        XCTAssertEqual(try CameraThumbnailDiskCache(root: root, cameraIdentity: "body-one").read(key: key), bytes)
        XCTAssertNil(try CameraThumbnailDiskCache(root: root, cameraIdentity: "body-two").read(key: key))
        XCTAssertNil(try first.read(key: key + "different-size-or-date"))
        let unrelated = first.directory.appendingPathComponent("keep-user-note.txt")
        try Data([42]).write(to: unrelated)
        XCTAssertEqual(try first.reconcile(validKeys: []), 1)
        XCTAssertNil(try first.read(key: key))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([42]))
    }

    func testThumbnailDiskCacheRejectsInvalidBytesAndRepairsCorruptEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try CameraThumbnailDiskCache(root: root, cameraIdentity: "body")
        XCTAssertFalse(try cache.write(Data([1, 2, 3]), key: "photo"))
        XCTAssertFalse(try cache.write(Data(repeating: 1, count: 4 * 1024 * 1024 + 1), key: "photo"))
        let bytes = try thumbnailFixture()
        XCTAssertTrue(try cache.write(bytes, key: "photo"))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "jpg" })
        try Data([0]).write(to: file)
        XCTAssertNil(try cache.read(key: "photo"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try cache.write(bytes, key: "photo"))
        XCTAssertEqual(try cache.read(key: "photo"), bytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).contains { $0.hasSuffix(".tmp") })
    }

    func testThumbnailDiskCacheRefusesRootAndEntryLinksIncludingBrokenLinks() throws {
        let area = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: area) }
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        let outside = area.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = area.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try CameraThumbnailDiskCache(root: link, cameraIdentity: "body"))
        let broken = area.appendingPathComponent("broken-root")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: area.appendingPathComponent("missing"))
        XCTAssertThrowsError(try CameraThumbnailDiskCache(root: broken, cameraIdentity: "body"))
        let cache = try CameraThumbnailDiskCache(root: area.appendingPathComponent("cache"), cameraIdentity: "body")
        let bytes = try thumbnailFixture()
        XCTAssertTrue(try cache.write(bytes, key: "photo"))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "jpg" })
        let original = outside.appendingPathComponent("original.png")
        try bytes.write(to: original)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        XCTAssertThrowsError(try cache.read(key: "photo"))
        XCTAssertThrowsError(try cache.write(bytes, key: "photo"))
        _ = try cache.reconcile(validKeys: [])
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertTrue(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testThumbnailDiskCacheUsesStrictExpiryAndRecreatesAfterSystemPurge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start: Int64 = 1_700_000_000_000
        let expired = try CameraThumbnailDiskCache(root: root, cameraIdentity: "old", now: { start })
        let unknown = try CameraThumbnailDiskCache(root: root, cameraIdentity: "unknown-child", now: { start })
        try Data([9]).write(to: unknown.directory.appendingPathComponent("preserve.txt"))
        let bytes = try thumbnailFixture()
        XCTAssertTrue(try expired.write(bytes, key: "old-photo"))
        var current = start + Int64(90 * 24 * 60 * 60 * 1000)
        let active = try CameraThumbnailDiskCache(root: root, cameraIdentity: "current", now: { current })
        XCTAssertEqual(try active.cleanupExpired(), 0)
        current += 1
        XCTAssertEqual(try active.cleanupExpired(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.directory.path))
        XCTAssertTrue(try active.write(bytes, key: "current-photo"))
        try FileManager.default.removeItem(at: active.directory)
        XCTAssertNil(try active.read(key: "current-photo"))
        XCTAssertTrue(try active.write(bytes, key: "current-photo"))
        XCTAssertEqual(try active.read(key: "current-photo"), bytes)
    }

    func testPreviewStoreReusesDiskAfterMemoryPressureAndStoreReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try thumbnailFixture()
        let source = FakePreviewSource(thumbs: [.bytes(bytes)])
        let store = CameraPreviewStore(source: source)
        let opened = await store.openDiskCache(root: root, cameraIdentity: "body")
        XCTAssertTrue(opened)
        let info = try sampleInfo(1)
        let first = try await store.thumbnail(info: info)
        await store.clearForMemoryPressure()
        let second = try await store.thumbnail(info: info)
        let reopened = CameraPreviewStore(source: source)
        _ = await reopened.openDiskCache(root: root, cameraIdentity: "body")
        let third = try await reopened.thumbnail(info: info)
        XCTAssertEqual(first, bytes); XCTAssertEqual(second, bytes); XCTAssertEqual(third, bytes)
        let count = await source.counts()
        XCTAssertEqual(count.thumb, 1)
    }

    func testPreviewLocalThumbnailReadsDiskOfflineWithoutAnotherCameraRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try thumbnailFixture()
        let source = FakePreviewSource(thumbs: [.bytes(bytes)])
        let store = CameraPreviewStore(source: source)
        _ = await store.openDiskCache(root: root, cameraIdentity: "body")
        let info = try sampleInfo(1)
        _ = try await store.thumbnail(info: info)
        await store.clearForMemoryPressure(); await store.setConnected(false)
        let disk = try await store.thumbnail(info: info, allowRemote: false)
        XCTAssertEqual(disk, bytes)
        let memory = await store.cachedThumbnail(info: info); XCTAssertEqual(memory, bytes)
        let count = await source.counts(); XCTAssertEqual(count.thumb, 1)
    }

    func testPreviewLocalThumbnailMissNeverNegativeCachesOrStartsNetwork() async throws {
        let source = FakePreviewSource(thumbs: [.bytes(try thumbnailFixture())])
        let store = CameraPreviewStore(source: source); let info = try sampleInfo(1)
        let local = try await store.thumbnail(info: info, allowRemote: false)
        XCTAssertNil(local)
        let before = await source.counts(); XCTAssertEqual(before.thumb, 0)
        let remote = try await store.thumbnail(info: info)
        XCTAssertNotNil(remote)
        let after = await source.counts(); XCTAssertEqual(after.thumb, 1)
    }

    func testPreviewLocalThumbnailHonorsReconciledCatalogDeletion() async throws {
        let id = UUID(); let source = FakePreviewSource(thumbs: [.bytes(try thumbnailFixture())])
        let store = CameraPreviewStore(source: source, connectionID: id)
        let info = try sampleInfo(1); _ = try await store.thumbnail(info: info)
        let empty = CameraCatalogSnapshot(connectionID: id, revision: 0, storageIDs: [], files: [], objectInfos: [:],
            totalHandles: 0, metadataComplete: true, changedWhileScanning: false)
        _ = await store.reconcile(empty)
        let missing = try await store.thumbnail(info: info, allowRemote: false)
        XCTAssertNil(missing)
        let count = await source.counts(); XCTAssertEqual(count.thumb, 1)
    }

    func testPreviewReconcileRejectsPartialRacedAndWrongConnectionCatalogs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try thumbnailFixture()
        let id = UUID()
        let source = FakePreviewSource(thumbs: [.bytes(bytes)])
        let store = CameraPreviewStore(source: source, connectionID: id)
        _ = await store.openDiskCache(root: root, cameraIdentity: "body")
        let info = try sampleInfo(1)
        _ = try await store.thumbnail(info: info)
        let disk = try CameraThumbnailDiskCache(root: root, cameraIdentity: "body")
        let key = NativePreviewPolicy().thumbnailKey(info: info)
        for (connection, complete, changed) in [(id, false, false), (id, true, true), (UUID(), true, false)] {
            let snapshot = CameraCatalogSnapshot(connectionID: connection, revision: 0, storageIDs: [], files: [], objectInfos: [:],
                totalHandles: 0, metadataComplete: complete, changedWhileScanning: changed)
            let accepted = await store.reconcile(snapshot)
            XCTAssertFalse(accepted); XCTAssertEqual(try disk.read(key: key), bytes)
        }
        let empty = CameraCatalogSnapshot(connectionID: id, revision: 0, storageIDs: [], files: [], objectInfos: [:],
            totalHandles: 0, metadataComplete: true, changedWhileScanning: false)
        let accepted = await store.reconcile(empty)
        XCTAssertTrue(accepted); XCTAssertNil(try disk.read(key: key))
    }

    func testReconciledThumbnailCannotBeResurrectedByLateNetworkCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let requested = expectation(description: "thumbnail request started")
        let source = HeldPreviewSource(started: { requested.fulfill() })
        let id = UUID()
        let store = CameraPreviewStore(source: source, connectionID: id)
        _ = await store.openDiskCache(root: root, cameraIdentity: "body")
        let info = try sampleInfo(1)
        let operation = Task { try await store.thumbnail(info: info) }
        await fulfillment(of: [requested], timeout: 2)
        let empty = CameraCatalogSnapshot(connectionID: id, revision: 1, storageIDs: [], files: [], objectInfos: [:],
            totalHandles: 0, metadataComplete: true, changedWhileScanning: false)
        _ = await store.reconcile(empty)
        await source.complete(try thumbnailFixture())
        _ = try await operation.value
        let disk = try CameraThumbnailDiskCache(root: root, cameraIdentity: "body")
        XCTAssertNil(try disk.read(key: NativePreviewPolicy().thumbnailKey(info: info)))
    }

    func testClosedPreviewOwnerCannotWriteIntoAReconnectedCameraCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let requested = expectation(description: "request started before disconnect")
        let source = HeldPreviewSource(started: { requested.fulfill() })
        let store = CameraPreviewStore(source: source)
        _ = await store.openDiskCache(root: root, cameraIdentity: "same-body")
        let info = try sampleInfo(1)
        let operation = Task { try await store.thumbnail(info: info) }
        await fulfillment(of: [requested], timeout: 2)
        await store.close()
        let reconnected = try CameraThumbnailDiskCache(root: root, cameraIdentity: "same-body")
        await source.complete(try thumbnailFixture())
        do { _ = try await operation.value; XCTFail("Closed owner must reject late completion") }
        catch { XCTAssertTrue(error is CameraStreamError) }
        XCTAssertNil(try reconnected.read(key: NativePreviewPolicy().thumbnailKey(info: info)))
        let reopened = await store.openDiskCache(root: root, cameraIdentity: "same-body")
        XCTAssertFalse(reopened)
    }

    @MainActor func testBrowsePreferencesDefaultReadDoesNotWriteAndRoundTripUsesSharedNormalization() throws {
        let suite = "ZTransferTests.browse.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowsePreferencesStore(defaults: defaults)
        let initial = try XCTUnwrap(store.read())
        XCTAssertEqual(initial.columns, 3); XCTAssertTrue(initial.collapseBursts)
        XCTAssertNil(defaults.object(forKey: BrowsePreferencesStore.key))
        let value = NativeBrowsePreferences(columns: 100, collapseBursts: false, extensions: [".JPG", ".NEF"],
            protectedOnly: true, burstOnly: true, untransferredOnly: true, startDay: 20261231, endDay: 20260101)
        XCTAssertTrue(store.save(value))
        let reopened = try XCTUnwrap(BrowsePreferencesStore(defaults: defaults).read())
        XCTAssertEqual(reopened.columns, 4); XCTAssertFalse(reopened.collapseBursts)
        XCTAssertEqual(reopened.extensions, [".JPG", ".NEF"])
        XCTAssertTrue(reopened.protectedOnly && reopened.burstOnly && reopened.untransferredOnly)
        XCTAssertEqual(reopened.startDay, 20260101); XCTAssertEqual(reopened.endDay, 20261231)
        let data = try XCTUnwrap(defaults.data(forKey: BrowsePreferencesStore.key))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(document["storageSlot"])
        XCTAssertTrue(store.save(NativeBrowsePreferences.companion.defaults()))
        XCTAssertNil(store.read()?.extensions); XCTAssertEqual(store.read()?.startDay, 0)
        XCTAssertFalse(try XCTUnwrap(store.read()).untransferredOnly)
    }

    @MainActor func testBrowsePreferencesPreserveCorruptFutureWrongTypeAndOversizedValues() throws {
        let suite = "ZTransferTests.browse.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowsePreferencesStore(defaults: defaults)
        XCTAssertTrue(store.save(NativeBrowsePreferences.companion.defaults()))
        let valid = try XCTUnwrap(defaults.data(forKey: BrowsePreferencesStore.key))
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        future["version"] = 999
        let invalidValues = [Data("broken".utf8), try JSONSerialization.data(withJSONObject: future), Data(repeating: 0, count: 65 * 1024)]
        for original in invalidValues {
            defaults.set(original, forKey: BrowsePreferencesStore.key)
            XCTAssertNil(store.read()); XCTAssertFalse(store.save(NativeBrowsePreferences.companion.defaults()))
            XCTAssertEqual(defaults.data(forKey: BrowsePreferencesStore.key), original)
        }
        defaults.set("wrong stored type", forKey: BrowsePreferencesStore.key)
        XCTAssertNil(store.read()); XCTAssertFalse(store.save(NativeBrowsePreferences.companion.defaults()))
        XCTAssertEqual(defaults.string(forKey: BrowsePreferencesStore.key), "wrong stored type")
    }

    @MainActor func testBrowsePreferencesEmptyExtensionFilterIsNotSilentlyConvertedToAllTypes() throws {
        let suite = "ZTransferTests.browse.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowsePreferencesStore(defaults: defaults)
        XCTAssertTrue(store.save(NativeBrowsePreferences(columns: 2, collapseBursts: true, extensions: [],
            protectedOnly: false, burstOnly: false, untransferredOnly: false, startDay: 20260229, endDay: 20260905)))
        let read = try XCTUnwrap(store.read())
        XCTAssertEqual(read.extensions, []); XCTAssertEqual(read.startDay, 0); XCTAssertEqual(read.endDay, 0)
    }

    func testFilesFilterCalendarUsesLocalGregorianDayRatherThanUTC() throws {
        let moment = Date(timeIntervalSince1970: 0)
        let east = try XCTUnwrap(TimeZone(secondsFromGMT: 9 * 3600))
        let west = try XCTUnwrap(TimeZone(secondsFromGMT: -8 * 3600))
        XCTAssertEqual(OriginalFilesPageBridge.localDayKey(at: moment, timeZone: east), 19700101)
        XCTAssertEqual(OriginalFilesPageBridge.localDayKey(at: moment, timeZone: west), 19691231)
    }

    @MainActor func testSharedFilesFilterHostLoadsWithEmptySecondCardAndRealEmptyOriginalIndex() async throws {
        let camera = stationCamera(command: FakeCameraConnection(bytes: Data()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        let bridge = OriginalFilesPageBridge(connectionID: camera.connectionID,
            catalog: CameraCatalog(source: camera, stationMode: true), queue: queue,
            previews: CameraPreviewStore(source: camera), exifSource: camera, exifCache: NativePreviewExifCache(), stationMode: true)
        bridge.setConnected(true)
        let info = try sampleInfo(7)
        let file = try XCTUnwrap(NativeOriginalTransferQueue().enqueue(info: info, byDate: false, dayKey: 0)).file
        let snapshot = CameraCatalogSnapshot(connectionID: camera.connectionID, revision: 0, storageIDs: [0x10001, 0x20001],
            files: [file], objectInfos: [7: info], totalHandles: 1, metadataComplete: true, changedWhileScanning: false)
        XCTAssertTrue(bridge.acceptCatalog(snapshot, sequence: bridge.model.beginScan()))
        let originals = try await queue.originals(since: -1, rescan: true)
        XCTAssertTrue(originals.fullSnapshot); XCTAssertTrue(originals.entries.isEmpty)
        XCTAssertTrue(bridge.model.publishOriginals(update: NativeOriginalIndexUpdate(revision: originals.revision,
            baseRevision: originals.baseRevision, fullSnapshot: originals.fullSnapshot)))
        let controller = SharedUiController.shared.originalFiles(model: bridge.model, languageTag: "en", onBack: { KotlinUnit() })
        controller.loadViewIfNeeded(); XCTAssertNotNil(controller.view)
        bridge.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOriginalIndexScansOnlyRootAndSharedDateBucketsWithoutFollowingLinks() throws {
        let area = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = area.appendingPathComponent("originals", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: area) }
        for folder in ["ZT2026-09-05", "ZT2026-99-99", "frames", "ZT2026-09-05/nested"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        for name in ["ROOT.JPG", "ZT2026-09-05/DATE.NEF", "ZT2026-99-99/SHAPE.JPG",
                     "frames/EFFECT.JPG", "ZT2026-09-05/nested/DEEP.JPG", ".HIDDEN.JPG",
                     ".00000000-0000-0000-0000-000000000000_.nkpart_x.JPG", ".nkpart_legacy.JPG"] {
            try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
        }
        let outside = area.appendingPathComponent("outside.JPG")
        try Data([9]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("LINK.JPG"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("BROKEN.JPG"), withDestinationURL: area.appendingPathComponent("missing.JPG"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ZT2026-09-06"), withDestinationURL: area)
        let cache = OriginalFileIndexCache()
        try cache.scan(root: root)
        let snapshot = cache.update(since: -1)
        XCTAssertTrue(snapshot.fullSnapshot)
        XCTAssertEqual(Set(snapshot.entries.map(\.name)), ["ROOT.JPG", "DATE.NEF", "SHAPE.JPG", ".HIDDEN.JPG"])
        XCTAssertTrue(snapshot.entries.allSatisfy { $0.size == 3 })
        XCTAssertNil(snapshot.entries.first(where: { $0.name == "ROOT.JPG" })?.folder)
        XCTAssertEqual(snapshot.entries.first(where: { $0.name == "DATE.NEF" })?.folder, "ZT2026-09-05")
        XCTAssertFalse(SandboxTransferFile.isPrivatePartName(".HIDDEN.JPG"))
        XCTAssertFalse(SandboxTransferFile.isPrivatePartName(".not-a-uuid_.nkpart_x.JPG"))
        XCTAssertTrue(SandboxTransferFile.isPrivatePartName(".00000000-0000-0000-0000-000000000000_.nkpart_x.JPG"))
        let rootLink = area.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
        XCTAssertThrowsError(try cache.scan(root: rootLink))
        let brokenRoot = area.appendingPathComponent("broken-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: brokenRoot, withDestinationURL: area.appendingPathComponent("missing", isDirectory: true))
        XCTAssertThrowsError(try cache.scan(root: brokenRoot))
        XCTAssertEqual(cache.update(since: -1).entries, snapshot.entries)
    }

    func testOriginalIndexFailedScanRetainsSnapshotAndCompleteRescanReflectsRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try SandboxTransferFile(directory: root, name: "A.JPG", declaredSize: 1, captureDate: nil)
        try file.write(Data([1])); let saved = try file.commit(expectedBytes: 1)
        let cache = OriginalFileIndexCache(); try cache.scan(root: root)
        let old = cache.update(since: -1)
        XCTAssertThrowsError(try cache.scan(root: saved.url)) // A file where a root is expected is not an empty directory.
        XCTAssertEqual(cache.update(since: -1).entries, old.entries)
        XCTAssertEqual(cache.update(since: -1).revision, old.revision)
        try FileManager.default.removeItem(at: saved.url)
        try cache.scan(root: root)
        let next = cache.update(since: old.revision)
        XCTAssertTrue(next.fullSnapshot); XCTAssertTrue(next.entries.isEmpty)
        XCTAssertGreaterThan(next.revision, old.revision)
    }

    func testOriginalStoreRecordsOnlyVerifiedDownloadAndRestoresIndexFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraOriginalStore(root: root)
        let before = try await store.originals(since: -1, rescan: true)
        XCTAssertTrue(before.entries.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let camera = apCamera(command: FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 3, payload: Data("ABC".utf8))))
        _ = try await camera.connect(guid: Data(0...15))
        let saved = try await store.download(camera: camera, info: sampleInfo(7), byDate: false, dayKey: 0)
        let delta = try await store.originals(since: before.revision, rescan: false)
        XCTAssertFalse(delta.fullSnapshot); XCTAssertEqual(delta.entries.count, 1)
        XCTAssertEqual(delta.entries.first?.url, saved.url)
        XCTAssertEqual(delta.entries.first?.size, saved.bytes)
        let unchanged = try await store.originals(since: delta.revision, rescan: false)
        XCTAssertFalse(unchanged.fullSnapshot); XCTAssertTrue(unchanged.entries.isEmpty)
        let reopened = CameraOriginalStore(root: root)
        let rebuilt = try await reopened.originals(since: -1, rescan: true)
        XCTAssertEqual(rebuilt.entries, delta.entries) // No queue history or sidecar is required after restart.
        await camera.abort()
    }

    func testOriginalIndexJournalIsBoundedAndOldConsumersReceiveFullSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = OriginalFileIndexCache(); try cache.scan(root: root)
        let base = cache.update(since: -1).revision
        // Cache-unit records only, no fake media is written or exposed as a real device result.
        for number in 0..<1025 {
            cache.record(SavedCameraFile(url: root.appendingPathComponent("\(number).JPG"), bytes: 1, sha256: "unit"), folder: nil)
        }
        let old = cache.update(since: base)
        XCTAssertTrue(old.fullSnapshot); XCTAssertEqual(old.entries.count, 1025)
        let recent = cache.update(since: old.revision - 1)
        XCTAssertFalse(recent.fullSnapshot); XCTAssertEqual(recent.entries.count, 1)
        XCTAssertTrue(cache.update(since: old.revision).entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testCancelledOriginalIndexScanDoesNotReplacePreviousSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("A.JPG"))
        let store = CameraOriginalStore(root: root)
        let before = try await store.originals(since: -1, rescan: true)
        try Data([2]).write(to: root.appendingPathComponent("B.JPG"))
        let scan = Task { try await store.originals(since: before.revision, rescan: true) }
        scan.cancel()
        do { _ = try await scan.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let retained = try await store.originals(since: -1, rescan: false)
        XCTAssertEqual(retained.entries, before.entries)
        let refreshed = try await store.originals(since: before.revision, rescan: true)
        XCTAssertTrue(refreshed.fullSnapshot); XCTAssertEqual(refreshed.entries.count, 2)
    }

    @MainActor func testRealFilesControllerUsesCompleteCatalogWithoutStartingQueue() async throws {
        let camera = stationCamera(command: FakeCameraConnection(bytes: Data()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        let bridge = OriginalFilesPageBridge(connectionID: camera.connectionID,
            catalog: CameraCatalog(source: camera, stationMode: true), queue: queue,
            previews: CameraPreviewStore(source: camera), exifSource: camera, exifCache: NativePreviewExifCache(), stationMode: true)
        bridge.setConnected(true)
        let info = try sampleInfo(7)
        let file = try XCTUnwrap(NativeOriginalTransferQueue().enqueue(info: info, byDate: false, dayKey: 0)).file
        let snapshot = CameraCatalogSnapshot(connectionID: camera.connectionID, revision: 0, storageIDs: [0x10001],
            files: [file], objectInfos: [7: info], totalHandles: 1, metadataComplete: true, changedWhileScanning: false)
        XCTAssertTrue(bridge.acceptCatalog(snapshot, sequence: bridge.model.beginScan()))
        let controller = SharedUiController.shared.originalFiles(model: bridge.model, languageTag: "zh-Hant", onBack: { KotlinUnit() })
        controller.loadViewIfNeeded()
        XCTAssertNotNil(controller.view)
        let before = await queue.snapshot()
        XCTAssertTrue(before.rows.isEmpty); XCTAssertFalse(before.running)
        bridge.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testFilesBridgeRejectsDuplicateCatalogAndStaleEnqueueWithoutTouchingQueue() async throws {
        let camera = stationCamera(command: FakeCameraConnection(bytes: Data()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        let bridge = OriginalFilesPageBridge(connectionID: camera.connectionID,
            catalog: CameraCatalog(source: camera, stationMode: true), queue: queue,
            previews: CameraPreviewStore(source: camera), exifSource: camera, exifCache: NativePreviewExifCache(), stationMode: true)
        bridge.setConnected(true)
        let info = try sampleInfo(7)
        let file = try XCTUnwrap(NativeOriginalTransferQueue().enqueue(info: info, byDate: false, dayKey: 0)).file
        let sequence = bridge.model.beginScan()
        let invalid = CameraCatalogSnapshot(connectionID: camera.connectionID, revision: 0, storageIDs: [0x10001],
            files: [file, file], objectInfos: [7: info], totalHandles: 2, metadataComplete: true, changedWhileScanning: false)
        XCTAssertFalse(bridge.acceptCatalog(invalid, sequence: sequence)) // No dictionary duplicate-key trap.
        let completion = FilesEnqueueCompletionProbe()
        let handles = KotlinIntArray(size: 1); handles.set(index: 0, value: 7)
        bridge.enqueue(handles: handles, scanSequence: sequence, completion: completion)
        XCTAssertEqual(completion.count, 0)
        let state = await queue.snapshot(); XCTAssertTrue(state.rows.isEmpty)
        bridge.close(); XCTAssertEqual(bridge.model.beginScan(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testCatalogBatchPreservesOrderAndDoesNotStartWhenDeferred() async throws {
        let camera = stationCamera(command: FakeCameraConnection(bytes: Data()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        let infos = try [sampleInfo(9), sampleInfo(7)]
        let mapper = NativeOriginalTransferQueue()
        let files = try infos.map { try XCTUnwrap(mapper.enqueue(info: $0, byDate: false, dayKey: 0)).file }
        let accepted = await queue.enqueueCatalog(infos, files: files, byDate: false, dayKey: 0, deferred: true)
        XCTAssertEqual(accepted, 2)
        let state = await queue.snapshot()
        XCTAssertEqual(state.rows.map(\.handle), [9, 7]); XCTAssertFalse(state.running)
        XCTAssertTrue(state.rows.allSatisfy { $0.status == "WAITING" })
        let cancelled = Task { await queue.enqueueCatalog(infos, files: files, byDate: false, dayKey: 0, deferred: true) }
        cancelled.cancel()
        let rejected = await cancelled.value
        XCTAssertEqual(rejected, 0)
        let unchanged = await queue.snapshot(); XCTAssertEqual(unchanged.rows.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    @MainActor func testSharedQueueCarriesActualStationModeWithoutSignalStrengthSample() {
        let camera = stationCamera(command: FakeCameraConnection(bytes: Data()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bridge = OriginalQueuePageBridge(connectionID: camera.connectionID,
            queue: CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root)),
            previews: CameraPreviewStore(source: camera), stationMode: camera.stationMode)
        XCTAssertTrue(bridge.model.stationMode)
        bridge.setConnected(true)
        let controller = SharedUiController.shared.originalQueue(model: bridge.model, languageTag: "en", onBack: { KotlinUnit() })
        controller.loadViewIfNeeded()
        XCTAssertNotNil(controller.view)
        bridge.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    @MainActor func testRealQueuePageLoadsSharedControllerWithoutStartingWaitingTasks() async throws {
        let camera = apCamera(command: FakeCameraConnection(bytes: Data()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        _ = await queue.enqueue(try sampleInfo(7), byDate: false, dayKey: 0, deferred: true)
        let bridge = OriginalQueuePageBridge(connectionID: camera.connectionID, queue: queue, previews: CameraPreviewStore(source: camera))
        bridge.publish(await queue.snapshot())
        let controller = SharedUiController.shared.originalQueue(model: bridge.model, languageTag: "zh-Hans", onBack: { KotlinUnit() })
        controller.loadViewIfNeeded()
        XCTAssertNotNil(controller.view)
        let state = await queue.snapshot()
        XCTAssertFalse(state.running)
        XCTAssertEqual(state.rows.first?.status, "WAITING")
        bridge.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testQueuePagePublishesActorResultBeforeAcknowledgingRemoval() async throws {
        let camera = apCamera(command: FakeCameraConnection(bytes: Data()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        let value = await queue.enqueue(try sampleInfo(7), byDate: false, dayKey: 0, deferred: true)
        let id = try XCTUnwrap(value)
        await queue.withdraw(id)
        let bridge = OriginalQueuePageBridge(connectionID: camera.connectionID, queue: queue, previews: CameraPreviewStore(source: camera))
        bridge.publish(await queue.snapshot())
        let done = expectation(description: "actor removal acknowledged")
        let completion = QueueActionCompletionProbe(done)
        bridge.execute(command: .remove, taskId: id, excludedTaskIds: KotlinLongArray(size: 0), completion: completion)
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(completion.succeeded, true)
        let latest = await queue.snapshot()
        XCTAssertTrue(latest.rows.isEmpty)
        let alreadyPublished = NativeQueuePageSnapshot(connectionId: camera.connectionID.uuidString,
            sequence: Int64(bitPattern: latest.sequence), historyRevision: Int64(bitPattern: latest.historyRevision),
            running: false, paused: false)
        XCTAssertFalse(bridge.model.publish(snapshot: alreadyPublished)) // ack already published this sequence
        bridge.close()
        let late = NativeQueuePageSnapshot(connectionId: camera.connectionID.uuidString,
            sequence: Int64(bitPattern: latest.sequence) + 1, historyRevision: Int64(bitPattern: latest.historyRevision) + 1,
            running: false, paused: false)
        XCTAssertFalse(bridge.model.publish(snapshot: late))
    }
    @MainActor func testSharedComposeControllerLoadsThroughExportedUIKitFactory() {
        // This is intentionally a real UIKit/Compose smoke test, not a fake Swift screen.
        // It can run only on Mac/iOS after the Kotlin framework and Swift bridge compile.
        let controller = SharedUiController.shared.componentProbe()
        controller.loadViewIfNeeded()
        XCTAssertNotNil(controller.view)
    }

    func testNativeFilterArgbByteOrderAndSourcePreservation() async throws {
        let selection = try XCTUnwrap(NativePhotoFilterCatalog.shared.selection(index: 0, intensityPercent: 80))
        let source = Data([0, 17, 34, 51, 128, 64, 96, 128, 255, 32, 64, 128, 255, 255, 255, 255])
        let expected = KotlinIntArray(size: 4)
        for (index, value) in [UInt32(0x00112233), 0x80406080, 0xff204080, 0xffffffff].enumerated() {
            expected.set(index: Int32(index), value: Int32(bitPattern: value))
        }
        XCTAssertTrue(NativePhotoFilter(selection: selection, preserveAlpha: true).render(pixels: expected, count: 4))
        let filtered = try await PhotoFilterPreviewRenderer().renderArgb(source, selection: selection, preserveAlpha: true)
        for index in 0..<4 {
            let expectedValue = UInt32(bitPattern: expected.get(index: Int32(index)))
            let actual = filtered[(index * 4)..<(index * 4 + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            XCTAssertEqual(actual, expectedValue)
        }
        XCTAssertEqual(Array(filtered.prefix(4)), [0, 17, 34, 51]) // shared preserves hidden RGB at zero alpha
        XCTAssertEqual(source, Data([0, 17, 34, 51, 128, 64, 96, 128, 255, 32, 64, 128, 255, 255, 255, 255]))
    }

    func testOpaqueCGImageFilterMatchesStraightSharedPixelsWithoutFlipping() async throws {
        let selection = try XCTUnwrap(NativePhotoFilterCatalog.shared.selection(index: 0, intensityPercent: 100))
        let bytes = Data([255, 32, 64, 128, 255, 224, 128, 16, 255, 255, 255, 255, 255, 0, 0, 0])
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        let source = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let renderer = PhotoFilterPreviewRenderer()
        let expected = try await renderer.renderArgb(bytes, selection: selection, preserveAlpha: false)
        let image = try await renderer.render(source, selection: selection)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        let actual = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(try XCTUnwrap(source.dataProvider?.data) as Data, bytes)
    }

    func testNativeFilterRejectsMalformedBufferAndPreCancelledTask() async throws {
        let selection = try XCTUnwrap(NativePhotoFilterCatalog.shared.selection(index: 0, intensityPercent: 80))
        let renderer = PhotoFilterPreviewRenderer()
        do { _ = try await renderer.renderArgb(Data([1, 2, 3]), selection: selection, preserveAlpha: true); XCTFail("Invalid ARGB") }
        catch { XCTAssertTrue(error is PhotoFilterPreviewError) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await renderer.renderArgb(Data([255, 1, 2, 3]), selection: selection, preserveAlpha: true)
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testImageIOMetadataMappingUsesSharedNormalization() {
        let properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "NIKON CORPORATION", kCGImagePropertyTIFFModel as String: "NIKON Z 8"],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFNumber as String: 4.0, kCGImagePropertyExifExposureTime as String: 0.008,
                kCGImagePropertyExifISOSpeedRatings as String: [640, 800], kCGImagePropertyExifFocalLength as String: 85.0,
                kCGImagePropertyExifLensModel as String: "  NIKKOR Z 85mm  ", kCGImagePropertyExifDateTimeOriginal as String: "2026:08:10 14:25:36"],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 33.5, kCGImagePropertyGPSLatitudeRef as String: "S",
                kCGImagePropertyGPSLongitude as String: 151.25, kCGImagePropertyGPSLongitudeRef as String: "E",
                kCGImagePropertyGPSAltitude as String: 123.4, kCGImagePropertyGPSAltitudeRef as String: 1]
        ]
        let metadata = PhotoMetadataReader.metadata(properties)
        XCTAssertEqual(metadata.model, "NIKON Z 8")
        XCTAssertEqual(metadata.aperture, "f/4")
        XCTAssertEqual(metadata.shutter, "1/125")
        XCTAssertEqual(metadata.iso, "ISO640")
        XCTAssertEqual(metadata.focalLength, "85mm")
        XCTAssertEqual(metadata.lensModel, "NIKKOR Z 85mm")
        XCTAssertEqual(metadata.dateTime, "2026-08-10 14:25:36")
        XCTAssertEqual(metadata.latitude?.doubleValue, -33.5)
        XCTAssertEqual(metadata.longitude?.doubleValue, 151.25)
        XCTAssertEqual(metadata.altitudeMeters?.doubleValue, -123.4)
        XCTAssertNil(metadata.address)
    }

    func testImageIOMetadataInvalidFieldsAndApexFallback() {
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFNumber as String: true, kCGImagePropertyExifApertureValue as String: 4,
                kCGImagePropertyExifExposureTime as String: "1/0", kCGImagePropertyExifShutterSpeedValue as String: 7],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 91,
                kCGImagePropertyGPSLongitude as String: "bad", kCGImagePropertyGPSAltitude as String: 0]
        ]
        let metadata = PhotoMetadataReader.metadata(properties)
        XCTAssertEqual(metadata.aperture, "f/4")
        XCTAssertEqual(metadata.shutter, "1/128")
        XCTAssertNil(metadata.latitude)
        XCTAssertNil(metadata.longitude)
        XCTAssertNil(metadata.altitudeMeters)
        XCTAssertNil(PhotoMetadataReader.metadata([:]).model)
    }

    func testApplePhotoDecimalFormattingUsesUSAndHalfUpBoundaries() {
        let formatter = ApplePhotoDecimalFormatter()
        XCTAssertEqual(formatter.fixed(value: 2.25, fractionDigits: 1), "2.3")
        XCTAssertEqual(formatter.fixed(value: -12.5, fractionDigits: 0), "-13")
        XCTAssertEqual(formatter.fixed(value: 1234.5, fractionDigits: 1), "1234.5")
        XCTAssertEqual(formatter.fixed(value: 1, fractionDigits: 1), "1.0")
    }

    func testMetadataFileReadDoesNotModifyOriginalBytes() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary:
            [kCGImagePropertyTIFFMake: "NIKON", kCGImagePropertyTIFFModel: "Z test"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = bytes as Data
        try original.write(to: url, options: .withoutOverwriting)
        let metadata = try await PhotoMetadataReader().read(url)
        XCTAssertEqual(metadata.model, "Z test")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testGattFIFORequiresAuthoritativeAcknowledgement() async throws {
        let driver = FakeGpsGattDriver()
        let connection = try readyGatt(driver)
        defer { connection.close() }
        let firstSent = expectation(description: "first write submitted")
        driver.onWrite = { firstSent.fulfill() }
        let first = Task { try await connection.write(Data(repeating: 1, count: 17), channel: .pair) }
        await fulfillment(of: [firstSent], timeout: 1)
        driver.onWrite = nil
        let queued = expectation(description: "second write enqueued")
        let second = Task { queued.fulfill(); try await connection.write(Data(repeating: 2, count: 32), channel: .controllerId) }
        await fulfillment(of: [queued], timeout: 1)
        XCTAssertEqual(driver.writes.count, 1)
        driver.reply(.geo) // unrelated callback must not finish PAIR
        XCTAssertEqual(driver.writes.count, 1)
        driver.reply(.pair)
        try await first.value
        XCTAssertEqual(driver.writes.map { $0.0 }, [.pair, .controllerId])
        driver.reply(.controllerId)
        try await second.value
    }

    @MainActor func testGattQueuedCancellationLeavesActiveWriteAlive() async throws {
        let driver = FakeGpsGattDriver()
        let connection = try readyGatt(driver)
        defer { connection.close() }
        let sent = expectation(description: "active")
        driver.onWrite = { sent.fulfill() }
        let first = Task { try await connection.write(Data(repeating: 0, count: 17), channel: .pair) }
        await fulfillment(of: [sent], timeout: 1)
        driver.onWrite = nil
        let queued = expectation(description: "queued")
        let second = Task { queued.fulfill(); try await connection.write(Data(repeating: 0, count: 41), channel: .geo) }
        await fulfillment(of: [queued], timeout: 1)
        second.cancel()
        do { try await second.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(connection.phase, .gattReady)
        XCTAssertEqual(driver.writes.count, 1)
        driver.reply(.pair)
        try await first.value
    }

    @MainActor func testGattTimeoutClosesAndIgnoresLateSameCharacteristicAck() async throws {
        let driver = FakeGpsGattDriver()
        let connection = try readyGatt(driver, timeout: 0.02)
        let oldCallback = driver.eventHandler
        do { try await connection.write(Data(repeating: 0, count: 17), channel: .pair); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? GpsGattError, .timedOut) }
        XCTAssertEqual(connection.phase, .failed)
        XCTAssertTrue(driver.closed)
        oldCallback?(.written(.pair, nil))
        oldCallback?(.ready(maximumWriteLength: 512))
        XCTAssertEqual(connection.phase, .failed)
        do { try await connection.write(Data(repeating: 0, count: 17), channel: .pair); XCTFail("Cannot reuse poisoned owner") }
        catch { XCTAssertEqual(error as? GpsGattError, .invalidState) }
    }

    @MainActor func testGattRejectsInvalidAndOversizePacketsWithoutSplitting() async throws {
        let driver = FakeGpsGattDriver()
        driver.maximumWriteLength = 20
        let connection = try readyGatt(driver)
        defer { connection.close() }
        do { try await connection.write(Data(repeating: 0, count: 32), channel: .controllerId); XCTFail("Needs supported long write") }
        catch { XCTAssertEqual(error as? GpsGattError, .payloadTooLarge) }
        do { try await connection.write(Data(repeating: 0, count: 16), channel: .pair); XCTFail("Wrong wire size") }
        catch { XCTAssertEqual(error as? GpsGattError, .invalidPayload) }
        XCTAssertTrue(driver.writes.isEmpty)
        XCTAssertEqual(connection.phase, .gattReady)
    }

    @MainActor func testGattNotificationOverflowFailsInsteadOfDroppingHandshake() throws {
        let driver = FakeGpsGattDriver()
        let connection = try readyGatt(driver)
        for _ in 0..<33 { driver.eventHandler?(.value(.pair, Data(repeating: 0, count: 17))) }
        XCTAssertEqual(connection.phase, .failed)
        XCTAssertEqual(connection.failure as? GpsGattError, .eventOverflow)
        XCTAssertTrue(driver.closed)
    }

    @MainActor func testGattCloseResumesActiveAndQueuedWritesExactlyOnce() async throws {
        let driver = FakeGpsGattDriver()
        let connection = try readyGatt(driver)
        let sent = expectation(description: "sent")
        driver.onWrite = { sent.fulfill() }
        let first = Task { try await connection.write(Data(repeating: 0, count: 17), channel: .pair) }
        await fulfillment(of: [sent], timeout: 1)
        let queued = expectation(description: "queued")
        let second = Task { queued.fulfill(); try await connection.write(Data(repeating: 0, count: 41), channel: .geo) }
        await fulfillment(of: [queued], timeout: 1)
        let oldCallback = driver.eventHandler
        connection.close(); connection.close()
        oldCallback?(.written(.pair, nil))
        for operation in [first, second] {
            do { try await operation.value; XCTFail("Expected close") } catch { XCTAssertEqual(error as? GpsGattError, .closed) }
        }
        XCTAssertEqual(driver.writes.count, 1)
    }

    @MainActor private func readyGatt(_ driver: FakeGpsGattDriver, timeout: TimeInterval = 3) throws -> NikonGpsGattConnection {
        let connection = NikonGpsGattConnection(driver: driver, operationTimeout: timeout)
        try connection.scan()
        try connection.connect(driver.candidate.id)
        XCTAssertEqual(connection.phase, .gattReady)
        return connection
    }

    func testFragmentedReadsPreserveNextPacket() async throws {
        let wire = FakeCameraConnection(bytes: Data([1, 2, 3, 4, 5, 6]), chunkSize: 2)
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let first = try await stream.readExactly(4, timeout: 1)
        let second = try await stream.readExactly(2, timeout: 1)
        XCTAssertEqual(first, Data([1, 2, 3, 4]))
        XCTAssertEqual(second, Data([5, 6]))
    }

    func testFinalBytesAreDeliveredBeforeEOF() async throws {
        let wire = FakeCameraConnection(bytes: Data([1, 2]), eof: true)
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let bytes = try await stream.readExactly(2, timeout: 1)
        XCTAssertEqual(bytes, Data([1, 2]))
        await expect(.endOfStream) { _ = try await stream.readExactly(1, timeout: 1) }
    }

    func testTruncatedReadClosesStream() async throws {
        let stream = CameraTCPStream(connection: FakeCameraConnection(bytes: Data([1]), eof: true))
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        await expect(.endOfStream) { _ = try await stream.readExactly(2, timeout: 1) }
        await expect(.notConnected) { try await stream.write(Data([1]), timeout: 1) }
    }

    func testConnectTimeoutIgnoresLateReady() async {
        let wire = FakeCameraConnection(autoReady: false)
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        await expect(.timedOut) { try await stream.connect(timeout: 0.05) }
        wire.lateReady()
        await expect(.notConnected) { try await stream.write(Data([1]), timeout: 1) }
    }

    func testReadTimeoutPoisonsConnection() async throws {
        let stream = CameraTCPStream(connection: FakeCameraConnection())
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        await expect(.timedOut) { _ = try await stream.readExactly(8, timeout: 0.05) }
        await expect(.notConnected) { _ = try await stream.readExactly(8, timeout: 1) }
    }

    func testWriteTimeoutPoisonsConnection() async throws {
        let stream = CameraTCPStream(connection: FakeCameraConnection(holdWrites: true))
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        await expect(.timedOut) { try await stream.write(Data([1]), timeout: 0.05) }
        await expect(.notConnected) { _ = try await stream.readExactly(1, timeout: 1) }
    }

    func testReadCancellationIgnoresLateReceive() async throws {
        let received = expectation(description: "receive registered")
        let wire = FakeCameraConnection(onReceive: { received.fulfill() })
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let reading = Task { try await stream.readExactly(8, timeout: 2) }
        await fulfillment(of: [received], timeout: 1)
        reading.cancel()
        do { _ = try await reading.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        wire.lateReceive()
        await expect(.notConnected) { try await stream.write(Data([1]), timeout: 1) }
    }

    func testConcurrentReaderCannotStealBytes() async throws {
        let received = expectation(description: "first reader registered")
        let stream = CameraTCPStream(connection: FakeCameraConnection(onReceive: { received.fulfill() }))
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let reading = Task { try await stream.readExactly(8, timeout: 2) }
        await fulfillment(of: [received], timeout: 1)
        await expect(.operationInProgress) { _ = try await stream.readExactly(1, timeout: 1) }
        // Full duplex is still allowed while a read is pending.
        try await stream.write(Data([1]), timeout: 1)
        stream.close()
        do { _ = try await reading.value; XCTFail("Expected close") }
        catch { XCTAssertEqual(error as? CameraStreamError, .closed) }
    }

    func testHandshakeBytesMatchSharedGoldenVectors() async throws {
        let wire = FakeCameraConnection()
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let channel = PtpIPChannel(stream: stream)
        try await channel.sendCommandHandshake(guid: Data(0...15), name: "NikonPTP", standard: false, timeout: 1)
        try await channel.sendCommandHandshake(guid: Data("0123456789abcdef".utf8), name: "ZTransfer", standard: true, timeout: 1)
        try await channel.sendEventHandshake(connectionNumber: 0x11223344, timeout: 1)
        XCTAssertEqual(wire.sent(), [
            hex("2C00000001000000000102030405060708090A0B0C0D0E0F4E0069006B006F006E0050005400500000000100"),
            hex("3000000001000000303132333435363738396162636465665A005400720061006E007300660065007200000000000100"),
            hex("0C0000000300000044332211"),
        ])
    }

    func testShortAckRejectedBeforeKotlinDecoder() async throws {
        let stream = CameraTCPStream(connection: FakeCameraConnection())
        defer { stream.close() }
        let channel = PtpIPChannel(stream: stream)
        do {
            _ = try await channel.commandAcknowledgement(PtpIPPacket(type: 2, payload: Data([1, 2, 3])))
            XCTFail("Expected malformed ACK")
        } catch {
            guard case PtpIPChannelError.malformedAcknowledgement = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testInvalidLengthAndControlLimitCloseStream() async throws {
        // < 8 and > caller limit: no payload should be consumed or allocated.
        for header in ["0700000002000000", "0010000002000000"] {
            let wire = FakeCameraConnection(bytes: hex(header))
            let stream = CameraTCPStream(connection: wire)
            defer { stream.close() }
            try await stream.connect(timeout: 1)
            let channel = PtpIPChannel(stream: stream)
            do {
                _ = try await channel.readControlPacket(timeout: 1, maximumPayloadBytes: 100)
                XCTFail("Expected framing rejection")
            } catch { XCTAssertTrue(error is PtpIPChannelError) }
            await expect(.notConnected) { try await stream.write(Data([1]), timeout: 1) }
        }
    }

    func testPayloadStreamingUsesBoundedChunks() async throws {
        // 131080 total bytes: 8-byte header plus 128 KiB payload, all from a fixed fixture.
        let wire = FakeCameraConnection(bytes: hex("080002000A000000") + Data(repeating: 0xAB, count: 131072))
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let channel = PtpIPChannel(stream: stream)
        var sizes: [Int] = []
        let type = try await channel.readPacketPayload(timeout: 2, maximumPayloadBytes: 131072) { chunk in
            sizes.append(chunk.count)
            XCTAssertTrue(chunk.allSatisfy { $0 == 0xAB })
        }
        XCTAssertEqual(type, 10)
        XCTAssertEqual(sizes, [65536, 65536])
    }

    func testAPCommandSequenceUsesAckSessionIdAndTransactionsOneThroughThree() async throws {
        let replies = hex("0E00000007000000012001000000")
            + hex("1400000009000000020000000300000000000000")
            + hex("0F0000000C00000002000000414243")
            + hex("0E00000007000000012002000000")
            + hex("0E00000007000000012003000000")
        let wire = FakeCameraConnection(bytes: replies, chunkSize: 2)
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        let opened = try await session.execute(operationCode: 0x1002, parameters: [0x11223344])
        let device = try await session.execute(operationCode: 0x1001)
        let closed = try await session.execute(operationCode: 0x1003)
        XCTAssertEqual(opened.code, 0x2001)
        XCTAssertEqual(device.payload, Data("ABC".utf8))
        XCTAssertEqual(closed.code, 0x2001)
        XCTAssertEqual(wire.sent(), [
            hex("16000000060000000100000002100100000044332211"),
            hex("120000000600000001000000011002000000"),
            hex("120000000600000001000000031003000000"),
        ])
    }

    func testStationTransactionZeroIsAvailableWithoutChangingAPDefault() async throws {
        let wire = FakeCameraConnection(bytes: hex("0E00000007000000012000000000"))
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: -1)
        _ = try await session.execute(operationCode: 0x1002, parameters: [1])
        XCTAssertEqual(wire.sent(), [hex("16000000060000000100000002100000000001000000")])
    }

    func testCommandPingGetsPongWithoutConsumingResponse() async throws {
        let wire = FakeCameraConnection(bytes: hex("080000000D0000000E00000007000000012001000000"))
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        let result = try await session.execute(operationCode: 0x1004)
        XCTAssertEqual(result.code, 0x2001)
        XCTAssertEqual(wire.sent().last, hex("080000000E000000"))
    }

    func testWrongTransactionPermanentlyClosesCommandOwner() async throws {
        let wire = FakeCameraConnection(bytes: hex("0E00000007000000012002000000"))
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        for _ in 0..<2 {
            do { _ = try await session.execute(operationCode: 0x1004); XCTFail("Expected transaction rejection") }
            catch {
                guard case PtpIPSessionError.wrongTransaction = error else { return XCTFail("Unexpected \(error)") }
            }
        }
        XCTAssertEqual(wire.sent().count, 1)
    }

    func testMetadataLimitAppliesAcrossPackets() async throws {
        let wire = FakeCameraConnection(bytes:
            hex("0F0000000A00000001000000414243") + hex("0F0000000C00000001000000444546"))
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        do {
            _ = try await session.execute(operationCode: 0x1001, maximumPayloadBytes: 4)
            XCTFail("Expected cumulative limit")
        } catch {
            guard case PtpIPSessionError.metadataLimit = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testConcurrentCommandsAreSerializedAcrossAllAwaits() async throws {
        let wire = FakeCameraConnection(bytes:
            hex("0E00000007000000012001000000") + hex("0E00000007000000012002000000"), chunkSize: 1)
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        async let first = session.execute(operationCode: 0x1004)
        async let second = session.execute(operationCode: 0x1004)
        let results = try await (first, second)
        XCTAssertEqual(results.0.code, 0x2001)
        XCTAssertEqual(results.1.code, 0x2001)
        XCTAssertEqual(wire.sent(), [
            hex("120000000600000001000000041001000000"),
            hex("120000000600000001000000041002000000"),
        ])
    }

    func testCancelledRequestDoesNotCloseAnotherActiveTransaction() async throws {
        let received = expectation(description: "active transaction waiting for response")
        received.assertForOverFulfill = false
        let wire = FakeCameraConnection(onReceive: { received.fulfill() })
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        let active = Task { try await session.execute(operationCode: 0x1004, timeout: 3) }
        await fulfillment(of: [received], timeout: 1)
        let cancelled = Task { try await session.execute(operationCode: 0x1001) }
        await Task.yield()
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        wire.feed(hex("0E00000007000000012001000000"))
        let result = try await active.value
        XCTAssertEqual(result.code, 0x2001)
        XCTAssertEqual(wire.sent().count, 1)
    }

    #if DEBUG
    func testAPDiagnosticReadsSharedDeviceInfoAndAllowsEventEOFOnClose() async throws {
        let eventWire = FakeCameraConnection()
        let closeRequest = hex("120000000600000001000000031003000000")
        let replies = hex("0E000000070000001E2001000000")
            + hex("6B0000000C000000020000006400EFCDAB8905A0033C5CB75E000001000300000001102894289401000000084002000000015067D000000000010000000138064E0069006B006F006E000000055A0020003300300000000431002E00300000000553004E003DD800DE0000")
            + hex("0E00000007000000012002000000")
            + hex("0E00000007000000012003000000")
        let commandWire = FakeCameraConnection(bytes: replies, onSend: { packet in
            if packet == closeRequest { eventWire.finish() }
        })
        let command = CameraTCPStream(connection: commandWire)
        let event = CameraTCPStream(connection: eventWire)
        defer { command.close(); event.close() }
        try await command.connect(timeout: 1)
        try await event.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: command, initialTransactionId: 0)
        let result = try await CameraHandshakeProbe.inspectAPSession(
            session, eventChannel: PtpIPChannel(stream: event), connectionNumber: 0x11223344
        )
        XCTAssertTrue(result.contains("Nikon Z 30"))
        XCTAssertTrue(result.contains("正常关闭"))
        XCTAssertEqual(commandWire.sent().count, 3)
        await session.close()
    }

    func testEventDisconnectDuringAPOpenDoesNotReportSuccess() async throws {
        let command = CameraTCPStream(connection: FakeCameraConnection())
        let event = CameraTCPStream(connection: FakeCameraConnection(eof: true))
        defer { command.close(); event.close() }
        try await command.connect(timeout: 1)
        try await event.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: command, initialTransactionId: 0)
        do {
            _ = try await CameraHandshakeProbe.inspectAPSession(
                session, eventChannel: PtpIPChannel(stream: event), connectionNumber: 1
            )
            XCTFail("Expected event-channel disconnect")
        } catch { XCTAssertEqual(error as? CameraStreamError, .endOfStream) }
        await session.close()
    }
    #endif

    func testIdleEventReadIsCancellableWithoutAnIdleDeadline() async throws {
        let registered = expectation(description: "idle event receive")
        let stream = CameraTCPStream(connection: FakeCameraConnection(onReceive: { registered.fulfill() }))
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let channel = PtpIPChannel(stream: stream)
        let reading = Task { try await channel.readControlPacket(timeout: 0.03, waitForPacket: true) }
        await fulfillment(of: [registered], timeout: 1)
        try await Task.sleep(nanoseconds: 80_000_000)
        // A regular packet timeout would already have closed this socket. Full-duplex write works.
        try await stream.write(Data([1]), timeout: 1)
        reading.cancel()
        do { _ = try await reading.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEventPartialHeaderStillHasPacketDeadline() async throws {
        let stream = CameraTCPStream(connection: FakeCameraConnection(bytes: Data([8])))
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let channel = PtpIPChannel(stream: stream)
        await expect(.timedOut) { _ = try await channel.readControlPacket(timeout: 0.03, waitForPacket: true) }
    }

    func testIdleOnlyCommandCannotQueueBehindActiveTransaction() async throws {
        let registered = expectation(description: "active command read")
        registered.assertForOverFulfill = false
        let wire = FakeCameraConnection(onReceive: { registered.fulfill() })
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        let active = Task { try await session.execute(operationCode: 0x1004, timeout: 2) }
        await fulfillment(of: [registered], timeout: 1)
        await expect(.operationInProgress) { _ = try await session.execute(operationCode: 0x1004, requireIdle: true) }
        wire.feed(response(transaction: 1))
        _ = try await active.value
        XCTAssertEqual(wire.sent().count, 1)
        let closed = await session.isClosed()
        XCTAssertFalse(closed)
    }

    func testPersistentAPReadsIdentifiersAndObjectInfoThenCloses() async throws {
        let object = hex("0100010001B10080FFFFFFFF01380403020140010000F00000004020000080150000"
            + "0E000000000000000000000000007856341209677147723DD800DE2E004E00450046000000"
            + "1032003000320036003000390030003400540031003500300036003000370000000000")
        let replies = apOpeningReplies()
            + response(transaction: 3, payload: hex("0100000001000100"))
            + response(transaction: 4, payload: hex("0200000007000000FFFFFFFF"))
            + response(transaction: 5, payload: object)
            + response(transaction: 6)
        let commandWire = FakeCameraConnection(bytes: replies, chunkSize: 3)
        let eventWire = FakeCameraConnection(bytes: hex("0800000004000000"))
        let camera = apCamera(command: commandWire, event: eventWire)
        let info = try await camera.connect(guid: Data(0...15))
        XCTAssertNil(info) // Unsupported DeviceInfo is tolerated, as on Android.
        let stores = try await camera.storageIDs()
        let handles = try await camera.objectHandles(storageID: 0x10001)
        let file = try await camera.objectInfo(handle: 7)
        XCTAssertEqual(stores, [0x10001])
        XCTAssertEqual(handles, [7, -1])
        XCTAssertEqual(file.fileName, "照片😀.NEF")
        XCTAssertEqual(file.size, 0xFFFFFFFF)
        XCTAssertTrue(file.identityComplete)
        await camera.disconnect()
        let state = await camera.snapshot()
        XCTAssertEqual(state.phase, .closed)
        XCTAssertNil(state.errorDescription)
        XCTAssertEqual(Array(commandWire.sent().dropFirst()), [
            hex("16000000060000000100000002100100000044332211"),
            hex("120000000600000001000000011002000000"),
            hex("120000000600000001000000041003000000"),
            hex("1E000000060000000100000007100400000001000100FFFFFFFF00000000"),
            hex("16000000060000000100000008100500000007000000"),
            hex("120000000600000001000000031006000000"),
        ])
    }

    func testMalformedCatalogIsNotEmptyAndDoesNotPoisonValidNextTransaction() async throws {
        let commandWire = FakeCameraConnection(bytes: apOpeningReplies()
            + response(transaction: 3, payload: hex("01000000"))
            + response(transaction: 4, payload: hex("00000000")))
        let camera = apCamera(command: commandWire)
        _ = try await camera.connect(guid: Data(0...15))
        do { _ = try await camera.storageIDs(); XCTFail("Expected malformed count") }
        catch {
            guard case CameraOperationError.malformedDataset(operation: 0x1004) = error else {
                await camera.abort(); return XCTFail("Unexpected \(error)")
            }
        }
        let stores = try await camera.storageIDs()
        XCTAssertEqual(stores, [])
        let state = await camera.snapshot()
        XCTAssertEqual(state.phase, .ready)
        await camera.abort()
    }

    func testKeepaliveAcceptsBusyResponseAsLiveConnection() async throws {
        let camera = apCamera(command: FakeCameraConnection(bytes: apOpeningReplies()
            + response(transaction: 3, code: 0x2019)))
        _ = try await camera.connect(guid: Data(0...15))
        let alive = await camera.keepalive()
        XCTAssertTrue(alive)
        let state = await camera.snapshot()
        XCTAssertEqual(state.phase, .ready)
        await camera.abort()
    }

    func testEventPingPublishesNoCatalogChangeButRealEventDoes() async throws {
        let eventWire = FakeCameraConnection(bytes: hex("0800000004000000"))
        let camera = apCamera(command: FakeCameraConnection(bytes: apOpeningReplies()), event: eventWire)
        _ = try await camera.connect(guid: Data(0...15))
        let changed = expectation(description: "catalog invalidation")
        let observer = Task {
            for await state in camera.updates where state.eventRevision > 0 {
                changed.fulfill(); break
            }
        }
        defer { observer.cancel() }
        eventWire.feed(hex("080000000D000000120000000800000002400000000007000000"))
        await fulfillment(of: [changed], timeout: 2)
        let state = await camera.snapshot()
        XCTAssertEqual(state.eventRevision, 1)
        XCTAssertEqual(eventWire.sent().last, hex("080000000E000000"))
        await camera.abort()
    }

    func testEventFailureClosesWholeOwnerAndCannotBeReopened() async throws {
        let eventWire = FakeCameraConnection(bytes: hex("0800000004000000"))
        let commandWire = FakeCameraConnection(bytes: apOpeningReplies())
        let camera = apCamera(command: commandWire, event: eventWire)
        _ = try await camera.connect(guid: Data(0...15))
        let closed = expectation(description: "event EOF closes owner")
        let observer = Task {
            for await state in camera.updates where state.phase == .closed {
                closed.fulfill(); break
            }
        }
        defer { observer.cancel() }
        eventWire.finish()
        await fulfillment(of: [closed], timeout: 2)
        await expect(.endOfStream) { _ = try await camera.storageIDs() }
        await expect(.endOfStream) { _ = try await camera.connect(guid: Data(0...15)) }
        XCTAssertEqual(commandWire.sent().count, 3)
        await camera.abort()
    }

    func testAPOpenRejectionClosesBothChannels() async throws {
        let commandWire = FakeCameraConnection(bytes: hex("0C0000000200000044332211")
            + response(transaction: 1, code: 0x2002))
        let camera = apCamera(command: commandWire)
        do { _ = try await camera.connect(guid: Data(0...15)); XCTFail("Expected rejection") }
        catch {
            guard case PtpIPSessionError.openRejected(0x2002) = error else {
                await camera.abort(); return XCTFail("Unexpected \(error)")
            }
        }
        let state = await camera.snapshot()
        XCTAssertEqual(state.phase, .closed)
        XCTAssertEqual(commandWire.sent().count, 2)
        await camera.abort()
    }

    func testPersistentOwnerQueuedCancellationLeavesActiveRequestUsable() async throws {
        let sent = expectation(description: "metadata command started")
        let storageRequest = hex("120000000600000001000000041003000000")
        let wire = FakeCameraConnection(bytes: apOpeningReplies(), onSend: { data in
            if data == storageRequest { sent.fulfill() }
        })
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(0...15))
        let active = Task { try await camera.storageIDs() }
        await fulfillment(of: [sent], timeout: 1)
        let cancelled = Task { try await camera.objectHandles(storageID: -1) }
        await Task.yield()
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        wire.feed(response(transaction: 3, payload: hex("0100000001000100")))
        let stores = try await active.value
        XCTAssertEqual(stores, [0x10001])
        let state = await camera.snapshot()
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(wire.sent().count, 4)
        await camera.abort()
    }

    func testBusyDisconnectAbortsInsteadOfQueuingCloseSession() async throws {
        let sent = expectation(description: "metadata command started")
        let storageRequest = hex("120000000600000001000000041003000000")
        let wire = FakeCameraConnection(bytes: apOpeningReplies(), onSend: { data in
            if data == storageRequest { sent.fulfill() }
        })
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(0...15))
        let active = Task { try await camera.storageIDs() }
        await fulfillment(of: [sent], timeout: 1)
        await camera.disconnect()
        do { _ = try await active.value; XCTFail("Expected abort") } catch {}
        let state = await camera.snapshot()
        XCTAssertEqual(state.phase, .closed)
        XCTAssertNil(state.errorDescription)
        // No CloseSession command may be inserted into an incomplete transaction.
        XCTAssertEqual(wire.sent().count, 4)
    }

    func testGracefulOwnerDisconnectAllowsEventEOFBeforeCloseResponse() async throws {
        let eventWire = FakeCameraConnection(bytes: hex("0800000004000000"))
        let closeRequest = hex("120000000600000001000000031003000000")
        let wire = FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 3), onSend: { data in
            if data == closeRequest { eventWire.finish() }
        })
        let camera = apCamera(command: wire, event: eventWire)
        _ = try await camera.connect(guid: Data(0...15))
        await camera.disconnect()
        let state = await camera.snapshot()
        XCTAssertEqual(state.phase, .closed)
        XCTAssertNil(state.errorDescription)
        XCTAssertEqual(wire.sent().last, closeRequest)
    }

    func testCancelledAPHandshakeNeverTransitionsToReady() async throws {
        let waiting = expectation(description: "command handshake waiting")
        waiting.assertForOverFulfill = false
        let wire = FakeCameraConnection(onReceive: { waiting.fulfill() })
        let camera = apCamera(command: wire)
        let opening = Task { try await camera.connect(guid: Data(0...15)) }
        await fulfillment(of: [waiting], timeout: 1)
        opening.cancel()
        do { _ = try await opening.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        wire.lateReady()
        wire.lateReceive()
        let state = await camera.snapshot()
        XCTAssertEqual(state.phase, .closed)
        XCTAssertEqual(wire.sent().count, 1)
        await camera.abort()
    }

    func testStreamingUsesBoundedChunksAndConsumesResponseBeforeNextCommand() async throws {
        let wire = FakeCameraConnection(bytes: response(transaction: 1, payload: Data(repeating: 0xAB, count: 131072))
            + response(transaction: 2))
        let stream = CameraTCPStream(connection: wire)
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        var count = 0
        let result = try await session.executeStreaming(operationCode: 0x1009, parameters: [7]) { data in
            XCTAssertLessThanOrEqual(data.count, 65536)
            XCTAssertTrue(data.allSatisfy { $0 == 0xAB })
            count += data.count
        }
        XCTAssertEqual(count, 131072)
        XCTAssertEqual(result.bytes, 131072)
        XCTAssertEqual(result.code, 0x2001)
        let next = try await session.execute(operationCode: 0x1004)
        XCTAssertEqual(next.code, 0x2001)
    }

    func testStreamingRejectsWrongDataTransactionBeforeWritingAnyMedia() async throws {
        let stream = CameraTCPStream(connection: FakeCameraConnection(bytes: response(transaction: 2, payload: Data([1, 2]))))
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        var writes = 0
        do {
            _ = try await session.executeStreaming(operationCode: 0x1009, parameters: [7]) { _ in writes += 1 }
            XCTFail("Expected transaction mismatch")
        } catch {
            guard case PtpIPSessionError.wrongTransaction = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(writes, 0)
        let closed = await session.isClosed()
        XCTAssertTrue(closed)
    }

    func testStreamingSinkFailureClosesCommandGate() async throws {
        let stream = CameraTCPStream(connection: FakeCameraConnection(bytes: response(transaction: 1, payload: Data([1, 2]))))
        defer { stream.close() }
        try await stream.connect(timeout: 1)
        let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0)
        do {
            _ = try await session.executeStreaming(operationCode: 0x1009, parameters: [7]) { _ in
                throw SandboxTransferError.invalidState
            }
            XCTFail("Expected disk failure")
        } catch { XCTAssertTrue(error is SandboxTransferError) }
        let closed = await session.isClosed()
        XCTAssertTrue(closed)
    }

    func testAPPartialDownloadWritesOriginalBytesAndUsesSharedParameters() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 3, payload: Data("ABC".utf8)))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(0...15))
        var output = Data()
        let result = try await camera.download(handle: 7, declaredSize: 3) { output.append($0) }
        XCTAssertEqual(output, Data("ABC".utf8))
        XCTAssertEqual(result.bytes, 3)
        XCTAssertEqual(wire.sent().last, hex("2600000006000000010000003194030000000700000000000000000000000300000000000000"))
        await camera.abort()
    }

    func testAPPartialUnsupportedFallsBackOnlyBeforeAnyBytes() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 3, code: 0x2005)
            + response(transaction: 4, payload: Data("ABC".utf8)))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(0...15))
        var output = Data()
        _ = try await camera.download(handle: 7, declaredSize: 3) { output.append($0) }
        XCTAssertEqual(output, Data("ABC".utf8))
        XCTAssertEqual(wire.sent().last, hex("16000000060000000100000009100400000007000000"))
        await camera.abort()
    }

    func testAPUnknownLargeSizeUses64BitQueryAndResumeOffset() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies()
            + response(transaction: 3, payload: hex("0000004001000000"))
            + response(transaction: 4, payload: Data("ABC".utf8)))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(0...15))
        let result = try await camera.download(handle: 7, declaredSize: 0xFFFFFFFF, resumeOffset: 0x13FFFFFFD) { _ in }
        XCTAssertEqual(result.bytes, 0x140000000)
        XCTAssertEqual(result.transferred, 3)
        XCTAssertEqual(wire.sent().last, hex("26000000060000000100000031940400000007000000FDFFFF3F010000000300000000000000"))
        await camera.abort()
    }

    func testAPPartialLengthMismatchDoesNotReportSuccess() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies()
            + hex("1400000009000000030000000400000000000000")
            + response(transaction: 3, payload: Data("ABC".utf8)))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(0...15))
        do { _ = try await camera.download(handle: 7, declaredSize: 3) { _ in }; XCTFail("Expected mismatch") }
        catch { XCTAssertTrue(error is CameraDownloadError) }
        await camera.abort()
    }

    func testSandboxCommitPreservesExistingFileAndHashesBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("photo.JPG")
        try Data("old".utf8).write(to: existing, options: .withoutOverwriting)
        let file = try SandboxTransferFile(directory: root, name: "photo.JPG", declaredSize: 3, captureDate: nil)
        try file.write(Data("ABC".utf8))
        let saved = try file.commit(expectedBytes: 3)
        XCTAssertEqual(saved.url.lastPathComponent, "photo (1).JPG")
        XCTAssertEqual(saved.sha256, "b5d4045c3f466fa91fe2cc6abe79232a1a57cdf104f7a26e716e0a1e2789df78a")
        XCTAssertEqual(try Data(contentsOf: existing), Data("old".utf8))
        file.discard()
        XCTAssertEqual(try Data(contentsOf: saved.url), Data("ABC".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testSandboxMismatchAndUnsafeNamesNeverPublishFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["../outside", "a/b", "a\\b", ".", "..", "", "bad\u{0}name"] {
            XCTAssertThrowsError(try SandboxTransferFile(directory: root, name: name, declaredSize: 3, captureDate: nil))
        }
        let file = try SandboxTransferFile(directory: root, name: "photo.JPG", declaredSize: 3, captureDate: nil)
        try file.write(Data([1]))
        XCTAssertThrowsError(try file.commit(expectedBytes: 3))
        file.discard()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testOriginalQueueSnapshotRetainsMetadataAndRejectsRemovingWaiting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let camera = apCamera(command: FakeCameraConnection(bytes: Data()))
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        var payload = Data(repeating: 0, count: 52)
        payload[0] = 1; payload[2] = 1; payload[4] = 1; payload[5] = 0x38; payload[8] = 3
        payload.append(hex("0B730061006D0070006C0065002E004A0050004700000000"))
        let info = try XCTUnwrap(PtpIPChannel.objectInfo(handle: 7, payload: payload))
        let enqueued = await queue.enqueue(info, byDate: false, dayKey: 0, deferred: true)
        let id = try XCTUnwrap(enqueued)
        let before = await queue.snapshot()
        let row = try XCTUnwrap(before.rows.first)
        XCTAssertEqual(before.connectionID, camera.connectionID)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.handle, 7)
        XCTAssertEqual(row.size, 3)
        XCTAssertEqual(row.name, "sample.JPG")
        XCTAssertEqual(row.storageIDs, [0x10001])
        XCTAssertNil(row.elapsedMs)
        XCTAssertEqual(row.downloadMBps, 0)
        let removedWaiting = await queue.removeTask(id)
        XCTAssertFalse(removedWaiting)
        await queue.withdrawPending()
        let withdrawn = await queue.snapshot()
        XCTAssertGreaterThan(withdrawn.historyRevision, before.historyRevision)
        XCTAssertEqual(withdrawn.rows.first?.status, "CANCELLED")
        let removed = await queue.removeTask(id)
        let removedAgain = await queue.removeTask(id)
        let final = await queue.snapshot()
        XCTAssertTrue(removed)
        XCTAssertFalse(removedAgain)
        XCTAssertTrue(final.rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)) // no network or file writes
    }

    func testOriginalQueueRetryExclusionsAndClearKeepWaitingWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let queue = CameraOriginalQueue(camera: apCamera(command: FakeCameraConnection(bytes: Data())),
                                        store: CameraOriginalStore(root: root))
        var payload = Data(repeating: 0, count: 52)
        payload[0] = 1; payload[2] = 1; payload[4] = 1; payload[5] = 0x38; payload[8] = 3
        payload.append(hex("0B730061006D0070006C0065002E004A0050004700000000"))
        let info = try XCTUnwrap(PtpIPChannel.objectInfo(handle: 7, payload: payload))
        let firstValue = await queue.enqueue(info, byDate: false, dayKey: 0, deferred: true)
        let secondValue = await queue.enqueue(info, byDate: false, dayKey: 0, deferred: true)
        let first = try XCTUnwrap(firstValue)
        let second = try XCTUnwrap(secondValue)
        await queue.withdraw(first)
        let retried = await queue.retryFailed(excluding: [first])
        XCTAssertEqual(retried, 0)
        await queue.clearTerminal()
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.rows.map(\.id), [second])
        XCTAssertEqual(snapshot.rows.first?.status, "WAITING")
        XCTAssertFalse(snapshot.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOriginalQueueSavesTwoManualExportsInFIFOOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let camera = apCamera(command: FakeCameraConnection(bytes: apOpeningReplies()
            + response(transaction: 3, payload: Data("ABC".utf8))
            + response(transaction: 4, payload: Data("DEF".utf8))))
        _ = try await camera.connect(guid: Data(0...15))
        var payload = Data(repeating: 0, count: 52)
        payload[0] = 1; payload[2] = 1; payload[4] = 1; payload[5] = 0x38; payload[8] = 3
        payload.append(hex("0B730061006D0070006C0065002E004A0050004700000000"))
        let info = try XCTUnwrap(PtpIPChannel.objectInfo(handle: 7, payload: payload))
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        let firstID = await queue.enqueue(info, byDate: false, dayKey: 0, deferred: true)
        let secondID = await queue.enqueue(info, byDate: false, dayKey: 0, deferred: true)
        let first = try XCTUnwrap(firstID)
        let second = try XCTUnwrap(secondID)
        let completed = expectation(description: "two originals completed")
        let observer = Task {
            for await snapshot in queue.updates {
                if snapshot.rows.count == 2 && snapshot.rows.allSatisfy({ $0.status == "COMPLETED" }) {
                    completed.fulfill(); break
                }
            }
        }
        defer { observer.cancel() }
        await queue.start()
        await fulfillment(of: [completed], timeout: 3)
        await queue.stop()
        let firstFile = await queue.savedFile(first)
        let secondFile = await queue.savedFile(second)
        let firstURL = try XCTUnwrap(firstFile?.url)
        let secondURL = try XCTUnwrap(secondFile?.url)
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("ABC".utf8))
        XCTAssertEqual(try Data(contentsOf: secondURL), Data("DEF".utf8))
        XCTAssertEqual(secondURL.lastPathComponent, "sample (1).JPG")
        let savedSnapshot = await queue.snapshot()
        XCTAssertEqual(savedSnapshot.completedOriginalRevision, 2)
        let originalIndex = try await queue.originals(since: -1, rescan: true)
        XCTAssertEqual(originalIndex.entries.count, 2)
        XCTAssertTrue(savedSnapshot.rows.allSatisfy { $0.elapsedMs != nil && $0.downloadMBps >= 0 })
        let removedHistory = await queue.removeTask(first)
        XCTAssertTrue(removedHistory)
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("ABC".utf8)) // removing a card never deletes its export
        await queue.clearTerminal()
        let retainedIndex = try await queue.originals(since: -1, rescan: false)
        XCTAssertEqual(retainedIndex.entries, originalIndex.entries)
        let emptyHistory = await queue.snapshot()
        XCTAssertTrue(emptyHistory.rows.isEmpty); XCTAssertEqual(emptyHistory.completedOriginalRevision, 2)
        await camera.abort()
    }

    func testStationBaselineUsesTransactionZeroAndNeverProbesDeviceInfoOnStorageSuccess() async throws {
        let wire = FakeCameraConnection(bytes: stationAck() + response(transaction: 0) + response(transaction: 1)
            + response(transaction: 2, payload: hex("0100000001000100")))
        let camera = stationCamera(command: wire)
        let device = try await camera.connect(guid: Data("0123456789abcdef".utf8))
        XCTAssertNil(device)
        let stores = try await camera.storageIDs()
        XCTAssertEqual(stores, [0x10001])
        XCTAssertEqual(Array(wire.sent().dropFirst()), [
            hex("16000000060000000100000002100000000001000000"),
            hex("1200000006000000010000001C9401000000"),
            hex("120000000600000001000000041002000000"),
        ])
        await camera.abort()
    }

    func testStationWrongResponderStopsBeforeOpeningEventSocket() async throws {
        let wire = FakeCameraConnection(bytes: stationAck())
        let events = FakeCameraConnection(bytes: hex("0800000004000000"))
        let camera = stationCamera(command: wire, event: events)
        do {
            _ = try await camera.connect(guid: Data("0123456789abcdef".utf8),
                                         stationOptions: StationConnectionOptions(expectedResponderGUID: String(repeating: "f", count: 32)))
            XCTFail("Expected wrong responder")
        } catch {
            guard case CameraStationError.unexpectedResponder = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(wire.sent().count, 1)
        XCTAssertTrue(events.sent().isEmpty)
        await camera.abort()
    }

    func testStationPairingPersistsAuthoritativeAckWithOrWithoutPacingEvent() async throws {
        for pacing in [hex("0E00000008000000084000000000"), Data()] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let profiles = try StationProfileStore(file: root.appendingPathComponent("identity.json"))
            let wire = FakeCameraConnection(bytes: stationAck() + response(transaction: 0) + response(transaction: 1)
                + response(transaction: 2, payload: hex("0100000001000100"))
                + response(transaction: 3) + response(transaction: 4) + response(transaction: 5))
            let events = FakeCameraConnection(bytes: hex("0800000004000000") + pacing, eof: true)
            let camera = stationCamera(command: wire, event: events)
            do {
                _ = try await camera.connect(guid: profiles.identity,
                    stationOptions: StationConnectionOptions(allowPairing: true, forceProfilePairing: true),
                    hasPairingMarker: { try profiles.isPaired($0) }, onPairingAcknowledged: { try profiles.markPaired($0) })
                XCTFail("Pairing must request a new connection, not return ready")
            } catch {
                guard case CameraStationError.pairingCompleted(let responder) = error else {
                    await camera.abort(); return XCTFail("Unexpected \(error)")
                }
                XCTAssertTrue(try profiles.isPaired(responder))
            }
            XCTAssertEqual(Array(wire.sent().suffix(3)), [
                hex("1200000006000000010000002B9503000000"),
                hex("1600000006000000010000005A930400000001200000"),
                hex("120000000600000001000000031005000000"),
            ])
            let state = await camera.snapshot()
            XCTAssertEqual(state.phase, .closed)
            await camera.abort()
        }
    }

    func testStationRejectedPairingDoesNotWriteMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = try StationProfileStore(file: root.appendingPathComponent("identity.json"))
        let wire = FakeCameraConnection(bytes: stationAck() + response(transaction: 0) + response(transaction: 1)
            + response(transaction: 2, payload: hex("0100000001000100"))
            + response(transaction: 3) + response(transaction: 4, code: 0x2002))
        let camera = stationCamera(command: wire)
        do {
            _ = try await camera.connect(guid: profiles.identity,
                stationOptions: StationConnectionOptions(allowPairing: true, forceProfilePairing: true),
                onPairingAcknowledged: { try profiles.markPaired($0) })
            XCTFail("Expected pairing rejection")
        } catch { XCTAssertTrue(error is CameraOperationError) }
        XCTAssertFalse(try profiles.isPaired("00112233445566778899aabbccddeeff"))
        await camera.abort()
    }

    func testStationIdentitySurvivesReloadAndCorruptionIsNotSilentlyReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("identity.json")
        let first = try StationProfileStore(file: file)
        let second = try StationProfileStore(file: file)
        XCTAssertEqual(first.identity, second.identity)
        XCTAssertEqual(first.identity.count, 16)
        try first.markPaired("00112233445566778899aabbccddeeff")
        XCTAssertTrue(try second.isPaired("00112233445566778899aabbccddeeff"))
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try StationProfileStore(file: file))
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }

    func testAppleBlowfishMatchesCapturedAndroidNikonStageThree() throws {
        let stage1 = hex("01DBE113EC44A17D6701E53A3C51A4DA3F")
        let stage2 = hex("0229FA26805E3D94B9E4F2B3A8136AD516")
        let response = try NikonGpsPairing.capturedResponse(stage1: stage1, stage2: stage2)
        XCTAssertEqual(response, hex("03DBE113EC44A17D6753ADF179358A8323"))
    }

    func testLocationUsesCurrentUTCAndSharedFixedGeoBytes() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-01-02T03:04:05Z"))
        let location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 39.9042, longitude: -116.4074),
            altitude: -12.5, horizontalAccuracy: 5, verticalAccuracy: 2, timestamp: now.addingTimeInterval(-30))
        let payload = CameraLocationProvider.payload(for: location, now: now)
        XCTAssertEqual(payload, hex("7F004E273619145774182C27004D0C00E907010203040500015747532D383400000000000000000000"))
        // The GEO UTC is 03:04:05, not the cached fix's 03:03:35. No fabricated satellites.
        XCTAssertEqual(payload?.count, 41)
    }

    func testLocationRejectsExpiredFixAndFallsBackWhenAltitudeInvalid() throws {
        let now = Date(timeIntervalSince1970: 1_735_786_800)
        func fix(age: Double, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), altitude: 500,
                horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertNotNil(CameraLocationProvider.payload(for: fix(age: 120), now: now))
        XCTAssertNil(CameraLocationProvider.payload(for: fix(age: 120.01), now: now))
        XCTAssertNil(CameraLocationProvider.payload(for: fix(age: 0, accuracy: -1), now: now))
        let payload = try XCTUnwrap(CameraLocationProvider.payload(for: fix(age: 1), now: now))
        XCTAssertEqual(payload[13], 0x50); XCTAssertEqual(payload[14], 0); XCTAssertEqual(payload[15], 0)
    }

    func testDownloadProgressReportsActualFinalBytesWithoutDependingOnSlowClock() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 3, payload: Data([1, 2, 3])))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        var samples: [CameraDownloadProgress] = []
        let result = try await camera.download(handle: 7, declaredSize: 3, onProgress: { samples.append($0) }) { _ in }
        XCTAssertEqual(result.bytes, 3)
        XCTAssertEqual(samples.last?.downloaded, 3)
        XCTAssertEqual(samples.last?.total, 3)
        await camera.abort()
    }

    func testDirectoryGrantBalancesScopeAndRefreshesStaleBookmark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("grant")
        let access = FakeDirectoryAccess(url: root)
        let store = ScopedDirectoryStore(bookmarkFile: file, access: access)
        try await store.select(root)
        access.stale = true
        let name = try await store.displayName()
        XCTAssertEqual(name, root.lastPathComponent)
        XCTAssertEqual(access.starts, 2); XCTAssertEqual(access.stops, 2)
        XCTAssertEqual(try Data(contentsOf: file), Data([2]))
    }

    func testDirectoryRevocationDoesNotResetBookmarkOrTouchDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("grant")
        let access = FakeDirectoryAccess(url: root)
        let store = ScopedDirectoryStore(bookmarkFile: file, access: access)
        try await store.select(root)
        access.allowed = false
        do { _ = try await store.displayName(); XCTFail("Expected revoked access") }
        catch { guard case ExportDirectoryError.permissionLost = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(access.stops, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
        try await store.forget()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testDirectoryOperationFailureStillReleasesGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let access = FakeDirectoryAccess(url: root)
        let store = ScopedDirectoryStore(bookmarkFile: root.appendingPathComponent("grant"), access: access)
        try await store.select(root)
        do {
            let _: String = try await store.withDirectory { _ in throw CameraStreamError.closed }
            XCTFail("Expected operation failure")
        } catch { XCTAssertEqual(error as? CameraStreamError, .closed) }
        XCTAssertEqual(access.starts, access.stops)
    }

    func testCatalogUsesSharedReverseOrderAndRetainsLastSnapshotOnFailure() async throws {
        let source = FakeCatalogSource(infos: [1: try sampleInfo(1), 2: try sampleInfo(2)])
        let catalog = CameraCatalog(source: source, stationMode: false)
        let first = try await catalog.refresh()
        XCTAssertEqual(first.files.map(\.handle), [2, 1])
        XCTAssertTrue(first.metadataComplete)
        await source.failEnumeration()
        do { _ = try await catalog.refresh(); XCTFail("Enumeration failure must not publish empty") }
        catch { XCTAssertTrue(error is CameraOperationError) }
        let preserved = await catalog.snapshot()
        XCTAssertEqual(preserved?.files.map(\.handle), [2, 1])
    }

    func testCatalogPartialMetadataDoesNotEraseCompleteSnapshot() async throws {
        let source = FakeCatalogSource(infos: [1: try sampleInfo(1), 2: try sampleInfo(2)])
        let catalog = CameraCatalog(source: source, stationMode: false)
        _ = try await catalog.refresh()
        await source.removeMetadata(2)
        let partial = try await catalog.refresh()
        XCTAssertFalse(partial.metadataComplete)
        XCTAssertEqual(partial.files.map(\.handle), [1])
        let preserved = await catalog.snapshot()
        XCTAssertEqual(preserved?.files.count, 2)
    }

    func testCatalogMarksEventsDuringScanAsInvalidation() async throws {
        let source = FakeCatalogSource(infos: [1: try sampleInfo(1), 2: try sampleInfo(2)], changeDuringRead: true)
        let result = try await CameraCatalog(source: source, stationMode: false).refresh()
        XCTAssertTrue(result.changedWhileScanning)
        XCTAssertTrue(result.metadataComplete)
    }

    func testPreviewCacheRetriesTransientErrorAndDoesNotCacheFhdFallbackAsFhd() async throws {
        let source = FakePreviewSource(thumbs: [.failure, .bytes(Data([1]))])
        let store = CameraPreviewStore(source: source)
        let info = try sampleInfo(1)
        do { _ = try await store.thumbnail(info: info); XCTFail("Expected transient failure") }
        catch { XCTAssertTrue(error is CameraOperationError) }
        let first = try await store.preview(info: info)
        let second = try await store.preview(info: info)
        let counts = await source.counts()
        XCTAssertEqual(first, Data([1])); XCTAssertEqual(second, first)
        XCTAssertEqual(counts.thumb, 2); XCTAssertEqual(counts.fhd, 2)
    }

    func testProductFhdMissDoesNotStealTheThumbnailBeforeExif() async throws {
        let source = FakePreviewSource(thumbs: [.bytes(Data([9]))])
        let store = CameraPreviewStore(source: source)
        let info = try sampleInfo(1)
        let first = try await store.fhd(info: info)
        let second = try await store.fhd(info: info)
        XCTAssertNil(first); XCTAssertNil(second)
        let before = await source.counts()
        XCTAssertEqual(before.fhd, 2); XCTAssertEqual(before.thumb, 0)
        let fallback = try await store.thumbnail(info: info)
        XCTAssertEqual(fallback, Data([9]))
        let after = await source.counts()
        XCTAssertEqual(after.thumb, 1)
    }

    func testProductFhdSuccessReusesExistingCacheWithoutCallingThumbnail() async throws {
        let payload = try thumbnailFixture()
        let source = FakePreviewSource(thumbs: [], fhds: [.bytes(payload)])
        let store = CameraPreviewStore(source: source)
        let info = try sampleInfo(1)
        let first = try await store.fhd(info: info)
        let second = try await store.fhd(info: info)
        XCTAssertEqual(first, payload); XCTAssertEqual(second, payload)
        let counts = await source.counts()
        XCTAssertEqual(counts.fhd, 1); XCTAssertEqual(counts.thumb, 0)
    }

    func testCacheOnlyPreviewThumbnailNeverTriggersAnIoMiss() async throws {
        let payload = try thumbnailFixture()
        let source = FakePreviewSource(thumbs: [.bytes(payload)])
        let store = CameraPreviewStore(source: source)
        let info = try sampleInfo(1)
        let absent = await store.cachedThumbnail(info: info)
        XCTAssertNil(absent)
        let before = await source.counts(); XCTAssertEqual(before.thumb, 0)
        _ = try await store.thumbnail(info: info)
        let cached = await store.cachedThumbnail(info: info)
        XCTAssertEqual(cached, payload)
        await store.clearForMemoryPressure()
        let cleared = await store.cachedThumbnail(info: info)
        XCTAssertNil(cleared)
        let after = await source.counts(); XCTAssertEqual(after.thumb, 1)
    }

    func testProductFhdKeepsCameraPixelOrientationWhileDiagnosticStillRotates() async throws {
        let jpeg = try orientedPreviewFixture(width: 40, height: 20, orientation: 6)
        let decoder = PreviewImageDecoder()
        let png = try await decoder.fhdPreviewPNG(jpeg)
        let product = try await decoder.decode(png)
        let diagnostic = try await decoder.decode(jpeg)
        XCTAssertEqual(product.width, 40); XCTAssertEqual(product.height, 20)
        XCTAssertEqual(diagnostic.width, 20); XCTAssertEqual(diagnostic.height, 40)
    }

    func testProductFhdMatches1920LongEdgeAndRejectsMalformedInput() async throws {
        let decoder = PreviewImageDecoder()
        let jpeg = try orientedPreviewFixture(width: 2000, height: 1000, orientation: 6)
        let png = try await decoder.fhdPreviewPNG(jpeg)
        let image = try await decoder.decode(png)
        XCTAssertEqual(image.width, 1920); XCTAssertEqual(image.height, 960)
        XCTAssertLessThanOrEqual(png.count, 20 * 1024 * 1024)
        do { _ = try await decoder.fhdPreviewPNG(Data([1, 2, 3])); XCTFail("Malformed input must fail") }
        catch { XCTAssertTrue(error is PreviewImageError) }
    }

    @MainActor func testNativeFhdBulkBoundaryChecksDimensionsBeforeComposeDecode() async throws {
        let png = try await PreviewImageDecoder().fhdPreviewPNG(thumbnailFixture())
        let payload = try XCTUnwrap(NativePreviewImageBridge.shared.fhdPng(data: png as NSData))
        XCTAssertEqual(payload.width, 12); XCTAssertEqual(payload.height, 8)
        var bad = png
        bad[16] = 0xff // Unsigned IHDR overflow must not become a small signed width.
        XCTAssertNil(NativePreviewImageBridge.shared.fhdPng(data: bad as NSData))
        XCTAssertNil(NativePreviewImageBridge.shared.fhdPng(data: Data() as NSData))
    }

    func testPreviewExifUsesSharedOriginalRulesAndSeparateRootExposureCompensation() throws {
        let values = NativePreviewExifValues()
        values.set(tag: .fNumber, value: "28/10")
        values.set(tag: .exposureTime, value: "3/2")
        values.set(tag: .exposureBiasValue, value: "2/3")
        values.set(tag: .photographicSensitivity, value: "64")
        values.set(tag: .focalLength, value: "85")
        let result = try XCTUnwrap(NativePreviewExifBridge.shared.metadata(values: values,
            formatter: ApplePreviewExifFormatter(locale: Locale(identifier: "fr_FR"))))
        XCTAssertEqual(result.aperture, "f/2,8"); XCTAssertEqual(result.shutterSpeed, "1,5s")
        XCTAssertEqual(result.exposureCompensation, "+0.7 EV"); XCTAssertEqual(result.iso, "ISO64")
        XCTAssertEqual(result.focalLength, "85mm")
    }

    func testPreviewExifNativeValuesKeepApexDateAndCoordinateFallbacks() throws {
        let values = NativePreviewExifValues()
        values.set(tag: .apertureValue, value: "4")
        values.set(tag: .exposureTime, value: "1/250")
        values.set(tag: .datetimeOriginal, value: " ")
        values.set(tag: .datetimeDigitized, value: " 2026:09:05 01:02:03 ")
        values.set(tag: .lensModel, value: "  NIKKOR  ")
        values.set(tag: .gpsLatitude, value: "[31/1,12/1,30/1]")
        values.set(tag: .gpsLatitudeRef, value: "S")
        values.set(tag: .gpsLongitude, value: "121.5")
        values.set(tag: .gpsLongitudeRef, value: "W")
        values.altitudeMeters = -15.5
        let result = try XCTUnwrap(NativePreviewExifBridge.shared.metadata(values: values,
            formatter: ApplePreviewExifFormatter(locale: Locale(identifier: "en_US_POSIX"))))
        XCTAssertEqual(result.aperture, "f/4"); XCTAssertEqual(result.shutterSpeed, "1/250")
        XCTAssertEqual(result.dateTime, " 2026:09:05 01:02:03 "); XCTAssertEqual(result.lensModel, "NIKKOR")
        XCTAssertEqual(try XCTUnwrap(result.latitude).doubleValue, -(31 + 12.0 / 60 + 30.0 / 3600), accuracy: 0.00000001)
        XCTAssertEqual(try XCTUnwrap(result.longitude).doubleValue, -121.5)
        XCTAssertEqual(try XCTUnwrap(result.altitudeMeters).doubleValue, -15.5)
    }

    func testPreviewExifAppleFormatterGoldensKeepHalfUpNonfiniteAndNegativeZero() {
        let formatter = ApplePreviewExifFormatter(locale: Locale(identifier: "en_US_POSIX"))
        let cases: [(Float, Int32, String)] = [(2.5, 0, "3"), (-2.5, 0, "-3"),
            (2.65, 1, "2.7"), (0, 1, "0.0"), (-0.0, 0, "-0"),
            (.nan, 0, "NaN"), (.infinity, 1, "Infinity"), (-.infinity, 0, "-Infinity")]
        for (value, digits, expected) in cases {
            XCTAssertEqual(formatter.fixed(value: value, fractionDigits: digits, rootLocale: false), expected)
        }
    }

    func testImageIoPreviewMetadataUsesSharedFieldsAndKeepsDecodedCoordinatePrecision() throws {
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifFNumber as String: 2.8,
                kCGImagePropertyExifExposureTime as String: 0.004, kCGImagePropertyExifExposureBiasValue as String: 2.0 / 3,
                kCGImagePropertyExifISOSpeedRatings as String: [64, 100], kCGImagePropertyExifLensModel as String: " NIKKOR ",
                kCGImagePropertyExifDateTimeOriginal as String: "2026:09:05 01:02:03"],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 31.123456789,
                kCGImagePropertyGPSLatitudeRef as String: "S", kCGImagePropertyGPSLongitude as String: 121.987654321,
                kCGImagePropertyGPSLongitudeRef as String: "E", kCGImagePropertyGPSAltitude as String: 123.5,
                kCGImagePropertyGPSAltitudeRef as String: 1],
        ]
        let result = try XCTUnwrap(PreviewExifReader.metadata(properties, locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertEqual(result.aperture, "f/2.8"); XCTAssertEqual(result.shutterSpeed, "1/250")
        XCTAssertEqual(result.exposureCompensation, "+0.7 EV"); XCTAssertEqual(result.iso, "ISO64,100")
        XCTAssertEqual(result.lensModel, "NIKKOR"); XCTAssertEqual(result.dateTime, "2026:09:05 01:02:03")
        XCTAssertEqual(result.latitude?.doubleValue, -31.123456789)
        XCTAssertEqual(result.longitude?.doubleValue, 121.987654321); XCTAssertEqual(result.altitudeMeters?.doubleValue, -123.5)
    }

    func testImageIoPreviewMetadataRejectsBooleanNumbersAndMissingAltitudeReference() throws {
        let properties: [String: Any] = [kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifFNumber as String: true, kCGImagePropertyExifISOSpeedRatings as String: [true]],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSAltitude as String: 123.5]]
        let result = try XCTUnwrap(PreviewExifReader.metadata(properties))
        XCTAssertNil(result.aperture); XCTAssertNil(result.iso); XCTAssertNil(result.altitudeMeters)
        let fractional = PreviewExifReader.metadata([kCGImagePropertyGPSDictionary as String: [
            kCGImagePropertyGPSAltitude as String: 123.5, kCGImagePropertyGPSAltitudeRef as String: 0.5]])
        XCTAssertNil(fractional?.altitudeMeters)
    }

    /// Inject bytes rather than asking ImageIO to re-encode (and possibly reduce) a fraction.
    private func rawBiasJpegFixture(numerator: Int32, denominator: Int32, little: Bool) throws -> Data {
        var tiff = [UInt8](repeating: 0, count: 52)
        func put(_ offset: Int, _ value: UInt32, _ width: Int) {
            for i in 0..<width { tiff[offset + i] = UInt8(truncatingIfNeeded: value >> ((little ? i : width - i - 1) * 8)) }
        }
        tiff[0] = little ? 73 : 77; tiff[1] = tiff[0]
        put(2, 42, 2); put(4, 8, 4); put(8, 1, 2)
        put(10, 0x8769, 2); put(12, 4, 2); put(14, 1, 4); put(18, 26, 4)
        put(26, 1, 2); put(28, 0x9204, 2); put(30, 10, 2); put(32, 1, 4); put(36, 44, 4)
        put(44, UInt32(bitPattern: numerator), 4); put(48, UInt32(bitPattern: denominator), 4)
        let original = [UInt8](try orientedPreviewFixture(width: 12, height: 8, orientation: 1))
        var output = Data([0xFF, 0xD8, 0xFF, 0xE1, 0, 60, 69, 120, 105, 102, 0, 0])
        output.append(contentsOf: tiff)
        var position = 2
        while position + 4 <= original.count {
            XCTAssertEqual(original[position], 0xFF)
            let marker = original[position + 1]
            if marker == 0xDA || marker == 0xD9 { output.append(contentsOf: original[position...]); return output }
            let length = Int(original[position + 2]) * 256 + Int(original[position + 3])
            guard length >= 2, position + length + 2 <= original.count else { throw PreviewImageError.invalidImage }
            let isExif = marker == 0xE1 && length >= 8 && Array(original[(position + 4)..<(position + 10)]) == [69, 120, 105, 102, 0, 0]
            if !isExif { output.append(contentsOf: original[position..<(position + length + 2)]) }
            position += length + 2
        }
        throw PreviewImageError.invalidImage
    }

    func testRealJpegRawBiasPreservesAndroidFloatBoundaryForBothEndianOrders() throws {
        for little in [true, false] {
            let jpeg = try rawBiasJpegFixture(numerator: 36_293_949, denominator: 725_879_001, little: little)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try jpeg.write(to: url)
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertNil(PreviewExifReader.metadata(properties)?.exposureCompensation)
            let result = try PreviewExifReader.metadata(fileDescriptor: input.fileDescriptor, size: Int64(jpeg.count),
                cancellation: PreviewExifReadCancellation(), locale: Locale(identifier: "en_US_POSIX"))
            XCTAssertEqual(result?.exposureCompensation, "+0.1 EV")
            XCTAssertEqual(try input.offset(), 0)
        }
    }

    func testRealJpegRawSignedAndZeroDenominatorUseOriginalNormalization() throws {
        for (numerator, denominator, expected) in [(Int32(-2), Int32(3), "-0.7 EV" as String?), (Int32(99), Int32(0), nil)] {
            let jpeg = try rawBiasJpegFixture(numerator: numerator, denominator: denominator, little: true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try jpeg.write(to: url)
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            let result = try XCTUnwrap(PreviewExifReader.metadata(fileDescriptor: input.fileDescriptor, size: Int64(jpeg.count),
                cancellation: PreviewExifReadCancellation(), locale: Locale(identifier: "en_US_POSIX")))
            XCTAssertEqual(result.exposureCompensation, expected)
        }
    }

    func testRealJpegMultipleExifSegmentsRetainVisitedOrOverrideNewDirectory() throws {
        let original = try rawBiasJpegFixture(numerator: 36_293_949, denominator: 725_879_001, little: true)
        let other = try rawBiasJpegFixture(numerator: -2, denominator: 3, little: true)
        for distance in [0, 64] {
            var tiff = [UInt8](repeating: 0, count: 52 + distance)
            tiff.replaceSubrange(0..<26, with: other[12..<38])
            tiff.replaceSubrange((26 + distance)..<(52 + distance), with: other[38..<64])
            func put(_ at: Int, _ value: UInt32) {
                for i in 0..<4 { tiff[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
            }
            put(18, UInt32(26 + distance)); put(36 + distance, UInt32(44 + distance))
            var jpeg = Data(original.prefix(64))
            jpeg.append(contentsOf: [0xFF, 0xE1, 0, UInt8(tiff.count + 8), 69, 120, 105, 102, 0, 0])
            jpeg.append(contentsOf: tiff); jpeg.append(original.dropFirst(64))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try jpeg.write(to: url)
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            let result = try PreviewExifReader.metadata(fileDescriptor: input.fileDescriptor, size: Int64(jpeg.count),
                cancellation: PreviewExifReadCancellation(), locale: Locale(identifier: "en_US_POSIX"))
            XCTAssertEqual(result?.exposureCompensation, distance == 0 ? "+0.1 EV" : "-0.7 EV")
            XCTAssertEqual(try input.offset(), 0)
        }
    }

    func testCameraExifJpegHeaderDoesNotRequireImageEntropyOrFinalEoi() throws {
        let jpeg = try rawBiasJpegFixture(numerator: 36_293_949, denominator: 725_879_001, little: true)
        let prefix = Data(jpeg.prefix(64)) // Complete APP1, no image scan data.
        let result = try PreviewExifReader.metadata(header: prefix, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(result?.exposureCompensation, "+0.1 EV")
        XCTAssertNil(try PreviewExifReader.metadata(header: Data(repeating: 0, count: 32)))
        XCTAssertNil(try PreviewExifReader.metadata(header: Data(repeating: 0, count: 2 * 1024 * 1024 + 1)))
    }

    func testCameraExifTiffPrefixKeepsApertureWhenLaterBiasDataIsMissing() throws {
        var bytes = [UInt8](repeating: 0, count: 64)
        func put(_ offset: Int, _ value: UInt32, _ width: Int) {
            for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        put(0, 0x4949, 2); put(2, 42, 2); put(4, 8, 4); put(8, 1, 2)
        put(10, 0x8769, 2); put(12, 4, 2); put(14, 1, 4); put(18, 26, 4)
        put(26, 2, 2); put(28, 0x829D, 2); put(30, 5, 2); put(32, 1, 4); put(36, 56, 4)
        put(40, 0x9204, 2); put(42, 10, 2); put(44, 1, 4); put(48, 72, 4)
        put(56, 28, 4); put(60, 10, 4)
        let result = try PreviewExifReader.metadata(header: Data(bytes), locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(result?.aperture, "f/2.8"); XCTAssertNil(result?.exposureCompensation)
    }

    private func previewExifJpegFixture() throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(orientedPreviewFixture(width: 12, height: 8, orientation: 1) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        let exif: [CFString: Any] = [
            kCGImagePropertyExifFNumber: 4, kCGImagePropertyExifExposureTime: 0.004,
            kCGImagePropertyExifISOSpeedRatings: [64], kCGImagePropertyExifDateTimeOriginal: "2026:09:05 01:02:03"]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return output as Data
    }

    func testLocalExifReadsRealPublishedJpegWithoutMutatingFileOrIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("ORIGINAL.JPG"), jpeg = try previewExifJpegFixture()
        try jpeg.write(to: url)
        let store = CameraOriginalStore(root: root)
        let index = try await store.originals(since: -1, rescan: true)
        let result = try await store.originalExif(locator: url.absoluteString)
        XCTAssertEqual(result?.iso, "ISO64"); XCTAssertEqual(result?.dateTime, "2026:09:05 01:02:03")
        let unchanged = try await store.originals(since: index.revision, rescan: false)
        XCTAssertEqual(unchanged.revision, index.revision); XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), jpeg)
    }

    func testExifProviderActuallyExtractsMetadataAndDoesNotMoveBorrowedDescriptor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let jpeg = try previewExifJpegFixture(); try jpeg.write(to: url)
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        try input.seek(toOffset: 17)
        let result = try PreviewExifReader.metadata(fileDescriptor: input.fileDescriptor, size: Int64(jpeg.count),
            cancellation: PreviewExifReadCancellation(), locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(result?.aperture, "f/4"); XCTAssertEqual(result?.shutterSpeed, "1/250")
        XCTAssertEqual(try input.offset(), 17)
    }

    func testExifDescriptorReaderOwnsDuplicateAndReadsBeyondTwoGiB() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let output = try FileHandle(forWritingTo: url)
        let offset: Int64 = 2_147_483_648 + 4096
        try output.seek(toOffset: UInt64(offset)); try output.write(contentsOf: Data([7, 8, 9, 10])); try output.close()
        let input = try FileHandle(forReadingFrom: url)
        let reader = try PreviewExifFileReader(fileDescriptor: input.fileDescriptor, size: offset + 4, cancellation: PreviewExifReadCancellation())
        try input.close() // Provider's owned duplicate remains valid.
        var bytes = [UInt8](repeating: 0, count: 4)
        let count = bytes.withUnsafeMutableBytes { reader.read(into: $0.baseAddress!, position: offset, count: $0.count) }
        XCTAssertEqual(count, 4); XCTAssertEqual(bytes, [7, 8, 9, 10]); XCTAssertFalse(reader.failed)
    }

    func testExifDescriptorReaderCancellationAndTruncationNeverReadInvalidMemory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3, 4]).write(to: url)
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let cancellation = PreviewExifReadCancellation()
        let reader = try PreviewExifFileReader(fileDescriptor: input.fileDescriptor, size: 4, cancellation: cancellation)
        cancellation.cancel()
        var bytes = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(bytes.withUnsafeMutableBytes { reader.read(into: $0.baseAddress!, position: 0, count: $0.count) }, 0)
        let active = try PreviewExifFileReader(fileDescriptor: input.fileDescriptor, size: 4, cancellation: PreviewExifReadCancellation())
        let output = try FileHandle(forWritingTo: url); try output.truncate(atOffset: 0); try output.close()
        XCTAssertEqual(bytes.withUnsafeMutableBytes { active.read(into: $0.baseAddress!, position: 0, count: $0.count) }, 0)
        XCTAssertTrue(active.failed)
    }

    func testLocalExifRejectsUnpublishedOrChangedOriginalAndPropagatesCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("ORIGINAL.JPG"); try previewExifJpegFixture().write(to: url)
        let store = CameraOriginalStore(root: root)
        do { _ = try await store.originalExif(locator: url.absoluteString); XCTFail("Unpublished") } catch {}
        _ = try await store.originals(since: -1, rescan: true); try Data([1]).write(to: url)
        do { _ = try await store.originalExif(locator: url.absoluteString); XCTFail("Changed size") } catch {}
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.originalExif(locator: "file:///not-owned.JPG")
        }
        do { _ = try await task.value; XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func rawIndexFixture(_ ranges: [(UInt32, UInt32)]) -> Data {
        var data = Data(repeating: 0, count: max(128, 8 + ranges.count * 40))
        func u16(_ at: Int, _ value: UInt16) { data[at] = UInt8(truncatingIfNeeded: value); data[at + 1] = UInt8(truncatingIfNeeded: value >> 8) }
        func u32(_ at: Int, _ value: UInt32) { for i in 0..<4 { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) } }
        data[0] = 73; data[1] = 73; u16(2, 42); u32(4, 8)
        for (i, range) in ranges.enumerated() {
            let at = 8 + i * 40; u16(at, 2)
            u16(at + 2, 0x0201); u16(at + 4, 4); u32(at + 6, 1); u32(at + 10, range.0)
            u16(at + 14, 0x0202); u16(at + 16, 4); u32(at + 18, 1); u32(at + 22, range.1)
            if i + 1 < ranges.count { u32(at + 26, UInt32(at + 40)) }
        }
        return data
    }

    private func writeRawFixture(root: URL, bodies: [(UInt32, Data)], ranges: [(UInt32, UInt32)]? = nil,
                                 size: UInt64? = nil, header: Data? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("ORIGINAL.NEF")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
        let index = header ?? rawIndexFixture(ranges ?? bodies.map { ($0.0, UInt32($0.1.count)) })
        try output.write(contentsOf: index)
        for (offset, bytes) in bodies { try output.seek(toOffset: UInt64(offset)); try output.write(contentsOf: bytes) }
        if let size { try output.truncate(atOffset: size) } // Sparse fixture, not a multi-GB allocation.
        return url
    }

    private func padJpegFixture(_ jpeg: Data, minimumBytes: Int = 60_000) -> Data {
        // Legal COM segment makes a lower-resolution JPEG larger in encoded bytes.
        var result = Data(jpeg.prefix(2))
        repeat {
            result.append(contentsOf: [0xff, 0xfe, 0xea, 0x62])
            result.append(Data(repeating: 65, count: 60_000))
        } while result.count + jpeg.count - 2 <= minimumBytes
        result.append(jpeg.dropFirst(2))
        return result
    }

    func testRawPreviewSelectsDecodedPixelsNotEncodedSizeAndKeepsFullOrientation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let large = try orientedPreviewFixture(width: 3000, height: 1500, orientation: 6)
        let small = padJpegFixture(try orientedPreviewFixture(width: 20, height: 10, orientation: 1), minimumBytes: large.count)
        XCTAssertGreaterThan(small.count, large.count)
        let url = try writeRawFixture(root: root, bodies: [(4096, small), (UInt32(8192 + small.count), large)])
        let store = CameraOriginalStore(root: root); let index = try await store.originals(since: -1, rescan: true)
        let actual = try await store.originalRawPreviewData(locator: url.absoluteString)
        XCTAssertEqual(actual, large)
        let png = try await PreviewImageDecoder().originalBitmapPNG(XCTUnwrap(actual))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 3000); XCTAssertEqual(image.height, 1500)
        let unchanged = try await store.originals(since: index.revision, rescan: false)
        XCTAssertEqual(unchanged.revision, index.revision); XCTAssertTrue(unchanged.entries.isEmpty)
    }

    func testRawPreviewReadsIndexedJpegBeyondPrefixAndTwoGiBWithoutReadingWholeRaw() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = try orientedPreviewFixture(width: 40, height: 30, orientation: 1)
        let offset: UInt32 = 2_147_483_648 + 4096
        let url = try writeRawFixture(root: root, bodies: [(offset, jpeg)], size: UInt64(offset) + UInt64(jpeg.count))
        let store = CameraOriginalStore(root: root); _ = try await store.originals(since: -1, rescan: true)
        let actual = try await store.originalRawPreviewData(locator: url.absoluteString)
        XCTAssertEqual(actual, jpeg)
        do { _ = try await store.originalData(locator: url.absoluteString); XCTFail("Ordinary bitmap retains its existing full-read size bound") }
        catch { XCTAssertTrue(error is OriginalIndexError) }
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(fileSize, Int(offset) + jpeg.count)
    }

    func testRawPreviewCanUseScannedJpegWithoutTiffDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = try orientedPreviewFixture(width: 60, height: 40, orientation: 1)
        let url = try writeRawFixture(root: root, bodies: [(1024, jpeg)], header: Data(repeating: 0, count: 128))
        let store = CameraOriginalStore(root: root); _ = try await store.originals(since: -1, rescan: true)
        let actual = try await store.originalRawPreviewData(locator: url.absoluteString)
        XCTAssertEqual(actual, jpeg)
    }

    func testRawPreviewEqualPixelAreaKeepsFirstCandidateInOriginalIndexOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = padJpegFixture(try orientedPreviewFixture(width: 60, height: 40, orientation: 1))
        let second = try orientedPreviewFixture(width: 40, height: 60, orientation: 1)
        let url = try writeRawFixture(root: root, bodies: [(4096, first), (100_000, second)])
        let store = CameraOriginalStore(root: root); _ = try await store.originals(since: -1, rescan: true)
        let actual = try await store.originalRawPreviewData(locator: url.absoluteString)
        XCTAssertEqual(actual, first)
    }

    func testRawPreviewSkipsOutOfFileAndUndecodableCandidates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = try orientedPreviewFixture(width: 40, height: 30, orientation: 1)
        let url = try writeRawFixture(root: root, bodies: [(4096, Data([0xff, 0xd8, 0xff, 0xd9])), (8192, jpeg)],
            ranges: [(UInt32.max, 100_000), (4096, 4), (8192, UInt32(jpeg.count))])
        let store = CameraOriginalStore(root: root); _ = try await store.originals(since: -1, rescan: true)
        let actual = try await store.originalRawPreviewData(locator: url.absoluteString)
        XCTAssertEqual(actual, jpeg)
    }

    func testRawPreviewUsesExactIndexAndRejectsChangedSizeOrSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = try orientedPreviewFixture(width: 40, height: 30, orientation: 1)
        let url = try writeRawFixture(root: root, bodies: [(4096, jpeg)])
        let store = CameraOriginalStore(root: root)
        do { _ = try await store.originalRawPreviewData(locator: url.absoluteString); XCTFail("Unpublished locator") } catch {}
        _ = try await store.originals(since: -1, rescan: true)
        let before = try Data(contentsOf: url)
        try Data([1]).write(to: url)
        do { _ = try await store.originalRawPreviewData(locator: url.absoluteString); XCTFail("Changed size") } catch {}
        try before.write(to: url)
        let moved = root.appendingPathComponent("MOVED.NEF"); try FileManager.default.moveItem(at: url, to: moved)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: moved)
        do { _ = try await store.originalRawPreviewData(locator: url.absoluteString); XCTFail("Symlink") } catch {}
    }

    func testRawPreviewCancellationPrecedesFileAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CameraOriginalStore(root: root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.originalRawPreviewData(locator: "file:///not-owned.NEF")
        }
        do { _ = try await task.value; XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRawNativeBridgeContainsMalformedTiffExceptionsAndChecksJpegEnvelope() throws {
        var header = rawIndexFixture([])
        header[4] = 0xff; header[5] = 0xff; header[6] = 0xff; header[7] = 0x7f
        XCTAssertTrue(NativeRawPreviewBridge.shared.candidates(data: header as NSData).isEmpty)
        XCTAssertTrue(NativeRawPreviewBridge.shared.candidates(data: Data(repeating: 0, count: 16 * 1024 * 1024 + 1) as NSData).isEmpty)
        XCTAssertTrue(NativeRawPreviewBridge.shared.isCompleteJpeg(data: Data([0xff, 0xd8, 0xff, 0xd9]) as NSData))
        XCTAssertFalse(NativeRawPreviewBridge.shared.isCompleteJpeg(data: Data([0xff, 0xd8, 0xff, 0xd9, 0]) as NSData))
        XCTAssertFalse(NativeRawPreviewBridge.shared.isCompleteJpeg(data: Data() as NSData))
    }

    private func orientedPreviewFixture(width: Int, height: Int, orientation: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testLocalPreviewReadsOnlyAnAlreadyPublishedIndexWithoutRescanningOrMutatingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("ORIGINAL.JPG")
        let bytes = Data(repeating: 37, count: 150_123) // More than two read chunks.
        try bytes.write(to: url)
        let store = CameraOriginalStore(root: root)
        do { _ = try await store.originalData(locator: url.absoluteString); XCTFail("No published locator yet") }
        catch { XCTAssertTrue(error is OriginalIndexError) }
        let index = try await store.originals(since: -1, rescan: true)
        let locator = try XCTUnwrap(index.entries.first?.url.absoluteString)
        let actual = try await store.originalData(locator: locator)
        XCTAssertEqual(actual, bytes)
        let unchanged = try await store.originals(since: index.revision, rescan: false)
        XCTAssertEqual(unchanged.revision, index.revision); XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testLocalPreviewRejectsExternalAliasesPrivatePartsAndNonFileLocators() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("A.JPG")
        try Data([1, 2, 3]).write(to: file)
        let part = root.appendingPathComponent(".nkpart_hidden.JPG")
        try Data([1, 2, 3]).write(to: part)
        let store = CameraOriginalStore(root: root)
        let snapshot = try await store.originals(since: -1, rescan: true)
        let locator = try XCTUnwrap(snapshot.entries.first?.url.absoluteString)
        for invalid in ["https://example.invalid/A.JPG", "file:///etc/passwd", locator + "?q=1",
                        locator + "#fragment", part.absoluteString, root.appendingPathComponent("missing.JPG").absoluteString] {
            do { _ = try await store.originalData(locator: invalid); XCTFail("Unowned locator: \(invalid)") }
            catch { XCTAssertTrue(error is OriginalIndexError) }
        }
    }

    func testLocalPreviewFailsOnDeletedOrChangedLengthWithoutChangingItsOldIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("A.JPG")
        try Data([1, 2, 3]).write(to: file)
        let store = CameraOriginalStore(root: root)
        let index = try await store.originals(since: -1, rescan: true)
        let locator = try XCTUnwrap(index.entries.first?.url.absoluteString)
        try Data([1, 2, 3, 4]).write(to: file)
        do { _ = try await store.originalData(locator: locator); XCTFail("Changed length") } catch {}
        try FileManager.default.removeItem(at: file)
        do { _ = try await store.originalData(locator: locator); XCTFail("Deleted file") } catch {}
        let unchanged = try await store.originals(since: index.revision, rescan: false)
        XCTAssertEqual(index.revision, unchanged.revision); XCTAssertTrue(unchanged.entries.isEmpty)
    }

    func testLocalPreviewCannotFollowAnIndexedLeafReplacedByASymlink() async throws {
        let area = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = area.appendingPathComponent("originals")
        defer { try? FileManager.default.removeItem(at: area) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("A.JPG")
        let outside = area.appendingPathComponent("outside.JPG")
        try Data([1, 2, 3]).write(to: file); try Data([9, 9, 9]).write(to: outside)
        let store = CameraOriginalStore(root: root)
        let index = try await store.originals(since: -1, rescan: true)
        let locator = try XCTUnwrap(index.entries.first?.url.absoluteString)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do { _ = try await store.originalData(locator: locator); XCTFail("Followed a symlink") }
        catch { XCTAssertTrue(error is OriginalIndexError) }
        XCTAssertEqual(try Data(contentsOf: outside), Data([9, 9, 9]))
    }

    func testLocalPreviewSupportsIndexedDateBucketButRejectsReplacementDirectorySymlink() async throws {
        let area = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = area.appendingPathComponent("originals")
        let folder = root.appendingPathComponent("ZT2026-09-05")
        defer { try? FileManager.default.removeItem(at: area) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("A.JPG"))
        let store = CameraOriginalStore(root: root)
        let index = try await store.originals(since: -1, rescan: true)
        let locator = try XCTUnwrap(index.entries.first?.url.absoluteString)
        let data = try await store.originalData(locator: locator); XCTAssertEqual(data, Data([1, 2, 3]))
        let moved = area.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        do { _ = try await store.originalData(locator: locator); XCTFail("Followed a replaced directory") }
        catch { XCTAssertTrue(error is OriginalIndexError) }
    }

    func testLocalPreviewReadHonorsCancellationBeforeAccessingStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CameraOriginalStore(root: root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.originalData(locator: "file:///not-owned.JPG")
        }
        do { _ = try await task.value; XCTFail("Cancelled reader must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLocalBitmapPreservesOriginalResolutionAndCameraPixelOrientation() async throws {
        let jpeg = try orientedPreviewFixture(width: 3000, height: 1500, orientation: 6)
        let decoder = PreviewImageDecoder()
        let png = try await decoder.originalBitmapPNG(jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 3000); XCTAssertEqual(image.height, 1500)
        let diagnostic = try await decoder.decode(jpeg)
        XCTAssertEqual(diagnostic.width, 1024); XCTAssertEqual(diagnostic.height, 2048)
    }

    @MainActor func testLocalBitmapBulkBridgeDoesNotApplyCameraFhdOrProbeLimits() async throws {
        let jpeg = try orientedPreviewFixture(width: 3000, height: 1500, orientation: 6)
        let png = try await PreviewImageDecoder().originalBitmapPNG(jpeg)
        let local = try XCTUnwrap(NativePreviewImageBridge.shared.localPng(data: png as NSData))
        XCTAssertEqual(local.width, 3000); XCTAssertEqual(local.height, 1500)
        XCTAssertNil(NativePreviewImageBridge.shared.fhdPng(data: png as NSData))
        var corrupt = png; corrupt[16] = 0xff
        XCTAssertNil(NativePreviewImageBridge.shared.localPng(data: corrupt as NSData))
        do { _ = try await PreviewImageDecoder().originalBitmapPNG(Data([1, 2, 3])); XCTFail("Malformed image") }
        catch { XCTAssertTrue(error is PreviewImageError) }
    }

    func testPreviewConfirmedMissIsCachedUntilMemoryClear() async throws {
        let source = FakePreviewSource(thumbs: [.missing, .bytes(Data([2]))])
        let store = CameraPreviewStore(source: source)
        let info = try sampleInfo(1)
        let first = try await store.thumbnail(info: info)
        let second = try await store.thumbnail(info: info)
        XCTAssertNil(first); XCTAssertNil(second)
        let before = await source.counts()
        XCTAssertEqual(before.thumb, 1)
        await store.clearForMemoryPressure()
        let after = try await store.thumbnail(info: info)
        XCTAssertEqual(after, Data([2]))
    }

    func testImageDecoderAppliesOrientationAndBoundsOutput() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
            bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let original = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = try await PreviewImageDecoder().decode(data as Data, maximumPixelSize: 10)
        XCTAssertEqual(image.width, 5); XCTAssertEqual(image.height, 10)
        let queuePNG = try await PreviewImageDecoder().queueThumbnailPNG(data as Data)
        XCTAssertLessThanOrEqual(queuePNG.count, 1_048_576)
        let queueImage = try await PreviewImageDecoder().decode(queuePNG, maximumPixelSize: 128)
        XCTAssertEqual(queueImage.width, 20); XCTAssertEqual(queueImage.height, 40)
        let gridPNG = try await PreviewImageDecoder().gridThumbnailPNG(data as Data)
        XCTAssertLessThanOrEqual(gridPNG.count, 4 * 1024 * 1024)
        let gridImage = try await PreviewImageDecoder().decode(gridPNG, maximumPixelSize: 512)
        XCTAssertEqual(gridImage.width, 20); XCTAssertEqual(gridImage.height, 40)
    }

    private func sampleInfo(_ handle: Int32, captureDate: String? = nil) throws -> PtpObjectInfo {
        var prefix = Data(repeating: 0, count: 52)
        prefix[0] = 1; prefix[2] = 1; prefix[4] = 1; prefix[5] = 0x38; prefix[8] = UInt8(handle)
        var payload = prefix + hex("0B730061006D0070006C0065002E004A0050004700000000")
        if let captureDate {
            payload.append(UInt8(captureDate.utf16.count + 1))
            for unit in captureDate.utf16 { payload.append(UInt8(unit & 0xff)); payload.append(UInt8(unit >> 8)) }
            payload.append(contentsOf: [0, 0])
        }
        return try XCTUnwrap(PtpIPChannel.objectInfo(handle: handle, payload: payload))
    }

    func testDataOutMatchesIndependentThreePacketVectorIncludingEmptyPayload() async throws {
        for data in [hex("AABBCC"), Data()] {
            let wire = FakeCameraConnection(bytes: response(transaction: 0x11223344))
            let stream = CameraTCPStream(connection: wire)
            try await stream.connect(timeout: 1)
            let session = PtpIPCommandSession(stream: stream, initialTransactionId: 0x11223343)
            _ = try await session.execute(operationCode: 0x1016, parameters: [0x55667788], outgoingData: data)
            let tail = data.isEmpty ? "14000000090000004433221100000000000000000C0000000C00000044332211"
                : "14000000090000004433221103000000000000000F0000000C00000044332211AABBCC"
            XCTAssertEqual(wire.sent(), [hex("16000000060000000200000016104433221188776655" + tail)])
            await session.close()
        }
    }

    func testThumbnailBusyIsRetryableAndConfirmedMissDoesNotPoisonConnection() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 3, code: 0x2019)
            + response(transaction: 4, payload: Data([1])) + response(transaction: 5, code: 0x2010))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        do { _ = try await camera.thumbnail(handle: 10); XCTFail("Busy must not be a cacheable miss") }
        catch { XCTAssertTrue(error is CameraOperationError) }
        let bytes = try await camera.thumbnail(handle: 10)
        let missing = try await camera.thumbnail(handle: 11)
        let state = await camera.snapshot()
        XCTAssertEqual(bytes, Data([1])); XCTAssertNil(missing); XCTAssertEqual(state.phase, .ready)
        await camera.abort()
    }

    func testExifHeaderUsesSharedPartialParametersForBothOriginalHeaderSizes() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 3, payload: Data([1,2]))
            + response(transaction: 4, payload: Data([3,4])))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        let jpeg = try await camera.exifHeader(handle: 7, maximumBytes: 128 * 1024)
        let raw = try await camera.exifHeader(handle: 7, maximumBytes: 2 * 1024 * 1024)
        XCTAssertEqual(jpeg, Data([1,2])); XCTAssertEqual(raw, Data([3,4]))
        XCTAssertEqual(Array(wire.sent().suffix(2)), [
            hex("2600000006000000010000003194" + "03000000" + "07000000" + "00000000" + "00000000" + "00000200" + "00000000"),
            hex("2600000006000000010000003194" + "04000000" + "07000000" + "00000000" + "00000000" + "00002000" + "00000000")])
        let state = await camera.snapshot(); XCTAssertEqual(state.phase, .ready)
        await camera.abort()
    }

    func testExifHeaderRejectedOrEmptyResponseIsMissWithoutRetryOrConnectionPoison() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 3, code: 0x2019)
            + response(transaction: 4, code: 0x2005) + response(transaction: 5, code: 0x2009)
            + response(transaction: 6) + response(transaction: 7, payload: Data()))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        for _ in 0..<5 {
            let result = try await camera.exifHeader(handle: 7, maximumBytes: 128 * 1024)
            XCTAssertNil(result)
            let state = await camera.snapshot(); XCTAssertEqual(state.phase, .ready)
        }
        XCTAssertEqual(wire.sent().count, 8)
        await camera.abort()
    }

    func testExifHeaderInvalidLimitNeverUsesWireAndMalformedTransactionClosesOwner() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 99, payload: Data([1])))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        for invalid in [Int32(0), -1, 2 * 1024 * 1024 + 1] {
            await expect(.invalidArgument) { _ = try await camera.exifHeader(handle: 7, maximumBytes: invalid) }
        }
        XCTAssertEqual(wire.sent().count, 3)
        let result = try await camera.exifHeader(handle: 7, maximumBytes: 128 * 1024)
        XCTAssertNil(result)
        let state = await camera.snapshot(); XCTAssertEqual(state.phase, .closed)
    }

    func testCancelledExifRequestDoesNotInterruptAnotherActiveCameraTransaction() async throws {
        let sent = expectation(description: "storage command active")
        let storageRequest = hex("120000000600000001000000041003000000")
        let wire = FakeCameraConnection(bytes: apOpeningReplies(), onSend: { if $0 == storageRequest { sent.fulfill() } })
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        let active = Task { try await camera.storageIDs() }
        await fulfillment(of: [sent], timeout: 1)
        let cancelled = Task { try await camera.exifHeader(handle: 7, maximumBytes: 128 * 1024) }
        await Task.yield(); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation is not an EXIF cache miss") }
        catch { XCTAssertTrue(error is CancellationError) }
        wire.feed(response(transaction: 3, payload: hex("0100000001000100")))
        let stores = try await active.value
        XCTAssertEqual(stores, [0x10001]); XCTAssertEqual(wire.sent().count, 4)
        let state = await camera.snapshot(); XCTAssertEqual(state.phase, .ready)
        await camera.abort()
    }

    func testPreCancelledCameraHeaderParsingThrowsInsteadOfReturningPartialExif() async throws {
        let jpeg = try rawBiasJpegFixture(numerator: 36_293_949, denominator: 725_879_001, little: true)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PreviewExifReader.metadata(header: Data(jpeg.prefix(64)))
        }
        do { _ = try await cancelled.value; XCTFail("Expected parsing cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testFhdSuccessPreventsLaterUnsupportedResponseFromLatchingOff() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 3, payload: Data([1]))
            + response(transaction: 4, code: 0x2005) + response(transaction: 5, payload: Data([2])))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        let first = try await camera.fhdPicture(handle: 10)
        let unsupported = try await camera.fhdPicture(handle: 11)
        let next = try await camera.fhdPicture(handle: 12)
        XCTAssertEqual(first, Data([1])); XCTAssertNil(unsupported); XCTAssertEqual(next, Data([2]))
        await camera.abort()
    }

    func testFhdInitialUnsupportedStopsRepeatedWireRequests() async throws {
        let wire = FakeCameraConnection(bytes: apOpeningReplies() + response(transaction: 3, code: 0x2005))
        let camera = apCamera(command: wire)
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        let first = try await camera.fhdPicture(handle: 10)
        let next = try await camera.fhdPicture(handle: 11)
        XCTAssertNil(first); XCTAssertNil(next); XCTAssertEqual(wire.sent().count, 4)
        await camera.abort()
    }

    func testPhotoImportDeniedNeverSubmitsAndRetainsOriginal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = FakePhotoLibrary(authorization: .notDetermined, requested: .denied)
        do { try await PhotoLibraryImporter(client: client).save(url); XCTFail("Expected denial") }
        catch { guard case PhotoLibraryImportError.permissionDenied = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(client.requests, 1)
        XCTAssertEqual(client.imports, 0)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }

    func testPhotoImportFailureRetainsOriginalWithoutRetry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = FakePhotoLibrary(authorization: .allowed, success: false)
        do { try await PhotoLibraryImporter(client: client).save(url); XCTFail("Expected failure") }
        catch { guard case PhotoLibraryImportError.importFailed = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(client.requests, 0)
        XCTAssertEqual(client.imports, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testPhotoUnsupportedTypeDoesNotPrompt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = FakePhotoLibrary(authorization: .notDetermined)
        do { try await PhotoLibraryImporter(client: client).save(url); XCTFail("Expected unsupported type") }
        catch { guard case PhotoLibraryImportError.unsupportedType = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(client.requests, 0)
        XCTAssertEqual(client.imports, 0)
    }

    func testPhotoCancellationAfterSubmitReportsActualSuccess() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let submitted = expectation(description: "Photos submitted")
        let client = FakePhotoLibrary(authorization: .allowed, hold: true, onSubmit: { submitted.fulfill() })
        let importer = PhotoLibraryImporter(client: client)
        let task = Task { try await importer.save(url) }
        await fulfillment(of: [submitted], timeout: 1)
        task.cancel()
        client.complete()
        try await task.value
        XCTAssertEqual(client.imports, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func stationAck() -> Data { hex("1C000000020000004433221100112233445566778899AABBCCDDEEFF") }

    private func stationCamera(command: FakeCameraConnection, event: FakeCameraConnection? = nil) -> CameraWiFiConnection {
        CameraWiFiConnection(command: CameraTCPStream(connection: command),
                             event: CameraTCPStream(connection: event ?? FakeCameraConnection(bytes: hex("0800000004000000"))),
                             stationMode: true)
    }

    private func apCamera(command: FakeCameraConnection, event: FakeCameraConnection? = nil) -> CameraWiFiConnection {
        CameraWiFiConnection(command: CameraTCPStream(connection: command),
                           event: CameraTCPStream(connection: event ?? FakeCameraConnection(bytes: hex("0800000004000000"))))
    }

    private func apOpeningReplies() -> Data {
        hex("0C0000000200000044332211") + response(transaction: 1)
            + response(transaction: 2, code: 0x2005)
    }

    // Independent fixture writer; never calls a production codec to generate expected bytes.
    private func response(transaction: UInt32, code: UInt16 = 0x2001, payload: Data? = nil) -> Data {
        func u32(_ value: UInt32) -> Data {
            Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        var bytes = Data()
        if let payload { bytes = u32(UInt32(12 + payload.count)) + u32(12) + u32(transaction) + payload }
        return bytes + u32(14) + u32(7) + Data([UInt8(truncatingIfNeeded: code), UInt8(code >> 8)]) + u32(transaction)
    }

    private func expect(_ expected: CameraStreamError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? CameraStreamError, expected) }
    }

    private func hex(_ text: String) -> Data {
        let characters = Array(text)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }
}

/// Tests mutate fields only after awaited store calls complete; no concurrent mutation.
private final class FakeDirectoryAccess: ExportDirectoryAccess {
    let url: URL
    var allowed = true
    var stale = false
    var starts = 0
    var stops = 0
    private var version: UInt8 = 0
    init(url: URL) { self.url = url }
    func start(_ url: URL) -> Bool { starts += 1; return allowed }
    func stop(_ url: URL) { stops += 1 }
    func isDirectory(_ url: URL) -> Bool { true }
    func bookmark(_ url: URL) -> Data { version += 1; return Data([version]) }
    func resolve(_ bookmark: Data) -> ResolvedExportDirectory { ResolvedExportDirectory(url: url, stale: stale) }
}

private actor FakeCatalogSource: CameraCatalogSource {
    nonisolated let connectionID = UUID()
    private var infos: [Int32: PtpObjectInfo]
    private var failure = false
    private var revision: UInt64 = 0
    private let changeDuringRead: Bool
    init(infos: [Int32: PtpObjectInfo], changeDuringRead: Bool = false) { self.infos = infos; self.changeDuringRead = changeDuringRead }
    func failEnumeration() { failure = true }
    func removeMetadata(_ handle: Int32) { infos[handle] = nil }
    func storageIDs() throws -> [Int32] {
        if failure { throw CameraOperationError.malformedDataset(operation: 0x1004) }
        return [0x10001]
    }
    func objectHandles(storageID: Int32) -> [Int32] { [1, 2] }
    func objectInfo(handle: Int32) throws -> PtpObjectInfo {
        if changeDuringRead { revision &+= 1 }
        guard let info = infos[handle] else { throw CameraOperationError.malformedDataset(operation: 0x1008) }
        return info
    }
    func snapshot() -> CameraConnectionSnapshot {
        CameraConnectionSnapshot(connectionID: connectionID, phase: .ready, eventRevision: revision, errorDescription: nil)
    }
}

private actor FillPreviewSource: CameraPreviewSource {
    enum Result { case bytes(Data), missing, busy }
    private var results: [Int32: [Result]]
    private let holdFirst: Bool
    private let onFirst: (@Sendable () -> Void)?
    private var held: CheckedContinuation<Void, Never>?
    private var handles: [Int32] = []
    private var active = 0
    private var maximumActive = 0
    init(results: [Int32: [Result]], holdFirst: Bool = false, onFirst: (@Sendable () -> Void)? = nil) {
        self.results = results; self.holdFirst = holdFirst; self.onFirst = onFirst
    }
    func thumbnail(handle: Int32) async throws -> Data? {
        handles.append(handle); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if handles.count == 1, holdFirst {
            await withCheckedContinuation { continuation in held = continuation; onFirst?() }
        }
        guard var values = results[handle], !values.isEmpty else { throw CameraStreamError.closed }
        let next = values.removeFirst(); results[handle] = values
        switch next {
        case .bytes(let data): return data
        case .missing: return nil
        case .busy: throw CameraOperationError.rejected(operation: 0x100A, response: 0x2019)
        }
    }
    func releaseFirst() { held?.resume(); held = nil }
    func fhdPicture(handle: Int32, retryDeviceBusy: Bool) -> Data? { nil }
    func stats() -> (handles: [Int32], maximumActive: Int) { (handles, maximumActive) }
}

private actor HeldPreviewSource: CameraPreviewSource {
    private let started: @Sendable () -> Void
    private var continuation: CheckedContinuation<Data?, Never>?
    init(started: @escaping @Sendable () -> Void) { self.started = started }
    func thumbnail(handle: Int32) async -> Data? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started()
        }
    }
    func complete(_ data: Data) { continuation?.resume(returning: data); continuation = nil }
    func fhdPicture(handle: Int32, retryDeviceBusy: Bool) -> Data? { nil }
}

private actor FakePreviewSource: CameraPreviewSource {
    enum Result { case missing, bytes(Data), failure }
    private var thumbs: [Result]
    private var fhds: [Result]
    private var thumbCount = 0
    private var fhdCount = 0
    init(thumbs: [Result], fhds: [Result] = []) { self.thumbs = thumbs; self.fhds = fhds }
    func thumbnail(handle: Int32) throws -> Data? {
        thumbCount += 1
        guard !thumbs.isEmpty else { throw CameraStreamError.closed }
        switch thumbs.removeFirst() {
        case .missing: return nil
        case .bytes(let data): return data
        case .failure: throw CameraOperationError.rejected(operation: 0x100A, response: 0x2019)
        }
    }
    func fhdPicture(handle: Int32, retryDeviceBusy: Bool) throws -> Data? {
        fhdCount += 1
        guard !fhds.isEmpty else { return nil }
        switch fhds.removeFirst() {
        case .missing: return nil
        case .bytes(let data): return data
        case .failure: throw CameraOperationError.rejected(operation: 0x920f, response: 0x2019)
        }
    }
    func counts() -> (thumb: Int, fhd: Int) { (thumbCount, fhdCount) }
}

private final class FakePhotoLibrary: PhotoLibraryClient {
    private let lock = NSLock()
    private let state: PhotoLibraryAuthorization
    private let requested: PhotoLibraryAuthorization
    private let success: Bool
    private let hold: Bool
    private let onSubmit: (() -> Void)?
    private var completion: ((Bool, Error?) -> Void)?
    private var requestCount = 0
    private var importCount = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return requestCount }
    var imports: Int { lock.lock(); defer { lock.unlock() }; return importCount }
    init(authorization: PhotoLibraryAuthorization, requested: PhotoLibraryAuthorization = .allowed,
         success: Bool = true, hold: Bool = false, onSubmit: (() -> Void)? = nil) {
        state = authorization; self.requested = requested; self.success = success
        self.hold = hold; self.onSubmit = onSubmit
    }
    func authorization() -> PhotoLibraryAuthorization { state }
    func requestAddOnly(_ completion: @escaping (PhotoLibraryAuthorization) -> Void) {
        lock.lock(); requestCount += 1; lock.unlock()
        completion(requested)
    }
    func importFile(_ url: URL, kind: PhotoImportKind, completion: @escaping (Bool, Error?) -> Void) {
        lock.lock(); importCount += 1; self.completion = completion; lock.unlock()
        onSubmit?()
        if !hold { complete() }
    }
    func complete() {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(success, nil)
    }
}

/// Deliberately retains callbacks after cancel to reproduce Network.framework late completions.
private actor BackgroundAdmissionProbe {
    private var allowed = true
    private(set) var checks = 0
    func check() -> Bool { checks += 1; return allowed }
    func deny() { allowed = false }
}

private final class FakeCameraConnection: CameraByteConnection {
    private let lock = NSLock()
    private var bytes: Data
    private let chunkSize: Int
    private var eof: Bool
    private let autoReady: Bool
    private let holdWrites: Bool
    private let onReceive: (() -> Void)?
    private let onSend: ((Data) -> Void)?
    private var output: [Data] = []
    private var stateCallback: ((CameraConnectionEvent) -> Void)?
    private var receiveCallback: ((Data?, Bool, Error?) -> Void)?
    private var pendingReceive: (maximum: Int, callback: (Data?, Bool, Error?) -> Void)?

    init(bytes: Data = Data(), chunkSize: Int = 65536, eof: Bool = false, autoReady: Bool = true,
         holdWrites: Bool = false, onReceive: (() -> Void)? = nil, onSend: ((Data) -> Void)? = nil) {
        self.bytes = bytes; self.chunkSize = chunkSize; self.eof = eof
        self.autoReady = autoReady; self.holdWrites = holdWrites; self.onReceive = onReceive
        self.onSend = onSend
    }
    func start(on queue: DispatchQueue, state: @escaping (CameraConnectionEvent) -> Void) {
        lock.lock(); stateCallback = state; lock.unlock()
        if autoReady { state(.ready) }
    }
    func receive(maximumLength: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
        lock.lock()
        receiveCallback = completion
        let count = min(bytes.count, min(maximumLength, chunkSize))
        let value = Data(bytes.prefix(count))
        bytes.removeFirst(count)
        let complete = eof && bytes.isEmpty
        if count == 0 && !complete { pendingReceive = (maximumLength, completion) }
        lock.unlock()
        onReceive?()
        if count > 0 || complete { completion(value, complete, nil) }
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        lock.lock(); output.append(data); lock.unlock()
        onSend?(data)
        if !holdWrites { completion(nil) }
    }
    func cancel() {}
    func sent() -> [Data] { lock.lock(); defer { lock.unlock() }; return output }
    func lateReady() {
        lock.lock(); let callback = stateCallback; lock.unlock(); callback?(.ready)
    }
    func lateReceive() {
        lock.lock(); let callback = receiveCallback; lock.unlock(); callback?(Data(repeating: 1, count: 8), false, nil)
    }
    func feed(_ data: Data) {
        lock.lock()
        bytes.append(data)
        let pending = pendingReceive
        pendingReceive = nil
        let count = min(bytes.count, pending?.maximum ?? 0)
        let value = Data(bytes.prefix(count))
        bytes.removeFirst(count)
        let complete = eof && bytes.isEmpty
        lock.unlock()
        pending?.callback(value, complete, nil)
    }
    func finish() {
        lock.lock(); eof = true; lock.unlock()
        feed(Data())
    }
}
