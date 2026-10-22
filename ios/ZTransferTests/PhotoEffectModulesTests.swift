import XCTest
import SwiftUI
import UIKit
@testable import ZTransfer

final class PhotoEffectModulesTests: XCTestCase {
    func testNormalizeRejectsEmptyAndUnknownBits() {
        XCTAssertEqual(normalizePhotoEffectModules(0), allPhotoEffectModules)
        XCTAssertEqual(normalizePhotoEffectModules(32), allPhotoEffectModules)
        XCTAssertEqual(normalizePhotoEffectModules(33), 1)
    }

    func testFreeEditionBindsFrameAndWatermarkVisibility() {
        XCTAssertEqual(effectivePhotoEffectModules(1 | PhotoEffectModule.frame.rawValue, isPro: false), 13)
        XCTAssertEqual(effectivePhotoEffectModules(1, isPro: false), 1)
        XCTAssertEqual(effectivePhotoEffectModules(1, isPro: true), 1)
    }

    func testOldPayloadGetsAllModules() throws {
        let value = try JSONDecoder().decode(PhotoEffectsSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(value.photoEffectModules, allPhotoEffectModules)
    }

    func testHiddenModulesDisableActiveEffectsButPreserveDraftSettings() {
        var value = PhotoEffectsSettings()
        value.photoFrameEnabled = true
        value.photoFrameBorderEnabled = true
        value.photoEffectModules = PhotoEffectModule.filter.rawValue
        value.watermark.enabled = true
        let effective = effectivePhotoEffectsSettings(value, isPro: true)
        XCTAssertFalse(effective.photoFrameEnabled)
        XCTAssertFalse(effective.photoFrameBorderEnabled)
        XCTAssertFalse(effective.watermark.enabled)
        XCTAssertTrue(value.watermark.enabled)
    }
}

@MainActor
final class PhotoEffectModuleMenuLifecycleTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var presented = false
        @Published var showAnchor = true
        @Published var scheme = ColorScheme.light
        @Published var draft = PhotoEffectsSettings()
    }

    private struct Host: View {
        @ObservedObject var state: State
        let store: PhotoLUTStore
        var body: some View {
            VStack {
                if state.showAnchor {
                    PhotoEffectModuleMenuButton(isPresented: $state.presented)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(PhotoEffectModuleMenuOverlay(isPresented: $state.presented,
                draft: $state.draft, lutStore: store, isPro: true))
            .environment(\.colorScheme, state.scheme)
        }
    }

    func testActualMenuClosesOnThemeChangeAnchorRemovalAndHostDeparture() async throws {
        let suite = "ModuleMenuLifecycle-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = State()
        let store = PhotoLUTStore(role: .local, defaults: defaults)
        let host = UIHostingController(rootView: AnyView(Host(state: state, store: store)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        try await Task.sleep(for: .milliseconds(100))
        let originalDraft = state.draft
        for scheme in [ColorScheme.dark, .light] {
            state.presented = true
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(state.presented)
            state.scheme = scheme
            for _ in 0..<40 where state.presented { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(state.presented)
        }
        state.presented = true
        try await Task.sleep(for: .milliseconds(80))
        state.showAnchor = false
        for _ in 0..<40 where state.presented { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.presented)
        state.showAnchor = true
        try await Task.sleep(for: .milliseconds(80))
        state.presented = true
        try await Task.sleep(for: .milliseconds(80))
        host.rootView = AnyView(Color.clear)
        for _ in 0..<40 where state.presented { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.presented)
        XCTAssertEqual(state.draft, originalDraft, "Closing a menu must not mutate its host draft")
    }
}
