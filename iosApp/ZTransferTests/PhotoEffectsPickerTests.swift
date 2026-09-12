import XCTest
import PhotosUI
import UniformTypeIdentifiers
@testable import ZTransfer

final class PhotoEffectsPickerTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    func testSelectionCopiesHaveUniqueNamesAndLastAssetOwnsTheirDirectory() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        var files: PhotoEffectsInputFiles? = try PhotoEffectsInputFiles()
        weak var lifetime = files
        var first: IOSPhotoEffectAsset? = try files!.copy(source, assetID: "first", displayName: nil, fallbackExtension: "jpg")
        var second: IOSPhotoEffectAsset? = try files!.copy(source, assetID: "second", displayName: nil, fallbackExtension: "jpg")
        let firstURL = try XCTUnwrap(first?.url), secondURL = try XCTUnwrap(second?.url)
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(firstURL.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: secondURL), Data([1, 2, 3]))
        files = nil; first = nil
        XCTAssertNotNil(lifetime)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(second?.id, "second")
        second = nil
        XCTAssertNil(lifetime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    @MainActor
    func testReplacingSelectionReleasesOnlyItsPrivateCopies() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let session = PhotoEffectsBatchSession()
        let copy: URL = try {
            let owner = try PhotoEffectsInputFiles()
            let asset = try owner.copy(source, assetID: "old", displayName: nil, fallbackExtension: "jpg")
            session.replaceSelection([asset])
            return asset.url
        }()
        session.replaceSelection([IOSPhotoEffectAsset(id: "external", url: source, displayName: "original")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        session.removeCurrent()
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    func testProviderRepresentationIsCopiedBeforeItsTemporaryFileExpires() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let provider = NSItemProvider()
        provider.suggestedName = "selected.jpg"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        let files = try PhotoEffectsInputFiles()
        let asset = try await PhotoEffectsPickerLoad().load(provider, into: files, assetID: "selected")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(asset.id, "selected")
        XCTAssertEqual(asset.displayName, "selected.jpg")
        XCTAssertEqual(try Data(contentsOf: asset.url), Data([1, 2, 3]))
    }

    func testCancelledProviderLoadReturnsWithoutWaitingForItsCallback() async throws {
        let files = try PhotoEffectsInputFiles()
        let provider = NSItemProvider()
        let began = expectation(description: "provider awaiting network")
        let providerCancelled = expectation(description: "provider cancellation forwarded")
        provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            progress.cancellationHandler = {
                completion(nil, false, CancellationError())
                providerCancelled.fulfill()
            }
            began.fulfill()
            return progress
        }
        let returned = expectation(description: "cancelled load returned")
        let task = Task {
            do { _ = try await PhotoEffectsPickerLoad().load(provider, into: files, assetID: nil); XCTFail("expected cancellation") }
            catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
            returned.fulfill()
        }
        await fulfillment(of: [began], timeout: 3)
        task.cancel()
        await fulfillment(of: [returned, providerCancelled], timeout: 3)
        await task.value
    }

    @MainActor
    func testCancelledPickerLeavesExistingSelectionUntouched() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let session = PhotoEffectsBatchSession()
        let existing = IOSPhotoEffectAsset(id: "existing", url: source, displayName: "existing")
        session.replaceSelection([existing])
        var wasCancelled = false
        let coordinator = PhotoEffectsPicker.Coordinator { result in
            if case .cancelled = result { wasCancelled = true }
            if case let .selected(assets, _) = result { session.replaceSelection(assets) }
        }
        coordinator.picker(PHPickerViewController(configuration: PHPickerConfiguration()), didFinishPicking: [])
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(session.assets, [existing])
    }
}
