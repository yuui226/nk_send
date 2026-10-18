import XCTest
@testable import ZTransfer

final class RemoteToolbarGeometryTests: XCTestCase {
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

    func testRecordingCapsuleSpansColumnsWithoutWideningAllTracks() {
        let result = RemoteToolbarGeometry.arrange(items: [item(.hd), item(.record, width: 78), item(.fps), item(.rotate)],
                                                   width: 162, pinnedEndCount: 1)
        XCTAssertEqual(result.frames[1], CGRect(x: 42, y: 0, width: 78, height: 36))
        XCTAssertEqual(result.frames[2].origin, CGPoint(x: 0, y: 40))
        XCTAssertEqual(result.frames[3].origin, CGPoint(x: 126, y: 0))
        XCTAssertEqual(result.height, 76)
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
