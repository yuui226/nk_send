import XCTest
import SwiftUI
@testable import ZTransfer

final class RemoteToolbarGeometryTests: XCTestCase {
    @MainActor
    func testHostedLayoutInvalidatesIntrinsicCacheForResizeAndChangedChildren() async throws {
        let state = LayoutState()
        let host = UIHostingController(rootView: LayoutHarness(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 170, height: 240))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func check(_ expectedWidth: CGFloat) async throws {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let expected = RemoteToolbarGeometry.arrange(items: state.widths.map {
                .init(size: CGSize(width: $0, height: 36))
            }, width: expectedWidth, pinnedEndCount: 1, scale: window.screen.scale)
            XCTAssertEqual(state.frames.count, expected.frames.count)
            for index in expected.frames.indices {
                let actual = try XCTUnwrap(state.frames[index])
                XCTAssertEqual(actual.minX, expected.frames[index].minX, accuracy: 0.5)
                XCTAssertEqual(actual.minY, expected.frames[index].minY, accuracy: 0.5)
                XCTAssertEqual(actual.width, expected.frames[index].width, accuracy: 0.5)
            }
        }
        try await check(170)
        state.widths = [72, 36, 36, 36, 36] // Dynamic intrinsic size and added items.
        try await check(170)
        window.frame.size.width = 330
        try await check(330) // Reflow must use current bounds, not cached positions.
        state.widths = [36, 36] // Hidden/removed controls may not leave stale slots.
        try await check(330)
    }

    @MainActor private final class LayoutState: ObservableObject {
        @Published var widths: [CGFloat] = [36, 36, 36]
        var frames: [Int: CGRect] = [:]
    }
    private struct Frames: PreferenceKey {
        static let defaultValue: [Int: CGRect] = [:]
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }
    private struct LayoutHarness: View {
        @ObservedObject var state: LayoutState
        @Environment(\.displayScale) private var scale
        var body: some View {
            RemoteAdaptiveToolLayout(displayScale: scale, horizontalSpacing: 6,
                                     verticalSpacing: 4, pinnedEndCount: 1) {
                ForEach(state.widths.indices, id: \.self) { index in
                    Color.blue.frame(width: state.widths[index], height: 36)
                        .background { GeometryReader { proxy in
                            Color.clear.preference(key: Frames.self,
                                value: [index: proxy.frame(in: .named("layout-test"))])
                        } }
                }
            }
            .coordinateSpace(name: "layout-test")
            .onPreferenceChange(Frames.self) { state.frames = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func item(_ tool: RemoteTool, width: CGFloat = 36, height: CGFloat = 36) -> RemoteToolbarGeometry.Item {
        .init(size: CGSize(width: width, height: height), tool: tool)
    }

    func testPinnedLockAndRotationStayOnFirstRowAndRegularToolsKeepTheirOrder() throws {
        // RemoteTool.regular no longer contains LOCK. Android RemoteToolBar
        // appends manager + pinned controls and reserves two first-row tracks.
        let regular = RemoteTool.regular.filter { $0.available(movie: false) }
        let items = regular.map { item($0) } + [.init(size: CGSize(width: 36, height: 36))]
            + RemoteTool.pinned.map { item($0) }
        let result = RemoteToolbarGeometry.arrange(items: items, width: 330, pinnedEndCount: 2)
        let lockIndex = try XCTUnwrap(items.firstIndex { $0.tool == .lock })
        let rotateIndex = try XCTUnwrap(items.firstIndex { $0.tool == .rotate })
        XCTAssertEqual(result.frames[lockIndex], CGRect(x: 252, y: 0, width: 36, height: 36))
        XCTAssertEqual(result.frames[rotateIndex], CGRect(x: 294, y: 0, width: 36, height: 36))
        XCTAssertEqual(result.frames[0].origin, .zero)
        XCTAssertEqual(result.frames[6].origin, CGPoint(x: 0, y: 40))
        XCTAssertEqual(result.frames.filter { !$0.isEmpty }.count, items.count)
    }

    func testHidingMostToolsDoesNotSpreadRemainingControlsAcrossRow() {
        let result = RemoteToolbarGeometry.arrange(items: [item(.hd), item(.lock), item(.rotate)],
                                                   width: 330, pinnedEndCount: 1, secondRowFirst: .lock)
        XCTAssertEqual(result.frames.map(\.minX), [0, 42, 294])
        XCTAssertEqual(result.height, 36)
        let minimal = RemoteToolbarGeometry.arrange(items: [item(.rotate)], width: 330, pinnedEndCount: 1)
        XCTAssertEqual(minimal.frames[0], result.frames[2])
    }

    func testWiderTextDefinesSingleTrackAndZeroSizedEntriesConsumeNoSpace() {
        let result = RemoteToolbarGeometry.arrange(items: [item(.hd, width: 38), item(.fps), item(.grid, width: 0), item(.rotate)],
                                                   width: 170, pinnedEndCount: 1)
        XCTAssertEqual(result.frames[0].minX, 0)
        // floor((170 + 6) / (38 + 6)) = 4 tracks, pitch 44;
        // the 36-wide icon is centered one point into its 38-wide cell.
        XCTAssertEqual(result.frames[1].minX, 45)
        XCTAssertEqual(result.frames[2], .zero)
        XCTAssertEqual(result.frames[3].minX, 133)
        XCTAssertEqual(result.height, 36)
    }
}
