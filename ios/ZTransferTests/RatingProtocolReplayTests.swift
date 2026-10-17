import Foundation
import XCTest
@testable import ZTransfer

final class RatingProtocolReplayTests: XCTestCase {
    func testRuntimeCloseWaitsForWholeRatingTransactionAndRunsOnce() async throws {
        try await verifyRuntimeClose(throughService: false)
    }

    func testWiFiDisconnectWaitsForWholeRatingTransactionAndRunsOnce() async throws {
        try await verifyRuntimeClose(throughService: true)
    }

    private func verifyRuntimeClose(throughService: Bool) async throws {
        let bytes = tiff(2)
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx, [12, 0, 0, 102_400, 0], payload: Data(bytes.prefix(8))),
            .init(PTPConstants.getPartialObjectEx, [12, 8, 0, 8_192, 0], payload: Data(bytes.dropFirst(8))),
            .init(PTPConstants.closeSession, [])
        ])
        let session = PTPSession(transport: wire)
        let repository = CameraRepository(session: session)
        let entered = GateTestLatch(), release = GateTestLatch()
        await wire.beforeNextReply(PTPConstants.getPartialObjectEx) {
            await entered.signal(); await release.wait()
        }
        let raw = file(12, "DSC_0012.NEF")
        let rating = Task { try await repository.readPhotoRatingHeader(file: raw) }
        await entered.wait()
        let close: @Sendable () async -> Void = {
            _ = try? await session.executeResponse(operation: PTPConstants.closeSession)
            await session.invalidate()
        }
        let service = WiFiConnectionService()
        await service.acceptConnection(repository, close: close)
        let retire: @Sendable () async -> Void = {
            if throughService { await service.disconnect() }
            else { await repository.retireConnection(close) }
        }
        let first = Task { await retire() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await repository.cameraSchedulerSnapshot().queued != 1, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let pending = await repository.cameraSchedulerSnapshot()
        XCTAssertEqual(pending.queued, 1)
        first.cancel()
        let second = Task { await retire() }
        // A second shutdown notification must not cancel the queued close.
        await repository.beginShutdown(reason: "duplicate transport notification")
        do {
            _ = try await repository.preview(handle: 99)
            XCTFail("Shutdown must reject new business requests")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await release.signal()
        let value = try await rating.value
        XCTAssertEqual(value, 2)
        await first.value; await second.value
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [PTPConstants.getPartialObjectEx,
                                             PTPConstants.getPartialObjectEx, PTPConstants.closeSession])
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
        let invalid = await session.isInvalidated
        XCTAssertTrue(invalid)
    }

    func testHeaderDiagnosticMeasuresActualSchedulerWait() async throws {
        let previous = PhotoRatingDiagnostics.beginProbe()
        defer { PhotoRatingDiagnostics.restore(previous) }
        let gate = RatingReplyGate()
        let wire = STAScriptTransport([
            .init(PTPConstants.getDeviceInfo, [], payload: staDeviceInfo()),
            .init(PTPConstants.getPartialObjectEx, [11, 0, 0, 102_400, 0], payload: tiff(4))
        ])
        await wire.beforeNextReply(PTPConstants.getDeviceInfo) { await gate.wait() }
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let foreground = Task { try await repository.loadDeviceInfo() }
        for _ in 0..<100 where await !gate.waiting { try await Task.sleep(for: .milliseconds(5)) }
        let held = await gate.waiting
        XCTAssertTrue(held)
        let raw = file(11, "DSC_0011.NEF")
        let rating = Task { try await repository.readPhotoRatingHeader(file: raw) }
        for _ in 0..<100 {
            if await repository.cameraSchedulerSnapshot().queued == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = await repository.cameraSchedulerSnapshot()
        XCTAssertEqual(snapshot.queued, 1)
        let before = await wire.commands.count
        XCTAssertEqual(before, 1)
        try await Task.sleep(for: .milliseconds(20))
        await gate.release()
        _ = try await foreground.value
        let value = try await rating.value
        XCTAssertEqual(value, 4)
        let report = PhotoRatingDiagnostics.snapshot()
        let field = try XCTUnwrap(report.range(of: "gate="))
        let milliseconds = try XCTUnwrap(Int(report[field.upperBound...].prefix(while: { $0.isNumber })))
        XCTAssertGreaterThanOrEqual(milliseconds, 15)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    @MainActor
    func testRawProbeRetainsDetailsAcrossPhotoListUpdates() async throws {
        let saved = PhotoFilterPersistence.load()
        defer {
            PhotoFilterPersistence.save(saved)
            PhotoRatingDiagnostics.setEnabled(false)
        }
        for enabled in [false, true] {
            let initial = file(42, "START.JPG")
            let raw = file(11, "DSC_0011.NEF")
            var script: [STAExchange] = enabled ? [
                .init(PTPConstants.getObjectPropValue, [42, PTPConstants.objectPropRating], payload: Data([50, 0]))
            ] : []
            script += [
                .init(PTPConstants.getObjectPropValue, [11, PTPConstants.objectPropRating], payload: Data([50, 0])),
                .init(PTPConstants.getPartialObjectEx, [11, 0, 0, 102_400, 0], payload: tiff(4))
            ]
            let wire = STAScriptTransport(script)
            let session = CameraSession(repository: CameraRepository(session: PTPSession(transport: wire)))
            let model = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
                PhotoScanResult(files: [initial], removedHandles: [], addedHandles: [],
                    handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
            }, setRemoteGate: { _ in }, ratingIO: PhotoRatingScanIO(session: session))
            model.load()
            for _ in 0..<100 where !model.hasCompletedFileScan { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(model.hasCompletedFileScan)
            var filter = PhotoFilterState(); filter.ratingEnabled = enabled
            model.setFilter(filter)
            if enabled {
                for _ in 0..<100 where !model.ratingScan.complete { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertTrue(model.ratingScan.complete)
            }
            await wire.beforeNextReply(PTPConstants.getPartialObjectEx) {
                await model.applyCatalogUpdate([initial, raw])
                await model.setTransferBusy(true)
                await model.setTransferBusy(false)
            }
            let previous = PhotoRatingDiagnostics.beginProbe()
            await session.probeRawRating(file: raw)
            PhotoRatingDiagnostics.restore(previous, preserveEntries: true)
            model.setTransferBusy(true)
            model.setTransferBusy(false)
            let report = PhotoRatingDiagnostics.snapshot()
            XCTAssertTrue(report.contains("object property=0xDC8A result=3"))
            XCTAssertTrue(report.contains("read file=DSC_0011.NEF"))
            XCTAssertTrue(report.contains("header result=4"))
            XCTAssertTrue(report.contains("raw probe complete"))
            PhotoRatingDiagnostics.detail("unexpected-detail")
            PhotoRatingDiagnostics.note("restored-summary")
            let restored = PhotoRatingDiagnostics.snapshot()
            XCTAssertFalse(restored.contains("unexpected-detail"))
            XCTAssertEqual(restored.contains("restored-summary"), enabled)
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
            model.cancelRatingScan()
        }
    }

    private func file(_ handle: UInt32, _ name: String, size: UInt64 = 1) -> CameraFile {
        CameraFile(id: handle, storageID: 1, format: 0x3801, size: size,
                   fileName: name, captureDate: "20261007T120000", isProtected: false)
    }

    private func tiff(_ rating: UInt16) -> Data {
        var data = Data([73, 73])
        data.appendUInt16(42, littleEndian: true)
        data.appendUInt32(8, littleEndian: true)
        data.appendUInt16(1, littleEndian: true)
        data.appendUInt16(0x4746, littleEndian: true)
        data.appendUInt16(3, littleEndian: true)
        data.appendUInt32(1, littleEndian: true)
        data.appendUInt16(rating, littleEndian: true)
        data.appendUInt16(0, littleEndian: true)
        data.appendUInt32(0, littleEndian: true)
        return data
    }

    private func atom(_ type: String, _ payload: Data) -> Data {
        var result = Data()
        result.appendUInt32(UInt32(payload.count + 8), littleEndian: false)
        result.append(contentsOf: Data(type.utf8))
        result.append(payload)
        return result
    }

    private func video(_ stars: Int) -> Data {
        var tag = Data()
        tag.appendUInt32(0x1001, littleEndian: false)
        tag.appendUInt16(8, littleEndian: false)
        tag.appendUInt16(1, littleEndian: false)
        tag.appendUInt16(UInt16(bitPattern: Int16(stars)), littleEndian: false)
        return atom("ftyp", Data(repeating: 0, count: 20)) +
            atom("moov", atom("udta", atom("NCDT", atom("NCTG", tag))))
    }

    func testObjectPropertyUsesAndroidOperationAndWireProperty() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getObjectPropValue,
                  [7, PTPConstants.objectPropRating], payload: Data([99, 0]))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let result = try await repository.readObjectRating(file: file(7, "DSC_0007.JPG"))
        XCTAssertEqual(result, 5)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testObjectPropertyUnsupportedIsLatchedForTheConnection() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getObjectPropValue,
                  [8, PTPConstants.objectPropRating], response: PTPConstants.operationNotSupported)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let first = try await repository.readObjectRating(file: file(8, "DSC_0008.JPG"))
        let second = try await repository.readObjectRating(file: file(9, "DSC_0009.JPG"))
        XCTAssertNil(first)
        XCTAssertNil(second)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testBusyObjectPropertyRemainsRetryable() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getObjectPropValue,
                  [10, PTPConstants.objectPropRating], response: PTPConstants.deviceBusy),
            .init(PTPConstants.getObjectPropValue,
                  [10, PTPConstants.objectPropRating], payload: Data([50, 0]))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        do {
            _ = try await repository.readObjectRating(file: file(10, "DSC_0010.JPG"))
            XCTFail("DeviceBusy must be surfaced to the scan")
        } catch let error as CameraRepositoryError {
            XCTAssertEqual(error, .ratingReadDeferred)
        }
        let result = try await repository.readObjectRating(file: file(10, "DSC_0010.JPG"))
        XCTAssertEqual(result, 3)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testHeaderFallsBackToStandardPartialObjectAfterNikonUnsupported() async throws {
        let previous = PhotoRatingDiagnostics.beginProbe()
        defer { PhotoRatingDiagnostics.restore(previous) }
        let bytes = tiff(4)
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx, [11, 0, 0, 102_400, 0],
                  response: PTPConstants.operationNotSupported),
            .init(PTPConstants.getPartialObject, [11, 0, 102_400], payload: bytes)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let result = try await repository.readPhotoRatingHeader(file: file(11, "DSC_0011.NEF"))
        XCTAssertEqual(result, 4)
        let report = PhotoRatingDiagnostics.snapshot()
        XCTAssertTrue(report.contains("read file=DSC_0011.NEF bytes=\(bytes.count) chunks=1"))
        for field in ["gate=", "command=", "parse=", "other=", "result=4"] {
            XCTAssertTrue(report.contains(field), "Missing diagnostic field: \(field)")
        }
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testRawObjectPropertyMissLatchesExtensionAndUsesHeaderForFollowingRaws() async throws {
        let bytes = tiff(1)
        let wire = STAScriptTransport([
            .init(PTPConstants.getObjectPropValue, [15, PTPConstants.objectPropRating],
                  response: 0xA80A),
            .init(PTPConstants.getPartialObjectEx, [15, 0, 0, 102_400, 0], payload: bytes),
            .init(PTPConstants.getPartialObjectEx, [16, 0, 0, 102_400, 0], payload: bytes)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let first = try await repository.readObjectOrRawHeaderRating(file: file(15, "DSC_0015.NEF"))
        let second = try await repository.readObjectOrRawHeaderRating(file: file(16, "DSC_0016.NEF"))
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testHeaderExtendsContiguousPrefixWithoutRepeatingFirstRead() async throws {
        let previous = PhotoRatingDiagnostics.beginProbe()
        defer { PhotoRatingDiagnostics.restore(previous) }
        let bytes = tiff(2)
        let split = bytes.prefix(8)
        let tail = bytes.dropFirst(8)
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx, [12, 0, 0, 102_400, 0], payload: Data(split)),
            .init(PTPConstants.getPartialObjectEx, [12, 8, 0, 8_192, 0], payload: Data(tail))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        await wire.beforeNextReply(PTPConstants.getPartialObjectEx) {
            try await Task.sleep(for: .milliseconds(15))
        }
        let result = try await repository.readPhotoRatingHeader(file: file(12, "DSC_0012.NEF"))
        XCTAssertEqual(result, 2)
        let report = PhotoRatingDiagnostics.snapshot()
        XCTAssertTrue(report.contains("bytes=\(bytes.count) chunks=2"))
        let command = try XCTUnwrap(report.range(of: "command="))
        let milliseconds = try XCTUnwrap(Int(report[command.upperBound...].prefix(while: { $0.isNumber })))
        XCTAssertGreaterThanOrEqual(milliseconds, 10)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testEmptySuccessfulTailCountsButBusyDoesNotPublishCompletedRead() async throws {
        for response in [PTPConstants.responseOK, PTPConstants.deviceBusy] {
            let previous = PhotoRatingDiagnostics.beginProbe()
            defer { PhotoRatingDiagnostics.restore(previous) }
            let wire = STAScriptTransport([
                .init(PTPConstants.getPartialObjectEx, [12, 0, 0, 102_400, 0], payload: Data([1, 2, 3])),
                .init(PTPConstants.getPartialObjectEx, [12, 3, 0, 8_192, 0], response: response)
            ])
            let repository = CameraRepository(session: PTPSession(transport: wire))
            do {
                let value = try await repository.readPhotoRatingHeader(file: file(12, "DSC_0012.NEF"))
                XCTAssertEqual(response, PTPConstants.responseOK)
                XCTAssertNil(value)
                let report = PhotoRatingDiagnostics.snapshot()
                XCTAssertTrue(report.contains("bytes=3 chunks=2"))
                XCTAssertTrue(report.contains("result=unknown"))
            } catch let error as CameraRepositoryError {
                XCTAssertEqual(response, PTPConstants.deviceBusy)
                XCTAssertEqual(error, .ratingReadDeferred)
                XCTAssertFalse(PhotoRatingDiagnostics.snapshot().contains("read file="))
            }
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testVideoReaderUsesNikonPartialWindowsAndNCTGPath() async throws {
        let bytes = video(5)
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx,
                  [13, 0, 0, UInt32(bytes.count), 0], payload: bytes)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let result = try await repository.readVideoRating(file: file(13, "CLIP_0013.MOV", size: UInt64(bytes.count)))
        XCTAssertEqual(result, 5)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testHeaderUnsupportedLatchesBothPartialOperations() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx, [14, 0, 0, 102_400, 0],
                  response: PTPConstants.operationNotSupported),
            .init(PTPConstants.getPartialObject, [14, 0, 102_400],
                  response: PTPConstants.operationNotSupported)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let first = try await repository.readPhotoRatingHeader(file: file(14, "DSC_0014.NEF"))
        let second = try await repository.readPhotoRatingHeader(file: file(14, "DSC_0014.NEF"))
        XCTAssertNil(first)
        XCTAssertNil(second)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }
}

private actor RatingReplyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func wait() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16, littleEndian: Bool) {
        var value = littleEndian ? value.littleEndian : value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32, littleEndian: Bool) {
        var value = littleEndian ? value.littleEndian : value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

/// Ordinary AP/USB FHD uses a different contract from paired STA previews.
final class PreviewProtocolReplayTests: XCTestCase {
    func testCropHeaderBusyRetriesAreOptInBoundedAndDoNotRetryOtherErrors() async throws {
        let parameters: [UInt32] = [1, 0, 0, 131072, 0]
        for (enabled, failures, code, succeeds) in [
            (true, 2, PTPConstants.deviceBusy, true),
            (true, 3, PTPConstants.deviceBusy, false),
            (false, 1, PTPConstants.deviceBusy, false),
            (true, 1, PTPConstants.operationNotSupported, false)
        ] {
            var script = (0..<failures).map { _ in
                STAExchange(PTPConstants.getPartialObjectEx, parameters, response: code)
            }
            if succeeds { script.append(.init(PTPConstants.getPartialObjectEx, parameters, payload: Data([1, 2]))) }
            let wire = STAScriptTransport(script)
            let repository = CameraRepository(session: PTPSession(transport: wire))
            do {
                let data = try await repository.readPrefix(handle: 1, length: 131072, retryDeviceBusy: enabled)
                XCTAssertTrue(succeeds)
                XCTAssertEqual(data, Data([1, 2]))
            } catch {
                XCTAssertFalse(succeeds)
                XCTAssertEqual(error as? PTPSessionError, .responseCode(code))
            }
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testCropHeaderCancellationDuringBusyDelayReleasesPreviewLane() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx, [1, 0, 0, 131072, 0], response: PTPConstants.deviceBusy),
            .init(PTPConstants.getPartialObjectEx, [2, 0, 0, 131072, 0], payload: Data([2]))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let request = Task { try await repository.readPrefix(handle: 1, length: 131072, retryDeviceBusy: true) }
        for _ in 0..<100 {
            if await wire.commands.count == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled header must not succeed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let next = try await repository.readPrefix(handle: 2, length: 131072, retryDeviceBusy: true)
        XCTAssertEqual(next, Data([2]))
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testBusyRetriesTwiceWithDelayThenSucceeds() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getFHDPicture, [1], response: PTPConstants.deviceBusy),
            .init(PTPConstants.getFHDPicture, [1], response: PTPConstants.deviceBusy),
            .init(PTPConstants.getFHDPicture, [1], payload: Data([1, 2, 3]))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let start = ContinuousClock.now
        let result = try await repository.preview(handle: 1)
        XCTAssertEqual(result, Data([1, 2, 3]))
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(300))
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), Array(repeating: PTPConstants.getFHDPicture, count: 3))
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testThreeBusyResponsesAndEmptyPayloadDoNotDisableNextFile() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getFHDPicture, [1], response: PTPConstants.deviceBusy),
            .init(PTPConstants.getFHDPicture, [1], response: PTPConstants.deviceBusy),
            .init(PTPConstants.getFHDPicture, [1], response: PTPConstants.deviceBusy),
            .init(PTPConstants.getFHDPicture, [2], payload: Data()),
            .init(PTPConstants.getFHDPicture, [3], payload: Data([3]))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let busy = try await repository.preview(handle: 1)
        let empty = try await repository.preview(handle: 2)
        let success = try await repository.preview(handle: 3)
        XCTAssertTrue(busy.isEmpty)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(success, Data([3]))
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testUnsupportedLatchesOnlyBeforeAnySuccessfulFHD() async throws {
        for previouslySucceeded in [false, true] {
            var script: [STAExchange] = []
            if previouslySucceeded { script.append(.init(PTPConstants.getFHDPicture, [1], payload: Data([1]))) }
            script.append(.init(PTPConstants.getFHDPicture, [2], response: PTPConstants.operationNotSupported))
            if previouslySucceeded { script.append(.init(PTPConstants.getFHDPicture, [3], payload: Data([3]))) }
            let wire = STAScriptTransport(script)
            let repository = CameraRepository(session: PTPSession(transport: wire))
            if previouslySucceeded { _ = try await repository.preview(handle: 1) }
            let unsupported = try await repository.preview(handle: 2)
            let next = try await repository.preview(handle: 3)
            XCTAssertTrue(unsupported.isEmpty)
            XCTAssertEqual(next, previouslySucceeded ? Data([3]) : Data())
            let commands = await wire.commands
            XCTAssertEqual(commands.count, previouslySucceeded ? 3 : 1)
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testCancellationDuringBusyDelayDoesNotSendFallbackOrRetry() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getFHDPicture, [1], response: PTPConstants.deviceBusy),
            .init(PTPConstants.getFHDPicture, [2], payload: Data([2]))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let request = Task { try await repository.preview(handle: 1) }
        for _ in 0..<100 {
            if await wire.commands.count == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled preview must not succeed") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation: \(error)") }
        let next = try await repository.preview(handle: 2)
        XCTAssertEqual(next, Data([2]))
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }
}

extension PreviewProtocolReplayTests {
    @MainActor
    func testFailedFHDPublishesBeforeExifAndRemoteThumbnailFollowsExif() async throws {
        for exifResponse in [PTPConstants.responseOK, PTPConstants.deviceBusy] {
            let wire = STAScriptTransport([
                .init(PTPConstants.getFHDPicture, [7], response: PTPConstants.operationNotSupported),
                .init(PTPConstants.getPartialObjectEx, [7, 0, 0, 128 * 1024, 0], response: exifResponse),
                .init(PTPConstants.getThumb, [7], payload: Data([7]))
            ])
            let repository = CameraRepository(session: PTPSession(transport: wire))
            let session = CameraSession(repository: repository)
            let file = CameraFile(id: 7, storageID: 1, format: 0x3801, size: 100,
                                  fileName: "A.JPG", captureDate: nil, isProtected: false)
            let previewPublished = PreviewPublicationProbe()
            await wire.beforeNextReply(PTPConstants.getPartialObjectEx) {
                let published = await previewPublished.published
                XCTAssertTrue(published, "FHD result must publish before the header reply")
                let commands = await wire.commands
                XCTAssertEqual(commands.map(\.code), [PTPConstants.getFHDPicture, PTPConstants.getPartialObjectEx])
            }
            let (image, metadata) = await session.previewAndExif(file: file, onPreviewLoaded: { data in
                XCTAssertEqual(data, Data())
                previewPublished.published = true
            })
            XCTAssertEqual(image, Data())
            XCTAssertNil(metadata)
            let beforeFallback = await wire.commands
            XCTAssertEqual(beforeFallback.map(\.code), [PTPConstants.getFHDPicture, PTPConstants.getPartialObjectEx])
            let thumbnail = try await session.thumbnail(handle: 7)
            XCTAssertEqual(thumbnail, Data([7]))
            let commands = await wire.commands
            XCTAssertEqual(commands.map(\.code), [PTPConstants.getFHDPicture, PTPConstants.getPartialObjectEx, PTPConstants.getThumb])
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testTransportFailureInvalidatesChannelWithoutFurtherPreviewCommands() async throws {
        let wire = STAScriptTransport([.init(PTPConstants.getFHDPicture, [1])])
        await wire.beforeNextReply(PTPConstants.getFHDPicture) { throw URLError(.networkConnectionLost) }
        let repository = CameraRepository(session: PTPSession(transport: wire))
        do { _ = try await repository.preview(handle: 1); XCTFail("Transport failure must propagate") }
        catch { XCTAssertTrue(error is URLError) }
        do { _ = try await repository.preview(handle: 2); XCTFail("Broken channel must reject new commands") }
        catch { XCTAssertEqual(error as? PTPSessionError, .invalidated) }
        do { _ = try await repository.readPrefix(handle: 1, length: 128 * 1024); XCTFail("No EXIF on broken channel") }
        catch { XCTAssertEqual(error as? PTPSessionError, .invalidated) }
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [PTPConstants.getFHDPicture])
    }
}

@MainActor
private final class PreviewPublicationProbe { var published = false }
