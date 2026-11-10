import XCTest
import CoreGraphics
@testable import ZTransfer

final class PreviewGeometryRegressionTests: XCTestCase {
    func testPreviewAnimatedRotationKeepsTargetDirectionInsets() {
        let placement = photoPreviewPlacement(imageSize: CGSize(width: 400, height: 600),
            viewportSize: CGSize(width: 400, height: 800), rotationDegrees: -30,
            infoBottom: 80, targetRotationDegrees: -90)
        XCTAssertEqual(placement.size.width, 376, accuracy: 0.001)
        XCTAssertEqual(placement.center.y, 440, accuracy: 0.001)
    }

    func testPreviewPlacementAndGesturesShareInformationClearance() {
        let viewport = CGSize(width: 400, height: 800)
        let image = CGSize(width: 400, height: 600)
        let placement = photoPreviewPlacement(imageSize: image, viewportSize: viewport,
                                               rotationDegrees: 0, infoBottom: 80)
        XCTAssertEqual(placement.size.width, 360, accuracy: 0.001)
        XCTAssertEqual(placement.size.height, 540, accuracy: 0.001)
        XCTAssertEqual(placement.center.y, 428, accuracy: 0.001)
        let offset = photoPreviewClampedOffset(CGSize(width: 1000, height: 1000), scale: 2,
                                               imageSize: image, viewportSize: viewport,
                                               rotationDegrees: 0, infoBottom: 80)
        XCTAssertEqual(offset, CGSize(width: 160, height: 112))
        let centeredTap = photoPreviewDoubleTapOffset(location: placement.center, scale: 2.5,
                                                      imageSize: image, viewportSize: viewport,
                                                      rotationDegrees: 0, infoBottom: 80)
        XCTAssertEqual(centeredTap, .zero)
        let landscape = photoPreviewPlacement(imageSize: image, viewportSize: viewport,
                                               rotationDegrees: -90, infoBottom: 80)
        XCTAssertEqual(landscape.size.width, 376, accuracy: 0.001)
        XCTAssertEqual(landscape.center.y, 440, accuracy: 0.001)
    }

    func testAndroidPreviewPinchPreservesPixelAtExistingZoom() {
        let old = CGSize(width: 30, height: -50)
        let centroid = CGPoint(x: 80, y: 90)
        let result = previewPinchOffset(offset: old, centroidFromCenter: centroid,
                                        factor: 3.0 / 2, pan: .zero)
        XCTAssertEqual((centroid.x - old.width) / 2 * 3 + result.width, centroid.x)
        XCTAssertEqual((centroid.y - old.height) / 2 * 3 + result.height, centroid.y)
    }

    func testAndroidPreviewPanUsesActualRestingCenter() {
        let image = CGSize(width: 400, height: 600)
        let viewport = CGSize(width: 400, height: 800)
        let center = CGPoint(x: 200, y: 340)
        XCTAssertEqual(clampPreviewPan(scale: 2, offset: CGSize(width: 1000, height: 1000),
                                       image: image, viewport: viewport, center: center),
                       CGSize(width: 200, height: 260))
        XCTAssertEqual(clampPreviewPan(scale: 2, offset: CGSize(width: -1000, height: -1000),
                                       image: image, viewport: viewport, center: center),
                       CGSize(width: -200, height: -140))
        XCTAssertEqual(clampPreviewPan(scale: 1, offset: CGSize(width: 90, height: 120),
                                       image: image, viewport: viewport, center: center), .zero)
    }

    func testAndroidPreviewLayoutNormalCropAndSmallViewport() {
        func layout(_ image: CGFloat, _ progress: CGFloat, alignment: CGFloat = 1,
                    top: CGFloat = 60) -> PreviewPhotoLayout {
            previewPhotoLayout(viewportHeight: 800, imageHeight: image, infoBottom: 80,
                               cropTop: top, cropExtraBottom: 84, progress: progress,
                               cropTopAlignment: alignment)
        }
        XCTAssertEqual(layout(400, 0), PreviewPhotoLayout(scale: 1, centerY: 440))
        for height in [CGFloat(400), CGFloat(1200)] {
            let value = layout(height, 1)
            XCTAssertEqual(value.centerY - height * value.scale / 2, 60, accuracy: 0.001)
            XCTAssertLessThanOrEqual(value.centerY + height * value.scale / 2, 716.001)
        }
        let start = layout(1200, 0), end = layout(1200, 1), middle = layout(1200, 0.5)
        XCTAssertEqual(middle.scale, (start.scale + end.scale) / 2, accuracy: 0.001)
        XCTAssertEqual(middle.centerY, (start.centerY + end.centerY) / 2, accuracy: 0.001)
        let small = previewPhotoLayout(viewportHeight: 100, imageHeight: 1200, infoBottom: 112,
                                      cropTop: 140, cropExtraBottom: 84, progress: 1)
        XCTAssertGreaterThan(small.scale, 0)
        XCTAssertTrue(small.centerY.isFinite)
        let landscape = layout(300, 1, alignment: 0.5, top: 140)
        XCTAssertGreaterThan(landscape.centerY, layout(300, 1, top: 140).centerY)
        XCTAssertLessThan(landscape.centerY, layout(300, 0, top: 140).centerY)
        XCTAssertLessThanOrEqual(landscape.centerY + 150 * landscape.scale, 716)
    }

    func testFHDNormalPortraitLandscapeCropAndRotationUseAndroidPlacement() {
        let viewport = CGSize(width: 400, height: 800)
        let portrait = CGSize(width: 400, height: 600)
        let normal = photoPreviewPlacement(imageSize: portrait, viewportSize: viewport,
            rotationDegrees: 0, infoBottom: 80, cropTop: 110)
        XCTAssertEqual(normal.center.y, 428, accuracy: 0.001)
        XCTAssertEqual(normal.size, CGSize(width: 360, height: 540))
        let crop = photoPreviewPlacement(imageSize: portrait, viewportSize: viewport,
            rotationDegrees: 0, infoBottom: 80, cropTop: 110, cropProgress: 1)
        XCTAssertEqual(crop.center.y - crop.size.height / 2, 110, accuracy: 0.001)
        let landscape = photoPreviewPlacement(imageSize: portrait, viewportSize: viewport,
            rotationDegrees: -90, infoBottom: 80, cropTop: 110, cropProgress: 1)
        XCTAssertEqual(landscape.size.width, 376, accuracy: 0.001)
        XCTAssertEqual(landscape.center.y, (440 + 170 + landscape.size.height / 2) / 2, accuracy: 0.001)
        let protected = photoPreviewPlacement(imageSize: portrait, viewportSize: viewport,
            rotationDegrees: 0, infoBottom: 122, cropTop: 110)
        XCTAssertGreaterThan(protected.center.y, normal.center.y)
        for p in stride(from: CGFloat(0), through: 1, by: 0.05) {
            let small = photoPreviewPlacement(imageSize: portrait, viewportSize: CGSize(width: 280, height: 300),
                rotationDegrees: 0, infoBottom: 100, cropTop: 110, cropProgress: p)
            XCTAssertGreaterThan(small.scale, 0)
            XCTAssertGreaterThanOrEqual(small.center.y - small.size.height / 2, 99.99)
            XCTAssertLessThanOrEqual(small.center.y + small.size.height / 2, 300.001)
        }
    }

    func testPreviewReturnPreservesFullTileAndClipsOnlyTheVisibleRegion() {
        let viewport = CGRect(x: 0, y: 100, width: 390, height: 700)
        let samples: [(CGRect, CGRect)] = [
            (CGRect(x: 12, y: 120, width: 118, height: 118), CGRect(x: 12, y: 120, width: 118, height: 118)),
            (CGRect(x: 12, y: 80, width: 118, height: 118), CGRect(x: 12, y: 100, width: 118, height: 98)),
            (CGRect(x: 12, y: 700, width: 118, height: 118), CGRect(x: 12, y: 700, width: 118, height: 100)),
            (CGRect(x: -10, y: 120, width: 118, height: 118), CGRect(x: 0, y: 120, width: 108, height: 118))
        ]
        for (full, visible) in samples {
            let bounds = photoPreviewAnchorBounds(.photo(7), bounds: [.photo(7): full], viewport: viewport)
            XCTAssertEqual(bounds?.image, full)
            XCTAssertEqual(bounds?.visible, visible)
        }
        XCTAssertNil(photoPreviewAnchorBounds(.photo(7), bounds: [:], viewport: viewport))
        XCTAssertNil(photoPreviewAnchorBounds(.photo(7), bounds: [.photo(7): .zero], viewport: viewport))
        XCTAssertNil(photoPreviewAnchorBounds(.photo(7), bounds: [.photo(7): CGRect(x: 12, y: 900, width: 118, height: 118)], viewport: viewport))
    }

    func testCellSourceRejectsOffscreenComposedAndInvalidBounds() {
        let viewport = CGRect(x: 0, y: 100, width: 320, height: 500)
        for frame in [CGRect(x: 0, y: 0, width: 90, height: 90), .zero, .null, .infinite] {
            XCTAssertNil(visiblePhotoListCellBounds(.photo(1), bounds: [.photo(1): frame], viewport: viewport))
        }
        let partial = CGRect(x: 0, y: 90, width: 90, height: 90)
        XCTAssertEqual(visiblePhotoListCellBounds(.photo(1), bounds: [.photo(1): partial], viewport: viewport), partial)
        let preview = photoPreviewAnchorBounds(.photo(42), bounds: [.photo(42): partial], viewport: viewport)
        XCTAssertEqual(preview?.image, partial)
        XCTAssertEqual(preview?.visible, partial.intersection(viewport),
                       "Android returns partially visible tiles without an extra scroll")
    }
}
