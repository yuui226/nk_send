import XCTest
import UIKit
import ImageIO
@testable import ZTransfer

@MainActor
final class CameraDownloadTests: XCTestCase {
    func testLargePhotoExportsOverlapStreamingDownloadAndPreserveSources() async throws {
        try await assertLargePhotoExportsOverlapDownload(cancelQueuedExport: false)
    }

    func testCancellingLargeExportDoesNotCancelOtherExportOrDownload() async throws {
        try await assertLargePhotoExportsOverlapDownload(cancelQueuedExport: true)
    }

    private func assertLargePhotoExportsOverlapDownload(cancelQueuedExport: Bool) async throws {
        let target = try directory()
        let original = try autoreleasepool {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
            }
            return try XCTUnwrap(image.pngData())
        }
        let first = target.appendingPathComponent("first.png"), second = target.appendingPathComponent("second.png")
        try original.write(to: first); try original.write(to: second)
        var settings = PhotoEffectsSettings()
        settings.photoFilterEnabled = true
        settings.selectedFilter = .init(preset: settings.orderedFilters[0], intensityPercent: 80)
        settings.photoFrameEnabled = true; settings.photoFramePreset = .minimal
        settings.watermark.enabled = false
        let recipe = settings
        let packet = Data(repeating: 0x5a, count: 1024 * 1024)
        let wire = DownloadReplay([.init(0x1009, [7], chunks: Array(repeating: packet, count: 64),
            declared: 64 * 1024 * 1024, chunkDelayNanoseconds: 50_000_000)])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let baseline = try previewTestPhysicalFootprint()
        let sampler = Task.detached(priority: .utility) { () throws -> (UInt64, Int) in
            var peak = baseline, samples = 0
            while !Task.isCancelled {
                peak = max(peak, try previewTestPhysicalFootprint()); samples += 1
                do { try await Task.sleep(for: .milliseconds(2)) } catch { break }
            }
            return (peak, samples)
        }
        defer { sampler.cancel() }
        let exportStarted = ProcessInfo.processInfo.systemUptime
        async let download = repository.downloadResult(handle: 7, size: 64 * 1024 * 1024, fileName: "incoming.JPG", to: target)
        async let local = LocalPhotoOutput.render(sourceURL: first, settings: recipe, availableMemory: { .max })
        let entered = expectation(description: "Queued export reached canvas budget")
        if !cancelQueuedExport {
            entered.fulfill()
            await fulfillment(of: [entered], timeout: 1)
        }
        let checkpoint = ExportBudgetCheckpoint(enabled: cancelQueuedExport, entered: entered)
        defer { checkpoint.release.signal() }
        let queued = Task {
            try await TransferQueue.renderFrameFile(source: second, settings: recipe,
                directory: target, metadata: .empty, availableMemory: { checkpoint.memory() })
        }
        defer { queued.cancel() }
        var queuedURL: URL?
        if cancelQueuedExport {
            await fulfillment(of: [entered], timeout: 5)
            for _ in 0..<100 {
                if await wire.firstChunkTime != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let activeChunk = await wire.firstChunkTime
            XCTAssertNotNil(activeChunk)
            queued.cancel(); checkpoint.release.signal()
            do { _ = try await queued.value; XCTFail("Cancelled export published output") }
            catch is CancellationError {}
        } else { queuedURL = try await queued.value }
        let localData = try await local
        let exportFinished = ProcessInfo.processInfo.systemUptime
        let downloaded = try await download
        sampler.cancel()
        let (peak, samples) = try await sampler.value
        let firstChunk = await wire.firstChunkTime, lastChunk = await wire.lastChunkTime
        XCTAssertLessThan(try XCTUnwrap(firstChunk), exportFinished)
        XCTAssertGreaterThan(try XCTUnwrap(lastChunk), exportStarted)
        XCTAssertEqual(downloaded.bytes, 64 * 1024 * 1024)
        let reader = try FileHandle(forReadingFrom: downloaded.url)
        defer { try? reader.close() }
        for _ in 0..<64 { XCTAssertEqual(try reader.read(upToCount: packet.count), packet) }
        XCTAssertTrue((try reader.read(upToCount: 1) ?? Data()).isEmpty)
        try autoreleasepool {
            let a = try XCTUnwrap(UIImage(data: localData))
            if let queuedURL {
                let b = try XCTUnwrap(UIImage(contentsOfFile: queuedURL.path))
                XCTAssertEqual(a.size, b.size)
            }
            XCTAssertGreaterThanOrEqual(a.size.width, 4000); XCTAssertGreaterThanOrEqual(a.size.height, 3000)
        }
        if cancelQueuedExport {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("ZTFrames").path))
        }
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), original)
        XCTAssertGreaterThan(samples, 100)
        print("F110 exports+64MiB download: cancelled=\(cancelQueuedExport) baseline=\(baseline) peak=\(peak) delta=\(peak-baseline) samples=\(samples) exportSeconds=\(exportFinished-exportStarted)")
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func file(size: UInt64 = 6) -> CameraFile {
        CameraFile(id: 7, storageID: 1, format: 0x3801, size: size,
                   fileName: "DSC_0007.JPG", captureDate: "20260914T120000", isProtected: false)
    }

    func testUSBAndVisibleWorkspaceStartWithFullObject() async throws {
        for usb in [true, false] {
            let wire = DownloadReplay([.init(0x1009, [7], chunks: [Data([1, 2]), Data([3, 4, 5, 6])], declared: 6)])
            let repository = CameraRepository(session: PTPSession(transport: wire), isUSBConnection: usb)
            if !usb { await repository.setPreferHighThroughputTransfers(true) }
            let output = try await repository.downloadResult(handle: 7, size: 6, fileName: "a.JPG", to: directory())
            XCTAssertEqual(try Data(contentsOf: output.url), Data([1, 2, 3, 4, 5, 6]))
            XCTAssertEqual(output.bytes, 6)
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testSTADirectReadKeepsPartialObjectEvenInHighThroughputWorkspace() async throws {
        let wire = DownloadReplay([
            .init(0x9431, [7, 0, 0, 6, 0], chunks: [Data(1...6)], declared: 6),
        ])
        let album = STAAlbumAccess(storageIDs: [1], prefetchedHandles: nil,
                                   directObjectRead: true, deviceInfo: nil)
        let repository = CameraRepository(session: PTPSession(transport: wire), staAlbum: album)
        await repository.setPreferHighThroughputTransfers(true)
        let result = try await repository.downloadResult(handle: 7, size: 6, fileName: "a.JPG", to: directory())
        XCTAssertEqual(try Data(contentsOf: result.url), Data(1...6))
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x9431])
    }

    func testSTAPhotosUseOneWholeImageRequestInEitherWorkspace() async throws {
        let packet = Data(repeating: 7, count: 1024 * 1024)
        for megabytes in [24, 120] {
            let size = UInt64(megabytes) * 1024 * 1024
            for throughput in [false, true] {
                let wire = DownloadReplay([
                    .init(0x9431, [7, 0, 0, UInt32(size), 0],
                          chunks: Array(repeating: packet, count: megabytes), declared: size)
                ])
                let album = STAAlbumAccess(storageIDs: [1], prefetchedHandles: nil,
                                           directObjectRead: true, deviceInfo: nil)
                let repository = CameraRepository(session: PTPSession(transport: wire), staAlbum: album)
                await repository.setPreferHighThroughputTransfers(throughput)
                let result = try await repository.downloadResult(handle: 7, size: size,
                                                                 fileName: "a.NEF", to: directory())
                XCTAssertEqual(result.bytes, size)
                XCTAssertEqual(try result.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(size))
                let commands = await wire.commands
                XCTAssertEqual(commands.map(\.code), [0x9431])
            }
        }
    }

    func testSTAPhotoShortDataPhaseFailsWithoutRequestingRemainder() async throws {
        let wire = DownloadReplay([.init(0x9431, [7, 0, 0, 6, 0], chunks: [Data([1, 2])], declared: 2)])
        let album = STAAlbumAccess(storageIDs: [1], prefetchedHandles: nil,
                                   directObjectRead: true, deviceInfo: nil)
        let repository = CameraRepository(session: PTPSession(transport: wire), staAlbum: album)
        let target = try directory()
        do {
            _ = try await repository.downloadResult(handle: 7, size: 6, fileName: "a.JPG", to: target)
            XCTFail("A photo must be complete in its single data transaction")
        } catch { XCTAssertEqual(error as? CameraDownloadError, .incomplete(received: 2, expected: 6)) }
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x9431])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testSTAPhotoAboveSingleRequestLimitFailsBeforeReadingObject() async throws {
        let size = UInt64(Int32.max) + 1
        for reportedSize in [size, UInt64(UInt32.max)] {
            let wire = DownloadReplay(reportedSize == size ? [] : [
                .init(0x9421, [7], chunks: [Data(size.littleEndianBytes)])
            ])
            let album = STAAlbumAccess(storageIDs: [1], prefetchedHandles: nil,
                                       directObjectRead: true, deviceInfo: nil)
            let repository = CameraRepository(session: PTPSession(transport: wire), staAlbum: album)
            let target = try directory()
            do {
                _ = try await repository.downloadResult(handle: 7, size: reportedSize, fileName: "a.NEF", to: target)
                XCTFail("The Android single-photo request limit must apply before sending file data commands")
            } catch {
                XCTAssertEqual(error as? CameraDownloadError, .photoExceedsSingleRequestLimit)
                XCTAssertEqual(error.localizedDescription, "Photo exceeds single-request size limit")
            }
            let commands = await wire.commands
            XCTAssertEqual(commands.map(\.code), reportedSize == size ? [] : [0x9421])
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }

    func testSTAPhotoUnsupportedEmptyPartialRetainsStreamingFullObjectFallback() async throws {
        let wire = DownloadReplay([
            .init(0x9431, [7, 0, 0, 6, 0], code: 0x2005),
            .init(0x1009, [7], chunks: [Data(1...6)], declared: 6)
        ])
        let album = STAAlbumAccess(storageIDs: [1], prefetchedHandles: nil,
                                   directObjectRead: true, deviceInfo: nil)
        let repository = CameraRepository(session: PTPSession(transport: wire), staAlbum: album)
        let result = try await repository.downloadResult(handle: 7, size: 6, fileName: "a.JPG", to: directory())
        XCTAssertEqual(try Data(contentsOf: result.url), Data(1...6))
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x9431, 0x1009])
    }

    func testOutputPreparationFailureDoesNotStartCameraSizeProbe() async throws {
        let wire = DownloadReplay([])
        let target = try directory().appendingPathComponent("missing", isDirectory: true)
        do {
            _ = try await CameraRepository(session: PTPSession(transport: wire))
                .downloadResult(handle: 7, size: 0, fileName: "a.JPG", to: target)
            XCTFail("Missing output directory must fail before camera I/O")
        } catch { XCTAssertTrue(error is CocoaError) }
        let commands = await wire.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testImageCaptureUSBUsesBoundedPartialRequestsAboveOneCallbackChunk() async throws {
        let tail = Data([3, 4])
        let wire = DownloadReplay([
            .init(0x9431, [7, 0, 0, UInt32(transferChunkSize), 0],
                  chunks: [Data(repeating: 1, count: Int(transferChunkSize))], declared: transferChunkSize),
            .init(0x9431, [7, UInt32(transferChunkSize), 0, 2, 0], chunks: [tail], declared: 2),
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
        let result = try await repository.downloadResult(handle: 7, size: transferChunkSize + 2,
                                                         fileName: "a.JPG", to: directory())
        XCTAssertEqual(result.bytes, transferChunkSize + 2)
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x9431, 0x9431])
    }

    func testBusyAloneDoesNotEnableHighThroughput() async throws {
        let wire = DownloadReplay([.init(0x9431, [7, 0, 0, 6, 0], chunks: [Data(repeating: 1, count: 6)], declared: 6)])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        await repository.setTransfersBusy(true)
        _ = try await repository.download(handle: 7, size: 6, fileName: "a.MP4", to: directory())
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testUnknownSizeNegativeReplyFallsBackToFullObject() async throws {
        for size in [UInt64(0), UInt64(UInt32.max)] {
            let wire = DownloadReplay([
                .init(0x9421, [7], code: 0x2005),
                .init(0x1009, [7], chunks: [Data([9, 8, 7])], declared: 3),
            ])
            let repository = CameraRepository(session: PTPSession(transport: wire))
            let result = try await repository.downloadResult(handle: 7, size: size, fileName: "a.JPG", to: directory())
            XCTAssertEqual(result.bytes, 3)
        }
    }

    func testImageCaptureUSBUnknownSizeUsesBoundedPartialUntilShortReply() async throws {
        let wire = DownloadReplay([
            .init(0x9421, [7], code: 0x2005),
            .init(0x9431, [7, 0, 0, UInt32(transferChunkSize), 0],
                  chunks: [Data([9, 8, 7])], declared: 3),
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
        let result = try await repository.downloadResult(handle: 7, size: UInt64(UInt32.max),
                                                         fileName: "a.JPG", to: directory())
        XCTAssertEqual(result.bytes, 3)
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x9421, 0x9431])
    }

    func testImageCaptureUSBUnknownSizeNeverFallsBackToUnboundedFullObject() async throws {
        let wire = DownloadReplay([
            .init(0x9421, [7], code: 0x2005),
            .init(0x9431, [7, 0, 0, UInt32(transferChunkSize), 0], code: 0x2005),
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
        do {
            _ = try await repository.downloadResult(handle: 7, size: 0,
                                                    fileName: "a.JPG", to: directory())
            XCTFail("Unknown ImageCapture object must not use an unbounded GetObject callback")
        } catch {
            XCTAssertEqual(error as? CameraRepositoryError, .resumeUnavailable)
        }
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x9421, 0x9431])
    }

    func testImageCaptureUSBLargeUnsupportedPartialNeverFallsBackForThisOrNextFile() async throws {
        let size: UInt64 = 2 * 1024 * 1024 * 1024
        let wire = DownloadReplay([
            .init(0x9431, [7, 0, 0, UInt32(transferChunkSize), 0], code: 0x2005),
            // After learning partial is unsupported, another large object
            // must fail before I/O, while a small full-object read stays valid.
            .init(0x1009, [9], chunks: [Data([3, 4])], declared: 2)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
        let target = try directory()
        for handle: UInt32 in [7, 8] {
            do {
                _ = try await repository.downloadResult(handle: handle, size: size,
                                                        fileName: "a\(handle).MP4", to: target)
                XCTFail("A known large ImageCapture object must never use a whole-object callback")
            } catch { XCTAssertEqual(error as? CameraRepositoryError, .resumeUnavailable) }
        }
        let result = try await repository.downloadResult(handle: 9, size: 2, fileName: "small.JPG", to: target)
        XCTAssertEqual(try Data(contentsOf: result.url), Data([3, 4]))
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x9431, 0x1009])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a7.MP4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a8.MP4").path))
    }

    func testUnknownSizeResolvedUsesPartialWithResolvedSize() async throws {
        let wire = DownloadReplay([
            .init(0x9421, [7], chunks: [Data(UInt64(6).littleEndianBytes)]),
            .init(0x9431, [7, 0, 0, 6, 0], chunks: [Data(repeating: 2, count: 6)], declared: 6),
        ])
        let result = try await CameraRepository(session: PTPSession(transport: wire))
            .downloadResult(handle: 7, size: UInt64(UInt32.max), fileName: "a.MP4", to: directory())
        XCTAssertEqual(result.bytes, 6)
    }

    func testShortCompletePartialAdvancesByReceivedBytes() async throws {
        let wire = DownloadReplay([
            .init(0x9431, [7, 0, 0, 6, 0], chunks: [Data([1, 2])], declared: 2),
            .init(0x9431, [7, 2, 0, 4, 0], chunks: [Data([3, 4, 5, 6])], declared: 4),
        ])
        let output = try await CameraRepository(session: PTPSession(transport: wire))
            .download(handle: 7, size: 6, fileName: "a.MP4", to: directory())
        XCTAssertEqual(try Data(contentsOf: output), Data([1, 2, 3, 4, 5, 6]))
    }

    func testUnsupportedEmptyPartialFallsBackAndCapabilityIsRemembered() async throws {
        let wire = DownloadReplay([
            .init(0x9431, [7, 0, 0, 6, 0], code: 0x2005),
            .init(0x1009, [7], chunks: [Data(repeating: 1, count: 6)], declared: 6),
            .init(0x1009, [8], chunks: [Data(repeating: 2, count: 6)], declared: 6),
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let target = try directory()
        _ = try await repository.download(handle: 7, size: 6, fileName: "a.MP4", to: target)
        _ = try await repository.download(handle: 8, size: 6, fileName: "b.MP4", to: target)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testPartialErrorAfterBytesNeverFallsBackAndPreservesPart() async throws {
        for code: UInt16 in [0x2005, 0x2019] {
            let wire = DownloadReplay([.init(0x9431, [7, 0, 0, 6, 0], code: code, chunks: [Data([1, 2])], declared: 2)])
            let repository = CameraRepository(session: PTPSession(transport: wire))
            let target = try directory()
            do { _ = try await repository.download(handle: 7, size: 6, fileName: "a.MP4", to: target); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? CameraDownloadError, .response(code)) }
            let part = target.appendingPathComponent(transferPartialFileName(size: 6, captureDate: nil, fileName: "a.MP4"))
            XCTAssertEqual(try Data(contentsOf: part), Data([1, 2]))
            let commands = await wire.commands
            XCTAssertEqual(commands.map(\.code), [0x9431])
        }
    }

    func testDeclaredLengthMismatchFailsAfterResponseAndKeepsSessionUsable() async throws {
        for usb in [false, true] {
            let wire = DownloadReplay([
                .init(usb ? 0x1009 : 0x9431, usb ? [7] : [7, 0, 0, 6, 0], chunks: [Data([1, 2])], declared: 6),
                .init(0x1004, []),
            ])
            let session = PTPSession(transport: wire)
            let repository = CameraRepository(session: session, isUSBConnection: usb)
            do { _ = try await repository.download(handle: 7, size: 6, fileName: "a.MP4", to: directory()); XCTFail("Expected short read") }
            catch { XCTAssertEqual(error as? CameraDownloadError, .incomplete(received: 2, expected: 6)) }
            _ = try await session.execute(operation: 0x1004)
        }
    }

    func testFullObjectChecksKnownSizeEvenWhenDataPhaseIsSelfConsistent() async throws {
        for usb in [false, true] {
            for reportedSize in [UInt64(6), UInt64(UInt32.max)] {
                for received in [3, 9] {
                    for declared: UInt64? in [UInt64(received), nil, 0, UInt64(UInt32.max)] {
                        var steps: [DownloadReplay.Step] = []
                        if reportedSize == UInt64(UInt32.max) {
                            steps.append(.init(0x9421, [7], chunks: [Data(UInt64(6).littleEndianBytes)]))
                        }
                        steps += [
                            .init(0x1009, [7], chunks: [Data(repeating: 1, count: received)], declared: declared),
                            .init(0x1004, [])
                        ]
                        let wire = DownloadReplay(steps)
                        let session = PTPSession(transport: wire)
                        let repository = CameraRepository(session: session, isUSBConnection: usb)
                        let target = try directory()
                        do {
                            _ = try await repository.downloadResult(handle: 7, size: reportedSize,
                                                                     fileName: "a.JPG", to: target)
                            XCTFail("A full object must match both reliable size sources")
                        } catch {
                            XCTAssertEqual(error as? CameraDownloadError,
                                           .incomplete(received: UInt64(received), expected: 6))
                        }
                        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
                        // Integrity rejection happens after the complete response;
                        // the session remains usable for the next operation.
                        _ = try await session.execute(operation: 0x1004)
                        let remaining = await wire.remaining
                        XCTAssertEqual(remaining, 0)
                    }
                }
            }
        }
    }

    func testFailedFullPhotoIsRemovedAndQueueRetryDownloadsAgain() async throws {
        for response: UInt16 in [0x2005, 0x2019] {
            let target = try directory(), cameraFile = file()
            let rejected = Data(repeating: 8, count: 6), accepted = Data(1...6)
            let wire = DownloadReplay([
                .init(0x1009, [7], code: response, chunks: [rejected], declared: 6),
                .init(0x1009, [7], chunks: [accepted], declared: 6)
            ])
            let camera = CameraSession(repository: CameraRepository(session: PTPSession(transport: wire)))
            let suite = "failed-photo-retry-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let usage = FreeUsageStore(defaults: defaults)
            let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!,
                                      premiumAccess: PremiumAccess(.free), freeUsage: usage)
            let originalID = await queue.enqueue(cameraFile)
            await queue.start(session: camera, directory: target)
            let failed = try await finish(queue)
            XCTAssertEqual(failed.items.first?.status, .failed)
            XCTAssertNil(failed.items.first?.outputURL)
            XCTAssertEqual(usage.snapshot().transfers, 0)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)

            let retryID = await queue.retry(id: try XCTUnwrap(originalID))
            XCTAssertNotNil(retryID)
            let completed = try await finish(queue)
            let item = try XCTUnwrap(completed.items.first)
            XCTAssertEqual(item.status, .completed)
            XCTAssertFalse(item.skipped)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(item.outputURL)), accepted)
            XCTAssertEqual(usage.snapshot().transfers, 1)
            let commands = await wire.commands
            XCTAssertEqual(commands.map(\.code), [0x1009, 0x1009])
        }
    }

    func testResumeRejectsUnresolvedSizeWithoutFullObjectRequest() async throws {
        let target = try directory()
        let part = target.appendingPathComponent(transferPartialFileName(size: UInt64(UInt32.max), captureDate: nil, fileName: "a.MP4"))
        try Data(repeating: 1, count: Int(transferResumeChunkSize)).write(to: part)
        let wire = DownloadReplay([.init(0x9421, [7], code: 0x2005)])
        do {
            _ = try await CameraRepository(session: PTPSession(transport: wire))
                .download(handle: 7, size: UInt64(UInt32.max), fileName: "a.MP4", to: target)
            XCTFail("An unknown-size resume cannot use full object")
        } catch { XCTAssertEqual(error as? CameraRepositoryError, .resumeUnavailable) }
        let calls = await wire.commands
        XCTAssertEqual(calls.map(\.code), [0x9421])
    }

    func testResumedStreamTrimsTailAndDoesNotCaptureIncompleteHeader() async throws {
        let target = try directory()
        let size = transferResumeChunkSize + 6
        let part = target.appendingPathComponent(transferPartialFileName(size: size, captureDate: nil, fileName: "a.MP4"))
        try Data(repeating: 8, count: Int(transferResumeChunkSize) + 2).write(to: part)
        let wire = DownloadReplay([.init(0x9431, [7, UInt32(transferResumeChunkSize), 0, 6, 0], chunks: [Data([1, 2, 3, 4, 5, 6])], declared: 6)])
        let result = try await CameraRepository(session: PTPSession(transport: wire))
            .downloadResult(handle: 7, size: size, fileName: "a.MP4", to: target, captureHeader: true)
        XCTAssertEqual(result.transferredBytes, 6)
        XCTAssertEqual(result.bytes, size)
        XCTAssertNil(result.headerPrefix)
        XCTAssertEqual(try Data(contentsOf: result.url).suffix(6), Data([1, 2, 3, 4, 5, 6]))
    }

    func testStillImageDeletesStaleResumePartAndUsesFullObject() async throws {
        let target = try directory()
        let size = transferResumeChunkSize + 2
        let part = target.appendingPathComponent(
            transferPartialFileName(size: size, captureDate: nil, fileName: "a.JPG")
        )
        try Data(repeating: 8, count: Int(transferResumeChunkSize)).write(to: part)
        let fresh = Data(repeating: 3, count: Int(size))
        let wire = DownloadReplay([
            .init(0x1009, [7], chunks: [fresh], declared: size)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        await repository.setPreferHighThroughputTransfers(true)
        let result = try await repository.downloadResult(handle: 7, size: size, fileName: "a.JPG", to: target)
        XCTAssertEqual(result.bytes, size)
        XCTAssertEqual(try Data(contentsOf: result.url), fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x1009])
    }

    func testFreshHeaderCaptureIsBoundedAcrossPackets() async throws {
        let wire = DownloadReplay([.init(0x1009, [7], chunks: [Data(repeating: 1, count: 200_000), Data(repeating: 2, count: 200_000)], declared: 400_000)])
        let result = try await CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
            .downloadResult(handle: 7, size: 400_000, fileName: "a.JPG", to: directory(), captureHeader: true)
        XCTAssertEqual(result.headerPrefix?.count, 256 * 1024)
        XCTAssertEqual(result.headerPrefix?.prefix(200_000), Data(repeating: 1, count: 200_000))
        XCTAssertEqual(result.headerPrefix?.suffix(62_144), Data(repeating: 2, count: 62_144))
    }

    func testSmallCompletePartIsRenamedWithoutCameraRequest() async throws {
        let target = try directory()
        let part = target.appendingPathComponent(transferPartialFileName(size: 6, captureDate: nil, fileName: "a.MP4"))
        try Data(repeating: 4, count: 6).write(to: part)
        let wire = DownloadReplay([])
        let result = try await CameraRepository(session: PTPSession(transport: wire))
            .downloadResult(handle: 7, size: 6, fileName: "a.MP4", to: target)
        XCTAssertEqual(result.transferredBytes, 0)
        XCTAssertEqual(try Data(contentsOf: result.url).count, 6)
    }

    func testSaveRenameRefusalCopiesToSameReservedName() throws {
        let target = try directory(), part = target.appendingPathComponent(".nkpart_test")
        try Data([1, 2]).write(to: part)
        let moves = DownloadValueBox<[String]>([])
        let copies = DownloadValueBox<[String]>([])
        let operations = TransferFileOperations(exists: TransferFileOperations.system.exists, move: { _, dest in
            moves.mutate { $0.append(dest.lastPathComponent) }
            throw CocoaError(.fileWriteUnknown)
        }, copy: { source, dest in
            copies.mutate { $0.append(dest.lastPathComponent) }
            try FileManager.default.copyItem(at: source, to: dest)
        }, remove: TransferFileOperations.system.remove, size: TransferFileOperations.system.size)
        let output = try finalizeTransferTemporary(temporary: part, directory: target, fileName: "a.JPG", operations: operations)
        XCTAssertEqual(output.lastPathComponent, "a.JPG")
        XCTAssertEqual(moves.value, ["a.JPG"])
        XCTAssertEqual(copies.value, ["a.JPG"])
        XCTAssertEqual(try Data(contentsOf: output), Data([1, 2]))
    }

    func testSaveCopyFallbackChecksLengthAndCompletePartDoesNotCopy() throws {
        let target = try directory(), part = target.appendingPathComponent(".nkpart_test")
        try Data([1, 2, 3]).write(to: part)
        let copied = DownloadValueBox(false)
        let operations = TransferFileOperations(exists: TransferFileOperations.system.exists,
            move: { _, _ in throw CocoaError(.fileWriteUnknown) }, copy: { _, dest in
                copied.value = true
                try Data([1]).write(to: dest)
            }, remove: TransferFileOperations.system.remove, size: TransferFileOperations.system.size)
        XCTAssertThrowsError(try finalizeTransferTemporary(temporary: part, directory: target, fileName: "a.JPG", allowCopy: false, operations: operations))
        XCTAssertFalse(copied.value)
        XCTAssertThrowsError(try finalizeTransferTemporary(temporary: part, directory: target, fileName: "a.JPG", operations: operations)) { error in
            XCTAssertEqual(error as? CameraDownloadError, .copyIncomplete(received: 1, expected: 3))
        }
        XCTAssertTrue(copied.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.JPG").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
    }

    func testSaveSuccessfulCopyDeletesTemporary() throws {
        let target = try directory(), part = target.appendingPathComponent(".nkpart_test")
        try Data([1, 2, 3]).write(to: part)
        let operations = TransferFileOperations(exists: TransferFileOperations.system.exists,
            move: { _, _ in throw CocoaError(.fileWriteUnknown) }, copy: TransferFileOperations.system.copy,
            remove: TransferFileOperations.system.remove, size: TransferFileOperations.system.size)
        let output = try finalizeTransferTemporary(temporary: part, directory: target, fileName: "a.JPG", operations: operations)
        XCTAssertEqual(try Data(contentsOf: output), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    func testProgressExcludesRetainedBytesAndUsesProtocolStartClock() throws {
        let target = try directory().appendingPathComponent("a.part")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let values = DownloadValueBox<[TransferDownloadProgress]>([])
        let writer = CameraDownloadWriter(output: try FileHandle(forWritingTo: target), resumeOffset: 4_000_000,
            totalHint: 8_000_000, captureHeader: false, startedAt: .now.advanced(by: .seconds(-2)),
            onProgress: { value in values.mutate { $0.append(value) } })
        writer.sink.started(nil)
        XCTAssertEqual(values.value.first?.downloaded, 4_000_000)
        XCTAssertEqual(values.value.first?.bytesPerSecond, 0)
        try writer.sink.received(Data(repeating: 1, count: 1000))
        writer.sink.started(nil)
        XCTAssertEqual(values.value.last?.downloaded, 4_001_000)
        XCTAssertLessThanOrEqual(values.value.last?.bytesPerSecond ?? .max, 500)
        XCTAssertGreaterThan(values.value.last?.bytesPerSecond ?? 0, 0)
        try writer.close()
    }

    func testWriterBatchesSmallPacketsAndFlushesEveryByteOnClose() throws {
        let target = try directory().appendingPathComponent("buffered.part")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let writer = CameraDownloadWriter(
            output: try FileHandle(forWritingTo: target), resumeOffset: 0,
            totalHint: 1_100_000, captureHeader: false, startedAt: .now, onProgress: nil
        )
        let first = Data(repeating: 0x11, count: 700_000)
        let second = Data(repeating: 0x22, count: 400_000)

        try writer.sink.received(first)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue, 0)
        try writer.sink.received(second)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue, first.count)
        XCTAssertEqual(writer.bytes, UInt64(first.count + second.count))

        try writer.close()
        let saved = try Data(contentsOf: target)
        XCTAssertEqual(saved.count, first.count + second.count)
        XCTAssertEqual(saved.prefix(first.count), first)
        XCTAssertEqual(saved.suffix(second.count), second)
    }

    func testFreshJPEGMetadataFlowsToFrameWithoutSecondCameraRead() async throws {
        let jpeg = Self.jpegWithCameraMetadata()
        let cameraFile = file(size: UInt64(jpeg.count))
        let wire = DownloadReplay([.init(0x1009, [7], chunks: [jpeg], declared: UInt64(jpeg.count))])
        let repository = CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
        let session = CameraSession(repository: repository)
        let metadata = DownloadValueBox<PhotoFrameMetadata?>(nil)
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), renderFrame: { source, _, _, snapshot in
            metadata.value = snapshot
            return source
        })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue(cameraFile, effects: effects)
        await queue.start(session: session, directory: try directory())
        let snapshot = try await finish(queue)
        XCTAssertEqual(snapshot.items.first?.status, .completed)
        XCTAssertNil(snapshot.items.first?.frameError)
        XCTAssertEqual(metadata.value?.model, "Z 30")
        let calls = await wire.commands
        XCTAssertEqual(calls.map(\.code), [0x1009])
    }

    func testOversizedCameraLabelIsBoundedInRenderedAndRetainedSnapshot() async throws {
        let jpeg = Self.jpegWithCameraMetadata(model: String(repeating: "a", count: 255) + "📷" + String(repeating: "b", count: 1000))
        let cameraFile = file(size: UInt64(jpeg.count))
        let wire = DownloadReplay([.init(0x1009, [7], chunks: [jpeg], declared: UInt64(jpeg.count))])
        let repository = CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
        let session = CameraSession(repository: repository)
        let metadata = DownloadValueBox<PhotoFrameMetadata?>(nil)
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), renderFrame: { source, _, _, snapshot in
            metadata.value = snapshot
            return source
        })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue(cameraFile, effects: effects)
        await queue.start(session: session, directory: try directory())
        let snapshot = try await finish(queue)
        XCTAssertEqual(snapshot.items.first?.status, .completed)
        XCTAssertNil(snapshot.items.first?.frameError)
        XCTAssertEqual(metadata.value?.model, String(repeating: "a", count: 255))
        XCTAssertEqual(snapshot.items.first?.sourceMetadataSnapshot?.model, metadata.value?.model)
        let calls = await wire.commands
        XCTAssertEqual(calls.map(\.code), [0x1009])
    }

    func testCapturedPartialHeaderExpandsThroughProductionCameraToOneMiB() async throws {
        let original = Self.jpegWithCameraMetadata()
        var jpeg = Data([255, 216])
        for _ in 0..<5 {
            jpeg.append(contentsOf: [255, 226, 255, 255])
            jpeg.append(Data(repeating: 0, count: 65533))
        }
        jpeg.append(original.dropFirst(2))
        XCTAssertEqual(JpegMetadataHeader.inspect(jpeg.prefix(cameraExifHeaderCaptureBytes)), .incomplete)
        let cameraFile = file(size: UInt64(jpeg.count))
        let wire = DownloadReplay([
            .init(0x1009, [7], chunks: [jpeg], declared: UInt64(jpeg.count)),
            .init(PTPConstants.getPartialObjectEx, [7, 0, 0, 1024 * 1024, 0], chunks: [jpeg], declared: UInt64(jpeg.count))
        ])
        let session = CameraSession(repository: CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true))
        let rendered = DownloadValueBox<PhotoFrameMetadata?>(nil)
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), renderFrame: { source, _, _, metadata in
            rendered.value = metadata; return source
        })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue(cameraFile, effects: effects)
        await queue.start(session: session, directory: try directory())
        let result = try await finish(queue)
        XCTAssertEqual(result.items.first?.status, .completed)
        XCTAssertNil(result.items.first?.frameError)
        XCTAssertEqual(rendered.value?.model, "Z 30")
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x1009, PTPConstants.getPartialObjectEx])
    }

    func testSupplementStopsAtTwoMiBAndCachesFinalPartialAcrossRetry() async throws {
        let target = try directory(), jpeg = Self.jpegWithCameraMetadata()
        let cameraFile = file(size: UInt64(jpeg.count))
        try jpeg.write(to: target.appendingPathComponent(cameraFile.fileName))
        let sizes: [UInt32] = [UInt32(cameraExifHeaderCaptureBytes), 1024 * 1024, 2 * 1024 * 1024]
        let wire = STAScriptTransport(sizes.map { size in
            .init(PTPConstants.getPartialObjectEx, [7, 0, 0, size, 0], payload: Data([255, 216]))
        })
        let session = CameraSession(repository: CameraRepository(session: PTPSession(transport: wire)))
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), renderFrame: { source, _, _, _ in
            XCTFail("Unusable partial metadata must not reach rendering"); return source
        })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue(cameraFile, effects: effects)
        await queue.start(session: session, directory: target)
        let first = try await finish(queue)
        XCTAssertNotNil(first.items.first?.frameError)
        let id = try XCTUnwrap(first.items.first?.id)
        let replacement = await queue.retry(id: id)
        XCTAssertNotNil(replacement)
        let second = try await finish(queue)
        XCTAssertNotNil(second.items.first?.frameError)
        let remaining = await wire.remaining
        let commands = await wire.commands
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(commands.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(cameraFile.fileName).path))
    }

    func testNoExifResultSurvivesRetryWithoutAnotherCameraRead() async throws {
        let target = try directory(), jpeg = Self.jpegWithCameraMetadata()
        let cameraFile = file(size: UInt64(jpeg.count))
        try jpeg.write(to: target.appendingPathComponent(cameraFile.fileName))
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx, [7, 0, 0, UInt32(cameraExifHeaderCaptureBytes), 0], payload: Data([255,216,255,218]))
        ])
        let session = CameraSession(repository: CameraRepository(session: PTPSession(transport: wire)))
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), renderFrame: { source, _, _, _ in
            XCTFail("No camera metadata should fail before rendering"); return source
        })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue(cameraFile, effects: effects)
        await queue.start(session: session, directory: target)
        let failed = try await finish(queue)
        let id = try XCTUnwrap(failed.items.first?.id)
        XCTAssertNotNil(failed.items.first?.frameError)
        let replacement = await queue.retry(id: id)
        XCTAssertNotNil(replacement)
        let retried = try await finish(queue)
        XCTAssertNotNil(retried.items.first?.frameError)
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [PTPConstants.getPartialObjectEx])
    }

    func testExistingJPEGWithoutCameraMetadataFailsOnlyDerivative() async throws {
        let target = try directory(), jpeg = Self.jpegWithCameraMetadata()
        let cameraFile = file(size: UInt64(jpeg.count))
        try jpeg.write(to: target.appendingPathComponent(cameraFile.fileName))
        let rendered = DownloadValueBox(false)
        let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), renderFrame: { source, _, _, _ in rendered.value = true; return source })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue(cameraFile, effects: effects)
        await queue.start(session: nil, directory: target)
        let snapshot = try await finish(queue)
        XCTAssertEqual(snapshot.items.first?.status, .completed)
        XCTAssertEqual(snapshot.items.first?.frameError, AppLocalized.resource("error_camera_metadata_unavailable"))
        XCTAssertNil(snapshot.items.first?.error)
        XCTAssertFalse(rendered.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(cameraFile.fileName).path))
    }

    func testMetadataSnapshotAndOriginalBodySurviveIndividualAndBatchRetry() async throws {
        for batchRetry in [false, true] {
            let target = try directory(), jpeg = Self.jpegWithCameraMetadata()
            let original = file(size: UInt64(jpeg.count))
            try jpeg.write(to: target.appendingPathComponent(original.fileName))
            let info = try XCTUnwrap(PTPDatasetParser.parseDeviceInfo(staDeviceInfo()))
            let firstWire = STAScriptTransport([
                .init(PTPConstants.getPartialObjectEx, [7, 0, 0, UInt32(cameraExifHeaderCaptureBytes), 0], payload: jpeg)
            ])
            let firstSession = CameraSession(repository: CameraRepository(session: PTPSession(transport: firstWire), deviceInfo: info))
            let rendered = DownloadValueBox<[PhotoFrameMetadata?]>([])
            let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), renderFrame: { source, _, _, metadata in
                rendered.mutate { $0.append(metadata) }
                if rendered.value.count == 1 { throw CocoaError(.fileWriteUnknown) }
                return source
            })
            var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
            await queue.enqueue(original, effects: effects)
            await queue.start(session: firstSession, directory: target)
            let failed = try await finish(queue)
            let firstTask = try XCTUnwrap(failed.items.first)
            XCTAssertEqual(firstTask.status, .completed)
            XCTAssertNil(firstTask.error)
            XCTAssertNotNil(firstTask.frameError)
            XCTAssertEqual(firstTask.sourceMetadataSnapshot?.model, "Z 30")
            let secondWire = STAScriptTransport([])
            let differentCamera = CameraSession(repository: CameraRepository(session: PTPSession(transport: secondWire),
                transportCameraIdentifier: "different-camera"))
            await queue.attach(session: differentCamera, directory: nil)
            if batchRetry { await queue.retryFailed() }
            else {
                let replacement = await queue.retry(id: firstTask.id)
                XCTAssertNotNil(replacement)
            }
            let completed = try await finish(queue)
            XCTAssertEqual(completed.items.first?.status, .completed)
            XCTAssertEqual(completed.items.first?.metadataCameraIdentity, firstTask.metadataCameraIdentity)
            XCTAssertEqual(rendered.value.count, 2)
            XCTAssertEqual((rendered.value.last ?? nil)?.model, "Z 30")
            let unexpected = await secondWire.commands
            XCTAssertTrue(unexpected.isEmpty, "Retry must use retained metadata without querying a different camera")
        }
    }

    func testFailedMetadataCannotBeRetriedFromANewCamera() async throws {
        for initiallyConnected in [true, false] {
            let target = try directory(), jpeg = Self.jpegWithCameraMetadata()
            let original = file(size: UInt64(jpeg.count))
            try jpeg.write(to: target.appendingPathComponent(original.fileName))
            let info = try XCTUnwrap(PTPDatasetParser.parseDeviceInfo(staDeviceInfo()))
            let firstWire = STAScriptTransport([
                .init(PTPConstants.getPartialObjectEx, [7, 0, 0, UInt32(cameraExifHeaderCaptureBytes), 0], response: 0x2005)
            ])
            let firstSession = CameraSession(repository: CameraRepository(session: PTPSession(transport: firstWire), deviceInfo: info))
            let queue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), renderFrame: { source, _, _, _ in
                XCTFail("Missing source metadata must fail before rendering")
                return source
            })
            var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
            await queue.enqueue(original, effects: effects)
            await queue.start(session: initiallyConnected ? firstSession : nil, directory: target)
            let first = try await finish(queue)
            let originalTask = try XCTUnwrap(first.items.first)
            XCTAssertEqual(originalTask.status, .completed)
            XCTAssertNil(originalTask.error)
            XCTAssertNotNil(originalTask.frameError)
            XCTAssertTrue(originalTask.metadataSourceBound)
            let secondWire = STAScriptTransport([])
            let differentCamera = CameraSession(repository: CameraRepository(session: PTPSession(transport: secondWire),
                transportCameraIdentifier: "different-camera"))
            await queue.attach(session: differentCamera, directory: target)
            _ = await queue.retry(id: originalTask.id)
            let retried = try await finish(queue)
            XCTAssertEqual(retried.items.first?.status, .completed)
            XCTAssertEqual(retried.items.first?.metadataCameraIdentity, originalTask.metadataCameraIdentity)
            let unexpected = await secondWire.commands
            XCTAssertTrue(unexpected.isEmpty)
        }
    }

    private func finish(_ queue: TransferQueue) async throws -> TransferQueueSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let value = await queue.snapshot()
            if !value.isTransferring && value.items.allSatisfy({ $0.status != .waiting && !$0.isGeneratingFrame }) { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.coderInvalidValue)
    }

    private static func jpegWithCameraMetadata(model: String = "Z 30") -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image.cgImage!, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Nikon", kCGImagePropertyTIFFModel: model]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class DownloadValueBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    func mutate(_ action: (inout T) -> Void) { lock.withLock { action(&stored) } }
}

private actor DownloadReplay: PTPCommandTransport {
    struct Step: Sendable {
        let operation: UInt16
        let parameters: [UInt32]
        let code: UInt16
        let chunks: [Data]
        let declared: UInt64?
        let chunkDelayNanoseconds: UInt64
        init(_ operation: UInt16, _ parameters: [UInt32], code: UInt16 = 0x2001, chunks: [Data] = [], declared: UInt64? = nil, chunkDelayNanoseconds: UInt64 = 0) {
            self.operation = operation; self.parameters = parameters; self.code = code
            self.chunks = chunks; self.declared = declared
            self.chunkDelayNanoseconds = chunkDelayNanoseconds
        }
    }
    private var steps: [Step]
    private(set) var commands: [PTPContainer] = []
    private(set) var firstChunkTime: TimeInterval?
    private(set) var lastChunkTime: TimeInterval?
    var remaining: Int { steps.count }
    init(_ steps: [Step]) { self.steps = steps }

    private func next(_ command: Data) throws -> (Step, Data) {
        let packet = try PTPCodec.decode(command)
        commands.append(packet)
        guard !steps.isEmpty else { throw CocoaError(.coderInvalidValue) }
        let step = steps.removeFirst()
        let parameters = stride(from: 0, to: packet.payload.count, by: 4).map { packet.payload.readUInt32LE(at: $0) }
        guard packet.code == step.operation, parameters == step.parameters else { throw CocoaError(.coderInvalidValue) }
        return (step, PTPCodec.encode(type: .response, code: step.code, transactionID: packet.transactionID))
    }

    func sendPTP(command: Data, data: Data?) throws -> (response: Data, payload: Data) {
        let (step, response) = try next(command)
        return (response, step.chunks.reduce(into: Data()) { $0.append($1) })
    }

    func receivePTP(command: Data, sink: PTPDataSink) async throws -> PTPDataTransfer {
        let (step, response) = try next(command)
        sink.started(step.declared)
        for chunk in step.chunks {
            if step.chunkDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: step.chunkDelayNanoseconds) }
            let now = ProcessInfo.processInfo.systemUptime
            if firstChunkTime == nil { firstChunkTime = now }
            try sink.received(chunk)
            lastChunkTime = now
        }
        return PTPDataTransfer(response: response, receivedByteCount: UInt64(step.chunks.reduce(0) { $0 + $1.count }), declaredByteCount: step.declared)
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian) { Array($0) } }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset]) | UInt32(self[startIndex + offset + 1]) << 8 |
            UInt32(self[startIndex + offset + 2]) << 16 | UInt32(self[startIndex + offset + 3]) << 24
    }
}

extension CameraDownloadTests {
    func testProductionDownloadPublishesAfterOneHundredCaseInsensitiveCollisions() async throws {
        let target = try directory()
        for index in 0..<100 {
            let name = index == 0 ? "A.jpg" : "A (\(index)).jpg"
            try Data([9]).write(to: target.appendingPathComponent(name))
        }
        let payload = Data([1, 2, 3])
        let wire = DownloadReplay([.init(0x1009, [7], chunks: [payload], declared: 3)])
        let result = try await CameraRepository(session: PTPSession(transport: wire))
            .downloadResult(handle: 7, size: 3, fileName: "a.JPG", to: target)
        XCTAssertEqual(result.url.lastPathComponent, "a (100).JPG")
        XCTAssertEqual(try Data(contentsOf: result.url), payload)
        for index in 0..<100 {
            let name = index == 0 ? "A.jpg" : "A (\(index)).jpg"
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(name)), Data([9]))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).count, 101)
    }

    func testOriginalNamingHasNoDerivedTimestampLimitAndHandlesDotNames() {
        let occupied = Set((0...1000).map { $0 == 0 ? "A.JPG" : "A (\($0)).JPG" })
        XCTAssertEqual(uniqueOriginalFileName("a.jpg", occupied: occupied), "a (1001).jpg")
        XCTAssertEqual(uniqueOriginalFileName(".hidden", occupied: [".HIDDEN"]), ".hidden (1)")
        XCTAssertEqual(uniqueOriginalFileName("noext", occupied: ["NOEXT"]), "noext (1)")
    }

    func testConcurrentPublicationReservesNameUntilMoveCompletes() async throws {
        let target = try directory()
        let firstPart = target.appendingPathComponent(".nkpart_first")
        let secondPart = target.appendingPathComponent(".nkpart_second")
        try Data([1]).write(to: firstPart); try Data([2]).write(to: secondPart)
        let entered = expectation(description: "First publication holds reservation")
        let finished = expectation(description: "Second publication gets another name")
        let release = DispatchSemaphore(value: 0)
        let operations = TransferFileOperations(exists: TransferFileOperations.system.exists, move: { source, destination in
            if source == firstPart {
                entered.fulfill()
                release.wait()
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }, copy: TransferFileOperations.system.copy, remove: TransferFileOperations.system.remove, size: TransferFileOperations.system.size)
        let first = Task.detached {
            try finalizeTransferTemporary(temporary: firstPart, directory: target, fileName: "a.JPG", operations: operations)
        }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task.detached {
            defer { finished.fulfill() }
            return try finalizeTransferTemporary(temporary: secondPart, directory: target, fileName: "A.jpg", operations: operations)
        }
        await fulfillment(of: [finished], timeout: 2)
        release.signal()
        let firstOutput = try await first.value
        let secondOutput = try await second.value
        XCTAssertEqual(firstOutput.lastPathComponent, "a.JPG")
        XCTAssertEqual(secondOutput.lastPathComponent, "A (1).jpg")
        XCTAssertEqual(try Data(contentsOf: firstOutput), Data([1]))
        XCTAssertEqual(try Data(contentsOf: secondOutput), Data([2]))
    }

    func testCopyCollisionDoesNotDeleteExternalFileAndFailedReservationCanRetry() throws {
        let target = try directory(), part = target.appendingPathComponent(".nkpart_test")
        try Data([1, 2, 3]).write(to: part)
        let operations = TransferFileOperations(exists: TransferFileOperations.system.exists,
            move: { _, _ in throw CocoaError(.fileWriteUnknown) }, copy: { _, destination in
                try Data([9]).write(to: destination)
                throw CocoaError(.fileWriteFileExists)
            }, remove: TransferFileOperations.system.remove, size: TransferFileOperations.system.size)
        XCTAssertThrowsError(try finalizeTransferTemporary(temporary: part, directory: target, fileName: "a.JPG", operations: operations))
        let external = target.appendingPathComponent("a.JPG")
        XCTAssertEqual(try Data(contentsOf: external), Data([9]))
        XCTAssertEqual(try Data(contentsOf: part), Data([1, 2, 3]))
        try FileManager.default.removeItem(at: external)
        let retry = try finalizeTransferTemporary(temporary: part, directory: target, fileName: "a.JPG")
        XCTAssertEqual(retry.lastPathComponent, "a.JPG")
        XCTAssertEqual(try Data(contentsOf: retry), Data([1, 2, 3]))
    }
}

/// Deterministically hold the second budget query, after source loading and
/// before canvas allocation, without changing production cancellation logic.
private final class ExportBudgetCheckpoint: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private let enabled: Bool
    private let entered: XCTestExpectation
    init(enabled: Bool, entered: XCTestExpectation) { self.enabled = enabled; self.entered = entered }
    func memory() -> Int64 {
        let hold = lock.withLock { calls += 1; return enabled && calls == 2 }
        if hold {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
        }
        return .max
    }
}
