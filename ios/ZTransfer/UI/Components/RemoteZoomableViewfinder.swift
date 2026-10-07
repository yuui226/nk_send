import SwiftUI

struct RemoteZoomableViewfinder<Content: View>: View {
    let aspect: CGFloat
    let imageSize: CGSize
    let metadata: RemoteLiveViewMetadata?
    let onFocus: (RemoteFocusPoint) -> Void
    @ViewBuilder let content: () -> Content
    @State private var viewport = RemoteViewfinderViewport()

    var body: some View {
        GeometryReader { proxy in
            let fitted = RemoteFramingGrid.fit(width: Float(proxy.size.width), height: Float(proxy.size.height), aspect: Float(aspect))
            let imageRect = CGRect(x: CGFloat(fitted.left), y: CGFloat(fitted.top),
                                   width: CGFloat(fitted.width), height: CGFloat(fitted.height))
            ZStack(alignment: .topTrailing) {
                content()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(CGFloat(viewport.scale))
                    .offset(x: CGFloat(viewport.offset.x), y: CGFloat(viewport.offset.y))
                    .mask { Path { $0.addRect(imageRect) } }
                    .allowsHitTesting(false)
                RemoteViewfinderInput(identity: .init(aspect: aspect, imageSize: imageSize, metadata: metadata), onTransform: { change in
                    viewport.transform(centroid: change.centroid, pan: change.pan,
                                       zoom: change.zoom, aspect: Float(aspect))
                }, acceptsTap: { point in
                    viewport.focusPoint(at: point, aspect: Float(aspect)) != nil
                }, onTap: { point in
                    if let focus = viewport.focusPoint(at: point, aspect: Float(aspect)) { onFocus(focus) }
                }, onDoubleTap: { viewport.reset() })
                if viewport.scale > 1.01 {
                    navigator(crop: viewport.visibleRegion(aspect: Float(aspect)))
                        .frame(width: 64, height: 64 / aspect)
                        .padding(.top, 42).padding(.trailing, 8)
                        .allowsHitTesting(false)
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--remote-camera-tools-ui-test") {
                    Text(verbatim: "scale=\(viewport.scale);x=\(viewport.offset.x);y=\(viewport.offset.y)")
                        .font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("remote-viewport-state")
                }
                #endif
            }
            .clipped()
            .onAppear { viewport.resize(proxy.size, aspect: Float(aspect)); viewport.reset() }
            .onChange(of: proxy.size) { viewport.resize($0, aspect: Float(aspect)) }
            .onChange(of: aspect) { _ in
                viewport.reset()
                viewport.resize(proxy.size, aspect: Float(aspect))
            }
        }
    }

    private func navigator(crop: CGRect) -> some View {
        Canvas { context, size in
            let full = Path(CGRect(origin: .zero, size: size))
            context.fill(full, with: .color(.black.opacity(0.22)))
            context.stroke(full, with: .color(.white.opacity(0.65)), lineWidth: 1)
            let visible = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                                 width: crop.width * size.width, height: crop.height * size.height)
            context.stroke(Path(visible), with: .color(Color(red: 1, green: 212.0 / 255, blue: 91.0 / 255)), lineWidth: 1.8)
        }
        .accessibilityIdentifier("remote-viewport-navigator")
    }
}

/// RemoteLutImage's ContentScale.Fit followed by its horizontal graphics scale.
/// Keep the encoded image's intrinsic aspect until after it has been fitted.
struct RemoteViewfinderImage: View {
    let image: UIImage
    let aspect: CGFloat
    let multiplier: CGFloat
    let size: CGSize

    var body: some View {
        let fitted = RemoteFramingGrid.fit(width: Float(size.width), height: Float(size.height), aspect: Float(aspect))
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: CGFloat(fitted.width), height: CGFloat(fitted.height))
            .scaleEffect(x: multiplier, y: 1, anchor: .center)
            .frame(width: size.width, height: size.height)
    }
}
