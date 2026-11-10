// Audit characterization only: these assertions capture the current discrepancies.
// Appended temporarily to DomainModelTests.swift for execution; not a production contract.
@MainActor
final class TransferBusinessAuditProbe: XCTestCase {
    private func fixture(free: Bool = false) throws -> (TransferQueue, URL, FreeUsageStore) {
        let suite = "transfer-audit-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let usage = FreeUsageStore(defaults: defaults)
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!, premiumAccess: PremiumAccess(free ? .free : .lifetime), freeUsage: usage)
        return (queue, directory, usage)
    }
    private func wait(_ queue: TransferQueue) async throws -> TransferQueueItem {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let state = await queue.snapshot()
            if let item = state.items.first, item.status != .waiting,
               !state.isTransferring, !item.isGeneratingFrame { return item }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "AuditTimeout", code: 1)
    }
    private func jpeg(_ directory: URL) throws -> CameraFile {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        try data.write(to: directory.appendingPathComponent("AUDIT.JPG"))
        return CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(data.count), fileName: "AUDIT.JPG", captureDate: "20261102T120000", isProtected: false)
    }
    func testCompleteVideoPartialCurrentlyPublishesAfterQuotaExhaustedAndWithoutCamera() async throws {
        let (queue, directory, usage) = try fixture(free: true)
        for _ in 0..<FreeUsageStore.transferLimit { usage.recordTransfer(id: UUID(), isPro: false) }
        let file = CameraFile(id: 1, storageID: 1, format: 0x300D, size: 10, fileName: "AUDIT.MOV", captureDate: "20261102T120000", isProtected: false)
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(transferPartialFileName(size: file.size, captureDate: file.captureDate, fileName: file.fileName)))
        _ = await queue.enqueue(file)
        await queue.start(session: nil, directory: directory)
        let item = try await wait(queue)
        XCTAssertEqual(item.status, .completed)
        XCTAssertTrue(item.skipped)
        XCTAssertNotNil(item.outputURL)
        XCTAssertEqual(usage.snapshot().transfersLeft, 0)
    }
    func testExistingOriginalWithDisabledRuntimeEffectsCurrentlyLosesSkippedStatus() async throws {
        let (queue, directory, _) = try fixture()
        let file = try jpeg(directory)
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        _ = await queue.enqueue(file, effects: settings, photoEffectsEnabled: true)
        await queue.setPhotoEffectsEnabled(false)
        await queue.start(session: nil, directory: directory)
        let item = try await wait(queue)
        XCTAssertEqual(item.status, .completed)
        XCTAssertFalse(item.skipped)
        XCTAssertTrue(item.frameGenerationSkipped)
    }
    func testValidJPEGWithoutExifCurrentlyFailsFrameGeneration() async throws {
        let (queue, directory, _) = try fixture()
        let file = try jpeg(directory)
        let camera = TransferAuditMetadataCamera()
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = true
        _ = await queue.enqueue(file, effects: settings)
        await queue.start(session: camera, directory: directory)
        let item = try await wait(queue)
        XCTAssertEqual(item.status, .completed)
        XCTAssertNotNil(item.frameError)
        XCTAssertNil(item.frameURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file.fileName).path))
        let reads = await camera.reads
        XCTAssertEqual(reads, 1)
    }
    func testPureDecorationCurrentlyReadsCameraMetadataUnnecessarily() async throws {
        let (queue, directory, _) = try fixture()
        let file = try jpeg(directory)
        let camera = TransferAuditMetadataCamera()
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = true
        settings.metadata = PhotoFrameMetadataSettings(showDate: false, showTime: false, showFocalLength: false, showExposure: false, showBrand: false, showModel: false, showLensModel: false, showCoordinates: false, showAltitude: false, datePattern: "yyyy-MM-dd", timePattern: "HH:mm:ss")
        XCTAssertFalse(settings.metadata.hasVisibleMetadata)
        _ = await queue.enqueue(file, effects: settings)
        await queue.start(session: camera, directory: directory)
        let item = try await wait(queue)
        let reads = await camera.reads
        XCTAssertEqual(reads, 1)
        XCTAssertNil(item.frameError)
        XCTAssertNotNil(item.frameURL)
    }
    func testPlaceLookupCurrentlyBlocksAnUnrelatedReadyRender() async throws {
        let (_, directory, _) = try fixture()
        let probe = TransferAuditPlaceProbe()
        let resolver = PhotoFramePlaceResolver { _, _, _ in await probe.lookup() }
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime),
            parseMetadata: { _ in PreparedPhotoMetadata(value: PhotoFrameMetadata(make: nil, model: nil, lensModel: nil, focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil, latitude: 35, longitude: 139), state: .complete) },
            placeResolver: resolver, placeAllowed: { true },
            renderFrame: { source, _, _, _ in await probe.render(source) })
        let camera = TransferAuditCaptureCamera()
        let first = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10, fileName: "PLACE.JPG", captureDate: nil, isProtected: false)
        let second = CameraFile(id: 2, storageID: 1, format: 0x3801, size: 10, fileName: "PLAIN.JPG", captureDate: nil, isProtected: false)
        var place = PhotoEffectsSettings()
        place.photoFrameEnabled = true; place.photoFrameBorderEnabled = true
        var metadata = place.metadata; metadata.showCity = true; place.metadata = metadata
        var plain = PhotoEffectsSettings()
        plain.photoFrameEnabled = true; plain.photoFrameBorderEnabled = false
        _ = await queue.enqueue(first, effects: place)
        await queue.start(session: camera, directory: directory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !probe.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let started = await probe.started
        XCTAssertTrue(started)
        _ = await queue.enqueue(second, effects: plain)
        await queue.start(session: camera, directory: directory)
        while ContinuousClock.now < deadline {
            let state = await queue.snapshot()
            if state.items.count == 2, state.items[1].isGeneratingFrame, !state.isTransferring { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        let before = await probe.rendered
        XCTAssertEqual(before, [], "Current implementation holds the single compute slot while awaiting place lookup")
        await probe.release()
        while ContinuousClock.now < deadline {
            if await probe.rendered.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let after = await probe.rendered
        XCTAssertEqual(after, ["PLACE.JPG", "PLAIN.JPG"])
        await queue.closePhotoGeneration()
    }
}

private actor TransferAuditMetadataCamera: TransferDownloading {
    private(set) var reads = 0
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        throw CameraTransportError.unavailable
    }
    func frameMetadataHeader(file: CameraFile) async throws -> Data? {
        reads += 1
        return Data([0xff, 0xd8, 0xff, 0xd9]) // Valid JPEG structure with no EXIF.
    }
}

private actor TransferAuditPlaceProbe {
    private var continuation: CheckedContinuation<PhotoPlaceLookupResult, Never>?
    private(set) var started = false
    private(set) var rendered: [String] = []
    func lookup() async -> PhotoPlaceLookupResult {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: .empty); continuation = nil }
    func render(_ source: URL) -> URL { rendered.append(source.lastPathComponent); return source }
}

private actor TransferAuditCaptureCamera: TransferDownloading {
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let url = directory.appendingPathComponent(file.fileName)
        try Data(repeating: 1, count: Int(file.size)).write(to: url)
        return url
    }
    func downloadResult(file: CameraFile, to directory: URL, captureHeader: Bool,
                        progress: (@Sendable (TransferDownloadProgress) -> Void)?) async throws -> CameraDownloadResult {
        let start = ContinuousClock.now
        let url = try await download(file: file, to: directory, progress: nil)
        return CameraDownloadResult(url: url, bytes: file.size, transferredBytes: file.size,
                                    startedAt: start, headerPrefix: captureHeader ? Data([1]) : nil)
    }
}
