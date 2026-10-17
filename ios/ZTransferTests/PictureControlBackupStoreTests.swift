import XCTest
@testable import ZTransfer

final class PictureControlBackupStoreTests: XCTestCase {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testFirstOriginalSurvivesStoreRecreationWithBodyBankAndSlotIsolation() throws {
        let directory = try folder()
        let identity = "Nikon\0Z 30\0相机😀\0picture-control-photo"
        let original = try PictureControlSlotSnapshot(cameraIdentity: identity, slot: 209, data: Data([1, 2, 3]), selection: 5)
        let store = PictureControlBackupStore(directory: directory)
        XCTAssertEqual(try store.saveOriginal(original), original)
        let other = try PictureControlSlotSnapshot(cameraIdentity: identity, slot: 209, data: Data([9]), selection: 209)
        XCTAssertEqual(try PictureControlBackupStore(directory: directory).saveOriginal(other), original)
        XCTAssertEqual(try store.load(identity: identity, slot: 209), original)
        XCTAssertNil(try store.load(identity: identity, slot: 208))
        XCTAssertNil(try store.load(identity: identity.replacingOccurrences(of: "photo", with: "movie"), slot: 209))
        XCTAssertNil(try store.load(identity: identity + "other", slot: 209))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let bytes = try Data(contentsOf: files[0])
        XCTAssertEqual(Array(bytes.prefix(8)), [0x5A, 0x54, 0x50, 0x43, 0, 0, 0, 2])
        XCTAssertNotNil(bytes.range(of: Data([0xC0, 0x80])))
        XCTAssertNotNil(bytes.range(of: Data([0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80])))
    }
    func testEmptyOriginalIsExplicitAndCorruptionCannotBeReplaced() throws {
        let directory = try folder()
        let store = PictureControlBackupStore(directory: directory)
        let original = try PictureControlSlotSnapshot(cameraIdentity: "body", slot: 201, data: nil, selection: 1)
        XCTAssertEqual(try store.saveOriginal(original), original)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var bytes = try Data(contentsOf: file)
        bytes.removeLast()
        try bytes.write(to: file)
        XCTAssertThrowsError(try store.load(identity: "body", slot: 201))
        XCTAssertThrowsError(try store.saveOriginal(PictureControlSlotSnapshot(cameraIdentity: "body", slot: 201, data: Data([9]))))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testConcurrentStoreInstancesPublishOnlyOneOriginal() async throws {
        let directory = try folder()
        let snapshots = try (1...12).map {
            try PictureControlSlotSnapshot(cameraIdentity: "body", slot: 209, data: Data([UInt8($0)]), selection: 1)
        }
        let saved = try await withThrowingTaskGroup(of: PictureControlSlotSnapshot.self) { group in
            for snapshot in snapshots {
                group.addTask { try PictureControlBackupStore(directory: directory).saveOriginal(snapshot) }
            }
            var results: [PictureControlSlotSnapshot] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(saved.count, 12)
        XCTAssertTrue(saved.allSatisfy { $0 == saved[0] })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }
}
