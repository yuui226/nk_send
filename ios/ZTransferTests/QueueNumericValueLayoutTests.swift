import SwiftUI
import UIKit
import XCTest
@testable import ZTransfer

@MainActor
final class QueueNumericValueLayoutTests: XCTestCase {
    func testGenerationDurationAndShortStatusKeepNaturalWidthUnderNarrowProposals() throws {
        for label in ["生成中", "已跳过", "59m59.9s", "1h59m59s"] {
            let natural = ImageRenderer(content: TransferInfoPill(text: label, color: .purple, allowsTruncation: false))
            let constrained = ImageRenderer(content: TransferInfoPill(text: label, color: .purple, allowsTruncation: false))
            constrained.proposedSize = ProposedViewSize(width: 22, height: 20)
            XCTAssertEqual(try XCTUnwrap(constrained.uiImage).size.width,
                           try XCTUnwrap(natural.uiImage).size.width, accuracy: 0.5,
                           "Short metadata must not be measured as an ellipsis")
        }
        let description = ImageRenderer(content: TransferInfoPill(text: String(repeating: "很长的滤镜名称", count: 4),
                                                                  color: .purple, allowsTruncation: true))
        description.proposedSize = ProposedViewSize(width: 80, height: 20)
        XCTAssertLessThanOrEqual(try XCTUnwrap(description.uiImage).size.width, 80,
                                 "Android bounds the effect description to the remaining row width")
    }

    private final class Source: ObservableObject {
        struct Value { let text: String; let value: Int64 }
        @Published var value: Value
        var rect = CGRect.zero
        init(_ text: String, _ value: Int64) { self.value = .init(text: text, value: value) }
        func set(_ text: String, _ value: Int64) { self.value = .init(text: text, value: value) }
    }
    private struct Probe: UIViewRepresentable {
        let source: Source
        func makeUIView(context: Context) -> Marker { Marker() }
        func updateUIView(_ uiView: Marker, context: Context) { uiView.source = source }
        final class Marker: UIView {
            weak var source: Source?
            override func layoutSubviews() {
                super.layoutSubviews()
                if let window { source?.rect = convert(bounds, to: window) }
            }
        }
    }
    private struct Host: View {
        @ObservedObject var source: Source
        let clock: QueueNumericValueClock
        let trailing: Bool
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.white
                QueueAnimatedValue(text: source.value.text, value: source.value.value,
                                   color: .black, frameClock: clock)
                    .background(Probe(source: source))
                    .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                    .padding(16)
            }.ignoresSafeArea().environment(\.scenePhase, .active).environment(\.colorScheme, .light)
        }
    }

    func testOnlyChangedFractionPixelsMoveWhilePrefixAndUnitStayStill() async throws {
        let source = Source("42.1 MB/s", 421), clock = QueueNumericValueClock(text: "42.1 MB/s", value: 421, height: 20, automaticFrames: false)
        let window = try host(source, clock, trailing: false)
        defer { clock.unmount(); window.isHidden = true; window.rootViewController = nil }
        try await settle(window)
        let initial = try capture(window, "place-initial")
        let box = source.rect
        XCTAssertGreaterThan(box.width, 60); XCTAssertEqual(box.height, 20, accuracy: 0.5)
        source.set("42.3 MB/s", 423)
        try await wait { clock.motion.target.text == "42.3 MB/s" }
        clock.advance(0); clock.advance(90_000_000)
        try await settle(window)
        let middle = try capture(window, "place-middle")
        XCTAssertEqual(source.rect, box, "Same-width samples must not shift the label")
        let prefix = CGRect(x: box.minX, y: box.minY, width: 17, height: 20)
        let suffix = CGRect(x: box.minX + 38, y: box.minY, width: box.width - 38, height: 20)
        XCTAssertEqual(try pixels(initial, prefix), try pixels(middle, prefix), "Unchanged integer places must stay still")
        XCTAssertEqual(try pixels(initial, suffix), try pixels(middle, suffix), "The unchanged unit must stay still")
        XCTAssertNotEqual(try pixels(initial, box), try pixels(middle, box), "The changed fractional digit must actually animate")
        XCTAssertTrue(clock.motion.isRunning)
        clock.advance(180_000_000); try await settle(window)
        XCTAssertFalse(clock.motion.isRunning)
    }

    func testActualCarryAndInterruptedShrinkKeepRightAnchorAndLeaveNoGhostDigits() async throws {
        let source = Source("9", 9), clock = QueueNumericValueClock(text: "9", value: 9, height: 20, automaticFrames: false)
        let window = try host(source, clock, trailing: true)
        defer { clock.unmount(); window.isHidden = true; window.rootViewController = nil }
        try await settle(window)
        let initial = try capture(window, "carry-initial"), original = source.rect
        XCTAssertGreaterThan(original.width, 5)
        source.set("99", 99); try await wait { clock.motion.target.text == "99" }
        clock.advance(0); clock.advance(50_000_000); try await settle(window)
        XCTAssertEqual(source.rect.maxX, original.maxX, accuracy: 0.5)
        XCTAssertGreaterThan(source.rect.width, original.width)
        source.set("100", 100); try await wait { clock.motion.target.text == "100" }
        clock.advance(70_000_000); try await settle(window)
        XCTAssertEqual(source.rect.maxX, original.maxX, accuracy: 0.5)
        XCTAssertGreaterThan(source.rect.width, original.width * 2.5)
        source.set("9", 9); try await wait { clock.motion.target.text == "9" }
        clock.advance(90_000_000); try await settle(window)
        XCTAssertEqual(source.rect, original, "Departing places have zero target width immediately")
        XCTAssertEqual(clock.motion.groups[""]?.places, [2, 1, 0])
        _ = try capture(window, "carry-interrupted")
        clock.advance(3_000_000_000); try await settle(window)
        let settled = try capture(window, "carry-settled")
        XCTAssertEqual(clock.motion.groups[""]?.places, [0]); XCTAssertFalse(clock.motion.isRunning)
        XCTAssertEqual(try pixels(initial, window.bounds), try pixels(settled, window.bounds), "No old leading digit may survive cleanup")
    }

    private func host(_ source: Source, _ clock: QueueNumericValueClock, trailing: Bool) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        addTeardownBlock { @MainActor in previous?.makeKeyAndVisible() }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        window.rootViewController = UIHostingController(rootView: Host(source: source, clock: clock, trailing: trailing))
        window.makeKeyAndVisible(); return window
    }
    private func settle(_ window: UIWindow) async throws {
        try await Task.sleep(for: .milliseconds(35)); window.layoutIfNeeded()
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Numeric UI input did not arrive"); throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func capture(_ window: UIWindow, _ name: String) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("queue-numeric-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: path)
        print("QUEUE_NUMERIC_IMAGE \(path.path)")
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return image
    }
    private func pixels(_ image: UIImage, _ rect: CGRect) throws -> Data {
        let scaled = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                            width: rect.width * image.scale, height: rect.height * image.scale).integral
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: scaled))
        // Normalize row strides; CGImage crops can retain the full image's padding.
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return Data(bytes)
    }
}
