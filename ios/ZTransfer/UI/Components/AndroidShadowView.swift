import SwiftUI
import MetalKit

/// Window-positioned Android shadow with analytic and general affine paths.
/// Parent opacity applies to content and this shadow together (AnimatedVisibility).
struct AndroidShadowView: UIViewRepresentable {
    let cornerRadius: CGFloat
    let elevation: CGFloat

    func makeUIView(context: Context) -> AndroidShadowHost { AndroidShadowHost() }
    func updateUIView(_ view: AndroidShadowHost, context: Context) {
        view.cornerRadius = cornerRadius
        view.elevation = elevation
        view.setNeedsLayout()
    }
}

@MainActor
private final class AndroidShadowResources {
    static let shared = Result { try AndroidShadowResources() }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let renderer: ZTransferAndroidShadowRenderer
    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ZTransferAndroidShadowRenderer.Failure.unavailable
        }
        self.device = device
        self.queue = queue
        renderer = try ZTransferAndroidShadowRenderer(device: device)
    }
}

/// One clock for all mounted shadows. Weak membership cannot keep a removed
/// view alive; unchanged geometry does not rebuild meshes or submit GPU work.
@MainActor
private final class AndroidShadowFrameClock: NSObject {
    static let shared = AndroidShadowFrameClock()
    private let hosts = NSHashTable<AndroidShadowHost>.weakObjects()
    private var link: CADisplayLink?

    func add(_ host: AndroidShadowHost) {
        hosts.add(host)
        guard link == nil else { return }
        let next = CADisplayLink(target: self, selector: #selector(frame))
        link = next
        next.add(to: .main, forMode: .common)
    }

    func remove(_ host: AndroidShadowHost) {
        hosts.remove(host)
        stopIfEmpty()
    }

    private func stopIfEmpty() {
        if hosts.allObjects.isEmpty { link?.invalidate(); link = nil }
    }

    @objc private func frame() {
        for host in hosts.allObjects { host.refreshShadow(usePresentation: true) }
        stopIfEmpty()
    }
}

@MainActor
final class AndroidShadowHost: UIView, @preconcurrency MTKViewDelegate {
    var cornerRadius: CGFloat = 0
    var elevation: CGFloat = 0
    private var metalView: MTKView?
    private var resources: AndroidShadowResources?
    private enum Scene {
        case analytic(ZTransferAndroidShadowRenderer.Scene)
        case resolved(ZTransferAndroidShadowRenderer.ResolvedScene)
        var origin: SIMD2<Float> {
            switch self { case .analytic(let scene): scene.origin; case .resolved(let scene): scene.origin }
        }
        var size: SIMD2<Int> {
            switch self { case .analytic(let scene): scene.size; case .resolved(let scene): scene.size }
        }
    }
    private struct Geometry: Equatable {
        let bounds: CGRect
        let origin: CGPoint
        let basisX, basisY: SIMD2<Float>
        let density: CGFloat
        let screenSize: CGSize
        let windowOrigin: CGPoint
        let radius, elevation: CGFloat
    }
    private var renderedGeometry: Geometry?
    private var scene: Scene?
    private(set) var renderingError: Error?

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = false
        do {
            let resources = try AndroidShadowResources.shared.get()
            self.resources = resources
            let view = MTKView(frame: .zero, device: resources.device)
            view.isOpaque = false
            view.backgroundColor = .clear
            view.clearColor = MTLClearColorMake(0, 0, 0, 0)
            view.colorPixelFormat = .bgra8Unorm
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.autoResizeDrawable = false
            view.isUserInteractionEnabled = false
            view.delegate = self
            addSubview(view)
            metalView = view
        } catch { renderingError = error }
    }
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        renderedGeometry = nil
        if window == nil {
            AndroidShadowFrameClock.shared.remove(self)
            scene = nil
            metalView?.isHidden = true
        } else {
            AndroidShadowFrameClock.shared.add(self)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var current: CALayer? = layer
        while let candidate = current {
            if !(candidate.animationKeys() ?? []).isEmpty {
                refreshShadow(usePresentation: true)
                return
            }
            current = candidate.superlayer
        }
        refreshShadow(usePresentation: false)
    }

    fileprivate func refreshShadow(usePresentation: Bool) {
        guard let window, let metalView else { return }
        // Always use one tree for conversion. A newly mounted view may not have
        // a presentation counterpart until its first Core Animation commit.
        let displayedLayer = usePresentation ? layer.presentation() : nil
        let displayedWindow = usePresentation ? window.layer.presentation() : nil
        let source: CALayer
        let target: CALayer
        if let displayedLayer, let displayedWindow {
            source = displayedLayer
            target = displayedWindow
        } else {
            source = layer
            target = window.layer
        }
        let bounds = source.bounds
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            renderedGeometry = nil
            scene = nil
            metalView.isHidden = true
            return
        }
        // The texture placement below is affine. Never approximate an ancestor's
        // perspective transform with three sampled points.
        var ancestor: CALayer? = source
        while let current = ancestor {
            guard CATransform3DIsAffine(current.transform), CATransform3DIsAffine(current.sublayerTransform) else {
                renderedGeometry = nil
                renderingError = ZTransferAndroidShadowRenderer.Failure.invalidMesh
                scene = nil
                metalView.isHidden = true
                return
            }
            if current.isHidden {
                renderedGeometry = nil
                scene = nil
                metalView.isHidden = true
                return
            }
            if current === target { break }
            ancestor = current.superlayer
        }
        guard CATransform3DIsIdentity(source.sublayerTransform) else {
            renderedGeometry = nil
            renderingError = ZTransferAndroidShadowRenderer.Failure.invalidMesh
            scene = nil
            metalView.isHidden = true
            return
        }
        let density = window.screen.scale
        let origin = source.convert(bounds.origin, to: target)
        // Sampling the complete bounds avoids losing basis precision by
        // subtracting almost equal window coordinates one point apart.
        let xAxis = source.convert(CGPoint(x: bounds.maxX, y: bounds.minY), to: target)
        let yAxis = source.convert(CGPoint(x: bounds.minX, y: bounds.maxY), to: target)
        let basisX = SIMD2<Float>(Float((xAxis.x - origin.x) / bounds.width),
                                 Float((xAxis.y - origin.y) / bounds.width))
        let basisY = SIMD2<Float>(Float((yAxis.x - origin.x) / bounds.height),
                                 Float((yAxis.y - origin.y) / bounds.height))
        let determinant = basisX.x * basisY.y - basisX.y * basisY.x
        guard basisX.x.isFinite, basisX.y.isFinite, basisY.x.isFinite, basisY.y.isFinite,
              determinant.isFinite, determinant != 0 else {
            renderedGeometry = nil
            renderingError = ZTransferAndroidShadowRenderer.Failure.invalidMesh
            scene = nil
            metalView.isHidden = true
            return
        }
        let windowOrigin = window.convert(CGPoint.zero, to: window.screen.coordinateSpace)
        let screenSize = window.screen.bounds.size
        let geometry = Geometry(bounds: bounds, origin: origin, basisX: basisX, basisY: basisY,
                                density: density, screenSize: screenSize, windowOrigin: windowOrigin,
                                radius: cornerRadius, elevation: elevation)
        guard geometry != renderedGeometry else { return }
        // Texture placement follows the sampled geometry directly, without
        // inheriting a second implicit Core Animation interpolation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        typealias Metrics = ZTransferAndroidShadowMetrics
        guard let lighting = Metrics.materialLighting(
            displayPixels: .init(Float(screenSize.width * density), Float(screenSize.height * density)),
            density: Float(density),
            windowOriginPixels: .init(Float(windowOrigin.x * density), Float(windowOrigin.y * density))) else { return }
        do {
            let radius = min(cornerRadius, min(bounds.width, bounds.height) * 0.5)
            let caster = Metrics.Caster(minimum: .zero,
                maximum: .init(Float(bounds.width * density), Float(bounds.height * density)), radius: Float(radius * density))
            let translation = SIMD2<Float>(Float(origin.x * density), Float(origin.y * density))
            let transform = ZTransferShadowTransform(x: .init(basisX.x, basisY.x, translation.x),
                y: .init(basisX.y, basisY.y, translation.y), perspective: .init(0, 0, 1))
            if transform.supportsAnalyticShadow {
                scene = try ZTransferAndroidShadowRenderer.scene(caster: caster, elevation: Float(elevation * density),
                    lighting: lighting, transform: transform).map(Scene.analytic)
            } else {
                let preparation = try ZTransferAndroidShadowRenderer.tessellatedScene(caster: caster,
                    elevation: Float(elevation * density), lighting: lighting, transform: transform)
                scene = try ZTransferAndroidShadowRenderer.resolve(preparation, caster: caster).map(Scene.resolved)
            }
            renderedGeometry = geometry
            guard let scene else { renderingError = nil; metalView.isHidden = true; return }
            metalView.isHidden = false
            // Counter-transform the texture so its texels remain aligned with
            // window pixels. Setting frame while rotated would be undefined.
            let inverseBasis = CGAffineTransform(a: CGFloat(basisX.x), b: CGFloat(basisX.y),
                                                 c: CGFloat(basisY.x), d: CGFloat(basisY.y),
                                                 tx: 0, ty: 0).inverted()
            metalView.bounds = CGRect(x: 0, y: 0, width: CGFloat(scene.size.x) / density,
                                      height: CGFloat(scene.size.y) / density)
            metalView.transform = inverseBasis
            let centerInWindow = CGPoint(x: (CGFloat(scene.origin.x) + CGFloat(scene.size.x) * 0.5) / density,
                                         y: (CGFloat(scene.origin.y) + CGFloat(scene.size.y) * 0.5) / density)
            let localCenter = CGPoint(x: centerInWindow.x - origin.x,
                                      y: centerInWindow.y - origin.y).applying(inverseBasis)
            metalView.center = CGPoint(x: localCenter.x + bounds.minX, y: localCenter.y + bounds.minY)
            metalView.drawableSize = CGSize(width: scene.size.x, height: scene.size.y)
            renderingError = nil
            metalView.setNeedsDisplay()
        } catch {
            renderedGeometry = nil
            renderingError = error
            scene = nil
            metalView.isHidden = true
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let resources, let scene, !view.isHidden,
              let drawable = view.currentDrawable, let command = resources.queue.makeCommandBuffer() else { return }
        do {
            switch scene {
            case .analytic(let scene):
                try resources.renderer.encode(layers: scene.layers, destination: drawable.texture, commandBuffer: command)
            case .resolved(let scene):
                try resources.renderer.encodeResolved(scene: scene, destination: drawable.texture, commandBuffer: command)
            }
            command.present(drawable)
            command.commit()
        } catch { renderingError = error }
    }
}
