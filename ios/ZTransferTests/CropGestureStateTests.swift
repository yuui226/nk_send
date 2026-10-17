import XCTest
@testable import ZTransfer

final class CropGestureStateTests: XCTestCase {
    func testTouchOwnershipChangesFromCornerToPinchAndStaysTransformAfterLift() throws {
        var input = CropTouchState<Int>()
        input.begin([1: CGPoint(x: 10, y: 20)]) { _ in 0 }
        let drag = try XCTUnwrap(input.move([1: CGPoint(x: 14, y: 26)]))
        XCTAssertEqual(drag.corner, 0)
        XCTAssertEqual(drag.pan, CGSize(width: 4, height: 6))
        XCTAssertEqual(drag.zoom, 1)
        input.begin([2: CGPoint(x: 34, y: 26)]) { _ in XCTFail("Second finger must not pick a corner"); return 2 }
        let pinch = try XCTUnwrap(input.move([1: CGPoint(x: 4, y: 30), 2: CGPoint(x: 44, y: 30)]))
        XCTAssertNil(pinch.corner)
        XCTAssertEqual(pinch.centroid, CGPoint(x: 24, y: 30))
        XCTAssertEqual(pinch.pan, CGSize(width: 0, height: 4))
        XCTAssertEqual(pinch.zoom, 2)
        input.end([2])
        let remaining = try XCTUnwrap(input.move([1: CGPoint(x: 9, y: 33)]))
        XCTAssertNil(remaining.corner)
        XCTAssertEqual(remaining.pan, CGSize(width: 5, height: 3))
        XCTAssertEqual(remaining.zoom, 1)
        input.end([1])
        input.begin([3: CGPoint(x: 1, y: 1)]) { _ in 3 }
        XCTAssertEqual(input.corner, 3)
    }

    func testTouchCancellationAndIncompleteEventsCannotReuseOldPositions() throws {
        var input = CropTouchState<Int>()
        input.begin([1: CGPoint(x: 10, y: 20)]) { _ in 0 }
        XCTAssertNil(input.move([:]))
        XCTAssertNil(input.move([1: CGPoint(x: CGFloat.nan, y: 0)]))
        XCTAssertEqual(input.points[1], CGPoint(x: 10, y: 20))
        input.reset()
        XCTAssertNil(input.move([1: CGPoint(x: 100, y: 200)]))
        input.begin([2: CGPoint(x: 500, y: 600), 3: CGPoint(x: 700, y: 600)]) { _ in 2 }
        XCTAssertNil(input.corner)
        let moved = try XCTUnwrap(input.move([2: CGPoint(x: 501, y: 602), 3: CGPoint(x: 701, y: 602)]))
        XCTAssertEqual(moved.pan, CGSize(width: 1, height: 2))
        XCTAssertEqual(moved.zoom, 1)
    }

    func testCornerHitTestingAndTinySourceZoomStayRepresentable() throws {
        var editor = CropEditorGeometry(source: .init(width: 32, height: 24, mcuWidth: 1, mcuHeight: 1, orientation: 1))
        try editor.resize(CGSize(width: 900, height: 1500))
        XCTAssertEqual(editor.corner(at: CGPoint(x: editor.frame.minX + 10, y: editor.frame.minY + 10)), 0)
        XCTAssertEqual(editor.corner(at: CGPoint(x: editor.frame.maxX, y: editor.frame.minY)), 1)
        XCTAssertEqual(editor.corner(at: CGPoint(x: editor.frame.maxX, y: editor.frame.maxY)), 2)
        XCTAssertEqual(editor.corner(at: CGPoint(x: editor.frame.minX, y: editor.frame.maxY)), 3)
        XCTAssertNil(editor.corner(at: CGPoint(x: editor.frame.midX, y: editor.frame.midY)))
        editor.select(.fixed(16, 9))
        for _ in 0..<20 {
            try editor.transform(centroid: CGPoint(x: editor.frame.midX, y: editor.frame.midY), pan: .zero, zoom: 1000)
            let recipe = try editor.recipe()
            XCTAssertGreaterThanOrEqual(recipe.rect.width, 16)
            XCTAssertGreaterThanOrEqual(recipe.rect.height, 9)
            XCTAssertEqual(recipe.rect.width * 9, recipe.rect.height * 16)
        }
        editor.reset()
        XCTAssertEqual(try editor.recipe().rect, CropRect(left: 0, top: 0, right: 32, bottom: 24))
    }

    func testPixelGeometryRatiosRemainStableAcrossTwentyRoundTrips() throws {
        for dimensions in [(6000, 4000), (4000, 6000), (6017, 4003)] {
            var editor = CropEditorGeometry(source: .init(width: dimensions.0, height: dimensions.1,
                mcuWidth: 1, mcuHeight: 1, orientation: 1))
            try editor.resize(CGSize(width: 1080, height: 1920))
            let image = editor.image, original = editor.frame
            for _ in 0..<20 {
                editor.select(.fixed(1, 1))
                let square = editor.frame
                for (w, h) in [(3,2),(4,3),(5,4),(16,9),(2,1),(2,3),(3,4),(4,5),(9,16),(1,2)] {
                    editor.select(.fixed(w, h))
                    XCTAssertEqual(editor.frame.width / editor.frame.height, Double(w) / Double(h), accuracy: 0.00001)
                    XCTAssertEqual(editor.image, image)
                }
                editor.select(.fixed(1, 1)); XCTAssertEqual(editor.frame, square)
                editor.select(.original); XCTAssertEqual(editor.frame, original)
                XCTAssertEqual(editor.selection(orientation: 1).ratioWidth, 0)
                XCTAssertEqual(editor.selection(orientation: 1).ratioHeight, 0)
            }
        }
    }

    func testPixelGeometrySwapsAndManualReferenceMatchAndroid() throws {
        var editor = CropEditorGeometry(source: .init(width: 6000, height: 4000, mcuWidth: 1, mcuHeight: 1, orientation: 1))
        try editor.resize(CGSize(width: 1080, height: 1920))
        editor.select(.fixed(3, 2)); let before = editor.frame
        editor.select(editor.ratio, flip: true); XCTAssertEqual(editor.ratio, .fixed(2, 3))
        editor.select(editor.ratio, flip: true); XCTAssertEqual(editor.frame, before)
        editor.select(.fixed(1, 1))
        try editor.dragCorner(0, pan: CGSize(width: 100, height: 100), minimum: 48)
        let manual = editor.frame
        for _ in 0..<20 {
            editor.select(.fixed(9, 16)); editor.select(.fixed(1, 1))
            XCTAssertEqual(editor.frame, manual)
        }
    }

    func testPixelGeometryPanZoomResizeAndPixelLimits() throws {
        for orientation in 1...8 {
            var editor = CropEditorGeometry(source: .init(width: 6048, height: 4024,
                mcuWidth: 16, mcuHeight: 8, orientation: orientation))
            try editor.resize(CGSize(width: 900, height: 1500))
            for ratio: CropEditorGeometry.Ratio in [.original, .free, .fixed(1,1), .fixed(16,9), .fixed(9,16)] {
                editor.select(ratio)
                try editor.transform(centroid: CGPoint(x: editor.frame.midX, y: editor.frame.midY),
                    pan: CGSize(width: 9000, height: -8000), zoom: 3)
                let before = try editor.recipe()
                let frame = try editor.alignedFrame()
                XCTAssertGreaterThanOrEqual(frame.minX, -1); XCTAssertGreaterThanOrEqual(frame.minY, -1)
                XCTAssertLessThanOrEqual(frame.maxX, editor.size.width + 1)
                XCTAssertLessThanOrEqual(frame.maxY, editor.size.height + 1)
                try editor.resize(CGSize(width: 1500, height: 900))
                let after = try editor.recipe()
                XCTAssertLessThanOrEqual(abs(before.rect.left - after.rect.left), 16)
                XCTAssertLessThanOrEqual(abs(before.rect.top - after.rect.top), 8)
            }
        }
    }

}
