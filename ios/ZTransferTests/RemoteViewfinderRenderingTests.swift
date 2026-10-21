import SwiftUI
import XCTest
@testable import ZTransfer

@MainActor
final class RemoteViewfinderRenderingTests: XCTestCase {
    func testViewfinderBorderIsOneConnectedInsetContourAtBothDisplayScales() throws {
        for size in [CGSize(width: 320, height: 213), CGSize(width: 390, height: 110)] {
            for scale: CGFloat in [2, 3] {
                for dark in [false, true] {
                    for recording in [false, true] {
                        let renderer = ImageRenderer(content: Color.black
                            .frame(width: size.width, height: size.height)
                            .modifier(RemoteViewfinderSurface(recording: recording))
                            .environment(\.colorScheme, dark ? .dark : .light))
                        renderer.scale = scale
                        let image = try XCTUnwrap(renderer.cgImage)
                        let width = image.width, height = image.height
                        var bytes = [UInt8](repeating: 0, count: width * height * 4)
                        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                        var border = [Bool](repeating: false, count: width * height)
                        for i in border.indices {
                            let r = Int(bytes[i * 4]), g = Int(bytes[i * 4 + 1]), b = Int(bytes[i * 4 + 2])
                            border[i] = recording ? r > 200 && g < 120 && b < 135
                                : r > 60 && r < 220 && abs(r - g) < 3 && abs(g - b) < 3
                        }
                        let total = border.filter { $0 }.count
                        XCTAssertGreaterThan(total, 2 * (width + height))
                        let start = try XCTUnwrap(border.firstIndex(of: true))
                        var pending = [start], cursor = 0
                        border[start] = false
                        while cursor < pending.count {
                            let value = pending[cursor]; cursor += 1
                            let x = value % width, y = value / width
                            for dy in -1...1 { for dx in -1...1 {
                                let nx = x + dx, ny = y + dy
                                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                                let index = ny * width + nx
                                if border[index] { border[index] = false; pending.append(index) }
                            } }
                        }
                        XCTAssertEqual(pending.count, total, "The corner/edge stroke must form one continuous ring")
                        XCTAssertEqual(bytes[3], 0, "The outside corner stays clipped")
                        let center = ((height / 2) * width + width / 2) * 4
                        XCTAssertEqual(bytes[center], 0, "Stroke must not cover the live image")
                        XCTAssertEqual(bytes[center + 3], 255)
                        if scale == 3 && !dark {
                            let attachment = XCTAttachment(image: UIImage(cgImage: image))
                            attachment.name = "viewfinder-border-\(Int(size.height))-\(recording)"
                            attachment.lifetime = .keepAlways; add(attachment)
                        }
                    }
                }
            }
        }
    }

    private final class Desqueeze: ObservableObject {
        @Published var multiplier: CGFloat = 1
    }
    private struct DesqueezeHost: View {
        @ObservedObject var state: Desqueeze
        let image: UIImage
        var body: some View {
            RemoteRotationSurface(rotation: 0) {
                VStack {
                    RemoteViewfinderAspect(aspect: 1.5 * state.multiplier) { aspect in
                        GeometryReader { proxy in
                            RemoteZoomableViewfinder(aspect: aspect,
                                imageSize: image.size, metadata: nil, onFocus: { _ in }) {
                                RemoteViewfinderImage(image: image, aspect: aspect, size: proxy.size)
                            }
                            .background(Color.blue)
                        }
                    }
                    Spacer()
                }.frame(width: 300).background(.white)
            }
        }
    }

    func testDesqueezeTransitionKeepsImageAndMaskTogetherWithoutExposedBand() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let state = Desqueeze()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: DesqueezeHost(state: state, image: image))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(160))
        var previousHeight: CGFloat = 200
        for target: CGFloat in [1.33, 2, 1] {
            let targetHeight = 200 / target
            var intermediateHeights: [Int] = []
            withAnimation(ZTransferMotion.standard) { state.multiplier = target }
            for _ in 0..<7 {
                try await Task.sleep(for: .milliseconds(20))
                // A one-pixel column catches the full-height band and image
                // extent without blocking the main actor with a full-frame
                // readback/scan during this 240ms animation.
                let strip = CGSize(width: 1, height: window.bounds.height)
                let shot = UIGraphicsImageRenderer(size: strip, format: format).image { context in
                    context.cgContext.translateBy(x: -window.bounds.midX, y: 0)
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                let cg = try XCTUnwrap(shot.cgImage)
                var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                let context = try XCTUnwrap(CGContext(data: &rgba, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(origin: .zero, size: strip))
                let uncovered = stride(from: 0, to: rgba.count, by: 4).filter {
                    rgba[$0] < 20 && rgba[$0 + 1] < 20 && rgba[$0 + 2] > 220
                }.count
                XCTAssertLessThan(uncovered, 2, "Viewport background exposed during desqueeze, target=\(target)")
                let redHeight = (0..<cg.height).filter { y in
                    let offset = (y * cg.width + cg.width / 2) * 4
                    return rgba[offset] > 220 && rgba[offset + 1] < 20 && rgba[offset + 2] < 20
                }.count
                intermediateHeights.append(redHeight)
            }
            XCTAssertTrue(intermediateHeights.contains {
                CGFloat($0) > min(previousHeight, targetHeight) + 2 &&
                CGFloat($0) < max(previousHeight, targetHeight) - 2
            }, "Native rotation host must preserve desqueeze interpolation, not jump: \(intermediateHeights)")
            try await Task.sleep(for: .milliseconds(160))
            previousHeight = targetHeight
        }
    }

    func testRoundedFocusCornersStayShortAndKeepScreenSizeWhenZoomed() {
        for zoom: CGFloat in [1, 2, 8] {
            let path = focusCornerPath(center: .zero, halfWidth: 40 / zoom, halfHeight: 30 / zoom, zoom: zoom)
            var curves = 0
            var lengths: [CGFloat] = []
            var previous = CGPoint.zero
            path.cgPath.applyWithBlock { element in
                let value = element.pointee
                switch value.type {
                case .moveToPoint: previous = value.points[0]
                case .addLineToPoint:
                    let point = value.points[0]
                    lengths.append(hypot(point.x - previous.x, point.y - previous.y) * zoom)
                    previous = point
                case .addQuadCurveToPoint: curves += 1; previous = value.points[1]
                default: break
                }
            }
            XCTAssertEqual(curves, 4)
            XCTAssertEqual(lengths.count, 8)
            XCTAssertTrue(lengths.allSatisfy { abs($0 - 3.6) < 0.001 })
            XCTAssertEqual(path.boundingRect.width * zoom, 80, accuracy: 0.001)
        }
    }

    func testNativeRotationKeepsLiveSurfaceOpaqueAndCleansUpAfterEveryDirection() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = UIViewController()
        controller.view.backgroundColor = .white
        let surface = RemoteRotationHost()
        surface.frame = CGRect(x: 0, y: 59, width: 390, height: 751)
        controller.view.addSubview(surface)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { surface.stop(); window.isHidden = true; previous?.makeKey() }
        var settled = 0
        surface.onSettled = { settled += 1 }
        surface.update(content: AnyView(Color(uiColor: .red)), rotation: 0)
        try await Task.sleep(for: .milliseconds(100))
        for (index, rotation) in [90.0, -90, 0].enumerated() {
            surface.update(content: AnyView(Color(uiColor: .green)), rotation: rotation)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertNotNil(surface.animator)
            for _ in 0..<4 {
                XCTAssertEqual(surface.host.view.alpha, 1)
                XCTAssertFalse(surface.host.view.isUserInteractionEnabled)
                // Sample actual composited pixels, not just the opacity target.
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let shot = UIGraphicsImageRenderer(size: .init(width: 1, height: 1), format: format).image { context in
                    context.cgContext.translateBy(x: -195, y: -422)
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                // Renderer output can be extended-range/P3 and is not a
                // guaranteed byte layout. Normalize before sampling channels.
                var bytes = [UInt8](repeating: 0, count: 4)
                let pixel = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                pixel.draw(try XCTUnwrap(shot.cgImage), in: CGRect(x: 0, y: 0, width: 1, height: 1))
                XCTAssertLessThan(Int(bytes[2]), 30, "No white blank frame at the monitor center")
                XCTAssertGreaterThan(Int(bytes[0]) + Int(bytes[1]), 100, "No black blank frame")
                try await Task.sleep(for: .milliseconds(25))
            }
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertNil(surface.animator)
            XCTAssertEqual(surface.subviews.count, 1)
            XCTAssertEqual(settled, index + 1)
            XCTAssertEqual(surface.host.view.transform, .identity)
            XCTAssertTrue(surface.host.view.isUserInteractionEnabled)
        }
        surface.update(content: AnyView(Color.red), rotation: 90)
        surface.removeFromSuperview()
        XCTAssertNil(surface.animator)
        XCTAssertEqual(surface.subviews.count, 1)
    }

    func testFalseColorMatchesSourceGeometryWithDesqueezeAndSharedZoom() throws {
        let width = 300, height = 200
        let colors: [UInt32] = (0..<(width * height)).map { index in
            let x = index % width
            return x < 100 ? 0xffff0000 : x < 200 ? 0xffffffff : 0xff00ff00
        }
        let bitmap = try XCTUnwrap(RemoteExposureAnalysis.image(pixels: colors, width: width, height: height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            for (index, color) in [UIColor.red, .white, .green].enumerated() {
                color.setFill(); context.fill(CGRect(x: index * 100, y: 0, width: 100, height: height))
            }
        }
        func bounds<V: View>(_ view: V, size: CGSize, zoom: CGFloat, pan: CGFloat) throws -> [CGRect] {
            let renderedView = view.frame(width: size.width, height: size.height)
                .scaleEffect(zoom).offset(x: pan, y: 0)
                .frame(width: size.width, height: size.height).clipped().background(.black)
            let renderer = ImageRenderer(content: renderedView); renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                    height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            var result = Array(repeating: CGRect.null, count: 3)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let i = (y * image.width + x) * 4
                    let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                    let channel: Int? = r > 240 && g > 240 && b > 240 ? 1
                        : r > 240 && g < 15 && b < 15 ? 0 : g > 240 && r < 15 && b < 15 ? 2 : nil
                    if let channel { result[channel] = result[channel].union(CGRect(x: x, y: y, width: 1, height: 1)) }
                }
            }
            return result
        }
        for multiplier: CGFloat in [1, 1.33, 2] {
            for size in [CGSize(width: 240, height: 400), CGSize(width: 400, height: 240)] {
                for zoom: CGFloat in [1, 1.5] {
                    let aspect = 1.5 * multiplier, pan: CGFloat = zoom == 1 ? 0 : 13
                    let base = try bounds(RemoteViewfinderImage(image: source, aspect: aspect,
                        size: size), size: size, zoom: zoom, pan: pan)
                    let overlay = try bounds(RemoteFalseColorOverlay(image: bitmap, aspect: aspect), size: size, zoom: zoom, pan: pan)
                    for (a, b) in zip(base, overlay) {
                        XCTAssertFalse(a.isNull); XCTAssertFalse(b.isNull)
                        XCTAssertEqual(a.minX, b.minX, accuracy: 2)
                        XCTAssertEqual(a.minY, b.minY, accuracy: 2)
                        XCTAssertEqual(a.width, b.width, accuracy: 2)
                        XCTAssertEqual(a.height, b.height, accuracy: 2)
                    }
                }
            }
        }
    }

    func testDesqueezeFitsImageOnceAndKeepsSourceStripeAtOneThirdOfDisplayedWidth() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            UIColor.white.setFill()
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 200))
        }
        for multiplier in [CGFloat(1), 1.33, 1.5, 1.8, 2] {
            for size in [CGSize(width: 400, height: 400), CGSize(width: 800, height: 200)] {
                let aspect = 1.5 * multiplier
                let view = RemoteViewfinderImage(image: image, aspect: aspect, size: size)
                    .background(.black)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let rendered = try XCTUnwrap(renderer.cgImage)
                var pixels = [UInt8](repeating: 0, count: rendered.width * rendered.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: rendered.width,
                        height: rendered.height, bitsPerComponent: 8, bytesPerRow: rendered.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(rendered, in: CGRect(origin: .zero, size: size))
                }
                let row = rendered.height / 2
                let white = (0..<rendered.width).filter { x in
                    let index = (row * rendered.width + x) * 4
                    return pixels[index] > 240 && pixels[index+1] > 240 && pixels[index+2] > 240
                }
                let expectedWidth = min(size.width, size.height * aspect)
                XCTAssertEqual(CGFloat(white.count), expectedWidth / 3, accuracy: 2,
                               "multiplier=\(multiplier), size=\(size)")
                XCTAssertEqual(CGFloat(try XCTUnwrap(white.first) + (try XCTUnwrap(white.last))) / 2,
                               size.width / 2 - 0.5, accuracy: 1)
            }
        }
    }
}


@MainActor
final class RemoteFocusFeedbackRenderingTests: XCTestCase {
    private final class Feedback: ObservableObject {
        @Published var focused = false
        @Published var frames = [RemoteLiveViewFocusFrame(centerX: 0.5, centerY: 0.5, width: 0.4, height: 0.4)]
    }
    private struct Host: View {
        @ObservedObject var feedback: Feedback
        var body: some View {
            IOSLiveViewFocusFramesOverlay(frames: feedback.frames, focused: feedback.focused,
                                          visible: true, aspect: 1.5)
                .frame(width: 300, height: 200).background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        }
    }

    func testSameGeometryFocusChangesRenderedFeedbackAndEmptyPacketRetainsLastResult() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let feedback = Feedback()
        let controller = UIHostingController(rootView: Host(feedback: feedback))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKey?.makeKey() }

        func greenPixelCount() async throws -> Int {
            try await Task.sleep(for: .milliseconds(250))
            controller.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: controller.view.bounds.size, format: format).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let cg = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width,
                    height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            return stride(from: 0, to: pixels.count, by: 4).filter {
                Int(pixels[$0 + 1]) > Int(pixels[$0]) + 35 &&
                Int(pixels[$0 + 1]) > Int(pixels[$0 + 2]) + 25
            }.count
        }
        let initial = try await greenPixelCount()
        XCTAssertEqual(initial, 0)
        let originalFrames = feedback.frames
        feedback.focused = true
        let focused = try await greenPixelCount()
        XCTAssertGreaterThan(focused, 40)
        XCTAssertEqual(feedback.frames, originalFrames)
        feedback.frames = []
        feedback.focused = false
        let retained = try await greenPixelCount()
        XCTAssertEqual(retained, focused)
        feedback.frames = originalFrames
        let unfocused = try await greenPixelCount()
        XCTAssertEqual(unfocused, 0)
    }
}


@MainActor
final class RemoteMonitorScopesRenderingTests: XCTestCase {
    func testProductionScopesReserveInformationRowAndKeepSingleAndDoubleSlots() throws {
        let histogram = [Int](repeating: 1, count: 256)
        let waveform = try XCTUnwrap(RemoteExposureAnalysis.image(
            pixels: RemoteExposureAnalysis.waveformPixels(channels: [[Int](repeating: 1, count: 256 * 128)], sampleHeight: 192),
            width: 256, height: 128))
        for size in [CGSize(width: 240, height: 160), CGSize(width: 320, height: 213), CGSize(width: 600, height: 240)] {
            for informationInset: CGFloat in [0, RemoteDispLayout.informationInset] {
                for startInset: CGFloat in [8, 48] {
                    for enabled in [(true, true), (true, false), (false, true), (false, false)] {
                        let host = RemoteMonitorScopesOverlay(histogram: histogram, histogramRGB: nil,
                            waveformImage: waveform, histogramMode: enabled.0 ? .luma : .off,
                            waveformMode: enabled.1 ? .luma : .off,
                            startInset: startInset, informationInset: informationInset)
                            .frame(width: size.width, height: size.height)
                            .background(Color(red: 1, green: 0, blue: 1))
                        let renderer = ImageRenderer(content: host); renderer.scale = 1
                        let image = try XCTUnwrap(renderer.cgImage)
                        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                        try pixels.withUnsafeMutableBytes { buffer in
                            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                            context.draw(image, in: CGRect(origin: .zero, size: size))
                        }
                        var bounds = CGRect.null
                        for y in 0..<image.height {
                            for x in 0..<image.width {
                                let offset = (y * image.width + x) * 4
                                guard pixels[offset] < 250 || pixels[offset + 1] > 5 || pixels[offset + 2] < 250 else { continue }
                                bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                            }
                        }
                        let count = (enabled.0 ? 1 : 0) + (enabled.1 ? 1 : 0)
                        if count == 0 { XCTAssertTrue(bounds.isNull, "Unexpected pixels: \(bounds), size=\(size)"); continue }
                        let width = min(138, (size.width - startInset - 8 - 6) / 2)
                        let height = min(76, max(28, (size.height - informationInset) * 0.29))
                        XCTAssertEqual(bounds.minX, startInset, accuracy: 1)
                        XCTAssertEqual(bounds.width, width * CGFloat(count) + (count == 2 ? 6 : 0), accuracy: 1)
                        XCTAssertEqual(bounds.maxY, size.height - informationInset - 8, accuracy: 1)
                        XCTAssertEqual(bounds.height, height, accuracy: 2)
                    }
                }
            }
        }
    }
}


@MainActor
final class RemoteMeterFeedbackRenderingTests: XCTestCase {
    private func pixels<V: View>(_ view: V, height: Int) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: 22, height: CGFloat(height)).background(.black))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 22); XCTAssertEqual(image.height, height)
        var bytes = [UInt8](repeating: 0, count: 22 * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 22, height: height,
                bitsPerComponent: 8, bytesPerRow: 22 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 22, height: height))
        }
        return bytes
    }

    func testExposureScaleSurvivesMissingReadingAndPointerShowsActualDirection() throws {
        func litPoints(_ pixels: [UInt8], xs: Range<Int>) -> [CGPoint] {
            (0..<120).flatMap { y in xs.compactMap { x in
                let i = (y * 22 + x) * 4
                return max(pixels[i], pixels[i + 1], pixels[i + 2]) > 100 ? CGPoint(x: x, y: y) : nil
            } }
        }
        let missing = try pixels(RemoteExposureMeterOverlay(ev: nil), height: 120)
        XCTAssertTrue(litPoints(missing, xs: 3..<10).isEmpty)
        // Missing data keeps the dim scale; inspect nonblack ticks separately.
        XCTAssertTrue((0..<120).contains { missing[($0 * 22 + 17) * 4] > 20 })
        let zero = try pixels(RemoteExposureMeterOverlay(ev: 0), height: 120)
        XCTAssertFalse(litPoints(zero, xs: 3..<10).isEmpty)
        XCTAssertTrue(stride(from: 0, to: zero.count, by: 4).contains {
            Int(zero[$0 + 1]) > Int(zero[$0]) + 40 && Int(zero[$0 + 1]) > Int(zero[$0 + 2]) + 20
        })
        let positive = litPoints(try pixels(RemoteExposureMeterOverlay(ev: 4), height: 120), xs: 3..<10)
        let negative = litPoints(try pixels(RemoteExposureMeterOverlay(ev: -4), height: 120), xs: 3..<10)
        XCTAssertFalse(positive.isEmpty); XCTAssertFalse(negative.isEmpty)
        XCTAssertTrue(positive.allSatisfy { $0.y < 15 })
        XCTAssertTrue(negative.allSatisfy { $0.y > 105 })
    }

    func testSoundMeterKeepsSilenceDarkAndChannelsAndPeakSeparate() throws {
        func bright(_ bytes: [UInt8], left: Bool) -> Int {
            let xs = left ? 3..<9 : 13..<19
            return (4..<55).reduce(0) { count, y in
                count + xs.filter { x in
                    let i = (y * 22 + x) * 4
                    return max(bytes[i], bytes[i + 1], bytes[i + 2]) > 100
                }.count
            }
        }
        func render(_ left: Int, _ right: Int, peakLeft: Int = 0, peakRight: Int = 0) throws -> [UInt8] {
            try pixels(IOSSoundMeter(levels: .init(peakLeft: peakLeft, peakRight: peakRight,
                currentLeft: left, currentRight: right)), height: 72)
        }
        let silent = try render(0, 0)
        XCTAssertEqual(bright(silent, left: true), 0)
        XCTAssertEqual(bright(silent, left: false), 0)
        let left = try render(14, 0), right = try render(0, 14)
        XCTAssertGreaterThan(bright(left, left: true), 30)
        XCTAssertEqual(bright(left, left: false), 0)
        XCTAssertEqual(bright(right, left: true), 0)
        XCTAssertGreaterThan(bright(right, left: false), 30)
        let peak = try render(0, 0, peakLeft: 12)
        XCTAssertGreaterThan(bright(peak, left: true), 0)
        XCTAssertLessThan(bright(peak, left: true), bright(left, left: true) / 3)
        XCTAssertEqual(bright(peak, left: false), 0)
    }
}
