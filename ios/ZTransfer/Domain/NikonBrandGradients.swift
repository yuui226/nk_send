import CoreGraphics

struct NikonBrandGradientSpec { let start: CGPoint; let end: CGPoint; let locations: [CGFloat] }

enum NikonBrandGradients {
    static let specs: [NikonBrandGradientSpec] = [
        NikonBrandGradientSpec(start: CGPoint(x: -232.37078, y: 441.54325), end: CGPoint(x: 314.15783, y: 279.96727), locations: [0.0,  0.34,  0.66,  1.0]),
        NikonBrandGradientSpec(start: CGPoint(x: -185.44591, y: 391.44673), end: CGPoint(x: 339.28345, y: 220.85090), locations: [0.0,  0.355,  0.645,  1.0]),
        NikonBrandGradientSpec(start: CGPoint(x: -141.32136, y: 344.28204), end: CGPoint(x: 363.32607, y: 164.38788), locations: [0.0,  0.37,  0.63,  1.0]),
        NikonBrandGradientSpec(start: CGPoint(x: -99.51753, y: 299.61600), end: CGPoint(x: 386.22380, y: 110.23010), locations: [0.0,  0.385,  0.615,  1.0]),
        NikonBrandGradientSpec(start: CGPoint(x: -59.42329, y: 256.98444), end: CGPoint(x: 408.50267, y: 57.88248), locations: [0.0,  0.4,  0.6,  1.0]),
        NikonBrandGradientSpec(start: CGPoint(x: -21.06959, y: 216.24814), end: CGPoint(x: 430.15495, y: 7.08201), locations: [0.0,  0.415,  0.585,  1.0]),
        NikonBrandGradientSpec(start: CGPoint(x: 15.55904, y: 177.22917), end: CGPoint(x: 451.19611, y: -42.44207), locations: [0.0,  0.43,  0.57,  1.0]),
        NikonBrandGradientSpec(start: CGPoint(x: 51.25939, y: 139.43244), end: CGPoint(x: 471.90464, y: -91.05333), locations: [0.0,  0.445,  0.555,  1.0]),
        NikonBrandGradientSpec(start: CGPoint(x: 86.50333, y: 102.15401), end: CGPoint(x: 491.80864, y: -138.98386), locations: [0.0,  0.46,  0.54,  1.0]),
        NikonBrandGradientSpec(start: CGPoint(x: 122.11085, y: 64.65897), end: CGPoint(x: 512.43207, y: -187.36305), locations: [0.0,  0.475,  0.525,  1.0]),
        NikonBrandGradientSpec(start: .zero, end: .zero, locations: []),
    ]
}
