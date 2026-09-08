import Foundation
import ZTransferShared
import XCTest
@testable import ZTransfer

/// Source-level coverage until executed by Xcode on a Mac. These exercise the real catalog actor
/// and shared publication policies; the fake only supplies camera IO and deterministic suspension.
final class CatalogEventReconciliationTests: XCTestCase {
    func testRemovalPromotesBackupWithoutReadingMetadataAndPrunesAliasIndex() async throws {
        let source = EventCatalogSource(infos: [try info(91), try info(7, storage: 0x20001)])
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false, onChange: { await sink.change($0) })
        _ = try await catalog.refresh()
        let reads = await source.metadataReads
        await source.replace(storage: 0x10001, handles: [])
        await event(catalog, source, code: 0x4003, handle: 91, revision: 1)
        try await until { await sink.changes.count == 1 }
        let result = try unwrapCatalogValue(await catalog.snapshot())
        XCTAssertEqual(result.files.map(\.handle), [7])
        XCTAssertEqual(result.files[0].storageIds.map { $0.int32Value }, [0x20001])
        XCTAssertEqual(result.indexedObjectInfos.map(\.handle), [7])
        XCTAssertEqual(Set(result.objectInfos.keys), Set([Int32(7)]))
        let after = await source.metadataReads
        XCTAssertEqual(after, reads, "Removal is a handle-only query, never a new ObjectInfo scan")
        await catalog.close()
    }

    func testRemovalOfBackupKeepsPrimaryAndDropsOnlyBackupMembership() async throws {
        let source = EventCatalogSource(infos: [try info(91), try info(7, storage: 0x20001)])
        let catalog = CameraCatalog(source: source, stationMode: false)
        _ = try await catalog.refresh()
        await source.replace(storage: 0x20001, handles: [])
        await event(catalog, source, code: 0x4003, handle: 7, revision: 1)
        try await until { await catalog.snapshot()?.objectInfos.count == 1 }
        let result = try unwrapCatalogValue(await catalog.snapshot())
        XCTAssertEqual(result.files.map(\.handle), [91])
        XCTAssertEqual(result.files[0].storageIds.map { $0.int32Value }, [0x10001])
        await catalog.close()
    }

    func testSuccessfulEmptyAllCardEnumerationRemovesRowsButFailedCardDoesNot() async throws {
        let source = EventCatalogSource(infos: [try info(1), try info(2, name: "B.JPG", storage: 0x20001)])
        let catalog = CameraCatalog(source: source, stationMode: false)
        _ = try await catalog.refresh()
        await source.replace(storage: 0x10001, handles: [])
        await source.replace(storage: 0x20001, handles: [])
        await source.failStorage(0x20001)
        await event(catalog, source, code: 0x4003, handle: 1, revision: 1)
        try await until { await source.rejections > 0 }
        let preserved = await catalog.snapshot()
        XCTAssertEqual(preserved?.files.count, 2)
        await source.failStorage(nil)
        try await until { await catalog.snapshot()?.files.isEmpty == true }
        await catalog.close()
    }

    func testObjectInfoChangedRefreshesNameAndCacheWithoutAutomaticOldPhotoAddition() async throws {
        let old = try info(1), source = EventCatalogSource(infos: [try info(1)])
        let previews = CameraPreviewStore(source: EventPreviewSource(), connectionID: source.connectionID)
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false, previews: previews,
            onAddition: { await sink.addition($0) }, onChange: { await sink.change($0) })
        _ = try await catalog.refresh()
        _ = try await previews.thumbnail(info: old)
        let cached = try await previews.thumbnail(info: old, allowRemote: false)
        XCTAssertNotNil(cached)
        await source.update(try info(1, name: "RENAMED.NEF"))
        await event(catalog, source, code: 0x4007, handle: 1, revision: 1)
        try await until { await sink.changes.count == 1 }
        let snapshot = await catalog.snapshot(), additions = await sink.additions
        XCTAssertEqual(snapshot?.files.first?.fileName, "RENAMED.NEF")
        XCTAssertTrue(additions.isEmpty)
        let obsolete = try await previews.thumbnail(info: old, allowRemote: false)
        XCTAssertNil(obsolete)
        await catalog.close(); await previews.close()
    }

    func testStoreAddedRefreshesStorageIDsAndMergesBackupWithoutNewMedia() async throws {
        let source = EventCatalogSource(infos: [try info(1)])
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false,
            onAddition: { await sink.addition($0) }, onChange: { await sink.change($0) })
        _ = try await catalog.refresh()
        await source.update(try info(2, storage: 0x20001))
        await source.replace(storage: 0x20001, handles: [2])
        await event(catalog, source, code: 0x4004, handle: 0x20001, revision: 1)
        try await until { await sink.additions.count == 1 }
        let snapshot = await catalog.snapshot(), additions = await sink.additions
        XCTAssertEqual(snapshot?.storageIDs, [0x10001, 0x20001])
        XCTAssertEqual(snapshot?.files.count, 1)
        XCTAssertEqual(snapshot?.files.first?.storageIds.count, 2)
        XCTAssertEqual(additions.count, 1)
        XCTAssertNil(additions.first?.newMedia)
        await catalog.close()
    }

    func testExposureDevicePropChangedDoesNotScanPhotoCatalog() async throws {
        let source = EventCatalogSource(infos: [try info(1)])
        let catalog = CameraCatalog(source: source, stationMode: false)
        _ = try await catalog.refresh()
        let reads = await source.handleReads
        await event(catalog, source, code: 0x4006, handle: 0x5007, revision: 1)
        try await Task.sleep(nanoseconds: 220_000_000)
        let after = await source.handleReads, needed = await catalog.needsEventRescan
        XCTAssertEqual(after, reads); XCTAssertFalse(needed)
        await catalog.close()
    }

    func testTransferAndForegroundPreviewAdmissionHoldRemovalUntilBothAreIdle() async throws {
        let source = EventCatalogSource(infos: [try info(1)])
        let previews = CameraPreviewStore(source: EventPreviewSource(), connectionID: source.connectionID)
        let catalog = CameraCatalog(source: source, stationMode: false, previews: previews)
        _ = try await catalog.refresh()
        let reads = await source.handleReads
        await previews.setTransfersBusy(true)
        let token = await previews.beginForegroundUse()
        await source.replace(storage: 0x10001, handles: [])
        await event(catalog, source, code: 0x4003, handle: 1, revision: 1)
        try await Task.sleep(nanoseconds: 220_000_000)
        await previews.setTransfersBusy(false)
        try await Task.sleep(nanoseconds: 120_000_000)
        let blocked = await source.handleReads
        XCTAssertEqual(blocked, reads)
        await previews.endForegroundUse(token)
        try await until { await catalog.snapshot()?.files.isEmpty == true }
        await catalog.close(); await previews.close()
    }

    func testEventGapRescanReportsOnlyGenuinelyNewMediaOnce() async throws {
        let source = EventCatalogSource(infos: [try info(1, name: "OLD.JPG")])
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false,
            onAddition: { await sink.addition($0) }, onChange: { await sink.change($0) })
        _ = try await catalog.refresh()
        await source.update(try info(2, name: "NEW.NEF"))
        await source.replace(storage: 0x10001, handles: [1, 2])
        await source.setRevision(300)
        let batch = CameraEventBatch(cursor: CameraEventCursor(connectionID: source.connectionID, revision: 300),
                                     events: [], requiresRescan: true)
        await catalog.receiveEvents(batch)
        try await until { await sink.additions.count == 1 }
        await catalog.receiveEvents(batch)
        try await Task.sleep(nanoseconds: 180_000_000)
        let additions = await sink.additions
        XCTAssertEqual(additions.map { $0.newMedia?.handle }, [2])
        let snapshot = await catalog.snapshot()
        XCTAssertEqual(snapshot?.files.count, 2)
        await catalog.close()
    }

    func testPartialMetadataRescanKeepsOldRowsAndDoesNotSwallowNewHandle() async throws {
        let source = EventCatalogSource(infos: [try info(1, name: "OLD.JPG")])
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false, onAddition: { await sink.addition($0) })
        _ = try await catalog.refresh()
        await source.update(try info(2, name: "NEW.JPG"))
        await source.replace(storage: 0x10001, handles: [1, 2])
        await source.failInfo(2)
        await event(catalog, source, code: 0x400C, handle: 0x10001, revision: 1)
        try await until { await source.rejections > 0 }
        let old = await catalog.snapshot(), before = await sink.additions
        XCTAssertEqual(old?.files.map(\.handle), [1]); XCTAssertTrue(before.isEmpty)
        await source.failInfo(nil)
        try await until { await sink.additions.count == 1 }
        let after = await sink.additions
        XCTAssertEqual(after.first?.newMedia?.handle, 2)
        await catalog.close()
    }

    func testNewRequestDuringHeldEnumerationCannotBeClearedByOldResult() async throws {
        let source = EventCatalogSource(infos: [try info(1), try info(2, name: "B.JPG")])
        let catalog = CameraCatalog(source: source, stationMode: false)
        _ = try await catalog.refresh()
        await source.replace(storage: 0x10001, handles: [2])
        await source.holdNextHandles()
        await event(catalog, source, code: 0x4003, handle: 1, revision: 1)
        try await until { await source.isHeld }
        await source.replace(storage: 0x10001, handles: [])
        await event(catalog, source, code: 0x4003, handle: 2, revision: 2)
        await source.release()
        try await until { await catalog.snapshot()?.files.isEmpty == true }
        let final = await catalog.snapshot()
        XCTAssertEqual(final?.revision, 2)
        await catalog.close()
    }

    func testManualScanGenerationSupersedesHeldRemovalQuery() async throws {
        let source = EventCatalogSource(infos: [try info(1)])
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false, onChange: { await sink.change($0) })
        _ = try await catalog.refresh()
        await source.replace(storage: 0x10001, handles: [])
        await source.holdNextHandles()
        await event(catalog, source, code: 0x4003, handle: 1, revision: 1)
        try await until { await source.isHeld }
        await source.update(try info(2, name: "FRESH.JPG"))
        await source.replace(storage: 0x10001, handles: [2])
        let newer = try await catalog.refresh()
        await source.release()
        try await Task.sleep(nanoseconds: 180_000_000)
        let final = await catalog.snapshot(), changes = await sink.changes
        XCTAssertEqual(final?.publicationRevision, newer.publicationRevision)
        XCTAssertEqual(final?.files.map(\.handle), [2]); XCTAssertTrue(changes.isEmpty)
        await catalog.close()
    }

    func testRacedFullScanSchedulesCatchupAndPreservesOldSnapshotUntilStable() async throws {
        let source = EventCatalogSource(infos: [try info(1, name: "OLD.JPG")])
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false,
            onAddition: { await sink.addition($0) }, onChange: { await sink.change($0) })
        _ = try await catalog.refresh()
        await source.holdNextInfo()
        let scan = Task { try await catalog.refresh() }
        try await until { await source.isHeld }
        await source.update(try info(2, name: "NEW.JPG"))
        await source.replace(storage: 0x10001, handles: [1, 2])
        await event(catalog, source, code: 0x4002, handle: 2, revision: 1)
        await source.release()
        let raced = try await scan.value
        XCTAssertTrue(raced.changedWhileScanning)
        try await until { await sink.additions.count == 1 }
        let final = await catalog.snapshot(), additions = await sink.additions
        XCTAssertEqual(final?.files.count, 2)
        XCTAssertEqual(additions.first?.newMedia?.handle, 2)
        await catalog.close()
    }

    func testCloseWhileQueryIsHeldNeverPublishesOrRestartsWorker() async throws {
        let source = EventCatalogSource(infos: [try info(1)])
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false, onChange: { await sink.change($0) })
        let original = try await catalog.refresh()
        await source.replace(storage: 0x10001, handles: [])
        await source.holdNextHandles()
        await event(catalog, source, code: 0x4003, handle: 1, revision: 1)
        try await until { await source.isHeld }
        await catalog.close(); await source.release()
        try await Task.sleep(nanoseconds: 180_000_000)
        let snapshot = await catalog.snapshot(), changes = await sink.changes
        XCTAssertEqual(snapshot?.publicationRevision, original.publicationRevision)
        XCTAssertTrue(changes.isEmpty)
    }

    func testForeignAndRepeatedBatchesDoNotTriggerExtraQueries() async throws {
        let source = EventCatalogSource(infos: [try info(1)])
        let catalog = CameraCatalog(source: source, stationMode: false)
        _ = try await catalog.refresh()
        let reads = await source.handleReads
        await catalog.receiveEvents(CameraEventBatch(cursor: CameraEventCursor(connectionID: UUID(), revision: 10),
                                                       events: [], requiresRescan: true))
        await event(catalog, source, code: 0x4006, handle: 1, revision: 2)
        await catalog.receiveEvents(CameraEventBatch(cursor: CameraEventCursor(connectionID: source.connectionID, revision: 1),
                                                       events: [], requiresRescan: true))
        try await Task.sleep(nanoseconds: 180_000_000)
        let after = await source.handleReads
        XCTAssertEqual(after, reads)
        await catalog.close()
    }

    func testObserverLagDoesNotPublishRemovalUntilLatestRevisionIsForwarded() async throws {
        let source = EventCatalogSource(infos: [try info(1), try info(2, name: "B.JPG")])
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false, onChange: { await sink.change($0) })
        _ = try await catalog.refresh()
        await source.replace(storage: 0x10001, handles: [])
        await event(catalog, source, code: 0x4003, handle: 1, revision: 1)
        await source.setRevision(2) // Socket already saw the second deletion; observer has not.
        try await Task.sleep(nanoseconds: 220_000_000)
        let blocked = await sink.changes
        XCTAssertTrue(blocked.isEmpty)
        await event(catalog, source, code: 0x4003, handle: 2, revision: 2)
        try await until { await catalog.snapshot()?.files.isEmpty == true }
        await catalog.close()
    }

    func testFirstPartialBaselineRecoveryAndManualDetectionOffNeverAutoPublishOldPhotos() async throws {
        let source = EventCatalogSource(infos: [try info(1), try info(2, name: "SECOND.JPG")])
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false, onAddition: { await sink.addition($0) })
        await source.failInfo(2)
        let partial = try await catalog.refresh()
        XCTAssertFalse(partial.metadataComplete)
        await source.failInfo(nil)
        _ = try await catalog.refresh()
        await source.update(try info(3, name: "MANUAL.JPG"))
        await source.replace(storage: 0x10001, handles: [1, 2, 3])
        _ = try await catalog.refresh(detectNewHandles: false)
        let additions = await sink.additions, snapshot = await catalog.snapshot()
        XCTAssertTrue(additions.isEmpty)
        XCTAssertEqual(snapshot?.files.count, 3)
        await catalog.close()
    }

    func testObjectAddedAfterManualEnumerationBaselineCommitStillSurvivesCatchup() async throws {
        let source = EventCatalogSource(infos: [try info(1, name: "OLD.JPG")])
        let sink = EventCatalogSink()
        let catalog = CameraCatalog(source: source, stationMode: false, onAddition: { await sink.addition($0) })
        _ = try await catalog.refresh()
        await source.update(try info(2, name: "NEW.JPG"))
        await source.replace(storage: 0x10001, handles: [1, 2])
        await source.holdNextInfo()
        let scan = Task { try await catalog.refresh(detectNewHandles: false) }
        try await until { await source.isHeld }
        await event(catalog, source, code: 0x4002, handle: 2, revision: 1)
        await source.release()
        _ = try await scan.value
        try await until { await sink.additions.count == 1 }
        let additions = await sink.additions
        XCTAssertEqual(additions.first?.newMedia?.handle, 2)
        await catalog.close()
    }

    func testRealQueuedCatalogCommandRechecksAdmissionAfterFIFOAndConsumesNoTransactionID() async throws {
        let wire = EventCatalogWire(bytes: openingReplies())
        let events = EventCatalogWire(bytes: Data([8, 0, 0, 0, 4, 0, 0, 0]))
        let camera = CameraWiFiConnection(command: CameraTCPStream(connection: wire), event: CameraTCPStream(connection: events))
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        let foreground = Task { try await camera.storageIDs() }
        try await until { wire.sentCount == 4 }
        let admission = EventCatalogAdmission()
        let queued = Task { try await camera.catalogObjectHandles(storageID: 0x10001, permitted: { await admission.check() }) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let before = await admission.checks
        XCTAssertEqual(before, 0, "Admission must be behind the command FIFO, not before queueing")
        await admission.deny()
        wire.feed(reply(transaction: 3, payload: Data([0, 0, 0, 0])))
        _ = try await foreground.value
        do { _ = try await queued.value; XCTFail("Queued catalog command must be denied") }
        catch { XCTAssertEqual(error as? CameraStreamError, .operationInProgress) }
        let checked = await admission.checks
        XCTAssertEqual(checked, 1); XCTAssertEqual(wire.sentCount, 4)
        wire.feed(reply(transaction: 4, payload: Data([0, 0, 0, 0])))
        let fresh = try await camera.catalogStorageIDs(permitted: { true })
        XCTAssertTrue(fresh.isEmpty)
        XCTAssertEqual(wire.lastSent, Data([18, 0, 0, 0, 6, 0, 0, 0, 1, 0, 0, 0, 4, 16, 4, 0, 0, 0]))
        await camera.abort()
    }

    func testRealCatalogIdentifierBusyAndMalformedPayloadAreNotSuccessfulEmptyLists() async throws {
        let wire = EventCatalogWire(bytes: openingReplies() + reply(transaction: 3, code: 0x2019)
            + reply(transaction: 4, payload: Data([1, 2])) + reply(transaction: 5, payload: Data([0, 0, 0, 0])))
        let camera = CameraWiFiConnection(command: CameraTCPStream(connection: wire),
            event: CameraTCPStream(connection: EventCatalogWire(bytes: Data([8, 0, 0, 0, 4, 0, 0, 0]))))
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        do { _ = try await camera.catalogObjectHandles(storageID: 0x10001, permitted: { true }); XCTFail("Busy must fail") }
        catch { guard case CameraOperationError.rejected = error else { return XCTFail("\(error)") } }
        do { _ = try await camera.catalogObjectHandles(storageID: 0x10001, permitted: { true }); XCTFail("Truncated must fail") }
        catch { guard case CameraOperationError.malformedDataset = error else { return XCTFail("\(error)") } }
        let empty = try await camera.catalogObjectHandles(storageID: 0x10001, permitted: { true })
        XCTAssertTrue(empty.isEmpty)
        let state = await camera.snapshot()
        XCTAssertEqual(state.phase, .ready)
        await camera.abort()
    }

    private func openingReplies() -> Data {
        Data([12, 0, 0, 0, 2, 0, 0, 0, 0x44, 0x33, 0x22, 0x11])
            + reply(transaction: 1) + reply(transaction: 2, code: 0x2005)
    }
    private func reply(transaction: UInt32, code: UInt16 = 0x2001, payload: Data? = nil) -> Data {
        func u32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        var bytes = Data()
        if let payload { bytes = u32(UInt32(12 + payload.count)) + u32(12) + u32(transaction) + payload }
        return bytes + u32(14) + u32(7) + Data([UInt8(truncatingIfNeeded: code), UInt8(code >> 8)]) + u32(transaction)
    }

    private func event(_ catalog: CameraCatalog, _ source: EventCatalogSource, code: Int32, handle: Int32, revision: UInt64) async {
        await source.setRevision(revision)
        await catalog.receiveEvents(CameraEventBatch(cursor: CameraEventCursor(connectionID: source.connectionID, revision: revision),
            events: [CameraEventRecord(revision: revision, code: code, transactionID: 0, firstParameter: Int64(handle))], requiresRescan: false))
    }
    private func until(_ predicate: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !(await predicate()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Catalog event condition timed out"); throw CameraStreamError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func info(_ handle: Int32, name: String = "SAME.JPG", storage: Int32 = 0x10001) throws -> PtpObjectInfo {
        var payload = Data(repeating: 0, count: 52)
        for index in 0..<4 { payload[index] = UInt8(truncatingIfNeeded: storage >> (index * 8)) }
        payload[4] = 1; payload[5] = 0x38; payload[8] = 10
        for value in [name, "20260908T120000", ""] {
            payload.append(UInt8(value.utf16.count + 1))
            for unit in value.utf16 { payload.append(UInt8(truncatingIfNeeded: unit)); payload.append(UInt8(unit >> 8)) }
            payload.append(contentsOf: [0, 0])
        }
        return try XCTUnwrap(PtpIPChannel.objectInfo(handle: handle, payload: payload))
    }
}

// XCTest's ordinary autoclosures cannot contain await. This eager helper keeps actor reads outside.
private func unwrapCatalogValue<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

private actor EventCatalogSink {
    private(set) var changes: [CameraCatalogSnapshot] = []
    private(set) var additions: [CameraCatalogAddition] = []
    func change(_ value: CameraCatalogSnapshot) { changes.append(value) }
    func addition(_ value: CameraCatalogAddition) { additions.append(value) }
}

private actor EventCatalogSource: CameraCatalogSource {
    nonisolated let connectionID = UUID()
    private var infos: [Int32: PtpObjectInfo] = [:]
    private var stores: [Int32: [Int32]] = [:]
    private var revision: UInt64 = 0
    private var failedStorage: Int32?
    private var failedInfo: Int32?
    private var holdHandles = false
    private var holdInfo = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var metadataReads: [Int32] = []
    private(set) var handleReads: [Int32] = []
    private(set) var rejections = 0
    var isHeld: Bool { continuation != nil }
    init(infos: [PtpObjectInfo]) {
        for info in infos { self.infos[info.handle] = info; stores[info.storageId, default: []].append(info.handle) }
    }
    func setRevision(_ value: UInt64) { revision = value }
    func replace(storage: Int32, handles: [Int32]) { stores[storage] = handles }
    func update(_ value: PtpObjectInfo) { infos[value.handle] = value }
    func failStorage(_ storage: Int32?) { failedStorage = storage }
    func failInfo(_ handle: Int32?) { failedInfo = handle }
    func holdNextHandles() { holdHandles = true }
    func holdNextInfo() { holdInfo = true }
    func release() { let held = continuation; continuation = nil; held?.resume() }
    func storageIDs() async throws -> [Int32] { stores.keys.sorted() }
    func objectHandles(storageID: Int32) async throws -> [Int32] {
        handleReads.append(storageID)
        if storageID == failedStorage { rejections += 1; throw CameraOperationError.rejected(operation: 0x1007, response: 0x2019) }
        let captured = stores[storageID] ?? []
        if holdHandles { holdHandles = false; await withCheckedContinuation { continuation = $0 } }
        return captured
    }
    func objectInfo(handle: Int32) async throws -> PtpObjectInfo {
        metadataReads.append(handle)
        if handle == failedInfo { rejections += 1; throw CameraOperationError.rejected(operation: 0x1008, response: 0x2019) }
        let captured = infos[handle]
        if holdInfo { holdInfo = false; await withCheckedContinuation { continuation = $0 } }
        guard let captured else { throw CameraOperationError.malformedDataset(operation: 0x1008) }
        return captured
    }
    func snapshot() async -> CameraConnectionSnapshot {
        CameraConnectionSnapshot(connectionID: connectionID, phase: .ready, eventRevision: revision, errorDescription: nil)
    }
}

private actor EventPreviewSource: CameraPreviewSource {
    func thumbnail(handle: Int32) async throws -> Data? { Data([1, 2, 3]) }
    func fhdPicture(handle: Int32, retryDeviceBusy: Bool) async throws -> Data? { Data([4, 5, 6]) }
}

private actor EventCatalogAdmission {
    private var allowed = true
    private(set) var checks = 0
    func deny() { allowed = false }
    func check() -> Bool { checks += 1; return allowed }
}

/// Byte transport only: the test above uses the production connection and command-session FIFO.
private final class EventCatalogWire: CameraByteConnection {
    private let lock = NSLock()
    private var bytes: Data
    private var output: [Data] = []
    private var pending: (maximum: Int, callback: (Data?, Bool, Error?) -> Void)?
    init(bytes: Data) { self.bytes = bytes }
    var sentCount: Int { lock.lock(); defer { lock.unlock() }; return output.count }
    var lastSent: Data? { lock.lock(); defer { lock.unlock() }; return output.last }
    func start(on queue: DispatchQueue, state: @escaping (CameraConnectionEvent) -> Void) { state(.ready) }
    func receive(maximumLength: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
        lock.lock()
        let count = min(bytes.count, maximumLength)
        let value = Data(bytes.prefix(count)); bytes.removeFirst(count)
        if count == 0 { pending = (maximumLength, completion) }
        lock.unlock()
        if count > 0 { completion(value, false, nil) }
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        lock.lock(); output.append(data); lock.unlock(); completion(nil)
    }
    func feed(_ data: Data) {
        lock.lock(); bytes.append(data)
        let waiting = pending; pending = nil
        let count = min(bytes.count, waiting?.maximum ?? 0)
        let value = Data(bytes.prefix(count)); bytes.removeFirst(count)
        lock.unlock()
        waiting?.callback(value, false, nil)
    }
    func cancel() { lock.lock(); pending = nil; lock.unlock() }
}
