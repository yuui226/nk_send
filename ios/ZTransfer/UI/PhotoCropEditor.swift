import SwiftUI
import UIKit
import AVFoundation

struct PhotoCropEditor: View {
    let image: UIImage
    let orientation: Int
    @Binding var selection: JpegCropSelection
    @State private var gesture = CropGestureState()
    @State private var lastMagnification: CGFloat = 1
    @State private var lastDragTranslation: CGSize = .zero
    private let ratios: [(String, Int, Int)] = [("自由", 0, 0), ("1:1", 1, 1), ("4:3", 4, 3), ("3:2", 3, 2), ("16:9", 16, 9)]
    var body: some View {
        GeometryReader { proxy in
            let frame = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: proxy.size))
            ZStack {
                Color.black
                Image(uiImage: image).resizable().scaledToFit()
                CropOverlay(bounds: gesture.bounds)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                let dx = Double((value.translation.width - lastDragTranslation.width) / max(frame.width, 1))
                let dy = Double((value.translation.height - lastDragTranslation.height) / max(frame.height, 1))
                lastDragTranslation = value.translation
                gesture.pan(dx: dx, dy: dy)
                selection = gesture.selection(orientation: orientation)
            }.onEnded { _ in lastDragTranslation = .zero }.simultaneously(with: MagnificationGesture().onChanged { value in
                let delta = value / lastMagnification; lastMagnification = value
                gesture.zoom(scale: Double(delta)); selection = gesture.selection(orientation: orientation)
            }.onEnded { _ in lastMagnification = 1 }))
            .onAppear { gesture = CropGestureState(bounds: selection.bounds, ratioWidth: selection.ratioWidth, ratioHeight: selection.ratioHeight) }
            .overlay(alignment: .top) {
                HStack(spacing: 8) {
                    ForEach(ratios, id: \.0) { item in
                        Button(item.0) {
                            if item.1 == 0 { gesture = CropGestureState(bounds: gesture.bounds) }
                            else { gesture.setRatio(width: item.1, height: item.2) }
                            selection = gesture.selection(orientation: orientation)
                        }
                        .font(.caption.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                    }
                }.padding(.top, 12)
            }
        }
    }
}

private struct CropOverlay: View {
    let bounds: CropBounds
    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(x: bounds.left * proxy.size.width, y: bounds.top * proxy.size.height, width: (bounds.right-bounds.left) * proxy.size.width, height: (bounds.bottom-bounds.top) * proxy.size.height)
            Path { path in path.addRect(rect) }.stroke(Color.white, lineWidth: 2)
        }
    }
}
