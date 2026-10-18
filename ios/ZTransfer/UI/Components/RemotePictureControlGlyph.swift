// Generated from Android ic_picture_control{,_colors}.xml by generate-picture-control-icon.py.
// Preserve the 24:16 intrinsic aspect, 1249×800 viewport and scaleY=-1/translateY=740.
import SwiftUI

struct RemotePictureControlGlyph: View {
    @Environment(\.remoteToolTint) private var tint
    var body: some View {
        Canvas { context, size in
            let height = size.width * 16 / 24
            context.translateBy(x: 0, y: (size.height - height) / 2)
            context.scaleBy(x: size.width / 1249, y: height / 800)
            context.translateBy(x: 0, y: 740)
            context.scaleBy(x: 1, y: -1)
            for (path, color) in Self.layers { context.fill(path, with: .color(color ?? tint)) }
        }.frame(width: 22, height: 22)
    }
    private static let layers: [(Path, Color?)] = {
        var layers: [(Path, Color?)] = []
        // ic_picture_control.xml SHA256 acc5d7986978360baec31d0dcb3688daf4f9b99ae05395b8a8e44c45c0b81327
        do {
            var path = Path()
            path.move(to: CGPoint(x: 915, y: 170))
            path.addLine(to: CGPoint(x: 1101, y: 215))
            path.addLine(to: CGPoint(x: 981, y: 270))
            path.addLine(to: CGPoint(x: 799, y: 231))
            path.closeSubpath()
            path.move(to: CGPoint(x: 887, y: 66))
            path.addLine(to: CGPoint(x: 887, y: 132))
            path.addLine(to: CGPoint(x: 718, y: 220))
            path.addLine(to: CGPoint(x: 709, y: 226))
            path.addLine(to: CGPoint(x: 702, y: 231))
            path.addLine(to: CGPoint(x: 698, y: 237))
            path.addLine(to: CGPoint(x: 696, y: 243))
            path.addLine(to: CGPoint(x: 698, y: 249))
            path.addLine(to: CGPoint(x: 703, y: 255))
            path.addLine(to: CGPoint(x: 712, y: 259))
            path.addLine(to: CGPoint(x: 723, y: 263))
            path.addLine(to: CGPoint(x: 887, y: 298))
            path.addLine(to: CGPoint(x: 887, y: 614))
            path.addLine(to: CGPoint(x: 103, y: 614))
            path.addLine(to: CGPoint(x: 103, y: 66))
            path.addLine(to: CGPoint(x: 887, y: 66))
            path.closeSubpath()
            path.move(to: CGPoint(x: 1209, y: 210))
            path.addLine(to: CGPoint(x: 1209, y: 203))
            path.addLine(to: CGPoint(x: 1207, y: 198))
            path.addLine(to: CGPoint(x: 1201, y: 194))
            path.addLine(to: CGPoint(x: 1193, y: 190))
            path.addLine(to: CGPoint(x: 1183, y: 187))
            path.addLine(to: CGPoint(x: 950, y: 130))
            path.addLine(to: CGPoint(x: 950, y: 3))
            path.addLine(to: CGPoint(x: 40, y: 3))
            path.addLine(to: CGPoint(x: 40, y: 677))
            path.addLine(to: CGPoint(x: 950, y: 677))
            path.addLine(to: CGPoint(x: 950, y: 312))
            path.addLine(to: CGPoint(x: 986, y: 320))
            path.addLine(to: CGPoint(x: 1187, y: 228))
            path.addLine(to: CGPoint(x: 1198, y: 222))
            path.addLine(to: CGPoint(x: 1205, y: 216))
            path.closeSubpath()
            layers.append((path, nil))
        }
        // ic_picture_control_colors.xml SHA256 6028c991750b4d3b72e2e2ef22222e50cd5db3db16ba3821d135461c95a49493
        do {
            var path = Path()
            path.move(to: CGPoint(x: 253, y: 459))
            path.addLine(to: CGPoint(x: 340, y: 546))
            path.addLine(to: CGPoint(x: 373, y: 415))
            path.addLine(to: CGPoint(x: 286, y: 328))
            path.closeSubpath()
            layers.append((path, Color(red: 223 / 255, green: 102 / 255, blue: 114 / 255)))
        }
        do {
            var path = Path()
            path.move(to: CGPoint(x: 494, y: 544))
            path.addLine(to: CGPoint(x: 617, y: 544))
            path.addLine(to: CGPoint(x: 548, y: 428))
            path.addLine(to: CGPoint(x: 424, y: 428))
            path.closeSubpath()
            layers.append((path, Color(red: 210 / 255, green: 154 / 255, blue: 50 / 255)))
        }
        do {
            var path = Path()
            path.move(to: CGPoint(x: 732, y: 448))
            path.addLine(to: CGPoint(x: 819, y: 361))
            path.addLine(to: CGPoint(x: 688, y: 328))
            path.addLine(to: CGPoint(x: 601, y: 415))
            path.closeSubpath()
            layers.append((path, Color(red: 53 / 255, green: 164 / 255, blue: 124 / 255)))
        }
        do {
            var path = Path()
            path.move(to: CGPoint(x: 171, y: 212))
            path.addLine(to: CGPoint(x: 171, y: 333))
            path.addLine(to: CGPoint(x: 284, y: 265))
            path.addLine(to: CGPoint(x: 284, y: 144))
            path.closeSubpath()
            layers.append((path, Color(red: 57 / 255, green: 143 / 255, blue: 209 / 255)))
        }
        return layers
    }()
}
