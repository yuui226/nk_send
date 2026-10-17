import SwiftUI
import MetalKit
import CoreGraphics

/// Candidate surfaces render underneath the last confirmed layer (or source image).
/// Keeping the same ForEach identity when promoting a candidate retains its drawable.
struct RemoteLUTImage<Source: View>: View {
    let image: CGImage
    @ObservedObject var monitor: RemoteLUTMonitorState
    let source: Source
    @State private var displayed: Set<RemoteLUTLayer.ID> = []

    var body: some View {
        ZStack {
            ForEach([monitor.candidate, monitor.active].compactMap { $0 }) { layer in
                RemoteLUTMetalView(image: image, lut: layer.lut, onPresented: {
                    displayed.insert(layer.id)
                    monitor.presented(layer)
                }, onUnavailable: { displayed.remove(layer.id) }, onFailure: { reason in
                    displayed.remove(layer.id)
                    monitor.renderFailed(layer, reason: reason)
                })
                .onDisappear { displayed.remove(layer.id) }
            }
            if monitor.active.map({ !displayed.contains($0.id) }) ?? true {
                source
            }
        }
    }
}

struct RemoteLUTMetalView: UIViewRepresentable {
    let image: CGImage
    let lut: CubeLUT
    let onPresented: @MainActor () -> Void
    let onUnavailable: @MainActor () -> Void
    let onFailure: @MainActor (RemoteLUTRenderFailure) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image, lut: lut, onPresented: onPresented, onUnavailable: onUnavailable, onFailure: onFailure)
    }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.image = image
        context.coordinator.onPresented = onPresented
        context.coordinator.onUnavailable = onUnavailable
        context.coordinator.onFailure = onFailure
        view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.disposed = true
        view.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency MTKViewDelegate {
        let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private let renderer: RemoteLUTMetalRenderer?
        var image: CGImage
        let lut: CubeLUT
        var onPresented: @MainActor () -> Void
        var onUnavailable: @MainActor () -> Void
        var onFailure: @MainActor (RemoteLUTRenderFailure) -> Void
        var disposed = false
        private var failed = false
        private var presentation = RemoteLUTPresentationGate()

        init(image: CGImage, lut: CubeLUT, onPresented: @escaping @MainActor () -> Void,
             onUnavailable: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor (RemoteLUTRenderFailure) -> Void) {
            self.image = image
            self.lut = lut
            self.onPresented = onPresented
            self.onUnavailable = onUnavailable
            self.onFailure = onFailure
            let selected = MTLCreateSystemDefaultDevice()
            device = selected
            commandQueue = selected?.makeCommandQueue()
            renderer = selected.flatMap { try? RemoteLUTMetalRenderer(device: $0) }
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            unavailable()
        }
        func draw(in view: MTKView) {
            guard !disposed, !failed, !presentation.inFlight else { return }
            guard let commandQueue, let renderer else { fail(.gpu); return }
            guard let drawable = view.currentDrawable else { unavailable(); return }
            guard let buffer = commandQueue.makeCommandBuffer() else { fail(.gpu); return }
            do {
                try renderer.setLUT(lut)
                try renderer.encode(image: image, into: drawable.texture, commandBuffer: buffer)
                guard let frame = presentation.begin() else { return }
                #if !targetEnvironment(simulator)
                drawable.addPresentedHandler { [weak self] _ in
                    Task { @MainActor in
                        guard let self, !self.disposed, !self.failed, self.presentation.accepts(frame) else { return }
                        if self.presentation.present(frame) { self.onPresented() }
                    }
                }
                #endif
                buffer.addCompletedHandler { [weak self] command in
                    let succeeded = command.status == .completed
                    Task { @MainActor in
                        guard let self, !self.disposed, !self.failed, self.presentation.accepts(frame) else { return }
                        guard succeeded else { self.fail(.gpu); return }
                        var ready = self.presentation.complete(frame)
                        #if targetEnvironment(simulator)
                        // Simulator Metal omits MTLDrawable's presentation callback.
                        // This fallback proves submission only, never device presentation.
                        ready = self.presentation.present(frame) || ready
                        #endif
                        if ready { self.onPresented() }
                    }
                }
                buffer.present(drawable)
                buffer.commit()
            } catch {
                fail((error as? RemoteLUTMetalRenderer.Failure) == .inputColor ? .inputColor : .gpu)
            }
        }
        private func unavailable() {
            presentation.invalidate()
            Task { @MainActor [weak self] in
                guard let self, !self.disposed else { return }
                guard !self.presentation.isPresented else { return }
                self.onUnavailable()
            }
        }
        private func fail(_ reason: RemoteLUTRenderFailure) {
            guard !failed, !disposed else { return }
            failed = true
            // Avoid publishing SwiftUI state from make/update/draw callbacks.
            Task { @MainActor [weak self] in
                guard let self, !self.disposed else { return }
                self.onFailure(reason)
            }
        }
    }
}
