import SwiftUI
import UIKit
import XCTest
@testable import ZTransfer

@MainActor
final class QueueRemovalLayoutTests: XCTestCase {
    private struct Host: View {
        @ObservedObject var model: TransferQueueViewModel
        @ObservedObject var removal: QueueRemovalCoordinator
        var body: some View {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.snapshot.items) { item in
                        QueueItemView(item: item, session: nil, activeProgress: nil,
                            isRemoving: removal.removingIDs.contains(item.id) && item.status != .waiting,
                            isClearing: removal.isClearing, retryEnabled: false, onRetry: {}, onWithdraw: {},
                            removalValue: removal.value(for: item.id), removalCoordinator: removal)
                        .modifier(QueueItemPlacement(enabled: removal.removingIDs.isEmpty))
                    }
                }
                .coordinateSpace(name: QueueItemPlacement.coordinateSpace)
                .padding(12)
            }
            .frame(width: 320, height: 216)
            .background(ZTransferColors.background)
            .onChange(of: model.snapshot.items.map(\.id)) { removal.synchronize(liveIDs: Set($0)) }
        }
    }

    func testRealViewportSelectionFadesBeforeHeightAndRemovesOnlyInitialVisibleRows() async throws {
        let suite = "queue-removal-layout.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!)
        let ids = await queue.enqueue((1...8).map { CameraFile(id: UInt32($0), storageID: 1, format: 0x3801,
            size: 1024, fileName: "DSC_\($0).JPG", captureDate: nil, isProtected: false) })
        let model = TransferQueueViewModel(queue: queue), removal = QueueRemovalCoordinator(automaticFrames: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 260)
        window.rootViewController = UIHostingController(rootView: Host(model: model, removal: removal)
            .environment(\.scenePhase, .active).environment(\.colorScheme, .light))
        window.makeKeyAndVisible()
        defer { removal.leave(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let visible = markers(window).filter { $0.visibleOffset != nil }.sorted { $0.visibleOffset! < $1.visibleOffset! }
        XCTAssertGreaterThanOrEqual(visible.count, 2); XCTAssertLessThan(visible.count, ids.count)
        let first = try XCTUnwrap(visible.first), second = try XCTUnwrap(visible.dropFirst().first)
        let initialDistance = second.convert(.zero, to: window).y - first.convert(.zero, to: window).y
        try capture(window, name: "initial")

        removal.clear(model: model)
        let deadline = ContinuousClock.now + .seconds(3)
        while !removal.isWaitingForFrames || model.snapshot.items.count != visible.count {
            guard ContinuousClock.now < deadline else { XCTFail("Viewport cleanup did not settle"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(removal.removingIDs, Set(visible.map(\.id)))
        removal.advance(0); removal.advance(50_000_000)
        try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded()
        let earlyDistance = second.convert(.zero, to: window).y - first.convert(.zero, to: window).y
        XCTAssertEqual(earlyDistance, initialDistance, accuracy: 2, "The first ~50ms fades before collapsing height")
        XCTAssertLessThan(queueRemovalOpacity(removal.value(for: first.id).value), 1)
        removal.advance(100_000_000)
        try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded()
        try capture(window, name: "fade-before-collapse")
        // Alpha reaches zero at 280 * .64 = 179.2ms, before height ends.
        removal.advance(200_000_000)
        try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded()
        let collapsedDistance = second.convert(.zero, to: window).y - first.convert(.zero, to: window).y
        XCTAssertLessThan(collapsedDistance, initialDistance - 10)
        XCTAssertEqual(queueRemovalOpacity(removal.value(for: first.id).value), 0)
        XCTAssertGreaterThan(queueRemovalHeight(removal.value(for: first.id).value), 0)
        removal.advance(360_000_000)
        while removal.isClearing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(removal.isClearing); XCTAssertTrue(model.snapshot.items.isEmpty)
    }

    private func markers(_ view: UIView) -> [QueueRemovalAnchor.Marker] {
        (view as? QueueRemovalAnchor.Marker).map { [$0] } ?? view.subviews.flatMap(markers)
    }
    private func capture(_ window: UIWindow, name: String) throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("queue-removal-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: path)
        print("QUEUE_REMOVAL_IMAGE \(path.path)")
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
