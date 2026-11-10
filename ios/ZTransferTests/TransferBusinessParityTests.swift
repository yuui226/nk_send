import XCTest
import UIKit
@testable import ZTransfer

// Android 8a09e51b: regression coverage for the 2026-11-02 transfer audit.
@MainActor
final class TransferBusinessParityTests: XCTestCase {
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
    func testCompleteVideoPartialRespectsQuotaSizeAndCameraBeforePublishing() async throws {
        for scenario in ["quota", "size", "offline", "allowed"] {
            let (queue, directory, usage) = try fixture(free: true)
            if scenario == "quota" {
                for _ in 0..<FreeUsageStore.transferLimit { usage.recordTransfer(id: UUID(), isPro: false) }
            }
            let size: UInt64 = scenario == "size" ? FreeUsageStore.maximumFileBytes + 1 : 10
            let file = CameraFile(id: 1, storageID: 1, format: 0x300D, size: size, fileName: "AUDIT.MOV", captureDate: "20261102T120000", isProtected: false)
            let partial = directory.appendingPathComponent(transferPartialFileName(size: size, captureDate: file.captureDate, fileName: file.fileName))
            XCTAssertTrue(FileManager.default.createFile(atPath: partial.path, contents: nil))
            let handle = try FileHandle(forWritingTo: partial)
            try handle.truncate(atOffset: size); try handle.close()
            _ = await queue.enqueue(file)
            await queue.start(session: scenario == "offline" ? nil : TransferParityMetadataCamera(), directory: directory)
            let item = try await wait(queue)
            XCTAssertEqual(item.status, scenario == "allowed" ? .completed : .failed)
            XCTAssertEqual(item.outputURL != nil, scenario == "allowed")
            XCTAssertEqual(FileManager.default.fileExists(atPath: partial.path), scenario != "allowed")
            switch scenario {
            case "quota": XCTAssertEqual(item.error, AppLocalized.resource("transfer_limit_reached"))
            case "size": XCTAssertEqual(item.error, AppLocalized.formattedResource("transfer_size_limit", ["%1$d": "400"]))
            case "offline": XCTAssertEqual(item.error, AppLocalized.resource("camera_not_connected"))
            default: XCTAssertTrue(item.skipped); XCTAssertEqual(usage.snapshot().transfers, 0)
            }
        }
    }
    func testExistingOriginalWithDisabledRuntimeEffectsRemainsSkipped() async throws {
        let (queue, directory, _) = try fixture()
        let file = try jpeg(directory)
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        _ = await queue.enqueue(file, effects: settings, photoEffectsEnabled: true)
        await queue.setPhotoEffectsEnabled(false)
        await queue.start(session: nil, directory: directory)
        let item = try await wait(queue)
        XCTAssertEqual(item.status, .completed)
        XCTAssertTrue(item.skipped)
        XCTAssertTrue(item.frameGenerationSkipped)
    }
    func testValidJPEGWithoutExifStillProducesFrame() async throws {
        let (queue, directory, _) = try fixture()
        let file = try jpeg(directory)
        let camera = TransferParityMetadataCamera()
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = true
        _ = await queue.enqueue(file, effects: settings)
        await queue.start(session: camera, directory: directory)
        let item = try await wait(queue)
        XCTAssertEqual(item.status, .completed)
        XCTAssertNil(item.frameError)
        XCTAssertNotNil(item.frameURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file.fileName).path))
        let reads = await camera.reads
        XCTAssertEqual(reads, 1)
    }
    func testPureDecorationDoesNotReadCameraMetadata() async throws {
        let (queue, directory, _) = try fixture()
        let file = try jpeg(directory)
        let camera = TransferParityMetadataCamera()
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = true
        settings.metadata = PhotoFrameMetadataSettings(showDate: false, showTime: false, showFocalLength: false, showExposure: false, showBrand: false, showModel: false, showLensModel: false, showCoordinates: false, showAltitude: false, datePattern: "yyyy-MM-dd", timePattern: "HH:mm:ss")
        XCTAssertFalse(settings.metadata.hasVisibleMetadata)
        _ = await queue.enqueue(file, effects: settings)
        await queue.start(session: camera, directory: directory)
        let item = try await wait(queue)
        let reads = await camera.reads
        XCTAssertEqual(reads, 0)
        XCTAssertNil(item.frameError)
        XCTAssertNotNil(item.frameURL)
    }
    func testCropAndEffectsClockExcludesPendingPlaceLookup() async throws {
        let (_, directory, _) = try fixture()
        let clock = TransferParityClock()
        let probe = TransferParityPlaceProbe()
        let resolver = PhotoFramePlaceResolver { _, _, _ in await probe.lookup() }
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime),
            generationNow: { clock.read() },
            parseMetadata: { _ in PreparedPhotoMetadata(value: PhotoFrameMetadata(make: nil, model: nil, lensModel: nil, focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil, latitude: 35, longitude: 139), state: .complete) },
            placeResolver: resolver, placeAllowed: { true },
            renderCrop: { _, source, _, _ in clock.advance(200); return source },
            renderFrame: { source, _, _, _ in clock.advance(300); return source })
        let file = CameraFile(id: 2387500, storageID: 1, format: 0x3801, size: 10, fileName: "TIMING.JPG", captureDate: nil, isProtected: false)
        let crop = LosslessCropTask(fileID: file.id, recipe: JpegCropRecipe(
            source: JpegCropSource(width: 16, height: 16, mcuWidth: 16, mcuHeight: 16, orientation: 1),
            rect: .init(left: 0, top: 0, right: 16, bottom: 16)))
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true; effects.photoFrameBorderEnabled = true
        var metadata = effects.metadata; metadata.showCity = true; effects.metadata = metadata
        _ = await queue.enqueueCrop(file, task: crop, storageMode: .unified, effects: effects)
        await queue.start(session: TransferParityCaptureCamera(), directory: directory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !probe.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let started = await probe.started
        XCTAssertTrue(started)
        let waiting = await queue.snapshot()
        XCTAssertTrue(waiting.items[0].isGeneratingFrame)
        XCTAssertNil(waiting.items[0].frameGenerationStartedAtElapsedMs)
        XCTAssertNil(waiting.items[0].cropURL)
        clock.advance(10_000)
        await probe.release()
        let result = try await wait(queue)
        XCTAssertNotNil(result.cropURL)
        XCTAssertNotNil(result.frameURL)
        XCTAssertNil(result.frameError)
        XCTAssertEqual(result.frameGenerationElapsedMs, 500)
        await queue.closePhotoGeneration()
    }

    func testPlaceLookupYieldsComputeToAnUnrelatedReadyRender() async throws {
        for ending in ["complete", "cancel", "disable"] {
            let (_, directory, _) = try fixture()
            let probe = TransferParityPlaceProbe()
            let resolver = PhotoFramePlaceResolver { _, _, _ in await probe.lookup() }
            let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime),
                parseMetadata: { _ in PreparedPhotoMetadata(value: PhotoFrameMetadata(make: nil, model: nil, lensModel: nil, focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil, latitude: 35, longitude: 139), state: .complete) },
                placeResolver: resolver, placeAllowed: { true },
                renderFrame: { source, _, _, _ in await probe.render(source) })
            let camera = TransferParityCaptureCamera()
            let first = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10, fileName: "PLACE.JPG", captureDate: nil, isProtected: false)
            let second = CameraFile(id: 2, storageID: 1, format: 0x3801, size: 10, fileName: "PLAIN.JPG", captureDate: nil, isProtected: false)
            var place = PhotoEffectsSettings()
            place.photoFrameEnabled = true; place.photoFrameBorderEnabled = true
            place.metadata = PhotoFrameMetadataSettings(showDate: false, showTime: false, showFocalLength: false, showExposure: false, showBrand: false, showModel: false, showLensModel: false, showCoordinates: false, showAltitude: false, datePattern: "yyyy-MM-dd", timePattern: "HH:mm:ss", showCity: true)
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
                if state.items.count == 2, state.items[1].frameURL != nil, !state.isTransferring { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await Task.sleep(for: .milliseconds(50))
            let before = await probe.rendered
            XCTAssertEqual(before, ["PLAIN.JPG"], "Place preparation must not hold the compute slot")
            if ending == "cancel" { await queue.closePhotoGeneration() }
            if ending == "disable" { await queue.setPhotoEffectsEnabled(false) }
            await probe.release()
            while ContinuousClock.now < deadline {
                let snapshot = await queue.snapshot()
                if snapshot.items.allSatisfy({ !$0.isGeneratingFrame }), await queue.pendingMetadataPreparationCount == 0 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let after = await probe.rendered
            XCTAssertEqual(after, ending == "complete" ? ["PLAIN.JPG", "PLACE.JPG"] : ["PLAIN.JPG"])
            let final = await queue.snapshot()
            XCTAssertTrue(final.items.allSatisfy { !$0.isGeneratingFrame })
            XCTAssertEqual(final.items[0].frameURL != nil, ending == "complete")
            await queue.closePhotoGeneration()
        }
    }
}

private actor TransferParityMetadataCamera: TransferDownloading {
    private(set) var reads = 0
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        throw CameraTransportError.unavailable
    }
    func frameMetadataHeader(file: CameraFile) async throws -> Data? {
        reads += 1
        return Data([0xff, 0xd8, 0xff, 0xd9]) // Valid JPEG structure with no EXIF.
    }
}

private actor TransferParityPlaceProbe {
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

private actor TransferParityCaptureCamera: TransferDownloading {
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

private final class TransferParityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func read() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ amount: Int64) { lock.lock(); defer { lock.unlock() }; value += amount }
}
