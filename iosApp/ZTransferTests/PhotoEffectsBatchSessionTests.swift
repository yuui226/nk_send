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

    @MainActor
    func testRetryProcessesOnlyFailedAssets() async {
        let session = PhotoEffectsBatchSession()
        session.replaceSelection([asset("a"), asset("b")])
        let lock = NSLock()
        var attempts: [String: Int] = [:]

        session.generateAndSave { item in
            lock.lock(); attempts[item.id, default: 0] += 1; let count = attempts[item.id]!; lock.unlock()
            return item.id == "a" || count > 1
        }
        for _ in 0..<100 where session.isGenerating {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.failedAssets.map(\.id), ["b"])
        XCTAssertTrue(session.canRetryFailed)

        session.retryFailed()
        for _ in 0..<100 where session.isGenerating {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(attempts["a"], 1)
        XCTAssertEqual(attempts["b"], 2)
        XCTAssertEqual(session.failedAssets, [])
        XCTAssertEqual(session.status, .finished(saved: 1, failed: 0))
    }
}
