import SwiftUI
import UIKit

/// Android FileListScreen remote entry geometry, including bounded overshoot.
struct RemoteEntryRevealValues {
    let x: Double
    let y: Double
    let scale: Double
    let rotation: Double

    init(progress: Double) {
        let p = min(1.12, max(-0.12, progress))
        let path = min(1, max(0, p))
        let arc = sin(path * .pi)
        x = -48 * (1 - p)
        y = -6 * arc
        scale = 0.88 + 0.12 * p
        rotation = -3.5 * (1 - path) + 1.25 * arc
    }
}

private struct RemoteEntryReveal: AnimatableModifier {
    var progress: Double
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let value = RemoteEntryRevealValues(progress: progress)
        content.scaleEffect(value.scale)
            .rotationEffect(.degrees(value.rotation))
            .offset(x: value.x, y: value.y)
    }
}

/// Marks.kt RemoteMark; using its path avoids substituting a platform glyph.
private struct RemoteEntryMark: View {
    let color: Color
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            var body = Path()
            body.move(to: point(0.20, 0.30))
            body.addLine(to: point(0.30, 0.30))
            body.addLine(to: point(0.36, 0.20))
            body.addQuadCurve(to: point(0.42, 0.17), control: point(0.38, 0.17))
            body.addLine(to: point(0.57, 0.17))
            body.addQuadCurve(to: point(0.63, 0.20), control: point(0.61, 0.17))
            body.addLine(to: point(0.70, 0.30))
            body.addLine(to: point(0.80, 0.30))
            body.addQuadCurve(to: point(0.89, 0.39), control: point(0.89, 0.30))
            body.addLine(to: point(0.89, 0.73))
            body.addQuadCurve(to: point(0.80, 0.82), control: point(0.89, 0.82))
            body.addLine(to: point(0.20, 0.82))
            body.addQuadCurve(to: point(0.11, 0.73), control: point(0.11, 0.82))
            body.addLine(to: point(0.11, 0.39))
            body.addQuadCurve(to: point(0.20, 0.30), control: point(0.11, 0.30))
            body.closeSubpath()
            context.stroke(body, with: .color(color),
                           style: StrokeStyle(lineWidth: 0.075 * s, lineCap: .round, lineJoin: .round))
            context.stroke(Path(ellipseIn: CGRect(x: 0.32 * s, y: 0.40 * s,
                                                  width: 0.32 * s, height: 0.32 * s)),
                           with: .color(color), lineWidth: 0.075 * s)
            context.fill(Path(ellipseIn: CGRect(x: 0.725 * s, y: 0.385 * s,
                                                width: 0.07 * s, height: 0.07 * s)), with: .color(color))
        }
    }
}

struct RemoteEntryButton: View {
    let expanded: Bool
    let intro: Bool
    let busy: Bool
    let action: () -> Void

    private var label: String { AppLocalized.resource("remote_entry_intro") }
    private var labelWidth: CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .medium)]).width)
    }
    private var introWidth: CGFloat { max(140, labelWidth + 62) }
    private let curve = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.30)

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: action) {
                HStack(spacing: 0) {
                    RemoteEntryMark(color: busy ? ZTransferColors.secondaryText.opacity(0.5) : ZTransferColors.accentBlue)
                        .frame(width: 24, height: 24)
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(busy ? ZTransferColors.secondaryText : ZTransferColors.primaryText)
                        .lineLimit(1).fixedSize()
                        .opacity(intro ? 1 : 0)
                        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: intro ? 0.18 : 0.12)
                            .delay(intro ? 0.07 : 0), value: intro)
                        .padding(.leading, 6)
                        .frame(width: intro ? labelWidth + 6 : 0, alignment: .leading)
                        .clipped()
                        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: intro ? 0.25 : 0.24), value: intro)
                        .accessibilityHidden(true)
                }
                .frame(width: intro ? introWidth : 52, height: 52)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 26, active: intro && !busy,
                                                   activeColor: ZTransferColors.accentBlue,
                                                   showSheen: false, frostedOpacityBoost: 0.35, shadowElevation: 6))
            .animation(intro ? .interpolatingSpring(mass: 1, stiffness: 400, damping: 20) : curve, value: intro)
            .modifier(RemoteEntryReveal(progress: expanded ? 1 : 0))
            .animation(.interpolatingSpring(mass: 1, stiffness: 360, damping: 2 * 0.58 * sqrt(360)), value: expanded)
            .offset(x: 20)
            .accessibilityLabel(AppLocalized.resource("cd_remote_entry"))
            .accessibilityHidden(!expanded)

            if !expanded {
                Button(action: action) {
                    Color.clear.frame(width: 48, height: 56).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalized.resource("cd_remote_entry"))
            }
        }
        .frame(width: introWidth + 24, height: 56, alignment: .leading)
    }
}
