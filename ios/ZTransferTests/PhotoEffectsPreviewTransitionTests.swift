import XCTest
@testable import ZTransfer

final class PhotoEffectsPreviewTransitionTests: XCTestCase {
    private struct Frame: Equatable {
        let image: Int
        var canvas = "plain"
        var comparison = false
    }
    private func plan(_ current: Frame?, _ next: Frame?, _ canvas: String = "plain") -> PhotoEffectsPreviewTransition<Frame> {
        planPhotoEffectsPreviewTransition(current: current, next: next, requestedCanvas: canvas,
            canvasOf: { $0.canvas }, sameImage: { $0.image == $1.image })
    }

    func testNoResultAndOutdatedFirstCanvasDoNotInstallAnyFrame() {
        XCTAssertNil(plan(nil, nil).frame)
        let stale = plan(nil, Frame(image: 1), "rotated")
        XCTAssertEqual(stale.change, .keep); XCTAssertNil(stale.frame)
        let ready = Frame(image: 2, canvas: "rotated")
        let first = plan(stale.frame, ready, "rotated")
        XCTAssertEqual(first.change, .initial); XCTAssertEqual(first.frame, ready)
    }

    func testRotationReversalRejectsLateResultAndRestoresOriginalCanvas() {
        let original = Frame(image: 1)
        XCTAssertFalse(photoEffectsPreviewCanvasVisible(displayedCanvas: original.canvas, requestedCanvas: "rotated", failed: false))
        let late = plan(original, Frame(image: 2, canvas: "rotated"))
        XCTAssertEqual(late.change, .keep); XCTAssertEqual(late.frame, original)
        XCTAssertTrue(photoEffectsPreviewCanvasVisible(displayedCanvas: original.canvas, requestedCanvas: "plain", failed: false))
    }

    func testBorderChangeReplacesCanvasButRevertedBorderResultIsIgnored() {
        let original = Frame(image: 1), bordered = Frame(image: 2, canvas: "border")
        XCTAssertEqual(plan(original, bordered, "border").change, .replaceCanvas)
        XCTAssertEqual(plan(original, bordered).frame, original)
        XCTAssertEqual(plan(original, bordered).change, .keep)
    }

    func testFailureRevealsExistingCanvasUntilRecovery() {
        let original = Frame(image: 1)
        XCTAssertEqual(plan(original, original, "new").change, .keep)
        for (failed, visible) in [(false, false), (true, true), (false, false)] {
            XCTAssertEqual(photoEffectsPreviewCanvasVisible(displayedCanvas: original.canvas,
                requestedCanvas: "new", failed: failed), visible)
        }
        XCTAssertEqual(plan(original, Frame(image: 2, canvas: "new"), "new").change, .replaceCanvas)
    }

    func testComparisonOnlyUpdatesDataWhileNewPixelsCrossfade() {
        let original = Frame(image: 1)
        XCTAssertEqual(plan(nil, original).change, .initial)
        let comparison = plan(original, Frame(image: 1, comparison: true))
        XCTAssertEqual(comparison.change, .update)
        XCTAssertEqual(comparison.frame?.comparison, true)
        XCTAssertEqual(plan(original, Frame(image: 2)).change, .crossfade)
    }

    @MainActor
    func testFirstAcceptedFadeCompletesBeforeLatestPendingExifOrFHDFrame() async throws {
        let queue = ConflatedPreviewUpdates<Frame>()
        let started = expectation(description: "first accepted"), completed = expectation(description: "latest accepted")
        var release: CheckedContinuation<Void, Never>?
        var visible: Frame?, seen: [Int] = [], changes: [PhotoEffectsPreviewChange] = []
        let operation: @MainActor (Frame, @escaping @MainActor () -> Frame) async -> Void = { next, _ in
            let transition = self.plan(visible, next)
            visible = transition.frame; seen.append(next.image); changes.append(transition.change)
            if next.image == 1 {
                await withCheckedContinuation { release = $0; started.fulfill() }
                XCTAssertFalse(Task.isCancelled)
            } else { completed.fulfill() }
        }
        queue.submit(Frame(image: 1), operation: operation)
        await fulfillment(of: [started], timeout: 2)
        queue.submit(Frame(image: 2), operation: operation)
        queue.submit(Frame(image: 3), operation: operation)
        XCTAssertEqual(visible?.image, 1); XCTAssertEqual(seen, [1])
        release?.resume()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(seen, [1, 3]); XCTAssertEqual(changes, [.initial, .crossfade])
        queue.close()
    }

    @MainActor
    func testCancelledFirstFadeDropsPendingAndReentryUpdatesAcceptedIdentity() async throws {
        let queue = ConflatedPreviewUpdates<Frame>()
        let started = expectation(description: "first accepted"), cancelled = expectation(description: "cancelled")
        let returned = expectation(description: "accepted identity restored")
        var visible: Frame?
        queue.submit(Frame(image: 1)) { next, _ in
            visible = self.plan(visible, next).frame; started.fulfill()
            do { try await Task.sleep(for: .seconds(30)); XCTFail("Must cancel") }
            catch { cancelled.fulfill() }
        }
        await fulfillment(of: [started], timeout: 2)
        queue.submit(Frame(image: 2)) { _, _ in XCTFail("Old pending frame must be discarded") }
        queue.close()
        queue.submit(Frame(image: 1, comparison: true)) { next, _ in
            let transition = self.plan(visible, next)
            XCTAssertEqual(transition.change, .update)
            XCTAssertEqual(transition.frame?.comparison, true)
            returned.fulfill()
        }
        await fulfillment(of: [cancelled, returned], timeout: 2)
        queue.close()
    }
}
