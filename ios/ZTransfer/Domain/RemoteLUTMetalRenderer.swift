import Foundation
import Metal
import MetalKit
import CoreGraphics

final class RemoteLUTMetalRenderer {
    enum Failure: Error { case unavailable, pipeline, texture }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var lutTexture: MTLTexture?
    private var current: CubeLUT?

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw Failure.unavailable }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        self.queue = queue
        guard let library = try? device.makeLibrary(source: Self.shader, options: nil), let vertex = library.makeFunction(name: "remoteLUTVertex"), let fragment = library.makeFunction(name: "remoteLUTFragment") else { throw Failure.pipeline }
        let descriptor = MTLRenderPipelineDescriptor(); descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do { pipeline = try device.makeRenderPipelineState(descriptor: descriptor) } catch { throw Failure.pipeline }
    }

    func setLUT(_ candidate: CubeLUT) throws {
        if current?.digest == candidate.digest, lutTexture != nil { return }
        let descriptor = MTLTextureDescriptor(); descriptor.textureType = .type3D; descriptor.pixelFormat = .rgba16Float; descriptor.width = candidate.size; descriptor.height = candidate.size; descriptor.depth = candidate.size; descriptor.mipmapLevelCount = 1
        descriptor.usage = MTLTextureUsage.shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.texture }
        let values = candidate.rgba16FloatUploadValues
        values.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, candidate.size, candidate.size, candidate.size), mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!, bytesPerRow: candidate.size * 8, bytesPerImage: candidate.size * candidate.size * 8)
        }
        lutTexture = texture; current = candidate
    }

    func encode(source: MTLTexture, destination: MTLTexture, commandBuffer: MTLCommandBuffer, fit: SIMD2<Float> = SIMD2(repeating: 1)) throws {
        guard let lutTexture, let current, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: {
            let d = MTLRenderPassDescriptor(); d.colorAttachments[0].texture = destination; d.colorAttachments[0].loadAction = .clear; d.colorAttachments[0].storeAction = .store; return d
        }()) else { throw Failure.texture }
        var domain = SIMD4<Float>(current.domainMin.x, current.domainMin.y, current.domainMin.z, 0)
        var scale = SIMD4<Float>(1 / (current.domainMax.x-current.domainMin.x), 1 / (current.domainMax.y-current.domainMin.y), 1 / (current.domainMax.z-current.domainMin.z), 0)
        var size = UInt32(current.size)
        var fitValue = fit
        encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(source, index: 0); encoder.setFragmentTexture(lutTexture, index: 1)
        encoder.setFragmentBytes(&domain, length: MemoryLayout<SIMD4<Float>>.stride, index: 0); encoder.setFragmentBytes(&scale, length: MemoryLayout<SIMD4<Float>>.stride, index: 1); encoder.setFragmentBytes(&size, length: MemoryLayout<UInt32>.stride, index: 2); encoder.setVertexBytes(&fitValue, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); encoder.endEncoding()
    }

    /// Converts the existing decoded monitor CGImage into the source texture used
    /// by the LUT pass. The loader is recreated per frame only for the small
    /// monitor preview; callers can retain it when they have a persistent stream.
    func encode(image: CGImage, into destination: MTLTexture, commandBuffer: MTLCommandBuffer, fit: SIMD2<Float> = SIMD2(repeating: 1)) throws {
        guard image.colorSpace?.name == CGColorSpace.sRGB else { throw Failure.texture }
        let loader = MTKTextureLoader(device: device)
        guard let source = try? loader.newTexture(cgImage: image, options: [MTKTextureLoader.Option.SRGB: false]) else { throw Failure.texture }
        try encode(source: source, destination: destination, commandBuffer: commandBuffer, fit: fit)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut remoteLUTVertex(uint id [[vertex_id]], constant float2& fit [[buffer(0)]]) { float2 p=float2(float(id&1),float(id>>1)); VOut o; o.uv=float2(p.x,1.0-p.y); o.position=float4((p*2.0-1.0)*fit,0,1); return o; }
    fragment float4 remoteLUTFragment(VOut in [[stage_in]], texture2d<float> source [[texture(0)]], texture3d<half> table [[texture(1)]], constant float4& low [[buffer(0)]], constant float4& scale [[buffer(1)]], constant uint& size [[buffer(2)]]) { constexpr sampler s(filter::linear,address::clamp_to_edge); float4 pixel=source.sample(s,in.uv); float3 input=clamp((pixel.rgb-low.xyz)*scale.xyz,0.0,1.0); float3 coordinate=(input*(float(size)-1.0)+0.5)/float(size); return float4(clamp(float3(table.sample(s,coordinate).rgb),0.0,1.0),pixel.a); }
    """
}
