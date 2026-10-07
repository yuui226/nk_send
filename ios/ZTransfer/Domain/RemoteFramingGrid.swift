import Foundation

// Android RemoteViewfinderFeatures.kt: retain Float arithmetic before converting
// to SwiftUI coordinates. Fractions apply to the fitted, desqueezed image.
extension RemoteGridMode {
    static let menuOrder: [Self] = [.off, .thirds, .thirdsDiagonals, .fourths,
                                  .fourthsDiagonals, .center, .golden, .wide235, .wide169, .frame43]
    var labelResource: String {
        switch self {
        case .off: "remote_grid_off"
        case .thirds: "remote_grid_thirds"
        case .thirdsDiagonals: "remote_grid_thirds_diagonals"
        case .fourths: "remote_grid_fourths"
        case .fourthsDiagonals: "remote_grid_fourths_diagonals"
        case .center: "remote_grid_center"
        case .golden: "remote_grid_golden"
        case .wide235: "remote_grid_235"
        case .wide169: "remote_grid_169"
        case .frame43: "remote_grid_43"
        }
    }
    var next: Self { Self.menuOrder[(Self.menuOrder.firstIndex(of: self)! + 1) % Self.menuOrder.count] }
    var fractions: [Float] {
        switch self {
        case .thirds, .thirdsDiagonals: [1 / 3, 2 / 3]
        case .fourths, .fourthsDiagonals: [0.25, 0.5, 0.75]
        case .center: [0.5]
        case .golden: [0.38196602, 0.618034]
        default: []
        }
    }
    var diagonals: Bool { self == .thirdsDiagonals || self == .fourthsDiagonals }
    var frameAspect: Float? {
        switch self {
        case .wide235: 2.35
        case .wide169: 16 / 9
        case .frame43: 4 / 3
        default: nil
        }
    }
}

struct RemoteFramingGridLine: Equatable {
    let start: CGPoint
    let end: CGPoint
}

enum RemoteFramingGrid {
    struct Rect {
        let left: Float
        let top: Float
        let right: Float
        let bottom: Float
        var width: Float { right - left }
        var height: Float { bottom - top }
    }

    static func fit(width: Float, height: Float, aspect: Float) -> Rect {
        guard width > 0, height > 0, aspect.isFinite, aspect > 0 else {
            return Rect(left: 0, top: 0, right: 0, bottom: 0)
        }
        let fittedWidth: Float
        let fittedHeight: Float
        if aspect >= width / height {
            fittedWidth = width
            fittedHeight = width / aspect
        } else {
            fittedHeight = height
            fittedWidth = height * aspect
        }
        let left = (width - fittedWidth) / 2
        let top = (height - fittedHeight) / 2
        return Rect(left: left, top: top, right: left + fittedWidth, bottom: top + fittedHeight)
    }

    static func lines(_ grid: RemoteGridMode, width: Float, height: Float, aspect: Float) -> [RemoteFramingGridLine] {
        guard grid != .off else { return [] }
        let rect = fit(width: width, height: height, aspect: aspect)
        guard rect.width > 0, rect.height > 0 else { return [] }
        func line(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> RemoteFramingGridLine {
            RemoteFramingGridLine(start: CGPoint(x: CGFloat(x0), y: CGFloat(y0)),
                                  end: CGPoint(x: CGFloat(x1), y: CGFloat(y1)))
        }
        if let target = grid.frameAspect {
            let fitted = fit(width: rect.width, height: rect.height, aspect: target)
            let left = fitted.left + rect.left, right = fitted.right + rect.left
            let top = fitted.top + rect.top, bottom = fitted.bottom + rect.top
            return [line(left, top, right, top), line(right, top, right, bottom),
                    line(right, bottom, left, bottom), line(left, bottom, left, top)]
        }
        var result = grid.fractions.flatMap { fraction in
            let x = rect.left + rect.width * fraction
            let y = rect.top + rect.height * fraction
            return [line(x, rect.top, x, rect.bottom), line(rect.left, y, rect.right, y)]
        }
        if grid.diagonals {
            result += [line(rect.left, rect.top, rect.right, rect.bottom),
                       line(rect.right, rect.top, rect.left, rect.bottom)]
        }
        return result
    }
}
