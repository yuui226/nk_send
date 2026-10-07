import XCTest
@testable import ZTransfer

@MainActor
final class RemoteViewfinderInputLifecycleTests: XCTestCase {
    func testUnchangedIdentityRetainsPendingTapAndChangedIdentityCancelsIt() async throws {
        let identity = RemoteViewfinderInputIdentity(aspect: 1.5, imageSize: CGSize(width: 600, height: 400))
        let retained = RemoteViewfinderInput.Surface()
        var received: [CGPoint] = []
        retained.onTap = { received.append($0) }
        retained.updateIdentity(identity)
        retained.finishTap(at: CGPoint(x: 20, y: 30), timestamp: 0)
        retained.updateIdentity(identity)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(received, [CGPoint(x: 20, y: 30)])

        for changed in [
            RemoteViewfinderInputIdentity(aspect: 3, imageSize: identity.imageSize),
            RemoteViewfinderInputIdentity(aspect: 1.5, imageSize: CGSize(width: 1200, height: 800)),
            RemoteViewfinderInputIdentity(aspect: 1.5, imageSize: identity.imageSize,
                metadata: .init(focusJudgement: .focused, selectedFocusFrame: nil,
                    trackingCoordinateWidth: 2000, trackingCoordinateHeight: 1200,
                    focusCoordinateWidth: 200, focusCoordinateHeight: 120, soundLevels: nil))
        ] {
            let view = RemoteViewfinderInput.Surface()
            var called = false
            view.onTap = { _ in called = true }
            view.updateIdentity(identity)
            view.finishTap(at: CGPoint(x: 20, y: 30), timestamp: 0)
            view.updateIdentity(changed)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(called)
        }
    }

    func testDetachCancelsPendingTap() async throws {
        let view = RemoteViewfinderInput.Surface()
        var called = false
        view.onTap = { _ in called = true }
        view.finishTap(at: .zero, timestamp: 0)
        view.clear()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(called)
    }
}
