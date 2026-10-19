// Generated from AndroidX Compose Material Icons 1.5.4; Copyright AOSP.
// Apache-2.0; see Resources/licenses. Regenerate with generate-android-tool-icons.py.
import SwiftUI

struct QueueTopIcon: Shape {
    enum Kind: CaseIterable { case play, pause, checklist }
    let kind: Kind
    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .play:
            // rounded/PlayArrow.kt SHA256 7e22b8a6fa51a00a7492fba62e62f559f5481afb8d3071446bbed9310b6419b0
            path.move(to: CGPoint(x: 8, y: 6.82000017))
            path.addLine(to: CGPoint(x: 8, y: 17.1800003))
            path.addCurve(to: CGPoint(x: 9.53999996, y: 18.0200005), control1: CGPoint(x: 8, y: 17.9700012), control2: CGPoint(x: 8.86999989, y: 18.4500008))
            path.addLine(to: CGPoint(x: 17.6800003, y: 12.8400002))
            path.addCurve(to: CGPoint(x: 17.6800003, y: 11.1499996), control1: CGPoint(x: 18.3000011, y: 12.4499998), control2: CGPoint(x: 18.3000011, y: 11.5500002))
            path.addLine(to: CGPoint(x: 9.53999996, y: 5.98000002))
            path.addCurve(to: CGPoint(x: 8, y: 6.82000017), control1: CGPoint(x: 8.86999989, y: 5.55000019), control2: CGPoint(x: 8, y: 6.03000021))
            path.closeSubpath()
        case .pause:
            // filled/PauseKt.class SHA256 66b497305a2c16425195361d2912d2ae2c421f877594adc3f2a60f51b4947e7d
            path.move(to: CGPoint(x: 6, y: 19))
            path.addLine(to: CGPoint(x: 10, y: 19))
            path.addLine(to: CGPoint(x: 10, y: 5))
            path.addLine(to: CGPoint(x: 6, y: 5))
            path.addLine(to: CGPoint(x: 6, y: 19))
            path.closeSubpath()
            path.move(to: CGPoint(x: 14, y: 5))
            path.addLine(to: CGPoint(x: 14, y: 19))
            path.addLine(to: CGPoint(x: 18, y: 19))
            path.addLine(to: CGPoint(x: 18, y: 5))
            path.addLine(to: CGPoint(x: 14, y: 5))
            path.closeSubpath()
        case .checklist:
            // filled/ChecklistKt.class SHA256 4b49fc71c0453e9db90209ce700b2952ac2019cf768a5a0c818a7ab32e5c2847
            path.move(to: CGPoint(x: 22, y: 7))
            path.addLine(to: CGPoint(x: 13, y: 7))
            path.addLine(to: CGPoint(x: 13, y: 9))
            path.addLine(to: CGPoint(x: 22, y: 9))
            path.addLine(to: CGPoint(x: 22, y: 7))
            path.closeSubpath()
            path.move(to: CGPoint(x: 22, y: 15))
            path.addLine(to: CGPoint(x: 13, y: 15))
            path.addLine(to: CGPoint(x: 13, y: 17))
            path.addLine(to: CGPoint(x: 22, y: 17))
            path.addLine(to: CGPoint(x: 22, y: 15))
            path.closeSubpath()
            path.move(to: CGPoint(x: 5.53999996, y: 11))
            path.addLine(to: CGPoint(x: 2, y: 7.46000004))
            path.addLine(to: CGPoint(x: 3.40999985, y: 6.05000019))
            path.addLine(to: CGPoint(x: 5.52999973, y: 8.17000008))
            path.addLine(to: CGPoint(x: 9.7699995, y: 3.93000031))
            path.addLine(to: CGPoint(x: 11.1799994, y: 5.34000015))
            path.addLine(to: CGPoint(x: 5.53999996, y: 11))
            path.closeSubpath()
            path.move(to: CGPoint(x: 5.53999996, y: 19))
            path.addLine(to: CGPoint(x: 2, y: 15.46))
            path.addLine(to: CGPoint(x: 3.40999985, y: 14.0500002))
            path.addLine(to: CGPoint(x: 5.52999973, y: 16.1700001))
            path.addLine(to: CGPoint(x: 9.7699995, y: 11.9300003))
            path.addLine(to: CGPoint(x: 11.1799994, y: 13.3400002))
            path.addLine(to: CGPoint(x: 5.53999996, y: 19))
            path.closeSubpath()
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
