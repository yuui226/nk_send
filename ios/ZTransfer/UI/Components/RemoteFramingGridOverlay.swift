import SwiftUI

// FramingGridOverlay in RemoteViewfinderFeatures.kt: white 42%, 0.75dp,
// butt caps. The geometry excludes the displayed image's letterboxing.
struct RemoteFramingGridOverlay: View {
    let grid: RemoteGridMode
    let aspect: CGFloat

    var body: some View {
        Canvas { context, size in
            for line in RemoteFramingGrid.lines(grid, width: Float(size.width),
                                                height: Float(size.height), aspect: Float(aspect)) {
                var path = Path()
                path.move(to: line.start)
                path.addLine(to: line.end)
                context.stroke(path, with: .color(.white.opacity(0.42)),
                               style: StrokeStyle(lineWidth: 0.75, lineCap: .butt))
            }
        }
    }
}
