import SwiftUI
import MetalKit
import CoreGraphics

struct RemoteLUTMetalView: UIViewRepresentable {
    let image: CGImage
    let lut: CubeLUT

    func makeCoordinator() -> Coordinator { Coordinator(image: image, lut: lut) }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false; view.isPaused = true; view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm; view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) { context.coordinator.image = image; context.coordinator.lut = lut; view.setNeedsDisplay() }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice; let commandQueue: MTLCommandQueue; let renderer: RemoteLUTMetalRenderer
        var image: CGImage; var lut: CubeLUT
        init(image: CGImage, lut: CubeLUT) {
            self.image = image; self.lut = lut
            let selected = MTLCreateSystemDefaultDevice() ?? MTLCreateSystemDefaultDevice()!
            device = selected; commandQueue = selected.makeCommandQueue()!
            renderer = try! RemoteLUTMetalRenderer(device: selected)
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable, let buffer = commandQueue.makeCommandBuffer() else { return }
            do { try renderer.setLUT(lut); try renderer.encode(image: image, into: drawable.texture, commandBuffer: buffer); buffer.present(drawable); buffer.commit() } catch { }
        }
    }
}
