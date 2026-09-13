import SwiftUI

/// Geometry ported from Android ZMark.kt: height-relative bars, shear and
/// overlap gap. Drawing uses the full requested size, without launcher-icon
/// canvas padding (the previous 108-unit canvas shrank the visible mark).
struct DoubleZMark: View {
    static let aspectRatio: CGFloat = 0.62 + 0.30 + 0.44
    var tint: Color = ZTransferColors.primaryText

    var body: some View {
        Canvas { context, size in
            let h = min(size.height, size.width / Self.aspectRatio)
            let origin = CGPoint(x: (size.width - h * Self.aspectRatio) / 2, y: (size.height - h) / 2)
            func z(offset: CGFloat) -> Path {
                let bar = 0.13 * h, diagonal = 0.15 * h, w = 0.62 * h
                let points: [CGPoint] = [
                    .init(x: 0, y: 0), .init(x: w, y: 0), .init(x: w, y: bar),
                    .init(x: diagonal, y: h - bar), .init(x: w, y: h - bar),
                    .init(x: w, y: h), .init(x: 0, y: h), .init(x: 0, y: h - bar),
                    .init(x: w - diagonal, y: bar), .init(x: 0, y: bar)
                ]
                var path = Path()
                for (index, p) in points.enumerated() {
                    let point = CGPoint(x: origin.x + offset + p.x + 0.30 * (h - p.y), y: origin.y + p.y)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                return path
            }
            let left = z(offset: 0), right = z(offset: 0.44 * h)
            context.drawLayer { layer in
                layer.fill(left, with: .color(tint))
                layer.blendMode = .destinationOut
                layer.stroke(right, with: .color(.black), style: StrokeStyle(lineWidth: 0.12 * h, lineJoin: .round))
                layer.fill(right, with: .color(.black))
                layer.blendMode = .normal
                layer.fill(right, with: .color(tint))
            }
        }
    }
}
