import XCTest
@testable import ZTransfer

final class ScanBatchPolicyTests: XCTestCase {
    func testUSBScanYieldsWithinBatchToPhotoAndResumesWithoutSkippingHandles() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        let entered = GateTestLatch(), release = GateTestLatch()
        let size = transferChunkSize + 1
        var script: [STAExchange] = [
            .init(PTPConstants.getStorageIDs, payload: staU32Array([1])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array(Array(1...8))),
            .init(PTPConstants.getObjectInfo, [8], payload: objectInfo(8)),
            .init(PTPConstants.getObjectInfo, [7], payload: objectInfo(7)),
            .init(PTPConstants.getPartialObjectEx, [8, 0, 0, UInt32(transferChunkSize), 0],
                  payload: Data(repeating: 9, count: Int(transferChunkSize))),
            .init(PTPConstants.getPartialObjectEx, [8, UInt32(transferChunkSize), 0, 1, 0], payload: Data([9])),
        ]
        script += (1...6).reversed().map { .init(PTPConstants.getObjectInfo, [UInt32($0)], payload: objectInfo(UInt32($0))) }
        let wire = STAScriptTransport(script)
        let repository = CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
        let scan = Task {
            try await repository.scanCatalog(nextBatchSize: { 48 }) { batch in
                if batch.map(\.id) == [8] {
                    await wire.beforeNextReply(PTPConstants.getObjectInfo) {
                        await entered.signal()
                        await release.wait()
                    }
                }
            }
        }
        await entered.wait()
        let photo = Task {
            try await repository.downloadResult(handle: 8, size: size, fileName: "8.JPG", to: target)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await repository.cameraSchedulerSnapshot().queued == 0, ContinuousClock.now < deadline { await Task.yield() }
        let queued = await repository.cameraSchedulerSnapshot().queued
        XCTAssertEqual(queued, 1)
        await release.signal()
        let result = try await photo.value
        let catalog = try await scan.value
        XCTAssertEqual(result.bytes, size)
        XCTAssertEqual(catalog.files.map(\.id), Array(UInt32(1)...8).reversed())
        XCTAssertTrue(catalog.metadataComplete)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    @MainActor
    func testTypeSelectionNormalizesOnlyAfterScanAndPersistsWholeSelection() async throws {
        let original = PhotoFilterPersistence.load()
        defer { PhotoFilterPersistence.save(original) }
        let jpg = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10,
            fileName: "photo.JPG", captureDate: "20261016T120000", isProtected: false)
        for selection: Set<String> in [[".nef"], [".nef", ".jpg"], []] {
            for emptyCatalog in [false, true] {
                let files = emptyCatalog ? [] : [jpg]
                let gate = ScanThumbnailAdmissionGate()
                let model = PhotoListViewModel(scanCatalog: { _, _, _, _, onBatch in
                    try await onBatch(files)
                    _ = await gate.wait()
                    return PhotoScanResult(files: files, removedHandles: [], addedHandles: [],
                        handleQueriesSucceeded: true, metadataComplete: true)
                }, setRemoteGate: { _ in })
                defer { model.cancelLoading() }
                model.setFilter(PhotoFilterState(extensions: selection))
                model.load()
                for _ in 0..<200 {
                    if await gate.isWaiting { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let waiting = await gate.isWaiting
                XCTAssertTrue(waiting)
                XCTAssertTrue(model.isLoadingFiles)
                XCTAssertFalse(model.hasCompletedFileScan)
                XCTAssertEqual(model.filter.extensions, selection.isEmpty ? nil : selection)
                await gate.release()
                for _ in 0..<200 where model.isLoadingFiles {
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertFalse(model.isLoadingFiles)
                XCTAssertTrue(model.hasCompletedFileScan)
                let expected = !emptyCatalog && selection.contains(".jpg") ? selection : nil
                XCTAssertEqual(model.filter.extensions, expected)
                XCTAssertEqual(PhotoFilterPersistence.load().extensions, expected)
                XCTAssertEqual(model.sections.flatMap(\.files), files)
                // A later filter edit is subject to the same completed catalog.
                model.setFilter(PhotoFilterState(extensions: [".mov"]))
                XCTAssertNil(model.filter.extensions)
                XCTAssertNil(PhotoFilterPersistence.load().extensions)
            }
        }
    }

    func testOrdinaryThumbnailProtocolMissSettlesButTransientErrorsRemainRetryable() async throws {
        for code in [PTPConstants.noThumbnailPresent, PTPConstants.invalidObjectHandle, PTPConstants.deviceBusy, PTPConstants.responseOK] {
            let transportFailure = code == PTPConstants.responseOK
            let wire = STAScriptTransport([
                .init(PTPConstants.getThumb, [1], response: code),
                .init(PTPConstants.getThumb, [1], payload: Data([1, 2, 3]))
            ])
            if transportFailure {
                await wire.beforeNextReply(PTPConstants.getThumb) { throw URLError(.networkConnectionLost) }
            }
            let repository = CameraRepository(session: PTPSession(transport: wire))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
            let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                fileName: "photo.JPG", captureDate: "20261001T120000", isProtected: false)
            do {
                let result = try await store.prefetchOutcome(file: file, identity: "camera",
                    validate: { !$0.isEmpty }) {
                    try await repository.thumbnail(handle: 1, priority: .backgroundThumbnail)
                }
                XCTAssertNotEqual(code, PTPConstants.deviceBusy)
                XCTAssertFalse(transportFailure)
                XCTAssertEqual(result, .settled)
            } catch PTPSessionError.responseCode(let response) {
                XCTAssertEqual(response, PTPConstants.deviceBusy)
                XCTAssertEqual(code, PTPConstants.deviceBusy)
            } catch let error as URLError {
                XCTAssertTrue(transportFailure)
                XCTAssertEqual(error.code, .networkConnectionLost)
            }
            // A lost connection invalidates its PTP session. Keep the same cache
            // while replacing the failed session, as a reconnect must do.
            let retryRepository = transportFailure
                ? CameraRepository(session: PTPSession(transport: wire)) : repository
            let retry = try await store.prefetchOutcome(file: file, identity: "camera",
                validate: { !$0.isEmpty }) {
                try await retryRepository.thumbnail(handle: 1, priority: .backgroundThumbnail)
            }
            XCTAssertEqual(retry, .settled)
            let commands = await wire.commands.count
            XCTAssertEqual(commands, code == PTPConstants.deviceBusy || transportFailure ? 2 : 1)
            let blocked = await store.diskWritesBlocked
            XCTAssertFalse(blocked)
        }
    }

    @MainActor
    func testRealSecondCacheWriteFailureStopsWorkerAndPreservesCachedReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = PhotoThumbnailDiskCache(root: root)
        let cameraDirectory = disk.openCamera(identity: "camera").target("probe").deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cameraDirectory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = PhotoThumbnailStore(disk: disk)
        let files: [CameraFile] = [1, 2, 3].map { id in
            CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 100,
                fileName: "\(id).JPG", captureDate: "20261001T120000", isProtected: false)
        }
        let requests = STARecorder<UInt32>()
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
            PhotoScanResult(files: files, removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
        }, prefetchBatch: { batch in
            var result = ThumbnailBatchResult()
            for file in batch {
                let outcome = try? await store.prefetchOutcome(file: file, identity: "camera") {
                    await requests.append(file.id)
                    if file.id == 2 {
                        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cameraDirectory.path)
                    }
                    return Data([1, 2, 3])
                }
                if outcome?.isSettled == true { result.settled.insert(file.id) }
                result.diskWritesBlocked = await store.diskWritesBlocked
            }
            return result
        }, canFill: { true }, setRemoteGate: { _ in }, sequentialLoading: true)
        defer { model.cancelLoading() }
        model.load()
        for _ in 0..<200 where !model.thumbnailFillDiskBlocked {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.thumbnailFillDiskBlocked)
        let fetched = await requests.values
        XCTAssertEqual(fetched, [1, 2])
        let stoppedQueue = await model.thumbnailFillQueue.state()
        XCTAssertEqual(stoppedQueue.pending, [2, 3])
        XCTAssertEqual(stoppedQueue.settled, [1])
        XCTAssertTrue(stoppedQueue.failed.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cameraDirectory.path)
        let cached = try await store.prefetchOutcome(file: files[0], identity: "camera") {
            XCTFail("The first cached photo remains readable while writes are blocked")
            return Data()
        }
        XCTAssertEqual(cached, .cached)
        model.wakeThumbnailFill()
        await model.reload()
        let afterWake = await requests.values
        XCTAssertEqual(afterWake, [1, 2])
    }

    @MainActor
    func testDiskFailureStopsScanAndBackgroundPrefetchForTheConnection() async throws {
        for duringScan in [true, false] {
            let files: [CameraFile] = [1, 2, 3].map { id in
                CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 100,
                    fileName: "\(id).JPG", captureDate: "20261001T120000", isProtected: false)
            }
            let requested = STARecorder<UInt32>()
            let model = PhotoListViewModel(scanCatalog: { _, _, _, _, onBatch in
                if duringScan { try await onBatch(files) }
                return PhotoScanResult(files: files, removedHandles: [], addedHandles: [],
                    handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
            }, prefetchBatch: { batch in
                for file in batch { await requested.append(file.id) }
                if batch.contains(where: { $0.id == 2 }) {
                    return ThumbnailBatchResult(diskWritesBlocked: true)
                }
                return ThumbnailBatchResult(settled: Set(batch.map(\.id)))
            }, canFill: { true }, setRemoteGate: { _ in }, sequentialLoading: true)
            defer { model.cancelLoading() }
            model.load()
            for _ in 0..<200 where !model.thumbnailFillDiskBlocked {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(model.thumbnailFillDiskBlocked)
            XCTAssertEqual(model.availableFiles.count, 3)
            let before = await requested.values
            XCTAssertEqual(before, [1, 2])
            // An ordinary rescan keeps this connection's stop latch.
            await model.reload()
            model.wakeThumbnailFill()
            let after = await requested.values
            XCTAssertEqual(after, [1, 2])
        }
    }

    @MainActor
    func testDeletedInflightThumbnailCannotSettleReusedHandle() async throws {
        let old = CameraFile(id: 7, storageID: 1, format: 0x3801, size: 100,
            fileName: "old.JPG", captureDate: "20261001T120000", isProtected: false)
        let new = CameraFile(id: 7, storageID: 1, format: 0x3801, size: 200,
            fileName: "new.JPG", captureDate: "20261002T120000", isProtected: false)
        let gate = ScanThumbnailAdmissionGate()
        let fetched = STARecorder<String>()
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
            PhotoScanResult(files: [old], removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
        }, prefetchBatch: { files in
            for file in files {
                await fetched.append(file.fileName)
                if file.fileName == "old.JPG" { _ = await gate.wait() }
            }
            return ThumbnailBatchResult(settled: Set(files.map(\.id)))
        }, canFill: { true }, setRemoteGate: { _ in }, sequentialLoading: true)
        defer { model.cancelLoading() }
        model.load()
        for _ in 0..<200 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting)
        await model.applyCatalogUpdate([])
        await model.applyCatalogUpdate([new])
        await gate.release()
        for _ in 0..<200 {
            if await fetched.values.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await fetched.values
        XCTAssertEqual(requests, ["old.JPG", "new.JPG"])
    }

    @MainActor
    func testDeletedSettledHandleCanFetchNewPhotoReusingThatHandle() async throws {
        let old = CameraFile(id: 7, storageID: 1, format: 0x3801, size: 100,
            fileName: "old.JPG", captureDate: "20261001T120000", isProtected: false)
        let new = CameraFile(id: 7, storageID: 1, format: 0x3801, size: 200,
            fileName: "new.JPG", captureDate: "20261002T120000", isProtected: false)
        let fetched = STARecorder<String>()
        let invalidated = STARecorder<UInt32>()
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, onBatch in
            try await onBatch([old])
            return PhotoScanResult(files: [old], removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
        }, prefetchBatch: { files in
            for file in files { await fetched.append(file.fileName) }
            let ids = Set(files.map(\.id))
            return ThumbnailBatchResult(settled: ids, cached: ids)
        }, canFill: { true }, invalidateThumbnailState: { files in
            for file in files { await invalidated.append(file.id) }
        }, setRemoteGate: { _ in }, sequentialLoading: true)
        defer { model.cancelLoading() }
        model.load()
        for _ in 0..<200 where model.isLoadingFiles { try await Task.sleep(for: .milliseconds(5)) }
        // The stream can coalesce deletion and creation into one snapshot.
        await model.applyCatalogUpdate([new])
        for _ in 0..<200 {
            if await fetched.values.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await fetched.values
        XCTAssertEqual(requests, ["old.JPG", "new.JPG"])
        let removed = await invalidated.values
        XCTAssertEqual(removed, [7])
    }

    @MainActor
    func testRecoveredRepositoryAndListReconcileDeletedPrimaryAndNewPhoto() async throws {
        let guid = String(repeating: "1", count: 32)
        let album = STAAlbumAccess(storageIDs: [1, 0x10001], prefetchedHandles: nil,
            directObjectRead: false, deviceInfo: nil)
        let oldWire = STAScriptTransport([
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([2])),
            .init(PTPConstants.getObjectHandles, [0x10001, .max, 0], payload: staU32Array([1])),
            .init(PTPConstants.getObjectInfo, [2], payload: objectInfo(2, storage: 1, date: "20261001T120000", name: "old.JPG")),
            .init(PTPConstants.getObjectInfo, [1], payload: objectInfo(1, storage: 0x10001, date: "20261001T120000", name: "old.JPG"))
        ])
        let oldRepository = CameraRepository(session: PTPSession(transport: oldWire), staAlbum: album,
            transportCameraIdentifier: guid)
        let oldResult = try await oldRepository.scanCatalog()
        let old = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in oldResult },
            setRemoteGate: { _ in }, sequentialLoading: true)
        old.load()
        for _ in 0..<200 where old.isLoadingFiles { try await Task.sleep(for: .milliseconds(10)) }
        let snapshot = await oldRepository.staCatalogRecovery()
        let newWire = STAScriptTransport([
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1, 0x10001])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([3])),
            .init(PTPConstants.getObjectHandles, [0x10001, .max, 0], payload: staU32Array([1])),
            .init(PTPConstants.getObjectInfo, [3], payload: objectInfo(3, storage: 1, date: "20261001T130000", name: "new.JPG"))
        ])
        let repository = CameraRepository(session: PTPSession(transport: newWire), staAlbum: album,
            transportCameraIdentifier: guid)
        let restored = await repository.restoreSTACatalog(try XCTUnwrap(snapshot))
        XCTAssertTrue(restored)
        let replacement = PhotoListViewModel(scanCatalog: { preserve, cursor, detect, next, batch in
            try await repository.scanCatalog(preserveExisting: preserve, resumeSnapshot: cursor,
                detectNewHandles: detect, nextBatchSize: next, onBatch: batch)
        }, prefetchBatch: { files in
            let ids = Set(files.map(\.id))
            return ThumbnailBatchResult(settled: ids, cached: ids)
        }, canFill: { true }, setRemoteGate: { _ in }, sequentialLoading: true)
        var automatic: [UInt32] = []
        replacement.setNewMediaHandler { automatic += $0.map(\.id) }
        replacement.inheritCatalog(from: old)
        replacement.load()
        XCTAssertEqual(replacement.availableFiles.map(\.id), [2])
        for _ in 0..<200 where replacement.isLoadingFiles { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(replacement.hasCompletedFileScan)
        XCTAssertEqual(Set(replacement.availableFiles.map(\.id)), [3, 1])
        XCTAssertEqual(replacement.availableFiles.first(where: { $0.id == 1 })?.storageIDs, [0x10001])
        XCTAssertEqual(automatic, [3])
        for wire in [oldWire, newWire] { let remaining = await wire.remaining; XCTAssertEqual(remaining, 0) }
    }

    @MainActor
    func testRecoveredListTransportFailureRetainsCatalogWithoutAuthoritativeReconcile() async throws {
        let file = CameraFile(id: 7, storageID: 1, format: 0x3801, size: 100,
            fileName: "7.JPG", captureDate: "20261001T120000", isProtected: false)
        let old = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
            PhotoScanResult(files: [file], removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
        }, setRemoteGate: { _ in }, sequentialLoading: true)
        old.load()
        for _ in 0..<200 where old.isLoadingFiles { try await Task.sleep(for: .milliseconds(10)) }
        var losses = 0
        let replacement = PhotoListViewModel(scanCatalog: { preserve, _, detect, _, _ in
            XCTAssertTrue(preserve && detect)
            throw CameraRepositoryError.transportLost
        }, reconcileCache: { _, _ in XCTFail("Failure is not authoritative") },
            setRemoteGate: { _ in }, sequentialLoading: true, onTransportLost: { losses += 1 })
        replacement.setNewMediaHandler { _ in XCTFail("No new media on failure") }
        replacement.inheritCatalog(from: old)
        replacement.load()
        for _ in 0..<200 where replacement.isLoadingFiles { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(losses, 1)
        XCTAssertEqual(replacement.availableFiles.map(\.id), [7])
        XCTAssertEqual(replacement.loadState, .loaded)
        XCTAssertFalse(replacement.hasCompletedFileScan)
        XCTAssertEqual(replacement.availableStorageSlots, old.availableStorageSlots)
    }
    @MainActor
    func testRecoveredListKeepsRowsAndDoesNotReplayOldAutomaticTransfers() async throws {
        let oldFile = CameraFile(id: 7, storageID: 1, format: 0x3801, size: 100,
            fileName: "7.JPG", captureDate: "20261001T120000", isProtected: false)
        let newFile = CameraFile(id: 8, storageID: 1, format: 0x3801, size: 100,
            fileName: "8.JPG", captureDate: "20261001T130000", isProtected: false)
        let old = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
            PhotoScanResult(files: [oldFile], removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
        }, setRemoteGate: { _ in }, sequentialLoading: true)
        old.load()
        for _ in 0..<200 where old.isLoadingFiles { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(old.availableFiles.map(\.id), [7])
        let requests = STARecorder<Bool>()
        let replacement = PhotoListViewModel(scanCatalog: { preserve, cursor, detect, _, onBatch in
            await requests.append(preserve && detect && cursor == nil)
            try await onBatch([newFile])
            return PhotoScanResult(files: [newFile, oldFile], removedHandles: [], addedHandles: [7, 8],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
        }, prefetchBatch: { files in
            let ids = Set(files.map(\.id))
            return ThumbnailBatchResult(settled: ids, cached: ids)
        }, canFill: { true }, setRemoteGate: { _ in }, sequentialLoading: true)
        var automatic: [UInt32] = []
        replacement.setNewMediaHandler { automatic += $0.map(\.id) }
        replacement.inheritCatalog(from: old)
        XCTAssertEqual(replacement.availableFiles.map(\.id), [7])
        XCTAssertEqual(replacement.availableStorageSlots, old.availableStorageSlots)
        XCTAssertFalse(replacement.hasCompletedFileScan)
        replacement.load()
        XCTAssertEqual(replacement.availableFiles.map(\.id), [7])
        for _ in 0..<200 where replacement.isLoadingFiles { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(replacement.hasCompletedFileScan)
        XCTAssertEqual(replacement.availableFiles.map(\.id), [8, 7])
        XCTAssertEqual(automatic, [8])
        let flags = await requests.values
        XCTAssertEqual(flags, [true])
    }
    @MainActor
    func testConnectionRecoveryIsInstalledBeforePublishingReplacement() async throws {
        let preferences = UserDefaults(suiteName: "sta_connection")!
        let keys = ["wireless_mode", CameraPresentationMode.preferenceKey]
        let previous = keys.map { preferences.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { preferences.set(value, forKey: key) }
                else { preferences.removeObject(forKey: key) }
            }
        }
        for reset in [false, true] {
            let guid = String(repeating: "1", count: 32)
            let album = STAAlbumAccess(storageIDs: [1], prefetchedHandles: nil,
                directObjectRead: false, deviceInfo: nil)
            let oldWire = STAScriptTransport([
                .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([7])),
                .init(PTPConstants.getObjectInfo, [7], payload: objectInfo(7))
            ])
            let old = CameraRepository(session: PTPSession(transport: oldWire), staAlbum: album,
                transportCameraIdentifier: guid)
            let next = CameraRepository(session: PTPSession(transport: STAScriptTransport([])),
                staAlbum: album, transportCameraIdentifier: guid)
            let service = STACatalogReplayService([old, next])
            let model = ConnectionViewModel(wifiService: service)
            model.select(wirelessMode: .sta)
            await model.connectSelectedWiFi()
            let source = try XCTUnwrap(model.cameraSession)
            _ = try await old.scanCatalog()
            await model.handleTransportLost(source)
            XCTAssertNil(model.cameraSession)
            // Cancelling discovery must retain recovery for a later same-body retry.
            model.cancelWiFiConnection()
            if reset { await model.resetSTAPairing() }
            await model.connectSelectedWiFi(reconnect: true)
            let replacement = try XCTUnwrap(model.cameraSession)
            XCTAssertFalse(source === replacement)
            XCTAssertEqual(replacement.recoveredFromSessionID, reset ? nil : ObjectIdentifier(source))
            let transferred = await next.staCatalogRecovery()
            XCTAssertEqual(transferred != nil, !reset)
            await model.handleTransportLost(source) // Late old failure cannot retire replacement.
            XCTAssertTrue(model.cameraSession === replacement)
        }
    }
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
    func testWideningDuringFinalBatchAutomaticallyResumesRetainedCursor() async throws {
        let key = PhotoFilterPersistence.photoLoadingRangeKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        PhotoFilterPersistence.savePhotoLoadingRange(.three)
        var script: [STAExchange] = [
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1, 2, 3, 4, 5]))
        ]
        // The first pass reads the boundary witness (2); continuation rereads
        // that unaccepted tail without another StorageIDs/Handles request.
        for id: UInt32 in [5, 4, 3, 2, 2, 1] {
            script.append(.init(PTPConstants.getObjectInfo, [id],
                                payload: objectInfo(id, date: "2026100\(id)T120000")))
        }
        let wire = STAScriptTransport(script)
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let requests = STARecorder<Bool>()
        let gate = ScanThumbnailAdmissionGate()
        let model = PhotoListViewModel(scanCatalog: { preserve, cursor, detect, nextBatch, onBatch in
            await requests.append(preserve)
            if preserve { XCTAssertEqual(cursor?.processedHandles, [5, 4, 3]) }
            return try await repository.scanCatalog(preserveExisting: preserve, resumeSnapshot: cursor,
                detectNewHandles: detect, loadingRange: .three,
                currentLoadingRange: { PhotoFilterPersistence.loadPhotoLoadingRange() },
                nextBatchSize: nextBatch, onBatch: onBatch)
        }, resumeSnapshotProvider: { await repository.scanSnapshotForResume() }, prefetchBatch: { batch in
            // Block inside the second published batch, after its range boundary
            // has already been computed by the real repository.
            if batch.contains(where: { $0.id == 4 }) { _ = await gate.wait() }
            let ids = Set(batch.map(\.id))
            return ThumbnailBatchResult(settled: ids, cached: ids)
        }, canFill: { true }, setRemoteGate: { _ in }, sequentialLoading: true)
        defer { model.cancelLoading() }
        model.load()
        for _ in 0..<200 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting)
        model.setPhotoLoadingRange(.all)
        await gate.release()
        for _ in 0..<200 where model.isLoadingFiles { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.availableFiles.map(\.id), [5, 4, 3, 2, 1])
        let scans = await requests.values
        XCTAssertEqual(scans, [false, true])
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
        let commands = await wire.commands
        XCTAssertEqual(commands.filter { $0.code == PTPConstants.getStorageIDs }.count, 1)
        XCTAssertEqual(commands.filter { $0.code == PTPConstants.getObjectHandles }.count, 1)

    }

    @MainActor
    func testShrinkingRangeWhileThumbnailAdmissionWaitsSkipsOlderFiles() async throws {
        let key = PhotoFilterPersistence.photoLoadingRangeKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        PhotoFilterPersistence.savePhotoLoadingRange(.all)
        let files: [CameraFile] = [5, 4].map { id in
            CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 100,
                       fileName: "\(id).JPG", captureDate: "2026100\(id)T120000", isProtected: false)
        }
        let gate = ScanThumbnailAdmissionGate()
        let fetched = STARecorder<UInt32>()
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, onBatch in
            try await onBatch(files)
            return PhotoScanResult(files: files, removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
        }, prefetchBatch: { batch in
            for file in batch { await fetched.append(file.id) }
            let ids = Set(batch.map(\.id))
            return ThumbnailBatchResult(settled: ids, cached: ids)
        }, canFill: { await gate.wait() }, setRemoteGate: { _ in }, sequentialLoading: true)
        defer { model.cancelLoading() }
        model.load()
        for _ in 0..<200 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting)
        model.setPhotoLoadingRange(.one)
        await gate.release()
        for _ in 0..<200 where model.isLoadingFiles { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isLoadingFiles)
        let requests = await fetched.values
        XCTAssertEqual(requests, [5], "The older row must not reach the thumbnail request closure")
    }

    func testLoadingRangeChangesApplyToTheNextScanBatch() async throws {
        for widen in [true, false] {
            let initial: PhotoLoadingRange = widen ? .three : .all
            let updated: PhotoLoadingRange = widen ? .all : .one
            var script: [STAExchange] = [
                .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1])),
                .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1, 2, 3, 4, 5]))
            ]
            for id: UInt32 in (widen ? [5, 4, 3, 2, 1] : [5, 4, 3, 2]) {
                script.append(.init(PTPConstants.getObjectInfo, [id],
                                    payload: objectInfo(id, date: "2026100\(id)T120000")))
            }
            let range = STARecorder<PhotoLoadingRange>()
            let wire = STAScriptTransport(script)
            let repository = CameraRepository(session: PTPSession(transport: wire))
            let result = try await repository.scanCatalog(loadingRange: initial,
                currentLoadingRange: { await range.values.last ?? initial }, nextBatchSize: { 48 },
                onBatch: { _ in await range.append(updated) })
            XCTAssertEqual(result.files.map(\.id), widen ? [5, 4, 3, 2, 1] : [5])
            XCTAssertEqual(result.stoppedAtLoadingRange, !widen)
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testDeletionDuringEnumerationCannotRepublishResumeSnapshot() async throws {
        for operation in [PTPConstants.getObjectHandles, PTPConstants.getObjectInfo] {
            var script: [STAExchange] = [
                .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1])),
                .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1, 2, 3, 4, 5]))
            ]
            for id: UInt32 in [5, 4, 3, 2] {
                script.append(.init(PTPConstants.getObjectInfo, [id],
                                    payload: objectInfo(id, date: "2026100\(id)T120000")))
            }
            let wire = STAScriptTransport(script)
            let repository = CameraRepository(session: PTPSession(transport: wire))
            await wire.beforeNextReply(operation) {
                await repository.receiveEvent(STAEvent(code: 0x4003, handle: 1))
            }
            let result = try await repository.scanCatalog(loadingRange: .three, nextBatchSize: { 48 })
            XCTAssertTrue(result.stoppedAtLoadingRange)
            XCTAssertEqual(result.files.map(\.id), [5, 4, 3])
            let snapshot = await repository.scanSnapshotForResume()
            XCTAssertNil(snapshot, "An older in-flight enumeration must not acquire the deletion's new revision")
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testDeletionInvalidatesBoundedScanBeforeWideningScope() async throws {
        for duringPreview in [false, true] {
            for deleted: UInt32 in [1, 5] {
                let dates: [UInt32: String] = [5: "20261005T120000", 4: "20261004T120000",
                    3: "20261003T120000", 2: "20261002T120000", 1: "20261001T120000"]
                var script: [STAExchange] = [
                    .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1])),
                    .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1, 2, 3, 4, 5]))
                ]
                for id: UInt32 in [5, 4, 3, 2] {
                    script.append(.init(PTPConstants.getObjectInfo, [id], payload: objectInfo(id, date: dates[id]!)))
                }
                let current = ([1, 2, 3, 4, 5] as [UInt32]).filter { $0 != deleted }
                script.append(.init(PTPConstants.getStorageIDs, [], payload: staU32Array([1])))
                script.append(.init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array(current)))
                for id in current.reversed() where id <= 2 {
                    script.append(.init(PTPConstants.getObjectInfo, [id], payload: objectInfo(id, date: dates[id]!)))
                }
                let wire = STAScriptTransport(script)
                let repository = CameraRepository(session: PTPSession(transport: wire))
                let bounded = try await repository.scanCatalog(loadingRange: .three, nextBatchSize: { 48 })
                XCTAssertEqual(bounded.files.map(\.id), [5, 4, 3])
                let before = await repository.scanSnapshotForResume()
                XCTAssertNotNil(before)
                let result: PhotoScanResult
                if duringPreview {
                    await repository.setFHDActive(true)
                    let commandsBefore = await wire.commands.count
                    let scan = Task {
                        try await repository.scanCatalog(preserveExisting: true, resumeSnapshot: before,
                                                         loadingRange: .all, nextBatchSize: { 48 })
                    }
                    for _ in 0..<200 {
                        if await repository.catalogLoading { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    let waiting = await repository.catalogLoading
                    XCTAssertTrue(waiting)
                    let commandsWhilePaused = await wire.commands.count
                    XCTAssertEqual(commandsWhilePaused, commandsBefore)
                    await repository.receiveEvent(STAEvent(code: 0x4003, handle: deleted))
                    let invalidated = await repository.scanSnapshotForResume()
                    XCTAssertNil(invalidated)
                    await repository.setFHDActive(false)
                    result = try await scan.value
                } else {
                    await repository.receiveEvent(STAEvent(code: 0x4003, handle: deleted))
                    let invalidated = await repository.scanSnapshotForResume()
                    XCTAssertNil(invalidated)
                    result = try await repository.scanCatalog(preserveExisting: true, resumeSnapshot: before,
                                                             loadingRange: .all, nextBatchSize: { 48 })
                }
                XCTAssertEqual(result.files.map(\.id), Array(current.reversed()))
                let remaining = await wire.remaining
                XCTAssertEqual(remaining, 0)
            }
        }
    }

    func testBoundedPhotoScanRetainsTailAndWiderScopeResumesIt() async throws {
        let handles: [UInt32] = [1, 2, 3, 4, 5]
        var script: [STAExchange] = [
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array(handles)),
        ]
        let dates: [UInt32: String] = [
            5: "20261005T120000", 4: "20261004T120000", 3: "20261003T120000",
            2: "20261002T120000", 1: "20261001T120000",
        ]
        // The Android warm-up reads one object, then a three-object batch.
        // The second batch crosses the three-day boundary after reading 2;
        // handle 1 remains unread in the retained snapshot.
        for id in [5, 4, 3, 2] as [UInt32] {
            script.append(.init(PTPConstants.getObjectInfo, [id], payload: objectInfo(id, date: dates[id]!)))
        }
        // The bounded pass leaves the first out-of-range handle in the
        // snapshot. The wider pass must request that tail again.
        for id: UInt32 in [2, 1] {
            script.append(.init(PTPConstants.getObjectInfo, [id], payload: objectInfo(id, date: dates[id]!)))
        }
        let wire = STAScriptTransport(script)
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let bounded = try await repository.scanCatalog(loadingRange: .three,
                                                        nextBatchSize: { 48 })
        XCTAssertTrue(bounded.stoppedAtLoadingRange)
        XCTAssertEqual(bounded.files.map(\.id), [5, 4, 3])
        let snapshotValue = await repository.scanSnapshotForResume()
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.remainingHandles.flatMap { $0.handles }, [2, 1])

        let resumed = try await repository.scanCatalog(preserveExisting: true,
                                                       resumeSnapshot: snapshot,
                                                       loadingRange: .all,
                                                       nextBatchSize: { 48 })
        XCTAssertFalse(resumed.stoppedAtLoadingRange)
        XCTAssertEqual(resumed.files.map(\.id), [5, 4, 3, 2, 1])
        let finalSnapshot = await repository.scanSnapshotForResume()
        XCTAssertNil(finalSnapshot)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
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

    @MainActor
    func testBoundedScanPreservesOlderMemoryAndDiskThumbnails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PhotoThumbnailDiskCache(root: root)
        let store = PhotoThumbnailStore(disk: disk)
        let old = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
            fileName: "old.JPG", captureDate: "20261001T120000", isProtected: false)
        let recent = CameraFile(id: 2, storageID: 1, format: 0x3801, size: 100,
            fileName: "new.JPG", captureDate: "20261005T120000", isProtected: false)
        for file in [old, recent] {
            _ = try await store.prefetchOutcome(file: file, identity: "range-camera") { Data([1, 2, 3]) }
        }
        let decisions = STARecorder<Bool>()
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, onBatch in
            try await onBatch([recent])
            return PhotoScanResult(files: [recent], removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1],
                stoppedAtLoadingRange: true)
        }, reconcileCache: { files, authoritative in
            await decisions.append(authoritative)
            if authoritative { await store.reconcile(files: files, identity: "range-camera", directSTA: false) }
        }, setRemoteGate: { _ in })
        defer { model.cancelLoading() }
        model.load()
        for _ in 0..<200 where model.isLoadingFiles { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isLoadingFiles)
        let pruning = await decisions.values
        XCTAssertEqual(pruning, [false])
        let memoryHit = try await store.prefetchOutcome(file: old, identity: "range-camera") {
            XCTFail("Bounded scan must preserve the older memory entry")
            return Data()
        }
        XCTAssertEqual(memoryHit, .cached)
        let freshStore = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let diskHit = try await freshStore.prefetchOutcome(file: old, identity: "range-camera") {
            XCTFail("A fresh session must retain the older disk entry")
            return Data()
        }
        XCTAssertEqual(diskHit, .cached)
    }

    func testIncompleteMetadataDoesNotDisableDeletionSyncOrNewObjectResolution() async throws {
        let incomplete = Data(objectInfo(1).dropLast())
        let wire = STAScriptTransport([
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1])),
            .init(PTPConstants.getObjectInfo, [1], payload: incomplete),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([2])),
            .init(PTPConstants.nikonCompatibilityInit, [], payload: Data()),
            .init(PTPConstants.getObjectInfo, [2], payload: objectInfo(2))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let updates = STARecorder<[UInt32]>()
        let stream = await repository.catalogUpdates()
        let observer = Task {
            for await files in stream { await updates.append(files.map(\.id)) }
        }
        let result = try await repository.scanCatalog()
        XCTAssertFalse(result.metadataComplete, "Cache reconciliation must still see incomplete metadata")
        XCTAssertTrue(result.handleQueriesSucceeded)
        XCTAssertEqual(result.files.map(\.id), [1])
        await repository.receiveEvent(STAEvent(code: 0x4003, handle: 1))
        await repository.maintainCatalogIfIdle()
        for _ in 0..<200 {
            if await updates.values.contains([2]) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await repository.stopMonitoring()
        await observer.value
        let published = await updates.values
        XCTAssertEqual(published.last, [2])
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    @MainActor
    func testBoundedIncompleteCatalogKeepsEventsAliveWithoutAuthoritativeCachePruning() async throws {
        let key = PhotoFilterPersistence.photoLoadingRangeKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        PhotoFilterPersistence.savePhotoLoadingRange(.one)
        let wire = STAScriptTransport([
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1, 2, 3])),
            .init(PTPConstants.getObjectInfo, [3], payload: objectInfo(3, date: "20261003T120000")),
            .init(PTPConstants.getObjectInfo, [2], payload: Data(objectInfo(2, date: "20261002T120000").dropLast())),
            .init(PTPConstants.getObjectInfo, [1], payload: objectInfo(1, date: "20261001T120000")),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1, 2, 4])),
            .init(PTPConstants.nikonCompatibilityInit, [], payload: Data()),
            .init(PTPConstants.getObjectInfo, [4], payload: objectInfo(4, date: "20261004T120000"))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let scans = STARecorder<PhotoScanResult>()
        let reconciliation = STARecorder<Bool>()
        let updates = STARecorder<[UInt32]>()
        let stream = await repository.catalogUpdates()
        let observer = Task {
            for await files in stream { await updates.append(files.map(\.id)) }
        }
        let model = PhotoListViewModel(scanCatalog: { preserve, cursor, detect, nextBatch, onBatch in
            let result = try await repository.scanCatalog(preserveExisting: preserve,
                resumeSnapshot: cursor, detectNewHandles: detect, loadingRange: .one,
                nextBatchSize: nextBatch, onBatch: onBatch)
            await scans.append(result)
            return result
        }, reconcileCache: { _, authoritative in await reconciliation.append(authoritative) },
           setRemoteGate: { _ in })
        defer { model.cancelLoading() }
        model.load()
        for _ in 0..<200 where model.isLoadingFiles { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isLoadingFiles)
        let results = await scans.values
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.stoppedAtLoadingRange, true)
        XCTAssertEqual(results.first?.metadataComplete, false)
        let pruning = await reconciliation.values
        XCTAssertEqual(pruning, [false])
        await repository.receiveEvent(STAEvent(code: 0x4003, handle: 3))
        await repository.maintainCatalogIfIdle()
        for _ in 0..<200 {
            if await updates.values.last?.contains(4) == true { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await repository.stopMonitoring()
        await observer.value
        let finalIDs = await updates.values.last ?? []
        XCTAssertTrue(finalIDs.contains(4))
        XCTAssertFalse(finalIDs.contains(3))
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

    @MainActor
    func testMembershipReplacementUpdatesListBeforeScanEndsWithoutRefetching() async throws {
        let primary = CameraFile(id: 6, storageID: 1, format: 0x3801, size: 100,
            fileName: "backup.JPG", captureDate: "20261001T120000", isProtected: false)
        let replacement = CameraFile(id: 6, storageID: 1, format: 0x3801, size: 100,
            fileName: "backup.JPG", captureDate: "20261001T120000", isProtected: false,
            storageIDs: [1, 0x10001])
        let gate = ScanThumbnailAdmissionGate()
        let fetched = STARecorder<UInt32>()
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, onBatch in
            try await onBatch([primary])
            try await onBatch([replacement])
            _ = await gate.wait()
            return PhotoScanResult(files: [replacement], removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1, 0x10001])
        }, prefetchBatch: { batch in
            for file in batch { await fetched.append(file.id) }
            let ids = Set(batch.map(\.id))
            return ThumbnailBatchResult(settled: ids, cached: ids)
        }, canFill: { true }, setRemoteGate: { _ in }, sequentialLoading: true)
        defer { model.cancelLoading() }
        model.load()
        for _ in 0..<200 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting)
        XCTAssertTrue(model.isLoadingFiles)
        XCTAssertEqual(model.availableFiles.count, 1)
        XCTAssertEqual(model.availableFiles.first?.storageIDs, [1, 0x10001])
        let requests = await fetched.values
        XCTAssertEqual(requests, [6])
        await gate.release()
        for _ in 0..<200 where model.isLoadingFiles { try await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor
    func testRealDualCardReplacementUpdatesCardTwoFilterDuringScan() async throws {
        let savedFilter = PhotoFilterPersistence.load()
        defer { PhotoFilterPersistence.save(savedFilter) }
        var script: [STAExchange] = [
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([0x10001, 0x20001])),
            .init(PTPConstants.getObjectHandles, [0x10001, .max, 0], payload: staU32Array([2, 4, 6])),
            .init(PTPConstants.getObjectHandles, [0x20001, .max, 0], payload: staU32Array([1, 3, 5]))
        ]
        for id: UInt32 in [6, 5, 4, 3, 2, 1] {
            let pair = (id + 1) / 2
            script.append(.init(PTPConstants.getObjectInfo, [id], payload: objectInfo(id,
                storage: id % 2 == 0 ? 0x10001 : 0x20001,
                date: "20261001T12000\(pair)", name: "\(pair).JPG")))
        }
        let wire = STAScriptTransport(script)
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let gate = ScanThumbnailAdmissionGate()
        let fetched = STARecorder<UInt32>()
        let model = PhotoListViewModel(scanCatalog: { preserve, cursor, detect, nextBatch, onBatch in
            try await repository.scanCatalog(preserveExisting: preserve, resumeSnapshot: cursor,
                detectNewHandles: detect, nextBatchSize: nextBatch, onBatch: { batch in
                    try await onBatch(batch)
                    if batch.contains(where: { $0.id == 6 && $0.storageIDs.count == 2 }) {
                        _ = await gate.wait()
                    }
                })
        }, resumeSnapshotProvider: { await repository.scanSnapshotForResume() }, prefetchBatch: { batch in
            for file in batch { await fetched.append(file.id) }
            let ids = Set(batch.map(\.id))
            return ThumbnailBatchResult(settled: ids, cached: ids)
        }, canFill: { true }, setRemoteGate: { _ in }, sequentialLoading: true)
        defer { model.cancelLoading() }
        var filter = PhotoFilterState()
        filter.storageSlot = 2
        model.setFilter(filter)
        model.load()
        for _ in 0..<200 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting)
        XCTAssertTrue(model.isLoadingFiles)
        XCTAssertEqual(model.availableStorageSlots, [1, 2])
        XCTAssertEqual(model.sections.flatMap(\.files).map(\.id), [6, 4])
        let requested = await fetched.values
        XCTAssertEqual(requested, [6, 4])
        await gate.release()
        for _ in 0..<200 where model.isLoadingFiles { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.sections.flatMap(\.files).map(\.id), [6, 4, 2])
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
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
        XCTAssertEqual(published.map { $0.map(\.id) }, [[6], [6, 4], [2]])
        XCTAssertEqual(published[1][0].storageIDs, [1, 0x10001])
        XCTAssertEqual(published[2][0].storageIDs, [1, 0x10001])
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testCompletedResumeRetainsBackupAliasesInNewMediaBaseline() async throws {
        let enumeration: [STAExchange] = [
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1, 0x10001])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([2, 4, 6])),
            .init(PTPConstants.getObjectHandles, [0x10001, .max, 0], payload: staU32Array([1, 3, 5]))
        ]
        func metadata(_ ids: [UInt32]) -> [STAExchange] {
            ids.map { id in
                let pair = (id + 1) / 2
                return .init(PTPConstants.getObjectInfo, [id], payload: objectInfo(id,
                    storage: id % 2 == 0 ? 1 : 0x10001,
                    date: "20261001T12000\(pair)", name: "\(pair).JPG"))
            }
        }
        let wire = STAScriptTransport(enumeration + metadata([6, 5, 4, 3, 2, 1]) +
            enumeration + metadata([5, 3, 1]))
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let initial = try await repository.scanCatalog()
        XCTAssertEqual(initial.files.map(\.id), [6, 4, 2])
        // All handles were accepted, including aliases omitted from visible rows.
        let snapshot = PhotoScanSnapshot(storageIDs: [1, 0x10001],
            handleOrders: [(1, [2, 4, 6]), (0x10001, [1, 3, 5])],
            processedHandles: [1, 2, 3, 4, 5, 6], handleQueriesSucceeded: true,
            filterStorageIDs: [1, 0x10001], directStorageIDsByHandle: [:])
        _ = try await repository.scanCatalog(preserveExisting: true, resumeSnapshot: snapshot)
        let refreshed = try await repository.scanCatalog(preserveExisting: true, detectNewHandles: true)
        XCTAssertTrue(refreshed.addedHandles.isEmpty)
        XCTAssertTrue(refreshed.removedHandles.isEmpty)
        XCTAssertEqual(refreshed.files.map(\.id), [6, 4, 2])
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testSTARecoveryMovesCatalogBaselineToNewSameBodyConnectionOnly() async throws {
        let guid = String(repeating: "1", count: 32)
        let album = STAAlbumAccess(storageIDs: [1, 0x10001], prefetchedHandles: nil,
            directObjectRead: false, deviceInfo: nil)
        let handles: [STAExchange] = [
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([2, 4, 6])),
            .init(PTPConstants.getObjectHandles, [0x10001, .max, 0], payload: staU32Array([1, 3, 5]))
        ]
        func metadata(_ ids: [UInt32]) -> [STAExchange] {
            ids.map { id in
                let pair = (id + 1) / 2
                return .init(PTPConstants.getObjectInfo, [id], payload: objectInfo(id,
                    storage: id % 2 == 0 ? 1 : 0x10001,
                    date: "20261001T12000\(pair)", name: "\(pair).JPG"))
            }
        }
        let oldWire = STAScriptTransport(handles + metadata([6, 5, 4, 3, 2, 1]))
        let old = CameraRepository(session: PTPSession(transport: oldWire), staAlbum: album,
            transportCameraIdentifier: guid)
        _ = try await old.scanCatalog()
        await old.beginShutdown()
        let saved = await old.staCatalogRecovery()
        let recovery = try XCTUnwrap(saved)
        let newWire = STAScriptTransport([
            .init(PTPConstants.getStorageIDs, [], payload: staU32Array([1, 0x10001]))
        ] + handles + metadata([5, 3, 1]))
        let replacement = CameraRepository(session: PTPSession(transport: newWire), staAlbum: album,
            transportCameraIdentifier: guid)
        let generation = await replacement.photoRatingGeneration()
        let restored = await replacement.restoreSTACatalog(recovery)
        XCTAssertTrue(restored)
        let nextGeneration = await replacement.photoRatingGeneration()
        XCTAssertGreaterThan(nextGeneration, generation)
        let cursor = await replacement.scanSnapshotForResume()
        XCTAssertNil(cursor)
        let result = try await replacement.scanCatalog(preserveExisting: true, detectNewHandles: true)
        XCTAssertEqual(result.files.map(\.id), [6, 4, 2])
        XCTAssertTrue(result.files.allSatisfy { $0.storageIDs == [1, 0x10001] })
        XCTAssertTrue(result.addedHandles.isEmpty)
        XCTAssertTrue(result.removedHandles.isEmpty)
        let repeated = await replacement.restoreSTACatalog(recovery)
        XCTAssertFalse(repeated)
        for identity in [String(repeating: "2", count: 32), nil] as [String?] {
            let other = CameraRepository(session: PTPSession(transport: STAScriptTransport([])),
                staAlbum: album, transportCameraIdentifier: identity)
            let accepted = await other.restoreSTACatalog(recovery)
            XCTAssertFalse(accepted)
        }
        let ap = CameraRepository(session: PTPSession(transport: STAScriptTransport([])), transportCameraIdentifier: guid)
        let acceptedAP = await ap.restoreSTACatalog(recovery)
        XCTAssertFalse(acceptedAP)
        for wire in [oldWire, newWire] { let remaining = await wire.remaining; XCTAssertEqual(remaining, 0) }
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

    func testRejectedStorageQueryPreservesBaselineAndDoesNotBecomeNoCard() async throws {
        for failure in [STAExchange(PTPConstants.getStorageIDs, response: 0x2002),
                        STAExchange(PTPConstants.getStorageIDs, payload: Data([2, 0, 0, 0]))] {
            let wire = STAScriptTransport([
                .init(PTPConstants.getStorageIDs, payload: staU32Array([1])),
                .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1])),
                .init(PTPConstants.getObjectInfo, [1], payload: objectInfo(1)),
                failure,
                .init(PTPConstants.getStorageIDs, payload: staU32Array([1])),
                .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1]))
            ])
            let repository = CameraRepository(session: PTPSession(transport: wire))
            let first = try await repository.scanCatalog(nextBatchSize: { 48 })
            XCTAssertEqual(first.files.map(\.id), [1])
            do {
                _ = try await repository.scanCatalog(preserveExisting: true, nextBatchSize: { 48 })
                XCTFail("Rejected/malformed storage must fail, not publish an empty album")
            } catch {}
            let recovered = try await repository.scanCatalog(preserveExisting: true, nextBatchSize: { 48 })
            XCTAssertEqual(recovered.files.map(\.id), [1])
            XCTAssertTrue(recovered.removedHandles.isEmpty)
            XCTAssertTrue(recovered.addedHandles.isEmpty)
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testNonSTAStorageBusyRetriesAndSuccessfulEmptyRemovesBaseline() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getStorageIDs, response: PTPConstants.deviceBusy),
            .init(PTPConstants.getStorageIDs, response: PTPConstants.deviceBusy),
            .init(PTPConstants.getStorageIDs, payload: staU32Array([1])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1])),
            .init(PTPConstants.getObjectInfo, [1], payload: objectInfo(1)),
            .init(PTPConstants.getStorageIDs, payload: staU32Array([]))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let first = try await repository.scanCatalog(nextBatchSize: { 48 })
        XCTAssertEqual(first.files.map(\.id), [1])
        let empty = try await repository.scanCatalog(preserveExisting: true, nextBatchSize: { 48 })
        XCTAssertTrue(empty.files.isEmpty)
        XCTAssertEqual(empty.removedHandles, [1])
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testMonitorPageAndSessionCleanupHoldIndependentBackgroundOwnership() async {
        let repository = CameraRepository(session: PTPSession(transport: STAScriptTransport([])))
        await repository.setRemoteActive(true)
        await repository.setRemoteSessionActive(true)
        await repository.setRemoteActive(false)
        let duringCleanup = await repository.backgroundThumbnailFillAllowed()
        XCTAssertFalse(duringCleanup)
        await repository.setRemoteSessionActive(true)
        await repository.setRemoteSessionActive(false)
        let duringReplacement = await repository.backgroundThumbnailFillAllowed()
        XCTAssertFalse(duringReplacement)
        await repository.setRemoteSessionActive(false)
        let idle = await repository.backgroundThumbnailFillAllowed()
        XCTAssertTrue(idle)
    }

    func testReviewReadsFreshHandlesAndDeduplicatesAliasedCardsWhileMonitorOwnsCamera() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getStorageIDs, response: PTPConstants.deviceBusy),
            .init(PTPConstants.getStorageIDs, payload: staU32Array([1, 0x10001])),
            .init(PTPConstants.getObjectHandles, [1, .max, 0], payload: staU32Array([1, 2])),
            .init(PTPConstants.getObjectHandles, [0x10001, .max, 0], payload: staU32Array([2, 3])),
            .init(PTPConstants.getObjectInfo, [2], payload: objectInfo(2)),
            .init(PTPConstants.getObjectInfo, [3], payload: objectInfo(3)),
            .init(PTPConstants.getObjectInfo, [1], payload: objectInfo(1))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
        await repository.setRemoteActive(true)
        let catalog = try await repository.openRemoteReviewCatalog()
        let photos = try await catalog.loadNextPage()
        XCTAssertEqual(photos.map(\.file.id), [2, 1, 3])
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
        await repository.setRemoteActive(false)
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

private actor STACatalogReplayService: WiFiConnectionServicing {
    nonisolated let profiles: STAProfileStore
    private let fixture = STAProfileFixture()
    private var repositories: [CameraRepository]
    init(_ repositories: [CameraRepository]) {
        self.repositories = repositories
        profiles = fixture.store
    }
    func connectAP(host: String) async throws -> CameraRepository { throw STAConnectionError.notFound }
    func connectSTA(discovery: PTPIPDiscoveryService,
                    onStage: @escaping @Sendable (STAConnectionStage) async -> Void) async throws -> CameraRepository {
        guard !repositories.isEmpty else { throw STAConnectionError.notFound }
        return repositories.removeFirst()
    }
    func startKeepalive(for repository: CameraRepository, onLost: @escaping @Sendable () async -> Void) {}
    func disconnect() {}
}


private actor ScanThumbnailAdmissionGate {
    private var released = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    var isWaiting: Bool { !waiters.isEmpty }
    func wait() async -> Bool {
        if released { return true }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: true) }
    }
}
