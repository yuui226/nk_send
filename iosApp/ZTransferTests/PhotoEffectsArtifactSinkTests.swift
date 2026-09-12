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

        sink.replace(PhotoEffectsRenderedFile(assetID: "asset", ownedURL: first))
        sink.replace(PhotoEffectsRenderedFile(assetID: "asset", ownedURL: second))

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(sink.snapshot().map(\.url), [second])

        sink.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(sink.snapshot().isEmpty)
    }

    func testSnapshotOutlivesClearAndRepeatedReplacementDoesNotDeleteItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([7]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = PhotoEffectsArtifactSink()
        sink.replace(PhotoEffectsRenderedFile(assetID: "asset", ownedURL: url))
        var retained = sink.snapshot()
        sink.replace(retained[0])
        sink.clear()
        XCTAssertEqual(try Data(contentsOf: url), Data([7]))
        retained.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testFilesAndShareCoordinatorsKeepArtifactsThroughTheirSheetLifetime() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([8]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = PhotoEffectsArtifactSink()
        sink.replace(PhotoEffectsRenderedFile(assetID: "asset", ownedURL: url))
        var files: PhotoEffectsDocumentExporter.Coordinator? = .init(files: sink.snapshot(), completion: { _ in })
        var share: PhotoEffectsShareSheet.Coordinator? = .init(files: sink.snapshot(), completion: {})
        sink.clear()
        XCTAssertEqual(files?.files.count, 1)
        XCTAssertEqual(share?.files.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        files = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        share = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testSessionReleasesItsArtifactsWhenLastOwnerCloses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([9]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var session: PhotoEffectsBatchSession? = PhotoEffectsBatchSession()
        session?.artifacts.replace(PhotoEffectsRenderedFile(assetID: "asset", ownedURL: url))
        XCTAssertEqual(session?.artifacts.snapshot().count, 1)
        session = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
