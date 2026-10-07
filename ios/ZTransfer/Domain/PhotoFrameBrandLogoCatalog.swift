import Foundation
import CoreGraphics

struct PhotoFrameBrandLogoAsset: Equatable, Sendable {
    let brand: PhotoFrameBrand
    let viewBox: CGRect
    let pathData: String
    let layers: [String]
    init(brand: PhotoFrameBrand, viewBox: CGRect, pathData: String, layers: [String] = []) {
        self.brand = brand; self.viewBox = viewBox; self.pathData = pathData; self.layers = layers.isEmpty ? [pathData] : layers
    }
    var pathDatas: [String] { layers }

    func makePath() -> CGPath? { SVGPathParser(input: pathData).parse() }
}

private struct SVGPathParser {
    let input: String
    func parse() -> CGPath? {
        // SVG permits adjacent signed numbers and decimal fractions (e.g. .5-.2.3).
        let regex = try! NSRegularExpression(pattern: #"[A-Za-z]|[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?"#)
        let source = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: source.length))
        var cursor = 0
        var tokens: [String] = []
        for match in matches {
            let gap = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            guard gap.allSatisfy({ $0.isWhitespace || $0 == "," }) else { return nil }
            tokens.append(source.substring(with: match.range))
            cursor = NSMaxRange(match.range)
        }
        guard source.substring(from: cursor).allSatisfy({ $0.isWhitespace || $0 == "," }),
              !tokens.isEmpty else { return nil }
        let path = CGMutablePath(); var i = 0; var command = ""; var current = CGPoint.zero; var start = CGPoint.zero; var cubicControl: CGPoint?
        func number() -> CGFloat? { guard i < tokens.count, let v = Double(tokens[i]), v.isFinite else { return nil }; i += 1; return CGFloat(v) }
        while i < tokens.count {
            if tokens[i].first?.isLetter == true { command = tokens[i]; i += 1 }
            guard let op = command.first else { return nil }; let relative = op.isLowercase; let kind = op.uppercased()
            func point() -> CGPoint? { guard let x = number(), let y = number() else { return nil }; return CGPoint(x: relative ? current.x + x : x, y: relative ? current.y + y : y) }
            let previousControl = cubicControl
            cubicControl = nil
            switch kind {
            case "M": guard let p = point() else { return nil }; path.move(to: p); current = p; start = p; command = relative ? "l" : "L"
            case "L": guard let p = point() else { return nil }; path.addLine(to: p); current = p
            case "H": guard let x = number() else { return nil }; current.x = relative ? current.x + x : x; path.addLine(to: current)
            case "V": guard let y = number() else { return nil }; current.y = relative ? current.y + y : y; path.addLine(to: current)
            case "C": guard let p1 = point(), let p2 = point(), let p3 = point() else { return nil }; path.addCurve(to: p3, control1: p1, control2: p2); current = p3; cubicControl = p2
            case "S":
                guard let p2 = point(), let p3 = point() else { return nil }
                let p1 = previousControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: p3, control1: p1, control2: p2)
                current = p3; cubicControl = p2
            case "A":
                guard let rx = number(), let ry = number(), let rotation = number(),
                      let large = number(), let sweep = number(),
                      (large == 0 || large == 1), (sweep == 0 || sweep == 1),
                      let end = point() else { return nil }
                appendArc(path, from: current, to: end, rx: rx, ry: ry,
                          rotation: rotation, large: large == 1, sweep: sweep == 1)
                current = end
            case "Z": path.closeSubpath(); current = start; command = ""
            default: return nil
            }
        }
        return path.copy()
    }
    /// Endpoint ellipse conversion; split into at most 45-degree cubic segments,
    /// matching Android PathParser's subdivision and tangent approximation.
    private func appendArc(_ path: CGMutablePath, from start: CGPoint, to end: CGPoint,
                           rx inputRX: CGFloat, ry inputRY: CGFloat, rotation: CGFloat,
                           large: Bool, sweep: Bool) {
        if start == end { return }
        var rx = abs(inputRX), ry = abs(inputRY)
        guard rx > 0, ry > 0 else { path.addLine(to: end); return }
        let phi = rotation * .pi / 180, c = cos(phi), s = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x = c * dx + s * dy, y = -s * dx + c * dy
        let extent = x * x / (rx * rx) + y * y / (ry * ry)
        if extent > 1 { let factor = sqrt(extent); rx *= factor; ry *= factor }
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y * y - ry * ry * x * x)
        let denominator = rx * rx * y * y + ry * ry * x * x
        let k = (large == sweep ? CGFloat(-1) : 1) * sqrt(numerator / denominator)
        let cxLocal = k * rx * y / ry, cyLocal = -k * ry * x / rx
        let cx = c * cxLocal - s * cyLocal + (start.x + end.x) / 2
        let cy = s * cxLocal + c * cyLocal + (start.y + end.y) / 2
        let first = atan2((y - cyLocal) / ry, (x - cxLocal) / rx)
        var delta = atan2((-y - cyLocal) / ry, (-x - cxLocal) / rx) - first
        if sweep && delta < 0 { delta += 2 * .pi }
        if !sweep && delta > 0 { delta -= 2 * .pi }
        let count = max(1, Int(ceil(abs(delta) * 4 / .pi)))
        let step = delta / CGFloat(count)
        func position(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * c * cos(t) - ry * s * sin(t),
                    y: cy + rx * s * cos(t) + ry * c * sin(t))
        }
        func tangent(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * c * sin(t) - ry * s * cos(t),
                    y: -rx * s * sin(t) + ry * c * cos(t))
        }
        for index in 0..<count {
            let a = first + CGFloat(index) * step, b = a + step
            let p = position(a), q = position(b), u = tangent(a), v = tangent(b)
            let t = tan(step / 2)
            let alpha = sin(step) * (sqrt(4 + 3 * t * t) - 1) / 3
            path.addCurve(to: index == count - 1 ? end : q,
                          control1: CGPoint(x: p.x + alpha * u.x, y: p.y + alpha * u.y),
                          control2: CGPoint(x: q.x - alpha * v.x, y: q.y - alpha * v.y))
        }
    }

}

enum PhotoFrameBrandLogoCatalog {
    static let officialNikonResource = "nikon-official.svg"
    static func load(_ brand: PhotoFrameBrand, bundle: Bundle = .main) -> PhotoFrameBrandLogoAsset? {
        let resourceName = brand == .nikon ? "nikon-official" : brand.rawValue
        guard let url = bundle.url(forResource: resourceName, withExtension: "svg", subdirectory: "BrandLogos")
            ?? bundle.url(forResource: brand.rawValue, withExtension: "svg"),
              let xml = try? String(contentsOf: url, encoding: .utf8),
              let viewBox = attribute("viewBox", in: xml).flatMap(parseViewBox),
              let pathData = pathData(in: xml), !pathData.isEmpty else { return nil }
        let layers = allPathData(in: xml)
        return PhotoFrameBrandLogoAsset(brand: brand, viewBox: viewBox, pathData: pathData, layers: layers)
    }

    private static func attribute(_ name: String, in xml: String) -> String? {
        guard let range = xml.range(of: "\\b\(name)\\s*=\\s*\\\"([^\\\"]+)\\\"", options: .regularExpression) else { return nil }
        let value = String(xml[range])
        guard let equals = value.firstIndex(of: "=") else { return nil }
        return value[value.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \\\""))
    }

    private static func parseViewBox(_ value: String) -> CGRect? {
        let values = value.split { $0 == " " || $0 == "," }.compactMap { Double($0) }
        guard values.count == 4, values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static func pathData(in xml: String) -> String? {
        guard let range = xml.range(of: "<path\\b[^>]*\\bd=\\\"([^\\\"]+)\\\"", options: .regularExpression) else { return nil }
        let value = String(xml[range])
        guard let marker = value.range(of: "d=\\\"", options: .regularExpression) else { return nil }
        let start = marker.upperBound
        guard let end = value[start...].firstIndex(of: "\"") else { return nil }
        return String(value[start..<end])
    }

    private static func allPathData(in xml: String) -> [String] {
        let pattern = #"<path\b[^>]*\bd=\"([^\"]+)\""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return expression.matches(in: xml, range: range).compactMap { match in
            guard let value = Range(match.range(at: 1), in: xml) else { return nil }
            return String(xml[value])
        }
    }
}
