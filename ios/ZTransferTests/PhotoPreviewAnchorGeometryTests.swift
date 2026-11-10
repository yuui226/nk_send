import XCTest
import CoreGraphics
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif
@testable import ZTransfer

#if canImport(UIKit)
/// Host the production pager and its real thumbnail/FHD loaders. Pixel bounds
/// cover the first SwiftUI layout pass, not just the independent anchor math.
@MainActor
final class PhotoPreviewOpeningRenderingTests: XCTestCase {
    func testActualPagerOpensClippedThumbnailAndHandsOffToFHDWithoutMovingAgain() async throws {
        let previousRotation = UserDefaults.standard.object(forKey: "preview_rotation_quarter_turns")
        let previousTrace = ButtonInteractionTrace.enabled
        ButtonInteractionTrace.enabled = true
        defer { ButtonInteractionTrace.enabled = previousTrace; ButtonInteractionTrace.reset() }
        defer { UserDefaults.standard.set(previousRotation, forKey: "preview_rotation_quarter_turns") }
        for turns in [0, 1] {
            ButtonInteractionTrace.reset()
            UserDefaults.standard.set(turns, forKey: "preview_rotation_quarter_turns")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = try XCTUnwrap(DebugCameraData.shared.files.first)
            let data = DebugCameraData(files: [file], thumbnailData: try fixture(width: 120, fhd: false),
                                      previewData: try fixture(width: 1200, fhd: true))
            let session = CameraSession(repository: CameraRepository(debugData: data),
                thumbnailStore: PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root)))
            _ = try await session.thumbnail(file: file)
            XCTAssertNotNil(session.memoryThumbnailImage(file: file))
            let suite = "PreviewOpening-" + UUID().uuidString
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let queue = TransferQueueViewModel(queue: TransferQueue(defaults: UserDefaults(suiteName: suite)!))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            let view = PhotoPreviewView(session: session, queueModel: queue, files: [file],
                selectedFile: .constant(file), initialAnchor: CGRect(x: 32, y: 250, width: 105, height: 105),
                initialVisibleAnchor: CGRect(x: 32, y: 274, width: 105, height: 81))
            window.rootViewController = UIHostingController(rootView: view.environment(\.colorScheme, .light))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            var frames: [(UIImage, CGRect, Int)] = []
            var samples: [[String: Any]] = []
            let started = ContinuousClock.now
            while started.duration(to: .now) < .milliseconds(1600) {
                try await Task.sleep(for: .milliseconds(35))
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                let (bounds, green) = try pixels(image)
                if let bounds {
                    frames.append((image, bounds, green))
                    samples.append(["milliseconds": Int64(ProcessInfo.processInfo.systemUptime * 1000),
                        "x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height, "green": green])
                }
            }
            let final = try XCTUnwrap(frames.last)
            XCTAssertGreaterThan(frames.count, 5)
            XCTAssertEqual(final.1.width / final.1.height, turns == 0 ? 1.5 : 2.0 / 3, accuracy: 0.03)
            XCTAssertGreaterThan(final.2, 20, "The green center exists only in the real FHD result")
            XCTAssertTrue(frames.contains { $0.1.width < final.1.width * 0.85 }, "Opening must render intermediate sizes")
            for frame in frames where abs(frame.1.width - final.1.width) <= 2 &&
                abs(frame.1.height - final.1.height) <= 2 && frame.2 == 0 {
                XCTAssertEqual(frame.1.midY, final.1.midY, accuracy: 5,
                               "The same-aspect FHD must not relocate an already expanded thumbnail")
            }
            for frame in frames.suffix(3) {
                XCTAssertEqual(frame.1.minX, final.1.minX, accuracy: 1)
                XCTAssertEqual(frame.1.minY, final.1.minY, accuracy: 1)
                XCTAssertEqual(frame.1.width, final.1.width, accuracy: 1)
                XCTAssertEqual(frame.1.height, final.1.height, accuracy: 1)
            }
            for (name, frame) in [("first", frames[0]), ("middle", frames[frames.count / 4]), ("fhd", final)] {
                let attachment = XCTAttachment(image: frame.0)
                attachment.name = "actual-preview-\(turns)-\(name)"; attachment.lifetime = .keepAlways
                add(attachment)
            }
            for (name, data) in [("pixels", try JSONSerialization.data(withJSONObject: samples, options: .sortedKeys)),
                                 ("layout", Data(ButtonInteractionTrace.snapshot().utf8))] {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "actual-preview-\(turns)-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    private func fixture(width: CGFloat, fhd: Bool) throws -> Data {
        let size = CGSize(width: width, height: width * 2 / 3)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.magenta.setFill(); context.fill(CGRect(origin: .zero, size: size))
            if fhd {
                UIColor.green.setFill()
                context.fill(CGRect(x: width * 0.45, y: size.height * 0.45, width: width * 0.1, height: size.height * 0.1))
            }
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
    }

    private func pixels(_ image: UIImage) throws -> (CGRect?, Int) {
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1, green = 0
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            if rgba[i] > 200 && rgba[i + 1] < 40 && rgba[i + 2] > 200 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
            if rgba[i] < 40 && rgba[i + 1] > 200 && rgba[i + 2] < 40 { green += 1 }
        } }
        return (maxX >= minX ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil, green)
    }
}

#endif

final class PhotoPreviewAnchorGeometryTests: XCTestCase, @unchecked Sendable {
    private let anchor = CGRect(x: 12, y: 312, width: 336, height: 336)
    private let image = CGRect(x: 90, y: 850, width: 900, height: 600)
    private let directions: [Double] = [0, 90, 180, 270, -90, -180, -270]

    func testOpeningRejectsFirstPassBeforeSafeInsetsAndBottomToolsReachTheImage() throws {
        let page = CGSize(width: 400, height: 800)
        let imageSize = CGSize(width: 400, height: 600)
        func ready(_ placement: PhotoPreviewImagePlacement?) -> PhotoPreviewImagePlacement? {
            readyPhotoPreviewOpeningPlacement(placement, pageSize: page,
                bottomPadding: 34 + 88, rotation: -90, infoBottom: 59 + 70)
        }
        XCTAssertNil(ready(nil))
        // Both sizes occurred in earlier first-pass layouts. Neither may be
        // frozen as the anchor's endpoint, even if the source bitmap is ready.
        XCTAssertNil(ready(photoPreviewImagePlacement(imageSize: imageSize, viewportSize: page,
            rotation: -90, infoBottom: 129)))
        XCTAssertNil(ready(photoPreviewImagePlacement(imageSize: imageSize,
            viewportSize: CGSize(width: 400, height: 712), rotation: -90, infoBottom: 70)))
        let viewport = CGSize(width: 400, height: 678)
        XCTAssertNil(ready(photoPreviewImagePlacement(imageSize: imageSize, viewportSize: viewport,
            rotation: 0, infoBottom: 129)))
        let rendered = try XCTUnwrap(photoPreviewImagePlacement(imageSize: imageSize, viewportSize: viewport,
            rotation: -90, infoBottom: 129))
        let opening = try XCTUnwrap(ready(rendered))
        XCTAssertEqual(opening, rendered)
        let finalFrame = try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: anchor),
            image: opening.image, progress: 1, imageRotation: opening.rotation))
        rect(rendered.image, bounds(corners(opening.image).map { $0.applying(finalFrame.transform) }))
    }

    func testActualRendererLayoutKeepsThumbnailAndFHDAtTheSameNoncentralEndpoint() throws {
        let viewport = CGSize(width: 400, height: 800)
        for direction in directions {
            let thumbnail = try XCTUnwrap(photoPreviewImagePlacement(imageSize: CGSize(width: 400, height: 600),
                viewportSize: viewport, rotation: direction, infoBottom: 80))
            let fhd = try XCTUnwrap(photoPreviewImagePlacement(imageSize: CGSize(width: 1280, height: 1920),
                viewportSize: viewport, rotation: direction, infoBottom: 80))
            rect(thumbnail.image, fhd.image)
            XCTAssertNotEqual(thumbnail.image.midY, viewport.height / 2)
            if direction == 0 { rect(CGRect(x: 20, y: 158, width: 360, height: 540), thumbnail.image) }
            let source = PhotoPreviewAnchorBounds(image: CGRect(x: 18, y: 590, width: 116, height: 116),
                visible: CGRect(x: 18, y: 590, width: 116, height: 86))
            let opening = try XCTUnwrap(photoPreviewAnchorFrame(anchor: source, image: thumbnail.image,
                progress: 0, imageRotation: direction))
            rect(source.visible, clipBounds(opening, image: thumbnail.image))
            point(center(source.image), center(thumbnail.image).applying(opening.transform))
            let settled = try XCTUnwrap(photoPreviewAnchorFrame(anchor: source, image: thumbnail.image,
                progress: 1, imageRotation: direction))
            rect(fhd.image, bounds(corners(thumbnail.image).map { $0.applying(settled.transform) }))
        }
    }

    func testReturnUsesActualZoomedCropPlacementInsteadOfViewportCenter() throws {
        for direction in directions {
            let current = try XCTUnwrap(photoPreviewImagePlacement(imageSize: CGSize(width: 400, height: 600),
                viewportSize: CGSize(width: 400, height: 800), rotation: direction, infoBottom: 80,
                scale: 2.5, offset: CGSize(width: 30, height: -40), cropTop: 110, cropProgress: 1))
            if direction == 0 { rect(CGRect(x: -220, y: -335, width: 900, height: 1350), current.image) }
            let source = PhotoPreviewAnchorBounds(image: anchor,
                visible: CGRect(x: anchor.minX, y: anchor.minY + 90, width: anchor.width, height: anchor.height - 90))
            let start = try XCTUnwrap(photoPreviewAnchorFrame(anchor: source, image: current.image,
                progress: 1, imageRotation: direction))
            rect(current.image, bounds(corners(current.image).map { $0.applying(start.transform) }))
            let end = try XCTUnwrap(photoPreviewAnchorFrame(anchor: source, image: current.image,
                progress: 0, imageRotation: direction))
            point(center(source.image), center(current.image).applying(end.transform))
            rect(source.visible, clipBounds(end, image: current.image))
        }
    }

    func testOpeningMapsActualImageOntoOffCentreCropTile() throws {
        let frame = try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: anchor), image: image, progress: 0))
        point(center(anchor), center(image).applying(frame.transform))
        rect(anchor, clipBounds(frame, image: image))
        let drawn = bounds(corners(image).map { $0.applying(frame.transform) })
        contains(drawn, anchor)
        XCTAssertGreaterThan(drawn.width, anchor.width)
        XCTAssertEqual(drawn.height, anchor.height, accuracy: 0.01)
    }

    func testSavedDirectionsCancelAtSourceWithAsymmetricVisibleCrop() throws {
        let visible = CGRect(x: anchor.minX + 31, y: anchor.minY + 87, width: anchor.width - 31, height: anchor.height - 100)
        for direction in directions {
            let destination = destination(direction)
            let frame = try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: anchor, visible: visible),
                image: destination, progress: 0, imageRotation: direction))
            point(center(anchor), center(destination).applying(frame.transform))
            rect(visible, clipBounds(frame, image: destination))
            let c = center(destination)
            let saved = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: direction * .pi / 180)
                .translatedBy(x: -c.x, y: -c.y)
            let right = CGPoint(x: c.x + 450, y: c.y).applying(saved).applying(frame.transform)
            let down = CGPoint(x: c.x, y: c.y + 300).applying(saved).applying(frame.transform)
            XCTAssertEqual(right.y, anchor.midY, accuracy: 0.01)
            XCTAssertEqual(down.x, anchor.midX, accuracy: 0.01)
            XCTAssertGreaterThan(right.x, anchor.midX); XCTAssertGreaterThan(down.y, anchor.midY)
            XCTAssertEqual((right.x - anchor.midX) / (down.y - anchor.midY), 1.5, accuracy: 0.01)
        }
    }

    func testEndIsIdentityAndReleasesEntireRotatedPhoto() throws {
        let visible = CGRect(x: anchor.minX, y: anchor.minY + 100, width: anchor.width - 47, height: anchor.height - 100)
        for direction in directions {
            let destination = destination(direction)
            let frame = try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: anchor, visible: visible),
                image: destination, progress: 1, imageRotation: direction))
            XCTAssertEqual(frame.scale, 1); XCTAssertEqual(frame.rotation, 0)
            point(.zero, frame.translation)
            for p in corners(destination) + [center(destination)] { point(p, p.applying(frame.transform)) }
            rect(destination, clipBounds(frame, image: destination))
        }
    }

    func testEveryIntermediateFrameMovesContinuouslyAndOnlyReleasesMorePixels() throws {
        let visible = CGRect(x: anchor.minX, y: anchor.minY + 100, width: anchor.width - 47, height: anchor.height - 100)
        for direction in directions {
            let destination = destination(direction)
            let raw = CGRect(x: destination.midX - 450, y: destination.midY - 300, width: 900, height: 600)
            var previous = try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: anchor, visible: visible),
                image: destination, progress: 0, imageRotation: direction))
            let firstScale = previous.scale
            for step in 0...100 {
                let p = CGFloat(step) / 100
                let frame = try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: anchor, visible: visible),
                    image: destination, progress: p, imageRotation: direction))
                point(.init(x: anchor.midX * (1-p) + destination.midX * p,
                            y: anchor.midY * (1-p) + destination.midY * p), center(destination).applying(frame.transform))
                XCTAssertTrue(frame.scale.isFinite && frame.scale > 0)
                XCTAssertGreaterThanOrEqual(frame.scale, min(firstScale, 1) - 0.01)
                XCTAssertLessThanOrEqual(frame.scale, max(firstScale, 1) + 0.01)
                XCTAssertLessThanOrEqual(abs(frame.rotation), 180)
                XCTAssertLessThanOrEqual(abs(frame.rotation), abs(previous.rotation) + 0.01)
                contains(raw, frame.clip); contains(frame.clip, previous.clip)
                previous = frame
            }
        }
    }

    func testExtremeAspectRatiosAndDestinationSmallerThanTileKeepExactCrop() throws {
        let tile = CGRect(x: 20, y: 40, width: 200, height: 200)
        let destinations = [CGRect(x: 20, y: 500, width: 1_000, height: 20),
                            CGRect(x: 500, y: 100, width: 20, height: 1_000),
                            CGRect(x: 400, y: 650, width: 80, height: 60),
                            CGRect(x: 0, y: 0, width: 20_000, height: 10_000)]
        for destination in destinations {
            let start = try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: tile), image: destination, progress: 0))
            rect(tile, clipBounds(start, image: destination))
            let drawn = bounds(corners(destination).map { $0.applying(start.transform) })
            contains(drawn, tile)
            XCTAssertTrue(abs(drawn.width-tile.width) < 0.01 || abs(drawn.height-tile.height) < 0.01)
            let end = try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: tile), image: destination, progress: 1))
            rect(destination, clipBounds(end, image: destination))
        }
        XCTAssertGreaterThan(try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: tile), image: destinations[2], progress: 0)).scale, 1)
        XCTAssertLessThan(try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: tile), image: destinations[3], progress: 0)).scale, 0.05)
    }

    func testClipMatrixKeepsImageCentreFixedAndProgressIsBounded() throws {
        for direction in directions {
            let frame = try XCTUnwrap(photoPreviewAnchorFrame(anchor: .init(image: anchor), image: image, progress: 0.4, imageRotation: direction))
            point(center(image), center(image).applying(frame.clipTransform(about: center(image))))
        }
        XCTAssertEqual(photoPreviewAnchorFrame(anchor: .init(image: anchor), image: image, progress: -0.5),
                       photoPreviewAnchorFrame(anchor: .init(image: anchor), image: image, progress: 0))
        XCTAssertEqual(photoPreviewAnchorFrame(anchor: .init(image: anchor), image: image, progress: 1.5),
                       photoPreviewAnchorFrame(anchor: .init(image: anchor), image: image, progress: 1))
        XCTAssertNil(photoPreviewAnchorFrame(anchor: .init(image: .zero), image: image, progress: 0))
    }

    func testVisibleGridBoundsRetainFullCropAndConvertTogetherToPagerSpace() throws {
        let viewport = CGRect(x: 0, y: 400, width: 300, height: 500)
        let value = try XCTUnwrap(PhotoPreviewAnchorBounds.clipped(image: anchor, to: viewport))
        XCTAssertEqual(value.image, anchor)
        XCTAssertEqual(value.visible, anchor.intersection(viewport))
        let local = value.offsetBy(dx: -10, dy: -400)
        XCTAssertEqual(local.image, anchor.offsetBy(dx: -10, dy: -400))
        XCTAssertEqual(local.visible, value.visible.offsetBy(dx: -10, dy: -400))
        XCTAssertNil(PhotoPreviewAnchorBounds.clipped(image: anchor, to: CGRect(x: 0, y: 0, width: 20, height: 20)))
    }

    @MainActor
    func testPresentationClockUsesReal340And260msFramesWithoutIdleDeadlineReuse() async {
        let clock = PhotoPreviewPresentationClock(automaticFrames: false)
        clock.animate(to: 1); clock.advance(0); clock.advance(170_000_000)
        XCTAssertEqual(clock.progress, 0.7755613, accuracy: 0.00001)
        XCTAssertTrue(clock.isRunning)
        clock.advance(340_000_000)
        XCTAssertEqual(clock.progress, 1); XCTAssertFalse(clock.isRunning)
        let rested = await clock.waitUntilRest(at: 1); XCTAssertTrue(rested)
        clock.animate(to: 0); clock.advance(9_000_000_000)
        XCTAssertEqual(clock.progress, 1)
        clock.advance(9_130_000_000)
        XCTAssertEqual(clock.progress, 0.2244387, accuracy: 0.00001)
        clock.advance(9_260_000_000)
        XCTAssertEqual(clock.progress, 0); XCTAssertFalse(clock.isRunning)
    }

    @MainActor
    func testStalledOpeningGraceIsBoundedAndReleasesItsWaiter() async {
        let clock = PhotoPreviewPresentationClock(automaticFrames: false)
        clock.animate(to: 1)
        let began = ContinuousClock.now
        await clock.waitForOpeningGrace()
        let elapsed = began.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(100))
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertEqual(clock.waitingCount, 0)
        XCTAssertEqual(clock.progress, 0, "Grace must not fake an animation endpoint")
    }

    @MainActor
    func testOpeningFrameCompletionWinsGraceAndCancellationReleasesWaiter() async throws {
        let clock = PhotoPreviewPresentationClock(automaticFrames: false)
        clock.animate(to: 1)
        let waiting = Task { await clock.waitForOpeningGrace() }
        try await waitUntil { clock.waitingCount == 1 }
        clock.advance(0); clock.advance(340_000_000)
        await waiting.value
        XCTAssertEqual(clock.waitingCount, 0)
        clock.animate(to: 0)
        let cancelled = Task { await clock.waitUntilRest(at: 0) }
        try await waitUntil { clock.waitingCount == 1 }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertFalse(result); XCTAssertEqual(clock.waitingCount, 0)
        let stopped = Task { await clock.waitUntilRest(at: 0) }
        try await waitUntil { clock.waitingCount == 1 }
        clock.stop()
        let stopResult = await stopped.value
        XCTAssertFalse(stopResult); XCTAssertEqual(clock.waitingCount, 0)
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Presentation waiter did not register")
    }
    private func destination(_ direction: Double) -> CGRect {
        abs(Int(direction / 90)) % 2 == 1 ? CGRect(x: 240, y: 700, width: 600, height: 900) : image
    }
    private func center(_ rect: CGRect) -> CGPoint { .init(x: rect.midX, y: rect.midY) }
    private func corners(_ r: CGRect) -> [CGPoint] {
        [.init(x: r.minX, y: r.minY), .init(x: r.maxX, y: r.minY), .init(x: r.maxX, y: r.maxY), .init(x: r.minX, y: r.maxY)]
    }
    private func bounds(_ points: [CGPoint]) -> CGRect {
        let x = points.map(\.x), y = points.map(\.y)
        return .init(x: x.min()!, y: y.min()!, width: x.max()! - x.min()!, height: y.max()! - y.min()!)
    }
    private func clipBounds(_ frame: PhotoPreviewAnchorFrame, image: CGRect) -> CGRect {
        bounds(corners(frame.clip).map { $0.applying(frame.clipTransform(about: center(image))).applying(frame.transform) })
    }
    private func point(_ expected: CGPoint, _ actual: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected.x, actual.x, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(expected.y, actual.y, accuracy: 0.01, file: file, line: line)
    }
    private func rect(_ expected: CGRect, _ actual: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        point(expected.origin, actual.origin, file: file, line: line)
        point(.init(x: expected.maxX, y: expected.maxY), .init(x: actual.maxX, y: actual.maxY), file: file, line: line)
    }
    private func contains(_ outer: CGRect, _ inner: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(outer.minX <= inner.minX + 0.01 && outer.minY <= inner.minY + 0.01 &&
                      outer.maxX >= inner.maxX - 0.01 && outer.maxY >= inner.maxY - 0.01,
                      "\(outer) must contain \(inner)", file: file, line: line)
    }
}
