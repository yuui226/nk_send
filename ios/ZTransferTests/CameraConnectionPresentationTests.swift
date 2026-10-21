import XCTest
import CoreGraphics
import SwiftUI
import UIKit
@testable import ZTransfer

/// Android DisconnectedCameraPresentationTest.kt; protocol state remains separate.
final class CameraConnectionPresentationTests: XCTestCase {
    func testCompactConnectionSceneReservesGPSPanelBeforeExpansion() {
        let layout = ConnectionLayout(size: CGSize(width: 375, height: 647))
        // A 240 pt GPS footprint includes its 50 pt entry and real detail
        // panel. The original scene would overlap the fixed bottom entry.
        XCTAssertEqual(layout.cardsTop, 101.031875, accuracy: 0.000001)
        XCTAssertEqual(layout.cardsTop(reservingGPSHeight: 240, viewportHeight: 647), 77)
        let gpsBottom = 77 + layout.usbHeight + ConnectionLayout.gpsSpacing + 240
        XCTAssertEqual(gpsBottom, 577)
        XCTAssertEqual(647 - 62 - gpsBottom, 8)
        XCTAssertEqual(layout.usbHeight, 250)
        XCTAssertEqual(layout.wifiHeight, 310)
    }

    func testRoomyConnectionSceneKeepsOriginalPositionAndCardDimensions() {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 768, height: 1004),
                     CGSize(width: 1024, height: 1322)] {
            let layout = ConnectionLayout(size: size)
            XCTAssertEqual(layout.cardsTop(reservingGPSHeight: 260, viewportHeight: size.height),
                           layout.cardsTop)
            XCTAssertEqual(layout.toolbarTop(forCardsTop: layout.cardsTop), 6)
            XCTAssertEqual(layout.gpsTop - layout.cardsTop, 260)
            XCTAssertEqual(layout.cardWidth * 2 + layout.horizontalPadding * 2 +
                           ConnectionLayout.cardSpacing, size.width)
        }
    }

    func testConnectionSceneConsumesOnlyAvailableTopWhitespace() {
        let layout = ConnectionLayout(size: CGSize(width: 375, height: 647))
        for height in [CGFloat(240), 250, 260] {
            let top = layout.cardsTop(reservingGPSHeight: height, viewportHeight: 647)
            XCTAssertGreaterThanOrEqual(top, 42)
            XCTAssertLessThan(top, layout.cardsTop)
            XCTAssertLessThanOrEqual(top + layout.usbHeight + ConnectionLayout.gpsSpacing + height,
                                     647 - 62 - 8)
        }
        // An infeasible viewport cannot consume the actual button or breathing
        // bounds, even after all 6 pt of toolbar top whitespace is used.
        XCTAssertEqual(layout.cardsTop(reservingGPSHeight: 500, viewportHeight: 647), 42)
        XCTAssertEqual(layout.toolbarTop(forCardsTop: 42), 0)
    }

    func testCompactSceneReclaimsToolbarWhitespaceWithoutChangingButtonSizeOrCardClearance() {
        let layout = ConnectionLayout(size: CGSize(width: 375, height: 667))
        for (footprint, expectedTop, expectedToolbarTop) in [
            (CGFloat(289), CGFloat(48), CGFloat(6)), (292, 45, 3), (295, 42, 0)
        ] {
            let top = layout.cardsTop(reservingGPSHeight: footprint, viewportHeight: 667)
            let toolbarTop = layout.toolbarTop(forCardsTop: top)
            XCTAssertEqual(top, expectedTop)
            XCTAssertEqual(toolbarTop, expectedToolbarTop)
            XCTAssertGreaterThanOrEqual(toolbarTop, 0)
            XCTAssertEqual(top - 5 - (toolbarTop + ConnectionLayout.toolbarHeight), 1)
            XCTAssertEqual(top + layout.usbHeight + ConnectionLayout.gpsSpacing + footprint, 597)
        }
    }

    func testEnglishCompactFootprintClearsToolbarAtPeakBreathingAndEntireWorkbench() {
        let layout = ConnectionLayout(size: CGSize(width: 375, height: 667))
        // The first English UI run had action.maxY 608.5 at top 56; its
        // complete panel includes the existing 10 pt padding below the action.
        let gpsFootprint: CGFloat = 302.5
        let origin = Date(timeIntervalSince1970: 0)
        let pulse = NativeAttentionConfiguration(kind: .card(offset: 0), origin: origin,
                                                 enabled: true, paused: false)
        let peakScale = pulse.scale(at: origin.addingTimeInterval(2.4 * 0.38))
        XCTAssertEqual(peakScale, 1.04, accuracy: 0.000001)
        let top = layout.cardsTop(reservingGPSHeight: gpsFootprint, viewportHeight: 667)
        let toolbarTop = layout.toolbarTop(forCardsTop: top)
        let toolbarBottom = toolbarTop + ConnectionLayout.toolbarHeight
        let visibleCardTop = top - layout.usbHeight * CGFloat(peakScale - 1) / 2
        let fullPanelBottom = top + layout.usbHeight + ConnectionLayout.gpsSpacing + gpsFootprint
        XCTAssertEqual(top, 42)
        XCTAssertEqual(toolbarTop, 0)
        XCTAssertEqual(visibleCardTop - toolbarBottom, 1, accuracy: 0.000001)
        XCTAssertEqual(fullPanelBottom, 604.5)
        XCTAssertLessThan(fullPanelBottom, 667 - 62,
                          "The full panel must fit even when the preferred 8 pt gap cannot")
    }

    func testEveryDisconnectedTransportKeepsItsHintAndAction() {
        let expected: [(CameraPresentationMode, String, String, String?)] = [
            (.usb, "usb_connection_lost", "reconnect_camera_usb", nil),
            // 2026-10-20: user chose to remove iOS wireless-settings buttons.
            (.ap, "connection_lost", "connect_camera_wifi", nil),
            (.sta, "connection_lost", "reconnect_camera_sta", "reconnect_camera")
        ]
        for (mode, title, hint, action) in expected {
            XCTAssertEqual(mode.disconnectedTitle, title)
            XCTAssertEqual(mode.disconnectedHint, hint)
            XCTAssertEqual(mode.disconnectedAction, action)
            XCTAssertEqual(mode.canRetrySTA(connected: false), mode == .sta)
            XCTAssertFalse(mode.canRetrySTA(connected: true))
        }
    }

    func testRestorationDoesNotInventConnectedState() {
        for mode in CameraPresentationMode.allCases {
            var state = ConnectionState()
            state.rememberedPresentationMode = CameraPresentationMode(rawValue: mode.rawValue)
            state.wirelessMode = .sta
            XCTAssertEqual(state.presentationMode(transport: nil, isSTA: false), mode)
            XCTAssertEqual(state.usbPhase, .waitingForCamera)
            XCTAssertEqual(state.wifiPhase, .idle)
            XCTAssertNil(state.selectedDeviceID)
        }
    }

    func testInvalidOrAbsentHistoryFallsBackToWirelessPreference() {
        for raw in ["invalid", "", "sta"] {
            XCTAssertNil(CameraPresentationMode(rawValue: raw))
        }
        for wireless in WirelessMode.allCases {
            XCTAssertEqual(CameraPresentationMode.resolve(transport: nil, isSTA: false,
                remembered: nil, wireless: wireless), wireless == .sta ? .sta : .ap)
        }
    }

    func testActualTransportWinsHistoryAndUSBWinsStaleSTAFlag() {
        XCTAssertEqual(CameraPresentationMode.resolve(transport: .usb, isSTA: true,
            remembered: .sta, wireless: .sta), .usb)
        XCTAssertEqual(CameraPresentationMode.resolve(transport: .wifi, isSTA: false,
            remembered: .usb, wireless: .sta), .ap)
        XCTAssertEqual(CameraPresentationMode.resolve(transport: .wifi, isSTA: true,
            remembered: .usb, wireless: .ap), .sta)
    }

    func testRetryDoesNotChangePresentationBeforeSuccess() {
        var state = ConnectionState()
        state.rememberedPresentationMode = .sta
        state.wifiPhase = .reconnecting
        let mode = state.presentationMode(transport: nil, isSTA: false)
        XCTAssertEqual(mode, .sta)
        XCTAssertTrue(mode.canRetrySTA(connected: false))
        XCTAssertFalse(mode.canRetrySTA(connected: true))
    }
}

/// Exercises the real English SwiftUI card at the SE's existing two-column
/// width. The assertions inspect rendered pixels and exported help anchors,
/// rather than reproducing the card's proposed layout arithmetic.
@MainActor
final class ConnectionMethodCardLayoutTests: XCTestCase {
    @MainActor private final class Input: ObservableObject {
        @Published var state = ConnectionState()
        @Published var phase = ScenePhase.active
        @Published var visible = true
        var helpRects: [TipPopupTrigger: CGRect] = [:]
    }
    private struct HelpRects: PreferenceKey {
        static var defaultValue: [TipPopupTrigger: CGRect] { [:] }
        static func reduce(value: inout [TipPopupTrigger: CGRect],
                           nextValue: () -> [TipPopupTrigger: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, last in last })
        }
    }
    private struct Card: View {
        @ObservedObject var input: Input
        var body: some View {
            Group {
                if input.visible {
                    ConnectionMethodCard(mode: .wifi, state: input.state, height: 310, dimmed: false,
                        attentionActive: false, attentionOrigin: .distantPast,
                        selected: false, celebrationStart: nil, staHelpViewed: true, apHelpViewed: true)
                } else { Color.clear.frame(height: 310) }
            }
            .frame(width: 161.5, height: 310)
            .overlayPreferenceValue(TipPopupAnchorPreferenceKey.self) { anchors in
                GeometryReader { proxy in
                    Color.clear.preference(key: HelpRects.self, value: anchors.mapValues { proxy[$0] })
                }.allowsHitTesting(false)
            }
            .onPreferenceChange(HelpRects.self) { input.helpRects = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ZTransferColors.background)
            .environment(\.scenePhase, input.phase)
        }
    }
    @MainActor private final class Fixture {
        let input = Input()
        let window: UIWindow
        let previousWindow: UIWindow?
        let defaults: UserDefaults
        let suite = "ConnectionCard-\(UUID())"
        let previousLanguage = UserDefaults.standard.object(forKey: "app_language")
        init(mode: WirelessMode, skin: ZTransferButtonSkin = .titanium) throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousWindow = scene.windows.first(where: { $0.isKeyWindow })
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(skin.rawValue, forKey: "skin_preset")
            UserDefaults.standard.set("en", forKey: "app_language")
            input.state.wirelessMode = mode
            window.rootViewController = UIHostingController(rootView: Card(input: input)
                .defaultAppStorage(defaults).preferredColorScheme(.light))
            window.makeKeyAndVisible()
        }
        func close() {
            window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey()
            defaults.removePersistentDomain(forName: suite)
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: "app_language") }
            else { UserDefaults.standard.removeObject(forKey: "app_language") }
        }
    }
    private func descendant<T: UIView>(_ view: UIView, type: T.Type) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant($0, type: type) }.first
    }
    private func capture(_ fixture: Fixture, name: String? = nil) throws -> UIImage {
        fixture.window.layoutIfNeeded()
        let root = try XCTUnwrap(fixture.window.rootViewController?.view)
        let card = try XCTUnwrap(descendant(root, type: NativeAttentionHostView.self))
        // A 161.5pt proposal is rounded to the physical pixel grid on a 3x
        // device; use its actual screen scale, not the renderer's 2x export.
        let scale = fixture.window.screen.scale
        XCTAssertEqual(card.bounds.width, (161.5 * scale).rounded() / scale, accuracy: 0.01)
        XCTAssertEqual(card.bounds.height, 310, accuracy: 0.01)
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let frame = card.convert(card.bounds, to: fixture.window)
        let image = UIGraphicsImageRenderer(size: card.bounds.size, format: format).image { context in
            context.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
            fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
        if let name {
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        return image
    }
    private func difference(_ first: UIImage, _ second: UIImage, in region: CGRect) throws -> Double {
        func pixels(_ image: UIImage) throws -> [UInt8] {
            let source = try XCTUnwrap(image.cgImage)
            let rect = region.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
            let crop = try XCTUnwrap(source.cropping(to: rect))
            var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return bytes
        }
        let a = try pixels(first), b = try pixels(second)
        XCTAssertEqual(a.count, b.count)
        return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }
    private func helpRect(_ fixture: Fixture, mode: WirelessMode) throws -> CGRect {
        let frame = try XCTUnwrap(fixture.input.helpRects[mode == .ap ? .ap : .sta])
        XCTAssertEqual(frame.width, mode == .ap ? 36 : 34, accuracy: 0.01)
        XCTAssertEqual(frame.height, mode == .ap ? 36 : 34, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertGreaterThanOrEqual(frame.minY, 110, "Help must stay below the header and mode selector")
        XCTAssertLessThanOrEqual(frame.maxX, 161.5)
        XCTAssertLessThanOrEqual(frame.maxY, 310 - 16 + 0.5 / fixture.window.screen.scale + 0.001,
                                 "The complete help touch target must remain inside the card padding, allowing only half-pixel alignment")
        return frame
    }
    private let header = CGRect(x: 0, y: 0, width: 161, height: 108)
    private let content = CGRect(x: 14, y: 112, width: 133, height: 96)

    func testWirelessFeedbackKeepsAndroidPriorityTextAndBusyTreatment() throws {
        let fixture = try Fixture(mode: .ap); defer { fixture.close() }
        var state = fixture.input.state
        let expected: [(WiFiConnectionPhase, WiFiFailureKind?, ConnectionCardWirelessFeedback?, String?)] = [
            (.idle, nil, nil, nil), (.discovering, nil, nil, nil),
            (.connecting, nil, .probing, "Identifying camera…"),
            (.failed("raw socket error"), .notFound, .notFound, "Camera not detected"),
            (.failed("raw socket error"), .refused, .refused, "Camera refused connection"),
            (.failed("raw socket error"), .failed, .failed, "Could not connect to camera"),
            (.reconnecting, nil, .reconnecting, "Connection interrupted"), (.connected, nil, nil, nil)
        ]
        let traits = UITraitCollection(userInterfaceStyle: .light)
        for (phase, failure, feedback, title) in expected {
            state.wifiPhase = phase; state.wifiFailureKind = failure
            let actual = ConnectionCardWirelessFeedback.resolve(state, mode: .ap, showAPProbing: true)
            XCTAssertEqual(actual, feedback)
            XCTAssertEqual(actual?.title, title)
            if let actual {
                XCTAssertEqual(actual.busy, phase == .connecting || phase == .reconnecting)
                XCTAssertNotEqual(actual.message, "raw socket error")
                let color = phase == .connecting ? ZTransferColors.accentBlue : ZTransferColors.accentOrange
                XCTAssertEqual(UIColor(actual.accent).resolvedColor(with: traits),
                               UIColor(color).resolvedColor(with: traits))
            }
            var usb = state; usb.usbPhase = .connected
            XCTAssertNil(ConnectionCardWirelessFeedback.resolve(usb, mode: .ap, showAPProbing: true))
            XCTAssertFalse(ConnectionCardWirelessFeedback.isAPProbing(usb))
        }
        state.wifiPhase = .connecting
        XCTAssertTrue(ConnectionCardWirelessFeedback.isAPProbing(state))
        XCTAssertNil(ConnectionCardWirelessFeedback.resolve(state, mode: .ap, showAPProbing: false))
        state.wirelessMode = .sta
        for phase in [WiFiConnectionPhase.idle, .discovering, .pairing, .connecting, .connected, .reconnecting] {
            state.wifiPhase = phase
            XCTAssertNil(ConnectionCardWirelessFeedback.resolve(state, mode: .sta, showAPProbing: true))
            XCTAssertNil(ConnectionCardWirelessFeedback.resolve(state, mode: .ap, showAPProbing: true))
            XCTAssertFalse(ConnectionCardWirelessFeedback.isAPProbing(state))
        }
        state.wifiPhase = .failed("Camera pairing was cancelled")
        let failure = try XCTUnwrap(ConnectionCardWirelessFeedback.resolve(state, mode: .sta, showAPProbing: true))
        XCTAssertEqual(failure.message, "Camera pairing was cancelled")
        XCTAssertFalse(failure.busy)
        XCTAssertEqual(UIColor(failure.accent).resolvedColor(with: traits),
                       UIColor(ZTransferColors.statusError).resolvedColor(with: traits))
    }

    func testEnglishAPFeedbackKeepsHeaderTabsAndHelpInsideCardThroughFailureAndRecovery() async throws {
        let fixture = try Fixture(mode: .ap); defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(450))
        let idle = try capture(fixture, name: "english-ap-idle")
        let help = try helpRect(fixture, mode: .ap)
        let states: [(WiFiConnectionPhase, WiFiFailureKind?, String)] = [
            (.failed("transport detail"), .notFound, "not-found"),
            (.failed("transport detail"), .refused, "refused"),
            (.failed("transport detail"), .failed, "failed"),
            (.reconnecting, nil, "reconnecting"), (.connected, nil, "connected"), (.idle, nil, "recovered")
        ]
        for (phase, kind, name) in states {
            fixture.input.state.wifiPhase = phase; fixture.input.state.wifiFailureKind = kind
            try await Task.sleep(for: .milliseconds(340))
            let current = try capture(fixture, name: "english-ap-\(name)")
            XCTAssertEqual(try helpRect(fixture, mode: .ap), help, name)
            XCTAssertLessThan(try difference(idle, current, in: header), 0.15,
                              "\(name): title/tabs must not move behind the independently positioned badge")
            let delta = try difference(idle, current, in: content)
            if phase == .idle || phase == .connected { XCTAssertLessThan(delta, 0.15, name) }
            else { XCTAssertGreaterThan(delta, 1, "\(name): feedback must replace the actual visible steps") }
        }
    }

    func testEnglishSTAStepsAndErrorShareSlotWithoutMovingActions() async throws {
        // Inspect the live text host with liquid glass. Titanium uses the
        // label as a material mask (ZTransferTitaniumStamp), so that UIView
        // need not be a descendant of the visible hosting view.
        let fixture = try Fixture(mode: .sta, skin: .liquidGlass); defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(450))
        let idle = try capture(fixture, name: "english-sta-idle")
        let help = try helpRect(fixture, mode: .sta)
        let root = try XCTUnwrap(fixture.window.rootViewController?.view)
        let action = try XCTUnwrap(descendant(root, type: ButtonStateLabelView.self))
        let actionBounds = action.convert(action.bounds, to: fixture.window)
        let phases: [WiFiConnectionPhase] = [.discovering, .pairing, .connecting, .connected,
            .failed("The camera could not be found. Connect the camera to the phone's personal hotspot and try again."),
            .failed("The camera refused the connection."), .idle]
        for (index, phase) in phases.enumerated() {
            fixture.input.state.wifiPhase = phase
            try await Task.sleep(for: .milliseconds(340))
            let current = try capture(fixture, name: "english-sta-state-\(index)")
            XCTAssertEqual(try helpRect(fixture, mode: .sta), help)
            XCTAssertEqual(action.convert(action.bounds, to: fixture.window), actionBounds)
            XCTAssertLessThan(try difference(idle, current, in: header), 0.15)
            let delta = try difference(idle, current, in: content)
            if case .failed = phase { XCTAssertGreaterThan(delta, 1) }
            else { XCTAssertLessThan(delta, 0.15, "STA progress updates only the action, leaving the steps intact") }
        }
    }

    func testAPProbingDelayCancelsOnStateBackgroundAndUnmountBeforePublishing() async throws {
        let fixture = try Fixture(mode: .ap); defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(450))
        let idle = try capture(fixture)
        fixture.input.state.wifiPhase = .connecting
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertLessThan(try difference(idle, capture(fixture), in: content), 0.15,
                          "A quick AP probe must not flash feedback before the 350ms delay")
        fixture.input.state.wifiPhase = .idle
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThan(try difference(idle, capture(fixture), in: content), 0.15,
                          "A cancelled probe must not publish late feedback")
        fixture.input.state.wifiPhase = .connecting
        try await Task.sleep(for: .milliseconds(720))
        XCTAssertGreaterThan(try difference(idle, capture(fixture, name: "english-ap-delayed-probing"), in: content), 1)
        fixture.input.phase = .inactive
        try await Task.sleep(for: .milliseconds(340))
        XCTAssertLessThan(try difference(idle, capture(fixture), in: content), 0.15)
        fixture.input.phase = .active
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertLessThan(try difference(idle, capture(fixture), in: content), 0.15)
        fixture.input.visible = false
        try await Task.sleep(for: .milliseconds(500))
        fixture.input.visible = true
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertLessThan(try difference(idle, capture(fixture), in: content), 0.15,
                          "A remounted card starts its own delay; the departed task cannot publish")
        fixture.input.state.wifiPhase = .connected
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThan(try difference(idle, capture(fixture), in: content), 0.15)
        _ = try helpRect(fixture, mode: .ap)
    }
}
