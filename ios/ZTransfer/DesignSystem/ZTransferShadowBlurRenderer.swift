// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Metal

/// A8 clamp filtering and padded reduction for shadow masks. The caller owns mask
/// rasterization and compositing; no CPU readback or wait occurs here.
final class ZTransferShadowBlurRenderer {
    enum Failure: Error { case invalidInput, unavailable, allocation }
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let rescalePipeline: MTLComputePipelineState
    private let paddingPipeline: MTLComputePipelineState
    private let roundedRectanglePipeline: MTLRenderPipelineState
    private let rectanglePipeline: MTLRenderPipelineState
    private let reexpandPipeline: MTLComputePipelineState

    private struct RoundedMaskKey: Hashable {
        let sigma: Int
        let corner: Int
    }
    private struct RoundedMaskEntry {
        let texture: MTLTexture
        var producer: MTLCommandBuffer?
        var bytes: Int { texture.width * texture.height }
    }
    private var roundedMasks: [RoundedMaskKey: RoundedMaskEntry] = [:]
    private var roundedMaskRecency: [RoundedMaskKey] = []
    private var roundedMaskBytes = 0
    private let maximumCachedMaskBytes: Int

    init(device: MTLDevice, maximumCachedMaskBytes: Int = 4 * 1024 * 1024) throws {
        guard maximumCachedMaskBytes >= 0 else { throw Failure.invalidInput }
        self.maximumCachedMaskBytes = maximumCachedMaskBytes
        self.device = device
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.shader, options: options)
        guard let function = library.makeFunction(name: "blurMask") else { throw Failure.unavailable }
        pipeline = try device.makeComputePipelineState(function: function)
        guard let rescale = library.makeFunction(name: "rescaleMask"),
              let padding = library.makeFunction(name: "padMask"),
              let reexpand = library.makeFunction(name: "reexpandMask") else { throw Failure.unavailable }
        rescalePipeline = try device.makeComputePipelineState(function: rescale)
        paddingPipeline = try device.makeComputePipelineState(function: padding)
        reexpandPipeline = try device.makeComputePipelineState(function: reexpand)
        let rectangle = MTLRenderPipelineDescriptor()
        rectangle.vertexFunction = library.makeFunction(name: "maskRectangleVertex")
        rectangle.fragmentFunction = library.makeFunction(name: "maskRectangleFragment")
        rectangle.colorAttachments[0].pixelFormat = .r8Unorm
        // create_mask_GPU draws one opaque styled shape into a cleared A8 surface.
        rectanglePipeline = try device.makeRenderPipelineState(descriptor: rectangle)
        rectangle.vertexFunction = library.makeFunction(name: "maskRoundedRectangleVertex")
        rectangle.fragmentFunction = library.makeFunction(name: "maskRoundedRectangleFragment")
        roundedRectanglePipeline = try device.makeRenderPipelineState(descriptor: rectangle)

    }

    /// Renderer access remains serial. Reuse pending work only inside its own
    /// command; another command cannot depend on an unsubmitted/failed producer.
    /// The cache bounds retained pixel payload, not driver or in-flight scratch.
    func roundedRectangleMask(plan: ZTransferShadowBlur.RoundedRectanglePlan,
                              maximumSurfaceBytes: Int,
                              commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        for key in roundedMaskRecency {
            guard let producer = roundedMasks[key]?.producer else { continue }
            switch producer.status {
            case .completed: roundedMasks[key]?.producer = nil
            case .error: removeRoundedMask(key)
            default: break
            }
        }
        let key = RoundedMaskKey(sigma: plan.sigmaKey, corner: plan.roundedCorner)
        if let entry = roundedMasks[key],
           entry.producer == nil || entry.producer === commandBuffer {
            roundedMaskRecency.removeAll { $0 == key }
            roundedMaskRecency.append(key)
            return entry.texture
        }
        let texture = try encodeRoundedRectangleMask(plan: plan,
            maximumSurfaceBytes: maximumSurfaceBytes, commandBuffer: commandBuffer)
        let bytes = texture.width * texture.height
        // A miss never rewrites a texture already referenced by an encoded draw.
        removeRoundedMask(key)
        if bytes <= maximumCachedMaskBytes {
            while let oldest = roundedMaskRecency.first,
                  roundedMaskBytes > maximumCachedMaskBytes - bytes || roundedMasks.count >= 64 {
                removeRoundedMask(oldest)
            }
            roundedMasks[key] = RoundedMaskEntry(texture: texture, producer: commandBuffer)
            roundedMaskRecency.append(key)
            roundedMaskBytes += bytes
        }
        return texture
    }

    private func removeRoundedMask(_ key: RoundedMaskKey) {
        if let entry = roundedMasks.removeValue(forKey: key) { roundedMaskBytes -= entry.bytes }
        roundedMaskRecency.removeAll { $0 == key }
    }

    /// fillin_view_on_gpu's exact A8 mask and clamp blur, using the explicit
    /// CircularRRect coverage-AA route. The caller must select this capability.
    /// The budget covers the two retained surfaces, not recursive blur scratch.
    func encodeRoundedRectangleMask(plan: ZTransferShadowBlur.RoundedRectanglePlan,
                                    maximumSurfaceBytes: Int,
                                    commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let size = plan.textureSize
        guard size.x > 0, size.y > 0, maximumSurfaceBytes >= 0,
              size.x <= maximumSurfaceBytes / 2 / size.y else { throw Failure.invalidInput }
        let bounds = SIMD4<Int>(0, 0, size.x, size.y)
        let bytes = size.x * size.y
        let source = try makeMaskSurface(deviceBounds: bounds, maximumWorkingBytes: bytes,
                                        backing: .exact, commandBuffer: commandBuffer)
        let output = try makeMaskSurface(deviceBounds: bounds, maximumWorkingBytes: bytes,
                                        backing: .exact, commandBuffer: commandBuffer)
        try encodeCoverageRoundedRectangle(deviceBounds: plan.maskRectangle,
            radius: Float(plan.roundedCorner), surface: source, commandBuffer: commandBuffer)
        try encodeGaussian(source: source.texture, sourceBounds: bounds,
            destination: output.texture, destinationBounds: bounds,
            sigma: .init(repeating: plan.sigma), paddedUpscale: false, commandBuffer: commandBuffer)
        return output.texture
    }

    func encode(source: MTLTexture, destination: MTLTexture, sigma: SIMD2<Float>,
                commandBuffer: MTLCommandBuffer) throws {
        try encode(source: source, sourceBounds: .init(0, 0, source.width, source.height),
                   destination: destination, destinationBounds: .init(0, 0, destination.width, destination.height),
                   sigma: sigma, commandBuffer: commandBuffer)
    }

    /// Destination bounds are in source coordinates; output texture starts at zero.
    func encode(source: MTLTexture, sourceBounds: SIMD4<Int>, destination: MTLTexture,
                destinationBounds: SIMD4<Int>, sigma: SIMD2<Float>, commandBuffer: MTLCommandBuffer) throws {
        guard ZTransferShadowBlur.radius(sigma: sigma.x) != nil, ZTransferShadowBlur.radius(sigma: sigma.y) != nil,
              storageRoot(source) !== storageRoot(destination), source.pixelFormat == .r8Unorm, destination.pixelFormat == .r8Unorm,
              source.textureType == .type2D, destination.textureType == .type2D,
              source.sampleCount == 1, destination.sampleCount == 1,
              source.usage.contains(.shaderRead), destination.usage.contains(.shaderWrite),
              sourceBounds.x >= 0, sourceBounds.y >= 0, sourceBounds.z <= source.width, sourceBounds.w <= source.height,
              let plan = ZTransferShadowBlur.clampPlan(sourceBounds: sourceBounds, destinationBounds: destinationBounds, sigma: sigma),
              destinationBounds.z - destinationBounds.x == destination.width,
              destinationBounds.w - destinationBounds.y == destination.height else { throw Failure.invalidInput }
        let sigma = plan.sigma, rx = plan.radius.x, ry = plan.radius.y
        let subset = plan.sourceBounds
        let origin = SIMD2(destinationBounds.x, destinationBounds.y)
        let area = (2 * rx + 1) * (2 * ry + 1)
        if rx > 0 && ry > 0 && area <= ZTransferShadowBlur.maximumSamples {
            guard let kernel = ZTransferShadowBlur.kernel(sigma: sigma) else { throw Failure.invalidInput }
            var samples: [SIMD4<Float>] = []
            for y in -ry...ry {
                for x in -rx...rx {
                    samples.append(.init(Float(x), Float(y), kernel[(y + ry) * (2 * rx + 1) + x + rx], 0))
                }
            }
            try encodePass(source: source, destination: destination, samples: samples, subset: subset, origin: origin, commandBuffer: commandBuffer)
        } else if let bounds = plan.horizontalBounds {
            let width = bounds.z - bounds.x, height = bounds.w - bounds.y
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let intermediate = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
            try encodePass(source: source, destination: intermediate, samples: samples(sigma: sigma.x, horizontal: true),
                subset: subset, origin: .init(bounds.x, bounds.y), commandBuffer: commandBuffer)
            try encodePass(source: intermediate, destination: destination, samples: samples(sigma: sigma.y, horizontal: false),
                subset: .init(0, 0, width, height), origin: origin &- .init(bounds.x, bounds.y), commandBuffer: commandBuffer)
        } else {
            // This also copies an identity blur, matching GaussianBlur's tiled draw.
            try encodePass(source: source, destination: destination,
                samples: samples(sigma: rx > 0 ? sigma.x : sigma.y, horizontal: rx > 0),
                subset: subset, origin: origin, commandBuffer: commandBuffer)
        }
    }

    struct MaskSurface {
        let texture: MTLTexture
        /// Drawing is clipped here; GaussianBlur reads the entire backing texture.
        let contentBounds: SIMD4<Int>
        /// Subtract this from device coordinates when rasterizing the shape.
        let deviceOrigin: SIMD2<Int>
    }

    enum MaskBacking { case approximate, exact }

    /// General masks use approximate backing; nine-patch caches require exact dimensions.
    /// The caller still must rasterize the styled path with AA inside contentBounds.
    func makeMaskSurface(deviceBounds: SIMD4<Int>, maximumWorkingBytes: Int, backing: MaskBacking = .approximate,
                         commandBuffer: MTLCommandBuffer) throws -> MaskSurface {
        guard (0..<4).allSatisfy({ deviceBounds[$0] > -8_000_000 && deviceBounds[$0] < 8_000_000 }),
              deviceBounds.z > deviceBounds.x, deviceBounds.w > deviceBounds.y else { throw Failure.invalidInput }
        let contentSize = SIMD2(deviceBounds.z - deviceBounds.x, deviceBounds.w - deviceBounds.y)
        let size: SIMD2<Int>
        switch backing {
        case .exact: size = contentSize
        case .approximate:
            guard let approximate = ZTransferShadowBlur.maskBackingSize(contentSize) else { throw Failure.invalidInput }
            size = approximate
        }
        guard maximumWorkingBytes >= 0, size.x <= maximumWorkingBytes / size.y else { throw Failure.invalidInput }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
            width: size.x, height: size.y, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
        encoder.endEncoding()
        return MaskSurface(texture: texture,
            contentBounds: .init(0, 0, deviceBounds.z - deviceBounds.x, deviceBounds.w - deviceBounds.y),
            deviceOrigin: .init(deviceBounds.x, deviceBounds.y))
    }

    /// Axis-aligned, filled rectangle with all-edge coverage AA (not MSAA).
    /// Android 15 QuadPerEdgeAA: inner/outer quads, original picture-frame indices,
    /// and a two-pixel outer span when the inner quad collapses. Other path types
    /// and strokes must use their own rasterization route.
    func encodeCoverageRectangle(deviceBounds: SIMD4<Float>, surface: MaskSurface,
                                 commandBuffer: MTLCommandBuffer) throws {
        let texture = surface.texture, clip = surface.contentBounds
        guard (0..<4).allSatisfy({ deviceBounds[$0].isFinite && abs(deviceBounds[$0]) < 8_000_000 }),
              (0..<2).allSatisfy({ surface.deviceOrigin[$0] > -8_000_000 && surface.deviceOrigin[$0] < 8_000_000 }),
              deviceBounds.z > deviceBounds.x, deviceBounds.w > deviceBounds.y,
              texture.pixelFormat == .r8Unorm, texture.textureType == .type2D,
              texture.sampleCount == 1, texture.usage.contains(.renderTarget),
              clip.x >= 0, clip.y >= 0, clip.z > clip.x, clip.w > clip.y,
              clip.z <= texture.width, clip.w <= texture.height else { throw Failure.invalidInput }
        let origin = SIMD4<Float>(Float(surface.deviceOrigin.x), Float(surface.deviceOrigin.y),
                                  Float(surface.deviceOrigin.x), Float(surface.deviceOrigin.y))
        let rect = deviceBounds - origin
        let vertices = ZTransferShadowBlur.coverageRectangleVertices(rect)
        guard vertices.allSatisfy({ v in (0..<4).allSatisfy { v[$0].isFinite } }) else { throw Failure.invalidInput }
        let triangles = ZTransferShadowBlur.coverageRectangleIndices.map { vertices[Int($0)] }
        var size = SIMD2<Float>(Float(texture.width), Float(texture.height))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
        encoder.setRenderPipelineState(rectanglePipeline)
        encoder.setScissorRect(.init(x: clip.x, y: clip.y, width: clip.z - clip.x, height: clip.w - clip.y))
        encoder.setVertexBytes(triangles, length: triangles.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
        encoder.endEncoding()
    }

    /// CircularRRectOp fill branch for coverage AA, identity device transform,
    /// and radius >= 0.5. Callers must select this capability-dependent route;
    /// it does not stand in for FillRRectOp or MSAA.
    func encodeCoverageRoundedRectangle(deviceBounds: SIMD4<Float>, radius: Float, surface: MaskSurface,
                                        commandBuffer: MTLCommandBuffer) throws {
        let texture = surface.texture, clip = surface.contentBounds
        guard (0..<4).allSatisfy({ deviceBounds[$0].isFinite && abs(deviceBounds[$0]) < 8_000_000 }),
              (0..<2).allSatisfy({ surface.deviceOrigin[$0] > -8_000_000 && surface.deviceOrigin[$0] < 8_000_000 }),
              radius.isFinite, radius >= 0.5,
              deviceBounds.z - deviceBounds.x >= 2 * radius, deviceBounds.w - deviceBounds.y >= 2 * radius,
              texture.pixelFormat == .r8Unorm, texture.textureType == .type2D, texture.sampleCount == 1,
              texture.usage.contains(.renderTarget), clip.x >= 0, clip.y >= 0,
              clip.z > clip.x, clip.w > clip.y, clip.z <= texture.width, clip.w <= texture.height else { throw Failure.invalidInput }
        let translated = deviceBounds - SIMD4(Float(surface.deviceOrigin.x), Float(surface.deviceOrigin.y),
                                              Float(surface.deviceOrigin.x), Float(surface.deviceOrigin.y))
        var outerRadius = radius + 0.5
        let vertices = ZTransferShadowBlur.coverageRoundedRectangleVertices(bounds: translated, radius: radius)
        let triangles = ZTransferShadowBlur.coverageRoundedRectangleIndices.map { vertices[Int($0)] }
        var size = SIMD2<Float>(Float(texture.width), Float(texture.height))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(roundedRectanglePipeline)
        encoder.setScissorRect(.init(x: clip.x, y: clip.y, width: clip.z - clip.x, height: clip.w - clip.y))
        encoder.setVertexBytes(triangles, length: triangles.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&outerRadius, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
    }

    /// Full clamp GaussianBlur orchestration, including recursive large-sigma reduction.
    /// Explicit policy preserves the selected Skia build's re-expansion behavior.
    func encodeGaussian(source: MTLTexture, sourceBounds: SIMD4<Int>, destination: MTLTexture,
                        destinationBounds: SIMD4<Int>, sigma: SIMD2<Float>, paddedUpscale: Bool,
                        commandBuffer: MTLCommandBuffer) throws {
        guard storageRoot(source) !== storageRoot(destination),
              source.pixelFormat == .r8Unorm, destination.pixelFormat == .r8Unorm,
              source.textureType == .type2D, destination.textureType == .type2D,
              source.sampleCount == 1, destination.sampleCount == 1,
              source.usage.contains(.shaderRead), destination.usage.contains(.shaderWrite),
              sourceBounds.x >= 0, sourceBounds.y >= 0, sourceBounds.z <= source.width, sourceBounds.w <= source.height,
              let plan = ZTransferShadowBlur.clampPlan(sourceBounds: sourceBounds, destinationBounds: destinationBounds, sigma: sigma),
              destinationBounds.z - destinationBounds.x == destination.width,
              destinationBounds.w - destinationBounds.y == destination.height else { throw Failure.invalidInput }
        if plan.sigma.x <= ZTransferShadowBlur.maximumSigma && plan.sigma.y <= ZTransferShadowBlur.maximumSigma {
            try encode(source: source, sourceBounds: plan.sourceBounds, destination: destination,
                       destinationBounds: destinationBounds, sigma: plan.sigma, commandBuffer: commandBuffer)
            return
        }
        let bounds = plan.sourceBounds
        let size = SIMD2(bounds.z - bounds.x, bounds.w - bounds.y)
        let relativeDestination = destinationBounds &- SIMD4(bounds.x, bounds.y, bounds.x, bounds.y)
        guard let reduction = ZTransferShadowBlur.rescalePlan(sourceSize: size, destinationBounds: relativeDestination,
            sigma: plan.sigma, paddedUpscale: paddedUpscale) else { throw Failure.invalidInput }
        // Materialize only the retained subset so the edge padding samples precisely
        // these original boundary rows/columns, not neighboring backing texels.
        let cropped: MTLTexture
        if bounds == SIMD4(0, 0, source.width, source.height) {
            cropped = source
        } else {
            cropped = try makeMask(size: size)
            try encodePass(source: source, destination: cropped, samples: [.init(0, 0, 1, 0)],
                           subset: bounds, origin: .init(bounds.x, bounds.y), commandBuffer: commandBuffer)
        }
        let reduced = try makeMask(size: reduction.paddedSize)
        try encodeDownsample(source: cropped, destination: reduced, commandBuffer: commandBuffer)
        let blurBounds = reduction.blurBounds
        let blurred = try makeMask(size: .init(blurBounds.z - blurBounds.x, blurBounds.w - blurBounds.y))
        // A one-pixel retained source axis has already become sigma zero. Other
        // oversized axes either shrink now or shrink after the 1px border is added.
        try encodeGaussian(source: reduced, sourceBounds: .init(0, 0, reduced.width, reduced.height),
            destination: blurred, destinationBounds: blurBounds, sigma: reduction.sigma,
            paddedUpscale: paddedUpscale, commandBuffer: commandBuffer)
        try encodeReexpand(source: blurred, destination: destination, sourceBounds: reduction.reexpandBounds,
                           paddedUpscale: paddedUpscale, commandBuffer: commandBuffer)
    }

    private func makeMask(size: SIMD2<Int>) throws -> MTLTexture {
        guard size.x > 0, size.y > 0 else { throw Failure.invalidInput }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
            width: size.x, height: size.y, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        return texture
    }

    /// GrBlurUtils clamp reduction: repeated linear interior draws, then a single
    /// linear draw per original edge and direct original corners. Every intermediate
    /// is A8, preserving quantization between passes. Destination includes a 1px border.
    func encodeDownsample(source: MTLTexture, destination: MTLTexture,
                          commandBuffer: MTLCommandBuffer) throws {
        let target = SIMD2(destination.width - 2, destination.height - 2)
        guard target.x > 0, target.y > 0, target.x <= source.width, target.y <= source.height,
              storageRoot(source) !== storageRoot(destination),
              source.pixelFormat == .r8Unorm, destination.pixelFormat == .r8Unorm,
              source.textureType == .type2D, destination.textureType == .type2D,
              source.sampleCount == 1, destination.sampleCount == 1,
              source.usage.contains(.shaderRead), destination.usage.contains(.shaderWrite) else { throw Failure.invalidInput }
        var interior = source
        while interior.width != target.x || interior.height != target.y {
            let size = SIMD2(max((interior.width + 1) / 2, target.x),
                             max((interior.height + 1) / 2, target.y))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                width: size.x, height: size.y, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let next = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
            try encodeRescale(source: interior, original: source, destination: next,
                              pipeline: rescalePipeline, commandBuffer: commandBuffer)
            interior = next
        }
        try encodeRescale(source: interior, original: source, destination: destination,
                          pipeline: paddingPipeline, commandBuffer: commandBuffer)
    }

    /// GrBlurUtils::reexpand. The historical branch clamps to the fractional
    /// source rectangle; padded upscale clamps to the whole blurred content.
    func encodeReexpand(source: MTLTexture, destination: MTLTexture, sourceBounds: SIMD4<Float>,
                        paddedUpscale: Bool, commandBuffer: MTLCommandBuffer) throws {
        guard storageRoot(source) !== storageRoot(destination),
              source.pixelFormat == .r8Unorm, destination.pixelFormat == .r8Unorm,
              source.textureType == .type2D, destination.textureType == .type2D,
              source.sampleCount == 1, destination.sampleCount == 1,
              source.usage.contains(.shaderRead), destination.usage.contains(.shaderWrite),
              (0..<4).allSatisfy({ sourceBounds[$0].isFinite }),
              sourceBounds.x >= 0, sourceBounds.y >= 0,
              sourceBounds.z <= Float(source.width), sourceBounds.w <= Float(source.height),
              sourceBounds.x < sourceBounds.z, sourceBounds.y < sourceBounds.w else { throw Failure.invalidInput }
        let subset: SIMD4<Float> = paddedUpscale ? .init(0, 0, Float(source.width), Float(source.height)) : sourceBounds
        var clampBounds = subset + .init(0.5, 0.5, -0.5, -0.5)
        // GrTextureEffect::Sampling::Span::makeInset collapses subpixel spans
        // to their midpoint instead of supplying reversed clamp bounds.
        if clampBounds.x > clampBounds.z { clampBounds.x = (clampBounds.x + clampBounds.z) / 2; clampBounds.z = clampBounds.x }
        if clampBounds.y > clampBounds.w { clampBounds.y = (clampBounds.y + clampBounds.w) / 2; clampBounds.w = clampBounds.y }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw Failure.allocation }
        encoder.setComputePipelineState(reexpandPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        var bounds = sourceBounds
        encoder.setBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setBytes(&clampBounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.dispatchThreads(.init(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: .init(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }

    private func storageRoot(_ texture: MTLTexture) -> MTLTexture {
        var root = texture
        while let parent = root.parent { root = parent }
        return root
    }

    private func encodeRescale(source: MTLTexture, original: MTLTexture, destination: MTLTexture,
                               pipeline: MTLComputePipelineState, commandBuffer: MTLCommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw Failure.allocation }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setTexture(original, index: 2)
        encoder.dispatchThreads(.init(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: .init(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }

    private func samples(sigma: Float, horizontal: Bool) throws -> [SIMD4<Float>] {
        guard let radius = ZTransferShadowBlur.radius(sigma: sigma),
              let kernel = ZTransferShadowBlur.linearKernel(sigma: sigma) else { throw Failure.invalidInput }
        return kernel.prefix(radius + 1).map { .init(horizontal ? $0.x : 0, horizontal ? 0 : $0.x, $0.y, 0) }
    }

    private func encodePass(source: MTLTexture, destination: MTLTexture, samples: [SIMD4<Float>],
                            subset: SIMD4<Int>, origin: SIMD2<Int>, commandBuffer: MTLCommandBuffer) throws {
        // Skia shaders use loop variants rounded to four samples.
        var padded = samples
        let count = ((samples.count + 3) / 4) * 4
        while padded.count < count { padded.append(.init(samples.last?.x ?? 0, samples.last?.y ?? 0, 0, 0)) }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw Failure.allocation }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        padded.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        var sampleCount = UInt32(count)
        encoder.setBytes(&sampleCount, length: MemoryLayout<UInt32>.size, index: 1)
        var clampBounds = SIMD4<Float>(Float(subset.x) + 0.5, Float(subset.y) + 0.5,
                                       Float(subset.z) - 0.5, Float(subset.w) - 0.5)
        var offset = SIMD2<Float>(Float(origin.x), Float(origin.y))
        encoder.setBytes(&clampBounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        encoder.setBytes(&offset, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        encoder.dispatchThreads(.init(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: .init(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct MaskRoundedRectangleVertex { float4 position [[position]]; float2 offset; };
    vertex MaskRoundedRectangleVertex maskRoundedRectangleVertex(uint id [[vertex_id]],
        constant float4 *vertices [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
        float4 v = vertices[id];
        return { float4(2.0 * v.x / size.x - 1.0, 1.0 - 2.0 * v.y / size.y, 0, 1), v.zw };
    }
    fragment half4 maskRoundedRectangleFragment(MaskRoundedRectangleVertex in [[stage_in]],
                                                constant float &radius [[buffer(0)]]) {
        float d = length(in.offset);
        half coverage = saturate(half(radius * (1.0 - d)));
        return half4(coverage);
    }
    struct MaskRectangleVertex { float4 position [[position]]; float coverage; };
    vertex MaskRectangleVertex maskRectangleVertex(uint id [[vertex_id]],
        constant float4 *vertices [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
        float4 v = vertices[id];
        return { float4(2.0 * v.x / size.x - 1.0, 1.0 - 2.0 * v.y / size.y, 0, 1), v.z };
    }
    fragment half4 maskRectangleFragment(MaskRectangleVertex in [[stage_in]]) {
        return half4(half(in.coverage));
    }
    kernel void reexpandMask(texture2d<half, access::sample> source [[texture(0)]],
                             texture2d<half, access::write> destination [[texture(1)]],
                             constant float4& bounds [[buffer(0)]], constant float4& subset [[buffer(1)]],
                             uint2 position [[thread_position_in_grid]]) {
        uint2 size(destination.get_width(), destination.get_height());
        if (any(position >= size)) return;
        constexpr sampler linearClamp(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 scale = (bounds.zw - bounds.xy) / float2(size);
        float2 center = bounds.xy + (float2(position) + 0.5) * scale;
        destination.write(source.sample(linearClamp, clamp(center, subset.xy, subset.zw)), position);
    }
    kernel void rescaleMask(texture2d<half, access::sample> source [[texture(0)]],
                            texture2d<half, access::write> destination [[texture(1)]],
                            uint2 position [[thread_position_in_grid]]) {
        uint2 size(destination.get_width(), destination.get_height());
        if (any(position >= size)) return;
        constexpr sampler linearClamp(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 ratio = float2(source.get_width(), source.get_height()) / float2(size);
        destination.write(source.sample(linearClamp, (float2(position) + 0.5) * ratio), position);
    }
    kernel void padMask(texture2d<half, access::read> interior [[texture(0)]],
                        texture2d<half, access::write> destination [[texture(1)]],
                        texture2d<half, access::sample> original [[texture(2)]],
                        uint2 position [[thread_position_in_grid]]) {
        uint2 size(destination.get_width(), destination.get_height());
        if (any(position >= size)) return;
        if (all(position > uint2(0)) && all(position < size - 1)) {
            destination.write(interior.read(position - 1), position);
            return;
        }
        constexpr sampler linearClamp(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 sourceSize(original.get_width(), original.get_height());
        float2 center = (float2(position) - 0.5) * sourceSize / float2(size - 2);
        if (position.x == 0) center.x = 0.5;
        if (position.y == 0) center.y = 0.5;
        if (position.x == size.x - 1) center.x = sourceSize.x - 0.5;
        if (position.y == size.y - 1) center.y = sourceSize.y - 0.5;
        destination.write(original.sample(linearClamp, center), position);
    }
    kernel void blurMask(texture2d<half, access::sample> source [[texture(0)]],
                         texture2d<half, access::write> destination [[texture(1)]],
                         constant float4* samples [[buffer(0)]], constant uint& count [[buffer(1)]],
                         constant float4& subset [[buffer(2)]], constant float2& origin [[buffer(3)]],
                         uint2 position [[thread_position_in_grid]]) {
        if (position.x >= destination.get_width() || position.y >= destination.get_height()) return;
        constexpr sampler linearClamp(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 center = float2(position) + origin + 0.5;
        half sum = 0;
        for (uint i = 0; i < count; ++i) {
            half2 offset = half2(samples[i].xy);
            half weight = half(samples[i].z);
            sum += weight * source.sample(linearClamp, clamp(center + float2(offset), subset.xy, subset.zw)).r;
        }
        destination.write(half4(sum), position);
    }
    """
}
