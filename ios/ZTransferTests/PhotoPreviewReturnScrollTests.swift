import XCTest
import SwiftUI
@testable import ZTransfer

@MainActor
final class PhotoPreviewReturnScrollTests: XCTestCase {
    private final class Probe {
        var reader: ScrollViewProxy?
        var frames: [String: CGRect] = [:]
    }
    private struct Frames: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }
    private struct Measured: ViewModifier {
        let id: String
        func body(content: Content) -> some View {
            content.background(GeometryReader { geometry in
                Color.clear.preference(key: Frames.self, value: [id: geometry.frame(in: .global)])
            })
        }
    }
    private struct Grid: View {
        let probe: Probe
        var body: some View {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(0..<180) { index in
                            Color.blue.frame(height: 100)
                                .modifier(Measured(id: "photo_\(index)"))
                                .id("photo_\(index)")
                        }
                    }.padding(.horizontal, 12).padding(.top, 8)
                }
                .modifier(Measured(id: "viewport"))
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.white.frame(height: 40).modifier(Measured(id: "controls"))
                }
                .onPreferenceChange(Frames.self) { probe.frames = $0 }
                .onAppear { probe.reader = reader }
            }
        }
    }

    func testRealScrollViewPlacesOffscreenTargetsBelowFixedControlsInBothDirections() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let probe = Probe()
        let host = UIHostingController(rootView: Grid(probe: probe))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(200))
        let reader = try XCTUnwrap(probe.reader)
        for id in [75, 15] {
            let measured = try XCTUnwrap(probe.frames["viewport"])
            let controls = try XCTUnwrap(probe.frames["controls"])
            let top = max(measured.minY, controls.maxY)
            let height = measured.maxY - top
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                reader.scrollTo("photo_\(id)", anchor: UnitPoint(x: 0.5,
                    y: photoPreviewReturnAnchor(viewportHeight: height, itemHeight: 100)))
            }
            try await ZTransferNextDisplayFrame.wait()
            try await Task.sleep(for: .milliseconds(100))
            let target = try XCTUnwrap(probe.frames["photo_\(id)"])
            XCTAssertEqual(target.minY - top, 88, accuracy: 2)
        }
    }
}
