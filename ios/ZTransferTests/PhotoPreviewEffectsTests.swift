import XCTest
import SwiftUI
@testable import ZTransfer

@MainActor
final class PhotoPreviewToolPresentationTests: XCTestCase {
    @MainActor private final class FixtureState: ObservableObject {
        @Published var selection: PhotoPreviewToolSelection? = .init(file: photo(1, "JPG"), canCollapse: false)
        @Published var review = false
        @Published var effects = true
        @Published var progress: CGFloat = 1
        let feedback = PhotoPreviewPageFeedback()
        static func photo(_ id: UInt32, _ ext: String) -> CameraFile {
            .init(id: id, storageID: 1, format: 0x3801, size: 100,
                  fileName: "DSC_\(id).\(ext)", captureDate: nil, isProtected: false)
        }
    }
    private struct Fixture: View {
        @ObservedObject var state: FixtureState
        var body: some View {
            PhotoPreviewTools(selection: state.selection, isReview: state.review, effectsAvailable: true,
                effectsEnabled: state.effects, histogramMode: .off, feedback: state.feedback,
                inputsEnabled: true, editEnabled: true, collapseEnabled: true, rotationEnabled: true,
                onCollapse: {}, onEffects: { _ in }, onCrop: { _ in }, onHistogram: {}, onRotate: {})
                .compositingGroup().opacity(state.progress)
                .padding(20).background(Color.black).ignoresSafeArea().environment(\.colorScheme, .light)
        }
    }

    func testToolSizesShrinkOnlyAfterGapsReachFourPoints() {
        let roomy = PhotoPreviewToolLayout(width: 320, effects: true, collapse: true)
        XCTAssertEqual(roomy.size, 44); XCTAssertEqual(roomy.gap, 12)
        let narrow = PhotoPreviewToolLayout(width: 180, effects: true, collapse: true)
        XCTAssertEqual(narrow.gap, 4); XCTAssertEqual(narrow.size, 32.8, accuracy: 0.0001)
        XCTAssertEqual(narrow.size * 5 + narrow.gap * 4, 180, accuracy: 0.0001)
    }

    func testActualToolRowRetainsFadesAndKeepsRightToolsFixedAcrossFormatsAndReview() async throws {
        try await verifyToolRow(skin: .frostedGlass)
    }
    func testNativeLiquidGlassToolRowRetainsFadesAndKeepsRightToolsFixed() async throws {
        try await verifyToolRow(skin: .liquidGlass)
    }
    private func verifyToolRow(skin: ZTransferButtonSkin) async throws {
        let suite = "preview-tools-\(UUID())", state = FixtureState()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(skin.rawValue, forKey: "skin_preset")
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UIHostingController(rootView: Fixture(state: state).defaultAppStorage(defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 240)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(260))
        let jpeg = try capture(window)
        try jpeg.image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1018-preview-tools-jpeg.png"))
        XCTAssertGreaterThan(orange(jpeg.bytes), 10)
        state.selection = .init(file: FixtureState.photo(2, "NEF"), canCollapse: false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(orange(try capture(window).bytes), 5, "Outgoing effects must survive until the fade ends")
        try await Task.sleep(for: .milliseconds(280))
        let raw = try capture(window)
        try raw.image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1019-preview-tools-raw-\(skin.rawValue).png"))
        XCTAssertEqual(orange(raw.bytes), 0)
        if skin == .liquidGlass { assertRightGlyphsFixed(jpeg, raw) }
        else { XCTAssertLessThan(rightDifference(jpeg, raw), 0.8) }
        state.selection = nil
        try await Task.sleep(for: .milliseconds(45))
        XCTAssertGreaterThan(blue(try capture(window).bytes), 10)
        try await Task.sleep(for: .milliseconds(280))
        XCTAssertEqual(blue(try capture(window).bytes), 0, "Collection page releases all outgoing tools")
        state.review = true
        state.selection = .init(file: FixtureState.photo(3, "JPG"), canCollapse: false)
        try await Task.sleep(for: .milliseconds(280))
        let review = try capture(window)
        XCTAssertEqual(orange(review.bytes), 0, "Review never exposes editing")
        if skin == .liquidGlass { assertRightGlyphsFixed(raw, review) }
        else { XCTAssertLessThan(rightDifference(raw, review), 0.8) }
        try review.image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1018-preview-tools-review.png"))
    }
    func testNativeControlsFadeAsOneGroupOnEntryAndExit() async throws {
        let state = FixtureState(); state.progress = 0
        let suite = "preview-group-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(ZTransferButtonSkin.liquidGlass.rawValue, forKey: "skin_preset")
        defer { defaults.removePersistentDomain(forName: suite) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 240)
        window.rootViewController = UIHostingController(rootView: Fixture(state: state).defaultAppStorage(defaults))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(blue(try capture(window).bytes), 0)
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.34)) { state.progress = 1 }
        try await Task.sleep(for: .milliseconds(80))
        let entering = try capture(window)
        try await Task.sleep(for: .milliseconds(400))
        let shown = try capture(window)
        // At 80/340ms the correct fade can put every blue channel below the
        // fully-visible 55/255 glyph threshold. Check actual color energy.
        XCTAssertGreaterThan(blueEnergy(entering.bytes), 0)
        XCTAssertLessThan(blueEnergy(entering.bytes), blueEnergy(shown.bytes))
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) { state.progress = 0 }
        try await Task.sleep(for: .milliseconds(55))
        let exiting = try capture(window)
        XCTAssertGreaterThan(blue(exiting.bytes), 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(blue(try capture(window).bytes), 0)
    }
    private func blueEnergy(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) {
            $0 + max(0, Int(bytes[$1+2]) - Int(bytes[$1]))
        }
    }

    private func assertRightGlyphsFixed(_ lhs: Capture, _ rhs: Capture) {
        // Native glass samples/adapts its backdrop; comparing the entire RGBA
        // material was NOT a geometry assertion. Measure the actual blue marks.
        func bounds(_ shot: Capture) -> CGRect {
            var result = CGRect.null
            for y in 0..<shot.height { for x in max(0, shot.width - 120)..<shot.width {
                let i = (y * shot.width + x) * 4
                let r = Int(shot.bytes[i]), g = Int(shot.bytes[i+1]), b = Int(shot.bytes[i+2])
                if b > 55 && b > r * 3 / 2 && b > g {
                    result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            } }
            return result
        }
        let a = bounds(lhs), b = bounds(rhs)
        XCTAssertFalse(a.isNull); XCTAssertFalse(b.isNull)
        XCTAssertEqual(a.minX, b.minX, accuracy: 1); XCTAssertEqual(a.maxX, b.maxX, accuracy: 1)
        XCTAssertEqual(a.minY, b.minY, accuracy: 1); XCTAssertEqual(a.maxY, b.maxY, accuracy: 1)
    }

    private func orange(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).filter { Int(bytes[$0]) > 55 && Int(bytes[$0]) > Int(bytes[$0+1]) * 3 / 2 && bytes[$0+1] > bytes[$0+2] }.count
    }
    private func blue(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).filter { Int(bytes[$0+2]) > 35 && Int(bytes[$0+2]) > Int(bytes[$0]) * 3 / 2 }.count
    }
    private typealias Capture = (image: UIImage, bytes: [UInt8], width: Int, height: Int)
    private func rightDifference(_ lhs: Capture, _ rhs: Capture) -> Double {
        XCTAssertEqual(lhs.width, rhs.width); XCTAssertEqual(lhs.height, rhs.height)
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return .infinity }
        // Measure the actual raster, not the requested UIWindow frame (the
        // scene can resize it). Both trailing tools occupy this 120pt region.
        let startX = max(0, lhs.width - 120)
        var total = 0
        for y in 0..<lhs.height { for x in startX..<lhs.width { for c in 0..<3 {
            let i = (y * lhs.width + x) * 4 + c
            total += abs(Int(lhs.bytes[i]) - Int(rhs.bytes[i]))
        } } }
        return Double(total) / Double(lhs.height * (lhs.width - startX) * 3)
    }
    private func capture(_ window: UIWindow) throws -> Capture {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (image, bytes, cg.width, cg.height)
    }
}

final class PhotoPreviewEffectsTests: XCTestCase {
    private func photo(_ ext: String) -> CameraFile {
        .init(id: 1, storageID: 1, format: 0x3801, size: 1000, fileName: "DSC_0001." + ext, captureDate: nil, isProtected: false)
    }
    func testOnlyJPEGWithMasterOnOutsideReviewExposesEditor() {
        for ext in ["JPG", "JPEG", "jpg", "jpeg"] {
            XCTAssertTrue(showPreviewPhotoEffects(enabled: true, isReview: false, file: photo(ext)))
            XCTAssertFalse(showPreviewPhotoEffects(enabled: false, isReview: false, file: photo(ext)))
            XCTAssertFalse(showPreviewPhotoEffects(enabled: true, isReview: true, file: photo(ext)))
        }
        for ext in ["NEF", "MOV", "MP4", "PNG"] {
            XCTAssertFalse(showPreviewPhotoEffects(enabled: true, isReview: false, file: photo(ext)))
        }
        XCTAssertFalse(showPreviewPhotoEffects(enabled: true, isReview: false, file: nil))
    }
    func testDraftMasksInactiveFrameChildrenWithoutChangingStoredRecipe() {
        var stored = PhotoEffectsSettings()
        stored.photoFrameEnabled = false; stored.photoFrameBorderEnabled = true; stored.watermark.enabled = true
        stored.watermark.text = ""
        let draft = photoEffectsEditorDraft(stored)
        XCTAssertFalse(draft.photoFrameBorderEnabled); XCTAssertFalse(draft.watermark.enabled)
        XCTAssertEqual(draft.watermark.text, stored.watermark.displayText)
        XCTAssertTrue(stored.photoFrameBorderEnabled); XCTAssertTrue(stored.watermark.enabled)
        stored.photoFrameEnabled = true
        XCTAssertTrue(photoEffectsEditorDraft(stored).photoFrameBorderEnabled)
        XCTAssertTrue(photoEffectsEditorDraft(stored).watermark.enabled)
    }
    func testMissingSelectionDoesNotInventBundledFilterOrDiscardImportedMemory() throws {
        var stored = PhotoEffectsSettings()
        let first = try XCTUnwrap(TestPhotoFilterCatalog.presets.first)
        stored.filterIntensities[PhotoEffectsSettings.filterKey(first.id)] = 64
        let draft = photoEffectsEditorDraft(stored)
        XCTAssertNil(draft.selectedFilter)
        XCTAssertEqual(draft.filterIntensities[PhotoEffectsSettings.filterKey(first.id)], 64)
        XCTAssertFalse(draft.photoFilterEnabled)
        XCTAssertNil(stored.selectedFilter)
    }
}

/// The overlay must outlive a virtualized workbench page without presenting a
/// blank UIKit controller.
@MainActor
final class PhotoEffectsExpandedPresentationTests: XCTestCase {
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
    }

    func testAcceptedImageSurvivesSourceReplacementAndRejectsUnrelatedComparison() {
        let presentation = PhotoEffectsExpandedPresentation()
        let accepted = image(.blue), next = image(.red), comparison = image(.green)
        presentation.present(.init(image: accepted, initialComparison: nil, anchor: .zero), onDismiss: {})
        presentation.updateComparison(image: next, unfiltered: comparison)
        XCTAssertTrue(presentation.snapshot?.image === accepted)
        XCTAssertNil(presentation.comparison)
        presentation.updateComparison(image: accepted, unfiltered: comparison)
        XCTAssertTrue(presentation.comparison === comparison)
        presentation.updateComparison(image: accepted, unfiltered: nil)
        XCTAssertNil(presentation.comparison)
    }

    func testDismissReleasesPixelsAndCallbackOnceThenAcceptsNewImage() {
        let presentation = PhotoEffectsExpandedPresentation()
        var callbacks = 0
        weak var retainedImage: UIImage?
        autoreleasepool {
            let pixels = image(.blue)
            retainedImage = pixels
            presentation.present(.init(image: pixels, initialComparison: pixels, anchor: .zero)) { callbacks += 1 }
        }
        XCTAssertNotNil(retainedImage)
        presentation.dismiss(); presentation.dismiss()
        XCTAssertNil(presentation.snapshot); XCTAssertNil(presentation.comparison)
        XCTAssertNil(retainedImage); XCTAssertEqual(callbacks, 1)
        let next = image(.red)
        presentation.present(.init(image: next, initialComparison: nil, anchor: .zero)) { callbacks += 1 }
        XCTAssertTrue(presentation.snapshot?.image === next)
        presentation.dismiss()
        XCTAssertEqual(callbacks, 2)
    }

    private final class FixtureState: ObservableObject {
        @Published var sourceVisible = true
        var presentation: PhotoEffectsExpandedPresentation?
        var sourceAppearances = 0
        var sourceDisappearances = 0
    }
    private struct Source: View {
        @Environment(\.photoEffectsExpandedPresentation) private var presentation
        let state: FixtureState
        var body: some View {
            Color.clear.frame(width: 100, height: 100)
                .onAppear { state.presentation = presentation; state.sourceAppearances += 1 }
                .onDisappear { state.sourceDisappearances += 1 }
        }
    }
    private struct Fixture: View {
        @ObservedObject var state: FixtureState
        var body: some View {
            ZStack {
                Color.red
                if state.sourceVisible { Source(state: state) }
            }
            .photoEffectsExpandedPresentation()
        }
    }

    private func centerPixel(_ window: UIWindow) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let capture = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        let image = try XCTUnwrap(capture.cgImage)
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: CGFloat(image.width / 2), y: CGFloat(image.height / 2), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    func testLiveHostRetainsOverlayAfterSourceRemovalWithoutSystemModal() async throws {
        let state = FixtureState()
        let host = UIHostingController(rootView: Fixture(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(100))
        let presentation = try XCTUnwrap(state.presentation)
        let pixels = image(.blue)
        presentation.present(.init(image: pixels, initialComparison: nil, anchor: .zero), onDismiss: {})
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(host.presentedViewController)
        XCTAssertEqual(state.sourceDisappearances, 0, "Opening must keep the source hierarchy alive")
        state.sourceVisible = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.sourceDisappearances, 1)
        XCTAssertTrue(presentation.snapshot?.image === pixels)
        XCTAssertTrue(PopupDragBoundaryView.contains(window.center, in: window))
        let expandedPixel = try centerPixel(window)
        XCTAssertLessThan(expandedPixel[0], 20); XCTAssertGreaterThan(expandedPixel[2], 230)
        presentation.dismiss()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(PopupDragBoundaryView.contains(window.center, in: window))
        let returnedPixel = try centerPixel(window)
        XCTAssertGreaterThan(returnedPixel[0], 230); XCTAssertLessThan(returnedPixel[2], 20)
        XCTAssertNil(host.presentedViewController)
        state.sourceVisible = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.sourceAppearances, 2)
        XCTAssertTrue(state.presentation === presentation, "The host must survive pager cell replacement")
    }
}
