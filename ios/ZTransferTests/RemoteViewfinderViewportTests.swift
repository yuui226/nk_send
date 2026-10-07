import XCTest
@testable import ZTransfer

final class RemoteViewfinderViewportTests: XCTestCase {
    // ViewfinderViewportTest.kt: the two horizon cases are assigned to T08.
    func testCenteredZoomAndPanKeepCropInsideImage() {
        var viewport = RemoteViewfinderViewport()
        let aspect: Float = 5 / 3
        viewport.resize(CGSize(width: 1000, height: 600), aspect: aspect)
        viewport.transform(centroid: CGPoint(x: 500, y: 300), pan: .zero, zoom: 2, aspect: aspect)
        let center = viewport.visibleRegion(aspect: aspect)
        XCTAssertEqual(center.minX, 0.25, accuracy: 0.0001)
        XCTAssertEqual(center.maxX, 0.75, accuracy: 0.0001)
        viewport.transform(centroid: CGPoint(x: 500, y: 300), pan: CGSize(width: 10000, height: -10000), zoom: 1, aspect: aspect)
        let edge = viewport.visibleRegion(aspect: aspect)
        XCTAssertEqual(edge.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(edge.maxY, 1, accuracy: 0.0001)
        viewport.reset()
        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.offset, .zero)
    }

    func testLetterboxAndLayoutResizeKeepVisibleRegionValid() {
        var viewport = RemoteViewfinderViewport()
        viewport.resize(CGSize(width: 1000, height: 1000), aspect: 2)
        let full = viewport.visibleRegion(aspect: 2)
        XCTAssertEqual(full.minY, 0)
        XCTAssertEqual(full.maxY, 1)
        viewport.transform(centroid: CGPoint(x: 500, y: 500), pan: CGSize(width: 0, height: 900), zoom: 2, aspect: 2)
        XCTAssertEqual(viewport.offset.y, 250)
        viewport.resize(CGSize(width: 600, height: 300), aspect: 2)
        let crop = viewport.visibleRegion(aspect: 2)
        XCTAssertGreaterThanOrEqual(crop.minX, 0)
        XCTAssertLessThanOrEqual(crop.maxX, 1)
        XCTAssertGreaterThanOrEqual(crop.minY, 0)
        XCTAssertLessThanOrEqual(crop.maxY, 1)
        viewport.transform(centroid: .zero, pan: .zero, zoom: .nan, aspect: 2)
        XCTAssertEqual(viewport.scale, 2)
    }

    func testVideoCropAspectInSquareAndPortraitPanels() {
        let aspects: [Float] = [16 / 9, 3 / 2, 16 / 9 * 1.5]
        let sizes = [CGSize(width: 1000, height: 1000), CGSize(width: 600, height: 1200), CGSize(width: 1800, height: 700)]
        for aspect in aspects {
            for size in sizes {
                var viewport = RemoteViewfinderViewport()
                viewport.resize(size, aspect: aspect)
                viewport.transform(centroid: CGPoint(x: size.width / 2, y: size.height / 2), pan: .zero, zoom: 2, aspect: aspect)
                let crop = viewport.visibleRegion(aspect: aspect)
                XCTAssertEqual(crop.width, 0.5, accuracy: 0.0001)
                XCTAssertEqual(crop.height, 0.5, accuracy: 0.0001)
                viewport.transform(centroid: .zero, pan: CGSize(width: 100000, height: -100000), zoom: 1, aspect: aspect)
                let edge = viewport.visibleRegion(aspect: aspect)
                XCTAssertEqual(edge.minX, 0, accuracy: 0.0001)
                XCTAssertEqual(edge.maxY, 1, accuracy: 0.0001)
                XCTAssertEqual(edge.width, edge.height, accuracy: 0.0001)
            }
        }
    }

    func testOffCenterZoomPreservesPointUnderFingersAndInverseFocus() {
        var viewport = RemoteViewfinderViewport()
        viewport.resize(CGSize(width: 1000, height: 600), aspect: 5 / 3)
        let centroid = CGPoint(x: 350, y: 250)
        let before = viewport.focusPoint(at: centroid, aspect: 5 / 3)!
        viewport.transform(centroid: centroid, pan: CGSize(width: 20, height: 10), zoom: 2, aspect: 5 / 3)
        let after = viewport.focusPoint(at: CGPoint(x: 370, y: 260), aspect: 5 / 3)!
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)
        XCTAssertEqual(viewport.offset.x, 170)
        XCTAssertEqual(viewport.offset.y, 60)
    }

    func testScaleLimitsRejectInvalidInputAndLetterboxTaps() {
        var viewport = RemoteViewfinderViewport()
        viewport.resize(CGSize(width: 1000, height: 1000), aspect: 2)
        XCTAssertNil(viewport.focusPoint(at: CGPoint(x: 500, y: 200), aspect: 2))
        XCTAssertNotNil(viewport.focusPoint(at: CGPoint(x: 0, y: 250), aspect: 2))
        viewport.transform(centroid: CGPoint(x: 500, y: 500), pan: .zero, zoom: 20, aspect: 2)
        XCTAssertEqual(viewport.scale, 8)
        for invalid in [Float(0), -1, .infinity, .nan] {
            viewport.transform(centroid: .zero, pan: CGSize(width: 1000, height: 1000), zoom: invalid, aspect: 2)
            XCTAssertEqual(viewport.scale, 8)
            XCTAssertEqual(viewport.offset, .zero)
        }
        viewport.transform(centroid: .zero, pan: CGSize(width: 1000, height: 1000), zoom: 0.01, aspect: 2)
        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.offset, .zero)
    }
    func testTransformSlopUsesAccumulationButOnlyDispatchesCurrentDelta() {
        var gesture = RemoteViewfinderTransformGesture()
        XCTAssertNil(gesture.sample(previous: [CGPoint(x: 100, y: 100)], current: [CGPoint(x: 105, y: 100)]))
        XCTAssertNil(gesture.sample(previous: [CGPoint(x: 105, y: 100)], current: [CGPoint(x: 108, y: 100)]))
        let change = gesture.sample(previous: [CGPoint(x: 108, y: 100)], current: [CGPoint(x: 110, y: 100)])!
        XCTAssertEqual(change.centroid, CGPoint(x: 108, y: 100))
        XCTAssertEqual(change.pan, CGSize(width: 2, height: 0))
        XCTAssertEqual(change.zoom, 1)
        XCTAssertTrue(gesture.active)
    }

    func testTransformUsesPreviousCenterAndMeanRadius() {
        var gesture = RemoteViewfinderTransformGesture()
        let change = gesture.sample(previous: [CGPoint(x: 50, y: 100), CGPoint(x: 150, y: 100)],
                                    current: [CGPoint(x: 20, y: 110), CGPoint(x: 220, y: 110)])!
        XCTAssertEqual(change.centroid, CGPoint(x: 100, y: 100))
        XCTAssertEqual(change.pan, CGSize(width: 20, height: 10))
        XCTAssertEqual(change.zoom, 2)
    }

    func testRotationConsumesGestureWithoutRotatingImage() {
        var gesture = RemoteViewfinderTransformGesture()
        let change = gesture.sample(previous: [CGPoint(x: 50, y: 100), CGPoint(x: 150, y: 100)],
                                    current: [CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 150)])!
        XCTAssertTrue(gesture.active)
        XCTAssertEqual(change.zoom, 1)
        XCTAssertEqual(change.pan, .zero)
        var viewport = RemoteViewfinderViewport()
        viewport.resize(CGSize(width: 200, height: 200), aspect: 1)
        viewport.transform(centroid: change.centroid, pan: change.pan, zoom: change.zoom, aspect: 1)
        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.offset, .zero)
    }

}
