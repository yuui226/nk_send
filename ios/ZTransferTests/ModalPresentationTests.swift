import XCTest
import SwiftUI
import UIKit
@testable import ZTransfer

@MainActor
final class ModalPresentationTests: XCTestCase {
    func testDialogUsesMaterialTranslationAndAlphaAndRetainsExit() {
        let clock = AndroidDialogClock()
        clock.setPresented(true, at: 0)
        XCTAssertTrue(clock.retained)
        XCTAssertEqual(clock.frame.alpha, 0)
        XCTAssertEqual(clock.frame.offset, 20)
        // Independent Bezier point: t=.5 gives x=.2, y=.5 for standard.
        clock.advance(0.22 * 0.2)
        XCTAssertEqual(clock.frame.alpha, 0.5, accuracy: 0.00001)
        XCTAssertEqual(clock.frame.offset, 10, accuracy: 0.00001)
        clock.advance(0.22)
        XCTAssertFalse(clock.running)
        XCTAssertEqual(clock.frame.offset, 0)
        clock.setPresented(false, at: 1)
        // standard_accelerate at t=.5 gives x=.6125, y=.5.
        clock.advance(1 + 0.15 * 0.6125)
        XCTAssertEqual(clock.frame.alpha, 0.5, accuracy: 0.00001)
        XCTAssertEqual(clock.frame.offset, -5, accuracy: 0.00001)
        XCTAssertTrue(clock.retained)
        clock.advance(1.151)
        XCTAssertFalse(clock.retained)
        XCTAssertFalse(clock.running)
        clock.setPresented(true, at: 2)
        XCTAssertEqual(clock.frame.offset, 20, "A fresh entry starts below, not at the previous exit's -10")
        clock.reset()
    }

    func testInterruptedDialogReopensFromDisplayedFrameAndClockReleases() {
        var clock: AndroidDialogClock? = AndroidDialogClock()
        weak var weakClock = clock
        clock?.setPresented(true, at: 0)
        clock?.advance(0.1)
        let alpha = clock?.frame.alpha, offset = clock?.frame.offset
        clock?.setPresented(false, at: 0.1)
        XCTAssertEqual(clock?.frame.alpha, alpha)
        XCTAssertEqual(clock?.frame.offset, offset)
        clock?.advance(0.15)
        clock?.setPresented(true, at: 0.15)
        clock?.advance(0.4)
        XCTAssertTrue(clock?.retained == true)
        XCTAssertEqual(clock?.frame.alpha, 1)
        clock?.reset()
        XCTAssertFalse(clock?.retained == true)
        XCTAssertFalse(clock?.running == true)
        clock?.setPresented(true, at: 1)
        XCTAssertTrue(clock?.running == true, "Reattaching a visible page restarts its dialog")
        clock = nil
        XCTAssertNil(weakClock)
    }

    private final class ModuleState: ObservableObject {
        @Published var presented = false
        @Published var draft = PhotoEffectsSettings()
    }
    private struct ModulePage: View {
        @ObservedObject var state: ModuleState
        let store: PhotoLUTStore
        var body: some View {
            ZStack(alignment: .topTrailing) {
                Color.white.ignoresSafeArea()
                PhotoEffectModuleMenuButton(isPresented: $state.presented)
                    .padding(.trailing, 20).padding(.top, 20)
            }
            .modifier(PhotoEffectModuleMenuOverlay(isPresented: $state.presented,
                draft: $state.draft, lutStore: store, isPro: true))
        }
    }

    func testModuleMenuAnimatesRetainsExitAndReversesOnSameHostWithoutDimming() async throws {
        let suite = "ModuleModal.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ModuleState()
        let host = UIHostingController(rootView: ModulePage(state: state, store: PhotoLUTStore(defaults: defaults))
            .environment(\.colorScheme, .light))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func panel(_ view: UIView) -> GeniePopupHostView? {
            if let result = view as? GeniePopupHostView { return result }
            return view.subviews.lazy.compactMap(panel).first
        }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(panel(host.view))
        state.presented = true
        try await Task.sleep(for: .milliseconds(100))
        let menu = try XCTUnwrap(panel(host.view))
        XCTAssertFalse(menu.host.view.isUserInteractionEnabled, "Entry must animate before enabling actions")
        XCTAssertEqual(menu.accessibilityIdentifier, "popup-panel-photoEffectModules")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(menu.host.view.isUserInteractionEnabled)
        XCTAssertEqual(menu.bounds.width, 156, accuracy: 0.5)
        // Android: four 34pt chips, three 8pt gaps and 12pt padding on both sides.
        XCTAssertEqual(menu.bounds.height, 4 * 34 + 3 * 8 + 2 * 12, accuracy: 0.5)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1019-module-menu.png"))
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let bitmap = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        for y in [10, 425, 841] { XCTAssertEqual(bytes[(y * cg.width + 3) * 4], 255) }
        state.presented = false
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertTrue(panel(host.view) === menu, "Do not remove the menu before its collapse finishes")
        XCTAssertFalse(menu.host.view.isUserInteractionEnabled)
        state.presented = true
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(panel(host.view) === menu)
        XCTAssertTrue(menu.host.view.isUserInteractionEnabled)
        state.presented = false
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNil(panel(host.view))
    }

    private struct SettingsPage: View {
        let effects: PhotoEffectsStore
        let directory: DirectoryAccessStore
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.white.ignoresSafeArea()
                Color.clear.frame(width: 44, height: 36).geniePopupAnchor(.settings)
                    .padding(.leading, 12).padding(.top, 20)
            }
            .overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
                if let anchor = anchors[.settings] {
                    SettingsPopupOverlay(isPresented: .constant(true), showPhotoEffectsEntry: false,
                        effectsStore: effects, directory: directory, anchor: anchor)
                }
            }
            .frame(width: 393, height: 759)
        }
    }

    func testSettingsAndChooserDimWholePagerAndPhotoListViewport() async throws {
        let suite = "ModalPresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let effects = PhotoEffectsStore(defaults: defaults)
        let directory = DirectoryAccessStore(defaults: defaults)
        for settings in [true, false] {
            for paged in [true, false] {
                let page = Group {
                    if settings { SettingsPage(effects: effects, directory: directory) }
                    else {
                        ZStack {
                            Color.white.ignoresSafeArea()
                            AndroidDialogPresentation(isPresented: true) {
                                PhotoFilterChooserOverlay(draft: .constant(PhotoEffectsSettings()),
                                    state: .constant(PhotoFilterChooserState(isPresented: true)))
                            }
                        }.frame(width: 393, height: 759)
                    }
                }.defaultAppStorage(defaults).environment(\.colorScheme, .light)
                let content = UIHostingController(rootView: WorkspaceSafeAreaPage(
                    insets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0), content: page))
                if #available(iOS 16.4, *) { content.safeAreaRegions = [] }
                let controller: UIViewController = paged
                    ? WorkspacePagingController(pages: [content, UIViewController()], initialPage: 0) : content
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first(where: \.isKeyWindow)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
                window.rootViewController = controller; window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
                controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(700))
                controller.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let name = "\(settings ? "settings" : "chooser")-\(paged ? "pager" : "standalone")"
                try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1019-\(name).png"))
                try assertBackdrop(image, value: 0.68, name: name)
            }
        }
    }

    private func assertBackdrop(_ image: UIImage, value: Double, name: String) throws {
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let bitmap = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        for y in [10, 100, 425, 800, 841] {
            for x in [3, cg.width - 4] {
                XCTAssertEqual(Double(pixels[(y * cg.width + x) * 4]) / 255, value, accuracy: 0.025,
                    "\(name) backdrop at (\(x), \(y))")
            }
        }
        // Pixel checks must not pass merely because the dialog never mounted.
        let nonBackdrop = stride(from: 0, to: pixels.count, by: 4).filter {
            abs(Double(pixels[$0]) / 255 - value) > 0.1
        }.count
        XCTAssertGreaterThan(nonBackdrop, 2_000, "\(name) must actually render its card")
    }

    private struct ModalPage: View {
        let sta: Bool
        var body: some View {
            ZStack {
                Color.white.ignoresSafeArea()
                AndroidDialogPresentation(isPresented: true) {
                    if sta { STAResetPairingOverlay(count: 1, models: ["Z30"], onConfirm: {}, onDismiss: {}) }
                    else { GPSResetPairingOverlay(onConfirm: {}, onDismiss: {}) }
                }.ignoresSafeArea()
            }
            .frame(width: 393, height: 759)
        }
    }

    func testRealResetDialogsCoverBothSafeAreasWithoutDimmingSTA() async throws {
        for sta in [true, false] {
            let content = UIHostingController(rootView: WorkspaceSafeAreaPage(
                insets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0), content: ModalPage(sta: sta)))
            if #available(iOS 16.4, *) { content.safeAreaRegions = [] }
            let pager = WorkspacePagingController(pages: [content, UIViewController()], initialPage: 0)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = pager; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            pager.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            pager.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { context in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1019-reset-\(sta ? "sta" : "gps").png"))
            try assertBackdrop(image, value: sta ? 1 : 0.68, name: sta ? "STA" : "GPS")
        }
    }
}
