import SwiftUI

/// The Android connection page uses its own three-prong USB mark rather than a
/// platform glyph. Keeping the geometry here makes the mark identical in the
/// connection page and the later signal pill.
struct ClassicUSBIcon: View {
    var tint: Color

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height)
            let stroke = unit * 0.11
            let cx = size.width * 0.5
            let junctionY = size.height * 0.62
            var branches = Path()
            branches.move(to: CGPoint(x: cx, y: size.height * 0.84))
            branches.addLine(to: CGPoint(x: cx, y: size.height * 0.22))
            branches.move(to: CGPoint(x: cx, y: junctionY))
            branches.addLine(to: CGPoint(x: size.width * 0.25, y: size.height * 0.48))
            branches.move(to: CGPoint(x: cx, y: size.height * 0.52))
            branches.addLine(to: CGPoint(x: size.width * 0.76, y: size.height * 0.38))
            branches.addLine(to: CGPoint(x: size.width * 0.76, y: size.height * 0.25))
            context.stroke(branches, with: .color(tint), style: StrokeStyle(lineWidth: stroke, lineCap: .round))

            var arrow = Path()
            arrow.move(to: CGPoint(x: cx, y: size.height * 0.08))
            arrow.addLine(to: CGPoint(x: size.width * 0.36, y: size.height * 0.27))
            arrow.addLine(to: CGPoint(x: size.width * 0.64, y: size.height * 0.27))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(tint))
            context.fill(Path(ellipseIn: CGRect(x: size.width * 0.13, y: size.height * 0.37, width: unit * 0.18, height: unit * 0.18)), with: .color(tint))
            context.fill(Path(CGRect(x: size.width * 0.68, y: size.height * 0.10, width: unit * 0.16, height: unit * 0.16)), with: .color(tint))
        }
        .accessibilityLabel("USB")
    }
}
