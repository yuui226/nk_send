import XCTest
@testable import ZTransfer

final class PhotoEffectsBatchSessionTests: XCTestCase {
    private func asset(_ id: String) -> IOSPhotoEffectAsset {
        IOSPhotoEffectAsset(id: id, url: URL(fileURLWithPath: "/tmp/\(id).jpg"), displayName: id)
    }

    @MainActor
    func testSelectionDeduplicatesAndPreviewWraps() {
        let session = PhotoEffectsBatchSession()
        session.replaceSelection([asset("a"), asset("a"), asset("b"), asset("c")])
        XCTAssertEqual(session.selectedCount, 3)
        XCTAssertEqual(session.currentAsset?.id, "a")

        session.movePreview(by: -1)
        XCTAssertEqual(session.currentAsset?.id, "c")
        session.movePreview(by: 1)
        XCTAssertEqual(session.currentAsset?.id, "a")
    }

    @MainActor
    func testBatchStatusKeepsDenominatorAndReportsFailures() async {
        let session = PhotoEffectsBatchSession()
        session.replaceSelection([asset("a"), asset("b"), asset("c")])
        let lock = NSLock()
        var processed: [String] = []

        session.generateAndSave { item in
            lock.lock(); processed.append(item.id); lock.unlock()
            if item.id == "b" { return false }
            return true
        }

        for _ in 0..<100 where session.isGenerating {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.selectedCount, 3)
        XCTAssertEqual(Set(processed), Set(["a", "b", "c"]))
        XCTAssertEqual(session.status, .finished(saved: 2, failed: 1))
    }
}
