import XCTest
import UIKit
import ImageIO
@testable import ZTransfer

final class PhotoMetadataHeaderStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func files(_ directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func testMemoryOverflowSpoolBudgetAndActiveOwnershipAfterClose() async throws {
        let root = try directory()
        let store = PhotoMetadataHeaderStore(directory: root, memoryLimit: 4, diskLimit: 4)
        var memory: PhotoMetadataHeaderStore.Header? = try await store.retain(Data([1,2,3,4]))
        var disk: PhotoMetadataHeaderStore.Header? = try await store.retain(Data([5,6,7,8]))
        XCTAssertEqual(store.usage, .init(memoryBytes: 4, diskBytes: 4))
        let refused = try await store.retain(Data([9]))
        XCTAssertNil(refused)
        XCTAssertEqual(files(root).count, 1)
        store.close(); store.close()
        XCTAssertEqual(try memory?.read(), Data([1,2,3,4]))
        XCTAssertEqual(try disk?.read(), Data([5,6,7,8]))
        let closed = try await store.retain(Data())
        XCTAssertNil(closed)
        memory = nil; disk = nil
        XCTAssertEqual(store.usage, .init(memoryBytes: 0, diskBytes: 0))
        XCTAssertTrue(files(root).isEmpty)
    }

    func testDefaultBudgetsAreTwoMiBMemoryAndSixteenMiBDisk() async throws {
        let root = try directory()
        let store = PhotoMetadataHeaderStore(directory: root)
        var memory: PhotoMetadataHeaderStore.Header? = try await store.retain(Data(repeating: 1, count: 2 * 1024 * 1024))
        var disk: PhotoMetadataHeaderStore.Header? = try await store.retain(Data(repeating: 2, count: 16 * 1024 * 1024))
        XCTAssertNotNil(memory); XCTAssertNotNil(disk)
        XCTAssertEqual(store.usage, .init(memoryBytes: 2 * 1024 * 1024, diskBytes: 16 * 1024 * 1024))
        let refused = try await store.retain(Data([3]))
        XCTAssertNil(refused)
        memory = nil; disk = nil
        store.close()
        XCTAssertEqual(store.usage, .init(memoryBytes: 0, diskBytes: 0))
        XCTAssertTrue(files(root).isEmpty)
    }

    func testSpoolFailureReleasesReservationAndCanRetry() async throws {
        let root = try directory().appendingPathComponent("blocked")
        try Data([1]).write(to: root)
        let store = PhotoMetadataHeaderStore(directory: root, memoryLimit: 0, diskLimit: 4)
        do { _ = try await store.retain(Data([1,2,3,4])); XCTFail("Expected filesystem error") }
        catch { }
        XCTAssertEqual(store.usage, .init(memoryBytes: 0, diskBytes: 0))
        try FileManager.default.removeItem(at: root)
        var recovered: PhotoMetadataHeaderStore.Header? = try await store.retain(Data([1,2,3,4]))
        XCTAssertEqual(try recovered?.read(), Data([1,2,3,4]))
        recovered = nil
        XCTAssertEqual(store.usage.diskBytes, 0)
        store.close()
    }

    func testOldProcessCleanupPreservesAnotherLiveQueue() async throws {
        let root = try directory()
        let old = root.appendingPathComponent("previous-process")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data([0]).write(to: old.appendingPathComponent("old.header"))
        let first = PhotoMetadataHeaderStore(directory: root, memoryLimit: 0, diskLimit: 4)
        var firstHeader: PhotoMetadataHeaderStore.Header? = try await first.retain(Data([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        let second = PhotoMetadataHeaderStore(directory: root, memoryLimit: 0, diskLimit: 4)
        var secondHeader: PhotoMetadataHeaderStore.Header? = try await second.retain(Data([2]))
        XCTAssertEqual(files(root).count, 2)
        XCTAssertEqual(try firstHeader?.read(), Data([1]))
        XCTAssertEqual(try secondHeader?.read(), Data([2]))
        first.close(); second.close()
        firstHeader = nil; secondHeader = nil
        XCTAssertTrue(files(root).isEmpty)
    }
}

private actor MetadataTestLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}

private actor CapturedHeaderTestCamera: TransferDownloading {
    let header: Data
    let supplementalResult: Data?
    let readRelease = MetadataTestLatch()
    private(set) var reads = 0
    init(header: Data, supplementalResult: Data? = nil) { self.header = header; self.supplementalResult = supplementalResult }
    func photoMetadataIdentity() async -> PhotoMetadataCameraIdentity? {
        PhotoMetadataCameraIdentity(cacheIdentity: "Nikon\u{0}Z 30\u{0}pipeline-camera", session: "pipeline-session")
    }
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) throws -> URL {
        let output = directory.appendingPathComponent(file.fileName)
        try Data(repeating: 4, count: Int(file.size)).write(to: output)
        return output
    }
    func downloadResult(file: CameraFile, to directory: URL, captureHeader: Bool,
                        progress: (@Sendable (TransferDownloadProgress) -> Void)?) throws -> CameraDownloadResult {
        let output = try download(file: file, to: directory, progress: nil)
        return CameraDownloadResult(url: output, bytes: file.size, transferredBytes: file.size,
            startedAt: .now, headerPrefix: captureHeader ? header : nil)
    }
    func frameMetadataHeader(file: CameraFile, expectedSource: PhotoMetadataCameraIdentity?) async throws -> Data? {
        let identity = await photoMetadataIdentity()
        guard expectedSource?.camera == identity?.camera else { return nil }
        return try await frameMetadataHeader(file: file)
    }
    func frameMetadataHeader(file: CameraFile) async throws -> Data? {
        reads += 1
        await readRelease.wait()
        return supplementalResult // A nil FAILED result is deliberately not cached.
    }
}

private actor HoldingMetadataParser {
    let release = MetadataTestLatch()
    private(set) var calls = 0
    func parse(_ header: PhotoMetadataHeaderStore.Header) async throws -> PreparedPhotoMetadata {
        calls += 1
        await release.wait()
        return PreparedPhotoMetadata.parse(try header.read())
    }
}

private actor SharedMetadataRenderProbe {
    private(set) var calls = 0
    func render(_ source: URL, metadata: PhotoFrameMetadata?) throws -> URL {
        XCTAssertEqual(metadata?.model, "Metadata test")
        calls += 1
        if calls == 1 { throw CocoaError(.fileWriteUnknown) }
        return source
    }
}

@MainActor
final class PhotoMetadataPipelineTests: XCTestCase {
    func testPhotoExifFormattingMatchesAndroidAndFrameMetadata() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        for (seconds, shutter) in [(0.4, "1/3"), (0.5, "1/2"), (0.8, "1/1"), (1.0, "1.0s")] {
            for (fNumber, aperture) in [(1.98, "f/2.0"), (2.0, "f/2"), (2.02, "f/2")] {
              for dateSource in 0..<2 {
                let original = dateSource == 0 ? "2026:10:16 12:00:00" : "   "
                let digitized = dateSource == 1 ? "2026:10:16 12:00:00" : "   "
                let expectedDate = "2026:10:16 12:00:00"
                let lens = dateSource == 0 ? "  NIKKOR Z 50mm  " : "   "
                let expectedLens: String? = dateSource == 0 ? "NIKKOR Z 50mm" : nil
                let bytes = NSMutableData()
                let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
                    kCGImagePropertyExifDictionary: [
                        kCGImagePropertyExifExposureTime: seconds,
                        kCGImagePropertyExifFNumber: fNumber,
                        kCGImagePropertyExifDateTimeOriginal: original,
                        kCGImagePropertyExifDateTimeDigitized: digitized,
                        kCGImagePropertyExifLensModel: lens
                    ],
                    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2026:10:15 12:00:00"]
                ] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                let exif = try XCTUnwrap(PhotoExifParser.parse(bytes as Data))
                XCTAssertEqual(exif.shutterSpeed, shutter)
                XCTAssertEqual(exif.aperture, aperture)
                XCTAssertEqual(exif.dateTime, expectedDate)
                XCTAssertEqual(exif.lensModel, expectedLens)
                let header = bytes as Data
                let stored = try await PhotoExifStore().load(file: file(1)) { _ in header }
                XCTAssertEqual(stored, exif)
                let prepared = PreparedPhotoMetadata.parse(header)
                XCTAssertEqual(prepared.state, .complete)
                let metadata = try XCTUnwrap(prepared.value)
                XCTAssertEqual(metadata.shutter, shutter)
                XCTAssertEqual(metadata.aperture, aperture)
                XCTAssertEqual(metadata.dateTime, exif.dateTime)
                XCTAssertEqual(metadata.lensModel, expectedLens)
              }
            }
        }
    }

    func testExifDateFallsBackToTIFFThroughBothConsumers() async throws {
        // Construct little-endian EXIF IFDs explicitly so the fixture's
        // standalone TIFF date does not depend on ImageIO's writer.
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) -> Data {
            staInteger(tag) + staInteger(type) + staInteger(count) + staInteger(value)
        }
        let date = "2026:10:15 12:00:00"
        var tiff = Data([0x49, 0x49, 42, 0]) + staInteger(UInt32(8))
        tiff.append(staInteger(UInt16(2)))
        tiff.append(entry(0x0132, 2, 20, 38))
        tiff.append(entry(0x8769, 4, 1, 58))
        tiff.append(staInteger(UInt32(0)))
        tiff.append(Data(date.utf8) + Data([0]))
        tiff.append(staInteger(UInt16(2)))
        tiff.append(entry(0x9003, 2, 20, 88))
        tiff.append(entry(0x9004, 2, 20, 108))
        tiff.append(staInteger(UInt32(0)))
        for _ in 0..<2 { tiff.append(Data(repeating: 32, count: 19) + Data([0])) }
        XCTAssertEqual(tiff.count, 128)
        let payload = Data([69, 120, 105, 102, 0, 0]) + tiff
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 1))
        // UIKit may emit its own APP1. Remove it so a second metadata block
        // cannot override the deliberately constructed fixture.
        var body = Data()
        var offset = 2
        while offset + 3 < jpeg.count {
            let marker = jpeg[offset + 1]
            if marker == 0xda { body.append(jpeg[offset...]); break }
            let length = Int(jpeg[offset + 2]) * 256 + Int(jpeg[offset + 3])
            guard length >= 2, offset + 2 + length <= jpeg.count else { throw CocoaError(.fileReadCorruptFile) }
            if marker != 0xe1 { body.append(jpeg[offset..<(offset + 2 + length)]) }
            offset += 2 + length
        }
        let header = Data([255, 216, 255, 225, 0, UInt8(payload.count + 2)]) + payload + body
        // Assert the raw IFD date, rather than requiring ImageIO to expose it
        // in a particular dictionary (it may instead normalize it to metadata).
        XCTAssertEqual(String(data: tiff[38..<57], encoding: .ascii), date)
        let stored = try await PhotoExifStore().load(file: file(1)) { _ in header }
        XCTAssertEqual(stored?.dateTime, date)
        let prepared = PreparedPhotoMetadata.parse(header)
        XCTAssertEqual(prepared.state, .complete)
        XCTAssertEqual(prepared.value?.dateTime, date)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func file(_ id: UInt32) -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 10,
            fileName: "DSC_\(id).JPG", captureDate: "20261016T000000", isProtected: false)
    }
    private func jpeg() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage),
            [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Metadata test"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out"); throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testBlockedParserDoesNotBlockDownloadsAndBudgetFailureKeepsOriginal() async throws {
        let root = try directory(), header = try jpeg()
        let store = PhotoMetadataHeaderStore(directory: root.appendingPathComponent("spool"),
            memoryLimit: header.count, diskLimit: header.count)
        let parser = HoldingMetadataParser()
        let camera = CapturedHeaderTestCamera(header: header)
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), metadataHeaderStore: store,
            parseMetadata: { try await parser.parse($0) }, renderFrame: { source, _, _, metadata in
                XCTAssertEqual(metadata?.model, "Metadata test"); return source
            })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue([file(1), file(2), file(3)], effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait {
            let snapshot = await queue.snapshot()
            return !snapshot.isTransferring && snapshot.items.allSatisfy { $0.status == .completed }
        }
        try await wait { await parser.calls == 1 }
        // Original downloads finish before the independent metadata admission
        // consumer reports the third item's exhausted header budget.
        try await wait { await queue.snapshot().items.first(where: { $0.file.id == 3 })?.frameError != nil }
        XCTAssertEqual(store.usage, .init(memoryBytes: header.count, diskBytes: header.count))
        let blocked = await queue.snapshot()
        XCTAssertEqual(blocked.items.filter(\.isGeneratingFrame).count, 2)
        XCTAssertNotNil(blocked.items.first(where: { $0.file.id == 3 })?.frameError)
        await parser.release.open()
        try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
        try await wait { store.usage == .init(memoryBytes: 0, diskBytes: 0) }
        let completed = await queue.snapshot()
        XCTAssertEqual(completed.items.filter { $0.frameURL != nil }.count, 2)
        XCTAssertTrue(completed.items.allSatisfy { $0.outputURL != nil })
        await queue.closePhotoGeneration()
    }

    func testCloseDropsPendingSpoolButRetainsActiveParserUntilItReturns() async throws {
        let root = try directory(), header = try jpeg()
        let store = PhotoMetadataHeaderStore(directory: root.appendingPathComponent("spool"),
            memoryLimit: 0, diskLimit: header.count * 2)
        let parser = HoldingMetadataParser()
        let camera = CapturedHeaderTestCamera(header: header)
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), metadataHeaderStore: store,
            parseMetadata: { try await parser.parse($0) }, renderFrame: { source, _, _, _ in
                XCTFail("Closed preparation must not render"); return source
            })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue([file(1), file(2)], effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait { await parser.calls == 1 }
        try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.allSatisfy(\.metadataSourceBound) }
        await queue.closePhotoGeneration()
        try await wait { store.usage.diskBytes == header.count }
        let closed = await queue.snapshot()
        XCTAssertTrue(closed.items.allSatisfy { !$0.isGeneratingFrame && $0.outputURL != nil })
        await parser.release.open()
        try await wait { store.usage.diskBytes == 0 }
        let final = await queue.snapshot()
        XCTAssertTrue(final.items.allSatisfy { $0.frameURL == nil })
    }

    func testOneFailedRenderDoesNotLoseAnotherSharedPreparationWaiter() async throws {
        let root = try directory(), header = try jpeg(), original = file(1)
        try Data(repeating: 4, count: 10).write(to: root.appendingPathComponent(original.fileName))
        let camera = CapturedHeaderTestCamera(header: header, supplementalResult: header)
        let renderer = SharedMetadataRenderProbe()
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), renderFrame: { source, _, _, metadata in
            try await renderer.render(source, metadata: metadata)
        })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue(original, effects: effects)
        await queue.enqueue(original, effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.count == 2 && s.items.allSatisfy(\.metadataSourceBound) }
        await camera.readRelease.open()
        try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
        let result = await queue.snapshot()
        XCTAssertEqual(result.items.filter { $0.frameError != nil }.count, 1)
        XCTAssertEqual(result.items.filter { $0.frameURL != nil }.count, 1)
        let reads = await camera.reads
        let renders = await renderer.calls
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(renders, 2)
        await queue.closePhotoGeneration()
    }

    func testDuplicatePendingRequestsShareFailedReadWithoutCachingFailure() async throws {
        let root = try directory(), header = try jpeg(), original = file(1)
        try Data(repeating: 4, count: 10).write(to: root.appendingPathComponent(original.fileName))
        let camera = CapturedHeaderTestCamera(header: header)
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), renderFrame: { source, _, _, _ in
            XCTFail("Missing metadata must not render"); return source
        })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue(original, effects: effects)
        await queue.enqueue(original, effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.count == 2 && s.items.allSatisfy(\.metadataSourceBound) }
        let reads = await camera.reads
        XCTAssertEqual(reads, 1)
        await camera.readRelease.open()
        try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
        let failed = await queue.snapshot()
        XCTAssertTrue(failed.items.allSatisfy { $0.frameError != nil })
        let finalReads = await camera.reads
        XCTAssertEqual(finalReads, 1)
        let id = try XCTUnwrap(failed.items.first?.id)
        _ = await queue.retry(id: id)
        try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame && $0.status != .waiting } }
        let retriedReads = await camera.reads
        XCTAssertEqual(retriedReads, 2)
        await queue.closePhotoGeneration()
    }
}

private final class GenerationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_000
    func now() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ milliseconds: Int64) { lock.lock(); value += milliseconds; lock.unlock() }
}

private actor TimedGenerationRenderer {
    let releases = [MetadataTestLatch(), MetadataTestLatch()]
    private(set) var calls = 0
    func render(_ source: URL) async -> URL {
        let index = calls; calls += 1
        await releases[index].wait()
        return source
    }
    func release(_ index: Int) async { await releases[index].open() }
}

extension PhotoMetadataPipelineTests {
    func testFiveSecondsPreparationThenHalfSecondRenderRecordsOnlyHalfSecond() async throws {
        let root = try directory(), header = try jpeg()
        let clock = GenerationTestClock(), parser = HoldingMetadataParser(), renderer = TimedGenerationRenderer()
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), generationNow: clock.now,
            parseMetadata: { try await parser.parse($0) }, renderFrame: { source, _, _, _ in await renderer.render(source) })
        let camera = CapturedHeaderTestCamera(header: header)
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue(file(1), effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait { await parser.calls == 1 }
        clock.advance(5_000)
        let preparing = await queue.snapshot()
        XCTAssertNil(preparing.items.first?.frameGenerationStartedAtElapsedMs)
        XCTAssertNil(preparing.items.first?.displayedFrameGenerationElapsedMs(now: clock.now()))
        await parser.release.open()
        try await wait { await renderer.calls == 1 }
        clock.advance(250)
        let running = await queue.snapshot()
        XCTAssertEqual(running.items.first?.displayedFrameGenerationElapsedMs(now: clock.now()), 250)
        clock.advance(250)
        await renderer.release(0)
        try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
        let finished = await queue.snapshot()
        XCTAssertEqual(finished.items.first?.frameGenerationElapsedMs, 500)
        await queue.closePhotoGeneration()
    }

    func testSecondRenderDoesNotCountFirstWorkersFiveSeconds() async throws {
        let root = try directory(), header = try jpeg()
        let clock = GenerationTestClock(), renderer = TimedGenerationRenderer()
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), generationNow: clock.now,
            renderFrame: { source, _, _, _ in await renderer.render(source) })
        let camera = CapturedHeaderTestCamera(header: header)
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue([file(1), file(2)], effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait { await renderer.calls == 1 }
        try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.allSatisfy(\.metadataSourceBound) }
        clock.advance(5_000)
        let waiting = await queue.snapshot()
        XCTAssertNil(waiting.items.first(where: { $0.file.id == 2 })?.frameGenerationStartedAtElapsedMs)
        await renderer.release(0)
        try await wait { await renderer.calls == 2 }
        clock.advance(500)
        await renderer.release(1)
        try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
        let final = await queue.snapshot()
        XCTAssertEqual(final.items.first(where: { $0.file.id == 1 })?.frameGenerationElapsedMs, 5_000)
        XCTAssertEqual(final.items.first(where: { $0.file.id == 2 })?.frameGenerationElapsedMs, 500)
        await queue.closePhotoGeneration()
    }

    func testFailureAndWorkerTimeExistingOutputHaveNoCompletedGenerationDuration() async throws {
        for existing in [false, true] {
            let root = try directory(), header = try jpeg()
            let clock = GenerationTestClock(), parser = HoldingMetadataParser()
            let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), generationNow: clock.now,
                parseMetadata: { try await parser.parse($0) }, renderFrame: { _, _, _, _ in
                    XCTAssertFalse(existing)
                    clock.advance(500)
                    throw CocoaError(.fileWriteUnknown)
                })
            let camera = CapturedHeaderTestCamera(header: header)
            var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
            let original = file(1)
            await queue.enqueue(original, effects: effects)
            await queue.start(session: camera, directory: root)
            try await wait { await parser.calls == 1 }
            if existing {
                let folder = root.appendingPathComponent("ZTFrames")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let effective = effectivePhotoEffectsSettings(effects, isPro: true)
                try Data([1]).write(to: folder.appendingPathComponent(androidPhotoFrameOutputName(sourceName: original.fileName, settings: effective)))
            }
            await parser.release.open()
            try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
            let final = await queue.snapshot()
            XCTAssertNil(final.items.first?.frameGenerationElapsedMs)
            XCTAssertEqual(final.items.first?.frameURL != nil, existing)
            XCTAssertEqual(final.items.first?.frameError != nil, !existing)
            await queue.closePhotoGeneration()
        }
    }
}

private actor HoldingCropRenderer {
    let release = MetadataTestLatch()
    private(set) var calls = 0
    func render(_ source: URL, directory: URL) async throws -> URL {
        calls += 1
        await release.wait()
        let output = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".crop.JPG")
        try Data(contentsOf: source).write(to: output)
        return output
    }
}

extension PhotoMetadataPipelineTests {
    private func cropRecipe(_ file: CameraFile) -> LosslessCropTask {
        LosslessCropTask(fileID: file.id, recipe: JpegCropRecipe(
            source: JpegCropSource(width: 16, height: 16, mcuWidth: 16, mcuHeight: 16, orientation: 1),
            rect: .init(left: 0, top: 0, right: 16, bottom: 16)))
    }

    func testAllOriginalPathsContinueSecondDownloadWhileCropIsBlocked() async throws {
        for route in ["local", "partial", "download"] {
            let root = try directory(), header = try jpeg()
            let first: CameraFile
            if route == "partial" {
                // Only videos can legitimately reach complete-part recovery.
                // Inject the crop renderer to exercise this queue branch without
                // weakening the production JPEG-only/no-photo-resume policy.
                first = CameraFile(id: 1, storageID: 1, format: 0x300d, size: 10,
                    fileName: "DSC_1.MOV", captureDate: "20261016T000000", isProtected: false)
                try Data(repeating: 4, count: 10).write(to: root.appendingPathComponent(
                    transferPartialFileName(size: first.size, captureDate: first.captureDate, fileName: first.fileName)))
            } else {
                first = file(1)
                if route == "local" { try Data(repeating: 4, count: 10).write(to: root.appendingPathComponent(first.fileName)) }
            }
            let crop = HoldingCropRenderer(), clock = GenerationTestClock()
            let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), generationNow: clock.now,
                renderCrop: { _, source, directory in try await crop.render(source, directory: directory) })
            let camera = CapturedHeaderTestCamera(header: header)
            await queue.enqueueCrop(first, task: cropRecipe(first))
            await queue.enqueue(file(2))
            await queue.start(session: camera, directory: root)
            try await wait { await crop.calls == 1 }
            try await wait {
                let s = await queue.snapshot()
                return !s.isTransferring && s.items.count == 2 && s.items.allSatisfy { $0.status == .completed }
            }
            let before = await queue.snapshot()
            let original = try XCTUnwrap(before.items.first)
            XCTAssertTrue(original.isGeneratingFrame)
            XCTAssertNotNil(original.outputURL)
            XCTAssertNil(original.cropURL)
            XCTAssertNotNil(before.items.last?.outputURL)
            if route == "download" { XCTAssertNotNil(original.elapsedMs) }
            else { XCTAssertNil(original.elapsedMs); XCTAssertEqual(original.downloadMBps, 0) }
            clock.advance(5_000)
            await crop.release.open()
            try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
            let after = await queue.snapshot()
            XCTAssertEqual(after.items.first?.elapsedMs, original.elapsedMs)
            XCTAssertEqual(after.items.first?.downloadMBps, original.downloadMBps)
            XCTAssertEqual(after.items.first?.frameGenerationElapsedMs, 5_000)
            XCTAssertNotNil(after.items.first?.cropURL)
            XCTAssertNil(after.items.first?.frameURL)
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(original.outputURL)), Data(repeating: 4, count: 10))
            await queue.closePhotoGeneration()
        }
    }

    func testCropWaitsForMetadataThenAccumulatesCropAndEffectTime() async throws {
        let root = try directory(), header = try jpeg(), first = file(1)
        try Data(repeating: 4, count: 10).write(to: root.appendingPathComponent(first.fileName))
        let camera = CapturedHeaderTestCamera(header: header, supplementalResult: header)
        let crop = HoldingCropRenderer(), clock = GenerationTestClock()
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), generationNow: clock.now,
            renderCrop: { _, source, directory in try await crop.render(source, directory: directory) },
            renderFrame: { source, _, _, metadata in
                XCTAssertTrue(source.lastPathComponent.hasSuffix(".crop.JPG"))
                XCTAssertEqual(metadata?.model, "Metadata test")
                clock.advance(300)
                return source
            })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueueCrop(first, task: cropRecipe(first), effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait { await camera.reads == 1 }
        let prematureCrops = await crop.calls
        XCTAssertEqual(prematureCrops, 0)
        clock.advance(5_000)
        let waiting = await queue.snapshot()
        XCTAssertNil(waiting.items.first?.frameGenerationStartedAtElapsedMs)
        await camera.readRelease.open()
        try await wait { await crop.calls == 1 }
        clock.advance(200)
        await crop.release.open()
        try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
        let finished = await queue.snapshot()
        XCTAssertEqual(finished.items.first?.frameGenerationElapsedMs, 500)
        XCTAssertNotNil(finished.items.first?.cropURL)
        XCTAssertNotNil(finished.items.first?.frameURL)
        await queue.closePhotoGeneration()
    }

    func testEffectFailureRetryReusesPublishedCropWithoutRepeatingCrop() async throws {
        let root = try directory(), header = try jpeg(), first = file(1)
        try Data(repeating: 4, count: 10).write(to: root.appendingPathComponent(first.fileName))
        let camera = CapturedHeaderTestCamera(header: header, supplementalResult: header)
        let crop = HoldingCropRenderer(), renderer = SharedMetadataRenderProbe()
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime),
            renderCrop: { _, source, directory in try await crop.render(source, directory: directory) },
            renderFrame: { source, _, _, metadata in try await renderer.render(source, metadata: metadata) })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueueCrop(first, task: cropRecipe(first), effects: effects)
        await camera.readRelease.open(); await crop.release.open()
        await queue.start(session: camera, directory: root)
        try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.first?.frameError != nil && s.items.first?.isGeneratingFrame == false }
        let failed = await queue.snapshot()
        let task = try XCTUnwrap(failed.items.first)
        XCTAssertEqual(task.status, .completed)
        let saved = try XCTUnwrap(task.cropURL)
        XCTAssertNotNil(task.frameGenerationElapsedMs) // A crop was actually saved, despite the effect failure.
        let replacement = await queue.retry(id: task.id)
        XCTAssertNotNil(replacement)
        try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.first?.frameURL != nil && s.items.first?.isGeneratingFrame == false }
        let finished = await queue.snapshot()
        XCTAssertEqual(finished.items.first?.cropURL, saved)
        let crops = await crop.calls
        XCTAssertEqual(crops, 1)
        await queue.closePhotoGeneration()
    }
}

extension PhotoMetadataPipelineTests {
    func testCropAndPlainEffectShareOneComputeSlot() async throws {
        let root = try directory(), header = try jpeg(), first = file(1)
        let camera = CapturedHeaderTestCamera(header: header)
        let crop = HoldingCropRenderer(), renderer = TimedGenerationRenderer(), clock = GenerationTestClock()
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), generationNow: clock.now,
            renderCrop: { _, source, directory in try await crop.render(source, directory: directory) },
            renderFrame: { source, _, _, _ in await renderer.render(source) })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueueCrop(first, task: cropRecipe(first))
        await queue.enqueue(file(2), effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait { await crop.calls == 1 }
        try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.last?.sourceMetadataSnapshot != nil }
        let concurrentRenders = await renderer.calls
        XCTAssertEqual(concurrentRenders, 0)
        clock.advance(200)
        await crop.release.open()
        try await wait { await renderer.calls == 1 }
        clock.advance(300)
        await renderer.release(0)
        try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
        let finished = await queue.snapshot()
        XCTAssertEqual(finished.items.first?.frameGenerationElapsedMs, 200)
        XCTAssertEqual(finished.items.last?.frameGenerationElapsedMs, 300)
        await queue.closePhotoGeneration()
    }

    func testClosingGenerationPreservesActiveCropPublicationAndDropsWaitingCrop() async throws {
        let root = try directory(), header = try jpeg()
        let camera = CapturedHeaderTestCamera(header: header), crop = HoldingCropRenderer()
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime),
            renderCrop: { _, source, directory in try await crop.render(source, directory: directory) })
        for original in [file(1), file(2)] { await queue.enqueueCrop(original, task: cropRecipe(original)) }
        await queue.start(session: camera, directory: root)
        try await wait { await crop.calls == 1 }
        try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.allSatisfy { $0.outputURL != nil } }
        await queue.closePhotoGeneration()
        let closing = await queue.snapshot()
        XCTAssertTrue(closing.items[0].isGeneratingFrame)
        XCTAssertFalse(closing.items[1].isGeneratingFrame)
        await crop.release.open()
        try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
        let closed = await queue.snapshot()
        XCTAssertNotNil(closed.items[0].cropURL)
        XCTAssertNil(closed.items[1].cropURL)
        XCTAssertTrue(closed.items.allSatisfy { $0.status == .completed && $0.outputURL != nil })
        let calls = await crop.calls
        XCTAssertEqual(calls, 1)
    }
}

extension PhotoMetadataPipelineTests {
    private func gateDefaultsName() -> String {
        let name = "PhotoEffectsGateTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return name
    }

    func testRuntimeSwitchSkipsOnlyWaitingWorkAndReenableRetainsRecipe() async throws {
        for reenable in [false, true] {
            let root = try directory(), header = try jpeg(), defaults = UserDefaults(suiteName: gateDefaultsName())!
            let camera = CapturedHeaderTestCamera(header: header), renderer = TimedGenerationRenderer()
            let queue = TransferQueue(defaults: defaults, premiumAccess: PremiumAccess(.lifetime),
                renderFrame: { source, _, _, _ in await renderer.render(source) })
            var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
            await queue.enqueue([file(1), file(2)], effects: effects)
            await queue.start(session: camera, directory: root)
            try await wait { await renderer.calls == 1 }
            try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.last?.sourceMetadataSnapshot != nil }
            let recipe = await queue.snapshot().items.last?.effects
            await queue.setPhotoEffectsEnabled(false)
            let active = await queue.snapshot()
            XCTAssertTrue(active.items.first?.isGeneratingFrame == true)
            XCTAssertFalse(active.items.first?.frameGenerationSkipped == true)
            if reenable { await queue.setPhotoEffectsEnabled(true) }
            await renderer.release(0)
            if reenable {
                try await wait { await renderer.calls == 2 }
                await renderer.release(1)
            }
            try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
            let completed = await queue.snapshot()
            XCTAssertNotNil(completed.items.first?.frameURL)
            XCTAssertEqual(completed.items.last?.frameGenerationSkipped, !reenable)
            XCTAssertEqual(completed.items.last?.frameURL != nil, reenable)
            XCTAssertEqual(completed.items.last?.effects, recipe)
            if !reenable { XCTAssertNil(completed.items.last?.frameGenerationElapsedMs) }
            await queue.closePhotoGeneration()
        }
    }

    func testDisabledGateStillSavesCropAndMarksOnlyEffectsSkipped() async throws {
        let root = try directory(), header = try jpeg(), first = file(1), defaults = UserDefaults(suiteName: gateDefaultsName())!
        defaults.set(false, forKey: "photo_effects_enabled")
        try Data(repeating: 4, count: 10).write(to: root.appendingPathComponent(first.fileName))
        let camera = CapturedHeaderTestCamera(header: header, supplementalResult: header)
        let crop = HoldingCropRenderer(), clock = GenerationTestClock()
        let queue = TransferQueue(defaults: defaults, premiumAccess: PremiumAccess(.lifetime), generationNow: clock.now,
            renderCrop: { _, source, directory in try await crop.render(source, directory: directory) },
            renderFrame: { source, _, _, _ in XCTFail("Disabled effects must not render"); return source })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueueCrop(first, task: cropRecipe(first), effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait { await crop.calls == 1 }
        clock.advance(200)
        await crop.release.open()
        try await wait { await queue.snapshot().items.first?.isGeneratingFrame == false }
        let completed = await queue.snapshot()
        XCTAssertNotNil(completed.items.first?.cropURL)
        XCTAssertNil(completed.items.first?.frameURL)
        XCTAssertEqual(completed.items.first?.cropEffectsSkipped, true)
        XCTAssertEqual(completed.items.first?.frameGenerationSkipped, false)
        XCTAssertEqual(completed.items.first?.frameGenerationElapsedMs, 200)
        await camera.readRelease.open()
        await queue.closePhotoGeneration()
    }

    func testEnablingDuringCropPausesForMetadataAndResumesWithoutRecropping() async throws {
        for closeWhileWaiting in [false, true] {
            let root = try directory(), header = try jpeg(), first = file(1), defaults = UserDefaults(suiteName: gateDefaultsName())!
            defaults.set(false, forKey: "photo_effects_enabled")
            try Data(repeating: 4, count: 10).write(to: root.appendingPathComponent(first.fileName))
            let camera = CapturedHeaderTestCamera(header: header, supplementalResult: header)
            let crop = HoldingCropRenderer(), clock = GenerationTestClock()
            let queue = TransferQueue(defaults: defaults, premiumAccess: PremiumAccess(.lifetime), generationNow: clock.now,
                renderCrop: { _, source, directory in try await crop.render(source, directory: directory) },
                renderFrame: { source, _, _, metadata in
                    XCTAssertFalse(closeWhileWaiting)
                    XCTAssertEqual(metadata?.model, "Metadata test")
                    clock.advance(300); return source
                })
            var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
            await queue.enqueueCrop(first, task: cropRecipe(first), effects: effects)
            await queue.start(session: camera, directory: root)
            try await wait { await crop.calls == 1 }
            try await wait { await camera.reads == 1 }
            await queue.setPhotoEffectsEnabled(true)
            clock.advance(200)
            await crop.release.open()
            try await wait {
                let task = await queue.snapshot().items.first
                return task?.cropURL != nil && task?.frameGenerationStartedAtElapsedMs == nil && task?.isGeneratingFrame == true
            }
            let paused = await queue.snapshot()
            XCTAssertEqual(paused.items.first?.frameGenerationAccumulatedMs, 200)
            XCTAssertNil(paused.items.first?.displayedFrameGenerationElapsedMs(now: clock.now()))
            clock.advance(5_000)
            if closeWhileWaiting { await queue.closePhotoGeneration() }
            await camera.readRelease.open()
            try await wait { await queue.snapshot().items.first?.isGeneratingFrame == false }
            let completed = await queue.snapshot()
            XCTAssertEqual(completed.items.first?.frameGenerationElapsedMs, closeWhileWaiting ? 200 : 500)
            XCTAssertEqual(completed.items.first?.frameURL != nil, !closeWhileWaiting)
            XCTAssertEqual(completed.items.first?.cropEffectsSkipped, false)
            let crops = await crop.calls
            XCTAssertEqual(crops, 1)
            await queue.closePhotoGeneration()
        }
    }

    func testSkippedComputationsCannotGrowBlockedPreparationPastCapacity() async throws {
        let root = try directory(), header = try jpeg(), defaults = UserDefaults(suiteName: gateDefaultsName())!
        for id: UInt32 in 1...4 { try Data(repeating: 4, count: 10).write(to: root.appendingPathComponent(file(id).fileName)) }
        let camera = CapturedHeaderTestCamera(header: header)
        let queue = TransferQueue(defaults: defaults, premiumAccess: PremiumAccess(.lifetime), generationCapacity: 2,
            renderFrame: { source, _, _, _ in XCTFail("All computations must skip"); return source })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue([file(1), file(2)], effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait { await queue.pendingMetadataPreparationCount == 2 }
        try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.allSatisfy(\.metadataSourceBound) }
        await queue.setPhotoEffectsEnabled(false)
        try await wait { await queue.snapshot().items.allSatisfy { !$0.isGeneratingFrame } }
        await queue.enqueue([file(3), file(4)], effects: effects)
        await queue.start(session: camera, directory: root)
        try await wait { let s = await queue.snapshot(); return !s.isTransferring && s.items.count == 4 && s.items.allSatisfy { !$0.isGeneratingFrame } }
        let count = await queue.pendingMetadataPreparationCount
        XCTAssertEqual(count, 2)
        let skipped = await queue.snapshot()
        XCTAssertTrue(skipped.items.allSatisfy(\.frameGenerationSkipped))
        await camera.readRelease.open()
        try await wait { await queue.pendingMetadataPreparationCount == 0 }
        await queue.closePhotoGeneration()
    }
}
