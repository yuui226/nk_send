// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Metal
import Foundation

/// Encodes the android-15.0.0_r1 GrShadowGeoProc coverage calculation. Owns one
/// pipeline/LUT per renderer; the host owns target textures and command scheduling.
/// Scene preparation assembles HWUI layers; encoding uses target pixel coordinates.
final class ZTransferAndroidShadowRenderer {
    enum Failure: Error { case unavailable, allocation, invalidTarget, invalidMesh }
    struct Layer {
        let mesh: ZTransferAndroidShadowMetrics.RoundedRectMesh
        /// Premultiplied black shadow's already-quantized HWUI alpha.
        let alpha: UInt8
    }
    struct Scene {
        /// Physical pixel origin in the window. Place the resulting texture here.
        let origin: SIMD2<Float>
        let size: SIMD2<Int>
        let layers: [Layer]
    }

    /// Builds a tightly bounded texture scene without changing the physical light
    /// position. Coordinates are rounded outward only after the shadow is projected.
    /// Nil means no visible shadow; unsupported/invalid geometry throws explicitly.
    static func scene(caster: ZTransferAndroidShadowMetrics.Caster, elevation: Float,
                      lighting: ZTransferAndroidShadowMetrics.Lighting,
                      nodeAlpha: Float = 1, outlineAlpha: Float = 1,
                      scale: Float = 1, translation: SIMD2<Float> = .zero,
                      rotation: ZTransferAndroidShadowMetrics.QuarterTurn = .zero, reflected: Bool = false) throws -> Scene? {
        guard scale.isFinite, scale > 0 else { throw Failure.invalidMesh }
        let x = rotation.apply(SIMD2<Float>(reflected ? -scale : scale, 0))
        let y = rotation.apply(SIMD2<Float>(0, scale))
        return try scene(caster: caster, elevation: elevation, lighting: lighting,
            nodeAlpha: nodeAlpha, outlineAlpha: outlineAlpha,
            transform: .init(x: .init(x.x, y.x, translation.x), y: .init(x.y, y.y, translation.y),
                             perspective: .init(0, 0, 1)))
    }

    static func scene(caster: ZTransferAndroidShadowMetrics.Caster, elevation: Float,
                      lighting: ZTransferAndroidShadowMetrics.Lighting,
                      nodeAlpha: Float = 1, outlineAlpha: Float = 1,
                      transform: ZTransferShadowTransform) throws -> Scene? {
        typealias Metrics = ZTransferAndroidShadowMetrics
        guard elevation.isFinite, elevation >= 0,
              let opacity = Metrics.opacity(lighting: lighting, nodeAlpha: nodeAlpha,
                                            outlineAlpha: outlineAlpha) else { throw Failure.invalidMesh }
        guard elevation > 0, opacity.ambient > 0 || opacity.spot > 0 else { return nil }
        guard let geometry = Metrics.shadowGeometry(caster: caster, height: elevation,
            light: lighting.center, lightRadius: lighting.radius, transform: transform,
            transparent: opacity.transparentOccluder) else { throw Failure.invalidMesh }
        var layers: [Layer] = []
        for (shape, alpha) in [(geometry.ambient, opacity.ambient), (geometry.spot, opacity.spot)] where alpha > 0 {
            // ShadowRRectOp::Make rejects nonpositive scaled inset. Its caller
            // skips only that operation and keeps previously submitted layers.
            if shape.insetWidth <= 0 { continue }
            guard let mesh = shape.mesh() else { throw Failure.invalidMesh }
            layers.append(Layer(mesh: mesh, alpha: alpha))
        }
        let positions = layers.flatMap { $0.mesh.vertices.map(\.position) }
        guard let bounds = try textureBounds(positions) else { return nil }
        let origin = bounds.origin
        let local = layers.map { layer in
            let vertices = layer.mesh.vertices.map {
                Metrics.Vertex(position: $0.position - origin, offset: $0.offset,
                               distanceCorrection: $0.distanceCorrection)
            }
            return Layer(mesh: .init(kind: layer.mesh.kind, vertices: vertices, indices: layer.mesh.indices),
                         alpha: layer.alpha)
        }
        return Scene(origin: origin, size: bounds.size, layers: local)
    }

    struct TessellatedVertex {
        let position: SIMD2<Float>
        let alpha: UInt8
    }
    struct TessellatedLayer {
        let vertices: [TessellatedVertex]
        let indices: [UInt16]
        let alpha: UInt8
    }
    enum Component: Hashable { case ambient, spot }
    struct TessellatedScene {
        let origin: SIMD2<Float>
        let size: SIMD2<Int>
        let layers: [TessellatedLayer]
    }
    struct PreparedComponent {
        enum Content {
            /// World-space mesh: crop after including every fallback's bounds.
            case mesh(TessellatedLayer)
            case blur(ZTransferShadowGeometry.BlurFallback)
        }
        let component: Component
        let alpha: UInt8
        let content: Content
    }
    struct TessellatedPreparation {
        /// Legacy mesh-only crop, retained until the host handles the full sequence.
        let scene: TessellatedScene?
        /// Canonical draw order, including successful meshes and pending blurs.
        /// Empty/zero-alpha layers and invalid spot projections are omitted.
        let orderedComponents: [PreparedComponent]
        var blurFallbacks: [Component: ZTransferShadowGeometry.BlurFallback] {
            var result: [Component: ZTransferShadowGeometry.BlurFallback] = [:]
            for layer in orderedComponents {
                if case .blur(let recipe) = layer.content { result[layer.component] = recipe }
            }
            return result
        }
        var failedComponents: Set<Component> { Set(blurFallbacks.keys) }
        /// A failed spot projection skips that component; ambient remains valid.
        let skippedComponents: Set<Component>
    }

    static func tessellatedScene(caster: ZTransferAndroidShadowMetrics.Caster, elevation: Float,
                                 lighting: ZTransferAndroidShadowMetrics.Lighting,
                                 transform: ZTransferShadowTransform,
                                 nodeAlpha: Float = 1, outlineAlpha: Float = 1) throws -> TessellatedPreparation {
        typealias Metrics = ZTransferAndroidShadowMetrics
        guard elevation.isFinite, elevation >= 0,
              let opacity = Metrics.opacity(lighting: lighting, nodeAlpha: nodeAlpha, outlineAlpha: outlineAlpha)
        else { throw Failure.invalidMesh }
        guard elevation > 0, opacity.ambient > 0 || opacity.spot > 0 else {
            return TessellatedPreparation(scene: nil, orderedComponents: [], skippedComponents: [])
        }
        guard let geometry = ZTransferShadowGeometry.roundedRect(minimum: caster.minimum,
            maximum: caster.maximum, radii: .init(repeating: caster.radius), transform: transform,
            heightPlane: .init(0, 0, elevation), light: lighting.center, lightRadius: lighting.radius,
            transparent: opacity.transparentOccluder) else { throw Failure.invalidMesh }
        var layers: [TessellatedLayer] = []
        var ordered: [PreparedComponent] = []
        var skipped: Set<Component> = []
        for (component, mesh, alpha) in [(Component.ambient, geometry.ambient, opacity.ambient),
                                         (.spot, geometry.spot, opacity.spot)] where alpha > 0 {
            guard let mesh else {
                switch component {
                case .ambient:
                    guard let fallback = ZTransferShadowGeometry.ambientFallback(transform: transform, height: elevation)
                    else { throw Failure.invalidMesh }
                    ordered.append(.init(component: component, alpha: alpha, content: .blur(fallback)))
                case .spot:
                    if let fallback = ZTransferShadowGeometry.spotFallback(minimum: caster.minimum,
                        maximum: caster.maximum, transform: transform, heightPlane: .init(0, 0, elevation),
                        light: lighting.center, lightRadius: lighting.radius) {
                        ordered.append(.init(component: component, alpha: alpha, content: .blur(fallback)))
                    } else {
                        skipped.insert(component)
                    }
                }
                continue
            }
            if mesh.points.isEmpty { continue }
            let vertices = zip(mesh.points, mesh.alphas).map { TessellatedVertex(position: $0.0, alpha: $0.1) }
            let layer = TessellatedLayer(vertices: vertices, indices: mesh.indices, alpha: alpha)
            layers.append(layer)
            ordered.append(.init(component: component, alpha: alpha, content: .mesh(layer)))
        }
        guard let bounds = try textureBounds(layers.flatMap { $0.vertices.map(\.position) }) else {
            return TessellatedPreparation(scene: nil, orderedComponents: ordered, skippedComponents: skipped)
        }
        let local = layers.map { layer in
            TessellatedLayer(vertices: layer.vertices.map {
                TessellatedVertex(position: $0.position - bounds.origin, alpha: $0.alpha)
            }, indices: layer.indices, alpha: layer.alpha)
        }
        return TessellatedPreparation(scene: .init(origin: bounds.origin, size: bounds.size, layers: local),
                                      orderedComponents: ordered, skippedComponents: skipped)
    }
    struct ResolvedLayer {
        enum Content {
            case mesh(TessellatedLayer)
            case rectangle(BlurredRectangleLayer)
            case filledRectangle(FilledRectangleLayer)
            case circle(BlurredCircleLayer)
            case roundedRectangle(ZTransferShadowBlur.RoundedRectanglePlan, UInt8)
            case filledRoundedRectangle(FilledRoundedRectangleLayer)
            case filledCircle(FilledCircleLayer)
            case coverage(CoverageLayer)
        }
        let component: Component
        let content: Content
    }
    struct ResolvedScene {
        let origin: SIMD2<Float>
        let size: SIMD2<Int>
        let layers: [ResolvedLayer]
    }

    /// Resolve every component before cropping or publishing a scene. Unsupported
    /// fallback shapes remain explicit failures, never silently missing layers.
    static func resolve(_ preparation: TessellatedPreparation,
                        caster: ZTransferAndroidShadowMetrics.Caster) throws -> ResolvedScene? {
        var layers: [ResolvedLayer] = []
        var positions: [SIMD2<Float>] = []
        for item in preparation.orderedComponents where item.alpha > 0 {
            switch item.content {
            case .mesh(let mesh):
                positions.append(contentsOf: mesh.vertices.map(\.position))
                layers.append(.init(component: item.component, content: .mesh(mesh)))
            case .blur(let recipe):
                if let circle = recipe.identityCircle(caster: caster) {
                    positions.append(contentsOf: ZTransferShadowBlur.coverageCircleVertices(center: circle.center, radius: circle.radius).map { .init($0.x, $0.y) })
                    layers.append(.init(component: item.component, content: .filledCircle(.init(center: circle.center, radius: circle.radius, alpha: item.alpha))))
                    continue
                }
                if let shape = recipe.axisAlignedRoundedRectangle(caster: caster), shape.sigma <= 0.03,
                   shape.radius >= 0.5,
                   !(shape.bounds.z - shape.bounds.x == 2 * shape.radius && shape.bounds.w - shape.bounds.y == 2 * shape.radius) {
                    let vertices = ZTransferShadowBlur.coverageRoundedRectangleVertices(bounds: shape.bounds, radius: shape.radius)
                    positions.append(contentsOf: vertices.map { .init($0.x, $0.y) })
                    layers.append(.init(component: item.component, content: .filledRoundedRectangle(.init(
                        bounds: shape.bounds, radius: shape.radius, alpha: item.alpha))))
                    continue
                }
                if let circle = recipe.axisAlignedCircle(caster: caster) ?? recipe.rotatedBlurredCircle(caster: caster) {
                    let extent = circle.radius + 3 * circle.sigma
                    positions.append(contentsOf: circle.proxy ?? [circle.center - SIMD2(repeating: extent), circle.center + SIMD2(repeating: extent)])
                    layers.append(.init(component: item.component, content: .circle(.init(
                        center: circle.center, radius: circle.radius, sigma: circle.sigma, alpha: item.alpha, proxy: circle.proxy))))
                    continue
                }
                if let plan = recipe.roundedRectanglePlan(caster: caster) {
                    let draw = plan.drawRectangle
                    positions.append(.init(draw.x, draw.y))
                    positions.append(.init(draw.z, draw.w))
                    layers.append(.init(component: item.component, content: .roundedRectangle(plan, item.alpha)))
                    continue
                }
                if recipe.axisAlignedRectangle(caster: caster) == nil,
                   let vertices = recipe.rotatedIdentityRectangle(caster: caster) {
                    positions.append(contentsOf: vertices.map { .init($0.x,$0.y) })
                    layers.append(.init(component: item.component, content: .coverage(.init(vertices: vertices,
                        indices: ZTransferShadowBlur.coverageRectangleIndices, alpha: item.alpha))))
                    continue
                }
                if recipe.axisAlignedRectangle(caster: caster) == nil,
                   let rectangle = recipe.rotatedBlurredRectangle(caster: caster) {
                    positions.append(contentsOf: rectangle.proxy)
                    layers.append(.init(component: item.component, content: .rectangle(.init(bounds: rectangle.bounds,
                        sigma: rectangle.sigma, alpha: item.alpha, inverse: rectangle.inverse, proxy: rectangle.proxy))))
                    continue
                }
                guard let rectangle = recipe.axisAlignedRectangle(caster: caster)
                else { throw Failure.invalidMesh }
                let bounds = rectangle.bounds
                if rectangle.sigma <= 0.03 {
                    positions.append(contentsOf: ZTransferShadowBlur.coverageRectangleVertices(bounds).map { .init($0.x, $0.y) })
                    layers.append(.init(component: item.component, content: .filledRectangle(.init(bounds: bounds, alpha: item.alpha))))
                    continue
                }
                let outset = 3 * rectangle.sigma
                positions.append(.init(bounds.x - outset, bounds.y - outset))
                positions.append(.init(bounds.z + outset, bounds.w + outset))
                layers.append(.init(component: item.component, content: .rectangle(.init(
                    bounds: bounds, sigma: rectangle.sigma, alpha: item.alpha))))
            }
        }
        guard let crop = try textureBounds(positions) else { return nil }
        let local = layers.map { layer -> ResolvedLayer in
            switch layer.content {
            case .mesh(let mesh):
                return .init(component: layer.component, content: .mesh(.init(vertices: mesh.vertices.map {
                    .init(position: $0.position - crop.origin, alpha: $0.alpha)
                }, indices: mesh.indices, alpha: mesh.alpha)))
            case .coverage(let mesh):
                return .init(component: layer.component, content: .coverage(.init(vertices: mesh.vertices.map {
                    .init($0.x - crop.origin.x, $0.y - crop.origin.y, $0.z, $0.w)
                }, indices: mesh.indices, alpha: mesh.alpha)))
            case .filledCircle(let circle):
                return .init(component: layer.component, content: .filledCircle(.init(
                    center: circle.center - crop.origin, radius: circle.radius, alpha: circle.alpha)))
            case .filledRoundedRectangle(let shape):
                return .init(component: layer.component, content: .filledRoundedRectangle(.init(
                    bounds: shape.bounds - .init(crop.origin.x, crop.origin.y, crop.origin.x, crop.origin.y),
                    radius: shape.radius, alpha: shape.alpha)))
            case .roundedRectangle(let plan, let alpha):
                return .init(component: layer.component, content: .roundedRectangle(plan.translated(by: -crop.origin), alpha))
            case .circle(let circle):
                return .init(component: layer.component, content: .circle(.init(center: circle.center - crop.origin,
                    radius: circle.radius, sigma: circle.sigma, alpha: circle.alpha, proxy: circle.proxy?.map { $0 - crop.origin })))
            case .filledRectangle(let rectangle):
                let offset = SIMD4(crop.origin.x, crop.origin.y, crop.origin.x, crop.origin.y)
                return .init(component: layer.component, content: .filledRectangle(.init(
                    bounds: rectangle.bounds - offset, alpha: rectangle.alpha)))
            case .rectangle(let rectangle):
                if let inverse = rectangle.inverse {
                    let translated = inverse.map(crop.origin)
                    let localInverse = ZTransferShadowTransform(x: .init(inverse.x.x, inverse.x.y, translated.x),
                        y: .init(inverse.y.x, inverse.y.y, translated.y), perspective: .init(0,0,1))
                    return .init(component: layer.component, content: .rectangle(.init(bounds: rectangle.bounds,
                        sigma: rectangle.sigma, alpha: rectangle.alpha, inverse: localInverse,
                        proxy: rectangle.proxy?.map { $0 - crop.origin })))
                }
                let offset = SIMD4(crop.origin.x, crop.origin.y, crop.origin.x, crop.origin.y)
                return .init(component: layer.component, content: .rectangle(.init(
                    bounds: rectangle.bounds - offset, sigma: rectangle.sigma, alpha: rectangle.alpha)))
            }
        }
        return ResolvedScene(origin: crop.origin, size: crop.size, layers: local)
    }

    func encodeResolved(scene: ResolvedScene, destination: MTLTexture,
                        commandBuffer: MTLCommandBuffer) throws {
        guard destination.width == scene.size.x, destination.height == scene.size.y else { throw Failure.invalidTarget }
        if scene.layers.isEmpty {
            try encodeTessellated(layers: [], destination: destination, commandBuffer: commandBuffer)
        }
        for (index, layer) in scene.layers.enumerated() {
            switch layer.content {
            case .mesh(let mesh):
                try encodeTessellated(layers: [mesh], destination: destination,
                    preserveContents: index > 0, commandBuffer: commandBuffer)
            case .coverage(let mesh):
                try encodeCoverage(layers: [mesh], destination: destination,
                    preserveContents: index > 0, commandBuffer: commandBuffer)
            case .filledCircle(let circle):
                try encodeFilledCircles(layers: [circle], destination: destination,
                    preserveContents: index > 0, commandBuffer: commandBuffer)
            case .filledRoundedRectangle(let shape):
                try encodeFilledRoundedRectangles(layers: [shape], destination: destination,
                    preserveContents: index > 0, commandBuffer: commandBuffer)
            case .roundedRectangle(let plan, let alpha):
                let blur: ZTransferShadowBlurRenderer
                if let cached = maskRenderer { blur = cached }
                else {
                    blur = try ZTransferShadowBlurRenderer(device: device)
                    maskRenderer = blur
                }
                let mask = try blur.roundedRectangleMask(plan: plan,
                    maximumSurfaceBytes: 16 * 1024 * 1024, commandBuffer: commandBuffer)
                try encodeRoundedRectangleMasks(layers: [.init(plan: plan, mask: mask, alpha: alpha)],
                    destination: destination, preserveContents: index > 0, commandBuffer: commandBuffer)
            case .circle(let circle):
                try encodeBlurredCircles(layers: [circle], destination: destination,
                    preserveContents: index > 0, commandBuffer: commandBuffer)
            case .filledRectangle(let rectangle):
                try encodeFilledRectangles(layers: [rectangle], destination: destination,
                    preserveContents: index > 0, commandBuffer: commandBuffer)
            case .rectangle(let rectangle):
                try encodeBlurredRectangles(layers: [rectangle], destination: destination,
                    preserveContents: index > 0, commandBuffer: commandBuffer)
            }
        }
    }

    /// Shared by analytic and tessellated paths; crop only after projection.
    private static func textureBounds(_ positions: [SIMD2<Float>]) throws -> (origin: SIMD2<Float>, size: SIMD2<Int>)? {
        guard let first = positions.first else { return nil }
        var low = first
        var high = first
        for point in positions {
            guard point.x.isFinite, point.y.isFinite else { throw Failure.invalidMesh }
            low = .init(min(low.x, point.x), min(low.y, point.y))
            high = .init(max(high.x, point.x), max(high.y, point.y))
        }
        let origin = SIMD2<Float>(floor(low.x), floor(low.y))
        let extent = SIMD2<Float>(ceil(high.x) - origin.x, ceil(high.y) - origin.y)
        guard extent.x > 0, extent.y > 0,
              extent.x < Float(Int.max), extent.y < Float(Int.max) else { throw Failure.invalidMesh }
        return (origin, .init(Int(extent.x), Int(extent.y)))
    }

    private struct PackedLayer {
        let vertices: [SIMD4<Float>]
        let indices: [UInt16]
        let alpha: UInt8
        var coverageRadius: Float = 0
    }

    private var maskRenderer: ZTransferShadowBlurRenderer?
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let roundedRectangleBlurPipeline: MTLRenderPipelineState
    private let circleBlurPipeline: MTLRenderPipelineState
    private let rectangleBlurPipeline: MTLRenderPipelineState
    private let maskPipeline: MTLRenderPipelineState
    private let tessellatedPipeline: MTLRenderPipelineState
    private let rectangleCoveragePipeline: MTLRenderPipelineState
    private let roundedCoveragePipeline: MTLRenderPipelineState
    private let falloff: MTLTexture
    // Renderer instances are used by one host's serial draw scheduling. Retain at
    // most 64 immutable 512-byte profiles; in-flight commands retain their textures.
    private var circleProfiles: [Int: MTLTexture] = [:]
    // Effective sigma <= 128 gives seven possible widths, 4064 texels total.
    private var integralProfiles: [Int: MTLTexture] = [:]
    private var circleProfileRecency: [Int] = []
    private static let circleProfileCapacity = 64

    init(device: MTLDevice) throws {
        self.device = device
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.shader, options: options)
        guard let vertex = library.makeFunction(name: "shadowVertex"),
              let fragment = library.makeFunction(name: "shadowFragment") else { throw Failure.unavailable }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let gaussian = library.makeFunction(name: "tessellatedShadowFragment") else { throw Failure.unavailable }
        descriptor.fragmentFunction = gaussian
        tessellatedPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name: "rectangleCoverageVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "rectangleCoverageFragment")
        rectangleCoveragePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name: "roundedCoverageVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "roundedCoverageFragment")
        roundedCoveragePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let maskVertex = library.makeFunction(name: "maskVertex"),
              let maskFragment = library.makeFunction(name: "maskFragment") else { throw Failure.unavailable }
        descriptor.vertexFunction = maskVertex
        descriptor.fragmentFunction = maskFragment
        maskPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name: "profileVertex")
        guard let rectangleBlur = library.makeFunction(name: "rectangleBlurFragment") else { throw Failure.unavailable }
        descriptor.fragmentFunction = rectangleBlur
        rectangleBlurPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let circleBlur = library.makeFunction(name: "circleBlurFragment") else { throw Failure.unavailable }
        descriptor.fragmentFunction = circleBlur
        circleBlurPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let roundedRectangle = library.makeFunction(name: "roundedRectangleBlurFragment") else { throw Failure.unavailable }
        descriptor.fragmentFunction = roundedRectangle
        roundedRectangleBlurPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 128, height: 1, mipmapped: false)
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { throw Failure.allocation }
        ZTransferAndroidShadowMetrics.falloff.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, 128, 1), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: 128)
        }
        falloff = texture
    }

    /// Draws ambient/spot in supplied order; clears unless continuing an existing target.
    /// Does not wait for the GPU or read pixels on the UI thread.
    func encode(layers: [Layer], destination: MTLTexture, preserveContents: Bool = false,
                commandBuffer: MTLCommandBuffer) throws {
        let packed = layers.map { layer in
            var vertices: [SIMD4<Float>] = []
            vertices.reserveCapacity(layer.mesh.vertices.count * 2)
            for v in layer.mesh.vertices {
                vertices.append(.init(v.position.x, v.position.y, v.offset.x, v.offset.y))
                vertices.append(.init(v.distanceCorrection, 0, 0, 0))
            }
            return PackedLayer(vertices: vertices, indices: layer.mesh.indices, alpha: layer.alpha)
        }
        try encode(packed: packed, pipeline: pipeline, destination: destination, preserveContents: preserveContents, commandBuffer: commandBuffer)
    }

    /// SkShadowTessellator vertex alpha followed by GrFragmentProcessors' Gaussian
    /// color filter. This is distinct from the analytic round-rect LUT shader.
    func encodeTessellated(layers: [TessellatedLayer], destination: MTLTexture, preserveContents: Bool = false,
                          commandBuffer: MTLCommandBuffer) throws {
        let packed = layers.map { layer in
            var vertices: [SIMD4<Float>] = []
            vertices.reserveCapacity(layer.vertices.count * 2)
            for v in layer.vertices {
                vertices.append(.init(v.position.x, v.position.y, 0, 0))
                vertices.append(.init(Float(v.alpha) / 255, 0, 0, 0))
            }
            return PackedLayer(vertices: vertices, indices: layer.indices, alpha: layer.alpha)
        }
        try encode(packed: packed, pipeline: tessellatedPipeline, destination: destination,
                   preserveContents: preserveContents, commandBuffer: commandBuffer)
    }

    struct CoverageLayer {
        /// Position in xy, linear coverage in z (distinct from Gaussian mesh alpha).
        let vertices: [SIMD4<Float>]
        let indices: [UInt16]
        let alpha: UInt8
    }

    func encodeCoverage(layers: [CoverageLayer], destination: MTLTexture,
                        preserveContents: Bool = false, commandBuffer: MTLCommandBuffer) throws {
        let packed = layers.map { layer in PackedLayer(vertices: layer.vertices.flatMap { [$0, SIMD4<Float>.zero] },
            indices: layer.indices, alpha: layer.alpha) }
        try encode(packed: packed, pipeline: rectangleCoveragePipeline, destination: destination,
            preserveContents: preserveContents, commandBuffer: commandBuffer)
    }

    struct FilledCircleLayer {
        let center: SIMD2<Float>
        let radius: Float
        let alpha: UInt8
    }

    func encodeFilledCircles(layers: [FilledCircleLayer], destination: MTLTexture,
                            preserveContents: Bool = false, commandBuffer: MTLCommandBuffer) throws {
        let packed = try layers.filter { $0.alpha > 0 }.map { layer -> PackedLayer in
            guard layer.center.x.isFinite, layer.center.y.isFinite, abs(layer.center.x) < 8_000_000,
                  abs(layer.center.y) < 8_000_000, layer.radius.isFinite, layer.radius > 0, layer.radius < 8_000_000
            else { throw Failure.invalidMesh }
            let vertices = ZTransferShadowBlur.coverageCircleVertices(center: layer.center, radius: layer.radius).flatMap { [$0, SIMD4<Float>.zero] }
            return PackedLayer(vertices: vertices, indices: ZTransferShadowBlur.coverageCircleIndices,
                alpha: layer.alpha, coverageRadius: layer.radius + 0.5)
        }
        // CircleGeometryProcessor and CircularRRectOp share the same fill edge
        // equation; retain their different topology and offsets above.
        try encode(packed: packed, pipeline: roundedCoveragePipeline, destination: destination,
            preserveContents: preserveContents, commandBuffer: commandBuffer)
    }

    struct FilledRoundedRectangleLayer {
        let bounds: SIMD4<Float>
        let radius: Float
        let alpha: UInt8
    }

    func encodeFilledRoundedRectangles(layers: [FilledRoundedRectangleLayer], destination: MTLTexture,
                                       preserveContents: Bool = false, commandBuffer: MTLCommandBuffer) throws {
        let packed = try layers.filter { $0.alpha > 0 }.map { layer -> PackedLayer in
            let b = layer.bounds, r = layer.radius
            guard (0..<4).allSatisfy({ b[$0].isFinite && abs(b[$0]) < 8_000_000 }),
                  r.isFinite, r >= 0.5, b.z - b.x >= 2 * r, b.w - b.y >= 2 * r else { throw Failure.invalidMesh }
            let vertices = ZTransferShadowBlur.coverageRoundedRectangleVertices(bounds: b, radius: r).flatMap { [$0, SIMD4<Float>.zero] }
            return PackedLayer(vertices: vertices, indices: ZTransferShadowBlur.coverageRoundedRectangleIndices,
                alpha: layer.alpha, coverageRadius: r + 0.5)
        }
        try encode(packed: packed, pipeline: roundedCoveragePipeline, destination: destination,
            preserveContents: preserveContents, commandBuffer: commandBuffer)
    }

    struct FilledRectangleLayer {
        let bounds: SIMD4<Float>
        let alpha: UInt8
    }

    /// Identity mask filter draws the coverage-AA fill directly into the color
    /// target. Never quantize through an intermediate A8 texture in this route.
    func encodeFilledRectangles(layers: [FilledRectangleLayer], destination: MTLTexture,
                                preserveContents: Bool = false, commandBuffer: MTLCommandBuffer) throws {
        let packed = try layers.filter { $0.alpha > 0 }.map { layer -> PackedLayer in
            guard (0..<4).allSatisfy({ layer.bounds[$0].isFinite && abs(layer.bounds[$0]) < 8_000_000 }),
                  layer.bounds.z > layer.bounds.x, layer.bounds.w > layer.bounds.y else { throw Failure.invalidMesh }
            let vertices = ZTransferShadowBlur.coverageRectangleVertices(layer.bounds).flatMap { [$0, SIMD4<Float>.zero] }
            return PackedLayer(vertices: vertices, indices: ZTransferShadowBlur.coverageRectangleIndices, alpha: layer.alpha)
        }
        try encode(packed: packed, pipeline: rectangleCoveragePipeline, destination: destination,
            preserveContents: preserveContents, commandBuffer: commandBuffer)
    }

    struct BlurredRectangleLayer {
        /// Sorted axis-aligned bounds in destination pixel coordinates.
        let bounds: SIMD4<Float>
        /// Effective sigma; caller applies the mask filter's 128 limit.
        let sigma: Float
        let alpha: UInt8
        var inverse: ZTransferShadowTransform? = nil
        var proxy: [SIMD2<Float>]? = nil
    }

    /// GrBlurUtils::make_rect_blur, axis-aligned device-space case. Coverage
    /// modulates paint directly, without an intermediate A8 quantization.
    func encodeBlurredRectangles(layers: [BlurredRectangleLayer], destination: MTLTexture,
                                 preserveContents: Bool = false, commandBuffer: MTLCommandBuffer) throws {
        guard destination.pixelFormat == .bgra8Unorm, destination.textureType == .type2D,
              destination.sampleCount == 1, destination.usage.contains(.renderTarget) else { throw Failure.invalidTarget }
        var prepared: [(BlurredRectangleLayer, MTLTexture)] = []
        for layer in layers where layer.alpha > 0 {
            guard (0..<4).allSatisfy({ layer.bounds[$0].isFinite && abs(layer.bounds[$0]) < 8_000_000 }),
                  layer.bounds.z > layer.bounds.x, layer.bounds.w > layer.bounds.y else { throw Failure.invalidMesh }
            if let inverse = layer.inverse {
                guard inverse.isFinite, !inverse.hasPerspective, layer.proxy != nil else { throw Failure.invalidMesh }
            }
            prepared.append((layer, try integralProfileTexture(sigma: layer.sigma)))
        }
        let profiles = prepared.map { layer, texture in
            let sixSigma = 6 * layer.sigma, threeSigma = sixSigma / 2
            let inset = layer.bounds + SIMD4(threeSigma, threeSigma, -threeSigma, -threeSigma)
            let outer = layer.bounds + SIMD4(-threeSigma, -threeSigma, threeSigma, threeSigma)
            return ProfileLayer(rectangle: .init(outer.x, outer.y, outer.z - outer.x, outer.w - outer.y),
                uniforms: [inset, .init(Float(texture.width) / sixSigma, Float(layer.alpha) / 255,
                                       inset.x <= inset.z && inset.y <= inset.w ? 1 : 0, layer.inverse == nil ? 0 : 1),
                           .init(layer.inverse?.x.x ?? 1, layer.inverse?.x.y ?? 0, layer.inverse?.x.z ?? 0, 0),
                           .init(layer.inverse?.y.x ?? 0, layer.inverse?.y.y ?? 1, layer.inverse?.y.z ?? 0, 0)],
                texture: texture, quad: layer.proxy)
        }
        try encodeProfiles(profiles, pipeline: rectangleBlurPipeline, destination: destination,
                           preserveContents: preserveContents, commandBuffer: commandBuffer)
    }

    struct BlurredCircleLayer {
        let center: SIMD2<Float>
        let radius: Float
        let sigma: Float
        let alpha: UInt8
        var proxy: [SIMD2<Float>]? = nil
    }

    /// GrBlurUtils::make_circle_blur. The proxy uses original sigma; the profile
    /// retains Skia's quantized ratio and nearest sampling independently.
    func encodeBlurredCircles(layers: [BlurredCircleLayer], destination: MTLTexture,
                              preserveContents: Bool = false, commandBuffer: MTLCommandBuffer) throws {
        var prepared: [ProfileLayer] = []
        for layer in layers where layer.alpha > 0 {
            guard layer.center.x.isFinite, layer.center.y.isFinite,
                  abs(layer.center.x) < 8_000_000, abs(layer.center.y) < 8_000_000,
                  layer.radius < 8_000_000 else { throw Failure.invalidMesh }
            let (profile, texture) = try circleProfileTexture(radius: layer.radius, sigma: layer.sigma)
            let extent = layer.radius + 3 * layer.sigma
            prepared.append(ProfileLayer(rectangle: .init(layer.center.x - extent, layer.center.y - extent, 2 * extent, 2 * extent),
                uniforms: [.init(layer.center.x, layer.center.y, profile.solidRadius, 1 / profile.textureRadius),
                           .init(Float(layer.alpha) / 255, 0, 0, 0)], texture: texture, quad: layer.proxy))
        }
        try encodeProfiles(prepared, pipeline: circleBlurPipeline, destination: destination,
                           preserveContents: preserveContents, commandBuffer: commandBuffer)
    }

    /// make_rect_integral_fp caches by width, never by per-draw sigma/geometry.
    func integralProfileTexture(sigma: Float) throws -> MTLTexture {
        guard let width = ZTransferShadowBlur.integralTableWidth(sigma: sigma) else { throw Failure.invalidMesh }
        if let cached = integralProfiles[width] { return cached }
        guard let pixels = ZTransferShadowBlur.integralTable(sigma: sigma, maximumWorkingBytes: 2048) else { throw Failure.invalidMesh }
        let texture = try makeProfileTexture(pixels)
        integralProfiles[width] = texture
        return texture
    }

    /// Recompute each draw's geometry, but reuse only the quantized profile.
    /// Matches create_profile_effect's key; geometry must never come from cache.
    func circleProfileTexture(radius: Float, sigma: Float) throws -> (ZTransferShadowBlur.CircleProfilePlan, MTLTexture) {
        guard let plan = ZTransferShadowBlur.circleProfilePlan(radius: radius, sigma: sigma) else { throw Failure.invalidMesh }
        let texture: MTLTexture
        if let cached = circleProfiles[plan.key] {
            texture = cached
        } else {
            guard let profile = ZTransferShadowBlur.circleProfile(plan: plan, maximumWorkingBytes: 16384) else { throw Failure.invalidMesh }
            texture = try makeProfileTexture(profile.pixels)
            if circleProfileRecency.count == Self.circleProfileCapacity {
                circleProfiles.removeValue(forKey: circleProfileRecency.removeFirst())
            }
            circleProfiles[plan.key] = texture
        }
        circleProfileRecency.removeAll { $0 == plan.key }
        circleProfileRecency.append(plan.key)
        return (plan, texture)
    }

    struct RoundedRectangleMaskLayer {
        let plan: ZTransferShadowBlur.RoundedRectanglePlan
        /// Already AA-rasterized and Gaussian-filtered exact-size nine-patch mask.
        let mask: MTLTexture
        let alpha: UInt8
    }

    /// make_rrect_blur's nearest nine-patch lookup. Mask radius was rounded up;
    /// shaderCorner deliberately retains the original fractional device radius.
    func encodeRoundedRectangleMasks(layers: [RoundedRectangleMaskLayer], destination: MTLTexture,
                                     preserveContents: Bool = false, commandBuffer: MTLCommandBuffer) throws {
        var profiles: [ProfileLayer] = []
        for layer in layers where layer.alpha > 0 {
            let plan = layer.plan, mask = layer.mask, proxy = plan.proxyRectangle
            guard mask.pixelFormat == .r8Unorm, mask.textureType == .type2D, mask.sampleCount == 1,
                  mask.usage.contains(.shaderRead), mask.width == plan.textureSize.x, mask.height == plan.textureSize.y,
                  plan.blurRadius >= 0, plan.shaderCorner.isFinite, plan.shaderCorner > 0,
                  (0..<4).allSatisfy({ proxy[$0].isFinite }), proxy.z > proxy.x, proxy.w > proxy.y else { throw Failure.invalidMesh }
            let draw = plan.drawRectangle
            profiles.append(ProfileLayer(rectangle: .init(draw.x, draw.y, draw.z - draw.x, draw.w - draw.y),
                uniforms: [proxy, .init(plan.shaderCorner, Float(plan.blurRadius), Float(layer.alpha) / 255, 0)], texture: mask))
        }
        try encodeProfiles(profiles, pipeline: roundedRectangleBlurPipeline, destination: destination,
                           preserveContents: preserveContents, commandBuffer: commandBuffer)
    }

    private struct ProfileLayer {
        let rectangle: SIMD4<Float>
        let uniforms: [SIMD4<Float>]
        let texture: MTLTexture
        var quad: [SIMD2<Float>]? = nil
    }

    private func makeProfileTexture(_ pixels: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: pixels.count, height: 1, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, pixels.count, 1), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: pixels.count) }
        return texture
    }

    private func encodeProfiles(_ layers: [ProfileLayer], pipeline: MTLRenderPipelineState, destination: MTLTexture,
                                preserveContents: Bool, commandBuffer: MTLCommandBuffer) throws {
        guard destination.pixelFormat == .bgra8Unorm, destination.textureType == .type2D,
              destination.sampleCount == 1, destination.usage.contains(.renderTarget) else { throw Failure.invalidTarget }
        let quads = try layers.map { layer -> [SIMD2<Float>] in
            let r = layer.rectangle
            let points = layer.quad ?? [.init(r.x,r.y), .init(r.x,r.y+r.w), .init(r.x+r.z,r.y), .init(r.x+r.z,r.y+r.w)]
            guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw Failure.invalidMesh }
            return points
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = preserveContents ? .load : .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        var size = SIMD2<Float>(Float(destination.width), Float(destination.height))
        encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for (layer, quad) in zip(layers, quads) {
            encoder.setVertexBytes(quad, length: 4 * MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setFragmentBytes(layer.uniforms, length: layer.uniforms.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(layer.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    struct MaskLayer {
        let texture: MTLTexture
        /// The mask can occupy a subset of an approximate backing texture.
        let size: SIMD2<Int>
        let origin: SIMD2<Int>
        let alpha: UInt8
    }

    /// GrBlurUtils::draw_mask: integer device rectangle, nearest coverage lookup,
    /// premultiplied black source-over. Filtering has already happened in the mask.
    func encodeMasks(layers: [MaskLayer], destination: MTLTexture, preserveContents: Bool = false,
                     commandBuffer: MTLCommandBuffer) throws {
        guard destination.pixelFormat == .bgra8Unorm, destination.textureType == .type2D,
              destination.sampleCount == 1, destination.usage.contains(.renderTarget) else { throw Failure.invalidTarget }
        for layer in layers where layer.alpha > 0 {
            guard layer.texture.pixelFormat == .r8Unorm, layer.texture.textureType == .type2D,
                  layer.texture.sampleCount == 1, layer.texture.usage.contains(.shaderRead),
                  layer.size.x > 0, layer.size.y > 0,
                  layer.size.x <= layer.texture.width, layer.size.y <= layer.texture.height,
                  layer.origin.x > -8_000_000, layer.origin.x < 8_000_000,
                  layer.origin.y > -8_000_000, layer.origin.y < 8_000_000 else { throw Failure.invalidMesh }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = preserveContents ? .load : .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(maskPipeline)
        encoder.setCullMode(.none)
        var targetSize = SIMD2<Float>(Float(destination.width), Float(destination.height))
        encoder.setVertexBytes(&targetSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for layer in layers where layer.alpha > 0 {
            var rectangle = SIMD4<Float>(Float(layer.origin.x), Float(layer.origin.y), Float(layer.size.x), Float(layer.size.y))
            var alpha = Float(layer.alpha) / 255
            encoder.setVertexBytes(&rectangle, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
            encoder.setFragmentTexture(layer.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func encode(packed: [PackedLayer], pipeline: MTLRenderPipelineState,
                        destination: MTLTexture, preserveContents: Bool, commandBuffer: MTLCommandBuffer) throws {
        guard destination.pixelFormat == .bgra8Unorm, destination.sampleCount == 1,
              destination.width > 0, destination.height > 0 else { throw Failure.invalidTarget }
        // All validation/allocation precedes opening the encoder, so failure
        // cannot leave the caller's command buffer with an unfinished encoder.
        var draws: [(MTLBuffer, MTLBuffer, Int, UInt8, Float)] = []
        for layer in packed where layer.alpha > 0 {
            guard !layer.vertices.isEmpty, !layer.indices.isEmpty, layer.indices.count % 3 == 0,
                  layer.indices.allSatisfy({ Int($0) < layer.vertices.count / 2 }),
                  layer.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
            else { throw Failure.invalidMesh }
            let vertices = layer.vertices.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
            let indices = layer.indices.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
            guard let vertices, let indices else { throw Failure.allocation }
            draws.append((vertices, indices, layer.indices.count, layer.alpha, layer.coverageRadius))
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = preserveContents ? .load : .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setFragmentTexture(falloff, index: 0)
        var size = SIMD2<Float>(Float(destination.width), Float(destination.height))
        encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for (vertices, indices, count, alpha, radius) in draws {
            var opacity = SIMD2<Float>(Float(alpha) / 255, radius)
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint16,
                                          indexBuffer: indices, indexBufferOffset: 0)
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct MaskOut { float4 position [[position]]; float2 texel; };
    vertex MaskOut maskVertex(uint id [[vertex_id]], constant float4& rectangle [[buffer(0)]],
                              constant float2& size [[buffer(1)]]) {
        const float2 corners[4] = {float2(0, 0), float2(0, 1), float2(1, 0), float2(1, 1)};
        MaskOut out;
        out.texel = corners[id] * rectangle.zw;
        float2 point = rectangle.xy + out.texel;
        out.position = float4(point.x / size.x * 2 - 1, 1 - point.y / size.y * 2, 0, 1);
        return out;
    }
    vertex MaskOut profileVertex(uint id [[vertex_id]], constant float2* quad [[buffer(0)]],
                                 constant float2& size [[buffer(1)]]) {
        float2 point = quad[id];
        MaskOut out;
        out.position = float4(point.x / size.x * 2 - 1, 1 - point.y / size.y * 2, 0, 1);
        out.texel = float2(0);
        return out;
    }
    fragment half4 roundedRectangleBlurFragment(MaskOut in [[stage_in]], texture2d<half> mask [[texture(0)]],
                                                    constant float4 *uniforms [[buffer(0)]]) {
        constexpr sampler lut(coord::pixel, filter::nearest, address::clamp_to_edge);
        float4 proxy = uniforms[0];
        half corner = half(uniforms[1].x), blur = half(uniforms[1].y);
        float2 translated = in.position.xy - proxy.xy;
        float2 center = (proxy.zw - proxy.xy) * 0.5;
        half edge = half(2) * blur + corner + half(0.5);
        translated -= center;
        half2 direction = half2(sign(translated));
        translated = abs(translated);
        half2 warped = half2(translated - (center - float(edge)));
        warped = max(warped, half2(0));
        warped *= direction;
        warped += half2(edge);
        half2 dimensions = half2(half(2) * edge);
        half2 uv = warped / dimensions;
        half coverage = mask.sample(lut, float2(uv) * float2(mask.get_width(), mask.get_height())).r;
        return half4(0, 0, 0, coverage * half(uniforms[1].z));
    }
    fragment half4 circleBlurFragment(MaskOut in [[stage_in]], texture2d<half> profile [[texture(0)]],
                                         constant float4 *uniforms [[buffer(0)]]) {
        constexpr sampler lut(coord::pixel, filter::nearest, address::clamp_to_edge);
        half4 circle = half4(uniforms[0]);
        half2 vec = half2((in.position.xy - float2(circle.xy)) * float(circle.w));
        half dist = length(vec) + (half(0.5) - circle.z) * circle.w;
        half coverage = profile.sample(lut, float2(float(dist) * 512.0, 0.5)).r;
        return half4(0, 0, 0, coverage * half(uniforms[1].x));
    }
    fragment half4 rectangleBlurFragment(MaskOut in [[stage_in]], texture2d<half> integral [[texture(0)]],
                                            constant float4 *uniforms [[buffer(0)]]) {
        constexpr sampler lut(coord::pixel, filter::linear, address::clamp_to_edge);
        float4 rect = uniforms[0];
        float scale = uniforms[1].x;
        float2 pos = in.position.xy;
        if (uniforms[1].w != 0) {
            float3 a = uniforms[2].xyz, b = uniforms[3].xyz;
            pos = float2((pos.x * a.x + pos.y * a.y) + a.z, (pos.x * b.x + pos.y * b.y) + b.z);
        }
        half4 distances = half4(half2(rect.xy - pos), half2(pos - rect.zw));
        half xCoverage, yCoverage;
        if (uniforms[1].z != 0) {
            half2 xy = max(distances.xy, distances.zw);
            xCoverage = integral.sample(lut, float2(float(xy.x) * scale, 0.5)).r;
            yCoverage = integral.sample(lut, float2(float(xy.y) * scale, 0.5)).r;
        } else {
            xCoverage = half(1) - integral.sample(lut, float2(float(distances.x) * scale, 0.5)).r
                               - integral.sample(lut, float2(float(distances.z) * scale, 0.5)).r;
            yCoverage = half(1) - integral.sample(lut, float2(float(distances.y) * scale, 0.5)).r
                               - integral.sample(lut, float2(float(distances.w) * scale, 0.5)).r;
        }
        return half4(0, 0, 0, (xCoverage * yCoverage) * half(uniforms[1].y));
    }
    fragment half4 maskFragment(MaskOut in [[stage_in]], texture2d<half> mask [[texture(0)]],
                                constant float& alpha [[buffer(0)]]) {
        constexpr sampler coverageSampler(coord::pixel, filter::nearest, address::clamp_to_edge);
        return half4(0, 0, 0, half(alpha) * mask.sample(coverageSampler, in.texel).r);
    }
    struct RoundedCoverageOut { float4 position [[position]]; float2 offset; };
    vertex RoundedCoverageOut roundedCoverageVertex(uint id [[vertex_id]],
        const device float4* vertices [[buffer(0)]], constant float2& size [[buffer(1)]]) {
        float4 v = vertices[id * 2];
        return {float4(2.0 * v.x / size.x - 1.0, 1.0 - 2.0 * v.y / size.y, 0, 1), v.zw};
    }
    fragment half4 roundedCoverageFragment(RoundedCoverageOut in [[stage_in]], constant float2& paint [[buffer(0)]]) {
        half coverage = saturate(half(paint.y * (1.0 - length(in.offset))));
        return half4(0, 0, 0, coverage * half(paint.x));
    }
    struct RectangleCoverageOut { float4 position [[position]]; float coverage; };
    vertex RectangleCoverageOut rectangleCoverageVertex(uint id [[vertex_id]],
        const device float4* vertices [[buffer(0)]], constant float2& size [[buffer(1)]]) {
        float4 v = vertices[id * 2];
        return { float4(2.0 * v.x / size.x - 1.0, 1.0 - 2.0 * v.y / size.y, 0, 1), v.z };
    }
    fragment half4 rectangleCoverageFragment(RectangleCoverageOut in [[stage_in]],
                                              constant float& alpha [[buffer(0)]]) {
        return half4(0, 0, 0, half(in.coverage) * half(alpha));
    }
    struct ShadowOut { float4 position [[position]]; half3 params; };
    vertex ShadowOut shadowVertex(uint id [[vertex_id]],
                                  const device float4* vertices [[buffer(0)]],
                                  constant float2& size [[buffer(1)]]) {
        float4 v = vertices[id * 2];
        ShadowOut out;
        out.position = float4(v.x / size.x * 2.0 - 1.0, 1.0 - v.y / size.y * 2.0, 0, 1);
        out.params = half3(float3(v.zw, vertices[id * 2 + 1].x));
        return out;
    }
    fragment half4 shadowFragment(ShadowOut in [[stage_in]],
                                  texture2d<half> falloff [[texture(0)]],
                                  constant float& alpha [[buffer(0)]]) {
        half d = length(in.params.xy);
        float2 uv = float2(in.params.z * (1.0 - d), 0.5);
        constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        half factor = falloff.sample(linearSampler, uv).r;
        return half4(0, 0, 0, half(alpha) * factor);
    }
    fragment half4 tessellatedShadowFragment(ShadowOut in [[stage_in]],
                                             constant float& alpha [[buffer(0)]]) {
        half factor = 1 - in.params.z;
        factor = exp(-factor * factor * 4) - 0.018;
        return half4(0, 0, 0, half(alpha) * factor);
    }
    """
}
