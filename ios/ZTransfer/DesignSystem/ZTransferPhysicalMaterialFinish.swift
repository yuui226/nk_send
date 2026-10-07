import SwiftUI

/// GlassButton.kt titaniumRoundedFinish / woodSculptedFinish /
/// cameraControlCapFinish. Draw order and geometry are shared by every caller.
struct ZTransferPhysicalMaterialFinish: View, Animatable {
    let skin: ZTransferButtonSkin
    let cornerRadius: CGFloat
    let dark: Bool
    let panel: Bool
    let activeColor: Color
    var pressProgress: CGFloat
    var activeProgress: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pressProgress, activeProgress) }
        set { pressProgress = newValue.first; activeProgress = newValue.second }
    }

    var body: some View {
        Canvas { context, size in
            let w = max(size.width, 1), h = max(size.height, 1)
            let longest = max(w, h)
            let press = min(max(pressProgress, 0), 1)
            let active = min(max(activeProgress, 0), 1)
            let factor: CGFloat = panel ? 0.66 : 1
            let path = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
                .path(in: CGRect(origin: .zero, size: size))
            context.clip(to: path)
            func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> Color {
                Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
                      green: Double((hex >> 8) & 255) / 255,
                      blue: Double(hex & 255) / 255, opacity: Double(alpha))
            }
            func gradient(_ stops: [(CGFloat, Color)]) -> Gradient {
                Gradient(stops: stops.map { .init(color: $0.1, location: $0.0) })
            }
            func radial(_ stops: [(CGFloat, Color)], _ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
                context.fill(path, with: .radialGradient(gradient(stops),
                    center: CGPoint(x: w * x, y: h * y), startRadius: 0, endRadius: radius))
            }
            func linear(_ stops: [(CGFloat, Color)], _ start: CGPoint = .zero,
                        _ end: CGPoint? = nil, stroke: CGFloat? = nil) {
                let shading = GraphicsContext.Shading.linearGradient(gradient(stops),
                    startPoint: start, endPoint: end ?? CGPoint(x: 0, y: h))
                if let stroke { context.stroke(path, with: shading, lineWidth: stroke) }
                else { context.fill(path, with: shading) }
            }
            switch skin {
            case .titanium:
                let volume = 1 - 0.62 * press
                let f = factor * volume
                let light: UInt32 = dark ? 0xEAF2F6 : 0xFFFFFF
                let mid: UInt32 = dark ? 0xB8C4CA : 0xDCE4E8
                let shadow: UInt32 = dark ? 0x242E35 : 0x66737B
                radial([(0, rgb(light, 0.18 * f)), (0.34, rgb(mid, 0.105 * f)),
                        (0.62, rgb(mid, 0.035 * f)), (0.82, rgb(shadow, 0.055 * f)),
                        (1, rgb(shadow, (dark ? 0.16 : 0.12) * f))],
                       0.40, 0.30, max(w * 0.53, h * 1.88))
                linear([(0, rgb(light, 0.16 * f)), (0.24, rgb(mid, 0.065 * f)),
                        (0.52, .clear), (1, .clear)])
                linear([(0, rgb(light, 0.040 * f)), (0.22, .clear), (0.68, .clear),
                        (1, rgb(shadow, 0.15 * f))], .zero, CGPoint(x: w, y: 0))
                linear([(0, .clear), (0.54, .clear), (0.76, rgb(shadow, 0.060 * f)),
                        (1, rgb(shadow, (dark ? 0.30 : 0.22) * f))])
                linear([(0, .clear), (0.22, .clear), (0.43, rgb(light, 0.060 * f)),
                        (0.62, rgb(mid, 0.028 * f)), (0.82, .clear), (1, .clear)],
                       CGPoint(x: -w * 0.10, y: 0), CGPoint(x: w * 1.06, y: h * 0.72))
                if press > 0.001 {
                    radial([(0, rgb(shadow, 0.045 * press * factor)), (1, .clear)],
                           0.5, 0.52, longest * 0.72)
                }
            case .wood:
                let volume = 1 - 0.64 * press
                let f = factor * volume
                let warm: UInt32 = dark ? 0xF7D69B : 0xFFE0A9
                let shadow: UInt32 = dark ? 0x140A04 : 0x5C3013
                radial([(0, rgb(warm, (dark ? 0.115 : 0.13) * f)),
                        (0.35, rgb(warm, (dark ? 0.068 : 0.080) * f)),
                        (0.61, rgb(warm, 0.025 * f)), (0.81, rgb(shadow, 0.045 * f)),
                        (1, rgb(shadow, (dark ? 0.135 : 0.10) * f))],
                       0.39, 0.30, max(w * 0.53, h * 1.98))
                linear([(0, rgb(warm, (dark ? 0.105 : 0.14) * f)),
                        (0.20, rgb(warm, (dark ? 0.040 : 0.055) * f)), (0.46, .clear), (1, .clear)])
                linear([(0, rgb(warm, 0.025 * f)), (0.22, .clear), (0.72, .clear),
                        (1, rgb(shadow, (dark ? 0.135 : 0.095) * f))], .zero, CGPoint(x: w, y: 0))
                linear([(0, .clear), (0.58, .clear), (0.78, rgb(shadow, 0.055 * f)),
                        (1, rgb(shadow, (dark ? 0.31 : 0.21) * f))])
                if press > 0.001 {
                    radial([(0, rgb(shadow, 0.045 * press * factor)), (1, .clear)],
                           0.5, 0.52, longest * 0.72)
                }
            case .cameraControls where !panel:
                let volume = 1 - 0.72 * press
                let cool: UInt32 = dark ? 0xD2D7DA : 0xBEC4C7
                radial([(0, rgb(cool, 0.075 * volume)), (0.38, rgb(cool, 0.040 * volume)),
                        (0.72, .clear), (1, rgb(0, 0.11 * volume))], 0.42, 0.28, longest * 0.82)
                linear([(0, rgb(cool, 0.16 * volume)), (0.10, rgb(cool, 0.055 * volume)),
                        (0.34, .clear), (0.70, .clear), (1, rgb(0, 0.34 * volume))])
                if active > 0.001 {
                    radial([(0, activeColor.opacity(0.14 * active)),
                            (0.5, activeColor.opacity(0.045 * active)), (1, .clear)],
                           0.50, 0.42, longest * 0.78)
                }
                // Android Stroke is centered on the outline and then clipped.
                linear([(0, rgb(0, 0.20)), (0.45, rgb(0, 0.10)), (1, rgb(0, 0.68))], stroke: 3.2)
                linear([(0, rgb(cool, dark ? 0.22 : 0.16)), (0.34, rgb(cool, 0.050)),
                        (0.68, rgb(0, 0.30)), (1, rgb(0, 0.82))], stroke: 1.05)
                if press > 0.001 { context.fill(path, with: .color(rgb(0, 0.10 * press))) }
            case .cameraControls, .frostedGlass, .liquidGlass: break
            }
        }
        .allowsHitTesting(false)
    }
}

/// Inner-edge subtraction, not an exterior glyph shadow. Each knockout is
/// isolated before tinting, matching Android's DstOut + SrcIn saveLayers.
struct ZTransferTitaniumStamp: ViewModifier, Animatable {
    let dark: Bool
    let inlay: Color?
    var pressProgress: CGFloat
    nonisolated var animatableData: CGFloat {
        get { pressProgress }
        set { pressProgress = newValue }
    }

    private func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }

    func body(content: Content) -> some View {
        let depth = (dark ? 0.48 : 0.44) * (1 - 0.12 * min(max(pressProgress, 0), 1))
        let fine = depth * 0.48
        let face = inlay ?? rgb(dark ? 0x2B373E : 0x58656C)
        let faceAlpha = inlay == nil ? (dark ? 0.90 : 0.88) : (dark ? 0.96 : 0.92)
        content.hidden().overlay {
            face.opacity(faceAlpha).mask(content)
                .overlay { edge(content, offset: depth, color: rgb(dark ? 0x1D272D : 0x505D64), alpha: dark ? 0.38 : 0.28) }
                .overlay { edge(content, offset: fine, color: rgb(dark ? 0x111A1F : 0x3F4B52), alpha: dark ? 0.25 : 0.18) }
                .overlay { edge(content, offset: -depth, color: rgb(dark ? 0xD6E1E6 : 0xF1F6F8), alpha: dark ? 0.24 : 0.30) }
                .overlay { edge(content, offset: -fine, color: rgb(dark ? 0xF0F6F8 : 0xFFFFFF), alpha: dark ? 0.16 : 0.20) }
        }
    }

    private func edge(_ content: Content, offset: CGFloat, color: Color, alpha: Double) -> some View {
        color.opacity(alpha).mask {
            content.overlay {
                content.drawingGroup(opaque: false, colorMode: .nonLinear)
                    .transformEffect(CGAffineTransform(translationX: offset, y: offset))
                    .blendMode(.destinationOut)
            }.compositingGroup()
        }
    }
}
