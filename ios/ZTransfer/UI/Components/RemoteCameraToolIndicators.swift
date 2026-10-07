// Animation constants adapted from AndroidX Material3 ProgressIndicator.kt,
// Copyright 2023 The Android Open Source Project, Apache-2.0; see Resources/licenses.
import SwiftUI
import UIKit

/// Material3 1.1.2 ProgressIndicator.kt (the Android app's resolved version):
/// five 1332ms rotations, linear base, and staggered 666ms eased head/tail.
enum RemoteCameraToolIndicatorMotion {
    static func arc(milliseconds: Double) -> (start: Double, sweep: Double) {
        let total = max(0, milliseconds).truncatingRemainder(dividingBy: 6660)
        let phase = total.truncatingRemainder(dividingBy: 1332)
        let head = 290 * Double(ZTransferAndroidMotion.fastOutSlowIn(Float(min(1, phase / 666))))
        let tail = 290 * Double(ZTransferAndroidMotion.fastOutSlowIn(Float(max(0, (phase - 666) / 666))))
        // Compose computes the cap offset using the 40dp token diameter even
        // when RemoteScreen constrains the actual indicator to 18dp.
        let cap = (180 / Double.pi) * (1.5 / 20) / 2
        return (tail - 90 + Double(Int(total / 1332) * 216 % 360) + 286 * phase / 1332 + cap,
                max(0.1, abs(head - tail)))
    }

    static func pendingOpacity(milliseconds: Double) -> Double {
        let elapsed = max(0, milliseconds)
        let fraction = Float(elapsed.truncatingRemainder(dividingBy: 600) / 600)
        let reversed = Int(elapsed / 600) % 2 != 0
        let eased = Double(ZTransferAndroidMotion.fastOutSlowIn(reversed ? 1 - fraction : fraction))
        return 1 - 0.5 * eased
    }
}

@MainActor
private final class RemoteCameraToolLoop: NSObject, ObservableObject {
    @Published private(set) var milliseconds: Double = 0
    private var first: CFTimeInterval?
    private var link: CADisplayLink?
    func start() {
        guard link == nil else { return }
        first = nil; milliseconds = 0
        let next = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link = next
        next.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ sender: CADisplayLink) {
        if first == nil { first = sender.timestamp }
        milliseconds = (sender.timestamp - first!) * 1000
    }
    func stop() { link?.invalidate(); link = nil; first = nil; milliseconds = 0 }
}

struct RemoteCameraToolLoading: View {
    @StateObject private var clock = RemoteCameraToolLoop()
    var body: some View {
        Canvas { context, size in
            let arc = RemoteCameraToolIndicatorMotion.arc(milliseconds: clock.milliseconds)
            var path = Path()
            path.addArc(center: CGPoint(x: size.width / 2, y: size.height / 2),
                        radius: max(0, (size.width - 1.5) / 2), startAngle: .degrees(arc.start),
                        endAngle: .degrees(arc.start + arc.sweep), clockwise: false)
            context.stroke(path, with: .color(ZTransferColors.accentBlue),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
        }
        .frame(width: 18, height: 18).accessibilityHidden(true)
        .onAppear { clock.start() }.onDisappear { clock.stop() }
    }
}

struct RemoteCameraToolPending: ViewModifier {
    let pending: Bool
    @StateObject private var clock = RemoteCameraToolLoop()
    func body(content: Content) -> some View {
        content.opacity(pending ? RemoteCameraToolIndicatorMotion.pendingOpacity(milliseconds: clock.milliseconds) : 1)
            .onAppear { if pending { clock.start() } }
            .onChange(of: pending) { if $0 { clock.start() } else { clock.stop() } }
            .onDisappear { clock.stop() }
    }
}

struct RemoteCameraToolMark: View {
    @ObservedObject var panel: RemoteCameraToolController
    let tool: RemoteCameraTool
    var body: some View {
        if panel.tool == tool && panel.loading { RemoteCameraToolLoading() }
        else { RemoteCameraToolStaticMark(tool: tool) }
    }
}

struct RemoteCameraToolStaticMark: View {
    let tool: RemoteCameraTool
    var body: some View {
        if tool == .whiteBalance { Text("WB").font(.system(size: 11, weight: .bold)) }
        else { RemoteEditorIcon(kind: .focusArea).frame(width: 19, height: 19) }
    }
}
