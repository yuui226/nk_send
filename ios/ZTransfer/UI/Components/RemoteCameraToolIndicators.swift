// Animation constants adapted from AndroidX Material3 ProgressIndicator.kt,
// Copyright 2023 The Android Open Source Project, Apache-2.0; see Resources/licenses.
import SwiftUI
import UIKit

/// Material3 1.1.2 LinearProgressIndicator: two independent head/tail keyframes,
/// 1800ms restart, transparent track, Butt caps. Used while a preview reads FHD.
enum RemoteReviewLoadingMotion {
    struct Segment: Equatable { let head: Float; let tail: Float }
    static func segments(milliseconds: Double) -> [Segment] {
        let phase = Float(max(0, milliseconds).truncatingRemainder(dividingBy: 1800))
        func value(delay: Float, duration: Float, x1: Float, x2: Float) -> Float {
            ZTransferAndroidMotion.cubicBezier(min(1, max(0, (phase - delay) / duration)), x1: x1, x2: x2)
        }
        return [Segment(head: value(delay: 0, duration: 750, x1: 0.2, x2: 0.8),
                        tail: value(delay: 333, duration: 850, x1: 0.4, x2: 1)),
                Segment(head: value(delay: 1000, duration: 567, x1: 0, x2: 0.65),
                        tail: value(delay: 1267, duration: 533, x1: 0.1, x2: 0.45))]
    }
}

struct RemoteReviewFHDLoading: View {
    @StateObject private var clock = RemoteCameraToolLoop()
    @Environment(\.layoutDirection) private var layoutDirection
    var body: some View {
        Canvas { context, size in
            for segment in RemoteReviewLoadingMotion.segments(milliseconds: clock.milliseconds)
                where segment.head > segment.tail {
                let start = layoutDirection == .leftToRight ? segment.tail : 1 - segment.head
                let end = layoutDirection == .leftToRight ? segment.head : 1 - segment.tail
                context.fill(Path(CGRect(x: CGFloat(start) * size.width, y: 0,
                                         width: CGFloat(end - start) * size.width, height: size.height)),
                    with: .color(Color(red: 79/255, green: 195/255, blue: 247/255).opacity(0.9)))
            }
        }
        .frame(height: 2).allowsHitTesting(false).accessibilityHidden(true)
        .onAppear { clock.start() }.onDisappear { clock.stop() }
    }
}

/// Material3 1.1.2 ProgressIndicator.kt (the Android app's resolved version):
/// five 1332ms rotations, linear base, and staggered 666ms eased head/tail.
enum RemoteCameraToolIndicatorMotion {
    static func arc(milliseconds: Double, strokeWidth: Double = 1.5) -> (start: Double, sweep: Double) {
        let total = max(0, milliseconds).truncatingRemainder(dividingBy: 6660)
        let phase = total.truncatingRemainder(dividingBy: 1332)
        let head = 290 * Double(ZTransferAndroidMotion.fastOutSlowIn(Float(min(1, phase / 666))))
        let tail = 290 * Double(ZTransferAndroidMotion.fastOutSlowIn(Float(max(0, (phase - 666) / 666))))
        // Compose computes the cap offset using the 40dp token diameter even
        // when RemoteScreen constrains the actual indicator to 18dp.
        let cap = (180 / Double.pi) * (strokeWidth / 20) / 2
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
final class RemoteCameraToolLoop: NSObject, ObservableObject {
    @Published private(set) var milliseconds: Double = 0
    private var first: CFTimeInterval?
    private var link: CADisplayLink?
    var clockRunning: Bool { link != nil }
    func start() {
        guard link == nil else { return }
        first = nil
        if milliseconds != 0 { milliseconds = 0 }
        let next = CADisplayLink(target: ClockTarget(self), selector: #selector(ClockTarget.frame(_:)))
        link = next
        next.add(to: .main, forMode: .common)
    }
    func advance(_ timestamp: CFTimeInterval) {
        if first == nil { first = timestamp }
        let next = (timestamp - first!) * 1000
        if milliseconds != next { milliseconds = next }
    }
    @MainActor private final class ClockTarget: NSObject {
        weak var owner: RemoteCameraToolLoop?
        init(_ owner: RemoteCameraToolLoop) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advance(link.timestamp)
        }
    }
    func stop() {
        link?.invalidate(); link = nil; first = nil
        if milliseconds != 0 { milliseconds = 0 }
    }
}

struct RemoteCameraToolLoading: View {
    var diameter: CGFloat = 18
    var strokeWidth: CGFloat = 1.5
    var color: Color = ZTransferColors.accentBlue
    @StateObject private var clock = RemoteCameraToolLoop()
    var body: some View {
        Canvas { context, size in
            let arc = RemoteCameraToolIndicatorMotion.arc(milliseconds: clock.milliseconds, strokeWidth: Double(strokeWidth))
            var path = Path()
            path.addArc(center: CGPoint(x: size.width / 2, y: size.height / 2),
                        radius: max(0, (size.width - strokeWidth) / 2), startAngle: .degrees(arc.start),
                        endAngle: .degrees(arc.start + arc.sweep), clockwise: false)
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: strokeWidth, lineCap: .square))
        }
        .frame(width: diameter, height: diameter).accessibilityHidden(true)
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
        else if tool == .focusMode { Text("MODE").font(.system(size: 9, weight: .bold)) }
        else { RemoteEditorIcon(kind: .focusArea).frame(width: 19, height: 19) }
    }
}

/// Camera-owned recording time, isolated from the monitor frame hierarchy.
struct RemoteRecordingElapsedText: View {
    @ObservedObject var elapsed: RemoteRecordingElapsed
    var leadingSpace = false
    var body: some View {
        Text(String(format: leadingSpace ? " %d:%02d" : "%d:%02d", elapsed.seconds / 60, elapsed.seconds % 60))
    }
}
