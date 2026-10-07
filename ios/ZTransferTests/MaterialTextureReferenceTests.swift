import CryptoKit
import XCTest
@testable import ZTransfer

final class MaterialTextureReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        struct Probe: Decodable {
            let input: Int32
            let mixed: Int32
            let titaniumVariant: Int
            let woodVariant: Int
            let cameraVariant: Int
        }
        struct Tile: Decodable {
            struct Sample: Decodable { let index: Int; let argb: String }
            let skinOrdinal: Int
            let dark: Bool
            let variant: Int
            let seed: Int32
            let sha256: String
            let samples: [Sample]
        }
        let seedProbes: [Probe]
        let tiles: [Tile]
    }

    private func reference() throws -> Reference {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "AndroidMaterialTextures", withExtension: "json"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    func testSignedSeedsAndVariantSelectionMatchAndroidExecution() throws {
        let reference = try reference()
        XCTAssertEqual(reference.seedProbes.count, 8)
        for probe in reference.seedProbes {
            XCTAssertEqual(ZTransferMaterialTexture.mixSeed(probe.input), probe.mixed)
            XCTAssertEqual(ZTransferMaterialTexture.variant(material: .titanium, seed: probe.input), probe.titaniumVariant)
            XCTAssertEqual(ZTransferMaterialTexture.variant(material: .wood, seed: probe.input), probe.woodVariant)
            XCTAssertEqual(ZTransferMaterialTexture.variant(material: .cameraControls, seed: probe.input), probe.cameraVariant)
        }
    }

    func testEveryPixelOfAllEightyTilesMatchesAndroidExecution() throws {
        let reference = try reference()
        XCTAssertEqual(reference.tiles.count, 80)
        for tile in reference.tiles {
            let material = try XCTUnwrap(ZTransferMaterialTexture.Material(rawValue: tile.skinOrdinal))
            let identity = "material=\(material) dark=\(tile.dark) variant=\(tile.variant)"
            XCTAssertEqual(ZTransferMaterialTexture.tileSeed(material: material, variant: tile.variant), tile.seed, identity)
            let pixels = ZTransferMaterialTexture.pixels(material: material, dark: tile.dark, variant: tile.variant)
            XCTAssertEqual(pixels.count, 65_536, identity)
            for sample in tile.samples {
                XCTAssertEqual(pixels[sample.index], UInt32(sample.argb, radix: 16), "\(identity) index=\(sample.index)")
            }
            var bytes = Data(capacity: pixels.count * 4)
            for pixel in pixels {
                bytes.append(UInt8(truncatingIfNeeded: pixel >> 24))
                bytes.append(UInt8(truncatingIfNeeded: pixel >> 16))
                bytes.append(UInt8(truncatingIfNeeded: pixel >> 8))
                bytes.append(UInt8(truncatingIfNeeded: pixel))
            }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, tile.sha256, identity)
        }
    }
}
