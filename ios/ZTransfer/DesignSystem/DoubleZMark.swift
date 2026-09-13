import SwiftUI

struct DoubleZMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 108, sy = rect.height / 108
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        func z(_ p: inout Path, _ values: [CGFloat]) {
            p.move(to: point(values[0], values[1])); stride(from: 2, to: values.count, by: 2).forEach { p.addLine(to: point(values[$0], values[$0 + 1])) }; p.closeSubpath()
        }
        var path = Path()
        let left: [CGFloat] = [39.56,35, 63.12,35, 61.64,39.94, 35.34,68.06, 53.2,68.06, 51.72,73, 28.16,73, 29.64,68.06, 55.94,39.94, 38.08,39.94]
        let right: [CGFloat] = [56.28,35, 79.84,35, 78.36,39.94, 52.06,68.06, 69.92,68.06, 68.44,73, 44.88,73, 46.36,68.06, 72.66,39.94, 54.8,39.94]
        z(&path, left); z(&path, right)
        return path
    }
}
