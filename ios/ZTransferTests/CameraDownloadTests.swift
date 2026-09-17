import XCTest
import UIKit
import ImageIO
@testable import ZTransfer

@MainActor
final class CameraDownloadTests: XCTestCase {
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
        _ = try await repository.download(handle: 7, size: 6, fileName: "a.JPG", to: directory())
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

    func testUnknownSizeResolvedUsesPartialWithResolvedSize() async throws {
        let wire = DownloadReplay([
            .init(0x9421, [7], chunks: [Data(UInt64(6).littleEndianBytes)]),
            .init(0x9431, [7, 0, 0, 6, 0], chunks: [Data(repeating: 2, count: 6)], declared: 6),
        ])
        let result = try await CameraRepository(session: PTPSession(transport: wire))
            .downloadResult(handle: 7, size: UInt64(UInt32.max), fileName: "a.JPG", to: directory())
        XCTAssertEqual(result.bytes, 6)
    }

    func testShortCompletePartialAdvancesByReceivedBytes() async throws {
        let wire = DownloadReplay([
            .init(0x9431, [7, 0, 0, 6, 0], chunks: [Data([1, 2])], declared: 2),
            .init(0x9431, [7, 2, 0, 4, 0], chunks: [Data([3, 4, 5, 6])], declared: 4),
        ])
        let output = try await CameraRepository(session: PTPSession(transport: wire))
            .download(handle: 7, size: 6, fileName: "a.JPG", to: directory())
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
        _ = try await repository.download(handle: 7, size: 6, fileName: "a.JPG", to: target)
        _ = try await repository.download(handle: 8, size: 6, fileName: "b.JPG", to: target)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testPartialErrorAfterBytesNeverFallsBackAndPreservesPart() async throws {
        for code: UInt16 in [0x2005, 0x2019] {
            let wire = DownloadReplay([.init(0x9431, [7, 0, 0, 6, 0], code: code, chunks: [Data([1, 2])], declared: 2)])
            let repository = CameraRepository(session: PTPSession(transport: wire))
            let target = try directory()
            do { _ = try await repository.download(handle: 7, size: 6, fileName: "a.JPG", to: target); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? CameraDownloadError, .response(code)) }
            let part = target.appendingPathComponent(transferPartialFileName(size: 6, captureDate: nil, fileName: "a.JPG"))
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
            do { _ = try await repository.download(handle: 7, size: 6, fileName: "a.JPG", to: directory()); XCTFail("Expected short read") }
            catch { XCTAssertEqual(error as? CameraDownloadError, .incomplete(received: 2, expected: 6)) }
            _ = try await session.execute(operation: 0x1004)
        }
    }

    func testFullObjectChecksDataDeclarationInsteadOfStaleObjectInfoSize() async throws {
        let wire = DownloadReplay([.init(0x1009, [7], chunks: [Data([1, 2, 3])], declared: 3)])
        let result = try await CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
            .downloadResult(handle: 7, size: 6, fileName: "a.JPG", to: directory())
        XCTAssertEqual(result.bytes, 3)
    }

    func testResumeRejectsUnresolvedSizeWithoutFullObjectRequest() async throws {
        let target = try directory()
        let part = target.appendingPathComponent(transferPartialFileName(size: UInt64(UInt32.max), captureDate: nil, fileName: "a.JPG"))
        try Data(repeating: 1, count: Int(transferResumeChunkSize)).write(to: part)
        let wire = DownloadReplay([.init(0x9421, [7], code: 0x2005)])
        do {
            _ = try await CameraRepository(session: PTPSession(transport: wire))
                .download(handle: 7, size: UInt64(UInt32.max), fileName: "a.JPG", to: target)
            XCTFail("An unknown-size resume cannot use full object")
        } catch { XCTAssertEqual(error as? CameraRepositoryError, .resumeUnavailable) }
        let calls = await wire.commands
        XCTAssertEqual(calls.map(\.code), [0x9421])
    }

    func testResumedStreamTrimsTailAndDoesNotCaptureIncompleteHeader() async throws {
        let target = try directory()
        let size = transferResumeChunkSize + 6
        let part = target.appendingPathComponent(transferPartialFileName(size: size, captureDate: nil, fileName: "a.JPG"))
        try Data(repeating: 8, count: Int(transferResumeChunkSize) + 2).write(to: part)
        let wire = DownloadReplay([.init(0x9431, [7, UInt32(transferResumeChunkSize), 0, 6, 0], chunks: [Data([1, 2, 3, 4, 5, 6])], declared: 6)])
        let result = try await CameraRepository(session: PTPSession(transport: wire))
            .downloadResult(handle: 7, size: size, fileName: "a.JPG", to: target, captureHeader: true)
        XCTAssertEqual(result.transferredBytes, 6)
        XCTAssertEqual(result.bytes, size)
        XCTAssertNil(result.headerPrefix)
        XCTAssertEqual(try Data(contentsOf: result.url).suffix(6), Data([1, 2, 3, 4, 5, 6]))
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
        let part = target.appendingPathComponent(transferPartialFileName(size: 6, captureDate: nil, fileName: "a.JPG"))
        try Data(repeating: 4, count: 6).write(to: part)
        let wire = DownloadReplay([])
        let result = try await CameraRepository(session: PTPSession(transport: wire))
            .downloadResult(handle: 7, size: 6, fileName: "a.JPG", to: target)
        XCTAssertEqual(result.transferredBytes, 0)
        XCTAssertEqual(try Data(contentsOf: result.url).count, 6)
    }

    func testSaveTriesSuffixRenameBeforeCopyAndNeverOverwrites() throws {
        let target = try directory(), part = target.appendingPathComponent(".nkpart_test")
        try Data([1, 2]).write(to: part)
        let copied = DownloadValueBox(false)
        let operations = TransferFileOperations(exists: TransferFileOperations.system.exists, move: { source, dest in
            if dest.lastPathComponent == "a.JPG" { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: source, to: dest)
        }, copy: { _, _ in copied.value = true }, remove: TransferFileOperations.system.remove, size: TransferFileOperations.system.size)
        let output = try finalizeTransferTemporary(temporary: part, directory: target, fileName: "a.JPG", operations: operations)
        XCTAssertEqual(output.lastPathComponent, "a (1).JPG")
        XCTAssertFalse(copied.value)
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

    func testFreshJPEGMetadataFlowsToFrameWithoutSecondCameraRead() async throws {
        let jpeg = Self.jpegWithCameraMetadata()
        let cameraFile = file(size: UInt64(jpeg.count))
        let wire = DownloadReplay([.init(0x1009, [7], chunks: [jpeg], declared: UInt64(jpeg.count))])
        let repository = CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true)
        let session = CameraSession(repository: repository)
        let metadata = DownloadValueBox<PhotoFrameMetadata?>(nil)
        let queue = TransferQueue(renderFrame: { source, _, _, snapshot in
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

    func testExistingJPEGWithoutCameraMetadataFailsOnlyDerivative() async throws {
        let target = try directory(), jpeg = Self.jpegWithCameraMetadata()
        let cameraFile = file(size: UInt64(jpeg.count))
        try jpeg.write(to: target.appendingPathComponent(cameraFile.fileName))
        let rendered = DownloadValueBox(false)
        let queue = TransferQueue(renderFrame: { source, _, _, _ in rendered.value = true; return source })
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true
        await queue.enqueue(cameraFile, effects: effects)
        await queue.start(session: nil, directory: target)
        let snapshot = try await finish(queue)
        XCTAssertEqual(snapshot.items.first?.status, .failed)
        XCTAssertEqual(snapshot.items.first?.frameError, AppLocalized.resource("error_camera_metadata_unavailable"))
        XCTAssertFalse(rendered.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(cameraFile.fileName).path))
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

    private static func jpegWithCameraMetadata() -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image.cgImage!, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Nikon", kCGImagePropertyTIFFModel: "Z 30"]] as CFDictionary)
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
        init(_ operation: UInt16, _ parameters: [UInt32], code: UInt16 = 0x2001, chunks: [Data] = [], declared: UInt64? = nil) {
            self.operation = operation; self.parameters = parameters; self.code = code
            self.chunks = chunks; self.declared = declared
        }
    }
    private var steps: [Step]
    private(set) var commands: [PTPContainer] = []
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

    func receivePTP(command: Data, sink: PTPDataSink) throws -> PTPDataTransfer {
        let (step, response) = try next(command)
        sink.started(step.declared)
        for chunk in step.chunks { try sink.received(chunk) }
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
