import XCTest
import SwiftUI
import UIKit
@testable import ZTransfer

@MainActor
final class PhotoGrainControlTests: XCTestCase {
    private struct Bounds: PreferenceKey {
        static let defaultValue: [Int: CGRect] = [:]
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { _, rhs in rhs } }
    }
    private struct Row: View {
        let count: Int
        let measured: ([Int: CGRect]) -> Void
        var body: some View {
            PhotoEffectControlRow(primaryWeight: 3, secondaryWeight: 2) {
                ForEach(0..<count, id: \.self) { i in
                    Color.red.overlay { GeometryReader { geometry in
                        Color.clear.preference(key: Bounds.self, value: [i: geometry.frame(in: .named("row"))])
                    } }
                }
            }.coordinateSpace(name: "row").frame(width: 340, height: 50)
                .onPreferenceChange(Bounds.self, perform: measured)
        }
    }
    private struct Controls: View {
        @State var draft: PhotoEffectsSettings
        @State private var picker = false
        @State private var chooser = PhotoFilterChooserState()
        @FocusState private var focus: Bool
        let editor: PhotoLUTEditorState
        var body: some View {
            PhotoEffectsControls(draft: $draft, showingWatermarkPicker: $picker,
                textFieldFocused: $focus, photoLUTEditor: editor, filterChooser: $chooser)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(ZTransferColors.background)
        }
    }

    func testTwoWheelRowHasBothChildrenAndKeepsThreeChildLayout() async throws {
        for count in [2, 3] {
            var frames: [Int: CGRect] = [:]
            let (window, previous) = try host(Row(count: count, measured: { frames = $0 }))
            defer { close(window, previous) }
            for _ in 0..<50 where frames.count != count { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(frames.count, count)
            let first = try XCTUnwrap(frames[0]), second = try XCTUnwrap(frames[1])
            XCTAssertGreaterThan(first.width, 0)
            XCTAssertEqual(first.width / second.width, 1.5, accuracy: 0.01)
            XCTAssertEqual(second.minX - first.maxX, 8, accuracy: 0.01)
            XCTAssertEqual(first.height, 50, accuracy: 0.01)
            XCTAssertEqual(frames[count - 1]?.maxX ?? 0, 340, accuracy: 0.01)
        }
    }

    func testActualSharedGrainControlsThreeLanguagesAndThemes() async throws {
        let suite = "GrainControls-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previousLanguage = UserDefaults.standard.object(forKey: "app_language")
        defer {
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: "app_language") }
            else { UserDefaults.standard.removeObject(forKey: "app_language") }
        }
        for language in ["zh", "zh-Hant", "en"] {
            UserDefaults.standard.set(language, forKey: "app_language")
            let expected = language == "en" ? "Film grain" : language == "zh-Hant" ? "膠片顆粒" : "胶片颗粒"
            XCTAssertEqual(AppLocalized.resource("photo_grain"), expected)
            for dark in [false, true] {
                var draft = PhotoEffectsSettings()
                draft.photoEffectModules = PhotoEffectModule.grain.rawValue
                draft.photoGrain = .init(intensityPercent: 67, enabled: true, style: .coarse)
                let editor = PhotoLUTEditorState(role: .camera, defaults: defaults)
                let view = Controls(draft: draft, editor: editor).environment(\.colorScheme, dark ? .dark : .light)
                let (window, previous) = try host(view, dark: dark)
                defer { close(window, previous) }
                try await Task.sleep(for: .milliseconds(150))
                window.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "grain-controls-\(language)-\(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(editor.store.hasSelection, false)
            }
        }
    }

    private func host<V: View>(_ view: V, dark: Bool = false) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return (window, previous)
    }
    private func close(_ window: UIWindow, _ previous: UIWindow?) {
        window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
    }
}
