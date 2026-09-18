// Run from the repository root: xcrun swift tools/generate_ios_app_icon.swift [--check]
// Deterministically rasterizes the existing Android VectorDrawable; no new artwork.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error { case invalidSource(String) }

func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw IconError.invalidSource(reason) }
}

func color(_ hex: String) throws -> CGColor {
    try require(hex.count == 7 && hex.first == "#", "Expected opaque RGB color: \(hex)")
    guard let value = UInt32(hex.dropFirst(), radix: 16) else { throw IconError.invalidSource(hex) }
    return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [
        CGFloat((value >> 16) & 255) / 255, CGFloat((value >> 8) & 255) / 255,
        CGFloat(value & 255) / 255, 1
    ])!
}

func path(_ source: String) throws -> CGPath {
    // The actual launcher uses only absolute polygon commands. Reject future
    // unsupported commands rather than silently changing the Android geometry.
    let regex = try NSRegularExpression(pattern: #"[MLZ]|-?\d+(?:\.\d+)?"#)
    let range = NSRange(source.startIndex..., in: source)
    let leftovers = regex.stringByReplacingMatches(in: source, range: range, withTemplate: "")
    try require(leftovers.allSatisfy { $0.isWhitespace || $0 == "," }, "Unsupported vector command")
    let tokens = regex.matches(in: source, range: range).map { (source as NSString).substring(with: $0.range) }
    let result = CGMutablePath()
    var index = 0
    while index < tokens.count {
        let command = tokens[index]
        index += 1
        if command == "Z" { result.closeSubpath(); continue }
        try require(command == "M" || command == "L", "Expected path command")
        guard index + 1 < tokens.count,
              let x = Double(tokens[index]), let y = Double(tokens[index + 1]) else {
            throw IconError.invalidSource("Missing path coordinates")
        }
        let point = CGPoint(x: x, y: y)
        if command == "M" { result.move(to: point) } else { result.addLine(to: point) }
        index += 2
    }
    return result
}

let foregroundURL = URL(fileURLWithPath: "app/src/main/res/drawable/ic_launcher_foreground.xml")
let foreground = try XMLDocument(contentsOf: foregroundURL)
guard let vector = foreground.rootElement() else { throw IconError.invalidSource("Missing vector") }
try require(vector.attribute(forName: "android:viewportWidth")?.stringValue == "108" &&
            vector.attribute(forName: "android:viewportHeight")?.stringValue == "108", "Unexpected viewport")
let backgrounds = try XMLDocument(contentsOf: URL(fileURLWithPath: "app/src/main/res/values/ic_launcher_background.xml"))
guard let background = try backgrounds.nodes(forXPath: "/resources/color[@name='ic_launcher_background']").first?.stringValue else {
    throw IconError.invalidSource("Missing background")
}
let pixels = 1024
let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(try color(background))
context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
context.translateBy(x: 0, y: CGFloat(pixels))
context.scaleBy(x: CGFloat(pixels) / 72, y: -CGFloat(pixels) / 72)
// Android AdaptiveIconDrawable masks the central 72dp of its 108dp layers.
// Remove its 18dp motion margin, not the logo's own spacing. iOS supplies the
// rounded-corner mask; the source PNG remains a fully opaque square.
context.translateBy(x: -18, y: -18)
let paths = try vector.nodes(forXPath: "path")
try require(paths.count == 3, "Expected Android's three double-Z layers")
for case let element as XMLElement in paths {
    guard let geometry = element.attribute(forName: "android:pathData")?.stringValue,
          let fill = element.attribute(forName: "android:fillColor")?.stringValue else {
        throw IconError.invalidSource("Missing path or fill")
    }
    context.addPath(try path(geometry))
    context.setFillColor(try color(fill))
    if let stroke = element.attribute(forName: "android:strokeColor")?.stringValue {
        guard let rawWidth = element.attribute(forName: "android:strokeWidth")?.stringValue,
              let width = Double(rawWidth) else { throw IconError.invalidSource("Missing stroke width") }
        try require(element.attribute(forName: "android:strokeLineJoin")?.stringValue == "round", "Unexpected join")
        context.setStrokeColor(try color(stroke))
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
    } else { context.fillPath() }
}
let png = NSMutableData()
let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
try require(CGImageDestinationFinalize(destination), "Could not encode PNG")
let output = URL(fileURLWithPath: "ios/ZTransfer/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
if CommandLine.arguments.contains("--check") {
    try require(try Data(contentsOf: output) == png as Data, "AppIcon differs from Android; regenerate it")
    print("AppIcon matches Android vector, colors, layering and visible viewport.")
} else {
    try (png as Data).write(to: output, options: .atomic)
    print("Generated \(output.path)")
}
