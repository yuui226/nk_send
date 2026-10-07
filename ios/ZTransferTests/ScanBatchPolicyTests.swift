import XCTest
@testable import ZTransfer

final class ScanBatchPolicyTests: XCTestCase {
    func testAndroidWarmupGrowthColdAndInterruptedRules() {
        XCTAssertEqual(fileScanBatchSize(processed: 0, requested: 12, fastFirstBatch: true), 1)
        XCTAssertEqual(fileScanBatchSize(processed: 1, requested: 12, fastFirstBatch: true), 3)
        XCTAssertEqual(fileScanBatchSize(processed: 2, requested: 12, fastFirstBatch: true), 2)
        XCTAssertEqual(fileScanBatchSize(processed: 4, requested: 12, fastFirstBatch: true), 12)
        XCTAssertEqual(fileScanBatchSize(processed: 16, requested: 24, fastFirstBatch: true), 24)
        XCTAssertEqual(fileScanBatchSize(processed: 40, requested: 48, fastFirstBatch: true), 48)
        XCTAssertEqual(fileScanBatchSize(processed: 0, requested: 20, fastFirstBatch: false), 20)
        XCTAssertEqual(fileScanBatchSize(processed: 1, requested: 1, fastFirstBatch: true), 1)
        var policy = CachedThumbnailBatchPolicy()
        for count in [1, 3, 0, 11] {
            policy.complete(count: count, allCached: true)
            XCTAssertEqual(policy.size, 12)
        }
        policy.complete(count: 12, allCached: true)
        XCTAssertEqual(policy.size, 24)
        policy.complete(count: 24, allCached: true)
        XCTAssertEqual(policy.size, 48)
        for _ in 0..<10 { policy.complete(count: 48, allCached: true) }
        XCTAssertEqual(policy.size, 48)
        policy.complete(count: 48, allCached: false)
        XCTAssertEqual(policy.size, 12)
        policy.complete(count: 12, allCached: true)
        policy.complete(count: 0, allCached: false)
        XCTAssertEqual(policy.size, 12)
    }

    @MainActor
    func testProductionScanConsumesListCacheFeedback() async throws {
        for warm in [true, false] {
            let handles = Array(UInt32(1)...88)
            var script: [STAExchange] = [
                .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1])),
                .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array(handles))
            ]
            script += handles.reversed().map {
                .init(PTPConstants.getObjectInfo, [$0], payload: objectInfo($0))
            }
            let wire = STAScriptTransport(script)
            let repository = CameraRepository(session: PTPSession(transport: wire))
            let batches = STARecorder<Int>()
            let model = PhotoListViewModel(scanCatalog: { preserve, snapshot, detect, next, onBatch in
                try await repository.scanCatalog(preserveExisting: preserve, resumeSnapshot: snapshot,
                    detectNewHandles: detect, nextBatchSize: next) { files in
                        await batches.append(files.count)
                        try await onBatch(files)
                    }
            }, prefetchBatch: { files in
                let ids = Set(files.map(\.id))
                return ThumbnailBatchResult(settled: ids, cached: warm ? ids : [])
            }, canFill: { true }, setRemoteGate: { _ in })
            await model.reload()
            XCTAssertTrue(model.hasCompletedFileScan)
            XCTAssertEqual(model.availableFiles.count, 88)
            let sizes = await batches.values
            XCTAssertEqual(sizes, warm ? [1, 3, 12, 24, 48] : [1, 3, 12, 12, 12, 12, 12, 12, 12])
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    @MainActor
    func testDualCardProductionScanPreservesOrderAndWarmGrowth() async throws {
        let handles = Array(UInt32(1)...88)
        var script: [STAExchange] = [
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1, 0x10001])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array(handles.filter { $0 % 2 == 0 })),
            .init(PTPConstants.getObjectHandles, [0x10001, .max, 0], payload: staU32Array(handles.filter { $0 % 2 == 1 }))
        ]
        // Independent oracle: two cards alternate timestamps. The first
        // request reads both heads; every subsequent request consumes only
        // the card with the newer head, producing this exact wire sequence.
        script += handles.reversed().map { id in
            .init(PTPConstants.getObjectInfo, [id], payload: objectInfo(id,
                storage: id % 2 == 0 ? 1 : 0x10001, date: String(format: "20261001T12%02d%02d", id / 60, id % 60)))
        }
        let wire = STAScriptTransport(script)
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let batches = STARecorder<[UInt32]>()
        let model = PhotoListViewModel(scanCatalog: { preserve, snapshot, detect, next, onBatch in
            try await repository.scanCatalog(preserveExisting: preserve, resumeSnapshot: snapshot,
                detectNewHandles: detect, nextBatchSize: next) { files in
                    await batches.append(files.map(\.id))
                    try await onBatch(files)
                }
        }, prefetchBatch: { files in
            let ids = Set(files.map(\.id))
            return ThumbnailBatchResult(settled: ids, cached: ids)
        }, canFill: { true }, setRemoteGate: { _ in })
        await model.reload()
        XCTAssertTrue(model.hasCompletedFileScan)
        let published = await batches.values
        XCTAssertEqual(published.map(\.count), [1, 3, 12, 24, 48])
        XCTAssertEqual(published.flatMap { $0 }, Array(handles.reversed()))
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testIncompleteObjectInfoFreezesAdaptiveSizeWithoutDroppingDisplayRow() async throws {
        let handles = Array(UInt32(1)...40)
        var script: [STAExchange] = [
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array(handles))
        ]
        script += handles.reversed().map { id in
            let bytes = objectInfo(id)
            return .init(PTPConstants.getObjectInfo, [id], payload: id == 40 ? Data(bytes.dropLast()) : bytes)
        }
        let repository = CameraRepository(session: PTPSession(transport: STAScriptTransport(script)))
        let batches = STARecorder<Int>()
        let result = try await repository.scanCatalog(nextBatchSize: { 48 }) { await batches.append($0.count) }
        XCTAssertFalse(result.metadataComplete)
        XCTAssertEqual(result.files.count, 40)
        let sizes = await batches.values
        XCTAssertEqual(sizes, [1, 3, 12, 12, 12])
    }

    func testBackupDuplicateInSameBatchPublishesBothStorageMemberships() async throws {
        var script: [STAExchange] = [
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1, 0x10001])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([2, 4, 6])),
            .init(PTPConstants.getObjectHandles, [0x10001, .max, 0], payload: staU32Array([1, 3, 5]))
        ]
        // Equal timestamp/name/size pairs are logical backup duplicates.
        // Equal timestamps keep the earlier storage group, as on Android.
        for id: UInt32 in [6, 5, 4, 3, 2, 1] {
            let pair = (id + 1) / 2
            script.append(.init(PTPConstants.getObjectInfo, [id], payload: objectInfo(id,
                storage: id % 2 == 0 ? 1 : 0x10001,
                date: "20261001T12000\(pair)", name: "\(pair).JPG")))
        }
        let wire = STAScriptTransport(script)
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let batches = STARecorder<[CameraFile]>()
        let result = try await repository.scanCatalog(onBatch: { await batches.append($0) })
        XCTAssertEqual(result.files.map(\.id), [6, 4, 2])
        XCTAssertTrue(result.files.allSatisfy { $0.storageIDs == [1, 0x10001] })
        let published = await batches.values
        XCTAssertEqual(published.map { $0.map(\.id) }, [[6], [4], [2]])
        XCTAssertEqual(published[1][0].storageIDs, [1, 0x10001])
        XCTAssertEqual(published[2][0].storageIDs, [1, 0x10001])
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testCancelledDualCardBatchResumesOnlyAcceptedHandles() async throws {
        var script: [STAExchange] = [
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1, 0x10001])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([2, 4, 6])),
            .init(PTPConstants.getObjectHandles, [0x10001, .max, 0], payload: staU32Array([1, 3, 5]))
        ]
        // Second publication is cancelled: its heads were read but have not
        // been accepted, so they must be requested again on resume.
        for id: UInt32 in [6, 5, 4, 3, 2, 4, 5, 3, 2, 1] {
            script.append(.init(PTPConstants.getObjectInfo, [id], payload: objectInfo(id,
                storage: id % 2 == 0 ? 1 : 0x10001, date: "20261001T12000\(id)")))
        }
        let wire = STAScriptTransport(script)
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let batches = STARecorder<Int>()
        do {
            _ = try await repository.scanCatalog(onBatch: { files in
                await batches.append(files.count)
                if await batches.values.count == 2 { throw CancellationError() }
            })
            XCTFail("Second callback must cancel the scan")
        } catch is CancellationError { }
        let snapshotValue = await repository.scanSnapshotForResume()
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.processedHandles, [6])
        let resumed = try await repository.scanCatalog(preserveExisting: true, resumeSnapshot: snapshot)
        XCTAssertEqual(resumed.files.map(\.id), [6, 5, 4, 3, 2, 1])
        XCTAssertTrue(resumed.metadataComplete)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testDiskHitIsDifferentFromDownloadAndNegativeCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                              fileName: "1.JPG", captureDate: "20261001T120000", isProtected: false)
        let downloaded = try await store.prefetchOutcome(file: file, identity: "camera") { Data([1]) }
        XCTAssertEqual(downloaded, .settled)
        let hit = try await store.prefetchOutcome(file: file, identity: "camera") {
            XCTFail("Warm entry must not fetch")
            return Data()
        }
        XCTAssertEqual(hit, .cached)
        let negative = try await store.prefetchOutcome(file: file, identity: "empty-camera") { Data() }
        XCTAssertEqual(negative, .settled)
        let repeated = try await store.prefetchOutcome(file: file, identity: "empty-camera") {
            XCTFail("Authoritative empty result is settled but cannot accelerate")
            return Data()
        }
        XCTAssertEqual(repeated, .settled)
    }

    private func objectInfo(_ handle: UInt32, storage: UInt32 = 1, date: String = "20261001T120000", name: String? = nil) -> Data {
        var bytes = Data(repeating: 0, count: 52)
        bytes.replaceSubrange(0..<4, with: staInteger(storage))
        bytes.replaceSubrange(4..<6, with: staInteger(UInt16(0x3801)))
        bytes.replaceSubrange(8..<12, with: staInteger(UInt32(100)))
        bytes.append(staString(name ?? "\(handle).JPG"))
        bytes.append(staString(date))
        return bytes
    }
}
