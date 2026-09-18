import Foundation
import XCTest

final class STAAndroidTransferParityTests: XCTestCase {
    func testUnknownPTPDeclarationDoesNotBecomeHugeWriterProgressTotal() throws {
        for hint: UInt64 in [0, 3] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = CameraDownloadWriter(output: try FileHandle(forWritingTo: url), resumeOffset: 0,
                                             totalHint: hint, captureHeader: false, startedAt: .now,
                                             onProgress: { XCTAssertEqual($0.total, hint) })
            defer { try? writer.close() }
            var phase = PTPIPDownloadPhase(transactionID: 7)
            // 7 + all-ones signed Long; no replacement/copy of production parser or writer.
            let start = Data([7, 0, 0, 0] + Array(repeating: UInt8(0xFF), count: 8))
            XCTAssertNil(try start.withUnsafeBytes { try phase.consume(type: .startData, payload: $0, sink: writer.sink) })
            let end = Data([7, 0, 0, 0, 1, 2, 3])
            XCTAssertNil(try end.withUnsafeBytes { try phase.consume(type: .endData, payload: $0, sink: writer.sink) })
            let response = Data([1, 0x20, 7, 0, 0, 0])
            let result = try XCTUnwrap(response.withUnsafeBytes {
                try phase.consume(type: .commandResponse, payload: $0, sink: writer.sink)
            })
            XCTAssertNil(result.declaredByteCount)
            XCTAssertEqual(result.receivedByteCount, 3)
            try writer.close()
            XCTAssertEqual(writer.bytes, 3)
            XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        }
    }

    @MainActor
    func testBackgroundExpirationEndsAssertionBeforeNotifyingCleanupAndOnlyOnce() {
        let fixture = BackgroundActivityFixture()
        let activity = fixture.start(identifier: 7)
        fixture.expiration?()
        XCTAssertEqual(fixture.events, ["end:7", "expire"])
        fixture.expiration?()
        activity.finish()
        XCTAssertEqual(fixture.events, ["end:7", "expire"])
    }

    @MainActor
    func testFinishedBackgroundActivityIgnoresLateExpirationWhileNewOneRemainsActive() {
        let old = BackgroundActivityFixture()
        let first = old.start(identifier: 7)
        first.finish()
        let current = BackgroundActivityFixture()
        let second = current.start(identifier: 8)
        old.expiration?()
        XCTAssertEqual(old.events, ["end:7"])
        XCTAssertTrue(current.events.isEmpty)
        current.expiration?()
        second.finish()
        XCTAssertEqual(current.events, ["end:8", "expire"])
    }

    @MainActor
    func testImmediateBackgroundExpirationWaitsForReturnedIdentifierThenEndsIt() {
        let fixture = BackgroundActivityFixture()
        let activity = fixture.start(identifier: 9, expireDuringBegin: true)
        XCTAssertEqual(fixture.events, ["end:9", "expire"])
        activity.finish()
        XCTAssertEqual(fixture.events, ["end:9", "expire"])
    }

    @MainActor
    func testRejectedBackgroundAssertionDoesNotCancelForegroundTransfer() {
        for expireDuringBegin in [false, true] {
            let fixture = BackgroundActivityFixture()
            let activity = fixture.start(identifier: nil, expireDuringBegin: expireDuringBegin)
            fixture.expiration?()
            activity.finish()
            XCTAssertTrue(fixture.events.isEmpty)
        }
    }

    func testBorrowedWriterConsumesBytesBeforeBufferIsOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = CameraDownloadWriter(output: try FileHandle(forWritingTo: url), resumeOffset: 0,
                                         totalHint: 0, captureHeader: true, startedAt: .now, onProgress: nil)
        let borrowed = try XCTUnwrap(writer.sink.receivedBorrowed)
        var storage = [UInt8](repeating: 1, count: 1_100_000)
        try storage.withUnsafeBytes { try borrowed(UnsafeRawBufferPointer(rebasing: $0[..<500_000])) }
        _ = storage.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 2) }
        try storage.withUnsafeBytes { try borrowed($0) }
        _ = storage.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 3) }
        try storage.withUnsafeBytes { try borrowed(UnsafeRawBufferPointer(rebasing: $0[..<2])) }
        _ = storage.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 9) }
        try writer.close()
        XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 1, count: 500_000) + Data(repeating: 2, count: 1_100_000) + Data([3, 3]))
        XCTAssertEqual(writer.result(url: url).headerPrefix, Data(repeating: 1, count: 256 * 1024))
        XCTAssertThrowsError(try storage.withUnsafeBytes { try borrowed($0) })
    }

    func testBorrowedWriterReportsWriteFailureWithoutCountingUnwrittenBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([9]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = CameraDownloadWriter(output: try FileHandle(forReadingFrom: url), resumeOffset: 0,
                                         totalHint: 0, captureHeader: false, startedAt: .now, onProgress: nil)
        let borrowed = try XCTUnwrap(writer.sink.receivedBorrowed)
        XCTAssertThrowsError(try Data(repeating: 1, count: 1_100_000).withUnsafeBytes { try borrowed($0) }) { error in
            guard case CameraDownloadError.write = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(writer.bytes, 0)
        try writer.close()
        XCTAssertEqual(try Data(contentsOf: url), Data([9]))
    }

    // NikonCamera.kt shouldUsePartialObjectDownload/downloadChunkSize and
    // CameraIoGateTest.kt, limited to STA (the USB exception is not changed).
    func testAndroidSTAPolicyMatrixIncludingDirectReadAndThresholds() {
        let mib: UInt64 = 1024 * 1024
        let sizes: [UInt64] = [0, 1, 26 * mib, 128 * mib, 128 * mib + 1,
                              512 * mib, 512 * mib + 1, UInt64(UInt32.max), 5 * 1024 * mib]
        var cases = 0
        for support: Bool? in [nil, false, true] {
            for size in sizes {
                for resume: UInt64 in [0, 4 * mib] {
                    for high in [false, true] {
                        for direct in [false, true] {
                            let known = size > 0 && size != UInt64(UInt32.max)
                            let expected = support != false && known &&
                                (direct || !high || resume > 0 || size > 128 * mib)
                            XCTAssertEqual(shouldUsePartialObjectDownload(
                                partialObjectSupported: support, effectiveSize: size,
                                resumeOffset: resume, preferHighThroughput: high, forcePartial: direct), expected)
                            XCTAssertEqual(transferDownloadChunkSize(effectiveSize: size, preferHighThroughput: high),
                                           high ? 64 * mib : size > 512 * mib ? 32 * mib : 4 * mib)
                            cases += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 216)
        XCTAssertEqual(transferResumeChunkSize, 4 * mib)
        XCTAssertEqual(transferResumeOffset(existingSize: 6 * mib + 1, totalSize: 20 * mib,
                                            reportedSize: 20 * mib), 4 * mib)
    }

    func testAndroidSpeedExamplesAndUnknownInitialValues() {
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 26 * 1024 * 1024, elapsedMs: 11_000), 2_478_452)
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 8 * 1024 * 1024, elapsedMs: 2_000), 4 * 1024 * 1024)
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 0, elapsedMs: 1000), 0)
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 1024, elapsedMs: 0), 0)
    }

    func testProductionWriterBatchesSmallPacketsAndBypassesForLargePackets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = CameraDownloadWriter(output: try FileHandle(forWritingTo: url), resumeOffset: 0,
                                         totalHint: 0, captureHeader: true, startedAt: .now, onProgress: nil)
        let a = Data(repeating: 1, count: 500_000), b = Data(repeating: 2, count: 600_000)
        let c = Data(repeating: 3, count: 1_100_000), d = Data([4, 5])
        writer.sink.started(UInt64(a.count + b.count + c.count + d.count))
        try writer.sink.received(a)
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
        try writer.sink.received(b)
        XCTAssertEqual(try Data(contentsOf: url), a)
        try writer.sink.received(c)
        XCTAssertEqual(try Data(contentsOf: url), a + b + c)
        try writer.sink.received(d)
        try writer.close()
        try writer.close()
        XCTAssertEqual(try Data(contentsOf: url), a + b + c + d)
        let result = writer.result(url: url)
        XCTAssertEqual(result.bytes, UInt64(a.count + b.count + c.count + d.count))
        XCTAssertEqual(result.transferredBytes, result.bytes)
        XCTAssertEqual(result.headerPrefix, Data(repeating: 1, count: 256 * 1024))
    }

    func testResumedWriterCountsOnlyNewBytesAndDoesNotCaptureHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([9, 9, 9]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 3)
        let writer = CameraDownloadWriter(output: handle, resumeOffset: 3, totalHint: 5,
                                         captureHeader: true, startedAt: .now, onProgress: nil)
        try writer.sink.received(Data([1, 2]))
        try writer.close()
        XCTAssertEqual(try Data(contentsOf: url), Data([9, 9, 9, 1, 2]))
        let result = writer.result(url: url)
        XCTAssertEqual(result.bytes, 5)
        XCTAssertEqual(result.transferredBytes, 2)
        XCTAssertNil(result.headerPrefix)
    }
}

@MainActor
private final class BackgroundActivityFixture {
    var expiration: (@MainActor @Sendable () -> Void)?
    var events: [String] = []
    func start(identifier: Int?, expireDuringBegin: Bool = false) -> TransferBackgroundActivity<Int> {
        TransferBackgroundActivity(begin: { [self] handler in
            expiration = handler
            if expireDuringBegin { handler() }
            return identifier
        }, end: { [self] in events.append("end:\($0)") },
           onExpiration: { [self] in events.append("expire") })
    }
}
