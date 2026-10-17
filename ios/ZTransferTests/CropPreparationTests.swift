import XCTest
@testable import ZTransfer

final class CropPreparationTests: XCTestCase {
    func testPreviewAdmissionPrioritizesDirectoryAndRequiresConnection() {
        XCTAssertEqual(CropPreviewAdmission(hasDirectory: false, connected: false), .directoryRequired)
        XCTAssertEqual(CropPreviewAdmission(hasDirectory: false, connected: true), .directoryRequired)
        XCTAssertEqual(CropPreviewAdmission(hasDirectory: true, connected: false), .disconnected)
        XCTAssertEqual(CropPreviewAdmission(hasDirectory: true, connected: true), .accepted)
    }

    func testCachedDirectionWorksOfflineAndMissingDirectionRequiresConnection() async throws {
        let cached = try await cropPreparationOrientation(cached: 6, connected: false) {
            XCTFail("Cached EXIF must not read the camera")
            return Data()
        }
        XCTAssertEqual(cached, 6)
        do {
            _ = try await cropPreparationOrientation(cached: nil, connected: false) {
                XCTFail("Offline preparation must not read the camera")
                return Data()
            }
            XCTFail("Missing offline direction must fail")
        } catch let error as CropPreparationError { XCTAssertEqual(error, .connection()) }
        do {
            _ = try await cropPreparationOrientation(cached: nil, connected: true) { Data([0xff, 0xd8]) }
            XCTFail("Truncated header must fail")
        } catch let error as CropPreparationError { XCTAssertEqual(error, .orientation()) }
    }

    func testCancelledSlowHeaderCannotBecomePreparedDirection() async throws {
        let gate = CropHeaderGate()
        let operation = Task {
            try await cropPreparationOrientation(cached: nil, connected: true) { await gate.read() }
        }
        for _ in 0..<1000 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let started = await gate.started
        XCTAssertTrue(started)
        operation.cancel()
        await gate.finish()
        do {
            _ = try await operation.value
            XCTFail("Late camera result must remain cancelled")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOrientationPrefixDoesNotRequireOriginalGeometry() {
        for orientation: UInt8 in 1...8 {
            let tiff: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0,
                0x12, 1, 3, 0, 1, 0, 0, 0, orientation, 0, 0, 0, 0, 0, 0, 0]
            let bytes = Data([0xff, 0xd8, 0xff, 0xe1, 0, 34, 69, 120, 105, 102, 0, 0] + tiff)
            XCTAssertEqual(parseJpegCropOrientation(bytes), Int(orientation))
            XCTAssertNil(parseJpegCropHeader(bytes))
            XCTAssertNil(parseJpegCropOrientation(bytes.dropLast()))
        }
        XCTAssertEqual(parseJpegCropOrientation(Data([0xff, 0xd8, 0xff, 0xda, 0, 2])), 1)
        XCTAssertNil(parseJpegCropOrientation(Data([0xff, 0xd8, 0xff, 0xe1, 0, 34])))
    }

    func testDiagnosticDetailCannotChangeRetryClassification() {
        for detail in ["", "EXIF 2", "Unsupported orientation", "方向信息损坏"] {
            for (error, expected) in [(CropPreparationError.orientation(detail: detail), true),
                                      (.previewRead(detail: detail), true), (.connection(detail: detail), true), (.unavailable(detail: detail), true)] {
                XCTAssertEqual(error.canRetry, expected)
                XCTAssertEqual(cropPreparationCanRetry(error), expected)
                XCTAssertEqual(CropPreparationState.failed(error).isRetryable, expected)
            }
        }
    }

    func testAllPreparationFailuresExposeAndroidRetry() {
        XCTAssertTrue(cropPreparationCanRetry(.orientation(detail: "bad exif")))
        XCTAssertTrue(cropPreparationCanRetry(.previewRead(detail: "timeout")))
        XCTAssertTrue(cropPreparationCanRetry(.connection(detail: "offline")))
    }
}

private actor CropHeaderGate {
    private var continuation: CheckedContinuation<Data, Never>?
    private var finished = false
    var started: Bool { continuation != nil }
    func read() async -> Data {
        if finished { return Data([0xff, 0xd8, 0xff, 0xda, 0, 2]) }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        finished = true
        continuation?.resume(returning: Data([0xff, 0xd8, 0xff, 0xda, 0, 2]))
        continuation = nil
    }
}
