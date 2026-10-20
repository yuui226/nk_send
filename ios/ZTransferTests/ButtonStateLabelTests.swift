import XCTest
import SwiftUI
@testable import ZTransfer

@MainActor
final class ButtonStateLabelTests: XCTestCase {
    private func fixture() throws -> (UIWindow, ButtonStateLabelView) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 240)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let view = ButtonStateLabelView(frame: CGRect(x: 30, y: 100, width: 240, height: 20))
        window.rootViewController!.view.addSubview(view)
        view.configure(text: "Connect", rank: 0, color: .black, active: true)
        view.layoutIfNeeded()
        CATransaction.flush()
        return (window, view)
    }
    private func label(_ text: String, in view: UIView) throws -> UILabel {
        try XCTUnwrap(view.subviews.compactMap { $0 as? UILabel }.first { $0.text == text })
    }
    private func movement(_ label: UILabel) throws -> CABasicAnimation {
        let group = try XCTUnwrap(label.layer.animation(forKey: "button-state-text") as? CAAnimationGroup)
        return try XCTUnwrap(group.animations?.compactMap { $0 as? CABasicAnimation }
            .first { $0.keyPath == "transform.translation.y" })
    }

    func testSTAStatusIdentityKeepsFailuresAndReconnectOnTheIdleAction() {
        for phase in [WiFiConnectionPhase.idle, .unavailable, .reconnecting, .failed("one"), .failed("two")] {
            XCTAssertEqual(STAConnectButtonState(phase), .idle)
        }
        let progression = [WiFiConnectionPhase.idle, .discovering, .pairing, .connecting, .connected]
        XCTAssertEqual(progression.map { STAConnectButtonState($0).rawValue }, [0, 1, 2, 3, 4])
    }

    func testActualLayersRollForwardAndBackThenReleaseOutgoingText() async throws {
        let (window, view) = try fixture(); defer { window.isHidden = true }
        XCTAssertTrue(view.subviews.allSatisfy { $0.layer.animationKeys() == nil })
        view.configure(text: "Searching", rank: 1, color: .black, active: true)
        let old = try label("Connect", in: view), incoming = try label("Searching", in: view)
        XCTAssertEqual(try movement(old).toValue as? Double, -20)
        XCTAssertEqual(try movement(incoming).fromValue as? Double, 20)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(75))
        let rendered = try XCTUnwrap(incoming.layer.presentation())
        XCTAssertGreaterThan(rendered.transform.m42, 0)
        XCTAssertLessThan(rendered.transform.m42, 20)
        XCTAssertGreaterThan(rendered.opacity, 0)
        XCTAssertLessThan(rendered.opacity, 1)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(view.subviews.count, 1)
        XCTAssertNil(incoming.layer.animationKeys())
        view.configure(text: "Connect", rank: 0, color: .black, active: true)
        XCTAssertEqual(try movement(incoming).toValue as? Double, 20)
        XCTAssertEqual(try movement(label("Connect", in: view)).fromValue as? Double, -20)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(view.subviews.count, 1)
        XCTAssertEqual(try label("Connect", in: view).layer.opacity, 1)
    }

    func testInterruptedReturnReusesRenderedLabelWithoutJumpOrLateRemoval() async throws {
        let (window, view) = try fixture(); defer { window.isHidden = true }
        let idle = try label("Connect", in: view)
        view.configure(text: "Searching", rank: 1, color: .black, active: true)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(65))
        let y = try XCTUnwrap(idle.layer.presentation()).transform.m42
        view.configure(text: "Connect", rank: 0, color: .black, active: true)
        XCTAssertTrue(try label("Connect", in: view) === idle)
        XCTAssertEqual(try XCTUnwrap(movement(idle).fromValue as? Double), y, accuracy: 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(view.subviews.count, 1)
        XCTAssertTrue(view.subviews.first === idle)
        XCTAssertNil(idle.layer.animationKeys())
    }

    func testRapidChangesSameStateAndInactiveRemovalLeaveNoAnimation() async throws {
        let (window, view) = try fixture(); defer { window.isHidden = true }
        for rank in [1, 2, 3, 0, 1, 3, 2, 4, 0] {
            view.configure(text: "State \(rank)", rank: rank, color: .black, active: true)
            XCTAssertLessThanOrEqual(view.subviews.count, 5)
            try await Task.sleep(for: .milliseconds(15))
        }
        view.configure(text: "Connect", rank: 0, color: .blue, active: false)
        XCTAssertEqual(view.subviews.count, 1)
        let current = try label("Connect", in: view)
        XCTAssertNil(current.layer.animationKeys())
        XCTAssertEqual(current.textColor, .blue)
        for _ in 0..<120 { view.configure(text: "Connect", rank: 0, color: .blue, active: true) }
        XCTAssertNil(current.layer.animationKeys())
        view.configure(text: "Searching", rank: 1, color: .black, active: true)
        view.removeFromSuperview()
        XCTAssertEqual(view.subviews.count, 1)
        XCTAssertTrue(view.subviews.allSatisfy { $0.layer.animationKeys() == nil })
    }

    func testActiveAnimationDoesNotRetainItsRemovedOwner() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        weak var released: ButtonStateLabelView?
        autoreleasepool {
            let view = ButtonStateLabelView(frame: CGRect(x: 20, y: 100, width: 200, height: 20))
            released = view
            window.rootViewController!.view.addSubview(view)
            view.configure(text: "Connect", rank: 0, color: .black, active: true)
            view.configure(text: "Searching", rank: 1, color: .black, active: true)
            view.removeFromSuperview()
        }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(released)
    }

    private final class CardInput: ObservableObject {
        @Published var state = ConnectionState()
    }
    private struct CardHarness: View {
        @ObservedObject var input: CardInput
        var body: some View {
            ConnectionMethodCard(mode: .wifi, state: input.state, height: 340, dimmed: false,
                attentionActive: false, attentionOrigin: .distantPast,
                selected: false, celebrationStart: nil)
                .frame(width: 280)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ZTransferColors.background)
                .environment(\.scenePhase, .active)
        }
    }
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testProductionSTACardKeepsTheSameTextHostAndFixedGeometryAcrossStatusChanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 560)
        let input = CardInput()
        let suite = "STAButton-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { window.isHidden = true; defaults.removePersistentDomain(forName: suite) }
        defaults.set(ZTransferButtonSkin.liquidGlass.rawValue, forKey: "skin_preset")
        let host = UIHostingController(rootView: CardHarness(input: input)
            .defaultAppStorage(defaults).preferredColorScheme(.light))
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        let textHost = try XCTUnwrap(descendants(host.view).compactMap { $0 as? ButtonStateLabelView }.first)
        let original = textHost.convert(textHost.bounds, to: window)
        XCTAssertEqual(original.height, 20)
        XCTAssertGreaterThan(original.width, 100)
        input.state.wifiPhase = .discovering
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNotNil(try label(STAConnectButtonState.searching.title, in: textHost)
            .layer.animation(forKey: "button-state-text"))
        input.state.wifiPhase = .failed("Cancelled")
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(textHost.subviews.count, 1)
        XCTAssertNotNil(try label(STAConnectButtonState.idle.title, in: textHost))
        XCTAssertEqual(textHost.convert(textHost.bounds, to: window), original)
        XCTAssertFalse(textHost.isUserInteractionEnabled)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "sta-button-current-material"; attachment.lifetime = .keepAlways; add(attachment)
        input.state.wifiPhase = .connected
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(textHost.subviews.count, 1)
        XCTAssertEqual(try label(STAConnectButtonState.connected.title, in: textHost).layer.opacity, 1)
        XCTAssertEqual(textHost.convert(textHost.bounds, to: window), original)
    }
}
