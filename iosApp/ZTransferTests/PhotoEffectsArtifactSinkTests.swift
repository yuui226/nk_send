import XCTest
@testable import ZTransfer

final class PhotoEffectsArtifactSinkTests: XCTestCase {
    func testReplacementRemovesPreviousFileAndClearRemovesLatest() throws {
        let sink = PhotoEffectsArtifactSink()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-effects-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.jpg")
        let second = directory.appendingPathComponent("second.jpg")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)

        sink.replace(PhotoEffectsRenderedFile(assetID: "asset", url: first))
        sink.replace(PhotoEffectsRenderedFile(assetID: "asset", url: second))

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(sink.snapshot().map(\.url), [second])

        sink.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(sink.snapshot().isEmpty)
    }
}
