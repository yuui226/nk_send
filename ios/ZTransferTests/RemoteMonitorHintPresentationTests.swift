import SwiftUI
import XCTest
@testable import ZTransfer

final class RemoteMonitorHintMotionTests: XCTestCase {
    func testNormalFadeKeepsContentUntil200msExitAndRepeatedVisibleDoesNotRestart() {
        var hint = RemoteMonitorHintMotion()
        hint.setVisible(true); hint.advance(0); hint.advance(80_000_000)
        XCTAssertEqual(hint.alpha.value, ZTransferAndroidMotion.fastOutSlowIn(0.5), accuracy: 0.00001)
        hint.setVisible(true); hint.advance(160_000_000)
        XCTAssertEqual(hint.alpha.value, 1)
        XCTAssertFalse(hint.alpha.isRunning)
        hint.setVisible(false); hint.advance(200_000_000); hint.advance(300_000_000)
        XCTAssertEqual(hint.alpha.value, 1 - ZTransferAndroidMotion.fastOutSlowIn(0.5), accuracy: 0.00001)
        XCTAssertTrue(hint.retained)
        hint.advance(400_000_000)
        XCTAssertFalse(hint.retained)
        XCTAssertEqual(hint.alpha.value, 0)
    }

    func testInterruptedEnterUsesTransitionInterruptionSpringAndRetainsVelocity() {
        var hint = RemoteMonitorHintMotion()
        hint.setVisible(true); hint.advance(0); hint.advance(60_000_000)
        let value = hint.alpha.value, velocity = hint.alpha.velocity
        hint.setVisible(false)
        XCTAssertEqual(hint.alpha.value, value, accuracy: 0.00001)
        hint.advance(100_000_000)
        let expected = ZTransferAndroidMotion.criticallyDampedSpring(stiffness: 1500)
            .animationSample(at: 40_000_000, from: value, to: 0, velocity: velocity)
        XCTAssertEqual(hint.alpha.value, expected.value, accuracy: 0.00001)
        XCTAssertEqual(hint.alpha.velocity, expected.velocity, accuracy: 0.00001)
    }

    func testExitReversalUsesPostExitToVisibleSpringAndDisposedContentRestartsFromZero() {
        var hint = RemoteMonitorHintMotion()
        hint.setVisible(true); hint.advance(0); hint.advance(160_000_000)
        hint.setVisible(false); hint.advance(200_000_000); hint.advance(260_000_000)
        let value = hint.alpha.value, velocity = hint.alpha.velocity
        hint.setVisible(true); hint.advance(300_000_000)
        let expected = ZTransferAndroidMotion.criticallyDampedSpring(stiffness: 400)
            .animationSample(at: 40_000_000, from: value, to: 1, velocity: velocity)
        XCTAssertEqual(hint.alpha.value, expected.value, accuracy: 0.00001)
        XCTAssertEqual(hint.alpha.velocity, expected.velocity, accuracy: 0.00001)
        hint.advance(2_000_000_000)
        hint.setVisible(false); hint.advance(3_000_000_000); hint.advance(3_200_000_000)
        XCTAssertFalse(hint.retained)
        hint.setVisible(true)
        XCTAssertEqual(hint.alpha.value, 0)
        hint.advance(4_000_000_000); hint.advance(4_080_000_000)
        XCTAssertEqual(hint.alpha.value, ZTransferAndroidMotion.fastOutSlowIn(0.5), accuracy: 0.00001)
    }

    @MainActor func testDisappearanceResetsDisplayLinkState() {
        let animator = RemoteMonitorHintAnimator()
        animator.setVisible(true)
        XCTAssertTrue(animator.motion.retained)
        animator.stop()
        XCTAssertFalse(animator.motion.retained)
        XCTAssertFalse(animator.motion.alpha.isRunning)
    }
}

@MainActor
final class RemoteMonitorHintPresentationTests: XCTestCase {
    func testTwoLinesArePaintedInsteadOfOnlyReservingTheirHeight() throws {
        let label = RemoteMonitorHintLabel(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
        label.backgroundColor = .white
        label.configure(text: String(repeating: "AUTOFOCUS CAMERA ", count: 10),
                        style: .init(compact: true), color: .black)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: label.bounds, format: format).image { context in
            label.layer.render(in: context.cgContext)
        }
        XCTAssertEqual(try inkBands(image), 2, "Measure and paint must both retain the second line")
        let attachment = XCTAttachment(image: image)
        attachment.name = "Actual two-line hint ink"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func inkBands(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var bands = 0, previous = false
        for y in 0..<cg.height {
            let ink = (0..<cg.width).filter { x in
                let i = (y * cg.width + x) * 4
                return pixels[i] < 100 && pixels[i + 3] > 200
            }.count > 3
            if ink && !previous { bands += 1 }
            previous = ink
        }
        return bands
    }

    func testTextWrapsAtTwoLinesAndUsesProjectTypographyWithoutMaterialTokenSpacing() {
        let label = RemoteMonitorHintLabel()
        for compact in [true, false] {
            let style = RemoteMonitorHintStyle(compact: compact)
            label.configure(text: "Copied", style: style, color: .white)
            let short = label.measured(width: 256, height: 100)
            XCTAssertLessThan(short.width, 60)
            XCTAssertEqual(short.height, style.textHeight(lines: 1), accuracy: 1)
            label.configure(text: String(repeating: "Switch the camera to autofocus. ", count: 10), style: style, color: .white)
            let long = label.measured(width: 160, height: 100)
            XCTAssertLessThanOrEqual(long.width, 160)
            XCTAssertEqual(long.height, style.textHeight(lines: 2), accuracy: 1)
            XCTAssertEqual(label.numberOfLines, 2)
            XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
            XCTAssertEqual(label.attributedText?.attribute(.kern, at: 0, effectiveRange: nil) as? Int, 0)
        }
    }

    func testProductionBubbleUsesContentWidthAndInsetsInside280PointCap() throws {
        for compact in [true, false] {
            for text in ["Copied", String(repeating: "Switch the camera to autofocus. ", count: 6)] {
                let host = UIHostingController(rootView: RemoteMonitorHintBubble(text: text, compact: compact)
                    .frame(width: 350, height: 40))
                if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 350, height: 40))
                window.rootViewController = host; window.isHidden = false
                defer { window.isHidden = true }
                host.view.frame = window.bounds
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                func labels(_ view: UIView) -> [RemoteMonitorHintLabel] {
                    (view as? RemoteMonitorHintLabel).map { [$0] } ?? view.subviews.flatMap(labels)
                }
                let label = try XCTUnwrap(labels(host.view).first)
                let rect = label.convert(label.bounds, to: host.view)
                XCTAssertEqual(rect.midX, 175, accuracy: 1)
                XCTAssertEqual(rect.midY, 20, accuracy: 1)
                XCTAssertLessThanOrEqual(rect.width, compact ? 264 : 256)
                XCTAssertLessThanOrEqual(rect.height, 30)
                if text == "Copied" { XCTAssertLessThan(rect.width, 60) }
                else {
                    let style = RemoteMonitorHintStyle(compact: compact)
                    let lines = style.textHeight(lines: 2) <= 30 ? 2 : 1
                    XCTAssertEqual(rect.height, style.textHeight(lines: lines), accuracy: 1)
                }
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                if compact && text != "Copied" {
                    XCTAssertEqual(try inkBands(image), 2, "Hosting layout must paint both measured lines; bounds=\(label.bounds)")
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Hint \(compact ? "portrait" : "landscape") \(text == "Copied" ? "short" : "overflow")"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
}
