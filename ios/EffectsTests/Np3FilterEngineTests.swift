import XCTest
import CryptoKit
#if SWIFT_PACKAGE
@testable import ZTransferEffects
#else
@testable import ZTransfer
#endif

final class Np3FilterEngineTests: XCTestCase {
    func testApplicationCatalogContainsNoBundledRecipesOrLegacyAliases() {
        XCTAssertTrue(Np3FilterCatalog.presets.isEmpty)
        XCTAssertTrue(PhotoFilterCatalog.presets.isEmpty)
        for id in ["forest_verdure", "british_mono", "blue_hour",
                   "1ecd940d47f9572952b54c2f1e2dcabf5ea9570eca99439bfef3caa13803dba3"] {
            XCTAssertNil(Np3FilterCatalog.preset(id: id))
            XCTAssertNil(PhotoFilterCatalog.resolve(id))
        }
    }

    func testNeutralProtectionRejectsNoiseAndPreservesEstablishedColor() {
        XCTAssertEqual(Np3FilterEngine.neutralProtectionWeight(0), 0)
        XCTAssertEqual(Np3FilterEngine.neutralProtectionWeight(Np3FilterEngine.neutralProtectionChromaStart), 0)
        XCTAssertEqual(Np3FilterEngine.neutralProtectionWeight(Np3FilterEngine.neutralProtectionChromaEnd), 1)
        XCTAssertEqual(Np3FilterEngine.neutralProtectionWeight(1), 1)
        let start = Np3FilterEngine.neutralProtectionChromaStart
        let end = Np3FilterEngine.neutralProtectionChromaEnd
        XCTAssertEqual(Np3FilterEngine.neutralProtectionWeight((start + end) / 2), 0.5, accuracy: 0.0001)
        let weights = (0...16).map { Np3FilterEngine.neutralProtectionWeight(start + (end - start) * Float($0) / 16) }
        XCTAssertTrue(zip(weights, weights.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testBoundedHueAndSecondaryComponentMatchAndroidModuloDefinition() {
        for hue: Float in [-60, -30, -0.01, 0, 30, 359.99, 360, 390] {
            let expected = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            XCTAssertEqual(Np3FilterEngine.normalizeHue(hue), expected)
        }
        for step in 0...3_599 {
            let hue = Float(step) / 10
            let section = hue / 60
            let expected: Float = 0.73 * (1 - abs(section.truncatingRemainder(dividingBy: 2) - 1))
            XCTAssertEqual(Np3FilterEngine.hslSecondaryComponent(section: section, sector: Int(section), chroma: 0.73),
                           expected, accuracy: 0.000001)
        }
    }

    func testLookupPreservesAlphaAndTransparentSourcePixels() {
        XCTAssertEqual(Np3FilterEngine.exactLookupOutputColor(originalColor: 0x00112233, mappedRGB: 0x00123456, preserveAlpha: false), 0xff123456)
        XCTAssertEqual(Np3FilterEngine.exactLookupOutputColor(originalColor: 0x7f112233, mappedRGB: 0x00123456, preserveAlpha: true), 0x7f123456)
        XCTAssertEqual(Np3FilterEngine.exactLookupOutputColor(originalColor: 0x00112233, mappedRGB: 0x00123456, preserveAlpha: true), 0x00112233)
    }

    func testIntensityHasAndroidEvenDetentsAndSeparateDisabledState() {
        XCTAssertEqual(Np3FilterEngine.defaultIntensityPercent, 80)
        XCTAssertEqual([Int.min, 0, 1, 2, 3, 79, 80, 81, 99, 100, Int.max].map(Np3FilterEngine.normalizeIntensity),
                       [2, 2, 2, 2, 4, 80, 80, 82, 100, 100, 100])
    }

    func testCancellationStopsAtAndroidStripeCheckBoundary() throws {
        let preset = try XCTUnwrap(TestPhotoFilterCatalog.np3Presets.first)
        let engine = Np3FilterEngine(parameters: preset.parameters, intensityPercent: 80)
        let original: UInt32 = 0xff808080
        var pixels = [UInt32](repeating: original, count: 8_192)
        var checks = 0
        XCTAssertThrowsError(try engine.filterPixels(&pixels) {
            checks += 1
            return checks == 2
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(pixels.prefix(4_096).allSatisfy { $0 == engine.filterPixel(original) })
        XCTAssertTrue(pixels.suffix(4_096).allSatisfy { $0 == original })
        var untouched = [UInt32](repeating: original, count: 8)
        XCTAssertThrowsError(try engine.filterPixels(&untouched, isCancelled: { true }))
        XCTAssertEqual(untouched, [UInt32](repeating: original, count: 8))
    }

    private func curveHash(_ values: [UInt16]) -> String {
        let bytes = values.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
