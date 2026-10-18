import XCTest
import SwiftUI
import UIKit
@testable import ZTransfer

final class NativeAttentionMotionTests: XCTestCase {
    func testCardWaveKeepsAndroidPeriodAmplitudeAndOppositePhase() {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        let usb = NativeAttentionConfiguration(kind: .card(offset: 0), origin: origin, enabled: true, paused: false)
        let wifi = NativeAttentionConfiguration(kind: .card(offset: 0.5), origin: origin, enabled: true, paused: false)
        XCTAssertEqual(usb.scale(at: origin), 1, accuracy: 1e-12)
        XCTAssertEqual(usb.scale(at: origin.addingTimeInterval(2.4 * 0.38)), 1.04, accuracy: 1e-12)
        XCTAssertEqual(usb.scale(at: origin.addingTimeInterval(2.4 * 0.82)), 1, accuracy: 1e-12)
        for i in 0...288 {
            let t = Double(i) / 120
            XCTAssertEqual(usb.scale(at: origin.addingTimeInterval(t)),
                           usb.scale(at: origin.addingTimeInterval(t + 2.4)), accuracy: 1e-12)
            XCTAssertEqual(wifi.scale(at: origin.addingTimeInterval(t)),
                           usb.scale(at: origin.addingTimeInterval(t + 1.2)), accuracy: 1e-12)
            XCTAssertEqual(usb.scale(at: origin.addingTimeInterval(t), intensity: 0), 1)
        }
    }

    func testGPSAmbientPreservesBothCyclesAndStaticExpandedState() {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        for enabled in [false, true] {
            var pulse = NativeAmbientPulse(origin: origin, minimum: enabled ? 0.075 : 0.050,
                maximum: enabled ? 0.160 : 0.145, halfPeriod: enabled ? 2.4 : 2.8,
                restingOpacity: enabled ? 0.105 : 0.070, breathing: true, paused: false)
            XCTAssertEqual(pulse.opacity(at: origin), pulse.minimum, accuracy: 1e-12)
            XCTAssertEqual(pulse.opacity(at: origin.addingTimeInterval(pulse.halfPeriod)), pulse.maximum, accuracy: 1e-12)
            XCTAssertEqual(pulse.opacity(at: origin.addingTimeInterval(pulse.halfPeriod * 2)), pulse.minimum, accuracy: 1e-12)
            pulse.breathing = false
            XCTAssertEqual(pulse.opacity(at: origin.addingTimeInterval(1)), pulse.restingOpacity)
        }
    }

    @MainActor
    func testCardFadeCanReverseAndKeepsWindowCoordinatesAndClickTarget() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let controller = UIViewController(); window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true }
        let view = NativeAttentionHostView(frame: CGRect(x: 30, y: 80, width: 160, height: 240))
        var reported: CGRect?
        view.onWindowFrameChange = { reported = $0 }
        controller.view.addSubview(view)
        view.setNeedsLayout(); view.layoutIfNeeded()
        let button = UIButton(frame: CGRect(x: 20, y: 40, width: 60, height: 40))
        var clicks = 0
        button.addAction(UIAction { _ in clicks += 1 }, for: .touchUpInside)
        view.host.rootView = AnyView(ZStack(alignment: .topLeading) {
            Color.clear
            HostedTestButton(button: button).frame(width: 60, height: 40).offset(x: 20, y: 40)
        })
        view.host.view.setNeedsLayout()
        view.host.view.layoutIfNeeded()
        let origin = Date().addingTimeInterval(-2.4 * 0.38)
        var config = NativeAttentionConfiguration(kind: .card(offset: 0), origin: origin, enabled: true, paused: true,
                                                   frozenDate: origin.addingTimeInterval(2.4 * 0.38))
        view.configure(config)
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = CGPoint(x: center.x + (50 - center.x) * 1.04,
                            y: center.y + (60 - center.y) * 1.04)
        let hit = view.hitTest(point, with: nil)
        XCTAssertTrue(hit === button)
        (hit as? UIButton)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(clicks, 1)
        await Task.yield()
        XCTAssertEqual(reported, CGRect(x: 30, y: 80, width: 160, height: 240))
        config.paused = false; config.frozenDate = nil; view.configure(config)
        config.enabled = false; view.configure(config)
        let fade = try XCTUnwrap(view.motionView.layer.animation(forKey: "attention.fade") as? CAKeyframeAnimation)
        XCTAssertEqual(fade.duration, 0.32, accuracy: 0.01)
        XCTAssertNil(view.motionView.layer.animation(forKey: "attention.loop"))
        config.enabled = true; view.configure(config)
        XCTAssertNotNil(view.motionView.layer.animation(forKey: "attention.loop"))
        view.removeFromSuperview()
        XCTAssertTrue((view.motionView.layer.animationKeys() ?? []).isEmpty)
    }

    @MainActor
    func testAmbientLayerStopsOffWindowAndUsesNativeInfiniteClock() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        window.rootViewController = UIViewController(); window.isHidden = false
        defer { window.isHidden = true }
        let view = NativeAmbientFillView(frame: CGRect(x: 0, y: 0, width: 150, height: 50))
        window.rootViewController!.view.addSubview(view)
        var pulse = NativeAmbientPulse(origin: Date(), minimum: 0.05, maximum: 0.145, halfPeriod: 2.8,
                                       restingOpacity: 0.07, breathing: true, paused: false)
        view.configure(color: .blue, radius: 20, pulse: pulse)
        let animation = try XCTUnwrap(view.layer.animation(forKey: "ambient.opacity") as? CABasicAnimation)
        XCTAssertEqual(animation.duration, 2.8)
        XCTAssertTrue(animation.autoreverses)
        XCTAssertEqual(animation.repeatCount, .infinity)
        pulse.breathing = false
        view.configure(color: .blue, radius: 20, pulse: pulse)
        XCTAssertNil(view.layer.animation(forKey: "ambient.opacity"))
        XCTAssertEqual(view.layer.opacity, 0.07, accuracy: 1e-6)
        pulse.breathing = true
        view.configure(color: .blue, radius: 20, pulse: pulse)
        view.removeFromSuperview()
        XCTAssertNil(view.layer.animation(forKey: "ambient.opacity"))
    }
}

private struct HostedTestButton: UIViewRepresentable {
    let button: UIButton
    func makeUIView(context: Context) -> UIButton { button }
    func updateUIView(_ uiView: UIButton, context: Context) {}
}
