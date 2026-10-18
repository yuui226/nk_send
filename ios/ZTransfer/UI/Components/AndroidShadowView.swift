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
    }
}

/// Compare the actual displayed ancestor chain once per frame, shared by all
/// shadows. Stable hosts can skip coordinate conversion; moving hosts still use
/// CALayer.convert and the existing renderer, at the original display cadence.
/// Only weak model identities and value snapshots survive the frame boundary.
@MainActor
final class AndroidShadowGeometryCache {
    struct WindowGeometry: Equatable {
        let density: CGFloat
        let screenSize: CGSize
        let origin: CGPoint
        @MainActor init(_ window: UIWindow) {
            density = window.screen.scale
            screenSize = window.screen.bounds.size
            origin = window.convert(.zero, to: window.screen.coordinateSpace)
        }
    }
    struct WindowFrame {
        let geometry: WindowGeometry
        let presentation: CALayer?
    }
    private struct Key: Hashable {
        let model: ObjectIdentifier
        let presentation: Bool
    }
    private struct Signature: Equatable {
        let parent: ObjectIdentifier?
        let bounds: CGRect
        let position, anchor: CGPoint
        let z, anchorZ: CGFloat
        let transform, sublayerTransform: CATransform3D
        let hidden, flipped: Bool

        init(_ layer: CALayer) {
            parent = layer.superlayer.map { ObjectIdentifier($0.model()) }
            bounds = layer.bounds; position = layer.position; anchor = layer.anchorPoint
            z = layer.zPosition; anchorZ = layer.anchorPointZ
            transform = layer.transform; sublayerTransform = layer.sublayerTransform
            hidden = layer.isHidden; flipped = layer.isGeometryFlipped
        }
        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.parent == rhs.parent && lhs.bounds == rhs.bounds && lhs.position == rhs.position
                && lhs.anchor == rhs.anchor && lhs.z == rhs.z && lhs.anchorZ == rhs.anchorZ
                && lhs.hidden == rhs.hidden && lhs.flipped == rhs.flipped
                && CATransform3DEqualToTransform(lhs.transform, rhs.transform)
                && CATransform3DEqualToTransform(lhs.sublayerTransform, rhs.sublayerTransform)
        }
    }
    private struct Entry {
        weak var model: CALayer?
        let signature: Signature
        let changed: Bool
    }
    private var previous: [Key: Entry] = [:]
    private var current: [Key: Entry] = [:]
    private var windows: [ObjectIdentifier: WindowFrame] = [:]
    var sampledLayerCount: Int { current.count }
    var sampledWindowCount: Int { windows.count }

    func beginFrame() {
        swap(&previous, &current)
        current.removeAll(keepingCapacity: true)
        windows.removeAll(keepingCapacity: true)
    }
    func endFrame() { windows.removeAll(keepingCapacity: true) }
    func clear() { previous.removeAll(); current.removeAll(); windows.removeAll() }

    func window(_ window: UIWindow) -> WindowFrame {
        let key = ObjectIdentifier(window)
        if let cached = windows[key] { return cached }
        let result = WindowFrame(geometry: WindowGeometry(window), presentation: window.layer.presentation())
        windows[key] = result
        return result
    }

    func changed(_ source: CALayer, relativeTo target: CALayer, presentation: Bool) -> Bool {
        let model = source.model()
        let key = Key(model: ObjectIdentifier(model), presentation: presentation)
        if let cached = current[key], cached.model === model { return cached.changed }
        let signature = Signature(source)
        let old = previous[key]
        let ownChange = old?.model !== model || old?.signature != signature
        // Follow the displayed tree, not the model tree: reparenting can leave
        // the previous parent in the presentation tree until the next commit.
        let parentChange: Bool
        if model === target.model() { parentChange = false }
        else if let parent = source.superlayer {
            parentChange = changed(parent, relativeTo: target, presentation: presentation)
        } else { parentChange = false }
        let result = ownChange || parentChange
        current[key] = Entry(model: model, signature: signature, changed: result)
        return result
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
    private let geometry = AndroidShadowGeometryCache()

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
        if hosts.allObjects.isEmpty { link?.invalidate(); link = nil; geometry.clear() }
    }

    @objc private func frame() {
        geometry.beginFrame()
        for host in hosts.allObjects { host.refreshShadow(frame: geometry) }
        geometry.endFrame()
        stopIfEmpty()
    }
}

@MainActor
final class AndroidShadowHost: UIView, @preconcurrency MTKViewDelegate {
    var cornerRadius: CGFloat = 0 { didSet { if cornerRadius != oldValue { setNeedsLayout() } } }
    var elevation: CGFloat = 0 { didSet { if elevation != oldValue { setNeedsLayout() } } }
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
    private struct ValidatedInputs: Equatable {
        let window: AndroidShadowGeometryCache.WindowGeometry
        let radius, elevation: CGFloat
    }
    private var validatedInputs: ValidatedInputs?
    private var needsFrameValidation = true
    private var scene: Scene?
    private(set) var renderingError: Error?
    #if DEBUG
    private(set) var geometryEvaluationCount = 0
    #endif

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
        validatedInputs = nil
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

    fileprivate func refreshShadow(frame: AndroidShadowGeometryCache) {
        guard let window, metalView != nil else { return }
        let windowFrame = frame.window(window)
        let displayed = layer.presentation()
        let presentation = displayed != nil && windowFrame.presentation != nil
        let source = presentation ? displayed! : layer
        let target = presentation ? windowFrame.presentation! : window.layer
        let changed = frame.changed(source, relativeTo: target, presentation: presentation)
        let metrics = windowFrame.geometry
        let inputs = ValidatedInputs(window: metrics, radius: cornerRadius, elevation: elevation)
        // Hidden/empty hosts have no rendered geometry but can still be idle.
        // Any displayed ancestor/configuration change revalidates them, while
        // renderer failures retain their existing retry path.
        if !needsFrameValidation, !changed, renderingError == nil, validatedInputs == inputs { return }
        refreshShadow(source: source, target: target, metrics: metrics)
        validatedInputs = inputs
        needsFrameValidation = false
    }

    private func refreshShadow(usePresentation: Bool) {
        guard let window, metalView != nil else { return }
        // A synchronous layout may have drawn model geometry ahead of the
        // presentation commit; the next display frame must validate it once.
        needsFrameValidation = true
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
        refreshShadow(source: source, target: target, metrics: .init(window))
    }

    private func refreshShadow(source: CALayer, target: CALayer,
                               metrics: AndroidShadowGeometryCache.WindowGeometry) {
        guard let metalView else { return }
        #if DEBUG
        geometryEvaluationCount += 1
        #endif
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
        let density = metrics.density
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
        let windowOrigin = metrics.origin
        let screenSize = metrics.screenSize
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
