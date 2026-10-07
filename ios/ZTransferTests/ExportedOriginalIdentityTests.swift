import XCTest
@testable import ZTransfer

/// Android ExistingFileNameIndexTest: AP real names and STA inferred names
/// share number/type identity without changing filename reservation behavior.
final class ExportedOriginalIdentityTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/exports", isDirectory: true)
    private func file(_ name: String, size: UInt64 = 123) -> CameraFile {
        CameraFile(id: 99, storageID: 1, format: 0x3801, size: size,
                   fileName: name, captureDate: "20260929T120000", isProtected: false)
    }

    func testDifferentPrefixesMatchOnlySameNumberTypeSizeAndDirectory() {
        var index = TransferDirectoryIndex(directory: root)
        let copy = root.appendingPathComponent("DSC_9049 (2).JPG")
        index.addOriginal(copy, size: 123)
        XCTAssertEqual(index.existingOriginal(for: file("Z30_9049.jpg")), copy)
        XCTAssertNil(index.existingOriginal(for: file("Z30_9049.NEF")))
        XCTAssertNil(index.existingOriginal(for: file("Z30_9049.JPG", size: 124)))
        XCTAssertNil(index.existingOriginal(for: file("Z30_9050.JPG")))
        XCTAssertEqual(index.existingOriginal(for: file("Z30_9049.JPG", size: UInt64(UInt32.max))), copy)

        var exported = ExportedOriginalIndex()
        exported.add(copy, size: 123, folderName: "ZT2026-09-29")
        XCTAssertEqual(exported.original(for: file("Z30_9049.JPG"), folderName: "ZT2026-09-29"), copy)
        XCTAssertNil(exported.original(for: file("Z30_9049.JPG"), folderName: nil))
        XCTAssertNil(exported.original(for: file("Z30_9049.JPG"), folderName: "ZT2026-09-28"))
        XCTAssertNil(exported.original(for: file("Z30_9049.NEF"), folderName: "ZT2026-09-29"))
        XCTAssertNil(exported.original(for: file("Z30_9049.JPG", size: 124), folderName: "ZT2026-09-29"))
    }

    func testExactNameWinsAndReplacementRemovesOldSize() {
        var index = TransferDirectoryIndex(directory: root)
        let copy = root.appendingPathComponent("DSC_0001 (2).JPG")
        let exact = root.appendingPathComponent("DSC_0001.JPG")
        index.addOriginal(copy, size: 123)
        index.addOriginal(exact, size: 123)
        XCTAssertEqual(index.existingOriginal(for: file("DSC_0001.JPG")), exact)
        XCTAssertEqual(index.existingOriginal(for: file("dsc_0001.jpg")), copy)
        index.addOriginal(copy, size: 120)
        index.addOriginal(exact, size: 120)
        XCTAssertNil(index.existingOriginal(for: file("Z30_0001.JPG")))
        XCTAssertEqual(index.existingOriginal(for: file("Z30_0001.JPG", size: 120)), copy)
    }

    func testVideosCropsNonNumericNamesAndLeadingZeros() {
        var index = TransferDirectoryIndex(directory: root)
        for name in ["DSC_9053.MP4", "DSC_9049_crop.JPG", "holiday.JPG", "DSC_0001.JPG"] {
            index.addOriginal(root.appendingPathComponent(name), size: 123)
        }
        XCTAssertNotNil(index.existingOriginal(for: file("Z30_9053.mp4")))
        for name in ["Z30_9053.MOV", "Z30_9049.JPG", "trip.JPG", "Z30_1.JPG"] {
            XCTAssertNil(index.existingOriginal(for: file(name)))
        }
        XCTAssertNotNil(index.existingOriginal(for: file("HOLIDAY.jpg")))
    }

    func testDiskScanAndExportMergeUseTheSameCrossModeIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("DSC_9049 (2).JPG")
        try Data(count: 123).write(to: output)
        let index = TransferDirectoryIndex.scan(directory: directory)
        XCTAssertEqual(index.existingOriginal(for: file("Z30_9049.JPG")), output)
        XCTAssertEqual(existingTransferDestination(for: file("Z30_9049.JPG"), in: directory), output)
        var exported = ExportedOriginalIndex()
        exported.merge(index, folderName: nil)
        XCTAssertEqual(exported.original(for: file("Z30_9049.JPG"), folderName: nil), output)
    }
}
