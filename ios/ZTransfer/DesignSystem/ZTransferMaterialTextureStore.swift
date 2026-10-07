import SwiftUI
import CoreGraphics

struct ZTransferTextureKey: Hashable, Sendable {
    let material: ZTransferMaterialTexture.Material
    let dark: Bool
    let variant: Int

    init(material: ZTransferMaterialTexture.Material, dark: Bool, seed: Int32) {
        self.material = material
        self.dark = dark
        variant = ZTransferMaterialTexture.variant(material: material, seed: seed)
    }

    init?(skin: ZTransferButtonSkin, dark: Bool, seed: Int32, panel: Bool) {
        let material: ZTransferMaterialTexture.Material
        switch skin {
        case .titanium: material = .titanium
        case .wood: material = .wood
        case .cameraControls where !panel: material = .cameraControls
        case .cameraControls, .frostedGlass, .liquidGlass: return nil
        }
        self.init(material: material, dark: dark, seed: seed)
    }

    /// Stable native call-site identity; never use Swift's randomized Hasher.
    /// Explicit Android textureSeed constants bypass this mapping.
    static func stableSeed(_ identity: String) -> Int32 {
        let bits = identity.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return Int32(bitPattern: bits)
    }
}

/// CGImage is immutable after construction; safely shared by the serial worker
/// and main-actor cache. The image is independent of screen scale.
struct ZTransferTextureBitmap: @unchecked Sendable {
    let image: CGImage

    static func premultipliedRGBA(_ argb: [UInt32]) -> Data {
        var data = Data(capacity: argb.count * 4)
        for pixel in argb {
            let a = pixel >> 24
            // Android's SkPremultiplyARGBInline rounds each channel * a / 255.
            // Quantize alpha first, as Bitmap.createBitmap(IntArray) does.
            for shift: UInt32 in [16, 8, 0] {
                data.append(UInt8((((pixel >> shift) & 255) * a + 127) / 255))
            }
            data.append(UInt8(a))
        }
        return data
    }

    static func render(_ key: ZTransferTextureKey) -> Self? {
        let pixels = ZTransferMaterialTexture.pixels(material: key.material, dark: key.dark, variant: key.variant)
        let data = premultipliedRGBA(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: 256 * 4, space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return Self(image: image)
    }
}

private actor ZTransferTextureWorker {
    let generate: @Sendable (ZTransferTextureKey) -> ZTransferTextureBitmap?
    init(generate: @escaping @Sendable (ZTransferTextureKey) -> ZTransferTextureBitmap?) {
        self.generate = generate
    }
    // No await in this operation: tile generation is serial, like Android's
    // tileGenerationMutex, and never occupies the main actor.
    func render(_ key: ZTransferTextureKey) -> ZTransferTextureBitmap? { generate(key) }
}

@MainActor
final class ZTransferMaterialTextureStore: ObservableObject {
    static let shared = ZTransferMaterialTextureStore()
    @Published private var images: [ZTransferTextureKey: ZTransferTextureBitmap] = [:]
    private var loading: [ZTransferTextureKey: Task<Void, Never>] = [:]
    private let worker: ZTransferTextureWorker

    init(generate: @escaping @Sendable (ZTransferTextureKey) -> ZTransferTextureBitmap? = ZTransferTextureBitmap.render) {
        worker = ZTransferTextureWorker(generate: generate)
    }

    func image(for key: ZTransferTextureKey) -> CGImage? { images[key]?.image }

    func load(_ key: ZTransferTextureKey) async {
        if images[key] != nil { return }
        if let task = loading[key] { await task.value; return }
        let task = Task {
            if let bitmap = await worker.render(key) { images[key] = bitmap }
            loading[key] = nil
        }
        loading[key] = task
        // Cancellation of a single view must not discard work shared by other
        // buttons. A completed tile remains cached across theme/page changes.
        await task.value
    }
}
